# Luma Chat 1.3.0

Release date: 2026-08-28

## Projects 2.0

- Projects are now first-class catalog records independent from Coding Tasks.
- Selecting or adding a Project never creates a Task. New Task, the sidebar
  pencil button, and Command-N remain the only creation paths.
- Command-Shift-O opens the Project folder picker without creating a Task.
- A Project has a user-defined name, pinned/archived state, multiple folders,
  and an explicit primary folder. A new Task uses that primary folder by
  default.
- Each Task binds to one Project folder checkout. A new empty Task may choose a
  different folder; after messages, Goal, steps, or changes exist, switching
  checkout is rejected and the user must create a new Task.
- The sidebar supports all-project or per-project search, recent and pinned
  ordering, archived Task visibility, and reversible Task pin/archive actions.
- The Project manager supports rename, pin, archive/restore, add folder, choose
  primary folder, guarded folder removal, and guarded empty-project deletion.

## Migration and persistence safety

- Pre-1.3 workspace-only Agent sessions remain decodable and migrate
  idempotently by canonical workspace root.
- Existing validated workspace aliases become the initial Project name. Task
  timestamps are preserved, so migration does not fabricate recent activity.
- The catalog is persisted before migrated Task references, making interrupted
  migration safely repeatable.
- Catalog input is bounded and rejects duplicate roots, hidden control data,
  root-directory authority, oversized paths/bookmarks/files, and persisted
  `allowedPaths` authority expansion.
- Recent-project and security-bookmark refreshes are actor-serialized field
  updates. A stale navigation write cannot discard a newly added folder, and a
  Task cannot refresh a bookmark onto another checkout.
- Two writable Agent Tasks still cannot run against the same canonical checkout.
  Independent folder/worktree roots remain concurrently usable, and unrelated
  background Tasks continue while navigating Projects, Chat, or Settings.

## Release verification

- Release gate: 284 tests passed with zero failures.
- Manual GUI coverage verifies Agent navigation does not create a Task, adding a
  Project leaves it at zero Tasks, an explicit Task inherits the primary folder,
  and Settings remains available. Automated coverage verifies Project
  rename/search/pin/archive persistence and concurrent navigation behavior.
- Release build is arm64, ad-hoc signed, signature-verified, plist-validated, and
  archive-integrity tested.
- Developer ID signing, notarization, and an update channel remain required for
  distribution without macOS Gatekeeper warnings.

## Replacement roadmap

- The audited local Codex-replacement score is now 74/100.
- The next release is 1.4 Terminal and Review: real PTY ownership/reconnection,
  staged/unstaged/commit/branch review modes, hunk actions, and inline comments.
