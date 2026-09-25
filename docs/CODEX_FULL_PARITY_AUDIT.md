# LumaChat Full Codex-Class Parity Audit

Last audited: 2026-09-25, after the LumaChat 1.4.1 combined Phase A-H
development gate

## Scope and scoring rule

This is the broad Desktop/CLI platform-parity audit. The only intended
foundational difference is model routing: LumaChat remains local-first and uses
a user-controlled Ollama, remote Ollama, OpenAI-compatible, or
Anthropic-compatible endpoint.

A type, protocol, button, or static screen is not implementation evidence. A
capability earns credit only when its working implementation, persistence,
recovery/failure behavior, UI, tests, and release path form an honest chain.

- `COMPLETE`: the audited scope and release gates are complete.
- `PARTIAL`: a production path exists, but material parity gates remain.
- `DEVELOPMENT-GATED`: implementation and automated development release gates
  pass, but live external or production-distribution evidence remains.
- `MVP`: an intentionally constrained vertical slice works.
- `STUB`: a presentation or interface seam exists without the required chain.
- `MISSING`: no meaningful implementation exists.
- `BLOCKED`: an external dependency or decision prevents progress. A later
  planned phase is not itself a blocker.

## Executive result

The pre-Phase-A baseline was **56/100**. Phase A raised the formally
release-gated result to **64/100** and Phase B to **68.5/100**. The original
master prompt's eight implementation phases are now **8/8 complete**, and the
combined Phase A-H development gate passes. The formal production-credit score
is deliberately not recomputed from development-only evidence: notarization,
live external acceptance and qualifying long-duration soak remain incomplete.

Phase B supplies real Darwin PTYs and a Task Terminal pane; a closed Advanced
Git surface; complete typed Review sources with file/unified/side-by-side
rendering and file/hunk actions; durable structured inline comments; isolated
Review Tasks with source-receipt and structured-finding invariants; and a
provider-neutral PR service with a GitHub adapter, Keychain credentials,
bounded tools and validated result links.

The four Review issues found during the candidate audit are closed: untracked
files are included, complete artifact-backed sources are paged and incomplete
receipts fail closed, fallback copy matches available actions, and Last Agent
Turn is frozen from a globally consistent checkout identity. Stop/Pause/
shutdown persistence races, same-length concurrent file rewrites, cached root
replacement and renewable worktree lease identity were also closed before the
gate.

The 2026-09-25 isolated suite passed 744 tests with one explicit environment
skip and zero failures. The optimized arm64 build, ad-hoc signing,
bundle/extracted-bundle checks, canonical ZIP, SBOM/provenance and security audit
passed. VS Code passed 17/17 and GitHub Action passed 14/14 Node tests. This is
a development release gate, not Developer ID/notarized production evidence.

This is not full Task Handoff or cloud parity. The development tree now has a
user-controlled SSH Remote Runner, host receipts, 16 closed remote tools, local
approval identity, and bounded explicit Local/Worktree ↔ SSH migration. The
remote PTY is intentionally one-shot, `.futureCloud` remains a fail-closed seam,
and live-host acceptance, persistent interactive remote terminals,
cross-platform backends, and long soak remain incomplete. A deterministic
remote-disconnect boundary test is included in the passing failure shard.
Review/PR provider breadth and live external validation also remain incomplete.
Phase C Subagents, Phase D Skills/plugins/hooks/OAuth, Phase E Browser/CDP /
Computer Use 2.0, Phase F Automations/notifications/SSH, and Phase G's CLI,
App Server, SDK, VS Code adapter, GitHub Action and artifact Skills are now
development-gated. External event producers, secure relay, live services and
production distribution remain incomplete.
“Phase A release-ready” means the scoped Local/Worktree
slice is releasable; it does not rename the whole product a Codex-class
replacement.

## 100-point capability matrix

