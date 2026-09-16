# Luma Chat Agent Architecture

## Existing Chat path (preserved)

```text
LumaChatApp
  -> RootView
     -> SidebarView
     -> ChatDetailView
        -> ChatViewModel.send()
           -> ConversationStore / AttachmentService / ProjectService
           -> LLMClient.stream()
              -> Ollama / OpenAI-compatible / Anthropic HTTP request
              -> provider-specific streaming parser
           -> ConversationStore.save()
```

`ChatViewModel` remains the owner of classic chat state. Agent execution must not
be added to `ChatViewModel.send()`, and the existing `LLMClient.stream()` API stays
available for Chat without tool schemas or local project privileges.

## Codex path (additive)

```text
AgentViewModel (MainActor)
  -> AgentRuntime / AgentLoop (actor)
     -> ModelProvider
        -> OllamaProvider
        -> OpenAICompatibleProvider
        -> AnthropicProvider
     -> ToolRegistry
        -> PermissionManager
        -> ToolExecutor approval bridge
        -> WorkspaceSecurityValidator
        -> ToolExecutor
           -> Filesystem / Search / Build / Test / Terminal / Git / Todo / Web / Image / MCP / Browser / Computer Use
     -> ContextManager / ProjectContextBuilder
     -> AgentSessionStore / ChangeManager / AgentCheckpointManager
  -> GitRepositoryLayout
  -> ManagedWorktreeService / WorktreeRegistry / WorktreeLease
  -> WorktreeStateMigrator / WorktreeStateRecoveryStore
  -> Handoff + Deletion Journals / AgentTaskForkBuilder
  -> TaskTerminalService (per Task)
     -> PTYBackend -> DarwinPTYBackend -> forkpty / TerminalSandbox
     -> TaskTerminalEmulator -> AppKit terminal surface
  -> ReviewService (per exact Task/workspace binding)
     -> typed Git/task-history sources -> Review parser/presenter
     -> stable file/hunk patch -> GitService apply/check -> ChangeManager
     -> durable structured comments -> coding Agent context
  -> Review Task (separate persisted task type)
     -> locked source receipt -> Review-only tools -> structured findings
  -> PullRequestProvider
     -> GitHub adapter -> bounded network transport
     -> Keychain credential scope -> validated structured result link
```

The model server performs inference only. Filesystem, process, Git, and MCP STDIO
operations execute on the Mac running Luma Chat. Tool paths are relative to the
selected workspace; canonical paths and symlink targets are checked before every
operation.

## Modes

- **Chat** uses only the existing chat request path and has no project tools.
- **Plan** uses the Codex shell and runtime, but the executor permits read-only
  filesystem/search/Git inspection and Todo tools. It rejects writes, commands,
  deletes, and commits before execution.
- **Agent** enables registered tools according to the selected permission policy.
  Dangerous actions always require an inline approval.

Plan and Agent use separate persisted Agent sessions rather than extending the
existing `Conversation` JSON schema. This keeps older conversations decodable and
avoids a Chat data migration.

Every Agent Task also persists an `AgentExecutionLocation`. `local` uses the
user-selected checkout; `worktree` carries only a managed UUID that must be
rebound to the registry path and exact Task lease before Runtime starts. A nil
location in an older Session decodes as Local. Phase F adds `ssh`, which carries
only an opaque configured-runner UUID and must be rebound to a verified
host/user/canonical-root receipt before Runtime starts. `futureCloud` remains a
reserved fail-closed seam and is never presented as a working cloud backend.
See [`AUTOMATION_REMOTE_ARCHITECTURE.md`](AUTOMATION_REMOTE_ARCHITECTURE.md).

An Agent session may also own one bounded durable `AgentGoal`. Goal objective and
completion criteria are persisted before the provider starts, survive pause,
stop, launch-time interrupted-run recovery, and context compaction, and are
removed only by an explicit Clear action. Runtime terminal snapshots mark the
Goal completed idempotently using the snapshot timestamp. Goal edits are blocked
while a model loop is live because that loop has already captured its provider
context; Pause, edit, and Resume makes the state shown in the UI match the request
the model actually receives. The optional Goal field keeps pre-1.2 session JSON
decodable without migration, while its custom decoder reapplies input byte and
control-character bounds to corrupted/untrusted local data.

Projects 2.0 is a separate durable catalog rather than a projection of the task
list. `AgentProject` owns its user-defined name, pin/archive state, multiple
security-scoped folders, and one primary folder. `AgentSession` stores optional
`projectID` and `projectFolderID` references while retaining its workspace
snapshot for runtime/checkpoint compatibility. Opening or selecting a Project is
navigation only and never creates a task; the explicit New Task action copies the
selected Project's primary folder into the new session. A task may switch catalog
folders only before it has messages, steps, Goal, or changes.

Launch migration groups pre-1.3 sessions by canonical workspace root, imports
the validated legacy display name, persists the catalog first, and then stores
task references without changing task recency. The migration is idempotent.
Catalog validation rejects duplicate roots, root-directory authority, control
data, oversized paths/bookmarks/catalogs, and non-empty `allowedPaths`. Multiple
folders therefore do not expand one task's sandbox: one task always executes in
one checkout. Bookmark and recent-project refreshes are actor-serialized
field-level updates, so they cannot overwrite a concurrent folder-structure save
or rebind a folder to another checkout.

