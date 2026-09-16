# Luma Chat — Unreleased development notes

Checkpoint date: 2026-09-10

Status: Phase B is release-ready as Luma Chat 1.4.0 / build 7. Detailed evidence
is in
[`RELEASE_NOTES_1.4.0.md`](RELEASE_NOTES_1.4.0.md).

The validated artifact is `dist/LumaChat-1.4.0-arm64.zip` (7,315,724 bytes,
SHA-256 `224d6942969670cd090797416bdcfb979a79387a827b68fa8c184d64d871b2b0`).
It is ad-hoc signed and has not been published or tagged.

## Phase C — Subagents

- Added durable parent/child Agent sessions and the seven orchestration tools:
  spawn, message, wait, list, cancel, resume, and structured result collection.
- Added a priority/FIFO actor scheduler with global, provider/model, and parent
  concurrency ceilings; step/context/token/time budgets; timeout, failure
  isolation, restart interruption recovery, and parent cancellation propagation.
- Read-only children receive a bounded directory/tool/MCP/network scope;
  writable children receive a UUID-owned managed worktree. Registry publication
  and execution both enforce the scope fail-closed.
- Added Sidebar parent/child grouping and a live Subagent status surface with
  navigate/cancel/resume actions.
- Added focused scheduler, aggregation, recovery, timeout, cancellation,
  context-ownership, provider-overload, and isolation tests. Per the combined
  development request, execution is deferred to the final Phase C–H gate.

## Per-model parameters — priority feature

- Added durable, endpoint-namespaced backend/provider + exact-model Custom
  profiles to the existing `settings.json`; absence is the durable Auto state.
- Added centralized exact-model, family, backend and generic recommendation
  rules, separate backend/model context ceilings, numeric validation, and
  capability-aware parameter omission.
- Added a shared live editor to Chat, Agent and Settings with Auto/Custom state,
  Thinking, Reasoning Effort, context, max output, Reset to Auto and expandable
  advanced sampling controls.
- Classic Chat now uses the same effective profile for context selection and
  request encoding. Agent freezes it per run and reuses it for retry, resume,
  output continuation and every tool-call round.
- Added focused migration, isolation, reset, persistence, request-omission and
  multi-turn Agent profile tests. Execution remains deferred to the final
  combined gate requested for all development phases.

## Phase D — Skills, plugins, hooks, and OAuth connectors

- Added bounded `SKILL.md` discovery across global, project, repository,
  nested, and enabled-plugin sources. Explicit `$skill` invocation and
  description matching load only a small host-selected set; instructions stay
  transient while Session metadata records what was loaded.
- Added a fail-closed Skill resource tool that accepts only an exact Skill ID
  loaded for the current Task and rejects traversal, symlink, non-regular,
  oversized, and non-UTF-8 resources. Skill scripts are never auto-executed.
- Added a real plugin manifest/manager layer, separate from MCP, with Local,
  Git, HTTPS manifest, and user-selected registry sources; bounded package and
  declaration validation; explicit permission review; and atomic install,
  update, enable/disable, failure, and uninstall records.
- Plugin executable tools and lifecycle hooks register through the existing
  ToolRegistry → PermissionManager → ToolExecutor boundary. They execute an
  exact package-contained binary without model-built shell text, inside a
  permission-derived macOS sandbox with bounded non-blocking JSON I/O, minimal
  environment and timeouts, and mark external effects non-undoable.
- `minimumLumaChatVersion` is enforced during inspection, install/update, and
  launch reload instead of being presentation-only.
- Added the complete typed lifecycle event vocabulary, host-only hook
  invocation capabilities, continue/fail-task/disable-plugin policies, and
  bounded redacted history under project `tmp`.
- Added OAuth connector configuration, PKCE S256 authorization/code exchange,
  and Keychain-only access/refresh token storage. Plain settings and model
  context contain no OAuth credentials.
- Plugin-declared MCP servers now retain `ownerPluginID`, allowing extension
  refresh/uninstall to change only owned servers while preserving manual MCP
  configurations and their existing Keychain handling.
- Added the Extensions management surface plus focused Skill, runtime
  transient-injection/terminal-hook, plugin/hook, OAuth, and MCP ownership
  tests. Test/build execution remains deferred to the
  requested final combined Phase C–H gate. See
  [`PLUGIN_ARCHITECTURE.md`](PLUGIN_ARCHITECTURE.md).

## Phase E — Browser/CDP and Computer Use 2.0

- Added Task-owned Chromium/CDP sessions with isolated temporary profiles,
  explicitly named persistent profiles and opt-in loopback-only attachment to an
  existing debugging session. Profile/endpoint authority comes only from the
  persisted host Settings snapshot, rotates on change, and cannot be selected by
  model arguments.
- Added bounded navigation/tabs, DOM/layout and Accessibility projections,
  semantic/text/CSS targeting, screenshots, console/page errors, network
  request/response/status/safe-header inspection, performance metrics, bounded
  JavaScript and redacted cookie inspection/clearing.