| Capability | Weight | Before | After | State | Evidence and tests | Known limitations |
| --- | ---: | ---: | ---: | --- | --- | --- |
| Agent Core and model providers | 12 | 12 | 12 | PARTIAL | Bounded Runtime, provider adapters, tool loop and regression suites | Long-run soak, broader model fixtures, structured event bus |
| Permission, workspace, change safety | 8 | 8 | 8 | PARTIAL | Descriptor-safe I/O, scoped approvals, Undo/checkpoint/security suites; SSH identity reaches local approval cards; combined development gate passes | OS/backend generalization and live external acceptance remain |
| Projects | 5 | 5 | 5 | COMPLETE | Projects 2.0 catalog/migration/UI/tests; location metadata remains one-folder scoped | Complete for documented local scope |
| Tasks, concurrency, crash resume | 5 | 5 | 5 | PARTIAL | Per-Task Runtime, durable sessions, background navigation, transaction recovery; Task PTYs survive navigation and Agent Stop; Review Tasks persist a locked source contract and structured result | PTY process reattachment, browser/subagent structured resume and kill-stage drills |
| Goals, context, compaction, memory | 4 | 4 | 4 | PARTIAL | Durable Goal/Todo/context bounds and tests | Searchable session/project/user memory and category budgets |
| Managed worktrees and writable isolation | 6 | 1 | 5.5 | PARTIAL | Registry, leases, create/reuse/list/inspect/remove/cleanup/repair, location UI, lifecycle/E2E tests | No maintenance UI/scheduler; retained branches; orphan edge coverage |
| Task handoff and Task fork | 4 | 0 | 3 | PARTIAL / DEVELOPMENT-GATED | Release-gated Local ↔ Worktree CAS/Fork plus development-gated bounded Local/Worktree ↔ SSH migration and host rollback | Remote routes await live-host acceptance; SSH-to-SSH and broader kill/storage matrix remain |
| PTY terminal and task terminal sessions | 6 | 4 | 5.5 | PARTIAL / DEVELOPMENT-GATED | Local `forkpty`/Task Terminal plus bounded one-shot `remote_pty_run`; signal-crash test passes | No old-process/scrollback reattach; no persistent remote input/resize/reconnect; non-Darwin and long soak remain |
| Git lifecycle and advanced Git | 5 | 4 | 5 | COMPLETE | Normal/pointer/submodule/detached layouts; closed status/diff/log/show/branch/commit plus fetch/pull/push/switch/hard-reset/merge/rebase/cherry-pick/stash/tag/remote API; 21/21 focused and integrated release gate | Remote effects lack local Undo; linked-metadata limitations are surfaced rather than hidden |
| Review, inline comments, PR workflow | 5 | 2 | 4.5 | PARTIAL | Five complete typed sources, frozen Last Agent Turn, native file/unified/side-by-side pane, file/hunk Stage/Unstage/Revert, durable comments, isolated Review Tasks/findings, GitHub PR adapter/Keychain/tools and packaged UI smoke | GitHub only; no authorized live PR mutation E2E; provider-omitted patches remain unknowable |
| Subagents and scheduler | 5 | 0 | 0 | DEVELOPMENT-GATED | Durable child Tasks, seven tools, actor scheduler, budgets, scoped read/worktree isolation, structured aggregation, UI and passing focused tests | Live high-concurrency/long-duration acceptance remains |
| Skills | 4 | 0.5 | 0.5 | DEVELOPMENT-GATED | Five-source `SKILL.md` discovery, precedence, `$skill`/description selection, transient instructions, loaded metadata, exact-ID resource tool, UI and passing focused tests | Scripts intentionally do not auto-execute; live ecosystem breadth remains |
| Plugins, Hooks, OAuth connectors | 5 | 0 | 0 | DEVELOPMENT-GATED | Manifest/manager, atomic lifecycle, permission UI, sandboxed tools, typed hooks, PKCE and Keychain store pass combined gate | No hosted marketplace/signature transparency, OAuth live-provider refresh/device flow, or portable WASM sandbox |
| MCP tools/resources/prompts | 4 | 4 | 4 | PARTIAL / DEVELOPMENT-GATED | STDIO/Streamable HTTP, tools/resources/prompts, Keychain/tests, plugin ownership, and real child-process crash coverage | Richer health/restart UX and live-server breadth remain |
| Browser and DOM/CDP automation | 5 | 1.5 | 1.5 | DEVELOPMENT-GATED | Task-owned Chromium/CDP, isolated/persistent/attached profiles, bounded surfaces, downloads, annotations, focused tests and crash cleanup | Real-Chromium/package UI and long soak remain; bounded selectors do not cover every dynamic/shadow-DOM app |
| Computer Use | 2 | 2 | 2 | DEVELOPMENT-GATED | Opt-in allowlist, safe-window selection, capture-bound AX, verification, approval UI, secret refusal and passing focused tests | Live native packaged UI pending; no broad AX action surface or locked-screen execution |
| Automations and notifications | 4 | 0 | 0 | DEVELOPMENT-GATED | Durable scheduler/store/history, seven Task actions, dedicated worktrees, typed notifications, routing and passing focused tests | External event producers, native UI acceptance and soak remain |
| Remote execution and control | 4 | 0 | 0 | PARTIAL / DEVELOPMENT-GATED | SSH runner/store/Keychain, strict host receipt, 16 closed tools, migration, Settings/UI, focused and disconnect-boundary tests | Live-host E2E, persistent remote PTY, richer backends, secure relay and soak remain |
| CLI, App Server, SDK, IDE and GitHub | 4 | 0 | 0 | DEVELOPMENT-GATED | Shared-runtime CLI, authenticated server/SSE, Swift SDK, VS Code 17/17, GitHub Action 14/14 and package paths | Process-local idempotency and live transport/hosted-runner acceptance remain |
| Release and cross-platform readiness | 3 | 3 | 3 | PARTIAL / DEVELOPMENT-GATED | 744-test release gate, updater rollback/failure tests, ad-hoc signing, canonical ZIP, metadata and security audit | Developer ID/notarization/stapling, production update feed, non-Darwin backend and qualifying soak |
| **Total** | **100** | **56** | **68.5** |  |  |  |

The numeric total above remains the last formal production-credit score. It is
not a feature-completion percentage. Development phase progress is 8/8; rows
marked `DEVELOPMENT-GATED` intentionally retain their prior numeric points until
their listed external production gates are satisfied.

