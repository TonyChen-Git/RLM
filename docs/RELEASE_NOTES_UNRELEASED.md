# Luma Chat — Development integration history

## MCP 1.4.8 published compatibility and recovery — updated 2026-10-24

The automatic `v1.4.8` tag CI reruns also passed on the same commit:
macOS 962 Swift tests (two skips, zero failures), optimized compilation and
35 Python contracts; Linux worker 10/10. Their separate receipts are recorded
in the version validation file.

The exact-tag 1.4.8 2h → 8h → 24h → 72h soak sequence was launched on
October 24 at 20:21 Asia/Taipei. Its first run is preparing; no duration is
qualified or transferred from earlier versions. Immutable launch evidence and
the live state path are recorded in [validation/1.4.8.json](validation/1.4.8.json).


- Added the stable MCP `2026-07-28` stateless core profile for STDIO and
  Streamable HTTP, retaining `2025-06-18` legacy compatibility. Settings
  persists Automatic, legacy or stateless selection and shows the negotiated
  protocol. Existing records and plugin declarations default to legacy;
  newly created Settings drafts default to Automatic.
- Stateless operations use read-only `server/discover` and per-request version,
  empty client capabilities and client identity metadata. Core tools,
  resources, resource templates and prompts use bounded validation; HTTP
  supports JSON and request-scoped SSE without protocol sessions or GET
  reconnection. Only compatible discovery-probe failures can select a fresh
  legacy lifecycle; authentication failures do not trigger a downgrade.
- Added bounded `Mcp-Method`, `Mcp-Name` and schema `x-mcp-header` projections.
  Invalid annotated tools are excluded with redacted diagnostics while valid
  discovery results replace the registry. Protocol-owned headers cannot be
  overridden by configured values.
- Removed automatic operation replay after session expiry or uncertain
  transport failure. Failed connections retire tool authority and require
  explicit reconnect; users must verify remote outcomes before retrying.
  Discovery tokens and exact descriptor checks reject retained adapters after
  schema/permission changes. Failed tool discovery disables execution until
  discovery succeeds. STDIO probe recovery waits for complete old-process
  teardown so delayed callbacks cannot kill its replacement.
- MCP settings changes disconnect affected clients, invalidate approvals and
  publish only committed configuration. Ambiguous writes/readback failures
  leave affected servers disconnected. Staged Keychain credential updates
  preserve the metadata/credential recovery boundary without persisting secrets
  in JSON or logs.
- Modern client capabilities intentionally remain empty. MRTR `input_required`,
  sampling, elicitation and other unadvertised client capabilities fail with
  an explicit diagnostic; they cannot supply input or grant execution rights.
- Corrected connection-button and diagnostic truncation found by the first
  packaged MCP Settings UI run. Controls wrap with available width and complete
  diagnostics remain visible; the first candidate retains its separate evidence.

These changes are published as **1.4.8 build 15**, beyond the immutable
1.4.7 binary. The frozen focused run passes **140 MCP/Phase D tests, zero skips
or failures**. The separate full candidate gate passes **962 Swift tests and
48 Python contracts, each with one skip and zero failures**, plus successful
debug/optimized compilation, ad-hoc signing and archive/security checks.
The final gate includes the Settings layout fix. Its complete log reaches the
release footer; the controller exit code was not retained. October 24 recovery
matched the starting source receipt and repeated signature, ZIP and CLI checks.
The first candidate and stale controller record remain separate evidence.
Local Node contracts pass **17/17 VS Code** and **14/14 GitHub Action**.
Final packaged MCP native UI passes with an isolated loopback fixture:
legacy settings survive restart, save/mode switching disconnects the old
connection, modern filtering diagnostics and button labels display completely,
Refresh Discovery and Reconnect succeed, About reports 1.4.8 (15), and quit
returns 0. HTTP metadata was checked against 20 captured requests. This limited
scope does not qualify external providers or every Phase I–Q UI.
The regular [v1.4.8 release](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.8)
was published from `888addf6219a29487b2f45e91d5b5b9c39319242`; all five downloaded
assets match. Exact-commit hosted macOS CI passes 962 Swift tests (two skips,
zero failures), the optimized desktop build and 35 Python contracts; Linux
worker CI passes 10/10. The macOS skips are unavailable Homebrew `htop` and
the intentionally sandbox-blocked setuid system `top`. Source-bound soak
remains unqualified.
Exact evidence and artifact hashes are recorded in
[1.4.8 release notes](RELEASE_NOTES_1.4.8.md) and its
[validation receipt](validation/1.4.8.json). Official protocol references and
the supported profile are recorded in
[Phase L–Q architecture](PHASE_L_Q_ARCHITECTURE.md).

