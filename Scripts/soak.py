#!/usr/bin/env python3
"""Durable Phase H soak orchestrator.

Each cycle runs real Swift integration-test shards. A duration override or dry
run is explicitly marked non-qualifying, so a developer smoke cannot be
reported as a 2h/8h/24h/multi-day gate.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid


MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_SHARD_SECONDS = 30 * 60
FAILURE_SCENARIO_SELECTOR = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*Tests/test[A-Za-z0-9_]+$"
)
stopping = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=("2h", "8h", "24h", "multi-day"))
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--swift", default="/usr/bin/swift")
    parser.add_argument("--resume")
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--development-override", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def utc_now() -> str:
    return dt.datetime.now(tz=dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def atomic_json(path: Path, value: object) -> None:
    temporary = path.parent / f".soak-{uuid.uuid4()}.tmp"
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_contract(project: Path) -> dict[str, object]:
    path = project / "Scripts" / "soak_profiles.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != 2:
        raise ValueError("unsupported soak profile schema")
    profiles = value.get("profiles")
    shards = value.get("shards")
    failures = value.get("requiredFailureScenarios")
    if not isinstance(profiles, dict) or not isinstance(shards, list) or not isinstance(failures, dict):
        raise ValueError("malformed soak profile contract")
    required_categories = {
        "agent", "pty", "subagent", "automation", "browser",
        "ollama-reconnect", "task-switching", "failure-injection",
    }
    if len(shards) != len(required_categories) or not all(
        isinstance(item, dict) for item in shards
    ):
        raise ValueError("soak shard coverage is incomplete or duplicated")
    categories = [item.get("category") for item in shards]
    if set(categories) != required_categories or len(set(categories)) != len(categories):
        raise ValueError("soak shard coverage is incomplete or duplicated")
    required_failures = {
        "force-quit", "disk-full", "network-down", "ollama-down", "mcp-crash",
        "browser-crash", "pty-crash", "git-lock", "worktree-deleted", "remote-disconnect",
    }
    if set(failures.keys()) != required_failures:
        raise ValueError("failure-injection coverage is incomplete")
    selectors = list(failures.values())
    if len(set(selectors)) != len(selectors) or not all(
        isinstance(selector, str) and FAILURE_SCENARIO_SELECTOR.fullmatch(selector)
        for selector in selectors
    ):
        raise ValueError("failure-injection selectors must be unique exact XCTest selectors")
    for shard in shards:
        category = shard["category"]
        if category == "failure-injection":
            if shard.get("filterSource") != "requiredFailureScenarios" or "filter" in shard:
                raise ValueError("failure-injection shard must resolve the scenario mapping")
        else:
            pattern = shard.get("filter")
            if not isinstance(pattern, str) or not pattern:
                raise ValueError(f"soak category {category} has no test filter")
            try:
                re.compile(pattern)
            except re.error as error:
                raise ValueError(f"soak category {category} has an invalid test filter") from error
    return value


def resolved_shard_filter(
    shard: dict[str, object],
    failures: dict[str, str],
) -> str:
    if shard["category"] != "failure-injection":
        return str(shard["filter"])
    return "(?:" + "|".join(re.escape(selector) for selector in failures.values()) + ")"


def project_environment(project: Path, run_root: Path) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "TMPDIR": str(run_root / "system-tmp"),
        "TMP": str(run_root / "system-tmp"),
        "TEMP": str(run_root / "system-tmp"),
        "XDG_CACHE_HOME": str(run_root / "xdg-cache"),
        "XDG_CONFIG_HOME": str(run_root / "xdg-config"),
        "CLANG_MODULE_CACHE_PATH": str(run_root / "clang-module-cache"),
        "SWIFT_MODULECACHE_PATH": str(run_root / "swift-module-cache"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(run_root / "swift-module-cache"),
        "LUMACHAT_APP_SUPPORT_PATH": str(run_root / "app-support"),
        "LUMACHAT_RUNTIME_TMP_PATH": str(project / "tmp"),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    for path in environment.values():
        if path.startswith(str(project / "tmp")):
            Path(path).mkdir(parents=True, exist_ok=True)
    return environment


def swift_arguments(run_root: Path, *tail: str) -> list[str]:
    return [
        *tail,
        "--scratch-path", str(run_root / "scratch"),
        "--cache-path", str(run_root / "cache"),
        "--config-path", str(run_root / "config"),
        "--security-path", str(run_root / "security"),
        "--disable-sandbox",
        "--disable-automatic-resolution",
    ]


def run_process(command: list[str], cwd: Path, environment: dict[str, str], log: Path) -> int:
    with log.open("wb") as output:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        started = time.monotonic()
        while process.poll() is None:
            if stopping or time.monotonic() - started > MAX_SHARD_SECONDS:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                return 124 if not stopping else 130
            time.sleep(0.25)
        status = process.returncode
    if log.stat().st_size > MAX_LOG_BYTES:
        raise RuntimeError(f"unbounded shard log: {log}")
    return status


def assert_filters_exist(
    swift: str,
    project: Path,
    run_root: Path,
    environment: dict[str, str],
    shards: list[dict[str, object]],
    failures: dict[str, str],
) -> None:
    inventory_log = run_root / "test-inventory.log"
    status = run_process(
        [swift, *swift_arguments(run_root, "test", "list")],
        project,
        environment,
        inventory_log,
    )
    if status != 0:
        raise RuntimeError("Swift test inventory failed")
    inventory = inventory_log.read_text(encoding="utf-8", errors="replace")
    inventory_lines = [line.strip() for line in inventory.splitlines() if line.strip()]
    for scenario, selector in failures.items():
        matches = [
            line for line in inventory_lines
            if line == selector or line.endswith("." + selector)
        ]
        if len(matches) != 1:
            raise RuntimeError(
                f"failure scenario {scenario} selector matched {len(matches)} tests"
            )
    for shard in shards:
        pattern = resolved_shard_filter(shard, failures)
        if re.search(pattern, inventory) is None:
            raise RuntimeError(f"no tests match soak category {shard['category']}")


def handle_signal(_number: int, _frame: object) -> None:
    global stopping
    stopping = True


def main() -> int:
    options = parse_args()
    project = Path(options.project_root).resolve(strict=True)
    if not (project / "Package.swift").is_file() or project.name in {"", "/"}:
        raise ValueError("project root is invalid")
    contract = load_contract(project)
    profile = contract["profiles"][options.profile]
    official_duration = int(profile["durationSeconds"])
    if options.duration_seconds is not None and not options.development_override:
        raise ValueError("duration override requires --development-override")
    duration = (
        options.duration_seconds
        if options.duration_seconds is not None
        else official_duration
    )
    if duration <= 0:
        raise ValueError("duration must be positive")
    qualifying = (
        duration >= official_duration
        and options.duration_seconds is None
        and not options.development_override
        and not options.dry_run
    )

    soak_root = project / "tmp" / "soak"
    soak_root.mkdir(parents=True, exist_ok=True)
    if options.resume:
        run_root = Path(options.resume).resolve(strict=True)
        if run_root.parent != soak_root or run_root.is_symlink():
            raise ValueError("resume path is not an exact project soak run")
        state_path = run_root / "state.json"
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state.get("profile") != options.profile or state.get("status") not in {"running", "interrupted"}:
            raise ValueError("resume state does not match this profile")
    else:
        run_id = str(uuid.uuid4())
        run_root = soak_root / run_id
        run_root.mkdir(parents=False, exist_ok=False)
        state_path = run_root / "state.json"
        state = {
            "completedCycles": 0,
            "completedShards": 0,
            "durationSeconds": duration,
            "failures": [],
            "finishedAt": None,
            "profile": options.profile,
            "qualificationEligible": qualifying,
            "runID": run_id,
            "schemaVersion": 1,
            "startedAt": utc_now(),
            "status": "running",
        }
        atomic_json(state_path, state)

    for child in ("logs", "system-tmp", "xdg-cache", "xdg-config", "clang-module-cache", "swift-module-cache", "app-support"):
        (run_root / child).mkdir(parents=True, exist_ok=True)
    environment = project_environment(project, run_root)
    shards = contract["shards"]
    failures = contract["requiredFailureScenarios"]
    assert_filters_exist(
        options.swift,
        project,
        run_root,
        environment,
        shards,
        failures,
    )
    if options.dry_run:
        state["status"] = "dry-run"
        state["finishedAt"] = utc_now()
        state["qualificationEligible"] = False
        atomic_json(state_path, state)
        print(run_root)
        return 0

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline and not stopping:
        cycle = int(state["completedCycles"]) + 1
        for shard in shards:
            if stopping or time.monotonic() >= deadline:
                break
            category = shard["category"]
            shard_filter = resolved_shard_filter(shard, failures)
            log = run_root / "logs" / f"cycle-{cycle:06d}-{category}.log"
            status = run_process(
                [
                    options.swift,
                    *swift_arguments(
                        run_root,
                        "test",
                        "--jobs", "2",
                        "--filter", shard_filter,
                    ),
                ],
                project,
                environment,
                log,
            )
            state["completedShards"] = int(state["completedShards"]) + 1
            state["lastCategory"] = category
            state["lastUpdatedAt"] = utc_now()
            if status != 0:
                state["failures"].append({"category": category, "exitCode": status, "log": str(log)})
                state["status"] = "failed"
                state["finishedAt"] = utc_now()
                state["qualificationEligible"] = False
                atomic_json(state_path, state)
                return 1
            atomic_json(state_path, state)
        else:
            state["completedCycles"] = cycle
            atomic_json(state_path, state)

    state["finishedAt"] = utc_now()
    state["status"] = "interrupted" if stopping else "completed"
    state["qualificationEligible"] = bool(
        qualifying
        and not stopping
        and not state["failures"]
        and int(state["completedCycles"]) >= int(profile["minimumCompletedCycles"])
    )
    atomic_json(state_path, state)
    print(run_root)
    return 130 if stopping else (0 if state["qualificationEligible"] else 1)


if __name__ == "__main__":
    sys.exit(main())
