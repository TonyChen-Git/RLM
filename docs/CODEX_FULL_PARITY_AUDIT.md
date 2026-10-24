# LumaChat Full Codex-Class Parity Audit

Formal score and release evidence last audited: 2026-09-25, after the LumaChat
1.4.1 combined Phase A-H development gate. Current-Codex comparison refreshed
2026-09-29 against official OpenAI documentation; the 1.4.2 candidate evidence
and subsequent source changes are recorded separately below.

## Private-use acceptance scope — 2026-10-20

The user explicitly chose private use without Apple distribution signing
("不用簽 我私用"). The verified ad-hoc package remains the delivery artifact.
Developer ID signing, notarization, stapling, the production update feed and
live signed-update/rollback acceptance are `not_required_for_private_use` for
this request. They were not executed or passed, and the historical production
score and original release evidence are unchanged. Missing signing identities,
notary configuration and production feed credentials remain documented facts.
Future production distribution still requires those prerequisites and actual
acceptance. The updater continues to fail closed without its configured trust
material; permission and sandbox boundaries remain unchanged. Functional live
acceptance and version-bound soak retain their separate evidence requirements.

The user subsequently chose not to provide external model, SSH, MCP or test
repository targets at this time ("先不提供"). Acceptance requiring those targets
is `deferred_by_user`, with no passing live result claimed. Local fixture and
hosted CI evidence retain their documented scope.

## MCP 1.4.8 candidate integration — updated 2026-10-24

The development source now contains `2026-07-28` stateless MCP for both STDIO
and Streamable HTTP, alongside explicit `2025-06-18` legacy compatibility.
This is new product code beyond the immutable v1.4.7 release, packaged as the
local `1.4.8` / build `15` candidate. The full local release gate and packaging
pass. Limited packaged MCP UI with a local fixture also passes. Publication,
hosted CI and source-bound soak remain pending. Historical passing counts below retain their own version and input
fingerprints.

The frozen MCP/Phase D run passes **140 tests, zero skips or failures,
13.465 seconds**, fingerprint
`1a25a1e3cec4b5bf78edfa276d39029d648277641f8bedbe7fd17f441c150f03`.
It includes local fixtures and real sandboxed STDIO, with no external provider
acceptance. The final full gate after the version/build bump and Settings
layout correction records **962 Swift tests, one skip, zero failures,
253.914 seconds**, and **48 Python contracts, one skip, zero failures**. Node contracts pass **VS Code 17/17** and
**GitHub Action 14/14**. Debug/optimized compilation, ad-hoc signing, archive
and extracted-App checks, CLI version 1.4.8 and security audit all pass.

The complete gate's 350-input fingerprint is
`f7c34cecebea6d19723774fc017dbb33ed5d4fe0d46140df717d25ece5cbe29f`.
The log reaches the final release footer. The controller's original exit code
is unavailable; October 24 recovery matched the initial receipt against the
current inputs and repeated signature, ZIP CRC and CLI checks successfully.
The stale controller record and first candidate remain separate historical
evidence. ZIP SHA-256:
`ba0f14b8be761da2c2c648986fce9f19f9b831c0f0eb80ee973aa06865350888`.
The gate's base commit was `2f17a1aca6bc15be52417d184d01b98762555684`
with these changes uncommitted. Exact scope, skip reasons, artifact hashes and
retained diagnostic failures are in [1.4.8 notes](RELEASE_NOTES_1.4.8.md),
[validation/1.4.8.json](validation/1.4.8.json) and the
[focused MCP receipt](validation/mcp-stateless-2026-10-22.json).

The final packaged binary's October 24 MCP native UI run used an isolated
profile and loopback fixture. Legacy settings survived restart; legacy connect,
save-and-disconnect to Automatic, modern connect with invalid-tool warning,
Refresh Discovery and explicit Reconnect passed. Complete action labels and
wrapped diagnostics are visible. About reports `1.4.8 (15)` and clean quit
returns 0. Twenty captured HTTP requests include fourteen modern requests and
two modern discovery calls; protocol/method headers and the absence of modern
session headers are verified. This is limited MCP UI evidence, not external
provider or all Phase I–Q UI acceptance.

Implemented scope includes persisted protocol selection (old records/plugin
declarations default to legacy; new Settings drafts default to automatic),
read-only discovery negotiation, per-request protocol/capability metadata,
tools/resources/templates/prompts, bounded HTTP header projections and JSON or
request-scoped SSE. Invalid annotated tools are excluded with diagnostics.
Refresh separates successful filtering warnings from discovery failure, and
both connection and discovery tokens protect retained tool adapters from
stale schemas/permissions. The client checks each adapter's exact descriptor
before sending. Failed transports retire registered authority; session expiry
and ambiguous results require explicit recovery and never replay tool calls.
STDIO fallback joins prior process cleanup before creating the replacement.

Settings changes disconnect affected clients and clear cached approvals before
committing. Failed or ambiguous persistence keeps affected servers quarantined
while persisted readback is shown, rather than reconnecting stale credentials.
Keychain remains the credential boundary. These paths preserve existing
project, plugin ownership, sandbox and network approvals.

The supported modern profile advertises empty client capabilities. MRTR
`input_required`, sampling, elicitation and other unadvertised capabilities are
explicitly unsupported; no input or additional tool authority is supplied.
This records the implemented core profile, not universal provider/extension
compatibility. Live MCP/account acceptance remains `deferred_by_user`.
Apple distribution signing remains `not_required_for_private_use`; Windows
desktop work is outside this round. Slack/Gmail remain future provider
evaluation, as in the Phase M scope. Details and official protocol references
are in [Phase L–Q architecture](PHASE_L_Q_ARCHITECTURE.md).

## 1.4.7 integrated corrective release — 2026-10-19

Version `1.4.7`, build `14`, includes Swift 6.2.4 compatibility, isolated test/store
paths, Python shims within existing authorized tool roots, isolated OpenSSL
configuration, bounded incremental MCP framing and bounded diagnostic logging.
The shim scanner preserves embedded scripts, arguments and TerminalSession's
status/cwd wrapper without adding filesystem grants.

