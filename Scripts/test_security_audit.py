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
