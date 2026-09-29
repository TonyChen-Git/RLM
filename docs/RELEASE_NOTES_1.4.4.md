# Luma Chat 1.4.4 — Development Prerelease

- Candidate date: 2026-09-29
- Source version/build: `1.4.4` / `11`
- Status: packaged development prerelease; native UI validation pending

This candidate merges the 1.4.3 remote OpenAI-compatible HTTP connection fix
with the reviewed local-memory and project-instruction import work. The 1.4.3
history and its vLLM-oriented connection behavior are retained in the merge.

## Changes

- Retained support for user-selected remote OpenAI-compatible HTTP servers in
  Classic Chat and Agent, including Bearer API keys. Settings warns that HTTP
  sends credentials and conversation content without transport encryption;
  remote Anthropic endpoints still require TLS.
- Added opt-in, Project-scoped local memories. Global, Project and Task controls
  default off. User-written proposals require separate review and approval;
  only bounded, redacted approved content is sent as transient context to the
  selected model on a future enabled Task run. The memory pane supports edit,
  remove and clear, and Project deletion cleans up its memory file.
- Added read-only previews for a Project root `CLAUDE.md` or legacy
  `.cursorrules`. Users can edit the redacted preview and apply it to the
  Project System Prompt draft before saving Settings. Sources are not changed.
- Included the prior Steer/Queue, Side chat, Fork context, managed-worktree/MCP
  controls, and App Server mutation-journal/SSE hardening from 1.4.3.

## Validation

- `LUMACHAT_RELEASE_MODE=development Scripts/release.sh` passed archive
  contract 7/7, soak contract 4/4, security-audit contract 3/3, and 792 Swift
  tests with one environment skip and zero failures.
- The same script completed the optimized arm64 build, ad-hoc code signing,
  packaged CLI version check, canonical ZIP and extracted-app verification,
  archive manifest, SPDX SBOM, provenance, SHA-256, and source/app security audit.
- After integration, VS Code tests passed 17/17 and GitHub Action tests 14/14.
- Native packaged UI acceptance and live connectivity to the user's vLLM host
  have not been performed in this build environment.

Development ZIP: `LumaChat-1.4.4-arm64.zip`

ZIP SHA-256:
`90a5658270adb9b032c8a0e87991a4499756460e643ca72e4bd562d8f7c0e859`

## Remaining scope and production gates

- Memory suggestions from conversation history and full Claude Code/Cursor
  settings, scoped rules, and chat-history import remain unimplemented.
- Developer ID signing, notarization and stapling remain unavailable here.
- Production Ed25519 update key, trusted team ID, feed URL and archive URL
  remain unconfigured.
- Authorized live model/backend, SSH, Chromium, native Computer Use and hosted
  integration acceptance, plus qualifying 2h/8h/24h/multi-day soak, remain.

This development prerelease is not notarized or production-update capable.
