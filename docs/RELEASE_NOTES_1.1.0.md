# Luma Chat 1.1.0

Release date: 2026-08-27

## Background tasks and navigation

- Chat conversations and Codex tasks continue independently in the background.
- Switching Chat, Plan, Agent, Settings, conversations, and projects no longer
  cancels work or disables the rest of the window.
- Stop and Pause apply only to the selected task. App shutdown reconciles every
  active task to durable cancelled state.
- Drafts, attachments, approvals, runtime events, and persistence snapshots are
  isolated per conversation or task.
- The sidebar shows which conversations and tasks are running, stopping, or
  waiting for approval.
- Status and error feedback is non-modal and no longer blocks navigation.

## Multi-project safety

- Different project roots can run Agent tasks concurrently.
- One canonical checkout permits only one writable Agent at a time so two undo
  histories cannot race. Read-only Plan tasks and independent checkouts can run
  in parallel.
- MCP tools are filtered against each run's captured Project Settings and
  canonical workspace both when schemas are exposed and immediately before
  execution.

## Reliability

- Fixed a shutdown race that could persist a transient running state after the
  final cancelled snapshot.
- A background Chat stream can no longer overwrite the selected conversation's
  connection indicator.
- Added focused concurrency and MCP-isolation coverage. The release gate runs
  the complete 260-test suite.

## Codex feature alignment

This release covers the local desktop fundamentals relevant to the original
product scope: Chat/Plan/Agent modes, background multi-task execution, project
tools, approvals, MCP, AGENTS.md instructions, Todo state, automatic validation,
Git status/diffs, changed-file Keep/Revert/Undo, managed processes, attachments,
and crash recovery.

OpenAI-account cloud execution, cloud handoff, hosted code review, Codex Skills,
Hooks, first-class subagents, automatic Git worktree provisioning, and a full PTY
terminal pane require separate product integrations and are not represented as
completed by this local release.
