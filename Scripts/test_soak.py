#!/usr/bin/env python3
"""Unit tests for the durable Phase H soak contract."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import re
import shutil
import unittest
import uuid
from unittest import mock

import soak


class SoakContractTests(unittest.TestCase):
    def setUp(self) -> None:
        project = Path(__file__).resolve().parent.parent
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


if __name__ == "__main__":
    unittest.main()
