# Luma Chat Task Terminal Architecture

Status: release-gated as the Terminal slice of Phase B on 2026-09-06.
The adjacent Advanced Git, Review/hunk/inline Review Agent, and provider-neutral
PR slices now exist in the integrated development tree; their architecture and
current evidence are recorded in `AGENT_ARCHITECTURE.md` and
`CODEX_FULL_PARITY_AUDIT.md`. The complete Phase B regression, archive and
packaged UI gates passed in the 1.4.0 artifact.

## Capability chain

```text
AgentDetailView
  -> TaskTerminalPane / TaskTerminalPaneModel
     -> TaskTerminalService (one actor per Task/workspace binding)
        -> PTYBackend
           -> DarwinPTYBackend
              -> PseudoTerminalSession
                 -> LumaPTYSupport forkpty bridge
                 -> TerminalSandbox launcher/profile
                 -> bounded raw-byte ring + output events
                 -> PID/start-time descendant tracker + process-tree shutdown
        -> TaskTerminalMetadataStore

AgentRuntime
  -> ToolRegistry
     -> PermissionManager / ToolExecutor
        -> terminal_create / terminal_write / terminal_resize
        -> terminal_read / terminal_signal / terminal_close
           -> the same TaskTerminalService
```

The AppKit surface and Agent tools share a Task-owned service, but neither owns
the PTY descriptor. Closing a pane or navigating to another Task, Chat, or
Settings detaches only an event subscriber. The PTY, output pump, and process
tree continue independently of view lifetime and of the coding Agent loop.

## PTY transport

`LumaPTYSupport` is a small Darwin C boundary around `forkpty(3)`. The child has
a controlling terminal, session/process-group identity, descriptors 0/1/2
connected to the slave, an explicit working directory/environment, and the
sandbox launcher as its executable. The child also restores a usable signal
mask before `exec`, because `forkpty` may be called from a Swift/Dispatch worker
whose inherited mask is unsuitable for an interactive shell.

`PseudoTerminalSession` owns the nonblocking master descriptor and provides:

- raw bytes in both directions, canonical and raw terminal behavior, EOF, and
  an interactive login shell;
- `TIOCSWINSZ` resizing and `SIGWINCH` delivery;
- an allow-list of interrupt, quit, hangup, terminate, kill, suspend, and resume
  signals rather than arbitrary signal numbers;
- an asynchronous readiness-driven output pump, stable raw byte offsets, and a
  bounded 2 MiB ring even when no consumer is attached;
- serialized writes up to 64 KiB with bounded backpressure handling;
- exact exit code/signal state and a self-retaining reaper;
- graceful stop followed by bounded `SIGKILL` escalation.

Process-group signalling alone is insufficient when a descendant calls
`setsid()`. The Darwin backend therefore tracks the original session and every
observed descendant using `libproc` identities composed of PID plus kernel start
time. Stop/dispose signals only identities proven to belong to that PTY and
does not affect another terminal session.

The platform boundary is expressed by `PTYBackend` and
`PTYSessionTransport`. Task lifecycle, tools, and UI depend on that seam rather
than Darwin file descriptors. Only `DarwinPTYBackend` exists today; this is an
architectural seam, not a claim of Linux, Windows, or remote PTY support.

## Sandbox and permissions

The PTY uses the existing `TerminalSandbox` execution boundary. Its workspace,
Git-metadata, network, environment, HOME, temporary, cache, and toolchain policy
is captured by the Task service when a terminal is created; a model cannot
select a different backend or host through tool arguments. Working directories
are validated against the bound workspace, and each terminal UUID resolves
only inside the service for that exact Task.

The six structured tools remain ordinary registered tools:

| Tool | Permission | Bound |
| --- | --- | --- |
| `terminal_create` | execute | validated cwd, supported shell, 1...1000 rows/columns, bounded title/environment |
| `terminal_write` | execute | exact Task UUID, at most 64 KiB UTF-8, optional EOF |
| `terminal_resize` | execute | exact Task UUID and 1...1000 rows/columns |
| `terminal_read` | read | exact Task UUID and at most 64 KiB raw input per call |
| `terminal_signal` | execute | exact Task UUID and named signal allow-list |
| `terminal_close` | execute | exact Task UUID; stops the process and removes its metadata |

Every mutation passes `ToolRegistry`, `PermissionManager`, and `ToolExecutor`.
The UI separately uses destructive confirmation for Kill and Close. Tool-visible
descriptors omit PID and absolute workspace binding. `terminal_read` turns raw
bytes into bounded inert lossy UTF-8, strips ANSI/OSC control state, marks the
content untrusted, redacts secrets, and scrubs host workspace paths before the
result can enter provider context.

## Task session service and persistence

One `TaskTerminalService` may own at most 16 terminals. Stable UUIDs, ordering,
title, dimensions, lifecycle/exit state, clear generation, reconnect count,
relative working directory, shell, capability snapshot, workspace binding, and
raw offset bounds are written atomically beneath the Agent Session's
`Terminals/metadata.json`. The document is no-follow validated, identity-bound,
and limited to 256 KiB.

