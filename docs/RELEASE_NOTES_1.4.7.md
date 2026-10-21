# Luma Chat 1.4.7 — Integrated Patch Release

- Status updated: 2026-10-20
- Source version/build: `1.4.7` / `14`
- Release channel: regular GitHub Release from `main` (prerelease disabled)
- Status: published; final local gate/package, hosted macOS/Linux CI and limited native smoke evidence pass
- Published: 2026-10-19 23:05:13 Asia/Taipei (`2026-10-19T15:05:13Z`)
- Release commit: `890574e29000f009c8b7c69f6f3df53d2449deaf`
- Release: [v1.4.7](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.7) — regular release, latest at publication
- Signing boundary: verified ad-hoc package for private use; Apple distribution
  and production signed-update acceptance are `not_required_for_private_use`

This patch follows the immutable [1.4.6 release](RELEASE_NOTES_1.4.6.md).
The published 1.4.6 tag and artifacts remain unchanged. The 1.4.7 archive
below is published and scoped to its exact verified source. Temporary DEBUG
timing instrumentation was removed in `bb26729`. Final source `eeddc75` adds only
HTTP fixture ordering/liveness corrections; its production source and workflow
match the previously verified candidates.

## Private-use completion scope

The user explicitly requested private use without Apple signing ("不用簽 我私用").
Developer ID signing, notarization, stapling, the production update feed and
live signed-update/rollback acceptance are therefore outside this request's
completion conditions, recorded as `not_required_for_private_use`. They were
not executed or passed. The published ad-hoc artifact and its evidence remain
unchanged. Missing production identities/configuration remain prerequisites
for any later production distribution, and the updater's existing trust,
signature and fail-closed checks remain intact. Functional external acceptance
and version-bound soak still require their own results.

The user chose to defer providing external model, SSH, MCP and test repository
targets ("先不提供"). Live acceptance requiring those targets is
`deferred_by_user`; it was not executed or passed. This decision does not change
the scope of existing local fixture or hosted CI evidence.

## Verified changes

- Carry the post-1.4.6 Swift 6.2.4 compatibility corrections into a versioned
  package: explicit numeric conversions and simpler context-count expressions,
  preserving calculation order and test assertions.
- Replace environment-specific test paths with portable isolated fixtures.
  Inject the conversation store directory for tests so cleanup tests cannot
  delete another fixture's shared store; normal application storage keeps its
  existing default directory.
- Route Python through the selected, already-authorized developer tool root,
  avoiding the system `xcrun` dispatcher's host metadata/cache dependencies.
  Exact path boundaries and quoted paths are preserved; a Command Line Tools
  fallback works within the existing authorized roots. This adds no filesystem
  read grant.
- Give OpenSSL-linked tools an empty configuration inside their isolated
  execution directory, preventing an implicit read of host-wide configuration.
  This preserves library defaults and does not disable TLS verification.
- Replace quadratic scanning of large MCP newline-framed messages with bounded
  incremental framing, preserving message-size and malformed-input checks.
- Omit STDOUT diagnostic payloads over 64 KiB using a size-only marker, while
  delivering the complete wire response. This bounds synchronous redaction work
  without logging partial secrets or changing protocol limits.
- Rewrite developer executables using a conservative shell-word scanner, keeping
  embedded scripts, literal arguments, comments and redirect operands intact.
- Give hosted CI explicit workspace-local Application Support and runtime
  temporary directories, matching the isolated local verification boundary.
- Pace fragmented MCP test output against an absolute monotonic schedule, with
  a yield after at most eight catch-up writes. This prevents background timer
  coalescing from accumulating across 257 relative sleeps; the 4 MiB payload,
  16 KiB writes and ten-second request deadline are unchanged.
- Serialize HTTP test stream callbacks in wire byte order, including reversed
  chunk deadlines, and cancel scheduled callbacks with the fixture lifecycle.
  GET and POST SSE tests keep the response stream open and assert completion
  after the matching event, instead of relying on a narrow elapsed-time window.

## Release verification

