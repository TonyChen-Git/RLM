# Luma Chat 1.2.0

Release date: 2026-08-28

## Durable Goals

- Agent tasks can now own a first-class Goal with an objective and optional
  completion criteria.
- A Goal is persisted before provider/tool work begins, so launch failures,
  provider errors, Pause, Stop, and app restart cannot erase the requested
  outcome.
- Start a Goal from the Composer menu or enter `/goal <objective>`.
- The Goal bar shows Active, Paused, Needs attention, or Completed plus durable
  Todo progress, and exposes Pause, Resume, Edit, New Goal, and Clear actions.
- Editing is deliberately pause-first: the UI never claims that a live model
  loop received an objective it had already captured before the edit.
- Clear removes only Goal metadata; conversation, Todo, tool, change, and
  validation history stays intact.
- An active Goal cannot be silently replaced. It must be completed, edited, or
  explicitly cleared first.

## Persistence and safety

- Pre-1.2 Agent session JSON remains decodable with no migration.
- Goal objective and completion criteria have independent 16 KiB UTF-8 limits;
  both interactive input and decoded local JSON reject hidden control data.
- Terminal completion marks a Goal exactly once with a deterministic timestamp,
  even though Runtime publishes repeated final snapshots.
- Goal saves temporarily block conflicting send, model, workspace, attachment,
  resume, and delete operations to prevent stale task snapshots from racing a
  newly persisted outcome.
- Interrupted running/approval tasks still recover truthfully as Paused while
  preserving the Goal.

## Replacement roadmap

- Added a documented 100-point acceptance matrix and release sequence for
  Projects 2.0, real PTY terminals, code review, worktrees/handoff, Skills,
  plugins, subagents, automation, remote execution, notarization, and updates.
- The audited replacement score after this milestone is 68/100. This is not a
  claim of full Codex parity; remaining points require working, tested releases.

## Release verification

- Release gate: 274 tests passed with zero failures.
- Release build is arm64, ad-hoc signed, signature-verified, plist-validated, and
  archive-integrity tested.
- Developer ID signing, notarization, and an update channel remain required for
  distribution without macOS Gatekeeper warnings.
