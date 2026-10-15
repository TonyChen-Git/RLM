#!/usr/bin/env python3
"""Durable Phase H soak orchestrator.

Each cycle runs real Swift integration-test shards. A duration override or dry
run is explicitly marked non-qualifying, so a developer smoke cannot be
reported as a 2h/8h/24h/multi-day gate.
"""

from __future__ import annotations

import argparse
import datetime as dt
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid


MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_SHARD_SECONDS = 30 * 60
HEARTBEAT_SECONDS = 5
MAX_HEARTBEAT_GAP_SECONDS = 60
MAX_WALL_CLOCK_DRIFT_SECONDS = 5
TERMINATION_GRACE_SECONDS = 2
REAP_TIMEOUT_SECONDS = 5
FAILURE_SCENARIO_SELECTOR = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*Tests/test[A-Za-z0-9_]+$"
)
stopping = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=("2h", "8h", "24h", "multi-day"))
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--swift", default="/usr/bin/swift")
    parser.add_argument("--resume", help="Start a fresh continuous run referencing interrupted evidence; never reuse elapsed time or logs")
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


def stop_owned_process(process: subprocess.Popen) -> None:
    """Terminate only our unreaped child group; never trust a persisted PID.

    Keep the direct child unreaped through escalation so its PID/process-group
    number cannot be reused between TERM and KILL. Children inherit the flock
    descriptors so an abruptly killed orchestrator cannot release ownership
    while its immediate Swift process is still running.
    """
    if process.returncode is not None:
        return
    def send(number: int) -> None:
        try:
            os.killpg(process.pid, number)
        except (ProcessLookupError, PermissionError):
            # A freshly spawned child may not yet have established its session.
            # macOS also returns EPERM for a group containing only zombies.
            # Its unreaped PID is still ours, so direct signalling is safe.
            try:
                os.kill(process.pid, number)
            except ProcessLookupError:
                pass

    try:
        send(signal.SIGTERM)
    except PermissionError:
        # macOS can temporarily deny signals during the spawn/exec transition.
        # Continue to bounded escalation rather than leaking the owned child.
        pass
    time.sleep(TERMINATION_GRACE_SECONDS)
    deadline = time.monotonic() + REAP_TIMEOUT_SECONDS
    while True:
        try:
            send(signal.SIGKILL)
            break
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)
    process.wait(timeout=max(0.05, deadline - time.monotonic()))


def run_process(
    command: list[str], cwd: Path, environment: dict[str, str], log: Path,
    *, heartbeat=None, lock_descriptors: tuple[int, ...] = (),
) -> int:
    # Exclusive creation preserves a partial log even after an exception.
    with log.open("xb") as output, selectors.DefaultSelector() as selector:
        process = subprocess.Popen(
            command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
            pass_fds=lock_descriptors,
        )
        started = last_heartbeat = time.monotonic()
        written = 0
        try:
            assert process.stdout is not None
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                now = time.monotonic()
                if stopping or now - started > MAX_SHARD_SECONDS:
                    stop_owned_process(process)
                    return 130 if stopping else 124
                if heartbeat is not None and now - last_heartbeat >= HEARTBEAT_SECONDS:
                    heartbeat()
                    last_heartbeat = now
                for key, _events in selector.select(timeout=0.25):
                    chunk = os.read(key.fd, 64 * 1024)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    retained = chunk[:max(0, MAX_LOG_BYTES - written)]
                    output.write(retained)
                    output.flush()
                    written += len(retained)
                    if len(retained) != len(chunk):
                        raise RuntimeError(f"unbounded shard log: {log}")
                # Do not reap the child while descendants still own its output
                # pipe; retain its PID through any necessary group escalation.
                if not selector.get_map() and process.poll() is not None:
                    if heartbeat is not None:
                        heartbeat()
                    return process.returncode
        except BaseException:
            stop_owned_process(process)
            raise
        finally:
            if process.stdout is not None:
                process.stdout.close()
            output.flush()
            os.fsync(output.fileno())


