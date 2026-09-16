# LumaChat CLI

The `lumachat` frontend is a thin client of LumaChat's task-scoped headless
runtime. It does not own an `AgentRuntime`, change desktop selection, or keep a
second task store.

## Commands

```text
lumachat chat [--backend-id ID] [--model-id ID] [PROMPT]
lumachat agent [--task-id UUID | --workspace-path PATH] [PROMPT]
lumachat exec [--task-id UUID | --workspace-path PATH] PROMPT
lumachat resume --task-id UUID [PROMPT]
lumachat tasks [list [--all] | show ID]
lumachat projects [list [--all] | show ID]
lumachat skills [list | show ID]
lumachat mcp [list | show ID]
lumachat plugins [list | show ID]
```

`exec` is always non-interactive. Its approval policy is `deny`, so an
approval-requiring operation exits instead of waiting forever in CI. `chat`
and `agent` can read one prompt from stdin only when they are interactive.

`--json` emits one result envelope. `--jsonl` emits event records followed by
one terminal result record. Machine-readable failures go to stderr and never
pollute stdout. A single JSON envelope retains at most 4,096 events / 16 MiB;
if a longer run exceeds that replay budget the result sets `eventsTruncated`
and `droppedEventCount`. JSONL remains streaming and does not accumulate an
unbounded in-memory event list. Terminal summaries are capped at 8 KiB and a
terminal result payload that exceeds 16 MiB is omitted with `resultTruncated`
set in the result record.

## Shared-runtime boundary

The production adapter implements `LumaCLIHost` and delegates to the same
task-scoped service as `LumaChatHeadlessRuntimeFacade`. Its exact methods are:

```swift
resolveBackend(selection:)
chat(request:eventHandler:)
createTask(request:)
task(id:)
sendMessage(taskID:request:eventHandler:)
resume(taskID:request:eventHandler:)
tasks(action:)
projects(action:)
skills(action:)
mcp(action:)
plugins(action:)
```

The adapter also translates safe server/runtime failures into `LumaCLIError`:
backend unavailable to exit 69, approval/permission failures to 77,
configuration failures to 78, and task-not-found/execution failures to 1.
Unexpected errors remain generic and are redacted by the runner.

For a new Agent or exec run, the frontend calls `createTask` once, requires a
returned task UUID, and then calls `sendMessage` with that explicit UUID. For
an existing run, `--task-id` is forwarded unchanged. Resume always requires
`--task-id`. Existing send/resume first reads `task(id:)` and pins its durable
route through the terminal result. None of these operations may infer a task
from desktop selection.

The adapter must resolve an omitted route to exactly one configured
`backendID` and `modelID`. Explicit IDs are constraints, not preferences. The
runner compares the resolved, created, and terminal route identities; any
substitution exits as backend unavailable. An unavailable local backend must
never fall through to another provider or a future cloud seam.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Completed successfully |
| 1 | Execution, timeout, or not-found failure |
| 2 | Invalid command usage |
| 69 | Selected backend/model unavailable or substituted |
| 77 | Approval or permission denied |
| 78 | Invalid/missing configuration |
| 130 | Cancelled |

The `lumachat` product is a dependency-free `execv` launcher. It resolves only
an explicit `LUMACHAT_APP_BINARY`, its adjacent SwiftPM `LumaChatDesktop`
product, or the standard system/user LumaChat app locations; it never searches
`PATH` or launches a shell. Normal commands are forwarded as `--cli` and
`lumachat server` as `--server` to the app binary.

The app owns the only process entrypoint. CLI mode starts
`SharedAgentHeadlessRuntime`, passes the unchanged post-`--cli` arguments to
`LumaCLIEntrypoint.run`, shuts the runtime down, and exits exactly once with the
returned status. Help, version, and usage failures are parsed and rendered
without constructing that runtime. App Server mode defaults to
`127.0.0.1:32189`, requires its
Bearer token on every request, and refuses non-loopback binds. Supply the token
with `--token` or `LUMACHAT_SERVER_TOKEN`; when neither is present, the launcher
generates a random token and displays it once on stderr.

SwiftPM names the GUI product `LumaChatDesktop` and the CLI product `lumachat`.
The names must differ by more than case because ordinary macOS APFS volumes are
case-insensitive. Release packaging still installs the desktop binary as
`LumaChat.app/Contents/MacOS/LumaChat` and embeds the signed shim at
`LumaChat.app/Contents/Resources/bin/lumachat`, which may be linked from a
user-controlled command directory.
