# Luma Chat Subagent Architecture

Status: Phase C implementation complete; final combined Phase C–H validation is deferred by request.

## Execution model

A normal Coding Task is the only task type that receives a host-owned
`SubagentControlling` capability. It can use seven built-in tools to spawn,
message, wait, list, cancel, resume, and collect child results. Child Tasks are
ordinary durable `AgentSession` records with an explicit parent/child/depth
binding, so navigation, approval, transcript, failure, and crash recovery reuse
the established Task lifecycle.

`SubagentScheduler` is a single actor. Its durable queue applies priority then
FIFO ordering, a global concurrency ceiling of four, a per-provider/model
ceiling of two, eight active children per parent, and sixteen uncollected child
records per parent. Each record owns step, context, total-token, and wall-clock
budgets. A failed or timed-out child cannot terminate a sibling. Stopping a
parent propagates cancellation to all of its non-terminal children.

## Authority and isolation

Spawn validation is capability-narrowing:

- analysis defaults to an exact read-only tool allow-list;
- a relative read scope is rooted at a real descendant directory and rejects a
  final or intermediate symlink escape;
- writes require Git and a newly leased app-managed worktree owned by the child
  Task UUID;
- tool names and MCP UUIDs are exact allow-lists;
- network access defaults off and cannot exceed the parent capability;
- depth is limited to one, and every orchestration tool is removed from child
  scope.

The same scope is checked twice: `ToolRegistry` hides unauthorized schemas and
`ToolExecutor` rejects a cached or invented call immediately before execution.
Plan mode supplies a second read-only boundary for read-only children. Managed
worktree registry identity and lease validation remain authoritative for
writable children.

## Persistence, messages, and aggregation

The scheduler reuses Application Support and `AtomicFileWriter` at
`AgentSubagents/records.json`. The file is bounded, regular-file checked,
versioned, and structurally validated. A running child found after restart is
marked `interrupted` instead of falsely resumed; queued work can restart only
after the host configures its execution closures.

Parent follow-up messages are bounded, stored on the exact child record, and
consumed into that child's system context at the next model boundary. Each
model turn reports token use to the scheduler. Completion produces a validated
structured result containing summary, findings, files, commands, tests,
artifacts, confidence, and unresolved items. A parent cannot finish while a
child is running or a terminal result remains uncollected.

## UI and tests

The Sidebar groups and indents child Tasks beneath their parent and labels the
durable scheduler status. The Task detail surface shows live child cards with
navigation, cancellation, and resume controls. Child approvals and activity
remain visible through the normal Task UI.

`SubagentSchedulerTests` covers bounded parallelism/provider overload, parent
cancellation, child failure isolation, timeout, recovery/resume, exact message
ownership, structured aggregation, authority narrowing, and executor-level
scope rejection. Existing managed-worktree lifecycle suites remain the lower
layer for the writable-child checkout path. These tests are intentionally not
executed until the requested final combined validation gate.