## Combined development gate evidence — 2026-09-25

- Archive contract 6/6, soak contract 4/4, security-report contract 1/1.
- Swift: 744 tests, one explicit environment skip, zero failures, 189.790 s.
- Failure shard: exact 10/10 scenarios for force quit, disk full, network and
  backend loss, MCP/Browser/PTY crash, Git lock, deleted worktree, and remote
  disconnect.
- VS Code Node tests 17/17; GitHub Action Node tests 14/14.
- Optimized arm64 build 168.54 s; ad-hoc hardened signature, plist, canonical
  archive, extracted app, SBOM/provenance and security audit passed.
- Development ZIP SHA-256:
  `d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`.
- Not executed or claimed: Developer ID/notarization/stapling, production update
  feed, real authorized external-service acceptance, native packaged UI smoke,
  and qualifying 2h/8h/24h/multi-day soak.

## Trace findings

### Existing Chat path

`RootView` / `ChatDetailView` → `ChatViewModel.send()` → `LLMClient.stream()` →
`ConversationStore` remains separate from Agent execution. No Agent workspace,
worktree, tool, or permission authority is injected into Classic Chat.

### Existing Agent path

`AgentDetailView` → `AgentViewModel` → per-session `AgentRuntime` → provider +
`ToolRegistry` → permission/security → bounded tools → Session, ChangeManager,
checkpoint and project persistence. Before Runtime starts, a managed Task is
rebound to its exact registry record, UUID-owned checkout path, lifecycle state,
and Task lease. Location mutation has separate root locks and cannot share live
Runtime, terminal, process, or approval state.

### Phase A blocker resolution

1. `GitRepositoryLayout` now accepts normal `.git` directories, linked-worktree
   pointer files, separate Git directories/submodule forms, nested repositories,
   and detached HEAD, while malformed/stale/out-of-policy pointers fail closed.
2. Linked-worktree metadata is a closed Git/checkpoint capability. It is not
   added to general filesystem or model shell authority.
3. Git tools operate through the validated layout. Metadata-level mutation Undo
   is explicitly unavailable rather than represented by an empty fake record.
4. `AgentSession` persists execution location, Local baseline, worktree/fork
   provenance, and bounded checkpoint references.
5. `ManagedWorktreeService`, registry, conflict resolver, and leases provide
   isolated writable checkouts and reject lease theft.
6. `AgentViewModel` provides Local → Worktree, Worktree → Local, Fork, startup
   recovery, deletion lease recovery, dual-root exclusion, and location labels.

## Phase A — release-ready Local/Worktree slice

### IMPLEMENTED STATE

- UUID-owned create, planned-ID create, reuse, release, inspect, list, safe
  remove, clean-only cleanup, repair, external-deletion state, and orphan seams.
- Durable registry and lease capability; a Session path alone has no authority.
- Staged, unstaged, untracked, tombstone, empty-directory, and explicit
  Task-owned ignored-path transfer with bounded fingerprints and verification.
- Local → Worktree transaction with compensation before Session commit.
- Worktree → Local baseline compare-and-swap, fast-forward restriction, durable
  rollback payload, startup completion/rollback, and post-capture source check.
- Writable Task Fork creates a distinct checkout/lease and resets all live
  execution state while copying bounded durable context.
- Sidebar and detail actions show truthful execution location and valid actions.
- Exact Task-deletion lease journal; deletion does not automatically destroy a
  checkout that may contain user work.
- External-volume AppleDouble handling ignores only untracked `._*` metadata;
  tracked paths remain repository state.

### REMAINING LIMITATIONS

- Phase F now implements the three intentional V1 Remote routes—Local → SSH,
  managed Worktree → SSH, and SSH → the Task's original Local checkout—but
  only the controlled development gate has run. Live-host acceptance remains;
  SSH → SSH, SSH → arbitrary Local, and SSH → new Worktree routes are not claimed.
- Arbitrary ignored files are not migrated; only explicit Task-owned ignored
  paths are supplemental. Symlinks and special files fail closed.
- PTY signal crash, deleted worktree, Git lock and updater post-swap disk-full
  rollback are automated; every-stage relaunch and broader I/O injection remain.
- Cleanup/repair/list/inspect lack a general maintenance screen or scheduler.
- Normal checkout removal retains a created branch; branch garbage collection
  is not implicit.
- A Local branch divergence is rejected rather than merged. Immutable
  checkpoint provenance is referenced, not rewritten to a new identity.
- Linked-worktree Git metadata mutations have no native ChangeManager Undo.

### FILES INVOLVED

- Models/orchestration: `AgentModels.swift`, `AgentViewModel.swift`,
  `AgentTaskForkBuilder.swift`.
- Repository/worktrees: `GitRepositoryLayout.swift`,
  `ManagedWorktreeModels.swift`, `ManagedWorktreeService.swift`,
  `WorktreeRegistry.swift`, `WorktreeConflictResolver.swift`,
  `WorktreeCommandRunner.swift`, `TaskWorktreeManaging.swift`.