The prior corrected-test 8h run
`ccb2e92e-d3da-428c-af8f-25fd86ca7031` was interrupted by SIGTERM at
`2026-10-21T03:17:32Z`, sender unknown: 5,988.242 continuous seconds, 46 cycles,
368 completed / 369 attempted shards, exit 130. It does not qualify;
24h/72h did not start and that historical sequence is stopped. The controller's final
state is `tmp/release-1.4.7-corrected-soak-suite/state.json`. The original
exact-tag 1.4.7 2h qualification remains valid only for that historical source.

External model/SSH/MCP/test-repository acceptance remains `deferred_by_user`.
Developer ID/notarization/stapling/production feed and signed-update acceptance
remain `not_required_for_private_use`, not passed. Windows desktop work is
outside this round; Slack/Gmail remain future provider evaluation.

## Published 1.4.7 and earlier evidence

The [1.4.7 corrective patch](RELEASE_NOTES_1.4.7.md) was published on
October 19 as a regular GitHub Release from `main`. Final source `eeddc75` passes the complete local release gate:
896 Swift tests and 48 Python contracts, each with one skip and zero failures;
optimized arm64 compilation, ad-hoc packaging and archive/security checks pass.
Hosted macOS CI passes 896 tests, two skips and zero failures, optimized
compilation, archive 7/7 and soak harness 28/28 contracts. Linux worker CI passes
ten tests, zero skips/failures, in 5.348 seconds. The HTTP fixture preserves byte
order and verifies completion while its response stream remains open.
All five final artifact hashes match the preceding candidate; exact archive and
binary equivalence ties the final package to the October 19 limited native
smoke (startup, idle Task, About 1.4.7 (14), clean quit). This is not a second UI
run or external acceptance. Uploaded asset sizes/digests are verified.
Version-bound soak was pending at publication; the exact tag subsequently
qualified its 2h run, while longer runs remain unqualified as recorded in the
[parity audit](CODEX_FULL_PARITY_AUDIT.md).
Exact attempts are in the [1.4.7 validation receipt](validation/1.4.7.json).
Published 1.4.6 evidence follows.

The Phase I–Q work below is integrated into the
[1.4.6 build 13 release](RELEASE_NOTES_1.4.6.md), published on October 15 as a
regular GitHub Release from `main`. Its local release gate and limited native
UI smoke pass:
886 Swift tests (one skip), 48 Python contracts (one Linux-only skip), VS Code
17/17 and GitHub Action 14/14, all with zero failures. Ad-hoc arm64 packaging,
archive/security checks, the extracted CLI version and About 1.4.6 (13) pass;
the App exits cleanly. Linux worker CI now passes on tag and main (the tag
runs 10 tests with zero skips/failures). Hosted macOS CI first failed with
Swift 6.1.2 / Xcode 16.4 signal 11; Xcode 26.3 / Swift 6.2.4 then exposed
ordinary type-checking errors. Post-publication `main` commits `c63f53a`,
`8925875`, `081300c` and `0d9364b` pin that toolchain and make product/test
calculation types explicit while preserving order and assertions. The final
local focused run passes 45 tests, zero skips/failures (40.665 seconds);
the complete hosted run then failed with 886 tests, two skips and eight
failures (four unexpected). Full failure history is retained in the validation
receipt; the exposed environment/sandbox/MCP issues are corrected in 1.4.7. These changes are outside the immutable release ZIP.
A fresh sequence against the exact release source launched October 15 at
15:16:37 Asia/Taipei; actual 2h measurement began at 15:22:11 after inventory
preparation. Its 2h run completed and qualifies: 7,227.507 seconds, 48 cycles,
386 shards, zero failures. The following 8h run was interrupted and does not
qualify; 24h/72h never began and no run remains active. These are 1.4.6 results,
not 1.4.7 qualification. Longer soaks, external acceptance and Apple production
signing/notarization remain pending. This UI run did not
exercise Browser operations. Exact receipts and ZIP hash are in the version's
release notes; historical 1.4.5 receipts below keep their original scope.

