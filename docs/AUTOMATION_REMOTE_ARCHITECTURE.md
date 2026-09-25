# Automation, Notification, and SSH Remote Runner Architecture

Last development audit: 2026-09-25, after the 744-test combined Phase A-H
LumaChat 1.4.1 validation/release gate

## Scope and status

Phase F adds three connected but separate capabilities:

1. a durable Automation scheduler that creates ordinary persisted Agent or
   Review Tasks;
2. bounded macOS notifications whose clicks route back to the owning Task; and
3. a user-controlled SSH Remote Runner for Task-scoped filesystem, Git, shell,
   one-shot PTY, build, and test operations.

The implementation and focused tests pass in the complete development
regression/build/package gate. This is development evidence, not a live-host or
production claim: a real authorized SSH host, native UI acceptance and
long-duration soak remain external gates.

Remote model routing and remote tool execution remain different concerns. A
Task may use any configured model endpoint while its tools run on a selected
SSH host. Luma Chat never presents that host as a hosted Luma Chat cloud.

## Automation ownership chain

```text
Automation Settings
        |
        v
AgentViewModel
        |
        v
AutomationService -> AutomationScheduler -> AutomationStore
        |                    |                    |
        |                    |                    +-- versioned atomic JSON
        |                    +-- durable occurrence claim + run transition
        +-- creates a normal persisted Agent/Review Task
                                  |
                                  v
                         existing Agent Runtime
                                  |
                                  v
                    result / changes / retained worktree
```

`AutomationScheduler` is an actor and is the sole owner of schedule evaluation,
occurrence claims, queued/running/terminal state, concurrency, and history
pruning. A run and its occurrence claim are saved together before the executor
can observe the run. That atomic boundary is what prevents the same scheduled
or event occurrence from being created twice across ticks or relaunch.

The default scheduler polls every 30 seconds and allows two runs concurrently,
while preventing two runs of the same Automation from executing together. Both
limits are bounded constructor inputs rather than model-controlled values.

### Schedules and restart behavior

The persisted schedule model supports:

- one-time execution;
- anchored intervals;
- five-field cron expressions with a named time zone, `*`, lists, ranges, and
  steps;
- typed event triggers with exact key/value payload filters; and
- explicit missed-run policies: skip, run the newest once, or catch up to a
  bounded maximum.

Each occurrence has a stable host-computed key. Manual runs can also provide an
idempotency key; keyless manual runs intentionally create distinct occurrences.
At startup, a persisted `running` run becomes `interrupted`. Luma Chat does not
invent a result or silently replay it. Persisted queued work remains queued,
and the selected missed-run policy decides what happens to elapsed scheduled
occurrences.

The schema is versioned. The current store writes version 2 and accepts the
version-1 and early unversioned shapes before upgrading on a successful save.
The non-secret snapshot is stored at:

```text
Application Support/LumaChat/AgentAutomations/automations.json
```

Per-run artifact directories are created below the project-owned temporary
root (`tmp/automation-runs`). Definitions, run records, logs, results, change
summaries, occurrence claims, and retained-worktree metadata are bounded.

### Action types and Task integration

The host supports typed Automation actions for:

- Agent Task;
- Goal;
- Skill;
- project job;
- tests;
- repository check; and
- Review Changes.

Every execution creates a durable Task and runs it through the normal provider,
tool registry, permission, workspace, Skill, Review, and persistence paths.
Review is a real `ReviewWorkflowRequest(.changes)` bound to a source Task, not a
prompt-only imitation. Test and repository-check requests preserve a typed
executable/argv/working-directory definition; the Agent receives a bounded
display form and must use its normal approved tools to execute it.

The run record retains run ID, scheduled/start/end timestamps, status, bounded
logs, result metadata, changes, and worktree information. Opening a completed
run selects its real Task, where the existing Diff, Review, Commit, and PR
surfaces remain available. The Automation pane also offers explicit Task and
dedicated-worktree discard actions. Deleting an Automation definition retains
its completed run history and artifacts.

### Recurring mutation isolation

Recurring or event-driven mutation-capable actions are rejected unless they use
a dedicated managed worktree. This applies to Agent, Goal, Skill, project-job,
test, and repository-check actions; a user-authored check command cannot be
proven read-only merely from its label. Review Changes borrows its exact source
checkout read-only and is rejected if configured as a dedicated mutation run.

A dedicated Automation worktree is an ordinary Task-owned managed worktree.
Completion retains it for inspection. Discard first removes the exact Task and
its lease through existing worktree lifecycle code, then transactionally marks
the historical run as no longer retained. No recurring mutation is intentionally
routed into the project's main checkout.

### Event boundary

