#!/usr/bin/python3
"""Build and verify LumaChat's release ZIP with canonical POSIX metadata."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from typing import Dict, Iterable, List, Tuple
import zipfile


ARTIFACT_WORKFLOW_PLUGIN = "com.lumachat.artifact-workflows"
ARTIFACT_WORKFLOW_SKILLS = (
    "document",
    "image",
    "pdf",
    "presentation",
    "site",
    "spreadsheet",
    "visualization",
)
ARTIFACT_WORKFLOW_ARCHIVE_ROOT = (
    f"LumaChat.app/Contents/Resources/BuiltinPlugins/{ARTIFACT_WORKFLOW_PLUGIN}"
)

ARCHIVE_DIRECTORIES = {
    "LumaChat.app/",
    "LumaChat.app/Contents/",
    "LumaChat.app/Contents/MacOS/",
    "LumaChat.app/Contents/Resources/",
    "LumaChat.app/Contents/Resources/bin/",
    "LumaChat.app/Contents/Resources/BuiltinPlugins/",
    f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/",
    f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/skills/",
    "LumaChat.app/Contents/_CodeSignature/",
} | {
    f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/skills/{skill}/"
    for skill in ARTIFACT_WORKFLOW_SKILLS
}
ARCHIVE_FILES = {
    "LumaChat.app/Contents/Info.plist": 0o644,
    "LumaChat.app/Contents/MacOS/LumaChat": 0o755,
    "LumaChat.app/Contents/Resources/AppIcon.icns": 0o644,
    "LumaChat.app/Contents/Resources/bin/lumachat": 0o755,
    f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/plugin.json": 0o644,
    "LumaChat.app/Contents/_CodeSignature/CodeResources": 0o644,
}
ARCHIVE_FILES.update({
    f"{ARTIFACT_WORKFLOW_ARCHIVE_ROOT}/skills/{skill}/SKILL.md": 0o644
    for skill in ARTIFACT_WORKFLOW_SKILLS
})
CANONICAL_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
BUFFER_SIZE = 1024 * 1024


class ArchiveError(RuntimeError):
    pass


def _is_forbidden_member(name: str) -> bool:
    components = [component for component in name.split("/") if component]
    return any(
        component.startswith("._") or component == "__MACOSX"
        for component in components
    )


def _source_entries(source: Path) -> Dict[str, Tuple[Path, bool, int]]:
    if source.name != "LumaChat.app":
        raise ArchiveError("Release source must be named LumaChat.app")

    try:
        root_status = source.lstat()
    except FileNotFoundError as error:
        raise ArchiveError(f"Release source does not exist: {source}") from error
    if not stat.S_ISDIR(root_status.st_mode) or stat.S_ISLNK(root_status.st_mode):
        raise ArchiveError("Release source must be a real directory")

    entries: Dict[str, Tuple[Path, bool, int]] = {}
    for directory, child_directories, filenames in os.walk(
        source, topdown=True, followlinks=False
    ):
        child_directories.sort()
        filenames.sort()
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(source)
        archive_directory = source.name
        if relative_directory.parts:
            archive_directory += "/" + relative_directory.as_posix()
        archive_directory += "/"
        entries[archive_directory] = (directory_path, True, 0o755)

        for child_name in child_directories:
            child_path = directory_path / child_name
            child_status = child_path.lstat()
            if stat.S_ISLNK(child_status.st_mode):
                raise ArchiveError(f"Release bundle contains a symlink: {child_path}")
            if not stat.S_ISDIR(child_status.st_mode):
                raise ArchiveError(f"Release bundle contains an invalid node: {child_path}")

        for filename in filenames:
            file_path = directory_path / filename
            file_status = file_path.lstat()
            relative_file = file_path.relative_to(source).as_posix()
            archive_name = f"{source.name}/{relative_file}"
            if _is_forbidden_member(archive_name):
                raise ArchiveError(f"Release bundle contains metadata sidecar: {archive_name}")
            if stat.S_ISLNK(file_status.st_mode):
                raise ArchiveError(f"Release bundle contains a symlink: {file_path}")
            if not stat.S_ISREG(file_status.st_mode):
                raise ArchiveError(f"Release bundle contains an invalid node: {file_path}")
            entries[archive_name] = (
                file_path,
                False,
                ARCHIVE_FILES.get(archive_name, 0o644),
            )

    actual_directories = {name for name, (_, is_directory, _) in entries.items() if is_directory}
    actual_files = {name for name, (_, is_directory, _) in entries.items() if not is_directory}
    missing = sorted((ARCHIVE_DIRECTORIES - actual_directories) | (set(ARCHIVE_FILES) - actual_files))
    unexpected = sorted((actual_directories - ARCHIVE_DIRECTORIES) | (actual_files - set(ARCHIVE_FILES)))
    if missing or unexpected:
        details: List[str] = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if unexpected:
            details.append("unexpected: " + ", ".join(unexpected))
        raise ArchiveError("Release bundle manifest mismatch (" + "; ".join(details) + ")")

    return entries


def _zip_info(name: str, is_directory: bool, mode: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, CANONICAL_TIMESTAMP)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED if is_directory else zipfile.ZIP_DEFLATED
    file_type = stat.S_IFDIR if is_directory else stat.S_IFREG
    info.external_attr = ((file_type | mode) & 0xFFFF) << 16
    if is_directory:
        info.external_attr |= 0x10
    return info


def _ordered_entries(
    entries: Dict[str, Tuple[Path, bool, int]]
) -> Iterable[Tuple[str, Tuple[Path, bool, int]]]:
    return sorted(entries.items(), key=lambda item: (item[0].count("/"), item[0]))


def _write_archive(source: Path, destination: Path) -> None:
    entries = _source_entries(source)
    with zipfile.ZipFile(
        destination,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        allowZip64=True,
    ) as archive:
        for name, (path, is_directory, mode) in _ordered_entries(entries):
            info = _zip_info(name, is_directory, mode)
            if is_directory:
                archive.writestr(info, b"")
                continue
            with path.open("rb") as source_file, archive.open(
                info, mode="w", force_zip64=True
            ) as destination_file:
                shutil.copyfileobj(source_file, destination_file, BUFFER_SIZE)


def _digest(stream) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = stream.read(BUFFER_SIZE)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def verify_archive(source: Path, archive_path: Path) -> None:
    expected = _source_entries(source)
    try:
        archive = zipfile.ZipFile(archive_path, mode="r")
    except (FileNotFoundError, zipfile.BadZipFile) as error:
        raise ArchiveError(f"Invalid release archive: {archive_path}") from error

    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ArchiveError("Release archive contains duplicate member names")
        if any(
            name.startswith("/")
            or "\\" in name
            or ".." in [part for part in name.split("/") if part]
            or _is_forbidden_member(name)
            for name in names
        ):
            raise ArchiveError("Release archive contains an unsafe member name")
        if set(names) != set(expected):
            raise ArchiveError("Release archive members do not match the signed bundle")

        for info in infos:
            source_path, is_directory, expected_mode = expected[info.filename]
            if info.create_system != 3:
                raise ArchiveError(f"Archive member is missing Unix metadata: {info.filename}")
            archived_mode = (info.external_attr >> 16) & 0xFFFF
            expected_type = stat.S_IFDIR if is_directory else stat.S_IFREG
            if stat.S_IFMT(archived_mode) != expected_type:
                raise ArchiveError(f"Archive member has wrong file type: {info.filename}")
            if stat.S_IMODE(archived_mode) != expected_mode:
                raise ArchiveError(
                    f"Archive member has wrong mode {stat.S_IMODE(archived_mode):04o}: "
                    f"{info.filename}"
                )
            if info.is_dir() != is_directory:
                raise ArchiveError(f"Archive directory marker mismatch: {info.filename}")
            if not is_directory:
                with archive.open(info, mode="r") as archived_file, source_path.open(
                    "rb"
                ) as source_file:
                    if _digest(archived_file) != _digest(source_file):
                        raise ArchiveError(f"Archive content mismatch: {info.filename}")

        corrupt_member = archive.testzip()
        if corrupt_member is not None:
            raise ArchiveError(f"Archive CRC failed: {corrupt_member}")


def create_archive(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        _write_archive(source, temporary_path)
        verify_archive(source, temporary_path)
        with temporary_path.open("rb") as archive_file:
            os.fsync(archive_file.fileno())
        os.replace(temporary_path, output)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_descriptor = os.open(output.parent, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("create", "verify"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = _arguments()
    source = arguments.source.resolve()
    archive = arguments.archive.resolve()
    try:
        if arguments.operation == "create":
            create_archive(source, archive)
        else:
            verify_archive(source, archive)
    except (ArchiveError, OSError, zipfile.BadZipFile) as error:
        print(f"release archive error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
