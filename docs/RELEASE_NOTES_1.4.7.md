# Luma Chat 1.4.7 — Patch Release Preparation

- Status updated: 2026-10-19
- Source version/build: `1.4.7` / `14`
- Intended channel: regular GitHub Release from `main` (prerelease disabled)
- Status: ready for publication; final local gate/package, hosted macOS/Linux CI and limited native smoke evidence pass
- Signing boundary: verified ad-hoc package; Apple Developer ID,
  notarization/stapling and production update-feed acceptance remain pending

This patch follows the immutable [1.4.6 release](RELEASE_NOTES_1.4.6.md).
The published 1.4.6 tag and artifacts remain unchanged. The 1.4.7 candidate
archive below is unpublished and scoped to its exact source. Temporary DEBUG
timing instrumentation was removed in `bb26729`. Final source `eeddc75` adds only
HTTP fixture ordering/liveness corrections; its production source and workflow
match the previously verified candidates.

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

## Final candidate verification

Candidate source: `eeddc7508348fe236c51d46b4cab55b914f2ff13`.
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
final source's archive and binary match that tested package exactly. No second
UI run or final publication is claimed.

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

## Cleanup before publication

Removed 3,805,715,145 bytes of rebuildable caches from the root build, the
completed 1.4.7 release stage and inactive 1.4.6 soak runs. Release archives,
source snapshots, logs and receipts are preserved. Receipt:
`tmp/release-1.4.7-cleanup.json`. No unmerged local branch commits remain.

## Pending for 1.4.7

- Publish the verified regular GitHub Release from `main` and record the
  release commit/tag, uploaded artifact sizes/digests and publication receipt.
- Fresh version-bound soak; external SSH/MCP/PR/OAuth/model/voice/Computer Use
  acceptance where no real receipt exists.
- Apple Developer ID signing, notarization/stapling and production update-feed
  and rollback acceptance.

See the [current validation receipt](validation/1.4.7.json),
[parity audit](CODEX_FULL_PARITY_AUDIT.md) and
[1.4.6 validation receipt](validation/1.4.6.json) for retained earlier evidence.