Verified source `eeddc7508348fe236c51d46b4cab55b914f2ff13` passes
[hosted macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39190608251):
**896 Swift tests, two skips, zero failures, 219.665 seconds** on Xcode 26.3 /
Swift 6.2.4, debug compilation in 186.12 seconds, and the optimized build step.
Archive 7/7 and soak harness 28/28 contracts pass, without skips. Its 341-input
fingerprint is `6b456593bccf15a34e1eb207507ce7afe9bae87b296e8aea56e558951140ade0`.
Evidence: `tmp/release-1.4.7-macos-ready-ci.log` and
`tmp/release-1.4.7-ready-source-receipt.json`.
[Linux worker CI](https://github.com/TonyChen-Git/RLM/actions/runs/39226505634)
also passes: **ten tests, zero skips/failures, 5.348 seconds**
(`tmp/release-1.4.7-linux-ready-ci.log`). The fresh complete local gate also
passes, exit 0, with matching frozen source receipts: **896 Swift tests, one
skip, zero failures, 255.063 seconds**; **48 Python contracts, one Linux-only
skip, zero failures**. Debug/optimized arm64 compilation takes 404.04/184.48
seconds. Ad-hoc signing, plist/archive/extracted-App checks, security audit and
CLI version 1.4.7 pass. Logs and result: `tmp/release-1.4.7-ready.log` and
`tmp/release-1.4.7-ready-result.json`. All five artifact hashes match the earlier
candidates. The regular [v1.4.7 Release](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.7)
was published at `2026-10-19T15:05:13Z`, from commit
`890574e29000f009c8b7c69f6f3df53d2449deaf`. All five uploaded sizes/digests match;
receipt: `tmp/release-1.4.7-publication.json`.

Post-publication verification of the exact tag commit `890574e` separately
passes [macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39274782878):
**896 Swift tests, two skips, zero failures, 243.144 seconds**, debug build
189.74 seconds and optimized desktop build 456.01 seconds. Archive 7/7 and
soak harness 28/28 contracts pass with no skips.
[Linux worker CI](https://github.com/TonyChen-Git/RLM/actions/runs/39274782832)
passes **ten tests, zero skips/failures, 7.197 seconds**. Receipt:
`tmp/release-1.4.7-tag-ci-acceptance.json`; completed logs:
`tmp/release-1.4.7-tag-macos-ci.log` and `tmp/release-1.4.7-tag-linux-ci.log`.
These results are stored as `postPublicationTagCI` alongside the earlier
source-commit CI evidence. They do not qualify external-provider acceptance.

The final commit corrects only HTTP fixture ordering/liveness: serial delivery
preserves byte order despite reversed deadlines, cancellation stops scheduled
callbacks, and GET/POST SSE tests verify completion while the response stream
remains open. Eight focused tests pass, zero skips/failures, in 1.187 seconds.
The production transport and request deadlines remain unchanged. Earlier
`bb26729` local gate (896 Swift/48 Python, each one skip, zero failures), Linux
CI (ten tests, zero skips/failures) and the single GET SSE hosted failure remain
recorded separately in the release notes and validation receipt.

The earlier diagnostic run `38984361251` received only 3 MiB of a 4 MiB STDIO
fixture by 9.096 seconds before its ten-second deadline, while a separate 1 MiB
response's logging and decoding took about three milliseconds. Controlled
background-policy experiments corroborate accumulated relative-sleep drift.
`bb26729` uses absolute monotonic pacing with a yield after at most eight
catch-up writes, retaining the payload, chunk size and deadline. Temporary
DEBUG instrumentation is removed; production source/workflow match `744fb73`.

Native packaged smoke passes on October 19: startup, idle Task accessibility,
About accessibility/screenshot showing **1.4.7 (14)** and clean quit, exit 0.
The run creates zero messages and executes zero Browser operations; model,
microphone and external-provider acceptance are outside its scope. Receipt:
`tmp/release-1.4.7-ui/acceptance.json`, tied to the previous `bb26729` package
with ZIP SHA-256 `44d2ceb9cd7e45dc81e4a12fa78c0058cd1b880404f24843ed55442c7c8df856`.
The final archive and App binary match the smoke-tested package exactly,
verified in `tmp/release-1.4.7-native-artifact-equivalence.json`. The original UI
receipt retains its source scope; this is artifact equivalence, not a second UI
run. The final binary SHA-256 is
`12516c88ccf60286c808f3bba6f867e668e0c6b998e3b3689274d0d0061f2b79`.

Earlier failed and intentionally interrupted attempts, the previous `744fb73`
local pass and hosted failure, focused checks, Node 17/17 and 14/14 results,
and timing experiment details are retained in [1.4.7 notes](RELEASE_NOTES_1.4.7.md)
and [validation/1.4.7.json](validation/1.4.7.json). Version-bound soak
qualification for 8h/24h/72h remains pending. The immutable 1.4.6 tag/artifacts and its
qualifying 2h soak retain their separate scope. Unexecuted functional external
acceptance remains pending. Apple distribution and signed-update acceptance
are excluded from the current private-use completion scope as recorded above;
they have no passing production evidence.

The exact v1.4.7 tag's fresh 2h → 8h → 24h → 72h soak sequence launched at
`2026-10-19T15:07:46Z`. Its isolated archive verifies all 464 tracked files and
the same 341-input/source/toolchain receipt. The first 2h run is in preparation
at the original recorded checkpoint, with **no qualifying result at that time**. Original state:
`tmp/release-1.4.7-soak-suite/state.json`; immutable launch evidence:
`tmp/release-1.4.7-soak-start-checkpoint.json`. This is local integration and
failure-injection evidence only; old versions' soak time is not reused.

### October 20 scoped acceptance follow-up

The exact-version **2h soak qualifies**: 7,257.719 continuous seconds,
52 cycles, 418 completed shards, zero failures. Two 8h attempts do not qualify:
the first stops after 27,071.070 seconds when the continuous-clock guard
detects a 452-second clamshell sleep on battery; the second stops after
7,588.814 seconds with exit 130 from an interruption signal of unknown origin.
Final evidence: `tmp/release-1.4.7-soak-oct20-checkpoint.json`.
A detached fresh 8h → 24h → 72h sequence starts at `2026-10-20T06:37:55Z`;
launch receipt: `tmp/release-1.4.7-soak-retry2-launch-checkpoint.json`;
live state: `tmp/release-1.4.7-soak-retry2-suite/state.json`.
Neither interrupted time is reused; later profiles require the preceding pass.
That third 8h attempt subsequently fails at `2026-10-20T09:19:07Z` after
9,317.128 seconds, 64 cycles and 513 shards. The next PTY shard reports
81 tests, one skip and one failure: the real pip prompt was not observed
within ten seconds. Final receipt:
`tmp/release-1.4.7-soak-retry2-failure-checkpoint.json`.
Test-only follow-up on `main` stops interaction immediately when a prompt is
missing, adds bounded diagnostics and disables unnecessary pip bytecode cache
writes. The deadline and sandbox remain unchanged; the original failed result
and published binary remain unchanged. See the release notes for measured
cache-write costs and the distinction from PTY validation.

On October 21, the corrected fixture passes all 22 PTY tests (one existing
setuid-top environment skip, zero failures, 27.718 seconds) and two additional
real-pip runs (11.877/15.013 seconds, no skips or failures). Frozen before/after
receipts match fingerprint
`d295b7da89b9a78a6cda360ab948c79f51c8716ab0b9e592e67a64f0f670a1c9`.
At that test-only checkpoint, of the 341 release inputs only the PTY test file
differs; production inputs remain identical. Receipt: `tmp/pty-pip-oct20/verification.json`. These focused
results do not qualify a continuous soak or replace the original tag results.

A separate corrected-test **8h → 24h → 72h** sequence starts at
`2026-10-21T01:31:01Z` from immutable commit `fdcabc20a9c6538c76b1089afaf8a872af2c17e6`.
The snapshot verifies 464 tracked files and the focused test receipt. It keeps
the published production inputs but changes the PTY test file, so this is not
an unchanged release-tag test run. The launch checkpoint records preparation;
prior elapsed time is not reused.
Receipt: `tmp/release-1.4.7-corrected-soak-launch-checkpoint.json`; final state:
`tmp/release-1.4.7-corrected-soak-suite/state.json`. The correction's
[macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39527531264) is also
in progress at the recorded checkpoint; no passing result is claimed.

That corrected-test run `ccb2e92e-d3da-428c-af8f-25fd86ca7031` subsequently
receives **SIGTERM at `2026-10-21T03:17:32Z`** (11:17:32 Asia/Taipei), with
`senderKnown: false`. Its final state is interrupted: **5,988.242 continuous
seconds, 46 completed cycles, 368 completed shards and 369 attempted shards**,
exit 130. The in-flight Agent shard exits -15; the recorded cause is
`InterruptedError: soak interrupted`. The sender and reason for the signal are
unknown. It does not qualify, 24h/72h did not start, and no sequence remains
running. The original exact-tag 2h qualification is historical v1.4.7 evidence;
neither it nor this interrupted test-only run qualifies the later MCP source.

The published package also passes actual Chrome open/snapshot/find/screenshot/
close, with a visually verified 1280×657 PNG. Completed Task history and the
image recover after restart; both App exits are 0 and owned Chrome processes/
ephemeral profiles are absent afterward. The annotation pane displays correctly;
annotation writing remains unverified because the UI automation tool reports
`noWindowsAvailable` on dragging. Native TTS Play → Stop → Play controls pass,
but audible output, microphone recognition and navigation interruption are
not claimed. Computer Use safety disclosures/defaults pass UI inspection;
capture/action acceptance remains unrun. Receipt:
`tmp/release-1.4.7-browser-acceptance/acceptance.json`.
This uses a deterministic local model/page fixture, not an external provider.

## 1.4.6 integrated release — 2026-10-15

Version `1.4.6`, build `13`, integrates Phase I–Q and was published from `main`
as a regular [GitHub Release](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.6) with prerelease disabled at
`2026-10-15T02:13:10Z` (10:13:10 Asia/Taipei), as requested by the user.
Release commit/tag: `828c913fdcde4fdc7448f3881319e3b20f1d23a3` / `v1.4.6`.
All five uploaded asset sizes and API SHA-256 digests match the verified local
artifacts (`tmp/release-1.4.6-publication.json`). The release tag remains fixed;
these later acceptance records are a follow-up on `main`. The packaging script uses
`LUMACHAT_RELEASE_MODE=development` for ad-hoc signing; Developer ID,
notarization/stapling and production update-feed acceptance remain pending.

The complete retry gate **passes**, exit 0: **886 Swift tests**, one environment
skip, zero failures (273.489 seconds); **48 Python contracts**, one Linux-only
worker skip, zero failures (archive 7, soak 28, security 3, worker 10).
Fresh VS Code **17/17** and GitHub Action **14/14** also pass. Debug compilation
(326.27 seconds), optimized arm64 compilation (205.32 seconds), ad-hoc signing,
plist/archive checks, extracted CLI version **LumaChat 1.4.6**, and security
audit pass. Gate receipts: `tmp/release-1.4.6-retry.log`,
`tmp/release-1.4.6-retry-result.json`; Node logs:
`tmp/release-1.4.6-vscode.log`, `tmp/release-1.4.6-action.log`.

Post-publication Linux worker CI passes on [tag](https://github.com/TonyChen-Git/RLM/actions/runs/38669773678) and
[main](https://github.com/TonyChen-Git/RLM/actions/runs/38669774239); the tag run executes **10 tests, zero skips and zero
failures in 5.971 seconds** (`tmp/release-1.4.6-linux-ci.log`). This completes
executed Linux worker contract coverage, including the local macOS skip.
Real SSH host/network/fault acceptance remains pending.

Hosted macOS CI fails on [tag](https://github.com/TonyChen-Git/RLM/actions/runs/38669773617) and [main](https://github.com/TonyChen-Git/RLM/actions/runs/38669774231) before tests:
Xcode 16.4 / Swift 6.1.2 `swift-frontend` exits with **signal 11** during module
emission. Log: `tmp/release-1.4.6-macos-ci-failed.log`.
Post-publication `main` commits pin Xcode 26.3 build 17C529 / Apple Swift
6.2.4 (`c63f53a`), make numeric conversions and context additions explicit
(`8925875`, `081300c`), and fix three corresponding test expressions (`0d9364b`).
Earlier reruns failed compiler diagnostics for those expressions; the App
compiled before the final three test-source corrections. No assertion or
coverage change is claimed. Full failed-run IDs and diagnoses remain in the
[validation receipt](validation/1.4.6.json).
Final local focused validation on `0d9364b` passes **45 tests, zero skips,
zero failures, 40.665 seconds**; logs: `tmp/release-1.4.6-compat-final.log`,
`tmp/release-1.4.6-compat-final-result.json`. The [complete hosted run](https://github.com/TonyChen-Git/RLM/actions/runs/38698727639)
failed after **886 tests, two skips, eight failures (four unexpected), 342.539
seconds** (`tmp/release-1.4.6-macos-0d9364b-failed.log`). The focused local pass
does not override that broader failure. Environment/shared-storage, sandbox
runtime and MCP framing corrections are being prepared as 1.4.7. These later
workflow/source/test changes are not in the immutable release tag or ZIP; the
local release gate above and the published artifact retain their original scope.

The final package's isolated native smoke passes launch, idle Task accessibility,
About accessibility and screenshot showing **1.4.6 (13)**, and Cmd-Q with exit
0. It created zero Task messages and ran zero Browser operations; no model,
microphone or external-provider acceptance is implied. Receipt:
`tmp/release-1.4.6-browser/acceptance.json`.

ZIP: `dist/LumaChat-1.4.6-arm64.zip`, SHA-256
`0d5112022bee7d3c266a32cd0ef25692d1a34cc112411387805da39a5cdb026a`.
The frozen 340-input receipt is `tmp/release-1.4.6-source-receipt.json`,
fingerprint `32aed45fe29a36a81ff163a893b9204ac9e678e581b90ecc8162a60903b72d99`.

The first gate attempt passed its Swift suite and optimized build, then failed
extracted CLI verification because the CLI constant still reported `1.4.5`.
The corrected constant is covered by the full passing rerun. Failed evidence is
preserved in `tmp/release-1.4.6.log`, `tmp/release-1.4.6-result.json` (exit 1)
and `tmp/release-1.4.6-first-attempt/`.

See [1.4.6 release notes](RELEASE_NOTES_1.4.6.md) for this release's scope and
remaining acceptance. Earlier package hashes, Browser 5/5 acceptance and the
qualifying 2h soak below retain their original version/input scope. A fresh
exact-`v1.4.6` 2h → 8h → 24h → 72h sequence launched at 15:16:37 Asia/Taipei
on October 15. Its isolated archive verifies all 456 tracked files and the
same 340-input/source/toolchain receipt as the release. After inventory/build
preparation, actual 2h measurement began at `07:22:11Z` (15:22:11 Asia/Taipei).
The 2h run **completed and qualifies** at `09:22:39Z` (17:22:39 Asia/Taipei):
**7,227.507 continuous seconds, 48 complete cycles, 386 completed shards,
zero failures**, run `13b6ed74-57c2-458a-9cec-6d9d306d0e70`.
The subsequent 8h run `a62f13b0-7fc9-4989-9151-2a21403d188e` was interrupted
at `09:53:17Z`, exit 130, after 1,582.530 seconds, ten complete cycles and 81
completed shards; its active PTY child ended with `-15`. It does not qualify.
The suite stopped at `09:53:22Z`, with no active run and no 24h/72h start.
Controller receipt: `tmp/release-1.4.6-soak-suite/state.json`; snapshot receipt:
`tmp/release-1.4.6-tag-source-verification.json`. No old duration was reused or
overridden. The passing 2h result applies to 1.4.6 only, not the 1.4.7 patch. The local implementation includes the documented minimal
worker and bounded provider/import capabilities; remaining scope and production
gates are not implied complete by the regular GitHub release channel.

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
model-facing `remote_pty_run` tool is intentionally one-shot. The later Phase I
development tree adds a Task-owned interactive SSH Terminal; live-host and
packaged UI acceptance remain pending. `.futureCloud` remains a fail-closed
seam, and cross-platform backends and long soak remain incomplete. A deterministic
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

## Current Codex differential — 2026-09-29

The official baseline now explicitly includes [Steer and Queue while a run is
active](https://learn.chatgpt.com/docs/prompting),
[Local/Worktree/Cloud execution](https://learn.chatgpt.com/docs/environments/modes),
[scheduled local worktree tasks and web/mobile event triggers](https://learn.chatgpt.com/docs/automations),
[opt-in local memories](https://learn.chatgpt.com/docs/customization/memories),
[MCP and OAuth](https://learn.chatgpt.com/docs/extend/mcp), and
[code review](https://learn.chatgpt.com/docs/code-review). Codex also documents
[ephemeral side chats](https://learn.chatgpt.com/docs/developer-commands),
[voice in Codex](https://learn.chatgpt.com/docs/features/voice), and
[import from Claude Code/Cursor](https://learn.chatgpt.com/docs/import). The comparison is
capability by capability: Codex account services and OpenAI-hosted cloud compute
are not implied by the presence of local protocol types in LumaChat.

The 1.4.2 development candidate has 745 Swift tests (one environment skip), an
optimized ad-hoc signed arm64 package, and source/package audit evidence. Its
native packaged UI smoke and live external acceptance are still pending; the
2026-09-25 count, ZIP hash and formal scores elsewhere in this document remain
the historical 1.4.1 gate rather than being silently relabelled as 1.4.2.

| Gap found against the current baseline | 2026-09-29 source follow-up | Remaining boundary |
| --- | --- | --- |
| Active-run Steer and Queue | Text Steer joins the current run at a model-turn boundary; durable per-Task Queue supports text/images, edit/reorder/remove, and fail-closed recovery. Acceptance writes an atomic receipt containing bounded redacted text and a stable message ID first. Settings chooses the primary action; `⌘↩` uses it and `⌘⇧↩` uses the alternate action | Steer images are not supported. Accepted but unconfirmed Steer remains explicitly uncertain after crash; native UI acceptance pending |
| Fork context | Redacted user/assistant text from at most the latest 80 source messages and 64 KiB is copied to the new Task; tool calls/results, reasoning, images, approvals and live state are omitted | This is bounded context inheritance, not a full transcript or live process fork; older context may be omitted |
| Side chat | Separate ephemeral conversation with a bounded, redacted parent snapshot and user-selected read-only file/image snapshots; no Agent tools, workspace lease, approval or persistence authority | Snapshot can become stale; no tool or durable transcript support; native UI acceptance pending |
| Managed worktree maintenance | Registry-backed inspection, clean/unleased cleanup and repair surfaced in the desktop UI | Scheduled maintenance, retained-branch policy and orphan edge coverage remain |
| MCP health and restart | Visible connection diagnostics, explicit reconnect and discovery refresh; atomic tool-registration replacement and transient-discovery fallback | Live provider breadth and advanced OAuth interoperability remain |
| App Server restart idempotency and SSE buffering | Durable mutation request journal with pending/completed states; worst-case live SSE byte ceiling | Real transport/hosted-runner acceptance and long soak remain |
| Opt-in local memories | Global, Project, Task and background-suggestion controls default off; bounded Project store, review/approval/edit/delete, source-backed local suggestions, cross-Project search/category/sort and transient query-ranked context | Background extraction currently recognizes explicit user statements only; live model and long-soak acceptance pending |
| Claude Code / Cursor import | Bounded Claude `@` references, Cursor `.mdc` front matter and scoped runtime projection, configuration summary, explicit model preference draft, and user-selected text chat Task import with source digest | Other vendor settings and credentials have no automatic mapping; live exports and packaged UI acceptance pending |

The 2026-09-29 source follow-up passed 778 Swift tests with one environment skip
and zero failures, plus 17/17 VS Code and 14/14 GitHub Action tests. This is
development evidence; native packaged UI, live external and production release
gates remain. The formal **68.5/100** score below is not increased by source
changes alone.

The subsequent 1.4.4 development release script passed 792 Swift tests with one
environment skip and zero failures, including the 12 focused local-memory/import
tests, and completed an optimized arm64 package with ad-hoc signing, ZIP,
manifest/SBOM/provenance and security-audit verification. Native UI and live
external acceptance for those new controls remain pending. The formal
production-credit score is unchanged.

The largest still-open functional differences are live validation and remote
process cleanup guarantees for the new interactive SSH PTY; broader memory
extraction and live model acceptance; hosted Cloud execution/secure relay; voice interaction; broader vendor settings and chat-export formats; external service integrations and live
acceptance; and production signing, notarization, update feed and long-duration
soak. Event-triggered scheduled tasks are currently documented for Codex
web/mobile, not the desktop app or
CLI, so they are a broader product parity item rather than a desktop-only gate.

## Phase I — SSH interactive Task Terminal (1.4.5 follow-up)

The development tree now presents an SSH Task Terminal in the native Task pane.
It launches the system OpenSSH client inside the bounded Darwin PTY, supports
streaming input/output and resize, retains at most 2 MiB of raw output per
connection, and keeps Task navigation independent of the UI subscriber. The
existing one-shot `remote_pty_run` model tool is unchanged. The terminal
service persists host/user/UID/canonical-root, runner authority and Task
permission fingerprints with its metadata. A new shell or Reconnect requires
a fresh authenticated host receipt; credential, `known_hosts`, runner or
permission changes cannot reuse the previous tab. After relaunch a former
running tab is explicitly disconnected and Reconnect starts a new shell.

Local evidence: `swift build --product LumaChatDesktop` passed; 63 prior
terminal/SSH tests passed with one pre-existing environment skip; six new
`SSHInteractiveTerminalTests` passed for direct PTY input/output/resize/signal
and cleanup, bounded scrollback, metadata-only restart, disconnect, duplicate
reconnect, changed host/authority rejection and unavailable credential. These
tests use a local shell surrogate, **not** a live SSH host.
The frozen-source development release gate also passed 800 Swift tests
(one environment skip, zero failures), optimized desktop build, ad-hoc
packaging, archive verification, ZIP integrity and signature checks.
The resulting development ZIP SHA-256 is
`5c26015d6c7546ba27f99c11a79ca8fae11160470ff969094fd4faf97c7a8e0e`.
The formal production score remains 68.5/100.

Pending: real authorized SSH host E2E, packaged native UI smoke, host reboot,
network interruption, revoked credential, duplicate connection and long-run
soak. Terminal control bytes cover interrupt/quit/suspend and shell `fg`;
hangup/terminate/kill close the local SSH connection. Daemonized remote
descendants cannot be proven stopped by this transport. No old remote process
or scrollback reattachment is claimed.

## Phase J — Local memory suggestions and retrieval (development follow-up)

The development tree adds a separate default-off background suggestion switch.
After a Task reaches a durably completed state and becomes idle, a local scan
inspects at most its last 64 messages. Only explicit user "remember", preference
or workflow statements from Tasks with contribution permission produce bounded,
secret-filtered proposals. Startup and opt-in rescan completed Tasks. A Project
document atomically stores the proposal and processed source ID; deletion and
clear retain that ID so a rejected suggestion does not reappear after restart.
Every automatic proposal carries its Task/message source and category. The UI
supports cross-Project search, category filters, relevance/recent sort, source
inspection and editing. Only approved entries from the current Project are
ranked against the current request and projected to the selected model within
entry, category and byte budgets when global, Project and Task read switches
allow it. Proposed content is never model context.

Local evidence: 14 focused memory tests pass, including completed/paused Task
scan, restart idempotency, secret filtering, delete/clear tombstones, scoped
search and transient approved-only context. The frozen-source development
release gate passed 806 Swift tests (one environment skip, zero failures),
optimized arm64 packaging, ad-hoc signing, ZIP and archive verification. The
development ZIP SHA-256 is
`3dedf990b3d062cf80e91b3561a72733e439b30619776bfac7ec19ce9a1eda30`.
An isolated-profile packaged native UI smoke verified default-off controls,
Project/Task opt-in, a manual proposal, cross-Project search, immediate status
refresh after approval, editing, and clean App exit. Live model acceptance and
longer crash/soak exercises remain pending. This is a bounded local heuristic,
not general semantic memory extraction. The formal production score remains
68.5/100.

## Phase K — Claude Code / Cursor import (development follow-up)

Project Settings now previews root `CLAUDE.md` plus relative `@` references,
legacy `.cursorrules`, `.cursor/rules/**/*.mdc`, `.claude/settings.json` and
`.cursor/mcp.json`. File reads are bounded and no-follow; reference traversal,
cycles, changed sources, invalid UTF-8, hard links and unsafe paths fail closed.
Cursor front matter retains always, glob, agent-requested and manual activation
types in the atomic Project Settings record. The runtime projects reviewed
rules transiently with a 32 KiB cap; glob rules require a matching Task path,
and manual/agent-requested rules require an explicit user mention. Claude and
Cursor configuration summaries reveal only field/server names and a safe
model candidate; external permissions, hooks, commands, environment values,
MCP launch settings and credentials do not transfer.

The user can select a Claude Code JSONL or Cursor Markdown chat export, review
its redacted user/assistant text, and import it as a completed Task in the
selected Project. The importer rechecks the file, limits size/message count,
omits tool calls/results, reasoning and images, and persists the Task before
publishing it in the UI. A source digest rejects repeated import in the same
Project, including after restart; a failed save leaves no visible Task.

Local evidence: 25 selected importer, Project Settings and runtime-scope tests
passed, including restart idempotency, secret filtering, unsafe files, reference
cycles, `.mdc` scope and Project Settings persistence. The 2026-10-01
development release gate passed 816 Swift tests (one environment skip, zero
failures), optimized arm64 build, ad-hoc signature, canonical ZIP, extracted
bundle and archive verification. Development ZIP SHA-256:
`b5dfd65fe0f292b13377be1b3a3815e7731cba938d11f35239b6a8b11532a5b0`.
Isolated-profile packaged UI smokes verified the first `CLAUDE.md` preview
includes its referenced file and editable content; Cursor `.mdc` scope preview,
Project Settings save/reopen, safe Claude configuration summary, first JSONL
chat preview/import, completed text-only Task display, same-file duplicate
warning/disabled action, and clean App exit. Restart idempotency was exercised
by the integration test, not by a packaged App relaunch. Live acceptance with
real Claude Code/Cursor exports remains pending; only the documented
JSONL/Markdown shapes are accepted. Cursor MCP setup and broader vendor
configuration cannot be safely mapped to LumaChat permissions automatically.
Formal production score remains 68.5/100. See
[`PROJECT_IMPORT_ARCHITECTURE.md`](PROJECT_IMPORT_ARCHITECTURE.md).

## Phase I–Q integrated bug review (2026-10-03–12)

This follow-up reviews the integrated development tree and fixes defects found
after the historical 830-test gate below. The old ZIP is not evidence for these
new changes. New verification evidence is recorded separately in this section.

| Area | Defect corrected | Regression coverage |
| --- | --- | --- |
| I / O | Stale SSH lifecycle results, worker process cleanup, bounded logs, spawn failure and committed job changes omitted from diff | SSH interactive tests and Python worker protocol/process tests |
| J | Already processed suggestions consumed the candidate limit; stale searches could repopulate disabled memory results | Memory planner/store/integration tests |
| K | Project-settings parent symlinks could redirect writes; rule context omitted header/separator bytes from its budget | Project settings and instruction projector tests |
| L | Queue persisted raw secrets; recovery could follow substituted Task directories or block on FIFOs; Side chat follow-ups lost selected image payloads | Queue/Steer persistence and Side chat tests |
| L native UI | First Queue editor presentation lost its initial text; the sheet dismissed before save success; successful retry retained an old error banner; Side chat picker described persistent attachments | Task-bound editor draft, durable-save/retry regression and packaged UI replay |
| Shared persistence | Session startup/save used unbounded, link-following reads; unsafe parent paths could redirect directory creation | Session ordering, parent-link and FIFO recovery tests |
| M | Changing unsigned GitHub delivery/event headers could bypass replay identity or change event classification | Signed-body webhook projection/replay tests |
| N | Late capture/synthesis callbacks could affect new sessions; final recognition and navigation could retain the wrong submission/playback state | Injected capture/speech/permission tests and Task-bound reply tests |
| O | Worker binding lacked Task permission/workspace identity; Plan or changed authority could reuse a writable job | Worker authority and protocol pre/postflight tests |
| P | Invalid OAuth expiry could become unlimited; in-flight MCP responses could reconnect after disconnect or clean up a successor's namespace | OAuth expiry/race and MCP connection lifecycle/replacement tests |

All external acceptance and production limitations listed below remain pending
until supported by new live evidence. This historical review pass preceded the
subsequently authorized 1.4.6 release preparation, cleanup, commit and push.

### October 14 Browser lifecycle fix and development gate

- Diagnosis confirmed that the persistent CDP WebSocket inherited a 30-second
  URLSession resource timeout intended for individual commands. After approval
  waits, the socket had reached `completed` while pending transport state still
  appeared open. Metadata-only evidence is preserved at
  `tmp/phase-iq-oct14-browser-trace/app.log`. The resource-timeout override is
  removed; individual command deadlines remain bounded at 30 seconds. Command
  and send paths reject a completed socket immediately, and unexpected receive
  cancellation fails pending requests and closes the connection.
- **Five real loopback WebSocket lifecycle tests pass**, covering creator and
  command cancellation, peer closure, unexpected receive cancellation and reuse
  after 32 seconds idle. The cancellation regression failed two assertions
  before the fix (`tmp/phase-iq-oct13-cdp-cancellation-before.log`). Barrier-based
  focused tests passed in 32.159 seconds
  (`tmp/phase-iq-oct13-cdp-lifecycle-barriers.log`); the final full gate reran the
  five tests successfully in 32.139 seconds. The Browser soak filter includes
  this suite. Temporary DEBUG tracing was removed before freezing the source.
- A debug App using real Chrome/CDP passes **5/5 operations**: open, DOM
  snapshot, find (four matches), screenshot and close. The gap before the next
  Browser command was **53.18 seconds**, exceeding the previous connection
  lifetime. The actual 1280×657 PNG was visually inspected; the Browser
  annotation pane was checked through accessibility. App exit was 0 and no
  owned Chrome processes remained. Receipt:
  `tmp/phase-iq-oct14-browser-fixed/acceptance.json`. This run used a local
  deterministic model and page, and the debug binary still had temporary
  metadata tracing. The final optimized-package run is recorded separately below.
- The **final optimized arm64 development package also passes all five Browser
  operations** through real Chrome/CDP. The observed wait before approving the
  DOM snapshot was at least **68.382 seconds**; persisted tool timings show a
  **79.306-second** gap before its execution and a **0.059263-second** snapshot.
  The actual 1280×657 PNG was visually checked, and the native Browser annotation
  pane passed accessibility inspection and a CUA screenshot visual check. The
  native UI screenshot remains in the conversation tool result; no local copy
  was saved. App exit was 0, owned Chrome processes were gone and the fixture
  server was terminated. Evidence:
  `tmp/phase-iq-oct14-browser-package/acceptance.json` and `receipt.json`, tied
  to the `7c5c...` package below. The local deterministic model and page exercise
  real product browser operations; **live model and external-provider acceptance
  remain pending**.
- The new development gate passes **886 Swift tests, one environment skip,
  zero failures**, 258.252 seconds, and **48 Python contracts, one Linux-only
  worker skip, zero failures** (archive 7, soak 28, security 3, worker 10).
  The Swift skip remains the setuid system `top` executable rejected by the
  PTY sandbox. Log: `tmp/phase-iq-oct14-release.log`; the full release runner
  exited 0 (`tmp/phase-iq-oct14-release-result.json`). The optimized arm64 build
  passed in 197.62 seconds, followed by ad-hoc signing, plist checks,
  ZIP/extracted-archive verification and security audit.
- October 14 historical development ZIP: `LumaChat-1.4.5-arm64.zip`, SHA-256
  `7c5c0716e30becfbb600f06db6f37516cc5560cca88783701aa5019b7a4de3b0`.
  Its archive, manifest, provenance, SBOM and checksum are preserved under
  `tmp/phase-iq-oct14-preserved-integration-1.4.5/`. The tracked 1.4.5 files
  retain their original development-release checkpoint.
  Frozen source fingerprint:
  `b92bed4c88969962dcb240ea816b112b1ff3051fdc3a2c663da9ec99c8a45b3d`
  (`tmp/phase-iq-oct14-source-receipt.json`, **340** recorded
  source/test/script/config files). VS Code **17/17** and GitHub Action
  **14/14** evidence remains the October 11 run on unchanged integration inputs.
- The October 13 unlocked packaged retry and 60-second outer-deadline diagnostic
  remain preserved as failed evidence at
  `tmp/phase-iq-oct13-browser-live/receipt.json` and
  `tmp/phase-iq-oct13-browser-diagnostic/diagnostic-result.json`.
  The older `c332...` package and 881-test gate below remain historical.
  External SSH/MCP/PR/OAuth/voice/Computer Use acceptance, executed Linux CI,
  Developer ID/notarization/stapling and production update/feed recovery remain
  pending. **No production release is claimed.**
- The background **2h → 8h → 24h → 72h multi-day** sequence launched at
  **2026-10-14 15:24:13 Asia/Taipei** (`07:24:13Z`). Its **2h run completed and
  qualifies** at `09:29:56Z` (17:29:56 Asia/Taipei): **7,207.592 continuous
  measured seconds, 48 complete cycles, 389 completed shards, zero failures**.
  Run: `tmp/soak/19124a61-51f3-4eec-8bd6-e2679e8327e2/`. Inventory/build time
  was excluded; the linked abandoned run contributed no time or cycles.
- The following 8h run, `tmp/soak/f1c364d4-1834-455e-b29b-01082173cd9d/`, was
  **interrupted and does not qualify**: 669.134 measured seconds, four complete
  cycles and 36 completed shards; its active Browser shard ended with `-15`.
  The controller stopped at `09:46:31Z` (17:46:31 Asia/Taipei), so 24h and 72h
  never started. Controller receipt: `tmp/phase-iq-oct14-soak-suite/state.json`.
  These are preserved **pre-1.4.6 input** results; no duration or cycles will be
  carried into a new version's qualification run.

### October 12 recovery and replay follow-up (historical checkpoint)

The following source changes postdate the historical 852-test package. The October 12
881-test development gate and package cover them; their source receipt and
packaged recovery evidence are recorded below.

| Area | Follow-up correction | Verification boundary |
| --- | --- | --- |
| K | Atomically preserve one bounded, redacted undo slot for imported prompt/rules/model; restore checks Project/undo identity and current-field fingerprint; schema 2 preserves schema 1 reads; a nonblocking file lock rejects concurrent mutation without freezing the UI | Rollback, conflict, restart and lock tests pass in the 881-test gate; packaged accessibility restore/restart passes |
| L | Persist accepted redacted Steer text and a stable message ID before mailbox acceptance; reconcile only that transcript identity; expose per-record inspect/copy-to-draft/dismiss recovery on the originating idle Task | Stable-ID, persistence and recovery tests pass in the 881-test gate; packaged accessibility inspect/copy/dismiss/restart passes |
| M | Move producer identities into a separate non-evicting 16,384-entry ledger and write schema 3 so older apps cannot silently drop it; migrate retained legacy producer/per-Automation claims and event runs; reject malformed authority and reject new ingress when full | Replay after pruning/restart, failed-write and capacity tests pass in the 881-test gate; live GitHub ingress remains pending |
| Q | Preserve interrupted/abandoned soak evidence; enforce owner locks, bounded child logs/cleanup, fresh-run resume, stable inputs and continuous-time measurement; reject short-sleep/wall-clock drift as well as long heartbeat gaps | 28 soak harness tests are part of the passing Python contract run; no qualifying full-duration soak yet |

- October 12 Python contract run: **48 tests, one Linux-only worker skip, zero
  failures**, 62.256 seconds. Log: `tmp/phase-iq-oct12-python.log`. These are
  local contracts; the Linux isolation skip and external services remain
  unverified on this host.
- Focused Swift regressions pass: **70 tests, zero failures**, 7.432 seconds.
  Log: `tmp/phase-iq-oct12-focused-retry.log`. This includes new schema-2 import
  rollback, exact-ID Steer recovery and schema-3 replay ledger migration tests.
  The first compile exposed a `Darwin.flock` name collision; the corrected
  unqualified BSD `flock` call is covered by the held-lock and competing-store
  regressions. All **339** source/test/script/config files matched
  `tmp/phase-iq-oct12-source-receipt.json` at that packaging checkpoint.
- The full Swift integration suite passes **881 tests, one environment skip,
  zero failures**, 209.124 seconds. The skip remains the setuid system `top`
  executable rejected by the PTY sandbox. Log: `tmp/phase-iq-oct12-release.log`.
  The optimized arm64 build passed in 221.07 seconds, followed by ad-hoc signing,
  plist checks, ZIP/extracted-archive verification and security audit. The full
  release runner exited 0 (`tmp/phase-iq-oct12-release-result.json`). VS Code
  **17/17** and GitHub Action **14/14** pass; logs:
  `tmp/phase-iq-oct11-vscode.log` and `tmp/phase-iq-oct11-action.log`.
- October 12 development ZIP: `dist/LumaChat-1.4.5-arm64.zip`, SHA-256
  `c332aa0d10afae62054a38fc21d60f3d8c4f0d7a2f06314e75a3c12997e3c68d`.
  Frozen source fingerprint:
  `fa715a06f5a7d619cdfd3a170ffbc5b88e23f31c047b8380ca2009dee2548426`
  (`tmp/phase-iq-oct12-source-receipt.json`, 339 recorded files).
- On that package, native accessibility checks pass Steer per-record inspection,
  copying two different receipts once each, dismissing one and retaining the
  other across restart without sending. The same isolated profile passes
  instruction import/preview/save, restart, undo preview/restore and rejection
  of a repeated restore. Durable checkpoints confirm the imported value and
  undo before restart, the original prompt after restore, one remaining Steer
  receipt and zero session messages. Evidence:
  `tmp/phase-iq-oct12-recovery-ui/acceptance.json` and
  `tmp/phase-iq-oct12-recovery-ui/post-import-checkpoint.json`.
  The first app exit is recorded as 0; the second exit is not established.
  These checks cover synthetic Tasks through accessibility, not live model
  delivery, every crash boundary or pixel-layout acceptance.
- The old package did pass a real SIGKILL/relaunch Queue check on October 5:
  an unsaved editor draft was discarded, durable Queue/Session content was
  unchanged, and the original uncertain claim was not resent. The killed
  process returned `-9`; its replacement exited cleanly. Evidence:
  `tmp/phase-iq-review-ui-acceptance.md` and
  `tmp/phase-iq-review-crash-ui-attempt2.log`. This covers one synthetic paused
  Task and one kill boundary, not the newer recovery UI or every write point.
- The first real Chromium/CDP attempt is **partial, two of five operations**:
  product `browser_open` and `browser_snapshot` returned real browser results;
  the fixture stopped awaiting `browser_find`. Search, screenshot and close
  acceptance remain pending. Receipt: `tmp/phase-iq-browser-live/receipt.json`.
  The model driver and page were local deterministic fixtures; no live model
  or external-provider acceptance is claimed.
- The October 12 retry on that package passes real product
  `browser_open`, `browser_snapshot` and `browser_find` (four matches).
  `browser_screenshot` was cancelled after its 30-second tool timeout; no PNG
  success or `browser_close` acceptance is established for that attempt. The
  subsequent fix and debug rerun are recorded above. The preceding October 12
  attempt stopped because the fixture
  parser expected the wrong `browser_find` response shape; that fixture defect
  was corrected for this retry without changing product source. Both attempts
  are preserved at `tmp/phase-iq-oct12-browser-live/receipt.json` and
  `tmp/phase-iq-oct12-browser-retry/receipt.json`. The deterministic model driver
  does not constitute live model or external-provider acceptance.
- Neither existing 2h run qualifies. The second run is abandoned as detailed
  below. No new soak had started at this October 12 checkpoint; the October 14
  sequence is recorded above. 8h/24h/multi-day, live SSH/MCP/PR/OAuth/voice/Computer Use, executed Linux
  CI, Developer ID/notarization/stapling and production update/feed recovery
  evidence remain pending. The October 12 prerequisite check found no Developer
  ID identity or configured production signing/notary/feed values (presence-only
  receipt: `tmp/phase-iq-oct12-production-prerequisites.json`). This is development
  work, not a production release.

### Historical gate and interrupted soak evidence

- Focused Swift pass: 86 tests, zero failures; additional authority/MCP/memory
  pass: 42 tests, zero failures.
- After the native Queue editor and error-banner corrections, the complete
  release-script Swift gate passed **852 tests, one environment skip, zero
  failures** in 218.382 seconds. The skip is the system setuid `top` executable
  rejected by the PTY sandbox. Log: `tmp/phase-iq-review-verified-release.log`.
- Python archive/soak/security/worker contracts: **24 tests, one Linux-only
  worker skip, zero failures**. The worker suite is now part of `release.sh`.
- VS Code: **17/17**; GitHub Action: **14/14**. Python syntax and the two
  integration JSON schemas pass; `git diff --check` passes.
- The final optimized arm64 build passed (212.94 seconds), with development
  ad-hoc signing, plist checks, ZIP/extracted-archive verification and security
  audit. Development ZIP: `dist/LumaChat-1.4.5-arm64.zip`, SHA-256
  `e8696c66291824adaa6a0840bf37e9cf78da240095c6dfdae690bef48e7f6d76`.
- The final packaged native UI replay passed initial editor text, failed-save
  draft retention, successful retry/error clearing and restart persistence.
  The original uncertain queue claim remained unsent; both exits returned 0.
  Earlier replay also covered reorder/remove and transient Side chat file/image
  snapshots. Evidence: `tmp/phase-iq-review-ui-acceptance.md`. These are isolated
  synthetic-Task accessibility checks, not live model or pixel-layout acceptance.
- Frozen source receipt: `tmp/phase-iq-review-verified-source-receipt.json`;
  all 338 recorded source/test/script/config files matched after packaging.
- An actual **2h local integration soak** was launched at
  `2026-10-04T02:18:00Z` with the full 7,200-second profile (no dry-run or duration
  override). Run: `tmp/soak/a56eab72-1c1d-4701-8417-d32b17eaf82e/`; launcher log:
  `tmp/phase-iq-review-2h-soak.log`. It **failed in its first Agent shard**
  (`AgentProviderStreamingTests/testCancellingStreamingTransportCancelsURLSessionTask`)
  at `2026-10-04T02:22:07Z`; qualification is false. The failure was the test's
  fixed `Task.yield()` count expiring before URLSession started its request.
  The test now waits for an actual received line, then cancels and waits for
  the stop callback and Task completion, with bounded waits and failure cleanup.
  The complete streaming suite and 10 separate cancellation repeats pass;
  log: `tmp/phase-iq-review-streaming-regression.log`.
- After this test-only repair, the full Swift suite passed again: **852 tests,
  one environment skip, zero failures**, 205.019 seconds; log:
  `tmp/phase-iq-review-post-soak-swift.log`. Expanded soak coverage contracts
  bring the Python total to **26 tests, one Linux-only skip, zero failures**;
  log: `tmp/phase-iq-review-post-soak-python.log`.
- Soak filters now include the Phase I–Q memory/import, SSH/worker authority,
  Queue/Steer/Side chat/voice, webhook/PR and plugin/OAuth/MCP lifecycle suites.
  Whole-selector boundaries avoid matching unrelated class-name substrings.
  Source receipt: `tmp/phase-iq-review-soak-source-receipt.json`. Only the
  streaming test and two soak harness files changed after packaging; all
  product source and bundle inputs were identical to the verified ZIP at that
  checkpoint. Subsequent October 5–12 fixes require a new gate and package.
- A fresh full-duration 2h run started at `2026-10-04T14:36:35Z`:
  `tmp/soak/ef4a66ac-99ac-4057-81d3-343c28f906e2/`; launcher log:
  `tmp/phase-iq-review-2h-soak-retry.log`. The process subsequently disappeared
  before finalization. It is **abandoned, non-qualifying**, although its historical
  state file still says `running`. It recorded 60 complete cycles and 481 shards;
  the last persisted update is `2026-10-04T16:28:14Z`. The original evidence is
  preserved without rewriting it. Test inventory preparation precedes the
  7,200-second duration timer.
  The failed first run is retained separately. No qualifying result is claimed;
  8h, 24h and multi-day profiles remain unexecuted, and external acceptance is
  separate from these local integration/fixture exercises.
- Checkpoint at `2026-10-04T14:43:06Z`: the retry completed all eight first-cycle
  categories, **413 test executions, one environment skip, zero failures**, and
  entered cycle two. All 338 frozen files still match. Checkpoint evidence:
  `tmp/phase-iq-review-2h-soak-checkpoint.json`. This is progress evidence, not
  the full-duration acceptance result; this run later stopped before completion.

## Phase L–Q combined development gate (2026-10-01, historical)

The user requested implementation of all remaining phases before the next
integrated test and bug-fix pass. The local implementation and bug-fix pass now
has a clean development gate; it receives no new formal production score. See
[`PHASE_L_Q_ARCHITECTURE.md`](PHASE_L_Q_ARCHITECTURE.md) for the ownership and
security boundaries.

The frozen-source `Scripts/release.sh` gate passed **830 Swift tests** (one
environment skip, zero failures, 199.908 seconds), optimized arm64 build
(203.56 seconds), development ad-hoc signing, plist checks, canonical ZIP and
extracted archive verification. The resulting development ZIP is
`dist/LumaChat-1.4.5-arm64.zip`, SHA-256
`3e9bae3364eae6c725d229ac22d6e8d5b0c7ec55dd9dd127326a52b05828723a`.
The packaged worker script matches its source byte for byte. The local worker
protocol suite passed three tests; its Linux-only process-cancel case was
skipped on macOS and awaits the Linux CI run. `git diff --check` passed.

An isolated-profile smoke launched the final packaged App, created an Agent
Task, confirmed the microphone control and Pull Requests/Extensions settings,
then quit cleanly. The GitLab provider selector was exercised on the prior
development bundle; the final bundle showed the same Pull Requests setting
surface. This does not cover an active Queue, Side chat attachments, microphone
permission, remote worker, or real external provider flows.

| Phase | Current source path | Still required before completion |
| --- | --- | --- |
| L | Durable Steer acceptance receipts, text/image Queue editing and recovery, selected read-only Side chat snapshots; focused store/session tests and full Swift gate pass | Active Queue/Side chat packaged UI and real crash acceptance |
| M | GitLab PR adapter and HMAC-verified GitHub webhook projection into durable Automation event scheduling; provider/webhook/replay tests pass | Authorized GitLab/GitHub live acceptance and HTTPS webhook ingress configuration |
| N | On-device macOS Speech recognition, Task composer controls and interruptible synthesis; permission/interruption tests pass and packaged mic control is visible | Real microphone permission and spoken Task interaction acceptance |
| O | Linux Python command worker over pinned outbound SSH, independent worktree, job binding/heartbeat/reconnect/cancel/log/diff; journaled textual patch takeover into a new local managed worktree Task; local protocol and Swift path tests pass | Linux CI execution, real-host and fault acceptance; v1 supports command jobs and textual patch takeover, with full remote Agent runtime and binary takeover outside the minimal worker scope |
| P | Registry-pinned package digest, source/update/permission preview, OAuth refresh/revoke/recovery; 1.4.8 candidate adds modern stateless MCP core profile and legacy compatibility; focused/full local gates pass as recorded above | Current-source hosted CI; supported-provider live acceptance; optional unadvertised MCP client capabilities remain unsupported |
| Q | macOS development and Linux worker CI definitions; development release gate and limited packaged native UI smoke pass | External acceptance, Developer ID/notary/staple/feed/rollback and qualifying 2h/8h/24h/multi-day soak |

No Developer ID identity, notary profile, published feed, external service
credentials or authorized SSH test host has been supplied in this task. Their
live acceptance remains pending; deterministic fixture tests cannot substitute
for it. The 1.4.5 development artifact is not a new formal production release.

## 100-point capability matrix (formal 2026-09-25 gate)

| Capability | Weight | Before | After | State | Evidence and tests | Known limitations |
| --- | ---: | ---: | ---: | --- | --- | --- |
| Agent Core and model providers | 12 | 12 | 12 | PARTIAL | Bounded Runtime, provider adapters, tool loop and regression suites | Long-run soak, broader model fixtures, structured event bus |
| Permission, workspace, change safety | 8 | 8 | 8 | PARTIAL | Descriptor-safe I/O, scoped approvals, Undo/checkpoint/security suites; SSH identity reaches local approval cards; combined development gate passes | OS/backend generalization and live external acceptance remain |
| Projects | 5 | 5 | 5 | COMPLETE | Projects 2.0 catalog/migration/UI/tests; location metadata remains one-folder scoped | Complete for documented local scope |
| Tasks, concurrency, crash resume | 5 | 5 | 5 | PARTIAL | Per-Task Runtime, durable sessions, background navigation, transaction recovery; Task PTYs survive navigation and Agent Stop; Review Tasks persist a locked source contract and structured result | PTY process reattachment, browser/subagent structured resume and kill-stage drills |
| Goals, context, compaction, memory | 4 | 4 | 4 | PARTIAL | Durable Goal/Todo/context bounds and tests | Searchable session/project/user memory and category budgets |
| Managed worktrees and writable isolation | 6 | 1 | 5.5 | PARTIAL | Registry, leases, create/reuse/list/inspect/remove/cleanup/repair, location UI, lifecycle/E2E tests | Historical gate lacked maintenance UI; scheduler, retained branches and orphan edge coverage remain |
| Task handoff and Task fork | 4 | 0 | 3 | PARTIAL / DEVELOPMENT-GATED | Release-gated Local ↔ Worktree CAS/Fork plus development-gated bounded Local/Worktree ↔ SSH migration and host rollback | Remote routes await live-host acceptance; SSH-to-SSH and broader kill/storage matrix remain |
| PTY terminal and task terminal sessions | 6 | 4 | 5.5 | PARTIAL / DEVELOPMENT-GATED | Local `forkpty`/Task Terminal plus bounded one-shot `remote_pty_run`; signal-crash test passes | No old-process/scrollback reattach; no persistent remote input/resize/reconnect; non-Darwin and long soak remain |
| Git lifecycle and advanced Git | 5 | 4 | 5 | COMPLETE | Normal/pointer/submodule/detached layouts; closed status/diff/log/show/branch/commit plus fetch/pull/push/switch/hard-reset/merge/rebase/cherry-pick/stash/tag/remote API; 21/21 focused and integrated release gate | Remote effects lack local Undo; linked-metadata limitations are surfaced rather than hidden |
| Review, inline comments, PR workflow | 5 | 2 | 4.5 | PARTIAL | Five complete typed sources, frozen Last Agent Turn, native file/unified/side-by-side pane, file/hunk Stage/Unstage/Revert, durable comments, isolated Review Tasks/findings, GitHub PR adapter/Keychain/tools and packaged UI smoke; Phase M later adds the GitLab merge-request adapter | No authorized live GitHub/GitLab PR mutation E2E; provider-omitted patches remain unknowable |
| Subagents and scheduler | 5 | 0 | 0 | DEVELOPMENT-GATED | Durable child Tasks, seven tools, actor scheduler, budgets, scoped read/worktree isolation, structured aggregation, UI and passing focused tests | Live high-concurrency/long-duration acceptance remains |
| Skills | 4 | 0.5 | 0.5 | DEVELOPMENT-GATED | Five-source `SKILL.md` discovery, precedence, `$skill`/description selection, transient instructions, loaded metadata, exact-ID resource tool, UI and passing focused tests | Scripts intentionally do not auto-execute; live ecosystem breadth remains |
| Plugins, Hooks, OAuth connectors | 5 | 0 | 0 | DEVELOPMENT-GATED | Manifest/manager, atomic lifecycle, permission UI, sandboxed tools, typed hooks, PKCE and Keychain store pass combined gate | No hosted marketplace/signature transparency, OAuth live-provider refresh/device flow, or portable WASM sandbox |
| MCP tools/resources/prompts | 4 | 4 | 4 | PARTIAL / DEVELOPMENT-GATED | STDIO/Streamable HTTP, tools/resources/prompts, Keychain/tests, plugin ownership, and real child-process crash coverage | Historical gate lacked richer health/restart UX; live-server breadth remains |
| Browser and DOM/CDP automation | 5 | 1.5 | 1.5 | DEVELOPMENT-GATED | Task-owned Chromium/CDP, isolated/persistent/attached profiles, bounded surfaces, downloads, annotations, focused tests and crash cleanup | Real-Chromium/package UI and long soak remain; bounded selectors do not cover every dynamic/shadow-DOM app |
| Computer Use | 2 | 2 | 2 | DEVELOPMENT-GATED | Opt-in allowlist, safe-window selection, capture-bound AX, verification, approval UI, secret refusal and passing focused tests | Live native packaged UI pending; no broad AX action surface or locked-screen execution |
| Automations and notifications | 4 | 0 | 0 | DEVELOPMENT-GATED | Durable scheduler/store/history, seven Task actions, dedicated worktrees, typed notifications, routing and passing focused tests | External event producers, native UI acceptance and soak remain |
| Remote execution and control | 4 | 0 | 0 | PARTIAL / DEVELOPMENT-GATED | SSH runner/store/Keychain, strict host receipt, 16 closed tools, migration, Settings/UI, focused and disconnect-boundary tests | Live-host E2E, persistent remote PTY, richer backends, secure relay and soak remain |
| CLI, App Server, SDK, IDE and GitHub | 4 | 0 | 0 | DEVELOPMENT-GATED | Shared-runtime CLI, authenticated server/SSE, Swift SDK, VS Code 17/17, GitHub Action 14/14 and package paths | Historical gate had process-local idempotency; live transport/hosted-runner acceptance remains |
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
  is not available and provider tests use controlled transports. The Phase B
  gate included only GitHub; Phase M subsequently adds the GitLab merge-request
  adapter. Neither provider has a recorded authorized
  push→create→open→review end-to-end acceptance run. Bitbucket remains a future
  extension.
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
- At the historical Phase F gate, the remote PTY was deliberately one-shot.
  The later Phase I development follow-up above adds a separate interactive
  Task Terminal; live acceptance remains pending. `.futureCloud` remains only
  a versioned fail-closed seam; no relay or hosted service is claimed.
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