The shared Settings window commits only the page currently being edited. An
Agent/Project persistence failure therefore cannot partially commit a Classic
Chat connection first. Background Codex startup status is retained but is shown
only after entering Plan/Agent, so Classic Chat is not interrupted by an optional
Agent subsystem alert.

## Persistence and temporary data

- Existing Chat conversations: Application Support `LumaChat/Conversations`.
- Existing non-secret settings: Application Support `LumaChat/settings.json`.
- Existing secrets: macOS Keychain.
- Agent sessions/preferences: separate Application Support Agent paths.
- Managed worktree registry and persistent checkouts: Application Support
  `LumaChat/AgentWorktrees/registry.json` and `AgentWorktrees/Checkouts`.
- Crash intents: Application Support `LumaChat/AgentHandoffs` and
  `LumaChat/AgentDeletions`; reverse-handoff rollback payloads are stored in
  `LumaChat/AgentHandoffRecovery` with content-integrity capabilities.
- Projects 2.0 catalog: Application Support `LumaChat/AgentProjects/catalog.json`;
  project selection, pin/archive state, folders, primary folder, and bookmarks
  are independent from task JSON.
- Per-workspace Project Settings: canonical-identity Application Support record;
  environment values are stored only in Keychain. Preferred model, permission
  override, exact allow/deny commands, MCP selection, and system prompt are
  applied when the selected workspace identity matches.
- Tool output artifacts, process logs, edit snapshots, state-transfer scratch,
  build caches, and generated toolchains: `/Volumes/SD/Code/RLM/tmp` only.

The `tmp` directory is disposable. Managed checkouts may contain user work and
therefore remain persistent Application Support data; they are never treated as
cache or recursively cleaned with the project `tmp` tree.

## Reused modules

- `ConnectionProfile`, `AppSettings`, and the current selected model/endpoint are
  reused by provider adapters.
- `ProjectService` supplies the established folder-picker/bookmark UX and its
  path-safety rules inform the workspace validator. Agent tools use a live bounded
  workspace rather than the existing one-shot project snapshot.
- `ConversationStore`, `AttachmentService`, and `LocalContextService` remain on the
  Chat path and retain their current behavior.
- `LumaTheme`, `BrandMark`, and connection UI are reused so Codex feels native to
  Luma Chat without copying OpenAI brand assets.

## Dependency rules

1. Views never execute tools directly.
2. `AgentRuntime` depends on provider and tool protocols, not concrete providers or
   tool names.
3. Every tool is dynamically registered and passes permission plus workspace
   validation.
4. Read-only, parallel-safe calls may execute concurrently; writes are sequential.
5. Tool results shown to the model are size-limited and secret-redacted. Full
   output, when retained, is written only to the project `tmp` artifact directory.
6. UI shows action summaries, tool inputs/results, Todo, diffs, and final answers;
   it does not expose private chain-of-thought.

## Runtime and cancellation

Each persisted Agent session owns a dedicated `AgentRuntime`, active-run control
record, and lazily created `TaskTerminalService`. Different workspaces can
therefore keep independent model loops, Task PTYs, basic managed processes,
drafts, approvals, persistence snapshots, and security-scoped workspace leases
alive while the user navigates between tasks, Chat, and Settings.
Stop and Pause target only the selected session; app shutdown cancels and durably
reconciles every active session. Two writable Agent sessions are not allowed to
share one canonical checkout because their independent undo transactions could
race; Plan sessions remain read-only and independent Git checkouts may run in
parallel.

Location mutation acquires Task state plus canonical-root locks. Reverse
handoff locks both managed and Local roots, so another in-process writable Task
cannot enter either checkout during the transaction. A managed Task is runnable
only after registry record, UUID-owned path, state, and full lease capability
match its Session. Separate managed Tasks therefore isolate writable work by
construction; attempts to run two writers in one Local checkout still fail.

Within one session, `AgentRuntime` owns at most one active loop. Each model turn
consumes a bounded step and can yield one or more tool calls. Only tools marked
parallel-safe and read-only execute concurrently; mutations preserve provider order. Tool output is
returned as a real `tool` message before the next model turn. Provider requests,
MCP requests, terminal process groups, and the loop itself all participate in
Swift task cancellation. Stop terminates managed processes and preserves the
session; Pause records a resumable state; Retry/Resume starts from the persisted
message, Todo, step, and change history.

If an Agent mutation reaches a candidate final answer while Auto Run Tests is
enabled, the runtime invokes the registered, manifest-detected `test` tool through
the same permission/executor path. A failed result is returned to the model for a
repair turn. The step ceiling applies to both model and tool work.

Provider `finishReason` is part of the completion invariant. `length`,
`max_tokens`, and `max_output_tokens` preserve the bounded partial assistant and
schedule a continuation turn; filtered, contradictory, and tool-finish responses
without calls fail visibly. Tool definitions and schemas are included in context
allocation before each request, and an impossible model context fails before the
provider is called.

