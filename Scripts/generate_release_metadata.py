#!/usr/bin/env python3
"""Generate checksums, exact bundle manifest, SPDX SBOM, and provenance."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import uuid


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--release-mode", choices=("development", "production"), required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--architecture", required=True)
    return parser.parse_args()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_atomic(output: Path, data: bytes) -> None:
    root = Path(os.environ["TMPDIR"]).resolve(strict=True)
    descriptor, name = tempfile.mkstemp(prefix="lumachat-metadata-", suffix=".tmp", dir=root)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def app_manifest(app: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for base, directories, files in os.walk(app, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            if name.startswith("._"):
                raise ValueError("AppleDouble metadata is not permitted in release payloads")
            path = Path(base, name)
            relative = path.relative_to(app.parent).as_posix()
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"release payload contains symlink: {relative}")
            item: dict[str, object] = {
                "mode": stat.S_IMODE(metadata.st_mode),
                "path": relative,
                "type": "directory" if stat.S_ISDIR(metadata.st_mode) else "file",
            }
            if stat.S_ISREG(metadata.st_mode):
                item["sha256"] = digest(path)
                item["size"] = metadata.st_size
            entries.append(item)
    return entries


def main() -> None:
    args = arguments()
    project = Path(args.project_root).resolve(strict=True)
    app = Path(args.app).resolve(strict=True)
    archive = Path(args.archive).resolve(strict=True)
    output = Path(args.output_directory).resolve()
    if project not in app.parents or project not in archive.parents or app.is_symlink() or archive.is_symlink():
        raise ValueError("release inputs must be regular project-owned paths")
    epoch_text = os.environ.get("SOURCE_DATE_EPOCH", "")
    if args.release_mode == "production" and not epoch_text.isdigit():
        raise ValueError("production provenance requires SOURCE_DATE_EPOCH")
    epoch = int(epoch_text) if epoch_text.isdigit() else 0
    created = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")
    manifest = {
        "application": app.name,
        "entries": app_manifest(app),
        "schemaVersion": 1,
    }
    manifest_data = canonical_bytes(manifest)
    manifest_hash = hashlib.sha256(manifest_data).hexdigest()
    archive_hash = digest(archive)
    namespace = f"https://lumachat.local/spdx/{args.version}/{args.build}/{args.architecture}/{archive_hash}"
    sbom = {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {
            "created": created,
            "creators": ["Tool: LumaChat-generate_release_metadata.py"],
        },
        "dataLicense": "CC0-1.0",
        "documentNamespace": namespace,
        "name": f"LumaChat-{args.version}-{args.architecture}",
        "packages": [
            {
                "SPDXID": "SPDXRef-Package-LumaChat",
                "checksums": [{"algorithm": "SHA256", "checksumValue": archive_hash}],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "name": "LumaChat",
                "supplier": "Organization: LumaChat",
                "versionInfo": f"{args.version}+{args.build}",
            }
        ],
        "relationships": [
            {
                "relatedSpdxElement": "SPDXRef-Package-LumaChat",
                "relationshipType": "DESCRIBES",
                "spdxElementId": "SPDXRef-DOCUMENT",
            }
        ],
        "spdxVersion": "SPDX-2.3",
    }
    provenance = {
        "_type": "https://in-toto.io/Statement/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://lumachat.local/build/macos-swiftpm-v1",
                "externalParameters": {
                    "architecture": args.architecture,
                    "build": args.build,
                    "releaseMode": args.release_mode,
                    "version": args.version,
                },
                "internalParameters": {},
                "resolvedDependencies": [
                    {
                        "digest": {"sha256": digest(project / "Package.swift")},
                        "uri": "file:Package.swift",
                    }
                ],
            },
            "runDetails": {
                "builder": {"id": "https://lumachat.local/release.sh"},
                "byproducts": [
                    {"name": "application-manifest", "sha256": manifest_hash}
                ],
                "metadata": {"finishedOn": created, "invocationId": str(uuid.uuid5(uuid.NAMESPACE_URL, namespace))},
            },
        },
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": [{"digest": {"sha256": archive_hash}, "name": archive.name}],
    }
    stem = f"LumaChat-{args.version}-{args.architecture}"
    write_atomic(output / f"{stem}.archive-manifest.json", manifest_data)
    write_atomic(output / f"{stem}.sbom.spdx.json", canonical_bytes(sbom))
    write_atomic(output / f"{stem}.provenance.json", canonical_bytes(provenance))
    write_atomic(output / f"{stem}.sha256", f"{archive_hash}  {archive.name}\n".encode())


if __name__ == "__main__":
    main()
