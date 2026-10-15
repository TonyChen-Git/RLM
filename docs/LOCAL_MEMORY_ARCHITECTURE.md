# Local memory architecture (Phase J development)

Local memory is a Project-scoped, private JSON document under Application
Support. The store uses directory descriptors, `O_NOFOLLOW`, size and link
checks, a same-directory temporary file, rename and directory sync. A corrupt
document stops reads and writes rather than being replaced. Project deletion
removes the memory document.

## Authority and suggestion lifecycle

- Global memory and automatic suggestions are separate switches, both off by
  default. Each Project starts disabled. Each Task's read and contribution
  switches also default off.
- After a Task is durably completed and idle, a background scan considers at
  most the last 64 messages and at most 16 proposals. It uses local rules for
  explicit user "remember", preference and workflow statements. It never
  sends a transcript to a model. Running, paused and interrupted Tasks do not
  qualify. Startup and new opt-ins rescan eligible completed Tasks.
- Candidate text is bounded to 1 KiB and must survive secret redaction
  unchanged. Its Task/message IDs, redacted Task title and redacted excerpt
  form review evidence. A suggestion is stored as `proposed`; it cannot be
  projected to a model until the user explicitly approves it.
- The proposal and processed message ID are committed atomically in the same
  Project document. Repeated scans and app restart are idempotent. Removal and
  clear retain processed IDs so the same source does not recreate an entry.
  Capacity limits fail closed; no pending suggestion is treated as approved.

## Retrieval and UI

The memory pane supports manual proposals, category selection, review,
approval, edit, deletion and Project clear. Search spans the user's Project
catalog, with category filtering and relevance or recent sorting. Search is a
local UI operation; it does not expand model read authority. The source Task
can be opened from an automatic proposal.

For a model run, global memory, Project memory and that Task's read switch must
all permit use. The store reads only the current Project's approved entries,
ranks them against the current request and caps the selection at 16 entries,
16 KiB and six entries per category. The final transient JSON projection is
redacted again and capped at 7 KiB. It does not become a durable Session
message. A Task's contribution switch governs suggestions and manual
proposals, separately from its read switch.

## Limits and pending acceptance

The extractor is intentionally narrow and does not infer implicit facts from
arbitrary conversation. It does not claim semantic retrieval. An isolated
profile packaged native UI smoke passed for opt-in, proposal search and
approval status refresh. Live model acceptance and longer crash/soak exercises
remain pending as recorded in the parity audit.
