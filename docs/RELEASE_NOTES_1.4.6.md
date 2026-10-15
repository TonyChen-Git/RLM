# Luma Chat 1.4.6 — Release

- Release preparation date: 2026-10-14
- Source version/build: `1.4.6` / `13`
- Release channel: regular GitHub Release from `main` (prerelease disabled)
- Status: full release gate and packaged UI smoke passed; GitHub publication pending (2026-10-15)
- Artifact signing: ad-hoc; Developer ID signing and Apple notarization pending

This release integrates Phase I–Q and the subsequent persistence, authority,
recovery and Browser lifecycle fixes. LumaChat remains local-first: models,
SSH hosts and external providers are selected and controlled by the user.

## Changes

| Phase | Included scope |
| --- | --- |
| I | Task-owned interactive SSH terminals with bidirectional input/output, resize/signals, bounded scrollback and explicit reconnect/restart state tied to current host and permission receipts |
| J | Default-off background memory suggestions for completed idle Tasks, source evidence, review before saving, cross-Project search and bounded approved-only context |
| K | Bounded Claude references, scoped Cursor rules, configuration previews and selected text chat imports, with repeat detection and a persisted guarded undo slot for imported settings |
| L | Atomic Steer receipts and per-record recovery, durable text/image Queue editing and uncertain-send protection, plus selected read-only Side chat snapshots |
| M | GitLab merge requests and signed GitHub events with durable replay protection, filtering, Task provenance and isolated worktrees for mutation-capable actions |
| N | User-started on-device macOS speech recognition and interruptible spoken Task responses, with permission handling and text fallback |
| O | Installable Linux command worker over pinned outbound SSH, separate worktrees, heartbeat/reconnect/cancel, bounded logs/diffs and reviewed textual-patch takeover |
| P | Auditable registry/package digests and permission changes, OAuth refresh/revoke/expiry recovery, and explicit MCP compatibility diagnostics |
| Q | Development/production packaging paths, macOS and Linux-worker CI definitions, continuous soak evidence and recovery/failure checks |

The integrated bug pass also fixes unsafe persistence paths, stale callback and
connection races, secret redaction, import budgets, Queue editor recovery,
worker authority/cleanup and webhook replay after history pruning. The Browser
connection now survives approval waits beyond 30 seconds while each command
keeps its own bounded deadline; closed sockets and unexpected receive
cancellation fail pending requests promptly.

## Validation for this release

The tracked [validation receipt](validation/1.4.6.json) records the final test
counts, artifact hashes, limited smoke and historical soak boundaries.

The full `1.4.6` / `13` release gate **passed**, exit 0, using
`LUMACHAT_RELEASE_MODE=development` for ad-hoc signing:

- **886 Swift tests**, one environment skip, zero failures (273.489 seconds).
- **48 Python contracts**, one Linux-only worker skip, zero failures: archive 7,
  soak 28, security 3 and worker 10.
- VS Code **17/17** and GitHub Action **14/14** fresh integration checks pass.
- Debug compilation (326.27 seconds), optimized arm64 compilation (205.32
  seconds), ad-hoc signing, plist checks, canonical ZIP and extracted-archive
  checks, and security audit pass. The extracted packaged CLI reports
  **LumaChat 1.4.6**.
- The final optimized App launches with an isolated profile and displays its
  idle Task correctly through accessibility. About is verified through
  accessibility and a screenshot as **1.4.6 (13)**. Cmd-Q exits cleanly with
  code 0; no Task messages or Browser operations were executed in this smoke.
  This run does not add model, microphone or external-provider acceptance.

Artifact: `dist/LumaChat-1.4.6-arm64.zip`
SHA-256: `0d5112022bee7d3c266a32cd0ef25692d1a34cc112411387805da39a5cdb026a`

The frozen receipt `tmp/release-1.4.6-source-receipt.json` contains 340 inputs;
source fingerprint:
`32aed45fe29a36a81ff163a893b9204ac9e678e581b90ecc8162a60903b72d99`.
Evidence: `tmp/release-1.4.6-retry.log`,
`tmp/release-1.4.6-retry-result.json`, `tmp/release-1.4.6-vscode.log`,
`tmp/release-1.4.6-action.log`, and
`tmp/release-1.4.6-browser/acceptance.json` (the directory name does not imply
Browser operations were run).