- Transactions: `WorktreeStateMigrator.swift`,
  `AgentTaskHandoffJournal.swift`, `AgentTaskDeletionJournal.swift`,
  `WorktreeStateRecoveryStore.swift`, `AtomicFileWriter.swift`.
- Git/runtime integration: `GitService.swift`, `TerminalSandbox.swift`,
  `TerminalSession.swift`, `AgentCheckpointManager.swift`,
  `BuiltinToolFactory.swift`, `WorkspaceManager.swift`.
- UI: `AgentSidebarView.swift`, `AgentDetailView.swift`.
- Design detail: `docs/WORKTREE_ARCHITECTURE.md`.

### ARCHITECTURE

The registry owns paths; leases own Task access; Sessions store identities.
Forward handoff journals a planned identity before allocation, verifies copied
state, then atomically commits the Session. Reverse handoff proves the Local
baseline, writes an integrity-bound rollback snapshot, replaces Local by CAS,
commits the Session, transfers history, revalidates the source, and reclaims only
the exact leased checkout. Startup recovery compares the persisted Session with
the journal's `from` and `to` bindings and never guesses through ambiguity.

See `WORKTREE_ARCHITECTURE.md` for state machines and the recovery table.

### RISKS

Mitigated risks include `.git` pointer authority expansion, branch collision,
lease theft, half-migrated Session binding, Local overwrite, recovery payload
tampering, symbolic-link parent escape, stale delayed Session writes, and
external-volume AppleDouble noise. Residual risks are arbitrary ignored state,
third-party writes in the final source-removal race window, storage exhaustion,
and unexercised host-kill points. Source is re-captured immediately before
removal; a mismatch retains the transaction and checkout.

### COMPLETED IMPLEMENTATION PLAN

1. Completed repository-layout and linked-worktree Git/checkpoint support.
2. Completed registry, lease, conflict and lifecycle service.
3. Completed durable execution-location and UI actions.
4. Completed forward/reverse transaction, rollback store and launch recovery.
5. Completed writable Fork and bounded inheritance policy.
6. Completed focused/E2E regression coverage and strengthened release archive
   round-trip verification.

### TEST AND RELEASE EVIDENCE

- Repository layout, closed Git capability and checkpoint suites.
- Managed lifecycle, planned identity, collision, cleanup and repair suites.
- State transfer, CAS, fast-forward, rollback, symlink, tombstone and directory
  suites.
- Handoff/deletion journal, recovery store, AtomicFileWriter, history and Session
  ordering suites.
- Full ViewModel Local → Worktree → Fork → Local E2E, including external Local
  conflict and exact lease/journal/source checks.
- The 2026-08-31 gate passed 344 XCTest cases with zero failures and five
  release-archive regression cases with zero failures.
- The production arm64 build, ad-hoc signature, plist, CRC, exact archive
  manifest, per-file content digest, canonical `0755`/`0644` member modes,
  AppleDouble exclusion, and extracted-bundle signature all passed.
- The shipped `LumaChat-1.3.1-arm64.zip` SHA-256 is
  `b9736079bdfb686eb401f88c13d3ad26df75f28fd691e998121831ac09618fac`.
- A native packaged-app smoke launched Luma Chat, switched Chat → Agent,
  rendered the Projects/Task entry points, proved mode switching did not create
  an implicit Task, and exited normally.
- Exact commands and environment notes are recorded in the validation section
  of `AGENT_ARCHITECTURE.md`.

## Phase B — release-ready local Terminal/Git/Review slice

### CURRENT STATE

- The original sandboxed `Process`/pipe path remains for bounded background
  commands and managed-process stdin. Interactive Task Terminal is now a
  separate real-PTY path rather than a renamed pipe.
- A Darwin `forkpty(3)` bridge supplies a controlling terminal, raw/canonical
  byte I/O, EOF, resize/`SIGWINCH`, foreground signals, exit/reap state and
  bounded process-tree shutdown. Descendants are tracked by PID plus kernel
  start time, including children that call `setsid()`.
- `PTYBackend` / `PTYSessionTransport` isolate the platform boundary. The only
  current implementation is `DarwinPTYBackend`; UI, tools and Task lifecycle do
  not receive PTY descriptors.
- One `TaskTerminalService` per exact Task/workspace binding owns up to 16
  terminals, stable UUIDs, atomic bounded metadata, push events, ordered writes,
  clear generation, rename, signals, close/kill and explicit Reconnect.
- The native Terminal pane provides multiple tabs, New/Rename/Reconnect,
  signals/EOF, Kill/Clear/Copy/Search/Close, lifecycle badges, viewport resize,
  bracketed paste, application cursor keys and ANSI/VT attributed rendering.
- Terminal lifetime is Task-owned: view/Task/Chat/Settings navigation and Agent
  Stop do not stop it. Rebind/handoff/archive reject a live Task terminal; Fork
  starts isolated; deletion/shutdown disposes services before authority ends.
- The Agent has six separately permissioned structured tools:
  `terminal_create`, `terminal_write`, `terminal_resize`, `terminal_read`,
  `terminal_signal`, and `terminal_close`. Read output is inert, bounded,
  control-stripped, secret-redacted, host-path-scrubbed and marked untrusted.
