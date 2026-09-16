# LumaChat App Server v1 contract

This directory is the language-neutral description of the headless API shared
by LumaChat, the Swift SDK, IDE adapters, and CI integrations. JSON fields use
camelCase, dates use ISO-8601, and task status/event enum values use the exact
snake_case strings listed in the schema.

Every request requires `Authorization: Bearer <token>`. Mutation bodies may
include a UUID `requestID`; callers may instead send the same UUID as
`X-Request-ID`. If both are present they must match. A retry with the same ID
and payload addresses the same operation.

`POST /v1/tasks` accepts only `plan` and `agent`. Callers must send an exact
`backendID` and `modelID`; an unavailable route returns
`backend_unavailable`. The server and clients must never substitute a model,
provider, or cloud service. `future_cloud` is only a durable execution-kind
value in v1 and does not imply a cloud executor.

`GET /v1/tasks/{taskID}/events` is an SSE stream. Each block uses the event
sequence as `id`, the task-event kind as `event`, and one complete `taskEvent`
JSON object as `data`. `?after=<sequence>` resumes strictly after a previously
processed event. A cursor outside the bounded replay window fails explicitly
with `event_cursor_expired`.

Approval decisions are `allowOnce`, `allowForTask`, and `deny`. CI integrations
must stop on `awaiting_approval` unless a human-controlled approval channel is
explicitly provided; the checked-in GitHub Action never auto-approves.

- `lumachat-app-server-v1.schema.json` defines request, response, task, diff,
  approval, and event envelopes.
- `app-server-v1.routes.json` maps the v1 HTTP routes to those definitions and
  records success status codes.

The schemas describe the wire surface, not a hosted service. Transporting the
API beyond loopback requires an operator-controlled authenticated TLS boundary.