Commands, environment values, PIDs, PTY descriptors, and raw scrollback are
deliberately not persisted. On App relaunch, metadata that said `running` is
reconciled to `disconnected`; Luma Chat never guesses that an old process still
belongs to the new App instance. Explicit Reconnect preserves the stable
terminal UUID/title/dimensions and starts a fresh sandboxed shell, incrementing
the reconnect counter. This is metadata recovery, not process resurrection.

Within one App lifetime, switching Task or navigation surface does not require
Reconnect: the original PTY remains alive. Stop/Pause of the coding Agent also
does not stop Task terminals. Location rebind, handoff, and project archive are
blocked while the affected Task owns a live terminal. Fork creates an isolated
Task service and shares no terminal execution state. Task deletion, project
deletion, and App shutdown dispose services before Session authority ends.

Lifecycle mutations use per-entry transition guards. Metadata updates are
persisted before success is exposed, with rollback where an already-applied
rename cannot be committed. The pane also rejects stale attachment results,
serializes rapid key/paste writes, chunks input at 64 KiB, and applies direct
close/rename/signal state so a bounded event buffer cannot fabricate an old tab.

## Emulator and native surface

`TaskTerminalEmulator` consumes arbitrary byte boundaries incrementally. It
handles split/malformed UTF-8, combining marks, wide cells and emoji clusters,
C0 controls, tabs, cursor movement, insert/delete/erase operations, SGR styles,
256-colour and true-colour values, alternate screen state, application cursor
keys, bracketed paste, cursor visibility, resize, and soft wrapping.

Scrollback defaults to 10,000 lines, is capped at 20,000 lines and four million
cells, and is additionally bounded by the transport's raw-byte ring. Search and
selection/copy use stable buffer coordinates. Escape/control strings are capped
at 4 KiB; oversized sequences recover to ground state. OSC title, hyperlink,
clipboard, and other control-string actions are ignored, so terminal output
cannot install links, write the clipboard, or call back into the App.

`TaskTerminalSurfaceView` is an AppKit text surface hosted by SwiftUI. It renders
safe SGR bold/dim/italic/underline/strikethrough/inverse/hidden attributes,
indexed/true colours, and a visible cursor; automatic link/data detection and
rich-text imports are disabled. It forwards ordinary keys, control keys,
application cursor sequences, bracketed paste, viewport resize, selection copy,
and Find without using terminal output as an action source.

The pane exposes New, Rename, Reconnect, signals/EOF, Kill, Clear, Copy, Search,
Close, multiple tabs, lifecycle badges, and the selected terminal's exit state.
Its replay is bounded to 4 MiB and then continues through push events.

## Verification checkpoint

The release gate has the following passing focused evidence:

- 21 `PseudoTerminalSessionTests`: controlling TTY/process group, raw and
  canonical input, Ctrl-C/Ctrl-D, interactive shell, signals, immediate exit,
  resize/SIGWINCH, bounded output, ordinary and `setsid` descendant cleanup,
  cross-session isolation, sandbox escape rejection, and real `vim`, Python
  REPL, `nano`, `htop`, `git add -p`, offline `ssh -G` and `pip` prompt paths.
  The macOS setuid-root `/usr/bin/top` fixture is one explicit environment skip
  because the sandbox correctly rejects it;
- 11 `TaskTerminalEmulatorCoreTests`: incremental Unicode, malformed input,
  controls/CSI/SGR, private modes/alternate screen, ignored OSC, bounded escape
  recovery, scrollback/copy/search, resize, and invalid configuration;
- 5 `TaskTerminalServiceTests`, including injected `PTYBackend`, bounded/corrupt
  metadata recovery, multiple terminals, clear, lifecycle, and reconnect;
- 5 `TaskTerminalToolTests`: closed schemas, permission gating, argument limits,
  Task/network isolation, and inert/redacted model-visible output;
- 3 `AgentViewModelTaskTerminalLifecycleTests`: fork/rebind/archive guards,
  independence from Agent Stop, and deletion/shutdown disposal ordering;
- one pane-model ordering/lifecycle test and one attributed-surface rendering
  test.

These 47 direct Task Terminal cases pass. The complete isolated suite passed
504 tests with one explicit skip and zero failures. The C bridge passes strict
warning checks, and packaged 1.4.0 UI smoke created a real shell, rendered ANSI
output, preserved terminal/review state across pane navigation and quit cleanly.

## Remaining limitations and gates

- App relaunch cannot reattach to the previous Unix process or recover raw
  scrollback; explicit Reconnect starts a fresh shell from verified metadata.
- Only the Darwin backend is implemented. Remote SSH PTY and non-macOS backends
  remain later-phase work.
- The requested real-program matrix is covered where the release host provides
  the program. Node/npm are not installed and are recorded as not applicable;
  `/usr/bin/top` is explicitly skipped for the setuid sandbox reason above.
- Crash-at-every-stage, storage exhaustion, PTY crash injection, multi-hour
  soak, accessibility, and large paste/output stress matrices remain incomplete.
- Multi-hour soak, cross-platform backends and production remote terminals
  remain later Phase F/H work; they do not invalidate the completed Phase B
  local macOS gate.
