# Luma Chat 1.4.5 — Development Prerelease

- Candidate date: 2026-09-30
- Source version/build: `1.4.5` / `12`
- Status: ad-hoc signed development prerelease; not notarized

This release follows 1.4.4 and fixes the Qwen/OpenAI-compatible Agent request
shape and the Plan/Agent Composer layout.

## Changes

- The OpenAI-compatible Agent adapter sends one leading system message. It
  preserves all runtime system context in its original order and leaves
  user, assistant and tool turns in their original order. Other providers keep
  their existing request format.
- HTTP error handling retains status and bounded diagnostics while redacting
  credentials and echoed request content. Errors are still surfaced to users.
- Plan and Agent measure their bottom controls and allocate the remaining
  detail height to the transcript. Composer, attachments, active-run controls,
  queued follow-ups, approval card and Plan's read-only footer stay outside
  the scrolling transcript. The multiline input is left aligned and grows in
  the available width.
- The packaged UI smoke script lists manual Chat, Plan and Agent Composer
  checks using its isolated profile.

## Validation

- `LUMACHAT_RELEASE_MODE=development Scripts/release.sh` passed archive
  contract 7/7, soak contract 4/4, security-audit contract 3/3, and 794 Swift
  tests with one environment skip and zero failures.
- The same script completed the optimized arm64 build, ad-hoc signing,
  packaged CLI version check, canonical ZIP and extracted-app verification,
  archive manifest, SPDX SBOM, provenance, SHA-256 and source/app security audit.
- VS Code tests passed 17/17 and GitHub Action tests 14/14.
- The new packaged app launched with the isolated UI smoke profile. Empty
  Chat, Plan and Agent Composer positions were visually verified; Agent stayed
  at the bottom after window zoom and sidebar collapse. Plan's read-only
  footer stayed directly below its Composer.

The packaged UI smoke is manual. Plan and Agent split panes were also checked
with an isolated app clone using the current debug executable. Long
transcripts, live Approval/Queue states and the user's Qwen/vLLM endpoint were
not exercised end to end.

Development ZIP: `LumaChat-1.4.5-arm64.zip`

ZIP SHA-256:
`e0db363db1ab4ef17b49430562739eb306a4f164b34991998309d6bee19c4541`

## Production gates

Developer ID signing, notarization/stapling and the production update feed
remain unconfigured. This development prerelease is not notarized or
production-update capable.
