# Phase L–Q implementation and acceptance boundary

Version baseline: 1.4.5; integrated release: 1.4.6 build 13. This document
describes the current development tree.
Source changes are not release evidence. The integrated build, tests, packaged
native UI smoke and external acceptance must be recorded separately in the
full parity audit before any production claim.

## L — Active Task interaction

An accepted Steer atomically stores bounded, redacted text and a stable message
ID beside the Task before the in-memory mailbox reports success. The mailbox
and transcript preserve that ID. Session persistence reconciles only the same
message ID, role, name and digest, so repeated identical text cannot consume a
new receipt. A crash with no matching durable transcript leaves a per-record
recovery inspector. On the originating idle Task, the user may copy text into
the draft for manual review/send or dismiss one inspected receipt; copying does
not acknowledge delivery. The app never replays it automatically. Legacy
digest-only receipts remain uncertain because they cannot reconstruct content.
Queue entries can contain text, image references or both. A claimed entry is
never resent automatically after uncertain delivery. The composer can edit,
move and remove unclaimed entries, and it verifies image bounds and source
identity before submission. Side chat is ephemeral and can receive only the
user's selected bounded text/image snapshots. It has no Agent tool, write,
approval or parent Task authority.
Queue text is redacted at the persistence boundary, including atomic migration
of older queue files without clearing uncertain claims. Queue, Steer and worker
binding files use descriptor-relative I/O, reject symlink ancestors and special
files, and use nonblocking reads so a FIFO cannot hang recovery. Side chat keeps
the bounded in-memory image snapshots needed by its retained conversation;
follow-up turns cannot silently lose previously selected image context.
The main Session store uses the same bounded descriptor I/O and safely creates
each storage directory component. Corrupt or special Session files are skipped
during discovery and rejected on save; newer durable snapshots still reject
older saves. This also protects startup and crash recovery outside Queue.
Queue's editor owns a draft initialized from one Task-bound request, avoiding
empty text on first sheet presentation. It waits for durable save success
before dismissal; a failed or newly claimed edit keeps the text and shows the
error in the sheet. Side chat's file picker explicitly describes its transient
snapshot lifetime rather than the persistent Agent attachment path.
Each new save attempt clears the prior error, so a successful retry removes
both the editor's failure state and the surrounding Task error banner.

## M — Pull requests and event triggers

The provider-neutral PR service now has a GitLab merge-request adapter beside
GitHub. Credentials remain in Keychain. The headless App Server accepts a
GitHub webhook only with its existing bearer authorization and a configured
`LUMACHAT_GITHUB_WEBHOOK_SECRET`; it validates the original body with HMAC
SHA-256, projects allowlisted data, and sends an event into Automation's
durable producer-event and per-Automation idempotency path. Even an event that
matches no Automation is claimed before a later configuration change can make
its replay actionable. Producer identities live in a separate durable ledger
that normal run-history pruning cannot evict. Its 16,384-entry ceiling rejects
new events when full while retaining all previous identities. Schema version 3
prevents older apps from silently discarding this ledger. Startup migrates
retained legacy producer claims, per-Automation event claims and event runs
before schedule evaluation. A schema-3 snapshot with a missing or null ledger
is rejected. Event identities with both claims and runs already
evicted by an older version cannot be recovered: operators upgrading an
existing ingress must reconcile that history and rotate the webhook secret
before accepting previously exposed signatures. There is no automatic ledger
reset; a full ledger requires an explicit operator-managed ingress migration
and credential rotation. Operators also control the authenticated ingress.
Replay identity is derived from the authenticated body digest. GitHub delivery
and event headers are unsigned; a replacement delivery UUID cannot bypass
deduplication, and the event header must match the signed payload structure.
Mutation-capable event
actions require a dedicated worktree. The endpoint needs an operator-managed
authenticated HTTPS ingress or relay; no public listener or GitHub delivery
configuration is bundled. Slack and Gmail remain future provider candidates:
each needs a separate OAuth scope, webhook verification, revocation and
provider contract before enabling event tasks.

## N — Voice