## Browser lifecycle fix and development gate — 2026-10-14

- Fixed the persistent CDP WebSocket being ended by a 30-second URLSession
  resource timeout during approval waits. Removed that resource-timeout
  override while keeping bounded 30-second command deadlines; completed sockets
  fail immediately and unexpected receive cancellation cleans up pending work.
- Five real loopback lifecycle tests cover cancellation, peer closure and
  32-second idle reuse. The cancellation regression failed two assertions
  before the fix. All five pass in the final gate (32.139 seconds), and the
  Browser soak filter includes them. Temporary DEBUG tracing was removed
  before freezing the 340 source/test/script/config files.
- A debug App with real Chrome passes open, snapshot, find (four matches),
  screenshot and close after a 53.18-second gap between Browser commands.
  The actual PNG and annotation pane were checked; App exit was 0 and owned
  Chrome processes were cleaned up
  (`tmp/phase-iq-oct14-browser-fixed/acceptance.json`). This used local model
  and page fixtures and a debug binary with temporary metadata tracing.
- The final optimized arm64 package also passes all five real Chrome operations
  using local model/page fixtures. The observed wait before snapshot approval
  exceeded 68.38 seconds, persisted execution gap was 79.31 seconds and the
  snapshot completed in 0.059 seconds. The actual 1280×657 PNG and native
  Browser annotation pane were verified, including a CUA screenshot of the UI.
  App exit was 0; owned Chrome and fixture server processes were cleaned up
  (`tmp/phase-iq-oct14-browser-package/acceptance.json`). This is local integration
  acceptance; live model and external-provider acceptance remain pending.
- The October 14 development gate passes **886 Swift tests, one environment
  skip, zero failures** (258.252 seconds) and **48 Python contracts, one
  Linux-only skip, zero failures**: archive 7, soak 28, security 3 and worker 10.
  The optimized arm64 build, ad-hoc signing, plist and ZIP/extracted-archive
  verification, and security audit pass; the runner exited 0
  (`tmp/phase-iq-oct14-release.log`, `tmp/phase-iq-oct14-release-result.json`).
- Development ZIP SHA-256:
  `7c5c0716e30becfbb600f06db6f37516cc5560cca88783701aa5019b7a4de3b0`.
  Frozen receipt: `tmp/phase-iq-oct14-source-receipt.json` (340 files).
  The `c332...` package and 881-test gate below remain historical evidence.
- The background **2h → 8h → 24h → 72h multi-day** soak sequence launched
  on October 14 at **15:24 Asia/Taipei**. Its 2h run **completed and qualifies**
  at 17:29:56: **7,207.592 measured seconds, 48 complete cycles, 389 completed
  shards, zero failures** (`tmp/soak/19124a61-51f3-4eec-8bd6-e2679e8327e2/`).
  The subsequent 8h run was interrupted after 669.134 measured seconds and
  does not qualify (`tmp/soak/f1c364d4-1834-455e-b29b-01082173cd9d/`). The
  sequence is stopped; 24h and 72h never started. Controller receipt:
  `tmp/phase-iq-oct14-soak-suite/state.json`. The two older October 4 runs
  remain non-qualifying. These results precede the 1.4.6 version bump and are
  not credited to a new version's soak. External live acceptance, executed
  Linux CI and production signing/notarization/feed/rollback remain pending.

## Phase I–Q recovery and replay follow-up — 2026-10-12 (historical checkpoint)

- Accepted Steer now atomically saves bounded redacted text and a stable message
  ID. Exact transcript reconciliation and per-record recovery let the user
  inspect, copy to the originating idle Task's draft, or dismiss an uncertain
  message. Recovery never sends it automatically.
- Saved instruction/configuration imports now retain one bounded, redacted undo
  slot. Restore previews the change, rejects stale imported fields, and preserves
  unrelated settings and Keychain references. Schema 2 and nonblocking file locks
  protect the transaction across app versions and concurrent instances.
- Automation producer claims now use a separate non-evicting ledger. Ordinary
  history pruning cannot make an accepted signed event replayable; a full ledger
  rejects new events. Schema 3 migrates retained legacy claims. Previously evicted
  claims cannot be reconstructed and require operator reconciliation and webhook
  credential rotation before accepting previously exposed signatures.
