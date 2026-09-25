# Luma Chat Codex Replacement Roadmap

Last audited: 2026-09-25 after the LumaChat 1.4.1 combined Phase A-H development gate;
all eight implementation phases are complete, with production gates remaining

## Definition of 100

`100/100` means Luma Chat can replace Codex for this Mac's daily coding
workflow with tested, locally controlled equivalents. It does not mean copying
OpenAI's proprietary account, hosted compute, or internal orchestration. Remote
work must use a user-controlled host/backend and must be labelled truthfully.

The comparison baseline is the documented Codex app surface: [projects and
tasks](https://learn.chatgpt.com/docs/projects), [long-running
Goals](https://learn.chatgpt.com/docs/long-running-work), [local/worktree/cloud
modes](https://learn.chatgpt.com/docs/environments/modes), [Git
worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees), [scoped
terminals](https://learn.chatgpt.com/docs/integrated-terminal), [code
review](https://learn.chatgpt.com/docs/code-review), and
[subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents), plus
[Computer Use](https://learn.chatgpt.com/docs/computer-use).

Points are awarded only when the implementation, persistence/recovery behavior,
UI, automated tests, and release packaging all pass. A mock screen or an
unverified happy path earns no points.

## Local-workflow production-credit score

This roadmap keeps the narrower daily local-workflow rubric established before
the full platform audit. Its 84/100 result is therefore not directly comparable
to the broader 68.5/100 matrix in `CODEX_FULL_PARITY_AUDIT.md`, which includes
additional cloud, integration and production-distribution parity. Neither score
is the 8/8 implementation-completion percentage.

| Capability | Points | Current | Remaining release gates |
| --- | ---: | ---: | --- |
| Local agent core and safety | 25 | 23 | Long-run soak tests; broader model compatibility fixtures |
| Projects, tasks, and concurrency | 20 | 20 | Complete for the documented local Projects 2.0 scope; retain regression coverage |
| Terminal, Git, review, and worktrees | 20 | 20 | Phase B release-gated the PTY/pane, closed Advanced Git API, complete Review sources/actions/comments/Review Agent and provider-neutral PR seam with GitHub |
| Goals, extensions, subagents, automation | 20 | 9 | Phase C/D/F automated development gates pass; live integrations, external event producers and long soak remain |
| Product and release completeness | 15 | 12 | Phase F/G/H development gates pass; Developer ID/notarization/update feed, live services, secure relay and cross-platform gates remain |
| **Total** | **100** | **84** | **Formal points intentionally unchanged by development-only evidence** |

This score is intentionally stricter than feature counting. Existing filesystem,
terminal/process, Git, Todo, image, web, MCP, provider, permission, checkpoint,
undo, concurrent-task, and release-test paths retain their credit only while the
full regression suite remains green.

Phase B added five formally release-gated points. The four candidate Review gaps are
closed, Advanced Git passed its final focused suite, and the complete regression,
production package/sign/archive and packaged UI gates passed. The released
local-workflow score therefore remains **84/100**. This numeric score is not the
implementation percentage: the master program is now 8/8 phases implemented,
but production-only evidence is not converted into points speculatively.

The 2026-09-25 combined development gate passed 744 Swift tests with one
environment skip and zero failures, VS Code 17/17, GitHub Action 14/14, the
10/10 exact failure shard, optimized arm64 build, ad-hoc signing, canonical ZIP,
SBOM/provenance and security audit. The development ZIP SHA-256 is
`d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`.
Developer ID/notarization, live external acceptance and qualifying long soak
were not run or claimed.

## Development-gated Browser/CDP and Computer Use 2.0

The development tree now has a separate Task-owned Chromium/CDP layer with
isolated temporary and named persistent profiles plus explicit loopback-only
attachment. It provides bounded tabs/navigation, DOM/layout and Accessibility
projection, semantic/text/CSS actions, screenshot attachments, console/page
errors, network metadata, performance, JavaScript, redacted cookie inspection,
verified downloads and structured screenshot annotations. Browser-derived model
content is always a bounded untrusted-data envelope and profile/endpoint authority
cannot be selected by the model. See
[`BROWSER_ARCHITECTURE.md`](BROWSER_ARCHITECTURE.md).

The native Computer Use implementation closes part of the visual observe-act
gap. It is opt-in, requires a bounded exact-match bundle-ID allowlist, uses macOS Screen
Recording for observation and Accessibility for interaction, returns a bounded
ScreenCaptureKit target-window screenshot to a vision-capable model, and routes
actions through the existing `read` / `execute` / `dangerous` approval pipeline.
Text-only runs hide the capability; every UI action also requires the task's
latest 30-second, single-use capture ID, unique process, explicitly selected
visible window, and unchanged target-window geometry. Every action has a screenshot-backed inline
approval, and secret-like text is refused. Luma Chat,
ChatGPT/Codex, terminal apps, System Settings and security/credential surfaces
remain blocked regardless of the allowlist.

Phase E adds bounded safe-window enumeration/selection, capture-bound semantic
Accessibility IDs for a small press/focus role allowlist, and read-only or
post-action background verification that detects foreground, geometry, and
element-identity changes. The host computes exact Always Allow eligibility;
only observation/verification can qualify, while every mutation remains
`dangerous`, fresh-capture-bound, and approved once.

This does not establish complete visual automation parity with Codex. Browser
DOM/CDP is now a separate implementation, while Computer Use still has no broad
Accessibility action surface or locked-screen execution. Neither layer turns
GUI mutations into complete workspace Diff/Undo records. An allowlisted browser
or IDE can still contain network features or an embedded terminal that generic
pixel automation cannot classify, so they remain inappropriate for bypassing
structured network/terminal policy. Structured tools and
connectors remain preferred when they are available.

Computer Use 2.0 still adds no formal production points by itself. The audited
total remains **84/100**, while its focused and combined development gates now
pass. A stricter comparison
against the full current Codex desktop/CLI product is the separate
`CODEX_FULL_PARITY_AUDIT.md` matrix and must not be inferred from this score.

## Release sequence to 100

### 1.2 — Durable Goals

- Persist objective and optional completion criteria before Runtime starts.
- `/goal <objective>` and native Goal editor.
- Goal progress/status row using durable Todo and task state.
- Pause, Resume, edit-after-pause, clear-with-history-preserved, crash recovery.
- Backward-compatible session decoding and bounded untrusted JSON.

### 1.3 — Projects 2.0

- Project catalog independent of individual tasks.
- User-defined project names, multiple folders, primary folder, recent/pinned and
  archived tasks, per-project task search.
- Opening a project never creates a task; task creation remains explicit.
- Concurrent writable work requires independent checkout/worktree identity.
- **Released in 1.3.0:** legacy workspace-only tasks migrate idempotently into
  the catalog; catalog bookmark/recency refreshes are field-level atomic; one
  task binds to exactly one folder checkout and cannot be silently rebound after
  it owns messages, Goal, steps, or changes.
- **Phase A follow-through:** writable Tasks can now move into independently
  leased managed worktrees; two writers in one Local checkout remain rejected.

### 1.4 — Terminal and Review

- **Implemented in the current development tree:** one Task-owned service with
  multiple real `forkpty` terminals, resize/`SIGWINCH`, raw/canonical input,
  EOF/signals, exit state, bounded byte scrollback, PID/start-time process-tree
  cancellation, stable handles, metadata recovery and explicit fresh-shell
  Reconnect.
- **Implemented in the current development tree:** native Task Terminal pane
  with tabs, New/Rename/Reconnect, signals, Kill/Clear/Copy/Search/Close, safe
  incremental UTF-8/ANSI rendering, and continuity across Task/Chat/Settings
  navigation and Agent Stop.
- **Implemented in the current development tree:** permissioned
  `terminal_create`, `terminal_write`, `terminal_resize`, `terminal_read`,
  `terminal_signal`, and `terminal_close` tools, with Task isolation and inert,
  bounded, redacted model-visible output.
- **Implemented in the current development tree:** a closed Advanced Git API
  for fetch/pull/push, branch switching/deletion, hard reset, merge, rebase,
  cherry-pick, stash, tags and remotes, including explicit operation-state
  checks for merge/rebase/cherry-pick continue/abort. Network, destructive and
  history-rewriting operations use the permission policy declared by the host;
  plain force-push is not exposed.
- **Implemented in the current development tree:** Review sources for unstaged,
  staged, commit, branch and last Agent turn; file, unified and side-by-side
  presentations; line numbers, bounded syntax highlighting and binary/large
  fallbacks; and stable file/hunk fingerprints.
- **Implemented in the current development tree:** file/hunk Stage, Unstage and
  Revert. The pane builds a typed patch, Git performs `apply --check` and the
  mutation under one exclusive gate, stale identities fail closed, and Revert
  requires an explicit destructive confirmation.
- **Implemented in the current development tree:** durable file/line/range/hunk
  comments sent as typed `ReviewAgentContext`; separate persisted Review Tasks
  for Changes, Commit, Branch and PR; source-receipt-before-submission and
  structured-finding completion invariants; and Review/coding Task isolation.
- **Implemented in the current development tree:** a provider-neutral PR
  protocol, GitHub adapter, Keychain token scope, bounded GET/context/Create PR
  tools, Settings integration, and validated structured HTTPS result links.
- **Released through the local Phase B gate:** `CFBundleShortVersionString` is
  `1.4.0`, `CFBundleVersion` is `7`, and the verified arm64 ZIP is present.
- **Candidate Review blockers closed:** untracked files are included; complete
  artifact-backed content is continuously paged and incomplete receipts fail
  closed; fallback copy matches actions; Last Agent Turn freezes one globally
  consistent HEAD/path/content identity with bounded retry.
- **Gate completed:** Advanced Git focused/cancellation coverage, complete Swift
  regression, production build/sign/archive round-trip, packaged native UI
  smoke and artifact size/SHA-256 all passed. App relaunch intentionally restores
  Terminal metadata as `disconnected`; Reconnect starts a fresh shell rather
  than claiming to resurrect an old process or scrollback.

See [`TERMINAL_ARCHITECTURE.md`](TERMINAL_ARCHITECTURE.md) for the implemented
transport, persistence, lifecycle, safety, emulator, UI and focused-test chain.

### Phase C — Subagents (implementation and development gate complete)

- Durable child `AgentSession` identity, parent binding, goal/context/scope,
  complete budget/timestamp/status/result records and restart recovery.
- Seven orchestration tools plus a priority/FIFO scheduler with global,
  provider/model and per-parent capacity, timeout, cancellation propagation and
  failure isolation.
- Default read-only analysis scope, safe relative roots, exact tool/MCP/network
  narrowing, and dedicated managed worktrees for every writable child.
- Validated structured aggregation and a parent completion invariant requiring
  all outstanding results to be collected.
- Sidebar hierarchy and Task-level live status/navigation/cancel/resume UI.
- Focused tests pass in the final Phase C–H development validation/build gate.
  See [`SUBAGENT_ARCHITECTURE.md`](SUBAGENT_ARCHITECTURE.md).

### Phase D — Extensions (implementation and development gate complete)

- Bounded global/project/repository/nested/plugin `SKILL.md` discovery,
  precedence, explicit `$skill` and description selection, transient prompt
  injection, loaded-Skill metadata, and exact-ID resource access.
- Independent plugin manifest and lifecycle layer with Local, Git, HTTPS
  manifest, and user registry sources; permission preview; package/path/size
  and minimum-version validation; and atomic install/update/enable/disable/
  uninstall recovery.
- Plugin tools and host-only lifecycle hooks reuse the normal registry,
  permission, network, timeout, output-redaction, and execution boundary. Exact
  binaries run in permission-derived macOS sandboxes with non-blocking bounded
  I/O. All required lifecycle event names and failure policies are typed.
- PKCE OAuth connectors persist public configuration separately from
  Keychain-only credentials. Plugin MCP declarations have explicit ownership;
  manual MCP configurations remain independent.
- Extensions Settings and Task loaded-Skill presentation share the live
  extension state. Focused tests pass in the combined development gate. See
  [`PLUGIN_ARCHITECTURE.md`](PLUGIN_ARCHITECTURE.md).

### Phase F — Automations, notifications, and SSH (development-gated; live host pending)

- Added a versioned atomic Automation store and actor scheduler with durable
  occurrence claims, one-time/interval/five-field-cron/event schedules, missed-
  run policy, restart interruption recovery, bounded concurrency and run
  history.
- Agent Task, Goal, Skill, project job, tests, repository check and typed
  Changes Review actions create ordinary persisted Tasks. Recurring/event
  mutation-capable work is forced into a dedicated managed worktree. Completed
  runs expose their Task for existing Diff/Review/Commit/PR actions and provide
  explicit retained-worktree discard.
- Added six bounded macOS notification types with explicit authorization and
  typed click routing back to the exact Task. Notification failure remains a
  presentation failure and cannot rewrite Task/Automation state.
- Added SSH Runner Settings, atomic non-secret metadata, Keychain private keys,
  strict selected-host verification, host/user/root receipts and locally
  rendered approval identity. Configuration, credential, and exact known-hosts
  bytes are captured into one fingerprinted authority snapshot per run.
- Added 16 Task-bound remote tools spanning bounded filesystem, status/diff/log/
  add/commit, SwiftPM/Xcode build/test, shell, and one-shot SSH PTY. Local tools,
  native Task Terminal, Browser, Computer Use, subagent launch and executable
  plugins fail closed instead of running on the Mac for an SSH Task.
- Added explicit Mac/managed-Worktree to SSH and SSH to original Local migration
  using a verified same-HEAD Git-state snapshot. Each snapshot is capped at
  4 MiB and each desired/baseline transaction at 8 MiB; both exclude `.git`,
  secrets, arbitrary ignored caches, symlinks, special files, and AppleDouble
  entries. Apply/idempotent rollback share one UUID and refuse divergent state.
  Both directions use durable handoff journal stages and integrity-bound
  recovery snapshots plus the pinned baseline/remote authority; relaunch
  recovery compares the persisted Task binding with the exact source/destination
  and never overwrites a third state. Pending evidence blocks the runner too.
- The combined test/build/package run and deterministic remote-disconnect
  boundary test pass. Remaining Phase F gates are real SSH-host acceptance,
  ViewModel/UI handoff and Automation E2E, broader transition failure injection,
  and long soak. GitHub/Slack/Gmail/filesystem/webhook producers,
  persistent remote PTY and a secure relay are not implemented.
- `.futureCloud` remains only a truthful fail-closed protocol seam. See
  [`AUTOMATION_REMOTE_ARCHITECTURE.md`](AUTOMATION_REMOTE_ARCHITECTURE.md).

### Phase G — CLI, App Server, SDK, integrations, and artifact workflows (development-gated)

- Added the `lumachat` launcher and shared-runtime `chat`, `agent`, `exec`,
  `resume`, `tasks`, `projects`, `skills`, `mcp`, and `plugins` commands. Help,
  version, and usage errors are frontend-only; run commands retain bounded
  UTF-8-safe JSON or JSONL output and deterministic exit categories.
- Non-interactive execution is fail-closed: it never auto-approves, always
  attempts to stop a Task that reaches approval, and requires exact canonical
  backend, model, workspace, mode, and existing-Task identity.
- Added a loopback-only, bearer-authenticated versioned App Server over the same
  Agent runtime. It supports Task creation/message/status/diff/control,
  approvals, idempotency, and replayable SSE with monotonic Task sequences,
  heartbeats, bounded buffers, request/write deadlines, and request IDs.
- Added a language-neutral v1 protocol description and Swift SDK. The client
  rejects redirects and non-origin URLs and verifies media type, content
  length, API version, request ID, Task/backend/model identity, and SSE sequence.
- Added a thin VS Code adapter for selection/file prompts, fixes, Task control,
  diff review, and deliberately constrained patch application. Multi-root
  ambiguity, traversal, symlinks, `.git`, AppleDouble paths, stale scope, and
  truncated or manifest-mismatched responses fail closed.
- Added a GitHub Action for PR review against only the caller-selected
  user-controlled backend/model. It runs in Plan mode, verifies scope on every
  poll, stops its exact Task on every failure path, and never silently falls
  back to a cloud provider or auto-approves work.
- Added the bundled `com.lumachat.artifact-workflows` plugin with seven Skills:
  PDF, document, spreadsheet, presentation, image, visualization, and site.
  Installation, enablement, and permission revocation share the normal plugin
  state; release packaging checks the exact manifest and Skill payload.
- Focused Swift, Node, schema, packaging, and integration tests pass in the
  combined development gate. Process-local
  idempotency, count-bounded rather than aggregate-byte-bounded live SSE queues,
  VS Code filesystem races, and same-machine App Server workspace visibility
  remain documented limitations. See [`CLI_ARCHITECTURE.md`](CLI_ARCHITECTURE.md)
  and [`APP_SERVER_ARCHITECTURE.md`](APP_SERVER_ARCHITECTURE.md).

### Phase B release verification

- Direct Task Terminal evidence: 47 cases. Real programs include `vim`, Python
  REPL, `nano`, `htop`, `git add -p`, offline `ssh -G` and `pip`; setuid-root
  `/usr/bin/top` is one explicit sandbox skip.
- Advanced Git passed 21/21; the combined persistence/handoff/lease gate passed
  37/37; secure filesystem/change coverage passed 17/17.
- The isolated complete suite passed 504 tests with one explicit skip and zero
  failures in 177.768 seconds. All 5 archive tests passed. Production arm64
  build completed in 125.87 seconds.
- App and extracted-app signature/plist checks plus ZIP CRC, exact membership,
  content/mode and AppleDouble checks passed. Packaged UI smoke proved the
  no-implicit-Task invariant, real unstaged Review, real PTY/ANSI and pane
  continuity.
- `dist/LumaChat-1.4.0-arm64.zip` is 7,315,724 bytes with SHA-256
  `224d6942969670cd090797416bdcfb979a79387a827b68fa8c184d64d871b2b0`.

### 1.5 — Worktrees and handoff

- **Implemented in the current development tree:** create/reuse/list/inspect/
  remove/cleanup/repair managed Git worktrees with collision-safe branch and
  durable lease handling.
- Local ↔ Worktree handoff uses a transaction journal, Local baseline CAS,
  integrity-bound rollback snapshot, launch recovery, and exact source cleanup.
- Task Fork creates a distinct managed checkout while copying bounded context,
  Goal/Todo and checkpoint provenance without sharing Runtime/process state.
- Parallel writable tasks are isolated by construction and location is surfaced
  in Sidebar and Detail actions.
- Phase F adds bounded explicit Local/Worktree → SSH and SSH → original-Local
  migration with durable journal recovery and passing development tests, but
  live-host acceptance remains and it does not add SSH-to-SSH or arbitrary
  alternate-Local routes.
  General maintenance UI/scheduled cleanup, full
  process-kill/disk-full fault drills, and arbitrary ignored-file policy remain.

### Phase A verification

- Dedicated repository-layout, lifecycle, migration, journal, recovery, Fork,
  history, Session-ordering, and ViewModel end-to-end suites pass.
- The ViewModel test exercises Local → Worktree → Fork, rejects an externally
  changed Local baseline without mutation, then completes Worktree → Local and
  verifies exact leases, bindings, files, journals, and source cleanup.
- The 2026-08-31 release validation passed 344/344 Swift tests and 5/5 archive
  tests, built the production arm64 executable, and verified both packaged and
  extracted signatures, plist/version/executable, ZIP CRC, exact member/content
  identity, canonical `0755`/`0644` archive modes, and AppleDouble absence.
- The packaged `LumaChat-1.3.1-arm64.zip` SHA-256 is
  `b9736079bdfb686eb401f88c13d3ad26df75f28fd691e998121831ac09618fac`.
- Native UI smoke opened the packaged app, switched Chat → Agent, rendered the
  Task/Project entry points without creating an implicit Task, and exited
  normally. Developer ID/notarization/update/rollback remain later gates.

### 1.6 — Extensible autonomous platform

- **Implemented in the development tree:** discoverable Skills, plugin
  manifests/manager, lifecycle hooks, OAuth connector abstraction, explicit
  permissions, Extensions UI, and plugin-owned MCP coexistence.
- **Implemented in the development tree:** bounded parallel subagents,
  ownership of subtasks, aggregation, cancellation, and durable progress.
- **Implemented in the development tree:** recurring/project Automations,
  history, worktree isolation and six notification kinds. Authenticated external
  event producers remain future integrations.
- **Partially implemented in the development tree:** a user-controlled SSH
  Remote Runner as the truthful remote-execution mode, with bounded explicit
  migration. Persistent remote Terminal, secure relay and live-host release
  evidence remain.

### 2.0 — Replacement release

- Migration/backup/export and restore drills.
- Accessibility, localization, multi-day soak, crash/relaunch, disk-full, offline,
  provider-failure, and adversarial path/security suites.
- Developer ID signing, notarization, update feed, rollback package, reproducible
  hashes, release notes, and a clean project `tmp` after packaging.

## Non-negotiable 100-point gates

1. Switching tasks, Chat, Settings, projects, or review never pauses unrelated
   work and never locks navigation.
2. No implicit task is created by mode, agent, or project selection.
3. Persistent state survives force quit without fabricating model/tool results.
4. Every filesystem/process/network capability is scoped, reviewable, cancellable,
   and secret-redacted.
5. All caches, generated toolchains, logs, checkpoints, and release scratch data
   remain under the project `tmp`; the final release cleans them.
6. A full automated suite, manual GUI smoke test, signature verification, archive
   integrity check, and documented known limitations pass for every release.
