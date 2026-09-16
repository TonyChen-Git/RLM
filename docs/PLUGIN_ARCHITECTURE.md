# Luma Chat Skills, Plugins, Hooks, and OAuth Architecture

Status: Phase D implementation complete in the development tree; execution of
the combined Phase C–H validation/build/package gate is intentionally deferred
by request.

## Trust model

Skills, plugins, MCP servers, and OAuth connectors are separate capabilities.
A plugin manifest can declare all of them, but installing a plugin does not
silently grant filesystem, process, network, MCP, browser, or Computer Use
authority. The user reviews the manifest permissions before installation, the
installed record retains only the granted subset, and an enabled plugin enters
the runtime only when every required permission is still granted.

Plugin tools and hooks become normal `AgentTool` implementations. Their calls
therefore pass through `ToolRegistry`, `PermissionManager`, and `ToolExecutor`
immediately before execution. The runner launches one exact executable from
inside the validated installed package, never a shell command assembled from
model text. It uses a minimal environment, bounded JSON standard input,
bounded/redacted output, an explicit timeout, the Task workspace as its working
directory, and records external effects as non-undoable.

## Skills

`SkillService` discovers `SKILL.md` packages from five sources:

- global Skills under Application Support;
- `.lumachat/skills` in the selected project;
- repository `.agents/skills` and `skills` directories;
- bounded nested directories in the selected workspace;
- enabled plugin paths explicitly declared by a validated manifest.

Discovery is bounded by file count, depth, number of Skills, file size, and
instruction characters. Symlink packages are skipped. A descriptor contains
metadata and resource availability, not its instruction body. Identical
invocation names resolve by `nested → project → repository → plugin → global`
precedence while every source remains visible in the UI.

The host resolves explicit `$skill-name` invocations first and can otherwise
select a small number from description/usage overlap. Only then is the selected
`SKILL.md` read. Its instructions are inserted as transient provider system
messages for that run and are not appended to the durable conversation or base
system prompt. The Session persists only bounded `LoadedSkillReference`
metadata for UI and recovery truthfulness.

`references/`, `scripts/`, `templates/`, and `assets/` are detected, but their
presence grants no authority. The read-only `skill_read_resource` tool is
published only when the host supplies an exact loaded-Skill ID. It accepts a
bounded UTF-8 regular file below that Skill root, rejects absolute/traversal/
symlink escapes, and does not execute scripts.

## Plugin packages and lifecycle

`PluginManifest` supports identity, version/author/description, minimum Luma
Chat version, permissions, Skills, MCP servers, tools, commands, hooks, and
assets. Missing optional arrays decode as empty for forward/backward
compatibility. IDs, names, counts, timeouts, duplicate permissions/tool names,
declared paths, package entries, aggregate package bytes, and the running app's
minimum compatible version are validated before a candidate can be installed.

`PluginManager` keeps source resolution separate from runtime activation:

- Local Directory inspects an existing package.
- Git accepts HTTPS or SSH repositories, uses non-interactive shallow clone,
  optionally checks out one bounded revision, and removes `.git` from staging.
- Manifest URL downloads a bounded HTTPS manifest.
- Registry downloads a bounded HTTPS index and resolves the selected entry to
  another supported source while rejecting self-recursion and ID mismatch.

Install/update copies to project `tmp`, validates again, then swaps one direct
child of the Application Support plugin directory. The previous package is
held as a rollback copy until the installed record is durably committed with
`AtomicFileWriter`. Disable/enable and failure state use the same atomic record;
uninstall first moves the exact package to a project-`tmp` quarantine and can
restore it if persistence fails.

The Extensions settings surface distinguishes Installed, Available/Install,
Updates, and Permissions. Candidate inspection precedes confirmation so source,
version, and requested permissions are visible before mutation. Runtime tool,
Skill, hook, and plugin-owned MCP registration is refreshed after install,
update, enable, disable, or uninstall without replacing built-in tools.

## Lifecycle hooks

The manifest event vocabulary is closed and typed:

`SessionStart`, `SessionEnd`, `PreModel`, `PostModel`, `PreTool`, `PostTool`,
`PermissionRequest`, `PermissionDecision`, `PreCommit`, `PostCommit`,
`SubagentStart`, `SubagentEnd`, `TaskStart`, `TaskPause`, `TaskResume`,
`TaskComplete`, `HandoffStart`, and `HandoffComplete`.