- Soak recovery preserves old evidence and always starts fresh measurement.
  Owner locks, input fingerprints, bounded child output and clock checks reject
  interruptions, including short sleeps hidden by a pausing monotonic clock.
  The October 12 Python contract run passes **48 tests, one Linux-only skip, zero
  failures**, including 28 soak harness tests (`tmp/phase-iq-oct12-python.log`).
- The October 12 development gate passes **881 Swift tests, one environment skip,
  zero failures**, 209.124 seconds. Optimized arm64 build, ad-hoc signing, plist,
  ZIP/extracted-archive verification and security audit passed. The release
  runner exited 0 (`tmp/phase-iq-oct12-release-result.json`); all **339** frozen
  source/test/script/config files matched its receipt at packaging. VS Code **17/17** and
  GitHub Action **14/14** also pass.
- October 12 development ZIP SHA-256:
  `c332aa0d10afae62054a38fc21d60f3d8c4f0d7a2f06314e75a3c12997e3c68d`.
  Packaged native accessibility checks pass Steer inspect/copy/dismiss/restart
  and instruction import/save/restart/restore/repeated-restore rejection.
  Durable evidence preserves one remaining Steer receipt, the restored prompt
  and zero session messages. The first app exited 0; the second exit is not
  established. These isolated synthetic-Task checks do not validate live model
  delivery or pixel layout (`tmp/phase-iq-oct12-recovery-ui/acceptance.json`).
- Fixture-driven real Chromium/CDP acceptance passes open, DOM snapshot and
  search (four matches). Browser Screenshot timed out after 30 seconds; screenshot
  and close were not established by that attempt; the subsequent fix and debug
  rerun are recorded above. No external-provider acceptance is claimed
  (`tmp/phase-iq-oct12-browser-retry/receipt.json`).
- The 852-test package below is historical and does not include these changes.
  No new soak had started at this October 12 checkpoint; the October 14 sequence
  is recorded above. Neither prior 2h run qualifies. 8h/24h/multi-day,
  external live acceptance and production signing/notarization/feed/rollback
  remain pending. This is a development package. Full evidence:
  [parity audit](CODEX_FULL_PARITY_AUDIT.md).

## Phase I–Q integrated bug review — 2026-10-03–05 (historical gate)

- Fixed Queue secret redaction and unsafe persistence paths, bounded Session
  recovery, memory suggestion starvation/stale search results, import context
  budgeting and Side chat image retention.
- Fixed voice callback/navigation races, remote worker permission/workspace
  binding and cleanup, signed-webhook replay identity, OAuth expiry handling
  and MCP connection replacement races.
- Fixed native Queue editor initial text, failed-save draft retention and
  stale error banners after retry. Updated Side chat's snapshot picker wording.
- The historical development gate passed **852 Swift tests** (one environment skip,
  zero failures, 218.382 seconds), Python contracts **24 tests** (one Linux-only
  skip), VS Code **17/17** and GitHub Action **14/14**. Optimized arm64 build,
  ad-hoc signing, ZIP/archive verification and security audit passed. All 338
  recorded source files matched the frozen receipt after packaging.
- Final packaged native accessibility replay passed Queue save-failure/retry,
  error clearing and restart persistence without replaying an uncertain entry.
  Earlier replay covered Queue reorder/remove and Side chat file/image snapshot
  lifetime. These synthetic-Task checks do not cover live model delivery.
- Development ZIP SHA-256 for the 852-test gate:
  `e8696c66291824adaa6a0840bf37e9cf78da240095c6dfdae690bef48e7f6d76`.
  Full evidence: [parity audit](CODEX_FULL_PARITY_AUDIT.md).
- A real SIGKILL/relaunch check on that package preserved durable Queue/Session
  data and the uncertain claim while discarding an unsaved draft. It covered one
  synthetic paused Task, not all crash points or the new recovery UI. The first
  fixture-driven real Chromium attempt completed only open and DOM snapshot;
  search, screenshot and close remain pending. No live model acceptance is
  implied by either check.
