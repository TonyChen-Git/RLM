# Luma Chat 1.4.0

Release status: release-ready Phase B artifact (not published or tagged)

Validated: 2026-09-06

This document records the validated Phase B artifact
`LumaChat-1.4.0-arm64.zip`. The integrated regression, production build,
bundle/archive verification and packaged native UI smoke all passed. The app is
ad-hoc signed for local distribution; Developer ID signing, notarization and
the production update channel remain Phase H work.

## Task Terminal

- Adds a real Darwin `forkpty` transport behind `PTYBackend`, including a
  controlling terminal, raw/canonical bytes, interactive shell, EOF,
  resize/`SIGWINCH`, named signals, exit/reap state, bounded raw output and
  bounded process-tree shutdown.
- Adds a Task-owned multi-session service and a native pane with stable tabs,
  New/Rename/Reconnect, signals/EOF, Kill/Clear/Copy/Search/Close, lifecycle
  state, viewport resizing, ordered keys/paste, application cursor keys,
  bracketed paste and safe incremental UTF-8/ANSI/VT rendering.
- Adds six structured tools—`terminal_create`, `terminal_write`,
  `terminal_resize`, `terminal_read`, `terminal_signal` and `terminal_close`—
  through the existing registry, permission and executor path. Model-visible
  output is inert, bounded, control-stripped, secret-redacted, host-path-
  scrubbed and explicitly untrusted.
- Keeps live terminals Task-owned across Task/Chat/Settings navigation and
  Agent Stop. Handoff/rebind/archive reject live terminals, Fork is isolated,
  and deletion/shutdown dispose terminal authority before Session authority.

## Advanced Git

- Expands the closed Git API with remote/tag/stash inspection; fetch, explicit
  pull strategies and push; branch switch/delete; hard reset; merge, rebase and
  cherry-pick; stash push/apply/drop; tag create/delete; and remote add/remove.
- Adds explicit merge/rebase/cherry-pick continue and abort operations that
  require the corresponding fixed Git state marker and fail closed on
  ambiguous or unsafe metadata.
- Classifies every operation in a host-owned table as read-only, local write,
  network read, dangerous local or dangerous network before decoding model
  arguments. History-rewriting, destructive and remote mutations therefore use
  explicit approval policy; plain force-push is not exposed.
- Uses validated names/references/remotes, non-interactive execution, bounded
  affected-path inventories, unsafe filter/attribute refusal and
  ChangeManager snapshots. Hard reset refuses a repository layout where a
  complete truthful snapshot cannot be made.
- Leaves remote mutations outside workspace Undo and says so in the result.

The final focused Advanced Git suite passed 21/21, including cancellation,
conflict continue/abort, stale-action refusal, root-identity replacement and
globally consistent Last Agent Turn capture.

## Review pane and inline comments

- Adds Review sources for Unstaged, Staged, Commit, Branch and Last Agent Turn.
- Adds file-summary, unified and side-by-side views with stable file/hunk
  identity, line numbers, bounded syntax highlighting, added/deleted/renamed
  metadata, and explicit binary/large/malformed fallbacks.
- Adds file and hunk Stage/Unstage/Revert. The host creates the patch from the
  displayed fingerprints, rejects stale selections, serializes the Git
  operation, runs `git apply --check`, and commits or rolls back a native change
  snapshot. Revert always requires an explicit destructive confirmation.
- Adds durable comments anchored to a file, line, range or hunk. Sending them
  to the coding Agent persists typed `ReviewAgentContext`; anchors are not
  flattened into ordinary chat text.

## Review Agent

- Adds Review Changes, Review Commit, Review Branch and Review PR workflows as
  separate persisted Review Tasks bound to an exact source Task and checkout.
- Keeps Review Tasks isolated from the source Runtime, PTYs, approvals,
  permission allowances, change history and managed-worktree lease. Dependent
  Review and writable source runs conflict in both directions.
- Exposes only bounded local inspection plus the one workflow-specific source
  tool and structured finding submission. The executor repeats the allow-list
  check so a hidden tool call fails before execution.
- Requires a host-authenticated receipt for the actual source before accepting
  findings. Submitted severity, file, line, explanation and recommended fix are
  bounded and validated against that receipt; a prose-only final answer cannot
  complete the Review Task.

## Pull Request workflow

- Adds a provider-neutral `PullRequestProvider` and first-party GitHub adapter
  for bounded PR metadata, paginated file context and Create PR.
