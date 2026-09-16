# LumaChat VS Code adapter

This directory contains a dependency-free VS Code extension that delegates all
inference and task execution to one user-selected LumaChat App Server. It does
not contain a model client, an OpenAI client, or a cloud fallback.

## Run from an Extension Development Host

1. Start LumaChat's App Server. The local default is
   `http://127.0.0.1:32189`.
2. Open this directory in VS Code and launch an Extension Development Host.
   The extension uses only the `vscode` module supplied by that host and Node's
   built-in APIs; `npm install` is not needed.
3. Set `lumachat.backendID` and `lumachat.modelID` to the exact backend and
   model that LumaChat should use. An unavailable selection is an error and is
   never substituted.
4. Run **LumaChat: Set App Server Token**. App Server v1 requires a 32-512 byte
   Bearer token; it is kept in VS Code `SecretStorage`, not `settings.json`.

The checked-in test command is `node --test test/*.test.js`. Tests intentionally
use only `node:test`, `node:assert`, and in-memory fetch responses.

## Commands

| Command | Behavior |
| --- | --- |
| Send Selection | Sends bounded selected text and editor metadata to the active Agent task. |
| Ask | Sends a prompt to the active task, creating the configured Plan/Agent task when none is active. |
| Fix Selection | Sends a bounded fix request to an Agent task. |
| Open Task | Validates an opaque task ID with `GET /v1/tasks/{id}`, requires the response ID and workspace to match exactly, and makes it active in that workspace. |
| Show Diff | Reads the exact active task's `GET /v1/tasks/{id}/diff`, rejects truncated/task-mismatched/manifest-mismatched data, validates the unified text patch, and opens a read-only preview. |
| Apply Result | Re-fetches and validates the exact active task's diff, requires modal confirmation, then re-reads every target and applies one context-matching VS Code `WorkspaceEdit`. |
| Review Workspace | Creates a fresh read-only `plan` task with the configured backend/model and verifies the returned scope before making it active. |
| Pause / Resume / Stop Task | Calls the matching endpoint for the exact workspace task and accepts only a matching acknowledgement. |
| Set / Clear App Server Token | Updates VS Code `SecretStorage`; the token is never written to the output channel. |

The current task ID is workspace-scoped extension state. Main LumaChat, the CLI,
and this adapter operate on the same server-owned task rather than maintaining a
second transcript or parameter store. In a multi-root VS Code window, commands
without a selected editor require the user to focus a file in the intended
folder; the adapter does not silently choose the first root.

## App Server contract

The adapter uses only the Phase-G v1 surface:

- `GET /v1/health`
- `GET|POST /v1/tasks`
- `GET /v1/tasks/{id}`
- `POST /v1/tasks/{id}/messages`
- `GET /v1/tasks/{id}/events` (`text/event-stream`, exposed by the client)
- `POST /v1/tasks/{id}/approve|pause|resume|stop`
- `GET /v1/tasks/{id}/diff`

Bodies use camelCase. Task creation sends `mode`, `workspacePath`, `backendID`,
and `modelID`; message creation sends `content` plus bounded source metadata.
Diff responses must carry the requested `taskID`, `changedPaths`, `truncated`,
and `generatedAt` fields in addition to `diff`; optional `baseFingerprint` and
`receipt` fields are retained as provenance. Truncated diffs and manifests that
do not exactly match the parsed patch are refused. There is deliberately no assumed
`/apply` or `/reviews` route: Review is a normal Plan task, and Apply Result is
a local, user-confirmed workspace edit.

See [`../Schemas/lumachat-app-server-v1.schema.json`](../Schemas/lumachat-app-server-v1.schema.json)
for the language-neutral request/response envelope.

## Security and failure behavior

- Loopback is the default. A non-loopback URL is rejected unless
  `lumachat.server.allowRemote` is explicitly enabled; it must then be HTTPS and
  have a Bearer token.
- Origins containing credentials, a path, query, or fragment are rejected.
  Redirects are disabled so Authorization cannot move to another origin.
- Requests and responses have byte limits and timeouts. Task IDs are validated
  before URL construction.
- HTTP/model/backend errors stop the command. The extension performs one request
  against the configured App Server and never calls a model provider directly.
- Apply Result supports bounded UTF-8 text patches in local `file:` workspaces.
  It rejects traversal, `.git`, `._*`, symlinks, binary patches, renames/copies,
  quoted/nonmatching paths, duplicate targets, non-regular creation/deletion
  modes, file-mode changes, missing parents, overlapping hunks, truncated
  responses, and stale hunk context. New directories and remote VS Code
  filesystem schemes remain manual.
- Applying through `WorkspaceEdit` is editor-level, not a descriptor-safe
  filesystem transaction. Users must review the preview and resulting buffers;
  LumaChat's server receipt and base fingerprint are shown only as provenance.

The adapter never logs request bodies, Authorization headers, SecretStorage
values, or arbitrary server error text.