Hook tools are registered under collision-resistant host names, but
`isAvailable` returns false for ordinary model context. A call is exposed only
to a host-created `LifecycleHookInvocation` matching the plugin ID, declaration
index, event, and Task ID. This prevents a provider from fabricating a hook
call even if it remembers a previous tool name.

Each hook declares permission, network need, a 1–60 second timeout, and one of
three failure policies:

- `continue`: record the failure and keep the Task running;
- `fail_task`: record the failure and fail the current Task boundary;
- `disable_plugin`: record the failure, disable that plugin durably, and let the
  current Task continue without granting that plugin any further calls.

Hook input contains only bounded event/Task/detail metadata. Output is bounded
and secret-redacted before it enters the durable history in project `tmp`.
History keeps at most 1,000 records and 4 MiB. The install-time permission
grant authorizes the exact host-only hook binding; network remains closed unless
both the manifest grant and the Task-level network policy allow it.

## OAuth connectors

`OAuthConnectorStore` persists only non-secret connector configuration:
connector UUID/name/kind, HTTPS authorization and token endpoints, public
client ID, scopes, redirect URI, enabled state, connection time, and a bounded
account label. GitHub, Slack, Gmail, Google Drive, Jira, Linear, Notion, and a
custom kind share this abstraction.

Authorization uses a random state plus PKCE S256 verifier/challenge. Code
exchange is a bounded form-encoded HTTPS POST. Access token, refresh token,
expiry, and token type are encoded only inside the connector's Keychain item;
they never enter settings JSON, Session JSON, logs, provider context, or tool
arguments. A credential is returned only to a bounded connector tool after its
normal ToolExecutor network authorization. Disconnect removes the Keychain
item while retaining configuration; delete removes both.

## MCP coexistence and ownership

MCP remains an independent transport/runtime. Declarative plugin MCP entries
are materialized as ordinary `MCPServerConfiguration` values with
`ownerPluginID`. A deterministic owner identity lets refresh remove or replace
only servers owned by the affected plugin. Manual MCP servers retain
`ownerPluginID == nil` and are never removed during plugin disable/uninstall.
Existing settings without the field decode as manual servers. MCP header and
environment secrets continue to use the existing MCP Keychain store.

## Persistence and disposable data

| Data | Location | Secret-bearing |
| --- | --- | --- |
| Installed plugin records | Application Support `Extensions/plugins.json` | No |
| Installed plugin packages | Application Support `Extensions/Plugins/` | Package-defined files |
| Global Skills | Application Support `Extensions/Skills/` | No implicit secret handling |
| OAuth connector configuration | Application Support `Extensions/oauth-connectors.json` | No |
| OAuth credentials | macOS Keychain | Yes |
| MCP credentials | existing MCP Keychain namespace | Yes |
| Clone/install/quarantine scratch | project `tmp/extensions/` | Disposable |
| Hook output history | project `tmp/hook-logs/` | Redacted and disposable |

Corrupt optional extension state does not replace or disable built-in tools.
Package swaps and settings files are atomic; startup revalidates records,
manifest shape, direct-child install location, and package existence before an
installed plugin is accepted.

## Focused test coverage

The Phase D test sources cover discovery and source precedence, explicit and
automatic Skill selection, transient replay on every model turn, loaded-ID
resource authorization, traversal and symlink rejection, plugin manifest/
package permission, version and path validation, install/update/disable/reload/
uninstall recovery, host-only hook visibility including terminal step-limit
delivery, permission denial, non-zero failure policy, output redaction/history,
OAuth PKCE and token/JSON separation, insecure endpoint rejection, and plugin-
owned versus manual MCP persistence.

These tests are written but deliberately not reported as passing until the
requested final combined validation gate executes lint/static checks, the full
Swift suite, production build, package verification, and final diff review.

## Known limitations

- There is no Luma Chat-hosted marketplace; registry is a user-selected index.
- Remote manifest sources can install manifest-only plugins. Packages with
  executable/resources should use Local Directory or Git until a signed archive
  source is implemented.
- OAuth refresh/rotation, device-code flow, confidential-client secrets, and
  provider-specific connector tools remain future connector work.
- Plugin executables are permissioned native processes inside a macOS Seatbelt
  sandbox, not portable WASM modules. They receive no silent shell authority;
  workspace read/write and network rules follow the reviewed grant. Approved
  third-party process effects outside the workspace still cannot be represented
  by native Diff/Undo.
- Marketplace signature/transparency verification and automatic compatibility
  resolution remain release-hardening work.