- Adds provider/endpoint Settings plus a provider-scoped Keychain token. The
  credential is never written to Settings/Session JSON or model context, and a
  failed settings save restores the exact prior credential scope.
- Adds `pull_request_get`, `pull_request_context` and
  `pull_request_create`. Reads follow Agent network policy; Create is always a
  dangerous remote mutation requiring explicit approval.
- Rejects redirects and cross-origin responses, bounds streamed response bytes,
  supports cancellation, maps authentication/rate/remote failures, labels
  provider content untrusted, and redacts bounded model-visible fields.
- Shows an Open PR destination only from a successful built-in tool's
  structured, credential-free HTTPS URL. Provider prose cannot create a link.

## Release verification

- The isolated release workflow passed 504 Swift tests with one explicit
  environment skip and zero failures in 177.768 seconds. The skip is the macOS
  `/usr/bin/top` fixture: the setuid-root executable is correctly rejected by
  the sandbox; `htop` covers the interactive full-screen TUI path.
- The direct Task Terminal set contains 47 cases: 21 PTY, 11 emulator, 5
  service, 5 tool/security, 3 ViewModel lifecycle, one pane-model and one
  rendered-surface test. Real-program coverage includes `vim`, Python REPL,
  `nano`, `htop`, `git add -p`, offline `ssh -G` and an interactive `pip`
  uninstall prompt.
- Advanced Git passed 21/21. The combined persistence, worktree handoff and
  lease-focused gate passed 37/37. Descriptor-safe filesystem/change coverage
  passed 17/17, including concurrent same-length rewrites.
- All five release-archive tests passed. The isolated production arm64 build
  completed in 125.87 seconds; the app bundle and extracted bundle passed
  signature and plist checks, and the ZIP passed CRC, manifest/mode and
  AppleDouble/`__MACOSX` exclusion checks.
- Packaged UI smoke passed against a fresh application-support root: switching
  to Agent created no implicit Task; adding a Git Project still created no
  Task; explicit Task creation exposed Review and Terminal; Review rendered the
  actual unstaged file; a real PTY rendered ANSI output; panel switching kept
  state; the packaged app then quit cleanly.
- The artifact is arm64, marketing version `1.4.0`, build `7`, and 7,315,724
  bytes. SHA-256:
  `224d6942969670cd090797416bdcfb979a79387a827b68fa8c184d64d871b2b0`.

## Review correctness closed for Phase B

- Untracked files are represented in Unstaged and Review Changes.
- Artifact-backed Git output is read through bounded pagination, and incomplete
  or truncated source receipts fail closed.
- Binary/large/malformed fallbacks no longer advertise unavailable file
  actions.
- Last Agent Turn is a frozen, persisted source. Finalization uses one exclusive
  Git gate, HEAD plus per-file content identities and bounded retry/double
  rendering so concurrent same-size external or Task Terminal writes cannot
  produce a mixed snapshot.
- Stop, Pause and shutdown now have one terminal-state/persistence owner, so a
  natural completion cannot be replaced by a stale cancellation snapshot.

## Known limitations

- Relaunch restores Terminal metadata as `disconnected`; Reconnect starts a
  fresh shell and cannot reattach the old Unix process or raw scrollback.
- PTY is Darwin-only. Remote SSH terminals and non-macOS backends remain later
  phases. Long soak and broader crash/storage-failure matrices remain Phase H
  work.
- GitHub is the only PR provider. Deterministic tests do not make live pushes or
  create live PRs; provider-side changes have no local rollback. A GitHub PR may
  omit patches, and Review can inspect only the bounded content returned.
- Binary, oversized or malformed diffs use a visible fallback rather than
  fabricated textual hunks. Some linked-worktree index mutations cannot provide
  native Git-metadata Undo and report that limitation.
- Node/npm program fixtures were unavailable on the release host and are
  recorded as not applicable, not silently treated as passing.
- Phase C subagents, later Skills/plugins/hooks, browser/CDP, automations,
  Remote Runner, CLI/App Server/SDK/IDE integrations, Developer ID/notarization,
  update/rollback and full cross-platform preparation are not part of 1.4.0.

## Parity statement

After the Phase B gate, the narrower local-workflow roadmap is **84/100** and
full Codex-class product parity is **68.5/100**. Luma Chat 1.4.0 is a validated
Phase B local artifact, not yet a complete Codex-class replacement; the master
program continues through Phases C–H.
