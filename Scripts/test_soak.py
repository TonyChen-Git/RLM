#!/usr/bin/env python3
"""Unit tests for the durable Phase H and I–Q soak contract."""

from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import unittest
import uuid
from unittest import mock

import soak


# These are required coverage, rather than a copy of each shard's entire filter.
# Reading the Swift test sources below also catches renamed or removed suites.
REQUIRED_SUITES = {
    "agent": {
        "AgentCoreTests", "AgentRuntimeStreamingTests", "AgentProviderToolCallingTests",
        "AgentLocalMemoryStoreTests", "AgentLocalMemoryIntegrationTests",
        "AgentProjectSettingsTests", "AgentProjectSettingsIntegrationTests",
        "AgentProjectImportRollbackTests",
        "ProjectInstructionImporterTests", "ProjectInstructionRuleProjectorTests",
        "ExternalAssistantChatImporterTests", "ExternalAssistantChatImportIntegrationTests",
    },
    "pty": {
        "PseudoTerminalSessionTests", "TaskTerminalServiceTests", "AgentTerminalStreamingTests",
        "SSHInteractiveTerminalTests", "AgentViewModelTaskTerminalLifecycleTests",
        "AgentWorkerAuthorityTests", "RemoteRunnerTests",
    },
    "subagent": {"SubagentSchedulerTests"},
    "automation": {
        "AutomationSchedulerTests", "GitHubWebhookIngressTests", "PullRequestProviderTests",
    },
    "browser": {"BrowserToolTests", "BrowserAnnotationTests", "CDPWebSocketLifecycleTests"},
    "ollama-reconnect": {
        "AgentProviderStreamingTests", "LLMReasoningStreamTests", "MCPRuntimeTests",
        "MCPConnectionLifecycleTests", "MCPStreamableHTTPTests", "MCPResourcesPromptsTests",
        "PhaseDOAuthAndMCPTests", "PluginRegistryIntegrityTests", "PhaseDPluginAndHookTests",
    },
    "task-switching": {
        "AgentViewModelConcurrencyTests", "ChatViewModelConcurrencyTests",
        "AgentViewModelPersistenceTests", "AgentSessionStoreOrderingTests",
        "AgentQueuedFollowUpTests", "AgentSteerTests", "AgentSteerReceiptStoreTests",
        "SideChatSessionTests", "TaskVoiceProviderTests",
    },
}

REQUIRED_FAILURE_SELECTORS = {
    "force-quit": "AgentCoreTests/testInterruptedRunRecoveryPersistsTruthfulPausedState",
    "disk-full": "PhaseHUpdateTests/testDiskFullAfterAtomicSwapRestoresPreviousApplication",
    "network-down": "PhaseHFailureInjectionTests/testNetworkDownLeavesUpdateStateUnchanged",
    "ollama-down": "PhaseHFailureInjectionTests/testOllamaDownSurfacesConnectionFailureWithoutModels",
    "mcp-crash": "PhaseHFailureInjectionTests/testMCPProcessCrashFailsPendingRequestAndDisconnects",
    "browser-crash": "PhaseHFailureInjectionTests/testBrowserCrashCleansEphemeralProfileAndSession",
    "pty-crash": "PseudoTerminalSessionTests/testPTYSignalCrashReportsTerminationAndCompletes",
    "git-lock": "PhaseHFailureInjectionTests/testGitIndexLockFailsWithoutMutatingIndexOrWorktree",
    "worktree-deleted": "ManagedWorktreeServiceLifecycleTests/testRepairMarksExternallyDeletedCheckoutMissingWithoutReleasingLease",
    "remote-disconnect": "PhaseHFailureInjectionTests/testRemoteDisconnectPropagatesStableConnectionFailure",
}