Automatic validation prefers a deterministic test command. When test detection
is explicitly unsupported but a fixed build exists, it runs that build and records
the requested action, actual action, and fallback reason. A real test failure is
never relabeled or replaced by a build.

## Provider boundary

`AgentModelProvider` is separate from Classic Chat's `LLMClient`. Provider adapters
normalize internal messages and tool schemas into:

- Ollama native chat/tool calls and NDJSON streaming;
- OpenAI-compatible `tools`, `tool_calls`, `tool_call_id`, and SSE;
- Anthropic `tool_use` / `tool_result` blocks and SSE.

The connection profile and model are captured in an immutable session route at
task creation, so a later Chat connection change cannot silently reroute a running
or resumed Agent task. Ollama capability metadata is queried when available.
Unsupported native tool calling fails visibly instead of falling back to invented
tool output.

Local workspace paths are never included in the system prompt. Tool stdout/error
text is scrubbed of the canonical workspace prefix before becoming model context.
The remote model receives bounded results and image bytes only; it never receives
a bookmark or filesystem authority.

## Tool and workspace safety

All built-ins are registered through `ToolRegistry`. Filesystem/search operations
use descriptor-relative, no-follow workspace I/O. Canonical root identity,
symlink traversal, protected host runtime roots, binary detection, depth/entry
limits, and ignore rules are enforced before data is returned. Terminal commands
run in a macOS sandbox with a per-session process group, bounded redacted output,
and HOME/TMP/cache/toolchain paths forced below project `tmp`.

`GitRepositoryLayout` supports a normal `.git` directory, linked-worktree
pointer, separate Git directory/submodule layout, nested repository root, and
detached HEAD. Pointer and Git-command outputs are bounded and validated.
Resolved per-worktree/common metadata paths are available only to the closed Git
and checkpoint backends; they never widen model filesystem or arbitrary shell
authority. Linked-worktree Git mutations work, but metadata-level native Undo is
reported unavailable instead of showing a false reversible change.

Advanced Git remains a closed host API rather than arbitrary `git` arguments.
`GitOperation` assigns every operation one fixed safety class before any
model-provided values are decoded: read-only inspection; local mutation;
network read; destructive local mutation; or destructive network mutation.
The registered surface covers fetch/pull/push, branch switch/delete, hard reset,
merge, rebase, cherry-pick, stash, tag and remote workflows in addition to the
earlier status/diff/log/show/add/restore/checkout/commit tools. Merge, rebase and
cherry-pick continue/abort commands require the exact fixed Git operation marker;
ambiguous, missing, symlinked or wrong-type metadata fails closed. Inputs use
validated references, names and credential-free configured remotes; Git runs
non-interactively with a constrained environment. Plain force-push is absent;
the only forced form is an explicit destination-scoped `--force-with-lease`,
classified as a dangerous network effect.

Before a local Git mutation, the host derives a bounded affected-path inventory,
rejects executable content filters/custom diff or merge drivers where required,
and snapshots the relevant workspace and closed Git metadata through
`ChangeManager`. Hard reset requires a complete snapshot-capable repository
layout. Conflict-producing merge/rebase/cherry-pick operations record the
failed outcome so the conflict state remains reviewable and can be continued or
aborted explicitly. Remote pushes and provider mutations are not represented as
locally undoable changes.

Search applies root and nested `.gitignore` files with scoped Git semantics,
including negation, escaped leading markers/spaces, character classes, and
`**` zero-or-more-directory matching. Rule bytes/count, glob work, traversal,
and content reads share hard budgets; ignore files and workspace paths are read
only through descriptor-relative no-follow I/O.

`run_command` also publishes redacted stdout/stderr spool deltas while the child
is running. The producer is throttled to 100 ms, each delta is capped at 8 KiB,
and Runtime retains at most 16 KiB per stream on one stable running-step card.
These presentation events never enter provider history or masquerade as tool
results; completion appends exactly one authoritative result, while pause/stop
keeps a cancelled partial-output card without inventing a result message.

Processes created by `start_process` also own a private nonblocking stdin pipe.
`write_process_input` accepts at most 64 KiB of UTF-8 per call and can close the
pipe to deliver EOF; stop, disposal, and process finalization close it as well.
This remains the bounded pipe-based managed-process path for background work.
Programs that require a controlling TTY use the separate Task Terminal path
described below; the two transports are not presented as interchangeable.

Permission is evaluated for every call, including MCP. Plan is read-only except
for its in-memory Todo state. Dangerous classifications can never be bypassed by
a session allowance. When global network access is disabled, each network call
requires approval; an explicit network Allow-for-Session grant may authorize the
same scoped tool thereafter, but a prior execute grant never implies network
authority. In Auto Approve Safe mode only the fixed built-in `build` and `test`
actions bypass execute approval; arbitrary shell or same-named extension tools
do not. File approval cards use descriptor-safe diff previews.

An explicit Allow-for-Session decision for built-in write/execute/network tools is
persisted as a bounded, canonical-workspace-scoped grant and restored after app
restart. Exact terminal arguments remain SHA-256 scoped. Dangerous grants are
never retained, and MCP grants expire at process exit because third-party server
code can change independently between launches.