- Added approved managed-session downloads into project `tmp`, with browser GUID
  paths, timeout/size/cancellation limits, no-follow regular-file verification,
  SHA-256 receipts and explicit refusal for attached external sessions.
- Page output is projected before retention, secrets and URL query credentials
  are redacted, unknown headers are hidden, request bodies/cookies are not
  retained, and every model-visible result uses a valid bounded untrusted-data
  envelope. Metadata/link-local navigation is blocked and final redirects are
  revalidated.
- Added Browser screenshot annotation UI, bounded durable structured context and
  strict Browser-session plus owning-Task isolation. See
  [`BROWSER_ARCHITECTURE.md`](BROWSER_ARCHITECTURE.md).

- Added bounded enumeration and explicit selection for multiple safe on-screen
  App windows. The exact CG window ID/owner/geometry remains capture-bound;
  omitting `window_id` works only for a single-window App.
- Added bounded Accessibility snapshots that expose opaque capture-bound IDs for
  a small host-owned press/focus role set. Text-field values and secure fields
  are never exposed or targeted, and AX identity/path/frame are revalidated.
- Added semantic background actions plus read-only state verification. They
  record foreground stability, selected-window geometry, and element identity;
  semantic actions do not activate the App before acting.
- Added a host-computed scoped Always Allow policy and approval-card scope/
  semantic-frame presentation. Only observation and verification are eligible;
  every mutation stays `dangerous`, requires a fresh 30-second capture and
  one-time approval, and consumes that capture. Eligible session grants use the
  exact built-in tool/arguments, remain local to this host process and are not
  restored after relaunch.
- Preserved the exact bundle allowlist, multiple-process refusal, blocked Agent,
  terminal, System Settings, login/security/password/Keychain/installer apps,
  secret-like typing refusal at both tool and service boundaries, secure focused-
  field refusal, Screen Recording/Accessibility checks, screenshot-backed
  approval, and explicit `External Side Effect · Not Undoable` presentation.
  Focused tests were added but not executed under
  the combined Phase C–H validation deferral.

## Phase F — Automations, notifications, and SSH Remote Runner

- Added a durable, versioned Automation store and actor scheduler with
  one-time, anchored interval, five-field cron, and typed event schedules;
  skip/run-once/bounded-catch-up policy; durable occurrence deduplication;
  restart interruption recovery; cancellation; bounded concurrency; and full
  per-run status/log/result/change/worktree history.
- Added Automation actions for Agent Task, Goal, Skill, project job, tests,
  repository check, and typed Changes Review. Each run creates an ordinary
  persisted Task. Recurring or event-driven mutation-capable runs are forced
  into dedicated managed worktrees instead of the primary checkout.
- Added an Automation Settings surface for CRUD, enable/disable, Run Now,
  cancellation, history/log inspection, opening the owning Task, and exact
  worktree discard. Existing Task Diff/Review/Commit/PR surfaces remain the
  post-run publication path; there is no new unattended publish pipeline.
- Added a bounded typed event ingress for future GitHub, Slack, Gmail,
  filesystem, and webhook producers. Producer adapters/listeners are not
  included; payload only participates in exact host-side filters.
- Added Task completed, Approval required, Automation completed/failed,
  Subagent blocked, and Remote Agent waiting macOS notifications. Authorization
  is requested only by an explicit Settings action, delivery failures do not
  change durable execution state, and typed click routes select the owning Task.
- Added Remote Runner Settings, versioned atomic non-secret SSH configuration,
  Keychain-only private keys, system ssh-agent support without forwarding,
  strict selected `known_hosts` verification, and bounded host/user/canonical-
  root receipts. Run identities now pin one coherent configuration, credential,
  and exact `known_hosts` snapshot; changing any authority input invalidates
  matching instead of silently affecting an already-approved backend.
- Added 16 SSH Task tools: seven filesystem operations; Git status/diff/log/add/
  commit; SwiftPM/Xcode build and test; bounded shell; and bounded one-shot PTY.
  Runtime propagates the exact SSH identity into approvals, whose cards show
  backend, host/port, user, path, command, and cwd. Local filesystem/Git/
  Terminal, Browser, Computer Use, subagent launch, and executable plugins do
  not silently run on the Mac for a remote Task.
- Added explicit Mac/managed-Worktree to SSH and SSH back to the original Local
  checkout migration. Each verified same-HEAD snapshot is capped at 4 MiB and
  the paired desired/baseline transaction request is capped at 8 MiB
  and excludes `.git`, credentials, arbitrary ignored caches, symlinks, special
  files, and AppleDouble entries; rollback and local CAS reject state that
  changed after capture. Apply and idempotent rollback use the same transaction
  UUID and recognize only owned clean/indexed/full states. Both directions persist staged handoff journal and
  integrity-bound recovery evidence, so relaunch either finishes exact
  committed cleanup, performs a fingerprint-gated rollback, or preserves an
  ambiguous third state for repair instead of guessing. Unresolved evidence
  blocks both the affected Task and referenced runner until recovery succeeds.