- `GitService` is a closed, host-selected API. In addition to status/diff/log/
  show/add/restore/checkout/commit/branch, the development tree includes remotes,
  tags and stash inspection; fetch/pull/push; switch/delete/hard reset; merge,
  rebase and cherry-pick with continue/abort state checks; stash mutation; tag
  mutation; and remote configuration. A fixed `GitOperation` table declares
  read, local-write, network and dangerous behavior before model arguments are
  inspected. Plain `--force` is not exposed; push can request only a scoped
  `--force-with-lease` destination and remains an explicit remote side effect.
- `ReviewService` loads typed Unstaged, Staged, Commit, Branch and Last Agent
  Turn sources through Git/task-history adapters. `ReviewDiffParser` and the
  presentation builder provide file, unified and side-by-side views, line
  numbers, bounded syntax highlighting, added/deleted/renamed metadata, and
  explicit binary/large/malformed fallbacks.
- File and hunk Stage/Unstage/Revert actions carry stable file and hunk
  fingerprints. The host builds the patch, validates its path set, serializes it
  against other Git commands, runs `git apply --check`, then records an index or
  worktree ChangeManager transaction where the repository layout supports a
  truthful snapshot. Revert requires an explicit destructive confirmation.
- File/line/range/hunk comments persist in the source Task as typed
  `ReviewInlineComment` values. Sending feedback adds bounded
  `ReviewAgentContext` without flattening anchors into prose.
- Review Changes/Commit/Branch/PR creates a separate durable Review Task bound
  to one stopped coding Task and checkout. It borrows provenance but never the
  source Runtime, Terminal, approvals, undo history or managed-worktree lease.
  The Runtime exposes only Review-specific source/submission tools plus bounded
  local reads; a host-authenticated source receipt must precede a bounded,
  structured finding submission before completion can be recorded.
- `PullRequestProvider` is provider-neutral. The first adapter supports GitHub
  GET/context/Create, bounded paginated file context, no redirects, same-origin
  response checks and cancellation. Configuration is non-secret; its token is
  scoped by provider and endpoint in Keychain. The three PR tools are network
  tools, Create is dangerous, and the UI opens only a successful allow-listed
  tool's validated structured HTTPS URL.
- Version metadata is `1.4.0` / build `7`; the release workflow produced and
  verified `dist/LumaChat-1.4.0-arm64.zip`.

### RESIDUAL LIMITATIONS

- Terminal relaunch recovery is metadata-only: a previously running terminal is
  marked `disconnected`, and explicit Reconnect creates a fresh shell. The old
  Unix process and raw scrollback cannot be reattached.
- The persistent Task Terminal backend is Darwin-only. Phase F adds a bounded
  one-shot SSH PTY command, not persistent remote input/resize/reconnect/
  scrollback. Non-macOS transports, broader crash/storage fault injection and
  long soak remain later-phase work.
- No unit test performs a live push or creates a live PR. Remote-side rollback
  is not available, provider tests use controlled transports, and GitHub is the
  only provider adapter. There is no push→create→open→review end-to-end
  acceptance run. GitLab and Bitbucket remain future extensions.
- Review intentionally falls back instead of inventing text for binary,
  oversized or malformed diff content. GitHub may omit a file patch. Review PR
  findings are therefore limited to bounded content actually returned by the
  provider.
- Index mutations in linked-worktree layouts that cannot participate in native
  workspace metadata snapshots report Undo unavailable. Remote Git/PR effects
  never claim local workspace Undo.
- Review crash/disk-full/relaunch recovery and broader native UI acceptance can
  be expanded during Phase H hardening. The requested real-program Terminal
  matrix is covered where binaries exist; Node/npm were unavailable, and
  setuid-root `/usr/bin/top` is explicitly skipped while `htop` covers the TUI.

### FILES INVOLVED

- PTY boundary: `Sources/LumaPTYSupport/LumaPTYSupport.c` and its public header,
  `PTYBackend.swift`, `PseudoTerminalSession.swift`, and `TerminalSandbox.swift`.
- Task/UI/tools: `TaskTerminalService.swift`, `TaskTerminalEmulator.swift`,
  `TaskTerminalPane.swift`, `TaskTerminalSurfaceView.swift`,
  `BuiltinToolFactory.swift`, `AgentViewModel.swift`, and `AgentDetailView.swift`.
- Terminal tests: `PseudoTerminalSessionTests.swift`,
  `TaskTerminalServiceTests.swift`, `TaskTerminalToolTests.swift`,
  `TaskTerminalEmulatorCoreTests.swift`, `TaskTerminalPaneModelTests.swift`,
  `TaskTerminalSurfaceRenderingTests.swift`, and
  `AgentViewModelTaskTerminalLifecycleTests.swift`.
- Advanced Git: `GitService.swift`, `BuiltinToolFactory.swift`,
  `ChangeManager.swift`, `GitRepositoryLayout.swift`, and
  `AdvancedGitServiceTests.swift`.