Each workspace mutation records before/after fingerprints and a bounded durable
undo history. Undo uses compare-and-swap semantics and refuses to overwrite a
later user edit. Move records preserve source/destination order; when a mounted
filesystem such as exFAT does not implement atomic exclusive rename, the host
uses a bounded exclusive-create copy/remove transaction and restores both path
snapshots on failure. Undo persists history atomically from the user's point of
view: a history-save failure compensates the filesystem back to its pre-Undo
state before returning the error.

Checkpoints are written atomically beneath project `tmp` before Agent execution
when enabled and contain sanitized session/Todo metadata, Git HEAD identity,
bounded current file snapshots for task change paths, existing change IDs, and
the corresponding durable undo-history reference. Version-1 manifests remain
readable; version 2 adds the concrete file snapshot collection.

Changed-file cards expose Keep/Revert for the latest actionable transaction.
Both actions require exact task/change identity and strict LIFO order. Keep
persists removal of the Undo snapshot before changing in-memory history; Revert
retains compare-and-swap conflict protection. Older cards remain locked until
newer changes are kept or reverted.

Arbitrary shell execution cannot be represented as a safe per-file snapshot in
the general case. Its approval explains this limitation, every executed
`run_command`/managed-process input marks validation dirty, and Git workspaces
receive host-executed initial status plus final staged/unstaged diffs. Source
edits should use native filesystem tools when Keep/Revert/Undo is required.

## Task Terminal and PTY

The Phase B Terminal slice is detailed in
[`TERMINAL_ARCHITECTURE.md`](TERMINAL_ARCHITECTURE.md). One actor-isolated
`TaskTerminalService` owns up to 16 real PTYs for exactly one Task/workspace
binding. Both the native pane and the six permissioned `terminal_*` tools use
that service; neither receives a file descriptor or may resolve another Task's
terminal UUID.

The current Darwin backend uses a small C `forkpty(3)` bridge, the existing
`TerminalSandbox`, nonblocking raw-byte I/O, resizing/`SIGWINCH`, EOF and a named
signal allow-list. It tracks the original session plus observed descendants by
PID and kernel start time, including children that create a new session, so
bounded shutdown does not rely only on the original process group. `PTYBackend`
and `PTYSessionTransport` keep this OS boundary out of the UI and lifecycle
layers; no non-Darwin or Remote implementation is claimed.

The Task service atomically persists stable identity, title, dimensions,
lifecycle/exit state, relative cwd, capability/workspace binding, clear
generation, reconnect count, and offset bounds. It deliberately does not persist
environment values, commands, PIDs, descriptors, or raw scrollback. A relaunch
marks formerly running metadata `disconnected`; explicit Reconnect starts a
fresh sandboxed shell with the same terminal identity and dimensions. During one
App lifetime, navigation merely detaches the pane subscriber and the original
PTY continues running. Agent Stop/Pause does not stop it; Task deletion and App
shutdown dispose it before Session authority ends, while rebind/handoff/archive
are guarded against live terminals and Fork receives an isolated service.

`TaskTerminalEmulator` incrementally parses bounded UTF-8/ANSI/VT state,
including wide/combining cells, cursor/erase operations, SGR colour/style,
alternate screen, application cursor keys, bracketed paste, resize, scrollback,
selection copy and search. OSC title/link/clipboard and other control strings are
ignored. The AppKit surface disables automatic link/data detection and renders
only the safe attributed terminal state. Model-visible terminal reads are a
separate inert-text path: control sequences are removed and untrusted output is
bounded, secret-redacted, and stripped of host workspace paths.

## Review pane, Review Tasks, and Pull Requests

`ReviewPane` is backed by one `ReviewService` for the exact stopped coding
Task/workspace binding. The loader exposes five typed sources—Unstaged, Staged,
Commit, Branch and Last Agent Turn—and passes revisions as validated values to
the closed Git layer rather than constructing shell commands in a View.
`ReviewDiffParser` produces bounded `ReviewDocument` values with added, deleted,
modified and renamed files; textual hunks and line numbers; language/syntax
spans; and explicit binary, large or omitted fallbacks. The presentation builder
derives file-summary, unified and side-by-side rows from that same document so
display styles do not invent a second diff identity.

Every file and hunk has a stable identity plus a content fingerprint. A Stage,
Unstage or Revert request carries the identities the user actually viewed and a
host-built `ReviewPatchPayload`. `AgentViewModel` accepts only the valid source,
direction and destination combinations: Unstaged→index Stage,
Staged→index Unstage, or Unstaged→worktree Revert. Revert additionally requires
the pane's explicit destructive confirmation. `GitService` validates the patch
envelope and paths, rejects content filters, obtains exclusive command access,
runs `git apply --check`, applies through stdin, and commits or rolls back the
corresponding ChangeManager snapshot. A refreshed source invalidates stale
fingerprints and comment anchors. Linked-worktree index mutations that cannot
truthfully snapshot Git metadata report Undo unavailable instead of fabricating
a reversible change.