def assert_filters_exist(
    swift: str,
    project: Path,
    run_root: Path,
    environment: dict[str, str],
    shards: list[dict[str, object]],
    failures: dict[str, str],
    *, heartbeat=None, lock_descriptors: tuple[int, ...] = (),
) -> None:
    inventory_log = run_root / "test-inventory.log"
    status = run_process(
        [swift, *swift_arguments(run_root, "test", "list")],
        project,
        environment,
        inventory_log,
        heartbeat=heartbeat, lock_descriptors=lock_descriptors,
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


@contextlib.contextmanager
def ownership_lock(path: Path, *, create: bool = True):
    flags = os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT if create else 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("soak ownership lock is not a private regular file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("soak run still has an active owner or child process") from error
        yield descriptor
    finally:
        # Do not explicitly unlock: inherited descriptors must continue to hold
        # the lock if a child survives an uncatchable orchestrator termination.
        os.close(descriptor)


def input_receipt(project: Path, contract: dict[str, object], swift: str) -> dict[str, object]:
    files = {}
    paths = [project / "Package.swift", project / "Package.resolved"]
    for directory in ("Sources", "Tests", "Scripts", "AppBundle", ".github"):
        root = project / directory
        if root.is_symlink():
            raise ValueError("source directory symlinks cannot qualify a soak")
        if not root.exists():
            continue
        for parent, directories, names in os.walk(root, followlinks=False):
            directories[:] = sorted(name for name in directories if name != "__pycache__")
            for name in directories:
                if (Path(parent) / name).is_symlink():
                    raise ValueError("source directory symlinks cannot qualify a soak")
            paths.extend(Path(parent) / name for name in names
                         if not name.startswith("._") and name != ".DS_Store"
                         and not name.endswith((".pyc", ".pyo")))
    for path in sorted(paths):
        if path.is_symlink():
            raise ValueError("source file symlinks cannot qualify a soak")
        if path.is_file():
            files[str(path.relative_to(project))] = hashlib.sha256(path.read_bytes()).hexdigest()
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    executable = Path(swift).resolve(strict=True)
    return {
        "sourceFingerprint": hashlib.sha256(encoded).hexdigest(),
        "sourceFiles": files,
        "contractFingerprint": hashlib.sha256(json.dumps(
            contract, sort_keys=True, separators=(",", ":")
        ).encode()).hexdigest(),
        "swiftPath": str(executable),
        "swiftFingerprint": hashlib.sha256(executable.read_bytes()).hexdigest(),
    }


def recovery_receipt(path: str, soak_root: Path, profile: str) -> dict[str, object]:
    candidate = Path(path).absolute()
    if candidate.is_symlink():
        raise ValueError("resume path is not an exact project soak run")
    previous = candidate.resolve(strict=True)
    if previous.parent != soak_root.resolve(strict=True) or not previous.is_dir():
        raise ValueError("resume path is not an exact project soak run")
    # Old schema-1 runs had no ownership lock. Their owner cannot be verified;
    # preserve them verbatim and make no inactivity or continuity claim.
    lock = previous / "owner.lock"
    owner = "unverifiable-legacy"
    with contextlib.ExitStack() as stack:
        if lock.exists() or lock.is_symlink():
            stack.enter_context(ownership_lock(lock, create=False))
            owner = "no-lock-holder"
        raw = (previous / "state.json").read_bytes()
        state = json.loads(raw)
        if state.get("schemaVersion") != 1 and owner == "unverifiable-legacy":
            raise ValueError("resume state is missing its ownership lock")
        if state.get("profile") != profile or state.get("status") not in {
            "preparing", "running", "interrupted", "failed",
        }:
            raise ValueError("resume state does not match an unfinished profile")
        return {
            "previousRun": str(previous),
            "previousRunID": state.get("runID"),
            "previousStateSHA256": hashlib.sha256(raw).hexdigest(),
            "previousStatus": state.get("status"),
            "previousOwnerObservation": owner,
            "previousInputFingerprint": state.get("inputFingerprint"),
            "previousDurationSeconds": state.get("durationSeconds"),
            "continuousEvidenceReused": False,
        }


class ContinuousClock:
    def __init__(self) -> None:
        self.started = self.last_monotonic = time.monotonic()
        self.last_wall = time.time()

    def sample(self) -> float:
        now, wall = time.monotonic(), time.time()
        monotonic_gap, wall_gap = now - self.last_monotonic, wall - self.last_wall
        # Some monotonic clocks pause during system sleep. Comparing the two
        # deltas also rejects shorter sleeps or wall-clock adjustments that
        # stay below the maximum heartbeat gap.
        if (monotonic_gap < 0
                or abs(wall_gap - monotonic_gap) > MAX_WALL_CLOCK_DRIFT_SECONDS
                or max(monotonic_gap, wall_gap) > MAX_HEARTBEAT_GAP_SECONDS):
            raise RuntimeError("continuous soak heartbeat was interrupted or the system clock changed")
        self.last_monotonic, self.last_wall = now, wall
        return now - self.started


def append_event(run_root: Path, event: str, **values) -> None:
    data = (json.dumps({"at": utc_now(), "event": event, **values},
                       sort_keys=True, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(run_root / "events.jsonl", os.O_WRONLY | os.O_APPEND
                         | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "ab") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        raise


def main() -> int:
    global stopping
    stopping = False
    options = parse_args()
    project = Path(options.project_root).resolve(strict=True)
    if not (project / "Package.swift").is_file() or project.name in {"", "/"}:
        raise ValueError("project root is invalid")
    contract = load_contract(project)
    profile = contract["profiles"][options.profile]
    official_duration = int(profile["durationSeconds"])
    if options.duration_seconds is not None and not options.development_override:
        raise ValueError("duration override requires --development-override")
    duration = options.duration_seconds if options.duration_seconds is not None else official_duration
    if duration <= 0:
        raise ValueError("duration must be positive")
    qualifying = (duration >= official_duration and options.duration_seconds is None
                  and not options.development_override and not options.dry_run)
    soak_root = project / "tmp" / "soak"
    soak_root.mkdir(parents=True, exist_ok=True)
    with contextlib.ExitStack() as stack:
        # One harness per project avoids overlapping mutation fixtures. The OS
        # lock, not a PID-exists probe, is the authority for current runs.
        project_lock = stack.enter_context(ownership_lock(soak_root / "active.lock"))
        recovery = recovery_receipt(options.resume, soak_root, options.profile) if options.resume else None
        run_id = str(uuid.uuid4())
        run_root = soak_root / run_id
        run_root.mkdir(mode=0o700)
        run_lock = stack.enter_context(ownership_lock(run_root / "owner.lock"))
        lock_descriptors = (project_lock, run_lock)
        state_path = run_root / "state.json"
        state = {
            "attemptedShards": 0, "completedCycles": 0, "completedShards": 0,
            "continuousElapsedSeconds": 0, "durationSeconds": duration,
            "failures": [], "finishedAt": None, "profile": options.profile,
            "qualificationRequested": qualifying, "qualificationEligible": False,
            "runID": run_id, "schemaVersion": 2, "startedAt": utc_now(),
            "status": "preparing", "measurementStartedAt": None,
            "owner": {"pid": os.getpid(), "token": str(uuid.uuid4()), "lock": "owner.lock"},
            "recovery": recovery,
        }
        clock = None
        receipt = None

        def persist() -> None:
            if clock is not None:
                state["continuousElapsedSeconds"] = round(clock.sample(), 3)
            state["lastUpdatedAt"] = utc_now()
            atomic_json(state_path, state)

        def check_inputs() -> None:
            if input_receipt(project, load_contract(project), options.swift) != receipt:
                raise RuntimeError("soak source, contract, or Swift executable changed during this run")

        previous_signals = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        for number in previous_signals:
            signal.signal(number, handle_signal)
        try:
            persist()
            print(run_root, flush=True)
            append_event(run_root, "created", recovery=recovery)
            receipt = input_receipt(project, contract, options.swift)
            state["inputFingerprint"] = hashlib.sha256(json.dumps(
                receipt, sort_keys=True, separators=(",", ":")
            ).encode()).hexdigest()
            if recovery is not None:
                recovery["sameInputs"] = recovery["previousInputFingerprint"] == state["inputFingerprint"]
                recovery["sameDuration"] = recovery["previousDurationSeconds"] == duration
            metadata = {
                "schemaVersion": 2, "runID": run_id, "profile": options.profile,
                "officialDurationSeconds": official_duration, "durationSeconds": duration,
                "minimumCompletedCycles": int(profile["minimumCompletedCycles"]),
                "developmentOverride": options.development_override, "dryRun": options.dry_run,
                "qualificationRequested": qualifying, "recovery": recovery,
                "inputFingerprint": state["inputFingerprint"], "inputs": receipt,
            }
            atomic_json(run_root / "metadata.json", metadata)
            for child in ("logs", "system-tmp", "xdg-cache", "xdg-config",
                          "clang-module-cache", "swift-module-cache", "app-support"):
                (run_root / child).mkdir()
            environment = project_environment(project, run_root)
            persist()
            assert_filters_exist(options.swift, project, run_root, environment,
                                 contract["shards"], contract["requiredFailureScenarios"],
                                 heartbeat=persist, lock_descriptors=lock_descriptors)
            if stopping:
                raise InterruptedError("soak interrupted during preparation")
            check_inputs()
            if options.dry_run:
                state["status"] = "dry-run"
            else:
                clock = ContinuousClock()
                state["status"] = "running"
                state["measurementStartedAt"] = utc_now()
                append_event(run_root, "measurement-started")
                persist()
                while state["continuousElapsedSeconds"] < duration and not stopping:
                    cycle = int(state["completedCycles"]) + 1
                    for shard in contract["shards"]:
                        persist()
                        if stopping or state["continuousElapsedSeconds"] >= duration:
                            break
                        check_inputs()
                        category = shard["category"]
                        log = run_root / "logs" / f"cycle-{cycle:06d}-{category}.log"
                        state["currentShard"] = {"cycle": cycle, "category": category,
                                                 "log": str(log), "startedAt": utc_now()}
                        state["attemptedShards"] += 1
                        append_event(run_root, "shard-started", **state["currentShard"])
                        persist()
                        status = run_process(
                            [options.swift, *swift_arguments(run_root, "test", "--jobs", "2",
                                "--filter", resolved_shard_filter(shard, contract["requiredFailureScenarios"]))],
                            project, environment, log, heartbeat=persist,
                            lock_descriptors=lock_descriptors,
                        )
                        check_inputs()
                        if status != 0:
                            state["failures"].append({"category": category, "exitCode": status, "log": str(log)})
                            raise InterruptedError("soak interrupted") if stopping else RuntimeError(f"soak shard {category} failed with exit {status}")
                        state["completedShards"] += 1
                        state["lastCategory"] = category
                        append_event(run_root, "shard-completed", **state["currentShard"])
                        state["currentShard"] = None
                        persist()
                    else:
                        state["completedCycles"] = cycle
                        append_event(run_root, "cycle-completed", cycle=cycle)
                        persist()
                if stopping:
                    raise InterruptedError("soak interrupted")
                check_inputs()
                persist()
                state["status"] = "completed"
                state["qualificationEligible"] = bool(
                    qualifying and not state["failures"]
                    and state["continuousElapsedSeconds"] >= duration
                    and int(state["completedCycles"]) >= int(profile["minimumCompletedCycles"])
                )
            state["finishedAt"] = utc_now()
            persist()
            append_event(run_root, state["status"], qualified=state["qualificationEligible"])
            return 0 if options.dry_run or state["qualificationEligible"] else 1
        except BaseException as error:
            state["status"] = "interrupted" if stopping or isinstance(error, (InterruptedError, KeyboardInterrupt)) else "failed"
            state["qualificationEligible"] = False
            state["finishedAt"] = state["lastUpdatedAt"] = utc_now()
            state["failureReason"] = f"{type(error).__name__}: {error}"
            # Do not resample a failed clock; persist the last measured progress.
            try:
                atomic_json(state_path, state)
                append_event(run_root, state["status"], reason=state["failureReason"])
            except OSError as persistence_error:
                print(f"unable to persist soak termination: {persistence_error}", file=sys.stderr)
            print(state["failureReason"], file=sys.stderr)
            return 130 if state["status"] == "interrupted" else 1
        finally:
            for number, handler in previous_signals.items():
                signal.signal(number, handler)


if __name__ == "__main__":
    sys.exit(main())