- Review core/UI: `ReviewModels.swift`, `ReviewDiffParser.swift`,
  `ReviewPatchBuilder.swift`, `ReviewPresentationBuilder.swift`,
  `ReviewSyntaxHighlighter.swift`, `ReviewService.swift`, `ReviewPane.swift`,
  `AgentViewModel.swift`, `AgentModels.swift`, and `AgentDetailView.swift`.
- Review Agent: `ReviewWorkflowToolFactory.swift`, `AgentRuntime.swift`,
  `ContextManager.swift`, `ToolExecutor.swift`, and the Review workflow,
  contract, isolation and ViewModel suites.
- PR: `PullRequestModels.swift`, `PullRequestProvider.swift`,
  `GitHubPullRequestProvider.swift`, `PullRequestCredentialStore.swift`,
  `PullRequestToolFactory.swift`, Settings integration,
  `PullRequestToolResultLink.swift`, and their dedicated tests.
- Design detail: `docs/TERMINAL_ARCHITECTURE.md`.

### ARCHITECTURE

The C bridge and `PseudoTerminalSession` own Darwin handles, readiness sources,
the bounded two-MiB byte ring, process identity and reaping. `TaskTerminalService`
owns Task identity, durable metadata, transport lifecycle and event fan-out.
`TaskTerminalEmulator` owns bounded presentation state; the AppKit surface only
renders that state and encodes user keys. `BuiltinToolFactory` exposes sanitized
structured operations through the existing registry/permission/executor chain.

Metadata persists identity, dimensions, state, relative cwd, workspace and
capability binding, clear/reconnect counters and raw offsets, but never commands,
environment values, PID/descriptor authority or raw output. Navigation detaches
only the subscriber, not the service. This makes persistence and reconnect
semantics explicit rather than pretending that a new App process owns an old
PTY.

The Review View never parses shell output or executes Git directly. It asks the
Task-bound `ReviewService` for an immutable document, displays presentations
derived from that model, and submits a typed mutation carrying both the selected
identity and generated patch. `AgentViewModel` revalidates the Task/workspace
binding before and after each suspension, resolves the same Task-owned
`GitService` used by Agent tools, and persists any returned change record.

Review Agent is a task type, not a prompt convention. `AgentSession.taskType`
stores the locked source Task and normalized workflow request. Runtime filters
tool definitions, rejects hidden tools in the executor as a second boundary,
tracks the exact source receipt, discards prose-only premature completion and
persists only validated structured findings. PR Review reads through the
per-run configured provider; credentials never enter the request, Session JSON,
settings JSON or model context.

### RISKS

- Descriptor/reaper ownership, output draining without a consumer, ordinary and
  new-session descendant termination, and cross-session kill isolation now have
  focused tests. Crash-at-every-stage and long soak evidence remain residual.
- ANSI/VT output is untrusted. OSC clipboard/title/link actions are ignored, the
  UI disables automatic links/data, escape strings are bounded, and model reads
  use a separate inert/redacted renderer. Broader hostile-output fuzzing remains.
- Ordered pane writes, per-entry transitions, clear generation, stable offsets,
  and stale-attachment checks mitigate reordering. App-crash reattachment is
  explicitly unsupported rather than guessed.
- File/hunk fingerprints plus `git apply --check` reject a stale Review preview;
  the operation can still conflict if an external process writes between checks,
  so the Git command gate and transaction rollback remain part of the boundary.
- Structured Review source completeness is host-owned: untracked files and
  artifact pages are included, incomplete pagination cannot authorize a result,
  and fallback copy is generated from the actions actually available.
- Last Agent Turn is accepted only after stable HEAD/file-content identities and
  two identical complete renders. Persistent concurrent modification fails
  closed instead of freezing a mixed turn.
- Merge/rebase/cherry-pick lifecycle markers are repository-controlled state.
  The host inspects fixed metadata paths and fails closed on ambiguous or unsafe
  node types; focused conflict/continue/abort and cancellation cases pass.
- Push/PR actions create external effects. They do not inherit local execute
  permission, are non-interactive, do not expose configured remote URLs or
  credentials to model context, and do not claim Undo for provider state.
- Review Task checkout borrowing must never become lease ownership. Source
  archive/delete/handoff and a competing writable run are blocked while a
  dependent Review is active; dedicated isolation tests cover both directions.

### IMPLEMENTATION PLAN

1. **Completed:** audit the pipe transport and add a Darwin `forkpty` boundary
   behind a platform-neutral backend seam.
2. **Completed:** bounded raw PTY I/O, resize, signals, exit/reaping,
   process-tree cancellation, sandboxing and deterministic transport tests.
3. **Completed in the development tree:** Task-scoped multi-session service,
   atomic metadata, six tools, native pane, safe emulator/surface, lifecycle
   guards and focused UI smoke.
4. **Completed:** closed Advanced Git API, fixed operation safety, bounded
   snapshots, network policy and merge/rebase/cherry-pick lifecycle operations.
5. **Completed:** five complete Review sources, parser/presentations, native
   pane, stable file/hunk actions, structured comments and globally consistent
   frozen Last Agent Turn.