Inline comments retain a typed file, line, range or hunk anchor. They persist in
the source `AgentSession`; persistence failure restores the in-memory comment
set, and reloading a changed diff removes anchors that no longer validate.
Sending comments to the coding Agent appends a bounded `ReviewAgentContext` JSON
value to a durable message before Runtime starts. The context system and
provider adapters preserve this field as structured data instead of collapsing
all comments into chat prose.

Review Changes, Review Commit, Review Branch and Review PR are separate durable
Review Tasks. Their `AgentTaskType.review` stores the source Task UUID and a
normalized, locked `ReviewWorkflowRequest`. A Review Task borrows the source
checkout binding but never acquires its managed-worktree lease or inherits the
source Runtime, PTYs, approvals, permission grants, undo history or mutable
change list. Source lifecycle mutations and a conflicting writable run are
blocked while a dependent Review runs. The Runtime and executor both enforce a
Review-only tool set: bounded local inspection plus exactly the matching source
reader and `review_submit_findings`. The host records a source receipt for the
actual exposed paths; submission before that receipt, findings outside those
paths, duplicated/oversized/secret-bearing values, and prose-only completion all
fail closed. Only a validated `ReviewWorkflowResult` becomes the durable result
rendered by `ReviewFindingsPanel`.

PR integration is provider-neutral above `PullRequestProvider`. The first
adapter implements GitHub metadata/context/Create against a normalized HTTPS
endpoint (or loopback HTTP for controlled development), with an ephemeral URL
session, redirect rejection, same-origin response validation, bounded streaming
responses, cancellation and explicit error mapping. Provider configuration is
non-secret. Tokens are normalized and stored only in Keychain under the
provider+endpoint scope; changing that scope removes the old credential or rolls
back the exact previous value if Settings persistence fails.

`pull_request_get`, `pull_request_context`, and `pull_request_create` use the
provider captured in each run's immutable tool context. Reads require network
authorization when global Agent network access is disabled. Create PR is always
dangerous and must receive explicit approval; it assumes the head branch was
already pushed through the separate Git workflow. Remote title, body and patch
content are bounded, redacted and labelled untrusted. The UI derives an Open PR
link only from the structured `url` of a successful, exact built-in PR tool and
accepts only a credential-free HTTPS URL; provider prose cannot create a link.

The current implementation has no GitLab or Bitbucket adapter and deterministic
tests do not perform live push/Create PR mutations. GitHub may omit per-file
patches and bounded Review PR input cannot analyze content the provider did not
return. These are explicit limitations, not simulated results.

The 1.4.0 release audit's four source/action gaps are closed. Unstaged and
Review Changes synthesize bounded untracked-file patches; artifact-backed Git
output is consumed through continuous pagination and incomplete receipts fail
closed; fallback copy matches the actions actually exposed; and Last Agent Turn
is captured as a frozen persisted source rather than newest-per-path fragments.

Last Agent Turn finalization holds the exclusive Git command gate and compares
three checkout identities around two complete renders. Each identity includes
HEAD plus sorted changed/deleted/untracked path existence, mode, size and
SHA-256. A bounded three-attempt retry accepts only identical identities and
rendered output; continuing external or Task Terminal writes fail closed. The
workspace root's device/inode identity and every descriptor-safe file read are
also revalidated, including same-length in-place rewrites. Review still lacks a
live, separately authorized push→create→open→review acceptance run; deterministic
tests intentionally do not perform that external mutation.

## Managed worktrees, handoff, and fork

The Phase A location subsystem is detailed in
[`WORKTREE_ARCHITECTURE.md`](WORKTREE_ARCHITECTURE.md). Its central invariants
are:

- one UUID-owned managed checkout and exact lease capability per writable Task;
- a planned checkout identity persisted before Git allocation;
- forward handoff ordered as journal → allocate → copy/verify → Session commit;
- reverse handoff guarded by the exact Local baseline, fast-forward policy, and
  a durable content-addressed rollback snapshot;
- launch recovery that acts only when the persisted Session matches one proven
  side of the transaction;
- a second source-state verification before committed cleanup, so a newer
  external source edit retains the checkout;
- Task Fork copies bounded durable context and checkpoint provenance while
  resetting Runtime, process, terminal, approval, permission, and change state;
- Task deletion releases only the journaled lease after durable Session absence
  and never treats a potentially dirty checkout as disposable.

Sidebar and detail actions expose Local → Worktree, Worktree → Local, Fork,
Local/Worktree → SSH, and SSH → the retained original Local checkout only
for stopped, non-conflicting Tasks. Location badges remain truthful. SSH uses an
explicit bounded same-HEAD migration, pinned runner authority, durable baseline
and transaction UUID; it is never described as shared storage or continuous
synchronization. `.futureCloud` remains a fail-closed schema reservation.

## Browser/CDP

Phase E adds a real Task-owned Browser layer rather than routing web workflows
through pixel Computer Use. `BrowserToolCoordinator` binds one immutable Task /
workspace authority to an isolated, persistent, or explicitly attached
`BrowserService` session. Model arguments can select only tabs and operations;
profile mode, profile name, debug endpoint and repository root remain host-owned.
Changing any authority closes the prior session, and open/close/shutdown races
cannot leave an untracked Browser process.