- Actual 2h local integration soak run
  `a56eab72-1c1d-4701-8417-d32b17eaf82e` **failed in the first Agent shard**
  on a streaming-test startup synchronization assumption. Replaced scheduler
  yield counting with bounded receive/stop/completion events and failure cleanup.
  The streaming suite and 10 separate cancellation repeats pass; the full Swift
  suite again passes **852 tests, one skip, zero failures** (205.019 seconds).
  Phase I–Q soak coverage now uses complete selector matching; Python contracts
  pass **26 tests, one Linux-only skip**. Only test/harness files changed after
  that packaging checkpoint. Subsequent recovery/replay fixes require a new
  integrated gate and package.
  Failed evidence is retained. Fresh 2h run
  `ef4a66ac-99ac-4057-81d3-343c28f906e2` stopped before finalization and is
  **abandoned, non-qualifying**. Its historical state/logs remain unchanged.
  It recorded 60 complete cycles and 481 shards; the last persisted update was
  `2026-10-04T16:28:14Z`. Its earlier first-cycle checkpoint passed 413 test
  executions (one environment skip, zero failures). No full-duration qualifying
  result exists, even though the abandoned state file still says `running`.
  8h/24h/multi-day soak, external live acceptance, Linux CI execution and
  production signing/notarization/feed/rollback remain pending. The minimal
  worker runs command jobs and textual patch takeover; a full remote Agent
  runtime and binary takeover are outside that v1 scope. This is not a
  formal production release. No commit or push was made.

## Phase L–Q combined development gate — 2026-10-01 (historical)

- Added durable Steer acceptance receipts, image-capable Queue editing, and
  explicit read-only file/image Side chat snapshots.
- Added a GitLab merge-request provider and signed GitHub webhook ingress into
  Automation's durable event path.
- Added on-device macOS voice input and interruptible spoken Task replies.
- Added an installable Linux SSH command worker with separate worktrees,
  heartbeat, reconnect, cancellation, bounded logs/diff and a desktop job pane.
- Added registry package-digest verification and update permission previews,
  OAuth refresh/revoke, and explicit MCP protocol compatibility diagnosis.
- Added macOS development and Linux worker CI definitions. The combined
  development gate passed 830 Swift tests (one environment skip, zero failures),
  optimized arm64 build, ad-hoc signing and ZIP/archive verification. A limited
  isolated-profile packaged UI smoke passed. Development ZIP SHA-256:
  `3e9bae3364eae6c725d229ac22d6e8d5b0c7ec55dd9dd127326a52b05828723a`.
  Real external acceptance, Linux CI execution, production signing and
  qualifying soak remain pending; this is not a formal production release.


Checkpoint date: 2026-10-01

## Phase K development follow-up — Claude Code / Cursor import

Project Settings now previews bounded relative `CLAUDE.md` references, Cursor
`.mdc` front matter and glob scope, and safe summaries of Claude/Cursor Project
configuration. Reviewed `.mdc` rules persist with activation metadata; rules
are projected to a model only when their scope applies. A user-selected Claude
Code JSONL or Cursor Markdown chat export can become a completed text-only
Task after preview. Re-read verification, source digests, secret redaction,
atomic save and fail-closed duplicate detection guard import and recovery.
Hooks, scripts, commands, permissions, MCP credentials, tool events, reasoning
and images do not transfer. The Phase K development gate passed 816 Swift tests
(one environment skip, zero failures), optimized arm64 build, ad-hoc signing,
ZIP and archive verification. Development ZIP SHA-256:
`b5dfd65fe0f292b13377be1b3a3815e7731cba938d11f35239b6a8b11532a5b0`.
Isolated-profile packaged UI smokes verified first instruction/chat previews,
Project Settings save/reopen, completed Task display, duplicate blocking and
clean exit. Real Claude Code/Cursor export acceptance remains pending. See
[`CODEX_FULL_PARITY_AUDIT.md`](CODEX_FULL_PARITY_AUDIT.md).

## Phase J development follow-up — local memory suggestions

A separate default-off switch now enables local background suggestions from
durably completed, idle Tasks whose Project and Task contribution settings
allow memory. Explicit user statements become source-backed, categorized
proposals with secret filtering and restart-safe duplicate suppression. Users
can search across Projects, sort and filter by category, inspect the source,
edit and approve. Only approved entries from the current Project can enter a
Task's bounded transient context when all read controls allow it. The 14
focused memory tests pass. The frozen-source development release gate passed
806 Swift tests (one environment skip, zero failures), optimized packaging,
ad-hoc signature, ZIP and archive checks. The development ZIP SHA-256 is
`3dedf990b3d062cf80e91b3561a72733e439b30619776bfac7ec19ce9a1eda30`.
An isolated-profile packaged native UI smoke verified opt-in, proposal search,
approval status refresh and clean exit. Live model and longer soak acceptance
remain pending; extraction currently recognizes explicit statements rather
than arbitrary conversational facts.

