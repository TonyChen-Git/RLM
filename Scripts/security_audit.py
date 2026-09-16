#!/usr/bin/env python3
"""Fail-closed static and packaged security checks for a LumaChat release."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile


SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"sk-[A-Za-z0-9_-]{24,}"),
)
SOURCE_SUFFIXES = {".swift", ".js", ".json", ".md", ".py", ".sh", ".yml", ".yaml", ".plist"}


def args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--application", required=True)
    parser.add_argument("--release-mode", choices=("development", "production"), required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args()


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
    )
    if completed.returncode != 0:
        raise ValueError(f"command failed ({command[0]}): {completed.stdout[:2048].decode(errors='replace')}")
    return completed.stdout[:65536].decode(errors="replace")


def audit_tree(root: Path, *, scan_secrets: bool) -> tuple[int, int]:
    files = 0
    bytes_seen = 0
    for base, directories, names in os.walk(root, topdown=True, followlinks=False):
        directories[:] = sorted(
            name for name in directories if name not in {"tmp", "dist", ".git"}
        )
        for name in directories + sorted(names):
            if name.startswith("._"):
                raise ValueError(f"AppleDouble file is present: {Path(base, name)}")
            path = Path(base, name)
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"symlink is not permitted in audited payload: {path}")
            if not stat.S_ISREG(metadata.st_mode):
                continue
            files += 1
            bytes_seen += metadata.st_size
            if scan_secrets and path.suffix.lower() in SOURCE_SUFFIXES and metadata.st_size <= 2 * 1024 * 1024:
                value = path.read_bytes()
                if any(pattern.search(value) for pattern in SECRET_PATTERNS):
                    raise ValueError(f"possible embedded credential in {path}")
    return files, bytes_seen


def atomic_report(path: Path, value: dict[str, object]) -> None:
    root = Path(os.environ.get("TMPDIR", path.parent)).resolve()
    root.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="lumachat-security-", suffix=".tmp", dir=root)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        path.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    options = args()
    project = Path(options.project_root).resolve(strict=True)
    application = Path(options.application).resolve(strict=True)
    report = Path(options.report).resolve()
    if project not in application.parents or project not in report.parents:
        raise ValueError("audit paths must remain inside the project")
    source_files, source_bytes = audit_tree(project, scan_secrets=True)
    app_files, app_bytes = audit_tree(application, scan_secrets=True)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)])
    entitlement_process = subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(application)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
    )
    if entitlement_process.returncode != 0:
        raise ValueError("signed entitlements could not be inspected")
    try:
        entitlements = plistlib.loads(entitlement_process.stdout)
    except Exception as error:
        raise ValueError("signed entitlements are not a property list") from error
    if entitlements.get("com.apple.security.get-task-allow") is True:
        raise ValueError("get-task-allow is enabled")
    plist = application / "Contents" / "Info.plist"
    feed = run(["/usr/bin/plutil", "-extract", "LumaChatUpdateFeedURL", "raw", "-o", "-", str(plist)]).strip()
    key = run(["/usr/bin/plutil", "-extract", "LumaChatUpdatePublicKey", "raw", "-o", "-", str(plist)]).strip()
    team = run(["/usr/bin/plutil", "-extract", "LumaChatUpdateTeamIdentifier", "raw", "-o", "-", str(plist)]).strip()
    if options.release_mode == "production":
        if not feed.startswith("https://") or len(key) < 40 or not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ValueError("production update trust configuration is incomplete")
        run(["/usr/bin/xcrun", "stapler", "validate", str(application)])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(application)])
    elif any((feed, key, team)):
        raise ValueError("development release must keep auto-update trust disabled")
    atomic_report(
        report,
        {
            "applicationBytes": app_bytes,
            "applicationFiles": app_files,
            "getTaskAllow": False,
            "releaseMode": options.release_mode,
            "schemaVersion": 1,
            "sourceBytes": source_bytes,
            "sourceFiles": source_files,
            "updateTrustConfigured": options.release_mode == "production",
        },
    )


if __name__ == "__main__":
    main()