class SoakContractTests(unittest.TestCase):
    def setUp(self) -> None:
        project = Path(__file__).resolve().parent.parent
        self.project = project
        base = Path(
            os.environ.get("LUMACHAT_RELEASE_TEST_ROOT", project / "tmp")
        ).resolve()
        self.root = base / f"soak-contract-{uuid.uuid4()}"
        (self.root / "Scripts").mkdir(parents=True)
        self.contract = json.loads(
            (project / "Scripts" / "soak_profiles.json").read_text(encoding="utf-8")
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def write_contract(self, value: dict[str, object]) -> None:
        (self.root / "Scripts" / "soak_profiles.json").write_text(
            json.dumps(value),
            encoding="utf-8",
        )

    def test_current_contract_is_complete_and_resolves_failure_filter(self) -> None:
        self.write_contract(self.contract)
        loaded = soak.load_contract(self.root)
        self.assertEqual(loaded["requiredFailureScenarios"], REQUIRED_FAILURE_SELECTORS)
        failure_shard = next(
            shard
            for shard in loaded["shards"]
            if shard["category"] == "failure-injection"
        )
        pattern = soak.resolved_shard_filter(
            failure_shard,
            loaded["requiredFailureScenarios"],
        )
        for selector in loaded["requiredFailureScenarios"].values():
            self.assertIsNotNone(re.search(pattern, selector))

    def test_phase_i_q_suites_are_selected_in_their_expected_shards(self) -> None:
        shards = {shard["category"]: shard for shard in self.contract["shards"]}
        for category, suites in REQUIRED_SUITES.items():
            pattern = soak.resolved_shard_filter(
                shards[category], self.contract["requiredFailureScenarios"]
            )
            for suite in sorted(suites):
                with self.subTest(category=category, suite=suite):
                    source = (
                        self.project / "Tests" / "LumaChatTests" / f"{suite}.swift"
                    ).read_text(encoding="utf-8")
                    self.assertRegex(source, rf"\bclass {suite}: XCTestCase\b")
                    methods = re.findall(r"\bfunc (test[A-Za-z0-9_]+)\(", source)
                    self.assertTrue(methods, f"{suite} contains no XCTest methods")
                    for method in methods:
                        selector = f"{suite}/{method}"
                        self.assertIsNotNone(re.search(pattern, selector), selector)
                        qualified = f"LumaChatTests.{selector}"
                        self.assertIsNotNone(re.search(pattern, qualified), qualified)
                        # Swift inventory contains both build output and other selectors.
                        inventory = f"Build complete!\nOtherTests/testOther\n{qualified}\n"
                        self.assertIsNotNone(re.search(pattern, inventory), qualified)

    def test_shard_suite_filters_reject_substring_and_malformed_selectors(self) -> None:
        shards = {shard["category"]: shard for shard in self.contract["shards"]}
        for category, suites in REQUIRED_SUITES.items():
            pattern = soak.resolved_shard_filter(
                shards[category], self.contract["requiredFailureScenarios"]
            )
            for suite in sorted(suites):
                misleading = (
                    f"LumaChatTests.Prefix{suite}/testExample",
                    f"LumaChatTests.{suite}Suffix/testExample",
                    f"LumaChatTests.UnrelatedTests/test{suite}",
                    f"Test output mentions LumaChatTests.{suite}/testExample",
                    f"LumaChatTests.{suite}/testExample/extra",
                    f"LumaChatTests.{suite}/helperMethod",
                    f"LumaChatTests.{suite}",
                )
                for selector in misleading:
                    with self.subTest(category=category, selector=selector):
                        self.assertIsNone(re.search(pattern, selector))
            # The old AgentRuntime.*Tests filter silently selected unrelated classes.
            self.assertIsNone(re.search(pattern, "LumaChatTests.AgentRuntimeUnrelatedTests/testExample"))

    def test_contract_rejects_missing_scenario_and_duplicate_category(self) -> None:
        missing = copy.deepcopy(self.contract)
        del missing["requiredFailureScenarios"]["network-down"]
        self.write_contract(missing)
        with self.assertRaisesRegex(ValueError, "coverage is incomplete"):
            soak.load_contract(self.root)

        duplicate = copy.deepcopy(self.contract)
        duplicate["shards"][-1] = copy.deepcopy(duplicate["shards"][0])
        self.write_contract(duplicate)
        with self.assertRaisesRegex(ValueError, "coverage is incomplete or duplicated"):
            soak.load_contract(self.root)

    def test_contract_rejects_regex_or_duplicate_scenario_selectors(self) -> None:
        regex_selector = copy.deepcopy(self.contract)
        regex_selector["requiredFailureScenarios"]["network-down"] = ".*Tests/testAnything"
        self.write_contract(regex_selector)
        with self.assertRaisesRegex(ValueError, "unique exact XCTest selectors"):
            soak.load_contract(self.root)

        duplicate = copy.deepcopy(self.contract)
        duplicate["requiredFailureScenarios"]["network-down"] = duplicate[
            "requiredFailureScenarios"
        ]["ollama-down"]
        self.write_contract(duplicate)
        with self.assertRaisesRegex(ValueError, "unique exact XCTest selectors"):
            soak.load_contract(self.root)

    def test_inventory_requires_each_scenario_selector_exactly_once(self) -> None:
        run_root = self.root / "run"
        run_root.mkdir()
        selector = "PhaseHFailureInjectionTests/testNetworkDownLeavesUpdateStateUnchanged"
        inventory_log = run_root / "test-inventory.log"
        inventory_log.write_text(f"LumaChatTests.{selector}\n", encoding="utf-8")
        shard = {
            "category": "failure-injection",
            "filterSource": "requiredFailureScenarios",
        }
        with mock.patch.object(soak, "run_process", return_value=0):
            soak.assert_filters_exist(
                "/usr/bin/swift",
                self.root,
                run_root,
                {},
                [shard],
                {"network-down": selector},
            )

        inventory_log.write_text(
            f"LumaChatTests.{selector}\nOtherModule.{selector}\n",
            encoding="utf-8",
        )
        with mock.patch.object(soak, "run_process", return_value=0):
            with self.assertRaisesRegex(RuntimeError, "matched 2 tests"):
                soak.assert_filters_exist(
                    "/usr/bin/swift",
                    self.root,
                    run_root,
                    {},
                    [shard],
                    {"network-down": selector},
                )


class SoakRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        project = Path(__file__).resolve().parent.parent
        base = Path(os.environ.get("LUMACHAT_RELEASE_TEST_ROOT", project / "tmp")).resolve()
        self.root = base / f"soak-recovery-{uuid.uuid4()}"
        (self.root / "Scripts").mkdir(parents=True)
        (self.root / "Sources").mkdir()
        (self.root / "Package.swift").write_text("// fixture package\n")
        (self.root / "Sources" / "Fixture.swift").write_text("// source v1\n")
        contract = json.loads((project / "Scripts" / "soak_profiles.json").read_text())
        # Short synthetic timing applies only inside this temporary test project.
        contract["profiles"]["2h"]["durationSeconds"] = 2
        self.contract = contract
        (self.root / "Scripts" / "soak_profiles.json").write_text(json.dumps(contract))
        self.soak_root = self.root / "tmp" / "soak"
        self.soak_root.mkdir(parents=True)
        self.elapsed = 0.0
        self.options = argparse.Namespace(profile="2h", project_root=str(self.root),
            swift=sys.executable, resume=None, duration_seconds=None,
            development_override=False, dry_run=False)
        soak.stopping = False

    def tearDown(self) -> None:
        soak.stopping = False
        shutil.rmtree(self.root, ignore_errors=True)

    def runs(self):
        return [path for path in self.soak_root.iterdir() if path.is_dir()]

    def state(self, path):
        return json.loads((path / "state.json").read_text())

    def invoke(self, *, inventory=None, process=None):
        def make_clock():
            measured_from = self.elapsed
            clock = mock.Mock()
            clock.sample.side_effect = lambda: self.elapsed - measured_from
            return clock

        def successful_process(command, project, environment, log, **kwargs):
            self.elapsed += 0.125
            log.write_text("test fixture passed\n")
            kwargs["heartbeat"]()
            return 0

        with mock.patch.object(soak, "parse_args", return_value=self.options), \
                mock.patch.object(soak, "assert_filters_exist", side_effect=inventory), \
                mock.patch.object(soak, "run_process", side_effect=process or successful_process), \
                mock.patch.object(soak, "ContinuousClock", side_effect=make_clock), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return soak.main()

    def make_old_run(self, *, legacy=False):
        path = self.soak_root / str(uuid.uuid4())
        path.mkdir()
        (path / "logs").mkdir()
        (path / "logs" / "cycle-000001-agent.log").write_text("preserved partial output\n")
        state = {"schemaVersion": 1 if legacy else 2, "runID": path.name,
                 "profile": "2h", "status": "running", "completedCycles": 91,
                 "completedShards": 729, "durationSeconds": 1,
                 "qualificationEligible": True, "inputFingerprint": "old-source"}
        (path / "state.json").write_text(json.dumps(state))
        if not legacy:
            (path / "owner.lock").touch()
        return path

    def test_inventory_failure_records_failed_state_before_measurement(self):
        self.assertEqual(self.invoke(inventory=RuntimeError("inventory unavailable")), 1)
        run = self.runs()[0]
        state = self.state(run)
        self.assertEqual(state["status"], "failed")
        self.assertFalse(state["qualificationEligible"])
        self.assertIsNone(state["measurementStartedAt"])
        self.assertEqual(state["completedShards"], 0)
        self.assertIn("inventory unavailable", state["failureReason"])
        self.assertIsNotNone(state["finishedAt"])
        self.assertIn('"event":"failed"', (run / "events.jsonl").read_text())

    def test_interruption_during_inventory_is_durable_and_never_qualifies(self):
        def stop(*args, **kwargs):
            soak.handle_signal(15, None)
            raise RuntimeError("inventory cancelled")
        self.assertEqual(self.invoke(inventory=stop), 130)
        state = self.state(self.runs()[0])
        self.assertEqual(state["status"], "interrupted")
        self.assertFalse(state["qualificationEligible"])
        self.assertIsNone(state["measurementStartedAt"])

    def test_active_owner_and_duplicate_project_run_are_rejected(self):
        old = self.make_old_run()
        before = (old / "state.json").read_bytes()
        with soak.ownership_lock(old / "owner.lock"):
            with self.assertRaisesRegex(RuntimeError, "active owner"):
                soak.recovery_receipt(str(old), self.soak_root, "2h")
        with soak.ownership_lock(self.soak_root / "active.lock"):
            with self.assertRaisesRegex(RuntimeError, "active owner"):
                self.invoke()
        self.assertEqual((old / "state.json").read_bytes(), before)
        self.assertEqual(self.runs(), [old])

    def test_resuming_stale_run_preserves_logs_and_starts_fresh_evidence(self):
        old = self.make_old_run()
        before = {str(path.relative_to(old)): path.read_bytes()
                  for path in old.rglob("*") if path.is_file()}
        self.options.resume = str(old)
        self.assertEqual(self.invoke(), 0)
        new = next(path for path in self.runs() if path != old)
        state = self.state(new)
        self.assertEqual(state["completedCycles"], 2)
        self.assertEqual(state["completedShards"], 16)
        self.assertEqual(state["continuousElapsedSeconds"], 2)
        self.assertTrue(state["qualificationEligible"])
        self.assertFalse(state["recovery"]["continuousEvidenceReused"])
        self.assertFalse(state["recovery"]["sameInputs"])
        self.assertFalse(state["recovery"]["sameDuration"])
        self.assertEqual(state["recovery"]["previousOwnerObservation"], "no-lock-holder")
        self.assertEqual({str(path.relative_to(old)): path.read_bytes()
                          for path in old.rglob("*") if path.is_file()}, before)
        self.assertTrue((new / "metadata.json").is_file())

    def test_legacy_resume_cannot_assert_owner_or_reuse_elapsed_time(self):
        old = self.make_old_run(legacy=True)
        self.options.resume = str(old)
        self.assertEqual(self.invoke(inventory=RuntimeError("stop before new measurement")), 1)
        new = next(path for path in self.runs() if path != old)
        state = self.state(new)
        self.assertEqual(state["recovery"]["previousOwnerObservation"], "unverifiable-legacy")
        self.assertFalse(state["qualificationEligible"])
        self.assertEqual(state["continuousElapsedSeconds"], 0)
        self.assertFalse((old / "owner.lock").exists())
        self.assertEqual(self.state(old)["completedCycles"], 91)

    def test_current_run_with_missing_owner_lock_is_not_treated_as_legacy(self):
        old = self.make_old_run()
        (old / "owner.lock").unlink()
        with self.assertRaisesRegex(ValueError, "missing its ownership lock"):
            soak.recovery_receipt(str(old), self.soak_root, "2h")
        self.assertEqual(self.state(old)["completedCycles"], 91)

    def test_source_root_symlink_cannot_hide_a_changed_input(self):
        outside = self.root / "outside-sources"
        (self.root / "Sources").rename(outside)
        (self.root / "Sources").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "source directory symlinks"):
            soak.input_receipt(self.root, self.contract, sys.executable)

    def test_source_change_during_shard_fails_without_claiming_completion(self):
        def change_source(command, project, environment, log, **kwargs):
            log.write_text("partial source-change evidence\n")
            (self.root / "Sources" / "Fixture.swift").write_text("// source v2\n")
            self.elapsed += 0.125
            return 0
        self.assertEqual(self.invoke(process=change_source), 1)
        run = self.runs()[0]
        state = self.state(run)
        self.assertEqual(state["status"], "failed")
        self.assertFalse(state["qualificationEligible"])
        self.assertEqual(state["completedShards"], 0)
        self.assertIn("changed during this run", state["failureReason"])
        self.assertEqual(Path(state["currentShard"]["log"]).read_text(), "partial source-change evidence\n")

    def test_partial_shard_exception_is_retained_and_nonqualifying(self):
        def fail(command, project, environment, log, **kwargs):
            log.write_text("partial failure evidence\n")
            self.elapsed += 0.125
            kwargs["heartbeat"]()
            state = self.state(log.parent.parent)
            self.assertEqual(state["status"], "running")
            self.assertFalse(state["qualificationEligible"])
            raise RuntimeError("shard crashed")
        self.assertEqual(self.invoke(process=fail), 1)
        run = self.runs()[0]
        state = self.state(run)
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["continuousElapsedSeconds"], 0.125)
        self.assertEqual(state["attemptedShards"], 1)
        self.assertEqual(state["completedShards"], 0)
        self.assertIsNotNone(state["currentShard"])
        self.assertEqual(Path(state["currentShard"]["log"]).read_text(), "partial failure evidence\n")

    def test_development_duration_never_qualifies(self):
        self.options.development_override = True
        self.options.duration_seconds = 2
        self.assertEqual(self.invoke(), 1)
        state = self.state(self.runs()[0])
        self.assertEqual(state["status"], "completed")
        self.assertFalse(state["qualificationRequested"])
        self.assertFalse(state["qualificationEligible"])

    def test_preparation_time_is_excluded_from_continuous_measurement(self):
        def slow_inventory(*args, **kwargs):
            self.elapsed += 600
            kwargs["heartbeat"]()
        self.assertEqual(self.invoke(inventory=slow_inventory), 0)
        state = self.state(self.runs()[0])
        self.assertEqual(state["continuousElapsedSeconds"], 2)
        self.assertEqual(state["completedCycles"], 2)

    def test_duration_without_minimum_cycles_never_qualifies(self):
        def slow_shard(command, project, environment, log, **kwargs):
            log.write_text("one slow shard passed\n")
            self.elapsed += 2
            return 0
        self.assertEqual(self.invoke(process=slow_shard), 1)
        state = self.state(self.runs()[0])
        self.assertEqual(state["status"], "completed")
        self.assertEqual(state["completedCycles"], 0)
        self.assertFalse(state["qualificationEligible"])

    def test_contract_changed_during_inventory_is_nonqualifying(self):
        def change_contract(*args, **kwargs):
            self.contract["profiles"]["2h"]["durationSeconds"] = 1
            (self.root / "Scripts" / "soak_profiles.json").write_text(json.dumps(self.contract))
        self.assertEqual(self.invoke(inventory=change_contract), 1)
        state = self.state(self.runs()[0])
        self.assertEqual(state["status"], "failed")
        self.assertIsNone(state["measurementStartedAt"])
        self.assertFalse(state["qualificationEligible"])
        self.assertIn("changed during this run", state["failureReason"])

    def test_killed_shard_retains_durable_exit_code(self):
        def killed(command, project, environment, log, **kwargs):
            log.write_text("killed shard output\n")
            self.elapsed += 0.125
            kwargs["heartbeat"]()
            return -signal.SIGKILL
        self.assertEqual(self.invoke(process=killed), 1)
        state = self.state(self.runs()[0])
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["failures"][0]["exitCode"], -signal.SIGKILL)
        self.assertFalse(state["qualificationEligible"])

    def test_clock_rejects_process_suspension_and_system_sleep(self):
        for monotonic, wall in (([0, 61], [0, 61]), ([0, 1], [0, 61])):
            with self.subTest(monotonic=monotonic, wall=wall), \
                    mock.patch.object(soak.time, "monotonic", side_effect=monotonic), \
                    mock.patch.object(soak.time, "time", side_effect=wall):
                clock = soak.ContinuousClock()
                with self.assertRaisesRegex(RuntimeError, "heartbeat was interrupted"):
                    clock.sample()

    def test_clock_rejects_short_sleep_and_clock_adjustments(self):
        for monotonic, wall in (([0, 5], [0, 35]), ([0, 35], [0, 5]),
                                ([0, 5], [0, -1]), ([0, -1], [0, 1])):
            with self.subTest(monotonic=monotonic, wall=wall), \
                    mock.patch.object(soak.time, "monotonic", side_effect=monotonic), \
                    mock.patch.object(soak.time, "time", side_effect=wall):
                clock = soak.ContinuousClock()
                with self.assertRaisesRegex(RuntimeError, "heartbeat was interrupted"):
                    clock.sample()

    def test_clock_accepts_small_wall_clock_jitter_without_inflating_elapsed_time(self):
        with mock.patch.object(soak.time, "monotonic", side_effect=[0, 5, 10]), \
                mock.patch.object(soak.time, "time", side_effect=[100, 106, 110]):
            clock = soak.ContinuousClock()
            self.assertEqual(clock.sample(), 5)
            self.assertEqual(clock.sample(), 10)

    def test_child_inherits_owner_lock_until_it_exits(self):
        lock = self.soak_root / "child.lock"
        child = None
        try:
            with soak.ownership_lock(lock) as descriptor:
                child = subprocess.Popen([sys.executable, "-c", "import sys; print('ready', flush=True); sys.stdin.buffer.read(1)"],
                    pass_fds=(descriptor,), stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                self.assertEqual(child.stdout.readline(), b"ready\n")
            with self.assertRaisesRegex(RuntimeError, "active owner"):
                with soak.ownership_lock(lock):
                    self.fail("child ownership was lost")
            child.communicate(b"x", timeout=5)
            self.assertEqual(child.returncode, 0)
            with soak.ownership_lock(lock):
                pass
        finally:
            if child is not None and child.poll() is None:
                child.kill()
                child.communicate(timeout=5)

    def test_run_process_timeout_reaps_term_ignoring_child_and_keeps_log(self):
        log = self.root / "timeout.log"
        with mock.patch.object(soak, "MAX_SHARD_SECONDS", 0.25), \
                mock.patch.object(soak, "TERMINATION_GRACE_SECONDS", 0.05):
            status = soak.run_process([sys.executable, "-c",
                "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(30)"],
                self.root, dict(os.environ), log)
        self.assertEqual(status, 124)
        pid = int(log.read_text().strip())
        with self.assertRaises(ChildProcessError):
            os.waitpid(pid, os.WNOHANG)
        with self.assertRaises(FileExistsError):
            soak.run_process([sys.executable, "-c", "pass"], self.root, dict(os.environ), log)
        self.assertEqual(int(log.read_text().strip()), pid)

    def test_run_process_heartbeat_failure_reaps_child(self):
        log = self.root / "heartbeat-error.log"
        with mock.patch.object(soak, "HEARTBEAT_SECONDS", 0), \
                mock.patch.object(soak, "TERMINATION_GRACE_SECONDS", 0.05):
            with self.assertRaisesRegex(RuntimeError, "heartbeat persistence failed"):
                soak.run_process([sys.executable, "-c", "import time; time.sleep(30)"],
                    self.root, dict(os.environ), log,
                    heartbeat=mock.Mock(side_effect=RuntimeError("heartbeat persistence failed")))
        with self.assertRaises(ChildProcessError):
            os.waitpid(-1, os.WNOHANG)

    def test_spawn_signal_permission_race_retries_before_reaping(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                 start_new_session=True)
        real_killpg = os.killpg
        calls = []

        def transient_denial(pid, number):
            self.assertIsNone(child.returncode)
            self.assertEqual(pid, child.pid)
            calls.append(number)
            if len(calls) <= 2:
                raise PermissionError("transient spawn signal denial")
            return real_killpg(pid, number)

        try:
            with mock.patch.object(soak.os, "killpg", side_effect=transient_denial), \
                    mock.patch.object(soak.os, "kill", side_effect=PermissionError("transient direct denial")), \
                    mock.patch.object(soak, "TERMINATION_GRACE_SECONDS", 0.01):
                soak.stop_owned_process(child)
                # Calling cleanup twice must never signal a reaped/reused PID.
                soak.stop_owned_process(child)
            self.assertEqual(calls, [signal.SIGTERM, signal.SIGKILL, signal.SIGKILL])
            self.assertEqual(child.returncode, -signal.SIGKILL)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)

    def test_noisy_child_log_is_strictly_bounded_and_child_reaped(self):
        log = self.root / "noisy.log"
        with mock.patch.object(soak, "MAX_LOG_BYTES", 1024), \
                mock.patch.object(soak, "TERMINATION_GRACE_SECONDS", 0.01):
            with self.assertRaisesRegex(RuntimeError, "unbounded shard log"):
                soak.run_process([sys.executable, "-c",
                    "import os, time; os.write(1, b'x' * 100000); time.sleep(30)"],
                    self.root, dict(os.environ), log)
        self.assertEqual(log.read_bytes(), b"x" * 1024)
        with self.assertRaises(ChildProcessError):
            os.waitpid(-1, os.WNOHANG)


if __name__ == "__main__":
    unittest.main()