## Phase I development follow-up — SSH Task Terminal

SSH Tasks can now open a Task-owned interactive Terminal in the desktop pane.
The system OpenSSH client runs inside the bounded Darwin PTY, with streamed
input/output, resize, terminal control signals, Task navigation, explicit
Reconnect and metadata-only relaunch recovery. Host receipt, runner authority
and Task permission fingerprints prevent an old tab from reconnecting after
the host, credential, trust file or permissions change. A local surrogate
suite covers input/output/resize, disconnect, duplicate reconnect, revoked
authority and host replacement. Real SSH host, packaged UI and long soak
acceptance remain pending; `remote_pty_run` is still a one-shot model tool.
The final development release gate passed 800 Swift tests (one environment
skip), optimized desktop packaging and archive/signature/ZIP checks. The
development ZIP SHA-256 is
`5c26015d6c7546ba27f99c11a79ca8fae11160470ff969094fd4faf97c7a8e0e`.

The 1.4.5 development prerelease fixes the OpenAI-compatible Agent system
message order and the Plan/Agent bottom Composer layout. Its validation and
remaining live acceptance are recorded in
[`RELEASE_NOTES_1.4.5.md`](RELEASE_NOTES_1.4.5.md).

Status: the Phase A–H development implementation and its historical combined
development gate are complete. The 1.4.4 development prerelease packages the
follow-up changes below; its validation is recorded in
[`RELEASE_NOTES_1.4.4.md`](RELEASE_NOTES_1.4.4.md). This is not a production release: Developer ID,
notarization/stapling, production update credentials, live external acceptance,
and the qualifying long-duration soak remain external gates.

The previous combined Phase A–H development-gate artifact is `LumaChat-1.4.1-arm64.zip`, SHA-256
`d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`.
It is ad-hoc signed. Phase B's earlier evidence remains recorded in
[`RELEASE_NOTES_1.4.0.md`](RELEASE_NOTES_1.4.0.md).

## 2026-09-29 current-Codex gap follow-up

- Added text Steer for an active Agent run. Accepted messages enter a bounded
  process-memory mailbox and join at the next model-turn boundary without
  interrupting a provider stream or tool call. The default composer action is
  Steer; Settings can make Queue primary. `⌘↩` uses the primary action and
  `⌘⇧↩` uses the alternate action while a run is active. Steer acceptance is
  not crash-durable until the resulting session snapshot has been persisted;
  a failed or cancelled preflight returns accepted text to the in-process Task
  draft.
- Added a per-Task durable text Queue for prompts submitted during an active
  run. Entries can be edited/reordered/removed and dispatch in FIFO order after
  a successful durable turn. Claimed entries stay visible for explicit
  reconciliation after an uncertain crash rather than being replayed
  automatically. New image attachments cannot currently be added to Steer or
  Queue while a run is active.
- Forks now inherit a bounded, redacted text history: at most the latest 80
  user/assistant source messages and 64 KiB. Tool calls/results, reasoning,
  images, approvals, and live Runtime state are stripped from the child.
- Added a Side chat sheet for a separate, ephemeral text discussion of a Task.
  It receives only a bounded, redacted snapshot of the parent transcript and
  has no Agent tools, workspace lease, approval, file inspection, image input,
  or persistent transcript. Native UI acceptance remains pending.
- Added managed-worktree maintenance in the desktop UI: inspection, safe
  clean/unleased cleanup, repair, and failure reporting using the existing
  registry/lease service.
- Added MCP connection status and diagnostics, Reconnect, and Refresh Discovery.
  Refresh atomically replaces registered tools and retains the previous
  successful catalog on transient discovery failure.
- Added a durable App Server mutation journal with pending/completed outcomes
  and a worst-case byte ceiling for live SSE buffering. Uncertain mutations
  require inspecting the Task before resubmission.
- Added opt-in, Project-scoped local memories. Global, Project and Task use
  controls default off; user-written proposals require a separate approval
  before a bounded redacted snapshot reaches the selected model on a future
  run. The Task sheet supports edit, delete and clear; runtime context is
  transient and does not become a Session message. This first slice does not
  generate suggestions from conversation history.