Managed Chromium profiles, cache and downloads live only under the repository's
protected `tmp/browser` tree. The default profile is ephemeral. Named persistence
is explicit, owner-only and separately deletable. Attach Existing Browser accepts
only a loopback DevTools endpoint, warns that the session may already be signed
in, never terminates the external process, and refuses browser-global downloads.

DOM/layout, a bounded Accessibility tree, screenshots, console/page errors,
network metadata, performance, JavaScript and redacted cookie reads flow through
CDP. Page-derived data is projected before bounded retention and returned inside
an escaped `trust=untrusted` model envelope; request bodies, cookie values and
unknown headers are not exposed. Browser screenshot annotations persist bounded
structured regions under the Browser session with a separate owning-Task check.
Approved downloads use GUID paths, timeout/size limits, no-follow file validation
and SHA-256 artifact receipts. Full invariants and limitations are in
[`BROWSER_ARCHITECTURE.md`](BROWSER_ARCHITECTURE.md).

Routing order is structured provider/tool first, Browser DOM/CDP second,
Accessibility semantics third, and pixel Computer Use only as the last fallback.

## Computer Use 2.0

Computer Use is an experimental, opt-in Agent capability. It is disabled by
default and remains unavailable until the user enables it in Agent Settings.
Enabling it does not grant access to every application: the user must also enter
each complete macOS bundle identifier into a bounded exact-match allowlist. An
empty allowlist permits no applications, and the runtime fails closed for an
unknown identifier. Target applications must already be running; Computer Use
does not launch them automatically.

The allowlist cannot authorize Luma Chat itself, ChatGPT/Codex, terminal apps,
System Settings, login/security agents, password or Keychain apps, or installer
surfaces. These applications remain blocked even if their bundle identifiers are
saved in Settings. This blocks the direct variants, but a generic allowlisted
browser or IDE can still contain network features or an embedded terminal. The
bounded semantic layer cannot classify every control inside another App, so every
action remains human-approved and these surfaces should not be allowlisted for
sensitive work.

macOS authority and Luma Chat policy are separate layers:

- Screen Recording is required to list and capture visible windows of an
  allowlisted app.
- Accessibility is required to inspect semantic controls or activate, click,
  type, press keys, scroll, focus, or press them.
- The bundle-ID allowlist still applies when both macOS permissions are granted.
  Luma Chat reports missing permissions but never approves the corresponding
  System Settings prompt itself.

Phase E adds bounded window discovery and explicit selection. An App may have
several safe on-screen, layer-zero windows; `computer_list_windows` returns at
most 32 candidates and `computer_screenshot` accepts the exact `window_id`.
Omitting it remains valid only when exactly one window exists. Multiple matching
App processes still fail closed. Every later operation stays bound to the
selected CG window owner, ID, dimensions and unchanged geometry. Foreground
pixel actions raise and verify that exact Accessibility window instead of
activating every window in the App.

Computer Use tools use the existing permission pipeline. Permission status,
allowed-running-app/window discovery, target-window screenshots, bounded
Accessibility snapshots, and background verification are `read` tools and are
the only Computer Use tools exposed in Plan mode. Activation, clicking, typing,
key presses, scrolling, and semantic actions are all `dangerous`: every call
requires explicit inline approval and never receives a persistent allowance. Action
arguments require a short user-visible reason. The approval card loads the
validated capture from session storage and shows it; click approval also overlays
the requested coordinates, while semantic approval overlays the capture-bound
element frame. Secret-like text that redaction would hide is refused instead of
being invisibly typed, leaving authentication to the user.

The scoped Always Allow policy is host-computed from a fixed tool-name set and
shown in the approval UI. Only exact-scope observation/verification operations
are eligible. Every mutation, including Accessibility `press` and `focus`, is
ineligible regardless of model arguments and therefore remains a fresh-capture,
single-use `allowOnce` decision. This does not add a second authorization path or
weaken the rule that `dangerous` grants are never persisted. Computer Use session
allowances are keyed to the exact built-in tool and canonical argument payload,
remain process-local to this host, and are excluded from relaunch persistence.

Screenshots use ScreenCaptureKit and become bounded PNG image attachments stored
through the Agent image attachment path and returned to the next model request.
The selected provider must support vision and model image input must be enabled;
otherwise every Computer Use tool is hidden for that run. Screen content may
therefore be processed by the selected model server. Click coordinates are
relative to the returned image. Each task retains only its latest capture, which
expires after 30 seconds and is consumed by any UI action. The ID is bound to the
exact task, bundle identifier, unique process, selected visible window, dimensions,
and unchanged window geometry; expired, reused, moved/resized,
moved-to-another-app, missing, or out-of-bounds targets are rejected. Every
action rechecks both macOS permissions after approval and revalidates the target
immediately before execution; foreground actions validate it again after exact-
window activation. Text input is bounded Unicode and does not use the clipboard;
the service independently rejects secret-like text and rechecks that the focused
target is a non-secure editable control inside the selected window immediately
before posting events.
Narrowing the allowlist, disabling Computer Use, or changing the vision policy
pauses active tasks so an older execution snapshot cannot retain revoked GUI
authority.

