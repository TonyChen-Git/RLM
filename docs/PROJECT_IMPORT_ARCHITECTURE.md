# External assistant import (Phase K development)

LumaChat imports only user-reviewed local snapshots. Project instructions and
settings are previewed in Project Settings; a user-selected chat export is
imported as a separate completed Task with user/assistant text only. Imported
content never grants file, command, MCP, network, approval or hook authority.

## Sources and scope

- Claude Code: root `CLAUDE.md` and relative `@path` references within the
  selected Project. References are expanded recursively with a six-level,
  32-file and 256 KiB total ceiling. Cycles, traversal, symlinks, hard links,
  credential-looking paths, non-UTF-8 text and changed files fail closed.
- Cursor: legacy root `.cursorrules` and `.cursor/rules/**/*.mdc` files.
  `alwaysApply`, `globs` and `description` are parsed from a bounded front
  matter subset. The reviewed rules persist with their scope in Project
  Settings. Always rules enter each model turn; glob rules enter only when a
  matching path appears in this Task's recent user/tool text. Agent-requested
  and manual rules require an explicit user `@rule-name` mention. A 32 KiB
  transient projection caps each turn. The original `.mdc` files are never
  executed or changed.
- Project configuration: `.claude/settings.json` shows top-level keys and can
  copy a safe model preference into the Project Settings draft. Cursor
  `.cursor/mcp.json` shows server names only. Permissions, commands, hooks,
  environment values, MCP launch configurations and credentials are excluded.
  The user must still save Project Settings after applying a draft.
- Chat: a user-selected Claude Code JSONL transcript or Cursor Markdown
  export. Only text blocks from user/assistant messages are retained. Tool
  calls/results, reasoning, images and unknown records are omitted. The
  importer caps the source at 5 MiB, retained text at 256 KiB and messages at
  500. Each message and title is redacted before persistence. The source file
  is rechecked after preview. A source digest on the Task prevents a repeated
  import into the same Project, including after restart.

The importer uses file descriptors, `O_NOFOLLOW_ANY`, regular-file/link-count
checks, bounded reads and before/after metadata comparison. Preview source
changes are rejected before applying an instruction draft or importing a chat.
Project Settings writes are atomic through the existing store. Chat Task
persistence completes before the UI publishes the Task; a failed save leaves
the Task absent. Cancel closes a preview without writing.

## Saved import recovery

Saving an instruction/configuration import atomically records one undo slot in
Project Settings for only the changed prompt, scoped rules or model preference.
The snapshot is bounded and redacted; credentials, permissions, commands and MCP
configuration are never copied into it. Identical re-imports retain the existing
undo slot. A newer changed import replaces it.

The settings UI previews current and restored values before confirmation. Restore
is available after restart, checks the Project identity, undo ID and current
imported-field fingerprint, and refuses if those fields were edited afterwards.
Unrelated settings and current Keychain references are preserved. Successful
restore clears the slot atomically; failed saves keep the previous document.
Cross-instance mutations use a descriptor-based, nonblocking exclusive lock;
contention reports a retryable storage-busy error rather than waiting on the UI
thread. Document schema 2 keeps schema 1 readable and makes older apps reject new records instead of
silently deleting the undo state. This is single-import recovery, not a general
Project history or an undo of imported chat Tasks.

## Limits and acceptance

The Cursor Markdown parser accepts `## User` / `## Assistant`, `###` variants
and bold `**User:**` / `**Assistant:**` headings. Vendor export formats can
change, so an unknown shape fails closed. Scoped glob matching uses a bounded
`*`, `?`, `**` subset; it does not claim identical activation behavior to
Cursor. Cursor MCP server configuration and Claude permissions are previewed
as inert metadata only because they cannot safely map to LumaChat authority.
The 2026-10-01 development gate passed 816 Swift tests (one environment skip,
zero failures) and an ad-hoc signed arm64 package. Isolated-profile packaged
UI smokes covered first previews, settings save/reopen, text-only Task import,
duplicate blocking and clean exit. The integration suite covers import
idempotency across restart; a packaged App relaunch was not run. Live exports
from Claude Code/Cursor accounts remain pending in the parity audit.
That historical gate predates the saved-import undo slot. The October 12
follow-up is revalidating the rollback implementation; its new integrated gate
and packaged restore/conflict UI acceptance remain pending until recorded in
the parity audit.

Format references: [Claude Code memory and `CLAUDE.md`](https://code.claude.com/docs/en/memory),
[Cursor project rules](https://docs.cursor.com/context/rules), and
[Cursor Markdown chat export](https://docs.cursor.com/en/agent/chat/history).