The macOS composer starts microphone capture only after a user gesture and
microphone and Speech authorization. Apple's on-device Speech recognition is
required; unavailable languages fall back to text. Captured buffers stay in
memory, are not saved, and are stopped on navigation or user interruption.
Recognized text enters the currently selected Task through the existing
send/Queue/Steer controls. Speech synthesis plays the latest response and can
be interrupted. A third-party voice provider requires explicit configuration
and a new data-flow disclosure before it can be added.
Capture and speech synthesis each have a generation boundary. Late callbacks
from an interrupted capture or utterance cannot stop a newer one. Final
recognition closes capture while leaving text available for one submission;
playback stops capture to avoid feedback. Automatic playback accepts only a new
answer from the Task that submitted the voice text, and navigation revokes it.

## O — Self-managed remote worker

`Scripts/lumachat-worker` is an installable Python 3 Linux command worker. The
desktop calls one JSON protocol request per host-verified outbound SSH
connection. Protocol v1 exposes capability negotiation, start/status/cancel,
bounded logs and diff. Each job has a UUID, idempotency-bound request, a
separate detached Git worktree, durable private state and heartbeat. The Task
saves its job binding before the remote start call. Unknown SSH outcomes stay
uncertain until the user reconnects by Job ID; host identity or authority
changes fail closed. Network is denied only when the Linux host can enforce a
network namespace; otherwise the job refuses to start unless the user
explicitly allows network access. The local pane shows logs and a reviewable
patch and lets the user copy that patch. If the SSH Task retains an original
local Git workspace with the identical commit, the user may create a new
managed local worktree and Task, applying the reviewed patch through the
existing guarded Review patch path. This takeover is journaled for startup
recovery and rejects stale or redacted diff content.
Job preparation holds a per-ID filesystem lock. A failed preparation before
state commit can clean its incomplete worktree and retry the same ID; a
persisted job never changes its request digest, and uncertain post-commit
failure is marked interrupted for inspection instead of silently restarted.
The binding also captures the workspace UUID and a Task permission fingerprint
(mode, supplemental paths, permission mode, network policy and allowances).
Plan/Review/archived Tasks cannot start or reuse a worker job. Each request
revalidates Task authority and runner identity before and after SSH suspension;
legacy bindings without these fields require explicit operator reconciliation.
The supervisor reaps its child after cancellation or log overflow, escalates
when a child ignores termination, and durably reports spawn failures. Diff
includes commits made by the job relative to its captured starting commit.

Install the reviewed script on the user-controlled Linux host at the fixed
`/usr/local/bin/lumachat-worker` path with executable mode 0755 (for example,
`sudo install -m 0755 lumachat-worker /usr/local/bin/lumachat-worker`). The
fixed absolute path is required because SSH execution deliberately uses a
restricted `PATH`. Configure the existing SSH runner for the Git checkout and
verify its host receipt and credential before starting a Job.

This v1 worker runs a user-specified process. It is not a remote copy of the
macOS Agent runtime, hosted cloud, or automatic Task handoff. Takeover depends
on a locally available identical commit and textual patches; binary and
unavailable patches fail closed.
The Linux CI workflow tests the worker contract without SSH; an authorized
real Linux host is required for live acceptance.

## P — Extension trust and compatibility

A remote plugin registry entry must pin a SHA-256 of the canonical package
contents. Inspection records both the package digest and registry-index
digest. Installation rehashes source and copied package before the atomic
swap; a changed candidate is rejected while the prior installation remains.
The UI shows source, digest, version and permission additions/removals before
approval. The digest is integrity and audit evidence tied to the registry's
HTTPS origin, not a claim that the publisher is trustworthy. Plugin install
does not run declared tools or scripts automatically.

OAuth connectors keep refresh and access tokens in Keychain. Expiring tokens
refresh through the configured HTTPS token endpoint; invalid grants disconnect
and require reauthorization. A configured revocation endpoint supports
explicit remote revoke, while local disconnect always clears the Keychain
credential. Responses from an in-flight refresh or revoke are discarded if the
connection binding, connected timestamp or stored token changed while waiting.
Nonpositive or malformed expiry values are rejected rather than treated as
unlimited credentials. MCP connection generations reject late initialize or
expired-session responses after disconnect, including pending transports.
Namespaces remain reserved while interrupted connections and discovery
refreshes finish cleanup, preventing an old generation from unregistering a
replacement connection's tools.
MCP currently implements the `2025-06-18` initialize lifecycle;
other protocol revisions fail with a visible compatibility diagnostic and no
tool registration. Modern stateless MCP support remains pending.