`emitAutomationEvent` is a typed, bounded ingress for future GitHub, Slack,
Gmail, filesystem, and webhook producers. Producer event ID plus Automation ID
is the durable deduplication identity. Payload fields participate only in exact
host-side matching; payload text is not executed or appended as an instruction.

Phase F does **not** include authenticated GitHub/Slack/Gmail adapters, a
filesystem watcher, or a webhook listener. Those producer seams are reserved,
not disguised as connected services.

## Notifications

The notification service has six typed kinds:

- Task completed;
- Approval required;
- Automation completed;
- Automation failed;
- Subagent blocked; and
- Remote Agent waiting.

Only an explicit Settings action asks macOS for notification authorization.
Posting never opens the permission prompt implicitly, and delivery failure does
not change the durable Task or Automation result. Titles, bodies, metadata,
identifiers, actions, and deep links are validated and bounded before the
platform backend is called. A short in-process deduplication window suppresses
duplicate presentation without becoming execution state.

Notification metadata uses a versioned namespace and permits only the approved
`lumachat` deep-link scheme. A click is decoded into a typed route; the
`AgentViewModel` then reveals an archived project/Task if necessary, selects the
owning Task, restores its mode, and runs the normal lifecycle transition. The
notification service does not interpret an arbitrary URL as navigation or
execution authority.

The deduplication cache and click handler are process-local presentation state;
there is no durable notification outbox or guaranteed redelivery after a crash.

## SSH Remote Runner

### Configuration and credentials

Remote Runner Settings manages up to 64 enabled or disabled SSH runners and an
explicit Test Connection action. The non-secret, versioned configuration is
stored atomically at:

```text
Application Support/LumaChat/RemoteRunners/runners.json
```

Each runner contains an opaque UUID, display name, host, port, username,
absolute remote workspace root, an explicitly selected local `known_hosts`
file, authentication mode, timeouts, and output limit. Private keys are stored
only in the dedicated Keychain service. For a connection, a key may be
materialized as a mode-0600 file below project `tmp` and is removed by exact
pathname after launch. System ssh-agent authentication is also supported, but
agent forwarding to the remote host is disabled.

When a run identity is created, Luma Chat captures the validated runner record,
credential and exact bounded `known_hosts` bytes as one authority snapshot. Its
fingerprint uses domain-separated fixed-size digests, and every backend created
for that run retains those bytes instead of re-reading mutable files. Changing
the runner, Keychain key, or trust file invalidates resume/recovery matching.

The fixed `/usr/bin/ssh` invocation and fixed `/usr/bin/python3` remote helper
path disable user configuration, password and
interactive authentication, forwarding, local commands, and permissive host-key
fallbacks. Strict host-key checking uses only the configured `known_hosts`
snapshot. Executable, argv, environment, cwd, stdin, timeout, and output are
validated and bounded; values are individually framed as POSIX single-quoted
tokens before OpenSSH passes the command to the login shell.

All operations for a verified canonical workspace are serialized by the same
remote directory lease. The fixed wrapper resolves cwd through descriptor-
relative, no-follow directory opens after taking that lease, starts the child
in a private process group, forwards termination signals, and does not release
the lease while ordinary descendants remain. This is process-local cooperation
between Luma Chat operations, not a filesystem lock imposed on unrelated host
processes.

Every run verifies a fixed post-authentication probe and produces a
`RemoteHostReceipt` containing the configured host/user/root plus the
server-reported hostname, effective user/UID, and canonical workspace root.
Every remote operation then carries a `RemoteOperationReceipt` with runner,
host receipt, operation, requested/canonical path, times, exit code, timeout,
truncation, and location data.

### Task binding and approval

`AgentExecutionLocation` distinguishes `.local`, `.worktree`, `.ssh`, and
`.futureCloud`. An SSH Task persists only the selected runner UUID and a safe
label; credentials and arbitrary host/path inputs never enter Task JSON or
model arguments. Before each run, the ViewModel resolves the enabled runner,
checks the exact workspace-root binding, verifies the host receipt, and injects
the resulting identity into every tool context.

Local-only filesystem/Git/terminal tools, Browser, Computer Use, subagent
launch, and executable plugin processes are hidden or rejected for SSH Tasks.
This prevents a nominally remote Task from silently performing those operations
on the Mac. Initial/final Git inspection and automatic test selection use the
remote tools for an SSH Task.

Dangerous remote operations still use the local Luma Chat approval pipeline.
The approval card displays the backend, host and port, user, remote workspace
root, command, and working directory. Approval remains a local user decision;
the remote host cannot grant itself permission.

### Closed tool surface

Phase F registers these 16 Task-bound tools:

| Area | Tools |
| --- | --- |
| Filesystem | `remote_file_info`, `remote_list_directory`, `remote_read_file`, `remote_write_file`, `remote_create_directory`, `remote_remove`, `remote_move` |
| Git | `remote_git_status`, `remote_git_diff`, `remote_git_log`, `remote_git_add`, `remote_git_commit` |
| Validation | `remote_build`, `remote_test` |
| Shell / PTY | `remote_run_shell`, `remote_pty_run` |

Filesystem operations are rooted below the host-verified canonical workspace,
reject traversal, `.git` administrative paths, unsafe parent/symlink chains and
AppleDouble mutation, and use fixed host-owned Python operations. V1 remove handles one regular file or one
empty directory; it intentionally has no recursive-delete contract. Individual
file transfers are capped at 4 MiB. Git is a fixed argv surface limited to
status, diff, log, add, and commit, and refuses a repository discovered above
the configured workspace root. Build/test supports Swift Package Manager or
an explicit Xcode scheme. Arbitrary shell text is a separately dangerous,
bounded stdin script rather than an argument interpolated into host code.

`remote_pty_run` asks SSH for a PTY for one bounded command. It is not a
persistent Task Terminal: it cannot reconnect, stream later input, resize, or
restore scrollback. The native Terminal pane is disabled for SSH Tasks, and the
remote PTY backend fails explicitly instead of opening a local shell.

## Explicit workspace migration

The migration wire format represents the exact Git HEAD, symbolic branch,
binary full-index working/staged patches, all bounded non-ignored untracked
regular files, and explicit Task-owned supplemental paths. It never transfers
`.git` internals, credentials, symlinks, special files, arbitrary ignored
caches, or AppleDouble `._*` entries.

Each snapshot JSON is capped at 4 MiB; an apply/rollback transaction carrying
both desired and baseline snapshots is capped at 8 MiB. Snapshots have a 3 MiB
aggregate content budget, 2,048-node limit, and bounded path manifest.
Local/Worktree to SSH first
captures local state, verifies that the remote destination is clean and at the
same HEAD, applies it, then captures and compares the resulting fingerprint.
The host-owned apply and rollback carry the same journal transaction UUID.
Rollback recognizes only the exact clean, indexed, or fully applied transaction
states, is idempotent when already clean, and refuses unrelated state. SSH to
Local captures the same bounded representation and must pass the existing local
baseline/CAS policy before replacing local state.

Task handoff is an explicit host operation, never a model tool and never a
claim that two directories are naturally synchronized. A completed handoff
changes the persisted execution-location binding only after state verification;
failure retains or rolls back the source/destination according to the durable
handoff transaction. Mac to SSH, managed Worktree to SSH, and SSH back to the
Task's original Local checkout are the supported routes; SSH-to-SSH and an
arbitrary alternate Local destination are not V1 routes.

### Durable handoff transaction and recovery

Remote migration extends the existing handoff journal with explicit
`handoffToRemote` and `handoffFromRemote` transition kinds. The persisted
state machine is:

| Stage | Durable evidence | Safe recovery behavior |
| --- | --- | --- |
| `prepared` | Source binding, exact snapshot fingerprint, rollback capability | Keep the source binding; remove unused recovery material only when no destination was touched |
| `destinationAllocated` | Adds the exact SSH or original-Local destination binding | If the Task still points to the source, roll back only when the destination still matches the expected applied state |
| `destinationReady` | Destination state has been applied and verified | Commit the Task binding, or restore the pre-handoff side by compare-and-swap; never overwrite a third state |
| `sessionCommitted` | Session JSON points to the verified destination | Validate the destination binding, finish exact source-worktree cleanup when applicable, then remove journal/recovery files |

Remote journal entries also pin the exact pre-apply remote baseline and runner
authority identity. Startup compares the durable Session against both journaled bindings. Missing,
duplicate, contradictory, or fingerprint-divergent evidence is preserved for
repair and the affected Task is kept from another location mutation; recovery
does not guess. Every runner referenced by unresolved evidence is also blocked
from execution, verification, editing, disabling, or deletion. A committed
Local/Worktree-to-SSH handoff may reclaim only the
exact UUID/lease-owned source Worktree after re-capturing it unchanged. An
SSH-to-Local handoff leaves the remote checkout unchanged after commit.

## Future cloud / remote-control seam

`.futureCloud` is a versioned execution-location seam only. There is no
WebSocket relay, mobile approval client, Luma Chat hosted runner, or cloud
fallback in Phase F. Selecting that location fails closed and is labelled as
unavailable. A future authenticated relay must reuse the typed Task/status/
approval commands and truthful backend labels; the existing enum is not proof
that such a service exists.

## Static requirement matrix

