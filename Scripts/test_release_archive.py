#!/usr/bin/python3

import copy
import os
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

from release_archive import (
    ARTIFACT_WORKFLOW_ARCHIVE_ROOT,
    ARTIFACT_WORKFLOW_SKILLS,
    ArchiveError,
    create_archive,
    verify_archive,
)


class ReleaseArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary_root = os.environ.get("LUMACHAT_RELEASE_TEST_ROOT")
        if temporary_root is None:
            project_root = Path(__file__).resolve().parent.parent
            project_temporary_root = project_root / "tmp/release-archive-tests"
            project_temporary_root.mkdir(parents=True, exist_ok=True)
            temporary_root = str(project_temporary_root)
        self.root = Path(tempfile.mkdtemp(dir=temporary_root))
        self.application = self.root / "LumaChat.app"
        (self.application / "Contents/MacOS").mkdir(parents=True)
        (self.application / "Contents/Resources/bin").mkdir(parents=True)
        plugin = self.application / (
            "Contents/Resources/BuiltinPlugins/com.lumachat.artifact-workflows"
        )
        self.plugin = plugin
        (plugin / "skills").mkdir(parents=True)
        (self.application / "Contents/_CodeSignature").mkdir()
        (self.application / "Contents/Info.plist").write_bytes(b"plist")
        (self.application / "Contents/MacOS/LumaChat").write_bytes(b"binary")
        (self.application / "Contents/Resources/AppIcon.icns").write_bytes(b"icon")
        (self.application / "Contents/Resources/bin/lumachat").write_bytes(b"cli")
        (plugin / "plugin.json").write_bytes(b"{}")
        for skill in ARTIFACT_WORKFLOW_SKILLS:
            directory = plugin / "skills" / skill
            directory.mkdir()
            (directory / "SKILL.md").write_bytes(f"# {skill}\n".encode("utf-8"))
        (self.application / "Contents/_CodeSignature/CodeResources").write_bytes(
            b"signature"
        )
        self.archive = self.root / "LumaChat.zip"

    def tearDown(self) -> None:
        # Intentionally retain project-local fixtures. The repository policy
        # forbids recursively deleting AppleDouble sidecars that an ExFAT host
        # may materialize behind the test process.
        pass

    def test_create_uses_canonical_modes_and_verifies_contents(self) -> None:
        create_archive(self.application, self.archive)
        verify_archive(self.application, self.archive)

        with zipfile.ZipFile(self.archive) as archive:
            modes = {
                info.filename: stat.S_IMODE((info.external_attr >> 16) & 0xFFFF)
                for info in archive.infolist()
            }
            workflow_files = {
                info.filename
                for info in archive.infolist()
                if info.filename.startswith(f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/")
                and not info.is_dir()
            }

        self.assertEqual(modes["LumaChat.app/"], 0o755)
        self.assertEqual(modes["LumaChat.app/Contents/MacOS/LumaChat"], 0o755)
        self.assertEqual(modes["LumaChat.app/Contents/Info.plist"], 0o644)
        self.assertEqual(
            modes["LumaChat.app/Contents/Resources/AppIcon.icns"], 0o644
        )
        self.assertEqual(
            modes["LumaChat.app/Contents/Resources/bin/lumachat"], 0o755
        )
        self.assertEqual(
            modes[
                "LumaChat.app/Contents/Resources/BuiltinPlugins/"
                "com.lumachat.artifact-workflows/skills/pdf/SKILL.md"
            ],
            0o644,
        )
        self.assertEqual(
            workflow_files,
            {f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/plugin.json"}
            | {
                f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/skills/{skill}/SKILL.md"
                for skill in ARTIFACT_WORKFLOW_SKILLS
            },
        )

    def test_create_requires_every_artifact_workflow_skill(self) -> None:
        missing = self.plugin / "skills/visualization/SKILL.md"
        missing.unlink()

        with self.assertRaisesRegex(ArchiveError, "manifest mismatch.*missing"):
            create_archive(self.application, self.archive)

    def test_create_rejects_appledouble_source_file(self) -> None:
        (self.application / "Contents/._Info.plist").write_bytes(b"metadata")

        with self.assertRaisesRegex(ArchiveError, "metadata sidecar"):
            create_archive(self.application, self.archive)

    def test_verify_rejects_tampered_mode(self) -> None:
        create_archive(self.application, self.archive)
        altered_archive = self.root / "altered-mode.zip"
        with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(
            altered_archive, mode="w"
        ) as destination:
            for original in source.infolist():
                info = copy.copy(original)
                if info.filename == "LumaChat.app/Contents/Info.plist":
                    info.external_attr = ((stat.S_IFREG | 0o755) & 0xFFFF) << 16
                destination.writestr(info, source.read(original))

        with self.assertRaisesRegex(ArchiveError, "wrong mode"):
            verify_archive(self.application, altered_archive)

    def test_verify_rejects_tampered_content_even_with_valid_crc(self) -> None:
        create_archive(self.application, self.archive)
        altered_archive = self.root / "altered-content.zip"
        with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(
            altered_archive, mode="w"
        ) as destination:
            for info in source.infolist():
                data = source.read(info)
                if info.filename == "LumaChat.app/Contents/Info.plist":
                    data = b"different plist"
                destination.writestr(info, data)

        with self.assertRaisesRegex(ArchiveError, "content mismatch"):
            verify_archive(self.application, altered_archive)

    def test_verify_rejects_injected_appledouble_member(self) -> None:
        create_archive(self.application, self.archive)
        altered_archive = self.root / "altered-members.zip"
        with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(
            altered_archive, mode="w"
        ) as destination:
            for info in source.infolist():
                destination.writestr(info, source.read(info))
            destination.writestr("LumaChat.app/Contents/._Injected", b"metadata")

        with self.assertRaisesRegex(ArchiveError, "unsafe member name"):
            verify_archive(self.application, altered_archive)


if __name__ == "__main__":
    unittest.main()