- All SSH workspace operations now share a canonical-root directory lease;
  child cwd resolution is descriptor-relative and no-follow, descendants that
  remain in the child process group are terminated before release, generic filesystem tools reject
  `.git`, and the Git surface requires the workspace itself to be the repository
  top-level. Host-owned remote helpers use fixed `/usr/bin/python3` rather than
  a mutable login `PATH` lookup.
- Remote PTY is intentionally one-shot and has no persistent input, resize,
  reconnect, or scrollback contract. `.futureCloud` is still only a fail-closed
  seam: no secure relay, hosted runner, or cloud fallback is claimed.
- Focused Automation, notification, SSH store/transport/backend/tool, and
  migration tests have been added but not executed. The combined regression/
  build/package gate, live SSH-host acceptance, UI/ViewModel E2E, disconnect and
  every-stage failure injection, and soak remain pending. See
  [`AUTOMATION_REMOTE_ARCHITECTURE.md`](AUTOMATION_REMOTE_ARCHITECTURE.md).

## Phase G — CLI, App Server, SDK, integrations, and artifact workflows

- Added the packaged `lumachat` CLI with `chat`, `agent`, `exec`, `resume`,
  `tasks`, `projects`, `skills`, `mcp`, and `plugins`. It shares the desktop
  Agent runtime and enforces exact Task/backend/model/workspace identity,
  bounded UTF-8-safe JSON/JSONL output, stable exit categories, and fail-closed
  non-interactive approval handling.
- Added a loopback-only authenticated App Server with a language-neutral v1
  contract, Task/message/status/diff/control and approval routes, replayable
  monotonic SSE, request IDs, idempotency, heartbeats, and bounded request,
  response, buffer, idle, and write behavior.
- Added the Swift client SDK with strict origin, redirect, media type, length,
  version, request, Task/backend/model, and SSE-sequence checks.
- Added a thin VS Code extension for bounded selection/file requests, fixes,
  Task control, diff display, review, and constrained patch application. It
  rejects ambiguous multi-root scope, unsafe paths and modes, symlinks, stale
  Tasks, truncated output, and manifest/header mismatches.
- Added a GitHub Action that reviews a pull request using only the configured
  user-controlled backend/model in Plan mode, validates exact Task scope on
  every poll, and stops the exact Task on failures without auto-approval or
  cloud fallback.
- Added the built-in `com.lumachat.artifact-workflows` plugin with PDF,
  document, spreadsheet, presentation, image, visualization, and site Skills.
  All seven use the normal plugin permission/state lifecycle and are copied and
  byte-compared by release packaging.
- Added focused Swift/Node/schema/packaging tests for these paths. Per the
  requested sequencing, no test, lint, typecheck, build, or packaging command
  has run yet; validation remains part of the final combined Phase C-H gate.

## Candidate scope

- Real Task-scoped Darwin PTYs, native multi-terminal pane and six structured
  terminal tools.
- Closed Advanced Git operations for fetch/pull/push, switch/delete/hard reset,
  merge/rebase/cherry-pick lifecycle, stash, tags and remotes, with fixed
  permission classes and bounded snapshot policy.
- Five-source Review pane with file/unified/side-by-side presentation,
  file/hunk Stage/Unstage/Revert and durable typed inline comments.
- Separate persisted Review Changes/Commit/Branch/PR Tasks with source receipts,
  isolated tools and validated structured findings.
- Provider-neutral PR service, GitHub adapter, scoped Keychain token, bounded
  GET/context/Create tools, Settings integration and validated structured links.

## Phase B gate evidence

- Isolated integrated suite: 504 tests, one explicit environment skip, zero
  failures, 177.768 seconds.
- Direct Task Terminal matrix: 47 cases, including real `vim`, Python REPL,
  `nano`, `htop`, `git add -p`, offline SSH configuration and package prompt.
- Advanced Git: 21/21; combined persistence/handoff/lease gate: 37/37;
  secure filesystem/change gate: 17/17; archive tests: 5/5.
- Production arm64 build: 125.87 seconds. Bundle and extracted-bundle signature,
  plist, exact ZIP manifest/mode, CRC and AppleDouble checks passed.
- Packaged native UI smoke verified no implicit Task, explicit Task creation,
  real unstaged Review content, real PTY/ANSI output, panel continuity and clean
  quit.

## Work continuing after 1.4.0

The master parity program has eight phases, A-H. A and B are release-gated;
Phases C-G are present in the development tree with combined validation
deferred. Phase F still has the explicit live-host, failure-injection, UI-E2E
and soak gates listed above, while Phase G still needs its compiler, Node,
schema, packaged launcher and live transport gates. Work now continues with
Phase H production signing, notarization, update/rollback, cross-platform
preparation, soak and security audit.