Verified source before the packaging commit: `eeddc7508348fe236c51d46b4cab55b914f2ff13`.
The frozen receipt `tmp/release-1.4.7-ready-source-receipt.json` covers **341 inputs**,
fingerprint `6b456593bccf15a34e1eb207507ce7afe9bae87b296e8aea56e558951140ade0`.
[Hosted macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39190608251)
**passes: 896 Swift tests, two skips, zero failures, 219.665 seconds**, on Xcode
26.3 / Apple Swift 6.2.4. Debug compilation takes 186.12 seconds; the optimized
build step also passes. Archive contracts **7/7** and soak harness contracts
**28/28** pass with no skips. Evidence: `tmp/release-1.4.7-macos-ready-ci.log`.
The HTTP fixture's focused run additionally passes **eight tests, zero skips or
failures, 1.187 seconds** (`tmp/release-1.4.7-http-ordering-focused.log`).

The final source changes only the HTTP test fixture after `bb26729`: callbacks
are serialized in byte order, reversed deadlines cannot reorder chunks, and
GET/POST SSE completion is verified while the fixture stream remains open.
The production transport and request deadlines are unchanged. This corrects
the earlier hosted fixture failure recorded below.

The fresh complete local release gate **passes**, exit 0, with all frozen source
receipts matching: **896 Swift tests, one environment skip, zero failures,
255.063 seconds**; **48 Python contracts, one Linux-only skip, zero failures**.
The Python suites comprise archive 7 (2.245 seconds), soak 28 (4.571 seconds),
security 3 (0.007 seconds) and worker 10 (13.509 seconds). Debug and optimized
arm64 compilation pass in 404.04 and 184.48 seconds. Ad-hoc signing,
plist/archive/extracted-App checks, security audit and extracted CLI version
**LumaChat 1.4.7** pass. Evidence: `tmp/release-1.4.7-ready.log` and
`tmp/release-1.4.7-ready-result.json`.
[Linux worker CI for this source](https://github.com/TonyChen-Git/RLM/actions/runs/39226505634)
passes **ten tests, zero skips/failures, 5.348 seconds**; evidence:
`tmp/release-1.4.7-linux-ready-ci.log`.

All five final package artifact hashes match the preceding `bb26729`/`744fb73`
packages. Final ZIP SHA-256:
`44d2ceb9cd7e45dc81e4a12fa78c0058cd1b880404f24843ed55442c7c8df856`.
The App binary SHA-256 is
`12516c88ccf60286c808f3bba6f867e668e0c6b998e3b3689274d0d0061f2b79`.

The October 19 native smoke on the identical package passes startup, idle Task
accessibility, About accessibility and screenshot showing **1.4.7 (14)**,
and Cmd-Q with exit 0. It creates zero Task messages and performs zero Browser
operations. No model, microphone or external-provider acceptance is implied.
The original receipt `tmp/release-1.4.7-ui/acceptance.json` retains its `bb26729`
source scope; `tmp/release-1.4.7-native-artifact-equivalence.json` verifies the
final source's archive and binary match that tested package exactly.

## Post-publication exact-tag CI verification — 2026-10-20

The immutable release commit `890574e29000f009c8b7c69f6f3df53d2449deaf`
also passes its own hosted CI. These results are additional evidence; the
earlier `eeddc75` source CI records above remain unchanged.

- [macOS run 39274782878](https://github.com/TonyChen-Git/RLM/actions/runs/39274782878):
  **896 Swift tests, two skips, zero failures, 243.144 seconds**, on Xcode 26.3
  build 17C529 / Swift 6.2.4. Debug compilation takes 189.74 seconds; optimized
  desktop compilation passes in 456.01 seconds. Archive contracts **7/7** and
  soak harness contracts **28/28** pass without skips. The skips are unavailable
  Homebrew `htop` and the intentionally sandbox-blocked setuid system `top`.
- [Linux run 39274782832](https://github.com/TonyChen-Git/RLM/actions/runs/39274782832):
  **ten worker protocol tests, zero skips/failures, 7.197 seconds**.

Immutable receipt: `tmp/release-1.4.7-tag-ci-acceptance.json`; completed logs:
`tmp/release-1.4.7-tag-macos-ci.log` and `tmp/release-1.4.7-tag-linux-ci.log`.
The validation record stores these under `postPublicationTagCI`. Hosted CI does
not provide external-account/provider or Apple production-distribution acceptance.

## Confirmed STDIO fixture timing diagnosis

The [diagnostic hosted run](https://github.com/TonyChen-Git/RLM/actions/runs/38984361251)
on temporary DEBUG source `49ed176` failed with 896 tests, two skips and two
failures (248.981 seconds). It received only 3 MiB of a 4 MiB fixture response
by 9.096 seconds, before the ten-second request timeout. For a separate 1 MiB
response, diagnostic logging and decoding together took about three
milliseconds. These observations identify incomplete fixture delivery; the
framing/logging optimizations alone were not the cause or cure of the timeout.
Evidence: `tmp/release-1.4.7-mcp-timing-ci.log`.

Controlled local timing experiments show 257 relative ten-millisecond sleeps
taking 3.101 seconds normally and 25.098 seconds under macOS background policy.
Absolute monotonic scheduling with a yield after at most eight catch-up writes
takes about 2.572 seconds in both modes. These writes target `/dev/null` and
are timing experiments, not MCP live acceptance. Evidence:
`tmp/release-1.4.7-pacing-experiment.json` and
`tmp/release-1.4.7-pacing-experiment-yield.json`.
Commit `bb26729` applies that fixture correction and removes all temporary
DEBUG instrumentation. The subsequent hosted STDIO tests pass as recorded above.

Focused checks remain scoped to their inputs: wrapper/validation/Git on
`744fb73` passes **34 tests, zero skips/failures, 67.723 seconds**; earlier
MCP/validation/PTY on `c90b394` passes **71 tests, one skip, zero failures,
43.938 seconds**. Fresh Node checks pass **VS Code 17/17** and **GitHub Action
14/14**, zero failures. Exact logs and digests are in the
[validation receipt](validation/1.4.7.json).

## Preserved earlier attempts

- `bb26729`: complete local gate passes 896 Swift tests, one skip, zero failures
  (248.766 seconds), plus 48 Python contracts, one Linux-only skip, zero failures.
  Debug/optimized compilation takes 319.42/190.09 seconds; ad-hoc signing,
  archive/extracted-App checks, security audit and extracted CLI version 1.4.7
  pass. The frozen 341-input fingerprint is
  `88aed53e06a0465f0bb678e0a29c3a0e03100b87b6977888748099a159ba8533`.
  Logs/results retain the `tmp/release-1.4.7-verified` prefix; all five artifact
  hashes match the earlier `744fb73` package. [Linux worker CI](https://github.com/TonyChen-Git/RLM/actions/runs/39040615622)
  passes ten tests, zero skips/failures (7.933 seconds).
  [Hosted macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39040583738)
  runs 896 tests, two skips and one unexpected failure (262.973 seconds). All
  STDIO resource/prompt tests pass; the GET SSE fixture reports malformed
  JSON-RPC after 2.627 seconds. Its independently scheduled callbacks could
  reorder byte chunks on a busy runner; `eeddc75` corrects that fixture.
- `744fb73`: the complete local gate passes 896 Swift tests, one skip, zero
  failures (246.439 seconds), and 48 Python contracts, one skip, zero failures.
  Debug/optimized compilation takes 366.68/185.57 seconds; package verification
  passes. Its 341-input fingerprint is
  `8c2560cb10b219e6d9308bf93d4b130acfc3ae3b4bc607224e28e9adde1d76f4`.
  [Linux worker CI](https://github.com/TonyChen-Git/RLM/actions/runs/38906788610)
  passes ten tests, zero skips/failures (8.819 seconds), while
  [hosted macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/38906726117)
  fails with 896 tests, two skips and two failures (244.320 seconds), both paced
  4 MiB STDIO responses hitting the ten-second request deadline. Logs and source
  receipt retain the `tmp/release-1.4.7-final` prefix. This earlier local pass
  does not override its hosted failures.
- `8882175`: local 894 tests, one skip, one failure (248.268 seconds); hosted
  894 tests, two skips, two failures (274.910 seconds). The new OpenSSL fixture
  incorrectly used `/usr/bin/test`, corrected to `/bin/test`. The other hosted
  failure was an MCP timeout; its cause remained under investigation.
  Evidence is preserved in `tmp/release-1.4.7-attempt1/`.
- `c90b394`: the full local gate was deliberately interrupted before packaging
  after review found TerminalSession's appended `$?` wrapper bypassing developer
  shims. The local runner recorded exit 1 after the owned test child was stopped;
  hosted run `38904852630` was cancelled. The subsequent correction treats simple
  variables as opaque data and preserves conservative handling of nested
  expansion. Interrupted results do not count as a completed gate.

## Triggering evidence and validation boundary

The post-publication 1.4.6 follow-up on commit `0d9364b` compiled under Xcode
26.3 build 17C529 / Apple Swift 6.2.4, then its
[hosted run](https://github.com/TonyChen-Git/RLM/actions/runs/38698727639) failed:
**886 tests, two skips, eight failures (four unexpected), 342.539 seconds**.
The final local focused run on that commit separately passed **45 tests, zero
skips, zero failures, 40.665 seconds**. That focused result did not cover all
hosted failures. The original 1.4.6 package's passing local release gate remains
scoped to its release commit and toolchain.

The exact 1.4.6 release source also has a qualifying 2h soak: 7,227.507 measured
seconds, 48 complete cycles, 386 completed shards, zero failures. Its following
8h run was interrupted and does not qualify; 24h and 72h never began. Those
receipts remain 1.4.6 evidence and provide **no 1.4.7 soak qualification**.

## Publication

`main` and annotated tag `v1.4.7` were pushed at release commit
`890574e29000f009c8b7c69f6f3df53d2449deaf`. The GitHub Release has `draft: false`
and `prerelease: false`; it was latest at verification. All five uploaded asset
sizes and API SHA-256 digests match the verified local artifacts. Receipt:
`tmp/release-1.4.7-publication.json`. The tag remains fixed; later acceptance
records are follow-up documentation on `main`.

## Cleanup before publication

Removed 3,805,715,145 bytes of rebuildable caches from the root build, the
completed 1.4.7 release stage and inactive 1.4.6 soak runs. Release archives,
source snapshots, logs and receipts are preserved. Receipt:
`tmp/release-1.4.7-cleanup.json`. No unmerged local branch commits remain.

## Packaged local acceptance — 2026-10-20

The published 1.4.7 binary passes **five actual Chrome operations** through the
product: open, DOM snapshot, find, PNG screenshot and close. The 1280×657 PNG
shows the unique fixture label and was visually inspected. Task completion,
all five tool results and the screenshot remain available after App restart.
Both App runs exit 0; no owned Chrome process or ephemeral profile remains.
The model and page are local deterministic fixtures, not external providers.
Receipt: `tmp/release-1.4.7-browser-acceptance/acceptance.json`.

The Browser annotation pane passes visual/accessibility inspection. Saving a
drawn annotation remains unverified: the UI automation tool rejects dragging
with `noWindowsAvailable`. Native speech playback changes the control to Stop;
stopping restores Play. This verifies playback controls, not independently
heard audio, microphone recognition or navigation interruption. Computer Use
settings show the disabled default, empty allowlist, vision requirement,
screenshot destination disclosure and OS permission controls; no capture,
action or permission grant was performed.

## Version-bound soak — updated 2026-10-20

A fresh 2h → 8h → 24h → 72h sequence launched at **23:07:46 Asia/Taipei**
(`15:07:46Z`) from an isolated archive of the exact `v1.4.7` release commit.
All **464 tracked files** and the **341-input/source/toolchain** receipt match
that release. The original checkpoint records preparation; measured duration
starts after preparation. No prior version's duration or result is reused.
Snapshot receipt: `tmp/release-1.4.7-tag-source-verification.json`; immutable
launch checkpoint: `tmp/release-1.4.7-soak-start-checkpoint.json`; live controller
state: `tmp/release-1.4.7-soak-suite/state.json`.

The **2h run qualifies**: `9e7bfc70-4fe5-411c-af72-c89055c0f18d`,
7,257.719 continuous seconds, 52 complete cycles, 418 completed shards,
zero failures, completed `2026-10-19T17:14:51Z`.
The first 8h attempt reaches 27,071.070 seconds, 187 cycles and 1,499 shards
before the clock guard rejects a 452-second clamshell sleep on battery.
The second reaches 7,588.814 seconds, 51 cycles and 412 shards before an
interruption signal stops it, exit 130; the signal's sender is unknown.
Neither 8h attempt qualifies. Their final states and evidence are retained in
`tmp/release-1.4.7-soak-oct20-checkpoint.json`.

A fresh **8h → 24h → 72h** sequence launched at `2026-10-20T06:37:55Z`
after confirming AC power and an open lid. It uses the same immutable source
and fresh timing; the initial 8h run is
`b63ab86f-26b4-42af-93b5-40aff7289d16`. The controller is detached from the
launcher's terminal and records interruption signals. Launch evidence:
`tmp/release-1.4.7-soak-retry2-launch-checkpoint.json`; live state:
`tmp/release-1.4.7-soak-retry2-suite/state.json`.
This third 8h attempt stops at `2026-10-20T09:19:07Z` after 9,317.128 seconds,
64 complete cycles and 513 completed shards. Its 65th PTY shard runs 81 tests
with one skip and one failure: the real pip fixture does not observe
`Proceed (Y/n)?` within ten seconds. This is a failed result; 24h/72h have not
started. Final evidence:
`tmp/release-1.4.7-soak-retry2-failure-checkpoint.json`.
External-provider acceptance remains separate from this local soak.

### Post-publication test correction

The failed prompt helper previously recorded an assertion and continued,
allowing the fixture to send `n` without seeing the prompt. It now throws and
cleans up, reporting elapsed time, process state and at most 8 KiB of raw
output, escaped for logging. The real pip invocation adds `-B`, avoiding
unrelated bytecode cache writes in the PTY's fresh cache directory. Its prompt deadline, real package
manager, sandbox and refusal assertions remain unchanged.

A separate local import experiment using Python 3.9.6 measures default imports
at 2.021/3.118 seconds with 350 new cache files (4,335,258 bytes) each; `-B`
takes 0.444/0.419 seconds with no cache files. This supports reducing disk work,
but does not prove the original timeout's sole cause and is not PTY acceptance.
Evidence: `tmp/pip-import-diagnosis-20261020T151531Z/result.json`.
These are test-only changes on `main`, outside the immutable release tag;
they do not change the published application binary or retroactively pass
the failed soak.

On **October 21**, the frozen correction passes **22 PTY tests, one existing
setuid-top environment skip, zero failures, 27.718 seconds**, followed by two
additional real-pip passes (11.877/15.013 seconds, zero skips/failures). These
durations include fixture setup and cleanup; the prompt deadline remains ten
seconds. Before/after source and toolchain receipts match fingerprint
`d295b7da89b9a78a6cda360ab948c79f51c8716ab0b9e592e67a64f0f670a1c9`.
Only `Tests/LumaChatTests/PseudoTerminalSessionTests.swift` differs among the
341 release inputs. Receipt and logs: `tmp/pty-pip-oct20/verification.json`.
Future soak evidence from this corrected test suite must retain its distinct
source fingerprint and cannot be called an unchanged release-tag test run.

### Corrected-test soak launch — October 21

Commit `fdcabc20a9c6538c76b1089afaf8a872af2c17e6` is pushed directly to `main`.
A verified 464-file archive of that commit starts a fresh **8h → 24h → 72h**
sequence at **09:31:01 Asia/Taipei** (`01:31:01Z`). Production inputs remain
identical to v1.4.7; this sequence uses the corrected PTY tests and the distinct
fingerprint above. It does not alter the published tag/package or qualify its
previous failed attempts. AC power and an open lid are confirmed at launch.
The first run is `ccb2e92e-d3da-428c-af8f-25fd86ca7031`, preparing at the
immutable checkpoint, with no measured duration or passing result yet.
Later profiles start only after the preceding profile qualifies; no old time
is reused. Snapshot verification:
`tmp/release-1.4.7-corrected-tests-source-verification.json`; launch checkpoint:
`tmp/release-1.4.7-corrected-soak-launch-checkpoint.json`; live state:
`tmp/release-1.4.7-corrected-soak-suite/state.json`.

The correction also triggers [macOS CI](https://github.com/TonyChen-Git/RLM/actions/runs/39527531264),
in progress at `tmp/release-1.4.7-correction-ci-launch-checkpoint.json`.
This launch status adds no completed CI result; original release/tag CI evidence
remains separate.

## Pending for private-use 1.4.7

- Qualifying 8h, 24h and 72h results; the exact-version 2h run has passed.
- Native annotation write, microphone recognition/navigation interruption and
  actual Computer Use capture/action acceptance beyond the scoped checks above.
- External SSH/MCP/PR/OAuth/model/voice/Computer Use acceptance where no real
  receipt exists. The requested external model, SSH, MCP and test repository
  targets are currently `deferred_by_user`; their live acceptance remains unrun.

Future production distribution additionally requires Developer ID identity and
private key, Team ID, a notarytool Keychain profile, production HTTPS feed and
archive URLs, an Ed25519 update signing key, `SOURCE_DATE_EPOCH`, and successful
signing/notarization/stapling/feed/update-recovery acceptance. These requirements
are retained for that future scope and are not private-use blockers or passes.

See the [current validation receipt](validation/1.4.7.json),
[parity audit](CODEX_FULL_PARITY_AUDIT.md) and
[1.4.6 validation receipt](validation/1.4.6.json) for retained earlier evidence.
