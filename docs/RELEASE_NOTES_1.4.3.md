# Luma Chat 1.4.3 — Development Prerelease

- Candidate date: 2026-09-29
- Source version/build: `1.4.3` / `10`
- Status: packaged development prerelease; native UI validation pending

This candidate combines the 2026-09-29 workflow and recovery improvements with
support for user-selected remote OpenAI-compatible servers that expose HTTP,
including vLLM on another computer in a local network.

## Changes

- Added text Steer for active Agent runs and an editable, durable text Queue for
  subsequent prompts. Steer joins at the next model-turn boundary; Queue entries
  dispatch after a completed durable turn and require explicit reconciliation
  after an uncertain crash.
- Added a separate, temporary Side chat for bounded Task-summary discussion,
  and bounded, redacted text context when forking a Task.
- Added managed-worktree maintenance controls and MCP connection diagnostics,
  Reconnect, and Refresh Discovery in the desktop UI.
- Added a durable App Server mutation journal and a byte ceiling for live SSE
  buffering. Uncertain mutations require inspection before resubmission.
- Allowed remote HTTP endpoints for OpenAI-compatible providers in Classic Chat
  and Agent, including Bearer API keys. HTTPS remains supported, and the Settings
  screen warns that remote HTTP sends the API key and conversation content
  without transport encryption. Remote Anthropic endpoints still require TLS.

## Validation status

- The development release script passed archive contract 7/7, soak contract
  4/4, security-audit contract 3/3, and 780 Swift tests (one environment skip,
  zero failures). It completed the optimized arm64 build, ad-hoc signing,
  packaged CLI version check, ZIP/archive verification, manifest, SBOM,
  provenance, and source/application security audit.
- Tests cover both HTTP and HTTPS OpenAI-compatible model discovery and Agent
  request construction with Bearer credentials. VS Code 17/17 and GitHub
  Action 14/14 are results from the base source before this Swift-only change.
- The user's remote vLLM host is not reachable from this build environment;
  live connectivity and native UI acceptance remain pending.

Development ZIP: `LumaChat-1.4.3-arm64.zip`

ZIP SHA-256:
`15292306d3a1ffdb0ec502e83d84318a3e6ec37a1f05628259ec246bb992cfe7`

## Remaining production gates

- Developer ID signing, notarization and stapling.
- Production Ed25519 update key, trusted team ID, feed URL and archive URL.
- Authorized live model/backend, SSH, Chromium, native Computer Use and hosted
  integration acceptance.
- Qualifying 2h/8h/24h/multi-day soak runs.

This development prerelease must not be described as notarized,
production-update capable, or validated against the user's live vLLM server.
