# LumaChat App Server v1

The App Server is a loopback-first, headless projection of LumaChat's normal
task runtime. It is not a second Agent implementation: the desktop, CLI, and
HTTP entrypoints all compose `AgentViewModel`, `AgentRuntime`, providers,
tools, permissions, workspace leases, MCP, Skills, plugins, and durable task
storage through `SharedAgentHeadlessRuntime`.

## Starting the server

```text
lumachat server [--host 127.0.0.1|::1|localhost] [--port 32189] [--token TOKEN]
```

`LUMACHAT_SERVER_TOKEN` is preferred for automation because command-line
arguments may be visible to other local processes. If neither source supplies a
token, a cryptographically random token is generated and printed once. The
built-in launcher refuses non-loopback binds; a future secure relay must be a
separate, authenticated transport and must truthfully label its execution
backend.

Every route, including health, requires `Authorization: Bearer …`. Tokens are
32–512 UTF-8 bytes and compared without an early-exit byte comparison. Responses
carry `X-LumaChat-API-Version: v1`, `X-Request-ID`, `Cache-Control: no-store`, and
`X-Content-Type-Options: nosniff`.

## Language-neutral protocol

Commands use JSON over ordinary HTTP and task progress uses Server-Sent Events.
The normative JSON schema and route catalog are:

- `integrations/Schemas/lumachat-app-server-v1.schema.json`
- `integrations/Schemas/app-server-v1.routes.json`

The v1 surface is:

```text
GET  /v1/health
GET  /v1/tasks
POST /v1/tasks
GET  /v1/tasks/{taskID}
POST /v1/tasks/{taskID}/messages
GET  /v1/tasks/{taskID}/events?after={exclusiveSequence}
POST /v1/tasks/{taskID}/approve
POST /v1/tasks/{taskID}/pause
POST /v1/tasks/{taskID}/resume
POST /v1/tasks/{taskID}/stop
GET  /v1/tasks/{taskID}/diff
```

Task creation accepts `plan` or `agent`. Classic stateless chat is exposed by
the CLI's `chat` command and does not fabricate an Agent task. Mutations accept a
caller UUID in `requestID` or `X-Request-ID`; reusing one ID with a different
payload fails with `409 conflict`. Task states use stable snake-case wire values,
including `awaiting_approval` and `step_limit`. Approval decisions are
`allowOnce`, `allowForTask`, and `deny`.

The development tree persists mutation reservations and completed acceptance
responses in `AppServer/mutations.json` under Application Support. A completed
request ID replays its recorded response after server restart while it remains
in the bounded journal (at most 1,024 entries / 16 MiB). A pending reservation
means its outcome may be uncertain, so retry returns a conflict and the caller
must inspect the task. A corrupt or unavailable journal fails closed rather
than silently allowing the mutation to run again. Oldest completed entries may
be evicted at capacity; a much later resend outside that window is not
guaranteed to replay. Uncertain entries are retained. Approval decisions have
no durable completion receipt yet: after a successful `202 Accepted`, that
request ID remains pending and a resend returns `409 conflict` with an uncertain
outcome. The journal therefore does not promise general exactly-once execution.

The request's `backendID` and `modelID` are authority constraints. The runtime
probes the configured backend and exact model before create/send/resume. An
unavailable route returns `503 backend_unavailable`; it never selects another
local profile or silently falls through to a cloud provider. `future_cloud` is
only a durable protocol seam and has no executor.

## Event and recovery semantics

Each task owns a monotonically increasing `UInt64` sequence. The bounded broker
retains at most 512 events / 16 MiB by default and rejects an expired replay
cursor instead of returning a misleading partial stream. An SSE subscriber may
reconnect with its last sequence through `after`; replay is exclusive. Slow
subscribers and oversized events fail closed. Terminal streams close after the
terminal snapshot; an explicit Resume reopens the same task channel without
resetting its sequence.

Live subscriber queues now have a conservative aggregate byte ceiling. With
the default 512 KiB maximum event and 16 MiB live-buffer budget, each queue
holds at most 32 events, so even a stalled reader cannot retain more than the
byte budget. The in-memory event broker and its replay window do not survive a
server process restart; durable mutation replay above is a separate guarantee.

Runtime events are projected in observation order through one per-task delivery
tail. Message and reasoning deltas, tool progress, approval requests, state,
errors, and terminal snapshots all originate from the same persisted task used
by the desktop. Headless operations are keyed by explicit task ID and never
change desktop selection, so navigating between Chat, Settings, Review, or
another task cannot pause background work.

## Safety bounds

- HTTP headers: 64 KiB by default.
- JSON request/response: 4 MiB by default.
- One SSE event: 512 KiB by default.
- One live SSE subscriber queue: at most 16 MiB by default, enforced through
  the maximum event size and a derived event-count ceiling.
- JSON nesting: 32 levels and 20,000 nodes.
- Message content: 1 MiB; identifiers, paths, titles, and metadata are bounded.
- Transfer-Encoding, request pipelining, duplicate/continued headers, GET
  bodies, unsafe paths, unsupported media types, and redirects are rejected.
- Diff projection is bounded and carries its base fingerprint and changed paths.
- Error responses redact implementation detail; credentials and provider
  failures are not copied into the wire response.

## Clients and adapters

`LumaChatSDK` is a dependency-free Swift client for every JSON and SSE route.
It independently bounds responses/events, validates event names and sequence
IDs, supports exclusive replay cursors, and exposes typed API errors. The VS
Code extension and GitHub Action use the same neutral v1 shape through their
bounded JavaScript client. They contain no provider client or Agent loop.

The VS Code adapter sends selections/files, opens explicit tasks, previews
bounded unified diffs, and applies only context-matching local text patches
after a modal confirmation. The GitHub Action creates a read-only Plan task,
feeds a bounded base/head diff as explicitly untrusted data, waits for a typed
terminal result, and optionally posts a bounded comment. CI approval, timeout,
server loss, or unavailable backend is an explicit failure; no cloud fallback
is present.

## Known development limitations

- Durable mutation response replay and the live SSE byte ceiling are implemented
  and covered by focused tests in the development tree. Approval decisions
  remain pending after acceptance, completed entries have a bounded retention
  window, and the event broker's replay history remains process-scoped.
  Production and long-duration client acceptance have not yet been completed.
- The built-in transport is intentionally loopback HTTP. Remote use requires a
  separately designed TLS/relay trust boundary; setting a non-loopback URL in a
  client does not make this listener remote-capable.
- The server currently runs as an explicit headless process, not as an always-on
  background login item.
- Swift, VS Code, GitHub Action, packaging and deterministic failure-injection
  development gates pass. Live backend/IDE/hosted-Action acceptance remains an
  external environment gate; implementation presence is not a production claim.
