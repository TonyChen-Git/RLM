# Luma Chat 1.1.1

Release date: 2026-08-27

## Explicit task creation

- Switching between Chat, Plan, and Agent is now navigation-only and never
  creates a Coding task implicitly.
- A running task remains active in the background when another mode is opened.
  If no task exists in the target mode, the UI shows an empty state instead of
  silently creating a conversation.
- New Coding tasks are created only through the sidebar button, the empty-state
  button, or the Command-N shortcut.
- Opening or cancelling the Workspace picker can no longer leave behind an
  unintended empty task. The composer is hidden until a task has been created.

## Custom project names

- Every canonical Workspace can now have a user-defined display name from the
  Agent header or Project Settings.
- The name is shared by all tasks for that project and persists even after its
  tasks are removed.
- Renaming is presentation-only: it never changes the folder path, security
  identity, task title, permissions, or a running task's captured state.
- Clearing the custom name restores the actual folder name.

## Release reliability

- The release script now executes the complete test suite before packaging; a
  failed test prevents App and ZIP creation.
- Added focused regressions for explicit task creation, background mode
  switching, and project renaming during an active run.
- Release gate: 264 tests passed with zero failures.
