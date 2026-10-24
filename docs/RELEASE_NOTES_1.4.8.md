# Luma Chat 1.4.8 — Stateless MCP and Recovery

- Status updated: 2026-10-24
- Source version/build: `1.4.8` / `15`
- Status: published; local gate, packaging, limited MCP native UI and exact-commit
  hosted CI passed; source-bound soak not yet qualified
- Release channel: [regular GitHub Release](https://github.com/TonyChen-Git/RLM/releases/tag/v1.4.8) from `main`
- Release commit: `888addf6219a29487b2f45e91d5b5b9c39319242`
- Published: 2026-10-24 14:21:08 Asia/Taipei
- Signing boundary: verified ad-hoc package for private use

This release integrates the modern MCP implementation after the immutable
[1.4.7 release](RELEASE_NOTES_1.4.7.md). The existing 1.4.7 tag, package and
historical acceptance results retain their original scope. Publication does
not imply completed external acceptance or source-bound soak.

## Integrated changes

- Support the stable MCP `2026-07-28` stateless core profile over STDIO and
  Streamable HTTP, retaining `2025-06-18` legacy compatibility. Persist
  Automatic, legacy and stateless modes; existing configurations and plugin
  declarations migrate to legacy, while new Settings drafts use Automatic.
  Settings shows the negotiated protocol.
- Negotiate modern connections with read-only `server/discover`, then attach
  the protocol version, empty client capabilities and client identity to each
  request. Core tools, resources, resource templates and prompts use bounded
  validation. HTTP accepts JSON or request-scoped SSE without protocol
  sessions or GET reconnection. Only compatible discovery-probe failures can
  select a fresh legacy lifecycle; authentication failures cannot downgrade.
- Add bounded `Mcp-Method`, `Mcp-Name` and `x-mcp-header` schema projections.
  Protocol-owned headers cannot be overridden by configured headers. Invalid
  annotated tools are excluded with redacted diagnostics; valid tools still
  replace the discovery registry.
- Remove automatic replay after expired sessions or uncertain transport
  results. Failed connections retire tool authority and require explicit
  reconnect. Connection/discovery tokens and exact descriptor checks reject
  stale adapters after schema or permission changes. Failed tool discovery
  disables execution until discovery succeeds. STDIO negotiation waits for
  old-process cleanup before starting its replacement.
- Disconnect affected servers and invalidate approvals before saving MCP
  configuration. Publish only committed settings; ambiguous persistence or
  failed readback leaves affected servers disconnected. Keychain credential
  staging preserves the recovery boundary without writing secrets to JSON.
- Let Settings connection actions wrap at narrower widths and allow complete
  protocol and discovery diagnostics to remain visible. The first packaged UI
  run exposed truncated buttons and warnings; its separate evidence is retained.
- Include the post-1.4.7 PTY fixture correction: real pip probes avoid Python
  bytecode writes, and prompt waits fail immediately with bounded escaped
  diagnostics. Existing request deadlines and sandbox restrictions remain.

The modern profile advertises no optional client capabilities. MRTR
`input_required`, sampling, elicitation and other unadvertised capabilities
are explicitly unsupported. Users must inspect uncertain remote outcomes
before retrying. This is a supported core profile, not universal MCP provider
compatibility. Architecture and official protocol references are in
[Phase L–Q architecture](PHASE_L_Q_ARCHITECTURE.md).

## Completed local verification

The final full gate, including the Settings layout correction, started at
`2026-10-23T13:40:48Z` and reached the last release-script footer at
`2026-10-23T13:55:03Z` (21:40–21:55 Asia/Taipei; finish time from log mtime).
Its receipt covers **350 inputs**, fingerprint
`f7c34cecebea6d19723774fc017dbb33ed5d4fe0d46140df717d25ece5cbe29f`.
The starting commit was `2f17a1aca6bc15be52417d184d01b98762555684` with the
implementation and version bump uncommitted.

The controller stopped before saving its final status, so the original process
exit code is unavailable. The complete log records all gate results and the
script's final archive hash. Recovery on `2026-10-24T00:54:32Z` verified that
the starting input receipt still matches, and repeated signature, archive CRC
and CLI-version checks with exit 0. The original stale controller record is
retained; no original exit code or immediate end-of-gate receipt is inferred.

| Check | Result |
| --- | --- |
| Full Swift suite | 962 tests, 1 skip, 0 failures; 253.914 seconds |
| Python contracts | 48 tests, 1 skip, 0 failures |
| Debug / optimized arm64 compilation | Passed; 347.02 / 177.47 seconds |
| VS Code / GitHub Action local contracts | 17/17 and 14/14; no skips or failures |
| Ad-hoc signing and strict deep verification | Passed for bundle and extracted archive |
| Plist/privacy manifest, archive CRC/manifest and metadata exclusions | Passed |
| Extracted CLI version | `LumaChat 1.4.8` |
| Security audit | Passed; no `get-task-allow`, update trust unconfigured |

The Swift skip is the intentionally sandbox-blocked setuid system `top`.
Python comprises archive 7, soak harness 28, security 3 and worker 10 tests;
the worker process-cancellation case requires Linux `/proc` and skips on macOS.
Node results are local adapter contracts, not VS Code UI or hosted Action
acceptance. The local toolchain is Apple Swift 6.4; hosted CI independently
passed on Apple Swift 6.2.4 for the exact release commit.

The preceding focused MCP/Phase D run passed **140 tests, zero skips or
failures, 13.465 seconds** with unchanged 350-input fingerprint
`1a25a1e3cec4b5bf78edfa276d39029d648277641f8bedbe7fd17f441c150f03`.
That receipt predates the version/build bump; the full candidate gate above
qualifies its own inputs. Earlier diagnostic failures remain recorded and do
not count as passing evidence. See the [focused receipt](validation/mcp-stateless-2026-10-22.json)
and [candidate validation record](validation/1.4.8.json) for exact evidence
paths, sizes and hashes.

The preceding first candidate had passed its full gate with exit 0 on October
22, using fingerprint `2ac43949b9cfef43c0c4c4b926fed4041acd567494d416d30ee9fb5cfc28522d`.
Its packaged UI checks then found the Settings truncation. That candidate's
962-test result (241.759 seconds), original ZIP and functional UI evidence are
preserved under `priorCandidates` in the validation record; they do not qualify
the final layout or binary.

Before commit, one trailing space was removed from a test file. Product and
packaging inputs remain identical to the full gate; the publication source
fingerprint and exact test-only difference are recorded in `postGateCleanup`.

## Packaged native MCP UI

The final binary passed isolated-profile native UI checks on October 24, using
a loopback HTTP fixture. Saved legacy mode survived App restart and connected
with `2025-06-18`; saving Automatic disconnected that connection, then a new
connection used `2026-07-28` discovery. Invalid tool filtering showed its full
warning and one valid tool, resource and prompt. Refresh Discovery and explicit
Reconnect succeeded, and all connection-button labels remained visible.
About displayed `1.4.8 (15)` and the App exited with code 0.

The captured 20 HTTP requests include 14 modern requests and two modern
discovery calls; protocol/method headers were verified and modern session
headers were absent. Screenshots, accessibility snapshots and request evidence
are bound to the final binary hash in the validation record. This limited MCP
fixture acceptance does not qualify external providers or every Phase I–Q UI.

## Hosted CI and publication

Both workflows passed for `888addf6219a29487b2f45e91d5b5b9c39319242`:

- [macOS development gate](https://github.com/TonyChen-Git/RLM/actions/runs/40068761358):
  962 Swift tests, two skips, zero failures (256.763 seconds), optimized desktop
  build and 35 Python contracts. The skips are unavailable Homebrew `htop` and
  the intentionally sandbox-blocked setuid system `top`. Toolchain: Swift 6.2.4.
- [Linux worker](https://github.com/TonyChen-Git/RLM/actions/runs/40068776132):
  10 tests, no skips or failures (7.642 seconds), including Linux process cancellation.

The automatic tag-triggered reruns also passed: [macOS](https://github.com/TonyChen-Git/RLM/actions/runs/40069856902)
records 962 Swift tests, two skips and zero failures (223.466 seconds),
optimized compilation and 35 Python contracts; [Linux](https://github.com/TonyChen-Git/RLM/actions/runs/40069856827)
passes 10/10 (7.235 seconds). These are separate same-commit CI receipts.

The regular `v1.4.8` release was published on October 24 at 14:21:08 Asia/Taipei.
All five uploaded assets were downloaded and their complete bytes, sizes and
SHA-256 hashes matched the local artifacts. This is an ad-hoc private-use
release; the external and long-duration acceptance limits below remain.

## Published artifacts

- ZIP: `dist/LumaChat-1.4.8-arm64.zip`, 11,507,329 bytes
- ZIP SHA-256: `ba0f14b8be761da2c2c648986fce9f19f9b831c0f0eb80ee973aa06865350888`
- App binary SHA-256: `50d58eede3e7227445245f78d19b461131a01bddca5123a772d0da54560a042a`
- Archive manifest, checksum, SPDX SBOM and SLSA provenance are generated
  beside the ZIP; all five artifact hashes are in the validation record.

These files are the verified published artifacts. The provenance's fixed
development timestamp is a reproducibility field; actual gate times are
recorded above. No Apple distribution signature or notarization is claimed.

## Source-bound soak launch

The new 2h → 8h → 24h → 72h sequence started at
`2026-10-24T12:21:36Z` (20:21 Asia/Taipei), using an isolated archive of the
exact published tag. The first run is `46b1ba6f-f4b0-40d2-8805-a6ee0c4096cb`;
the launch checkpoint records its preparation stage, with no qualified elapsed
time. The controller stops on failure or interruption and does not reuse prior
run time. Live status is `tmp/release-1.4.8-soak-suite/run/state.json`; the
immutable launch checkpoint and input receipts are in the validation record.

## Acceptance still outstanding

- New source-bound 2h, 8h, 24h and multi-day soak. No earlier elapsed time or
  qualification transfers to this new implementation. The old corrected-test
  8h attempt ended interrupted after 5,988.242 seconds, 46 cycles and 368
  completed shards; 24h/72h did not start. The original 1.4.7 2h result remains
  valid only for its historical source.
- External model, SSH, MCP, OAuth and PR acceptance requiring user-provided
  targets remains `deferred_by_user`. Local fixtures and real sandboxed STDIO
  do not substitute for that acceptance.

Developer ID, notarization, stapling, production update feed and signed-update
acceptance are `not_required_for_private_use`, following the user's explicit
decision. They were not executed or passed. Windows desktop work is outside
this round; Slack/Gmail remain future provider evaluation. All other existing
Phase I–Q acceptance limits remain in the [parity audit](CODEX_FULL_PARITY_AUDIT.md).
