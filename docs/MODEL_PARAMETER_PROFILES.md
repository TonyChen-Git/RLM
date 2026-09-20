# Per-model Parameter Profiles

Status: implemented; focused profile tests and the combined Phase C–H
development release gate passed on 2026-09-20.

## Identity and persistence

Custom profiles live in the existing `AppSettings` payload in `settings.json`.
No second preferences store is created. A `ModelParameterKey` contains the API
provider, concrete backend, normalized endpoint identity, and trimmed exact
model ID. Scheme/host casing is canonicalized, while case-sensitive endpoint
paths and model IDs are preserved. The endpoint is an extra namespace beyond the required
backend/provider + model identity, so two independently hosted servers cannot
overwrite one another by reusing a model name.

Only complete Custom overrides are persisted. No record means Auto. Therefore
Auto always evaluates the latest recommendation code, while a Custom profile
can never be replaced by a new Auto rule. Reset to Auto removes exactly one
matching key.

Older settings remain decodable: missing backend/profile keys fall back to
backend inference and an empty profile list; malformed profile arrays are
discarded without preventing launch.

## Recommendation and validation

`ModelParameterRecommendationEngine` owns the single resolution path:

1. exact model rule;
2. model-family rule;
3. concrete-backend rule;
4. generic safe values.

It returns values together with provider/backend/model capability flags and
separate backend/model context ceilings. `ModelParameterValidation` clamps
context, output, temperature, probability samplers and penalties, disables
unsupported booleans, and is run both when Custom data is saved and immediately
before a request is encoded.

The Qwen 3 8B family starts with the requested conservative 64K context, 16K
output, temperature 1.0, top-p 0.95, top-k 20, Thinking on, Medium reasoning,
and Preserve Thinking off for Agent. Unsupported backend fields remain visible
as unavailable in the quick UI and are omitted from JSON.

## Request ownership

- Classic Chat resolves and freezes an effective profile before context
  truncation and streaming request creation.
- Agent resolves one effective profile when a run starts. `AgentLoop` applies
  it to every provider turn, including retry, output continuation, resumed
  work, and all tool-call rounds.
- Provider adapters only encode fields allowed by the recomputed backend/model
  capability set. Ollama uses native `options` plus `think`; MLX/LM Studio use
  compatible sampling fields and a scoped `chat_template_kwargs` thinking
  switch; standard OpenAI-compatible and Anthropic requests omit unsupported
  extensions.
- Runtime-discovered Agent context/output ceilings further reduce the frozen
  profile before allocation. Effective context can never exceed either known
  ceiling.

## Shared UI

`ModelParameterEditor` is used by both main Chat/Agent popovers and Settings.
It reads and writes through the same `ChatViewModel.settings` profile list.
Changing any control immediately materializes and persists a full Custom
profile; Reset removes it and immediately recomputes Auto.

The compact main view exposes Auto/Custom, context, max output, Thinking,
Reasoning Effort, Reset to Auto, and expandable advanced sampling controls.
Settings uses the same editor in its expanded form and also exposes the
concrete backend selector for OpenAI-compatible connections.
