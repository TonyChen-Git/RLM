#!/usr/bin/env python3
"""Local protocol and isolation acceptance for the self-managed Linux worker."""
import json
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock


WORKER = pathlib.Path(__file__).with_name("lumachat-worker")


class WorkerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lumachat-worker-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.environment = dict(os.environ, XDG_STATE_HOME=str(self.root / "state"))
        self.git("init")
        (self.repo / "README").write_text("base\n")
        self.git("add", "README")
        self.git("-c", "user.name=Worker Test", "-c", "user.email=worker@test.invalid",
                 "commit", "-m", "base")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                       capture_output=True, env=self.environment)

    def call(self, operation, **fields):
        request = {"protocol": 1, "operation": operation, "repo": str(self.repo), **fields}
        result = subprocess.run([str(WORKER)], input=json.dumps(request).encode(),
                                capture_output=True, env=self.environment, timeout=15)
        self.assertLessEqual(len(result.stdout), 1024 * 1024)
        return json.loads(result.stdout)

    def wait_job(self, job_id, expected, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            response = self.call("status", job_id=job_id)
            self.assertTrue(response["ok"], response)
            if response["result"]["status"] == expected:
                return response["result"]
            time.sleep(0.1)
        self.fail(f"Worker did not reach {expected}")

    def test_hello_idempotency_untracked_diff_and_logs(self):
        hello = self.call("hello")
        self.assertTrue(hello["ok"], hello)
        self.assertIn("worktree", hello["result"]["capabilities"])
        job_id = str(uuid.uuid4())
        argv = ["python3", "-c", "open('new.txt','w').write('new\\n'); print('done')"]
        start = self.call("start", job_id=job_id, argv=argv, network="allow")
        self.assertTrue(start["ok"], start)
        duplicate = self.call("start", job_id=job_id, argv=argv, network="allow")
        self.assertTrue(duplicate["ok"], duplicate)
        self.assertEqual(duplicate["result"]["job_id"], job_id)
        changed = self.call("start", job_id=job_id, argv=["false"], network="allow")
        self.assertEqual(changed["error"], "idempotency_conflict")
        self.wait_job(job_id, "completed")
        patch = self.call("diff", job_id=job_id)
        self.assertTrue(patch["ok"], patch)
        self.assertIn("new.txt", patch["result"]["diff"])
        logs = self.call("logs", job_id=job_id)
        self.assertIn("done", logs["result"]["text"])
        self.assertFalse((self.repo / "new.txt").exists())

    def test_bad_protocol(self):
        self.assertEqual(self.call("hello", protocol=0)["error"], "protocol_mismatch")

    def test_failed_prepare_can_retry_same_job_id(self):
        job_id = str(uuid.uuid4())
        invalid = self.call("start", job_id=job_id, argv=["true"],
                            ref="missing-ref", network="allow")
        self.assertEqual(invalid["error"], "invalid_ref")
        started = self.call("start", job_id=job_id, argv=["true"], network="allow")
        self.assertTrue(started["ok"], started)
        self.wait_job(job_id, "completed")

    def test_spawn_failure_becomes_failed_without_stale_running_state(self):
        job_id = str(uuid.uuid4())
        response = self.call("start", job_id=job_id,
                             argv=["/does/not/exist/lumachat-worker-test"], network="allow")
        self.assertTrue(response["ok"], response)
        failed = self.wait_job(job_id, "failed")
        self.assertIsNone(failed["exit_code"])

    def test_diff_includes_commits_created_by_job(self):
        job_id = str(uuid.uuid4())
        command = "printf 'committed\\n' > committed.txt; git add committed.txt; " \
                  "git -c user.name=Test -c user.email=test@example.invalid commit -m result"
        response = self.call("start", job_id=job_id,
                             argv=["/bin/sh", "-c", command], network="allow")
        self.assertTrue(response["ok"], response)
        self.wait_job(job_id, "completed")
        patch = self.call("diff", job_id=job_id)
        self.assertTrue(patch["ok"], patch)
        self.assertIn("+committed", patch["result"]["diff"])

    def test_log_limit_stops_sigterm_ignoring_child_and_remains_bounded(self):
        job_id = str(uuid.uuid4())
        command = ("import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                   "print(os.getpid(), flush=True); "
                   "os.write(1,b'x'*(9*1024*1024)); time.sleep(60)")
        started = self.call("start", job_id=job_id,
                            argv=["python3", "-c", command], network="allow")
        self.assertTrue(started["ok"], started)
        self.wait_job(job_id, "failed")
        log_path = pathlib.Path(started["result"]["checkout"]).parent / "output.log"
        self.assertEqual(log_path.stat().st_size, 8 * 1024 * 1024)
        child_pid = int(log_path.read_bytes().split(b"\n", 1)[0])
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_cancel_waits_for_sigterm_ignoring_child_to_exit(self):
        job_id = str(uuid.uuid4())
        command = ("import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                   "print(os.getpid(), flush=True); time.sleep(60)")
        started = self.call("start", job_id=job_id,
                            argv=["python3", "-c", command], network="allow")
        self.assertTrue(started["ok"], started)
        log_path = pathlib.Path(started["result"]["checkout"]).parent / "output.log"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (not log_path.exists() or not log_path.read_bytes()):
            time.sleep(0.05)
        child_pid = int(log_path.read_bytes().strip())
        response = self.call("cancel", job_id=job_id)
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["result"]["status"], "cancelled")
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_invalid_utf8_log_stays_within_client_text_bound(self):
        job_id = str(uuid.uuid4())
        started = self.call("start", job_id=job_id,
                            argv=["python3", "-c", "import os; os.write(1,b'\\xff'*262144)"],
                            network="allow")
        self.assertTrue(started["ok"], started)
        self.wait_job(job_id, "completed")
        response = self.call("logs", job_id=job_id)
        self.assertTrue(response["ok"], response)
        self.assertLessEqual(len(response["result"]["text"].encode()), 256 * 1024)
        self.assertEqual(response["result"]["next_offset"], 64 * 1024)

    def test_proc_identity_parses_parenthesized_names(self):
        loader = importlib.machinery.SourceFileLoader("lumachat_worker_tests", str(WORKER))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
        stat = "123 (a job ) name) S 45 " + " ".join(str(n) for n in range(5, 53))
        with mock.patch.object(pathlib.Path, "read_text", return_value=stat):
            self.assertEqual(module.process_birth(123), "22")
            self.assertEqual(module.process_info(123)["parent"], 45)

    @unittest.skipUnless(sys.platform == "linux", "Process cancellation requires Linux /proc")
    def test_cancel(self):
        job_id = str(uuid.uuid4())
        started = self.call("start", job_id=job_id,
                            argv=["python3", "-c", "import time; time.sleep(60)"],
                            network="allow")
        self.assertTrue(started["ok"], started)
        cancelled = self.call("cancel", job_id=job_id)
        self.assertTrue(cancelled["ok"], cancelled)
        self.assertEqual(self.call("status", job_id=job_id)["result"]["status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