Semantic targeting is deliberately narrow. A bounded traversal returns only
opaque, capture-bound IDs for visible pressable/focusable controls; it never
returns text-field values, rejects secure text fields, accepts only host-mapped
`press`/`focus`, and re-resolves the AX path, role, label, identifier and frame
immediately before use. Semantic actions do not activate the App and report
whether the foreground App, window geometry and element identity remained stable.
The read-only verification tool performs the same checks without input and does
not consume the capture.

Computer Use is still not a Browser or a broad accessibility automation
platform. Browser DOM/CDP is provided by the separate Task-owned Browser layer;
Computer Use itself has no browser extension, arbitrary DOM operations or
locked-screen execution. It cannot approve administrator, security, or privacy prompts. It
still refuses an App with multiple matching processes rather than guessing a
target. GUI actions may change app or remote state outside the workspace and may
not have a native Diff/Undo record. Approval and result surfaces therefore label
them as `External Side Effect · Not Undoable`, so structured tools and connectors
remain the preferred path when available.

## MCP lifecycle

`MCPManager` owns connection lifecycle and dynamically registers discovered tools
under a collision-safe `mcp.<server>.<tool>` namespace. Both STDIO and MCP
Streamable HTTP use JSON-RPC initialize/initialized negotiation, bounded payloads,
cancellation, redacted lifecycle logs, and clean unregister/disconnect behavior.
Streamable HTTP incrementally parses bounded SSE, correlates exact request IDs,
supports POST streams and 202-to-GET receive streams, negotiates session/protocol
headers, rejects redirects/cross-origin responses, expires 404 sessions, and
cancels active streams on stop.
Resources, resource templates, and prompts are discovered as optional server
capabilities. User-selected Composer actions call `resources/read` or
`prompts/get`; discovery rows alone never inject third-party content into model
context. MCP environment/header secrets are stored in Keychain and are redacted
from settings files, logs, approval payloads, and model messages.

Connected MCP adapters may coexist in the shared registry for different projects.
Before every model turn, registry schemas are filtered against the run's captured
Project Settings allow-list and canonical workspace. `ToolExecutor` repeats the
same check before dispatch, so a forged or stale project-only MCP tool name fails
closed even while another project's Agent is running.

## Image context

Image references persisted with Agent messages point only to private copies under
that Agent session's Application Support `Attachments` directory. Imports use
bounded descriptor-safe reads, validate signature/MIME/dimensions/digest, and
enforce per-message and per-session quotas. Request-scoped bytes are loaded only
after integrity revalidation. Vision-capable provider adapters receive their
native image representation; non-vision models receive metadata text without
image bytes. Deleting an Agent session removes its private attachment directory.
Automatic vision mode trusts Ollama metadata and otherwise fails closed for
OpenAI-compatible/Anthropic endpoints whose model capability cannot be proven;
the user can explicitly enable or disable vision per Agent settings. Context
allocation reserves conservative image tokens before bytes are hydrated.

Composer input disposition follows durable session state: a submitted draft and
pending images are consumed only after the user message snapshot saves. Pause,
Stop, and terminal completion use the same rule, and persistence failures keep a
resendable copy visible. The session store rejects older `updatedAt` snapshots so
late background saves cannot overwrite newer crash-recovery reconciliation.

## Validation environment

Repository build, test, package staging, generated modules, and test Application
Support data must be directed below `/Volumes/SD/Code/RLM/tmp`. The development
checkout is on ExFAT. Native host permission display is therefore synthesized;
an APFS pass remains required when validating enforcement of exact host `0600`
mode bits. The release archive does not inherit those synthesized modes: its
strict manifest writer and verifier encode directories/executable as `0755` and
plist, icon, and CodeResources as `0644`. SwiftPM operations that insist on a
volume-root `.TemporaryItems` directory are rejected instead of weakening the
Agent sandbox. Classic Chat regression remains a separate required test group.

### Phase A release gate — 2026-08-31

- `Scripts/release.sh` completed end-to-end with every temporary, cache,
  module, configuration, security, and test Application Support path below the
  repository `tmp` tree. Python bytecode emission is disabled for packaging.
- The release-archive suite passed **5 tests, 0 failures**, including rejection
  of source AppleDouble files, injected archive AppleDouble entries, altered
  Unix modes, and altered content with a newly valid CRC.
- The complete Swift suite passed **344 tests, 0 failures** in 443.388 seconds.
  This includes the real Git/ViewModel Local → Worktree → Fork → Local E2E,
  Local-conflict no-mutation behavior, lifecycle/lease, transaction/recovery,
  symlink/tamper, AtomicFileWriter, and Classic Chat regressions.
- The production build completed in 165.68 seconds. The packaged app and a
  cleanly extracted copy both passed `codesign --verify --deep --strict`; plist
  lint, `CFBundleExecutable`, version `1.3.1`, executable presence, and Mach-O
  arm64 checks passed.
- ZIP CRC, exact signed-bundle membership, duplicate/unsafe-name exclusion,
  SHA-256 content equality, AppleDouble/`__MACOSX` exclusion, and canonical
  `0755`/`0644` external attributes passed independently of ExFAT host modes.
