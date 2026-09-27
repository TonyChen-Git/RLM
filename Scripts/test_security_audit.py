#!/usr/bin/env python3
"""Unit tests for release security-audit report persistence."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import unittest
import uuid
from unittest import mock

import security_audit


class SecurityAuditReportTests(unittest.TestCase):
    def setUp(self) -> None:
        project = Path(__file__).resolve().parent.parent
        base = Path(
            os.environ.get("LUMACHAT_RELEASE_TEST_ROOT", project / "tmp")
        ).resolve()
        self.root = base / f"security-audit-contract-{uuid.uuid4()}"
        self.root.mkdir(parents=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def test_source_tree_skips_generated_build_but_rejects_source_symlink(self) -> None:
        source = self.root / "Sources"
        source.mkdir()
        (source / "main.swift").write_text("let value = 1\n", encoding="utf-8")
        build = self.root / ".build"
        build.mkdir()
        (build / "debug").symlink_to(source, target_is_directory=True)
        excluded = frozenset({"tmp", "dist", ".git", ".build"})

        self.assertEqual(
            security_audit.audit_tree(
                self.root,
                scan_secrets=True,
                excluded_root_names=excluded,
            ),
            (1, len("let value = 1\n")),
        )

        (source / "linked.swift").symlink_to(source / "main.swift")
        with self.assertRaisesRegex(ValueError, "symlink is not permitted"):
            security_audit.audit_tree(
                self.root,
                scan_secrets=True,
                excluded_root_names=excluded,
            )

    def test_app_tree_rejects_symlink_inside_generated_named_directory(self) -> None:
        application = self.root / "LumaChat.app"
        resources = application / "Contents" / "Resources" / ".build"
        resources.mkdir(parents=True)
        (resources / "debug").symlink_to(self.root, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "symlink is not permitted"):
            security_audit.audit_tree(application, scan_secrets=True)

    def test_atomic_report_uses_destination_filesystem_not_environment_tmpdir(self) -> None:
        report = self.root / "reports" / "security-audit.json"
        unrelated_tmpdir = self.root / "unrelated-system-tmp"
        unrelated_tmpdir.mkdir()
        real_mkstemp = security_audit.tempfile.mkstemp
        observed_directories: list[Path] = []

        def recording_mkstemp(*args: object, **kwargs: object) -> tuple[int, str]:
            observed_directories.append(Path(str(kwargs["dir"])).resolve())
            return real_mkstemp(*args, **kwargs)

        with mock.patch.dict(os.environ, {"TMPDIR": str(unrelated_tmpdir)}), mock.patch.object(
            security_audit.tempfile,
            "mkstemp",
            side_effect=recording_mkstemp,
        ):
            security_audit.atomic_report(report, {"schemaVersion": 1, "valid": True})

        self.assertEqual(observed_directories, [report.parent.resolve()])
        self.assertEqual(
            json.loads(report.read_text(encoding="utf-8")),
            {"schemaVersion": 1, "valid": True},
        )
        self.assertEqual(list(report.parent.glob("lumachat-security-*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