## Q — Distribution and verification

`Scripts/release.sh` contains distinct ad-hoc development and production
Developer ID/notarization/stapling/update-feed paths. The production GitHub
workflow requires operator-owned signing, notarization and update secrets;
it cannot synthesize them. The new macOS development CI runs the Swift gate,
and Linux CI exercises the Python worker. This is a cross-platform worker
backend, not a non-macOS desktop port. Production signing, the published feed,
packaged native UI, external SSH/MCP/PR/Browser/Computer Use and 2h/8h/24h/
multi-day soak require real evidence; an unexecuted workflow is not acceptance.

The eight soak categories also exercise the Phase I–Q Swift regressions:
memory/imports in Agent, SSH/worker authority in PTY, webhook/PR in Automation,
plugin/OAuth/MCP lifecycle in reconnect, CDP WebSocket lifecycle in Browser,
and Queue/Steer/Side chat/voice/Session recovery in Task switching. Category filters match complete XCTest selectors;
the contract tests check that the required suites exist and are selected.
Failure scenarios keep their exact selector mapping. These are local
integration and fixture exercises; they do not establish external-provider
availability, microphone behavior, Linux-host isolation or production signing.
Streaming cancellation tests synchronize with an actual received line and
URLSession's stop callback, with bounded waits and cleanup on failure, rather
than assuming a number of scheduler yields implies readiness.

Soak state distinguishes preparation, running, interruption, failure and
completion. An OS file lock prevents overlapping orchestrators and survives in
owned child processes; a persisted PID never authorizes signalling. `--resume`
starts a new run with a link to the old evidence, preserving old logs without
reusing elapsed time or cycle counts. Measurement begins after test inventory
build, with heartbeats, continuous/wall-clock gap detection and source/contract/
toolchain fingerprints checked throughout. Only uninterrupted full-duration
completion with the required cycles can qualify. Interrupted or abandoned runs
remain non-qualifying, even if an old state file still reads `running`.
Wall and monotonic deltas are compared on every heartbeat: drift above five
seconds fails the run even when a short sleep stays below the 60-second
heartbeat-gap ceiling. Small wall-clock jitter is tolerated without adding to
measured elapsed time. The harness contracts include interrupted preparation,
source changes, child cleanup, bounded logs, short sleep and clock adjustment;
passing them does not substitute for a full-duration run. On October 14 the 28
soak harness tests were included in the passing 48-test Python contract run
(one Linux-only worker skip). The same development gate passed 886 Swift tests
(one environment skip), optimized arm64 packaging and the security audit.
Exact source/package receipts and remaining acceptance are tracked in the audit.

The Task-owned CDP WebSocket must outlive a single command and time spent
waiting for user approval. Its URLSession retains the default resource lifetime
instead of applying the 30-second command maximum to the persistent connection.
Individual commands retain their bounded deadlines. Both enqueue and send paths
reject an ended socket, while any unexpected receive cancellation closes the
connection and fails pending requests. Five real loopback tests cover lifecycle
failures and idle reuse; actual Chrome debug acceptance additionally exercised
an approval gap longer than 30 seconds and all five Browser operations. The
October 14 final package excludes diagnostic tracing and passes all five Browser
operations through real Chrome after an observed approval wait exceeding 68
seconds. The PNG and native annotation pane were visually verified; App and
owned browser cleanup completed. These deterministic local model/page fixtures
do not replace external live acceptance or a qualifying full-duration soak.

A background sequence launched on October 14 at 15:24 Asia/Taipei with the
frozen 340-file inputs: 2h, then 8h, 24h and 72h multi-day. The 2h profile
completed with qualification true: 7,207.592 continuous seconds, 48 complete
cycles and 389 completed shards, zero failures. The following 8h profile was
interrupted after 669.134 seconds and does not qualify; 24h and 72h never
started. The controller receipt is `tmp/phase-iq-oct14-soak-suite/state.json`.
These pre-1.4.6 receipts are preserved. Fresh version/input runs cannot reuse
old duration or cycles, and any failure or input/continuity violation stops
the sequence. Only completed, qualifying receipts establish acceptance.
