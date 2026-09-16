# Luma Chat 1.3.1

Release date: 2026-08-29

Phase A validation refresh: 2026-08-31

## Managed worktrees, handoff, and Task Fork

- Adds UUID-owned managed Git worktrees with a durable registry, exact Task
  leases, collision-safe branch allocation, inspect/list/remove/clean-only
  cleanup, repair, and externally deleted-checkout handling.
- Supports normal `.git` directories, linked-worktree pointer files,
  separate-git-dir/submodule layouts, nested repositories, and detached HEAD
  through a closed Git/checkpoint metadata capability.
- Adds transactional Local → Worktree and Worktree → Local handoff with Local
  baseline compare-and-swap, fast-forward policy, integrity-bound rollback
  payloads, durable journals, launch recovery, history transfer, and exact
  source revalidation before cleanup.
- Adds Task Fork with a distinct checkout and lease for writable Tasks. Bounded
  conversation/Goal/Todo/checkpoint provenance is copied while Runtime,
  processes, terminals, approvals, permissions, and mutable change state reset.
- Sidebar/detail location labels and actions expose only valid Local/Managed
  Worktree operations. Switching modes or opening a Project still never creates
  an implicit Task.

## Computer Use MVP

- Adds an experimental, opt-in native macOS Computer Use loop for a
  vision-capable Agent: permission status, allowlisted App discovery,
  ScreenCaptureKit window capture, activation, click, bounded Unicode typing,
  navigation keys, and scrolling.
- Agent Settings has an exact bundle-ID allowlist plus shortcuts to macOS Screen
  Recording and Accessibility settings. Computer Use is off by default, an empty
  allowlist grants no access, and text-only model runs expose no Computer Use
  tools.
- Screenshots pass through the existing bounded, signature-checked Agent image
  store and are attached to the next model request. The provider-visible result
  includes the exact bundle, capture ID, window ID, and image dimensions needed
  for the next action.

## Safety and approval

- Luma Chat, ChatGPT/Codex, terminal apps, System Settings, login/security,
  password/Keychain, and installer surfaces remain blocked even if listed.
- Every UI action requires both macOS permissions, a user-visible reason, a
  screenshot from the same Task that is at most 30 seconds old, and explicit
  one-time approval. Capture IDs are single-use and only the latest capture per
  Task remains valid.
- Targets fail closed when a bundle ID maps to multiple running processes or the
  App has multiple visible windows. Actions revalidate the exact process,
  window, owner, dimensions, unchanged geometry, and frontmost App after
  activation.
- Approval cards display the validated screenshot; click approvals overlay the
  requested point. Secret-like text that would be hidden by redaction is refused
  and must be entered by the user.
- Narrowing the allowlist, disabling Computer Use, or changing vision policy
  pauses active Tasks so an older settings snapshot cannot retain revoked GUI
  authority.
- Screen contents and App UI instructions are treated as untrusted data. The
  system prompt requires a fresh observation after every action and prefers
  structured tools over pixel automation.

## Known MVP limits

- This is visual single-window automation, not browser DOM automation or
  semantic Accessibility-tree targeting. It does not operate in the background
  or on the lock screen and cannot approve administrator, security, or privacy
  prompts.
- A generic allowlisted browser or IDE may contain network functionality or an
  embedded terminal that pixel automation cannot reliably classify. Use
  structured browser, terminal, and connector tools for those workflows.
- GUI changes outside the workspace do not receive native Diff/Undo snapshots.
- Remote execution and Local/Worktree ↔ Remote handoff are not implemented.
  Arbitrary ignored files, symlinks, and special files are not migrated; only
  explicit Task-owned ignored paths are included. Worktree maintenance has no
  general UI or scheduled cleanup yet.

## Verification

- Dedicated Computer Use policy, schema, attachment roundtrip, vision fail-closed,
  and secret-input tests are included in the full regression suite.
- The release gate passed 344/344 Swift tests and 5/5 archive tests. The
  production arm64 app and extracted copy passed signature/plist verification;
  the ZIP passed CRC, exact manifest/content, canonical `0755`/`0644` modes,
  and AppleDouble exclusion.
- `LumaChat-1.3.1-arm64.zip` SHA-256:
  `b9736079bdfb686eb401f88c13d3ad26df75f28fd691e998121831ac09618fac`.
- A packaged-app native smoke verified Chat → Agent navigation, visible
  Project/New Task entry points, no implicit Task creation, and clean exit.
  Developer ID signing, notarization, and an update channel remain future work.

## Replacement roadmap

- The conservative local-workflow score is now 79/100 after the separate,
  working Phase A Worktree/Handoff/Fork chain. The broader full-product parity
  audit is 64/100; neither score claims complete Codex desktop/CLI parity.