- `dist/LumaChat-1.3.1-arm64.zip` is 5,925,087 bytes with SHA-256
  `b9736079bdfb686eb401f88c13d3ad26df75f28fd691e998121831ac09618fac`.
- Native UI smoke launched the packaged app, switched Chat → Agent, rendered
  Luma Codex/Projects/New Task controls, confirmed the switch created no
  implicit Task, and exited normally.

This is an ad-hoc-signed local release. Developer ID signing, Hardened Runtime,
notarization/stapling, update feed, rollback package, and cross-platform release
validation remain later release-program work and are not claimed by Phase A.

### Phase B release gate — 2026-09-06

- The direct Terminal set passed 47 cases: 21 PTY, 11 emulator, 5 service, 5
  tool/security, 3 ViewModel lifecycle, one pane-model and one rendered-surface
  case. Real-program coverage includes `vim`, Python REPL, `nano`, `htop`,
  `git add -p`, offline `ssh -G` and `pip`; setuid-root `/usr/bin/top` is one
  explicit sandbox skip.
- Advanced Git passed 21/21. The combined Advanced Git, persistence,
  Local↔Worktree handoff and renewable-lease gate passed 37/37. Descriptor-safe
  filesystem/change coverage passed 17/17.
- Runtime Stop/Pause/shutdown now use one terminal-session persistence owner;
  natural completion cannot be overwritten while persistence is suspended.
  Managed worktree lease renewal changes freshness without invalidating the
  immutable capability token.
- The isolated integrated suite passed 504 tests with one explicit skip and
  zero failures in 177.768 seconds. All five archive tests passed, and the
  isolated production arm64 build completed in 125.87 seconds.
- The app and extracted app passed strict code-signature and plist checks. ZIP
  CRC, exact manifest/content/mode and AppleDouble/`__MACOSX` exclusion passed.
- Packaged UI smoke on a fresh support root verified Chat→Agent with no implicit
  Task, Project addition with no implicit Task, explicit Task creation, real
  unstaged Review content, real PTY/ANSI output, pane continuity and clean quit.
- `dist/LumaChat-1.4.0-arm64.zip` is 7,315,724 bytes; SHA-256 is
  `224d6942969670cd090797416bdcfb979a79387a827b68fa8c184d64d871b2b0`.
  It is an ad-hoc-signed local artifact; Developer ID/notarization remain Phase
  H. The Phase B artifact remains the latest validated release. Phase C source
  integration is complete and awaits the requested combined Phase C–H gate.

### Phase C Subagent orchestration

- Parent Coding Tasks receive a host-owned orchestration capability and seven
  bounded tools; children cannot recursively delegate.
- `SubagentScheduler` owns the persistent priority queue, provider/model and
  global capacity, budgets, timeout, recovery, failure isolation and parent
  cancellation propagation.
- Read-only children are rooted to an exact safe directory. Writable children
  are ordinary durable Agent Tasks backed by their own managed-worktree lease.
- Tool publication and execution independently enforce exact child tool, MCP
  and network scope. Parent follow-ups are consumed only by the addressed child.
- Validated structured results are collection-gated before a Parent Task may
  finish. Sidebar and detail UI expose the durable parent/child status tree.
- The full design and deferred test matrix are documented in
  [`SUBAGENT_ARCHITECTURE.md`](SUBAGENT_ARCHITECTURE.md).

### Phase D extension runtime

- `SkillService` discovers bounded `SKILL.md` packages from global, project,
  repository, nested, and enabled-plugin roots. The host selects explicit
  `$skill` or description matches and adds instructions only to the current
  provider request; durable Session state stores bounded loaded-Skill metadata,
  not a permanently expanded system prompt.
- `skill_read_resource` is hidden without an exact host-loaded Skill ID and
  accepts only bounded UTF-8 regular files contained below that Skill root.
  Declared scripts do not gain execution authority.
- `PluginManager` separates source inspection from activation, validates
  manifests/packages/declared files and minimum app version, previews required
  permissions, and uses atomic records plus staged package swap/quarantine
  recovery for install, update, enable/disable, and uninstall.
- Plugin tools and hooks are registered alongside built-ins but execute through
  the same `ToolRegistry`, `PermissionManager`, and `ToolExecutor`. Hook schemas
  are unavailable to ordinary model context and require a matching host-created
  lifecycle capability. Each exact declared binary runs without a shell in a
  permission-derived macOS sandbox; bounded stdin writing cannot block timeout
  enforcement.
- Runtime dispatches typed lifecycle boundaries with bounded/redacted detail,
  per-hook timeout/permission/network gates, durable history, and
  continue/fail-task/disable-plugin failure policy.
- OAuth public configuration is atomic JSON; PKCE tokens are Keychain-only.
  Plugin-declared MCP servers carry explicit owner IDs so disable/uninstall
  cannot remove manual MCP configuration.
- Architecture, persistence, threat boundaries, focused test inventory, and
  honest limitations are documented in
  [`PLUGIN_ARCHITECTURE.md`](PLUGIN_ARCHITECTURE.md). The tests/build remain
  intentionally deferred to the combined Phase C–H gate.