6. **Completed for the Phase B local scope:** isolated Review Task/Runtime
   contract, complete source receipts, structured findings, provider-neutral PR
   protocol, GitHub adapter, Keychain configuration, bounded tools and safe
   result links. A live external PR mutation remains deliberately unexecuted.
7. **Completed:** integrated regression, archive tests, production build/sign/
   extract verification, packaged UI smoke, artifact size/hash and rescore.

### TERMINAL TEST EVIDENCE

- 21 PTY tests pass: controlling TTY/process group, raw and canonical input,
  Ctrl-C/Ctrl-D, interactive shell, signals, immediate exit, resize/SIGWINCH,
  bounded unconsumed output, ordinary and `setsid` process-tree cleanup,
  session isolation, sandbox escape rejection and the real-program matrix.
- 11 emulator tests pass: split Unicode and malformed input, C0/CSI/SGR,
  private modes/alternate screen, ignored OSC, bounded escape recovery,
  scrollback/copy/search and resize.
- 5 service, 5 structured-tool/security, 3 ViewModel lifecycle, one pane-model,
  and one surface-rendering test pass, for 47 focused Terminal cases total.
- The full application and C bridge build cleanly. Packaged 1.4.0 UI smoke
  exercised a real shell, ANSI output, Review/Terminal navigation continuity
  and exact unstaged Review content.

### REVIEW AND PR TEST EVIDENCE

- Review workflow and structured-data suites are included in the 504-test
  integrated gate. They cover source-before-result,
  PR network-source selection, rejection of premature prose, receipt path
  scoping, retry reconstruction and invalidation by a new user turn.
- The focused `AgentViewModelReviewWorkflowTests` run passed 4/4; its adjacent
  filter set passed 16/16. The Review Task contract passed 5/5, tool isolation
  passed 4/4, and Agent detail surface policy passed 2/2.
- A combined Review/Builtin/PR-configuration run passed 15/15. Because its
  original exact filter cannot be reconstructed from the retained evidence,
  this audit does not relabel it as a standalone 19/19 PR suite.
- The integrated release gate and packaged UI smoke passed. No deterministic
  test performs a live provider mutation.

### ADVANCED GIT EVIDENCE

- The source and dedicated test suite cover the closed operations, reference/
  branch/tag/remote validation, non-interactive network behavior, snapshots,
  content-filter/attribute refusal, operation-state markers, conflicts,
  cancellation and permission classification.
- The final dedicated `AdvancedGitServiceTests` suite passed 21/21. A combined
  Advanced Git, persistence, handoff and worktree-lease gate passed 37/37.

### PHASE D IMPLEMENTATION STATE — DEVELOPMENT-GATED

- Skills now have bounded global/project/repository/nested/plugin discovery,
  deterministic precedence, explicit and automatic selection, transient
  provider instructions, durable loaded metadata, and an exact-ID resource
  read boundary that rejects traversal and symlink escape.
- Plugins are no longer represented by MCP alone. A typed manifest and manager
  cover Local, Git, HTTPS manifest, and registry inspection; requested
  permissions; package/path/size/minimum-version validation; and atomic install/
  update/enable/disable/uninstall state with rollback/quarantine behavior.
- Plugin tools and hooks use the existing tool registry, permission manager,
  executor, network approval, timeout, and redaction chain. Lifecycle hook
  schemas are host-only and require an exact plugin/index/event/Task capability;
  declared binaries run without a shell in permission-derived macOS sandboxes,
  and continue, fail-task, and disable-plugin policies are explicit.
- OAuth connector configuration uses atomic non-secret JSON, PKCE S256, bounded
  HTTPS exchange, and Keychain-only credentials. Plugin MCP servers retain
  owner IDs so lifecycle sync cannot remove manual servers.
- Extensions UI and loaded-Skill Task metadata complete the intended vertical
  presentation path. Focused tests cover discovery/resource containment,
  transient instruction replay without Session pollution, terminal hook
  delivery, plugin lifecycle/path/version/permission rejection, hook visibility/
  failure/logging, OAuth PKCE/secret separation, and MCP ownership.
- This section's focused tests, combined Swift regression, optimized development
  build, package and ad-hoc signature gate pass. It does not change the formal
  68.5 production-credit score without live ecosystem acceptance. See
  [`PLUGIN_ARCHITECTURE.md`](PLUGIN_ARCHITECTURE.md).

### PHASE F IMPLEMENTATION STATE — DEVELOPMENT-GATED / LIVE HOST PENDING

- Automation now has a versioned atomic store, actor scheduler, durable
  occurrence claims, bounded run history, restart interruption recovery,
  explicit missed-run policies, manual idempotency, concurrency bounds, and
  one-time/interval/five-field-cron/event schedules.
- Seven typed action kinds create ordinary durable Agent or Review Tasks. Goal,
  Skill, project job, tests, repository check, and Changes Review reuse their
  existing Runtime contracts; Review is not simulated by prose. Recurring or
  event-driven mutation-capable actions are forced into a dedicated managed
  worktree, while Review borrows its exact source read-only.
