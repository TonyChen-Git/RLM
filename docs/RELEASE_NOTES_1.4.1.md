# Luma Chat 1.4.1 — Development Release

- Release date: 2026-09-25
- Version/build: `1.4.1` / `8`
- Status: ad-hoc signed development prerelease; not notarized for production

This release integrates the original Phase A–H implementation and the
per-model parameter-profile priority feature. It also hardens persistence and
recovery paths found during the final cross-phase audit. The implementation
program is 8/8 phases complete; external production gates remain listed below.

## Highlights

- Added endpoint-namespaced, per-model Auto/Custom parameter profiles to the
  existing `settings.json`. Auto recommendations resolve exact model → family
  → backend → generic fallback; a manual change persists a complete Custom
  override until Reset to Auto removes it.
- Added the shared model-parameter editor to Chat, Agent and Settings, including
  Thinking, Reasoning Effort, context, max output and advanced sampling fields.
  Unsupported backend capabilities are disabled or hidden and omitted from
  API requests.
- Applied one validated effective profile to Chat, Agent, retry, regenerate,
  resume, output continuation and every tool-call continuation. Ollama model
  capability discovery now respects backend/model context ceilings.
- Hardened Automation, Subagent, Task Terminal, updater, MCP and Remote Runner
  persistence against cancellation, shutdown, partial writes, late fsync
  failures, dangling symlinks and ambiguous third-party state. Uncertain state
  is preserved and fails closed instead of being guessed away.
- Versioned MCP and SSH credential references now preserve the previous
  Keychain secret until public metadata commits and exact readback succeeds.
- Tightened development/production release contracts so the built bundle and
  CLI version must agree and workflow tags/artifact names must match exactly.

## Validation evidence

- Archive contract: 6/6.
- Soak contract: 4/4; the qualifying long-duration soak itself was not run.
- Security-report contract: 1/1.
- Swift: 744 tests, one explicit environment skip, zero failures, 189.790 s.
- Focused integrated regression: 165/165.
- VS Code Node adapter: 17/17.
- GitHub Action Node adapter: 14/14.
- Python release scripts compiled; shell syntax, YAML parse and
  `git diff --check` passed.
- Optimized arm64 build: 168.54 s.
- Bundle and extracted-bundle validation, ad-hoc hardened-runtime signatures,
  plist/privacy checks, canonical ZIP, archive manifest, SBOM, provenance and
  static/package security audit passed.
- Security audit: 355 source files / 9,301,304 bytes and 15 application files /
  36,619,705 bytes. `get-task-allow=false`; production update trust is not
  configured.

## Artifacts

- `LumaChat-1.4.1-arm64.zip`
- `LumaChat-1.4.1-arm64.sha256`
- `LumaChat-1.4.1-arm64.archive-manifest.json`
- `LumaChat-1.4.1-arm64.sbom.spdx.json`
- `LumaChat-1.4.1-arm64.provenance.json`

ZIP SHA-256:
`d7bd60cc09888ebf7eacf541bf1d866588a348084520e441b414996f6ff1bfa7`

## Remaining production gates

- Developer ID signing, notarization and stapling.
- Production Ed25519 update key, trusted team ID, feed URL and archive URL.
- Authorized live Ollama/OpenAI-compatible, SSH, Chromium, native Computer Use,
  VS Code and hosted GitHub runner acceptance.
- Qualifying 2h/8h/24h/multi-day soak runs.
- Persistent interactive remote PTY, secure relay, SSH-to-SSH handoff and
  non-Darwin execution backends remain intentionally outside this release.

Do not present this artifact as notarized, production-update capable or a
completed live-service acceptance release.