- Added read-only import previews for root `CLAUDE.md` and legacy
  `.cursorrules`. Users can edit the redacted preview and explicitly apply it
  to the Project System Prompt draft before saving Settings. Nested includes,
  scoped Cursor rules and chat history remain out of scope.

The base source passed 778 Swift tests (one environment skip, zero failures),
17/17 VS Code tests, and 14/14 GitHub Action tests on 2026-09-29. The 1.4.3
development package passed 780 Swift tests (one environment skip, zero failures)
and archive, signature, and security validation. Its hash is recorded in
[`RELEASE_NOTES_1.4.3.md`](RELEASE_NOTES_1.4.3.md). Hosted Cloud/secure relay,
persistent interactive remote PTY, voice, complete Claude Code/Cursor import,
automatic memory suggestions and live external integration acceptance remain
open. The 1.4.1 ZIP hash above is historical.

The 1.4.4 release script subsequently passed 792 Swift tests with one
environment skip and zero failures, including 12 focused local-memory/import
tests, then completed the optimized build, ad-hoc signing, archive checks,
metadata generation and security audit. VS Code passed 17/17 and GitHub Action
passed 14/14 after integration. Native packaged UI acceptance remains pending.

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
  context-ownership, provider-overload, and isolation tests. They now pass in
  the combined Phase C–H development gate.

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
  multi-turn Agent profile tests. All pass in the combined development gate.

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
  tests. Test/build execution now passes in the combined Phase C–H development
  gate. See
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
  Focused tests now pass in the combined Phase C–H development gate; real
  browser/native UI acceptance remains an external environment gate.

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
  migration tests pass in the combined regression/build/package gate. A real
  remote-disconnect failure is covered through the injected transport boundary;
  live SSH-host acceptance, native UI E2E and long-duration soak remain pending.
  See
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
- Added focused Swift/Node/schema/packaging tests for these paths. The combined
  Swift gate passes, along with VS Code 17/17 and GitHub Action 14/14 Node tests
  and the development package round trip.

## Phase H — Release, update/rollback, soak, and security hardening

- Added a signed update-envelope verifier, exact manifest/archive validation,
  helper-based installation, durable transaction journal, reverse-swap rollback,
  downgrade/architecture/notarization policy, and fail-closed update state.
- Closed the post-swap disk-full window: if persisting the `swapped` journal
  fails after the physical rename exchange, the installer first restores the
  previous application. If that reverse swap also fails, the durable state is
  marked `failed` best-effort and the error reports that automatic rollback
  failed instead of claiming success.
- Added deterministic failure coverage for force quit, post-swap disk full,
  network down, Ollama down, MCP process crash, Browser process crash, PTY
  signal crash, Git index lock, deleted worktree, and remote disconnect. The
  failure shard resolves exact XCTest selectors and passes 10/10.
- Upgraded the soak contract to require eight exact unique categories and all
  ten named failure scenarios. Dry-run now inventories the compiled test bundle
  and rejects missing, duplicate, regex, or ambiguous selectors; development
  duration overrides are explicitly non-qualifying.
- Security-report persistence now creates its temporary file beside the final
  report so the atomic replace remains valid when project staging is on another
  filesystem. Release archive fixtures that deliberately contain AppleDouble
  metadata are retained in a dedicated project-`tmp` tree instead of poisoning
  the next release staging run.
- The 2026-09-25 development gate passed archive contract 6/6, soak contract
  4/4, security-report contract 1/1, and 744 Swift tests with one explicit
  environment skip and zero failures in 189.790 seconds. The optimized arm64
  build completed in 168.54 seconds; ad-hoc hardened signing, plist, canonical
  ZIP, extracted-app, SBOM/provenance, and static/package security audit passed.
- The security audit inspected 355 source files / 9,301,304 bytes and 15
  application files / 36,619,705 bytes; `get-task-allow` and update trust were
  both disabled for this development artifact.

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

## Remaining external production gates

The master parity program's eight development phases, A-H, are implemented and
have passed the combined development gate. Production completion still requires
a real Developer ID identity, notarization/stapling, production update signing
key/feed/archive URLs, real authorized SSH/backend/browser/native-UI acceptance,
and qualifying 2h/8h/24h/multi-day soak runs. The development artifact must not
be presented as notarized, published, or production-update capable.