The first attempt passed 886 Swift tests (one environment skip, zero failures,
259.278 seconds) and the optimized build (216.26 seconds), then **failed** the
extracted-app CLI version check because its constant still reported `1.4.5`.
The corrected `1.4.6` constant is covered by the complete passing rerun above.
The failed log, exit-1 receipt and artifacts remain at `tmp/release-1.4.6.log`,
`tmp/release-1.4.6-result.json` and `tmp/release-1.4.6-first-attempt/`.

### Preserved integration evidence before the version bump

- October 14 `1.4.5` integration gate: **886 Swift tests**, one environment skip,
  zero failures; **48 Python contracts**, one Linux-only skip, zero failures.
  Optimized arm64 compilation, ad-hoc signing, archive checks and security audit
  passed. ZIP SHA-256:
  `7c5c0716e30becfbb600f06db6f37516cc5560cca88783701aa5019b7a4de3b0`.
- That optimized package completed five real Chrome operations against local
  model/page fixtures after an observed approval wait exceeding 68 seconds.
  Its actual PNG and native annotation pane were verified; App exit and owned
  process cleanup passed. This does not establish external-model acceptance.
- Its frozen-input **2h soak completed and qualifies**: 7,207.592 continuous
  seconds, 48 complete cycles, 389 successful shards, zero failures. Run
  `19124a61-51f3-4eec-8bd6-e2679e8327e2` finished at
  `2026-10-14T09:29:56Z` (17:29:56 Asia/Taipei).
- The following 8h run, `f1c364d4-1834-455e-b29b-01082173cd9d`, was interrupted
  after 669.134 measured seconds, four complete cycles and 36 completed shards.
  It does not qualify. The sequence is stopped; 24h and 72h never started.
  These receipts are preserved and are not relabelled as `1.4.6` soak evidence.
- Earlier isolated packaged checks cover memory/import controls, Queue
  save/restart and one crash boundary, Steer recovery and saved-import undo.
  Their exact scope and limitations remain in the [parity audit](CODEX_FULL_PARITY_AUDIT.md).

The five historical 1.4.5 integration archive files are preserved under
`tmp/phase-iq-oct14-preserved-integration-1.4.5/`; the tracked 1.4.5 distribution
files retain the original development checkpoint.

Local evidence: `tmp/phase-iq-oct14-release.log`,
`tmp/phase-iq-oct14-browser-package/acceptance.json`,
`tmp/phase-iq-oct14-soak-suite/state.json` and the corresponding `tmp/soak/`
run directories. These local paths are not public download links.

## Scope and remaining acceptance

- Memory extraction is a bounded local heuristic for explicit user statements.
  Imports support the documented Claude JSONL and Cursor Markdown shapes;
  vendor credentials, hooks, commands and permissions are not transferred.
- The remote worker runs command jobs and supports textual patches. A full
  remote Agent runtime, binary takeover and a non-macOS desktop are outside
  this minimal worker release. SSH disconnect cannot prove that daemonized
  remote descendants have stopped.
- MCP implements the `2025-06-18` lifecycle with diagnostics for unsupported
  revisions; modern stateless MCP and additional providers remain future work.
- Real SSH/network/reboot/credential faults, external MCP/PR/OAuth/model
  providers, real microphone interaction, Computer Use, real vendor exports
  and executed Linux worker CI remain pending where no live receipt exists.
- Fresh `1.4.6` 2h/8h/24h/multi-day soak remains pending. Existing fixture and
  contract tests do not replace those acceptance runs.
- Developer ID signing, notarization, stapling, a published production update
  feed and production update/rollback acceptance remain pending. The regular
  GitHub Release uses the available ad-hoc-signed artifacts; its release channel
  does not establish these Apple signing or external acceptance results.

See [Phase L–Q architecture](PHASE_L_Q_ARCHITECTURE.md), the
[full parity audit](CODEX_FULL_PARITY_AUDIT.md) and the
[development history](RELEASE_NOTES_UNRELEASED.md).
