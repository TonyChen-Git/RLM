#!/usr/bin/env python3
"""Create a deterministic, detached-Ed25519 LumaChat update envelope.

The private key is read only by OpenSSL and is never copied into output or a
temporary file. The app verifies the exact Base64 payload bytes, so no client
depends on reproducing Python's JSON serialization.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.parse
import uuid


MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--application", required=True)
    parser.add_argument("--archive-url", required=True)
    parser.add_argument("--feed-output", required=True)
    parser.add_argument("--private-key", required=True)
    parser.add_argument("--public-key-base64", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--minimum-system-version", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--release-notes-url")
    return parser.parse_args()


def require_https(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or any(ord(character) < 0x20 for character in value)
        or len(value.encode("utf-8")) > 2048
    ):
        raise ValueError("release URLs must be credential-free HTTPS URLs")
    return value


def require_version(value: str) -> str:
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){1,3}", value):
        raise ValueError(f"unsupported numeric version: {value}")
    return value


def file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def application_digest(root: Path) -> str:
    value = hashlib.sha256()
    entries = sorted(root.rglob("*"), key=lambda item: item.as_posix())
    if len(entries) > 100_000:
        raise ValueError("application contains too many entries")
    for path in entries:
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        if path.is_symlink() or path.name.startswith("._"):
            raise ValueError(f"unsafe application entry: {relative}")
        if path.is_dir():
            kind = "d"
        elif path.is_file():
            kind = "f"
        else:
            raise ValueError(f"special application entry: {relative}")
        header = f"{kind}\0{relative}\0{metadata.st_mode & 0o7777}\0{metadata.st_size}\0".encode()
        value.update(header)
        if kind == "f":
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    value.update(block)
        value.update(b"\xff")
    return value.hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    temporary_root = Path(os.environ["TMPDIR"]).resolve()
    temporary_root.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="lumachat-feed-", suffix=".tmp", dir=temporary_root
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        path.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    args = parse_args()
    archive = Path(args.archive).resolve(strict=True)
    application = Path(args.application).resolve(strict=True)
    private_key = Path(args.private_key).resolve(strict=True)
    output = Path(args.feed_output).resolve()
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("archive must be a regular non-symlink file")
    if application.is_symlink() or not application.is_dir() or application.suffix != ".app":
        raise ValueError("application must be a regular non-symlink app bundle")
    if private_key.is_symlink() or not private_key.is_file():
        raise ValueError("private key must be a regular non-symlink file")
    archive_size = archive.stat().st_size
    if not 0 < archive_size <= MAX_ARCHIVE_BYTES:
        raise ValueError("archive size is outside the update contract")
    if not 0 < args.build <= 2_147_483_647:
        raise ValueError("build number is outside the update contract")
    version = require_version(args.version)
    minimum_system_version = require_version(args.minimum_system_version)
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_identifier):
        raise ValueError("invalid Apple Team ID")
    if args.bundle_identifier != "com.lumachat.desktop":
        raise ValueError("unexpected bundle identifier")
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", args.architecture):
        raise ValueError("invalid architecture")

    public_key = base64.b64decode(args.public_key_base64, validate=True)
    if len(public_key) != 32:
        raise ValueError("Ed25519 public key must be 32 raw bytes")
    derived = subprocess.run(
        [
            "/usr/bin/openssl",
            "pkey",
            "-in",
            str(private_key),
            "-pubout",
            "-outform",
            "DER",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
    ).stdout
    if derived != ED25519_SPKI_PREFIX + public_key:
        raise ValueError("private key does not match the configured raw public key")

    epoch_value = os.environ.get("SOURCE_DATE_EPOCH", "")
    if not re.fullmatch(r"[0-9]{10,}", epoch_value):
        raise ValueError("SOURCE_DATE_EPOCH is required")
    published_at = dt.datetime.fromtimestamp(
        int(epoch_value), tz=dt.timezone.utc
    ).isoformat(timespec="seconds").replace("+00:00", "Z")
    archive_hash = file_digest(archive)
    release_id = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"{args.bundle_identifier}:{version}:{args.build}:{args.architecture}:{archive_hash}",
    )
    payload: dict[str, object] = {
        "archiveSHA256": archive_hash,
        "archiveSize": archive_size,
        "archiveURL": require_https(args.archive_url),
        "applicationSHA256": application_digest(application),
        "architectures": [args.architecture],
        "build": args.build,
        "bundleIdentifier": args.bundle_identifier,
        "minimumSystemVersion": minimum_system_version,
        "notarized": True,
        "publishedAt": published_at,
        "releaseID": str(release_id).upper(),
        "schemaVersion": 1,
        "teamIdentifier": args.team_identifier,
        "version": version,
    }
    if args.release_notes_url:
        payload["releaseNotesURL"] = require_https(args.release_notes_url)
    payload_bytes = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    signature = subprocess.run(
        [
            "/usr/bin/openssl",
            "pkeyutl",
            "-sign",
            "-rawin",
            "-inkey",
            str(private_key),
        ],
        check=True,
        input=payload_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
    ).stdout
    if len(signature) != 64:
        raise ValueError("OpenSSL returned an invalid Ed25519 signature")
    envelope = {
        "payload": base64.b64encode(payload_bytes).decode("ascii"),
        "schemaVersion": 1,
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    output_bytes = (
        json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        + "\n"
    ).encode("utf-8")
    atomic_write(output, output_bytes)


if __name__ == "__main__":
    main()