| Requirement | Development-tree state | Evidence / remaining gate |
| --- | --- | --- |
| Service, scheduler, store | DEVELOPMENT-GATED | Actor scheduler, versioned atomic store, application facade |
| One-time, interval, cron, event | DEVELOPMENT-GATED | Five-field cron and bounded typed event ingress |
| Agent/Goal/Skill/job/tests/check/review | DEVELOPMENT-GATED | Durable Agent/Review Task executor path |
| Complete per-run history | DEVELOPMENT-GATED | IDs, times, status, logs, result, changes, worktree |
| Recurring mutation isolation | DEVELOPMENT-GATED | Validation forces dedicated managed worktree |
| Post-run Diff/Review/Commit/PR/Discard | PARTIAL / DEVELOPMENT-GATED | Open Task exposes existing surfaces; explicit discard exists; no separate automated publish pipeline |
| GitHub/Slack/Gmail/filesystem/webhook events | SEAM | Typed ingress only; producer adapters/listeners are absent |
| Six notification kinds and Task routing | DEVELOPMENT-GATED | Explicit authorization, bounded payload, typed click route |
| SSH shell/filesystem/Git/build/test | DEVELOPMENT-GATED / LIVE HOST PENDING | Host-bound backend and 16 structured tools |
| Remote PTY | MVP / DEVELOPMENT-GATED | One-shot SSH PTY only; no persistent interactive Task Terminal |
| Execution-location safety | PARTIAL / DEVELOPMENT-GATED | SSH identity is propagated and local capabilities are disabled; a fully generic cross-platform backend for every tool does not yet exist |
| Local approval with remote identity | DEVELOPMENT-GATED | Backend/host/port/user/root shown in approval card |
| Mac/Worktree to SSH and SSH to Mac | DEVELOPMENT-GATED / LIVE HOST PENDING | Bounded same-HEAD migration, verification, rollback/CAS, durable journal recovery and Task handoff orchestration |
| Secure relay/mobile remote control | SEAM | `.futureCloud` exists but always fails closed |
| Focused automated coverage | PASSED | Included in the 744-test development regression; remote-disconnect boundary injection also passes |

## Known limitations and remaining Phase F gates

- Exercise an explicitly authorized real SSH host, including host-key mismatch,
  disconnect/timeout/cancellation, remote non-zero exit, output truncation,
  migration rollback, and App relaunch. Current backend tests use controlled
  transports and are not proof of network interoperability.
- Extend failure injection beyond the passing remote-disconnect scenario to
  scheduler store I/O, artifact-directory failure, worktree allocation/cleanup,
  notification denial/backend failure, and every handoff/run transition.
- Add full ViewModel/UI end-to-end coverage for Automation Task creation,
  retained-worktree Diff/Review/Commit/PR/Discard, notification-click navigation,
  Settings CRUD/test connection, and all three supported remote-handoff routes.
- Add real producers if GitHub, Slack, Gmail, filesystem, or webhook-triggered
  execution is required. The current seam must not be described as connected.
- Persistent remote PTY transport, richer remote Git, remote Browser/Computer
  Use/plugins/subagents, cross-platform backends, SSH-to-SSH migration, a secure
  relay, and mobile control remain future work.
- The remote directory flock coordinates Luma Chat operations; an unrelated
  same-account process can ignore it, replace the path after an identity check,
  or deliberately daemonize into a new session. One-shot shell must therefore
  not be described as a complete remote job supervisor.
- A Keychain private key is materialized only for one SSH launch in an exact
  mode-0600 file below project `tmp` and removed by exact name, but POSIX modes
  do not isolate it from another hostile process running as the same local UID.
- Abrupt termination inside a multi-file working-tree `git apply` can leave a
  safe-but-ambiguous partial state. Recovery refuses to overwrite it and keeps
  all evidence; crash-total per-path compensation and kill-at-every-boundary
  coverage remain Phase H security/failure-injection gates.
- Multi-hour/multi-day Automation and SSH soak plus a live-host disconnect run
  remain external production gates.

## Principal files

- Automation: `Sources/LumaChat/Agent/Automations/*`,
  `Sources/LumaChat/Views/Agent/AutomationSettingsPane.swift`, and the
  Automation integration in `AgentViewModel.swift`.
- Notifications: `Sources/LumaChat/Services/AgentNotificationService.swift`,
  `MacOSAgentNotificationBackend.swift`, and the Task event integrations in
  `AgentViewModel.swift`.
- Remote Runner: `Sources/LumaChat/Agent/Remote/*`,
  `Sources/LumaChat/Views/Agent/RemoteRunnerSettingsPane.swift`, execution
  identity/approval models, runtime/tool integration, and Task location UI.
- Focused tests: `AutomationSchedulerTests.swift`,
  `AgentNotificationServiceTests.swift`, and `RemoteRunnerTests.swift`.