- The Automation Settings pane provides definition CRUD, enable/disable, Run
  Now, cancellation, history/log/result/change/worktree inspection, opening the
  owning Task, and exact dedicated-worktree discard. Existing Task surfaces
  provide Diff/Review/Commit/PR after a run; there is no separate unattended
  publish pipeline.
- A typed event ingress preserves seams for GitHub, Slack, Gmail, filesystem,
  and webhook producers. No producer adapter or listener exists yet; payload is
  used only for bounded exact matching and cannot become command text.
- The notification service implements Task completed, Approval required,
  Automation completed/failed, Subagent blocked, and Remote Agent waiting.
  Authorization is explicit, payload/deep-link metadata is bounded, delivery
  failure cannot alter durable execution state, and a click routes to the
  exact Task through a typed in-process handler.
- Remote Runner Settings atomically persists non-secret SSH configuration and
  keeps private keys in Keychain. The fixed system-OpenSSH invocation uses
  strict selected `known_hosts`, disables password/interactive authentication,
  forwarding, local commands and user configuration, and produces a
  post-authentication host/user/canonical-root receipt. Configuration,
  credential and exact trust-file bytes form one pinned run authority; an
  authority change cannot silently alter a backend minted for an earlier run.
- SSH Tasks carry only an opaque runner ID. Runtime injects its exact remote
  identity into every tool/approval context, verifies a receipt before each
  run, hides local filesystem/Git/Terminal/Browser/Computer Use/subagent/plugin
  execution, and uses the remote status/diff/test tools where the Runtime needs
  those lifecycle operations. Approval cards show backend, host/port, user,
  path, command, and cwd.
- The registered SSH surface has 16 closed tools: seven filesystem, five Git,
  build, test, bounded shell, and one-shot PTY. Filesystem paths remain below
  the verified root; generic access rejects `.git`, and mutation rejects
  AppleDouble, traversal, symlink-parent, special-file, and oversized input.
  A shared canonical-root lease serializes Luma Chat operations and holds while
  ordinary child process groups are cleaned up. V1 Git requires the configured
  root itself to be the repository top-level and is status/diff/log/add/commit; file
  transfer is capped at 4 MiB, and build/test targets SwiftPM or an Xcode scheme.
- Explicit Mac/managed-Worktree to SSH and SSH back to the original Local
  checkout use a bounded same-HEAD snapshot rather than assuming shared files.
  Each snapshot is at most 4 MiB and the paired desired/baseline transaction is
  at most 8 MiB. Both exclude `.git`, credentials, arbitrary ignored caches,
  special files, symlinks, and `._*`; apply and idempotent rollback share a
  transaction UUID and refuse state outside their exact owned transitions.
- `handoffToRemote` and `handoffFromRemote` use the durable Task handoff
  journal, pinned remote baseline/authority and integrity-bound recovery snapshots. Startup compares the Session
  with the recorded source/destination and transaction stage, completes only
  exact committed cleanup, and otherwise performs fingerprint-gated rollback
  or preserves contradictory evidence instead of guessing. Unresolved evidence
  blocks both its Task and referenced runner from new host operations.
- The remote PTY is deliberately one-shot. There is no persistent Task Terminal
  input/resize/reconnect/scrollback transport. `.futureCloud` remains only a
  versioned fail-closed seam; no relay or hosted service is claimed.
- Focused scheduler, notification, SSH store/transport/backend/tool and
  migration tests pass in the combined development gate. Deterministic remote-
  disconnect injection also passes. Real-host acceptance, native UI E2E,
  every-stage handoff/worktree injection, and Automation/SSH soak remain.
- Phase F therefore adds no formal production score yet. See
  [`AUTOMATION_REMOTE_ARCHITECTURE.md`](AUTOMATION_REMOTE_ARCHITECTURE.md) for
  the ownership chains, truthfulness boundary, requirement matrix, and exact
  remaining work.

### TEST PLAN

- PTY signal crash and updater post-swap disk-full injection now pass; broader
  storage injection, multi-hour soak and non-Darwin backends remain. Relaunch
  semantics are explicitly metadata-only and tested.
- Advanced Git retains only the live remote-mutation limitation and later
  hostile-config/failure-injection expansion.
- Review retains crash/disk-full expansion and broader UI accessibility work;
  untracked, artifact completeness, fallback contract and globally consistent
  Last Agent Turn regressions are covered.
- PR: retain controlled provider tests and add an explicitly authorized
  push→create→structured-link→Review PR acceptance run outside deterministic
  unit tests.
- Current development regression/release gate completed: 744 tests, 1 explicit
  skip, 0 failures; 6/6 archive contract tests; optimized build/ad-hoc sign/
  archive round-trip; SBOM/provenance/security audit; artifact SHA-256 recorded.
  The earlier Phase B packaged UI smoke remains historical evidence; the current
  1.4.1 combined gate did not rerun native UI smoke.

## Score change policy

Future score changes require a working vertical slice, persistence and recovery,
UI, tests, and release evidence. Reserved enum cases, mock screens, protocols,
or unexecuted tests do not earn points. A release note must state remaining
limitations without translating later planned work into a blocker.
