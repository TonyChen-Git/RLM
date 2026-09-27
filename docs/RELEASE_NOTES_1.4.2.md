# Luma Chat 1.4.2 — Development Release Candidate

- Candidate date: 2026-09-27
- Source version/build: `1.4.2` / `9`
- Status: locally packaged development candidate; native UI QA pending

This candidate addresses the UI issues reported after the 1.4.1 development
snapshot. It also isolates packaged-app UI smoke data from the user's normal
Project catalog.

## Changes in this candidate

- Enlarged and restyled the model editor's Advanced Parameters control so its
  visible row and click target agree. This addresses the narrow, displaced
  highlight and the difficulty opening the advanced controls.
- Restored the Classic Chat composer layout so the input stays near the bottom
  of the conversation and typed text begins at the expected leading edge.
- Removed the delivery-to-backend note beneath the Chat composer.
- Adjusted the shared visual theme toward the Codex desktop palette and
  surface hierarchy.
- Added `Scripts/ui_smoke.sh` and a packaged-app capability marker. UI smoke
  runs with an isolated, marked profile under repository `tmp/`; the wrapper
  rejects older packages without the isolation capability and removes only the
  profile it created after the app exits.

## Validation evidence and remaining UI QA

- Archive contract: 7/7.
- Soak contract: 4/4; qualifying long-duration soak was not run.
- Security-audit contract: 3/3, including the generated `.build` exclusion and
  continued symlink rejection in source and app trees.
- Swift: 745 tests, one explicit environment skip, zero failures.
- Optimized arm64 build, ad-hoc signed app, ZIP/archive verification, SBOM and
  provenance completed.
- The release script's final source audit initially encountered SwiftPM's
  generated `.build/debug` symlink. After excluding the root generated `.build`
  directory, the focused tests and direct security audit passed. The full
  release script was not rerun after this correction.

The isolated preview showed the Chat composer text aligned to the leading edge
and the backend-delivery footer absent before the Mac locked. Clicking the
Advanced Parameters control and native QA of the new packaged app remain
pending because the Mac was locked. This candidate is not yet UI-verified.

Development ZIP: `LumaChat-1.4.2-arm64.zip`

ZIP SHA-256:
`8dcbea2a992a3aac7c8d28b55c52c779b47c9990136dded5277d6cd74e6f6ad7`

The previous 1.4.1 build 8 passed 744 Swift tests (one environment skip), the
Node adapter suites, optimized arm64 build, signing, ZIP and security checks on
2026-09-25. Those results are historical evidence for 1.4.1 and do not verify
these 1.4.2 UI changes.

## Remaining production gates

- Developer ID signing, notarization and stapling.
- Production Ed25519 update key, trusted team ID, feed URL and archive URL.
- Authorized live model/backend, SSH, Chromium, native Computer Use and hosted
  integration acceptance.
- Qualifying 2h/8h/24h/multi-day soak runs.

Do not present this candidate as notarized, production-update capable or a
completed live-service acceptance release.
