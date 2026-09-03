# ALLM runnable examples (provider-neutral)

Self-asserting smoke tests that exercise the public ALLM API against a real
LLM provider — OpenAI by default, Anthropic via `ALLM_PROVIDER=anthropic`,
or Gemini via `ALLM_PROVIDER=gemini`. Each script ends with
`unless <assertion>, do: System.halt(1)`, so a script that prints `OK: …`
and exits `0` is the green signal; any non-zero exit is a real failure.

These scripts ship under `examples/` and are **not** part of the published
`hex` package (see `mix.exs :files`).

The scripts are organized as a learning path: start with the quickest
round-trip, then branch into streaming/tools, multi-turn chat, sessions,
vision, and per-tool manual control. Each script is independently
runnable; the order below is for reading, not for execution dependencies.

## How provider switching works

`examples/_helpers.exs` defines a tiny `ExamplesHelpers` module with a
provider table:

```elixir
@providers %{
  "openai" => %{
    adapter: ALLM.Providers.OpenAI,
    default_model: "gpt-5.4-nano",
    vision_default_model: "gpt-4o-mini",
    key_env: "OPENAI_API_KEY",
    image_adapter: ALLM.Providers.OpenAI.Images,
    image_default_model: "dall-e-2",
    embed_adapter: ALLM.Providers.OpenAI.Embeddings,
    embedding_default_model: "text-embedding-3-small",
    moderation_adapter: ALLM.Providers.OpenAI.Moderation,
    moderation_default_model: "omni-moderation-latest"
  },
  "anthropic" => %{
    adapter: ALLM.Providers.Anthropic,
    default_model: "claude-sonnet-4-6",
    vision_default_model: "claude-haiku-4-5-20251001",
    key_env: "ANTHROPIC_API_KEY",
    image_adapter: nil,
    image_default_model: nil,
    embed_adapter: ALLM.Providers.Voyage.Embeddings,
    embedding_default_model: "voyage-3.5-lite",
    embedding_key_env: "VOYAGE_API_KEY",
    moderation_adapter: nil,
    moderation_default_model: nil
  },
  "gemini" => %{
    adapter: ALLM.Providers.Gemini,
    default_model: "gemini-3-flash-preview",
    vision_default_model: "gemini-3-flash-preview",
    key_env: "GEMINI_API_KEY",
    image_adapter: ALLM.Providers.Gemini.Images,
    image_default_model: "gemini-3.1-flash-image-preview",
    default_temperature: 1.0,
    embed_adapter: ALLM.Providers.Gemini.Embeddings,
    embedding_default_model: "gemini-embedding-001",
    moderation_adapter: nil,
    moderation_default_model: nil
  }
}
```

The map shape lets future fields (`:image_adapter`, `:embed_adapter`,
`:moderation_adapter`, `:vision_default_model`, …) be added without churning
the destructure
pattern in the helper.

`ExamplesHelpers.embedding_engine/1` is the third constructor, sister to
`engine/1` and `image_engine/1`. It reads `:embed_adapter` /
`:embedding_default_model`, and `:embedding_key_env` — which falls back
to the row's chat `:key_env` when the row omits it. `ALLM_EMBEDDING_MODEL`
overrides the model independently of `ALLM_MODEL`.

Every script's first lines are:

```elixir
Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine()  # or ExamplesHelpers.engine(tools: [...])
```

The helper reads `ALLM_PROVIDER` (default `"openai"`), looks up the adapter
+ default model + key env var name, validates that the corresponding
`*_API_KEY` env var is set, and returns a configured `%ALLM.Engine{}`. The
helper bakes in `params: %{temperature: 0}` for determinism on OpenAI /
Anthropic (Gemini opts into `1.0` per Google's recommendation via the
row's `:default_temperature` field) and merges any per-script
`extra_opts` (`tools:`, `tool_executor:`, etc.) on top.

Adding a new provider is a single new row in the `@providers` table —
existing scripts pick it up unchanged.

## Prerequisites

The example scripts use the [`:env_loader`](https://hexdocs.pm/env_loader/EnvLoader.html)
Hex package as a `dev`-only dependency to load API keys from a project-root
`.env` file (gitignored). The helper auto-loads `.env` centrally — individual
scripts no longer carry their own `EnvLoader.load(...)` preamble.

So either:

1. Drop a `.env` file at the repository root with whichever keys you want
   to exercise (`OPENAI_API_KEY=sk-...`, `ANTHROPIC_API_KEY=sk-ant-...`,
   `GEMINI_API_KEY=...`, `VOYAGE_API_KEY=pa-...`) and run
   `mix run examples/run_all.exs` (with `ALLM_PROVIDER=…` to pick a
   non-default provider) — no further setup.
2. Or export the vars directly:
   `export OPENAI_API_KEY=sk-... && mix run examples/run_all.exs`.

### Which keys each provider arm needs

| `ALLM_PROVIDER` | Chat / vision / image scripts | Embedding scripts (16–18) | Moderation scripts (19–20) |
|---|---|---|---|
| `openai` | `OPENAI_API_KEY` | `OPENAI_API_KEY` | `OPENAI_API_KEY` |
| `gemini` | `GEMINI_API_KEY` | `GEMINI_API_KEY` | *skipped* |
| `anthropic` | `ANTHROPIC_API_KEY` | **`VOYAGE_API_KEY`** | *skipped* |

#### Embedding scripts and `VOYAGE_API_KEY`

The Anthropic arm is the one place where a second key is required.
Anthropic ships no embeddings endpoint and never has; it names Voyage AI
as its recommended embeddings partner, so the `"anthropic"` provider row
points `:embed_adapter` at `ALLM.Providers.Voyage.Embeddings` and
overrides `:embedding_key_env` to `"VOYAGE_API_KEY"`. There is no
`ALLM.Providers.Anthropic.Embeddings` module to point at instead — that
name would assert a wire that does not exist.

Because scripts 16–18 carry no `# Provider:` marker, they are **not**
skipped on the Anthropic arm, and `ensure_key_present!/1` halts on a
missing key. So `ALLM_PROVIDER=anthropic mix run examples/run_all.exs`
requires **both** `ANTHROPIC_API_KEY` and `VOYAGE_API_KEY`. Voyage's free
tier covers the examples budget.

#### Moderation scripts and the `# Provider: openai` marker

Scripts 19–20 are the mirror image of 16–18. Moderation is a
single-provider capability — Anthropic ships no moderation endpoint, and
Gemini's safety ratings ride `generateContent` rather than a standalone
call — so the `"anthropic"` and `"gemini"` rows carry
`moderation_adapter: nil` and `ExamplesHelpers.moderation_engine/1` raises
`ArgumentError` for them.

Because 19–20 **do** carry a `# Provider: openai` marker, `run_all.exs`
SKIPS them on those arms rather than reaching that raise, so no extra key
is needed anywhere. Both scripts cost **$0.00** — `/v1/moderations` is
free — which is why the OpenAI arm's cost estimate is unchanged.

The `:env_loader` dep is declared `only: [:dev]` in `mix.exs`, so it does
NOT ship in the published Hex package (the `examples/` directory itself is
also excluded from the package per `mix.exs :files`).

## Quick start

The fastest path to a green light: run `01_plain_text.exs`. It exercises
`ALLM.generate/3` end-to-end against the active provider with a one-line
prompt and a one-line assertion.

```bash
OPENAI_API_KEY=sk-... mix run examples/01_plain_text.exs
```

Other providers:

```bash
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/01_plain_text.exs
GEMINI_API_KEY=...           ALLM_PROVIDER=gemini    mix run examples/01_plain_text.exs
```

Once `01_plain_text.exs` is green, the rest of the suite is incremental
on top of the same engine + provider switch.

## Streaming and tools (02–04)

These three scripts cover the streaming primitive and tool calling — the
two features that account for most production traffic.

- `02_streaming_text.exs` walks `ALLM.stream_generate/3` end-to-end.
  Demonstrates SSE chunk consumption and `Stream.run/1` cleanup.
- `03_single_tool_call.exs` runs a single `ALLM.chat/3` round with one
  tool, asserting the auto-loop terminates with the assistant text after
  one tool round-trip.
- `04_parallel_tool_calls.exs` issues two tools within a single chat
  loop — useful when the model decides to call multiple tools in
  parallel.

## Multi-turn chat (05–07)

- `05_multi_turn_chat.exs` accumulates a thread across two `chat/3`
  calls, demonstrating how the caller stitches together a conversation
  without using `Session`.
- `06_structured_output.exs` exercises
  `response_format: ALLM.json_schema(...)` with native enforcement on
  OpenAI/Gemini and the tool-forcing pattern on Anthropic (described
  below).
- `07_manual_tool_round_trip.exs` shows the engine-wide
  `mode: :manual` halt path — the chat loop returns the assistant's
  tool calls without invoking them, the caller fabricates a tool result,
  and a second call closes the loop.

## Sessions (08–09, 15)

Sessions wrap the chat loop with persistent state and a richer status
union (`:idle`, `:halted_for_tools`, `:halted_for_user`).

- `08_session_round_trip.exs` builds a `Session`, drives one turn, and
  asserts the session value survives a `:erlang.term_to_binary/1` /
  `binary_to_term/1` round-trip.
- `09_ask_user.exs` exercises `{:ask_user, _, _}` halt — a tool returns
  an "ask the user" tuple, the session halts with
  `status: :halted_for_user`, and a follow-up `Session.reply/4` resumes
  the loop.
- `15_per_tool_manual_session.exs` (also listed under per-tool manual
  mode below) drives the partition entirely through `Session.start/3`,
  `Session.submit_tool_result/3`, and `Session.continue/3`.

## Vision and images (10–13)

- `10_generate_image.exs` — `ALLM.generate_image/3` against the active
  provider's image adapter.
- `11_edit_image.exs` — `ALLM.edit_image/4` with a base image + mask
  (inpainting).
- `12_vision_input.exs` — `ALLM.generate/3` with a multimodal user
  message (`[%TextPart{}, %ImagePart{}]` content).
- `13_image_variations.exs` — `ALLM.image_variations/3` against
  `dall-e-2` 256×256 (OpenAI-only).

Per-script details on each are in the dedicated sections further down.

## Per-tool manual mode (14–15)

`14_per_tool_manual.exs` and `15_per_tool_manual_session.exs` exercise
the per-tool manual partition. One tool (`get_weather`) is auto;
another (`confirm_action`) carries `manual: true`. Under
`mode: :auto`, the chat orchestrator runs the auto bucket eagerly and
halts with `halted_reason: :manual_tool_calls`, surfacing the manual
subset in `metadata.manual_tool_calls` (script 14) or
`Session.pending_tool_calls` (script 15). Both scripts assert the
two-turn flow: halt-on-manual, caller appends/submits the manual tool
result, second call/continue completes with `"sunny"` in the assistant
text.

## Embeddings (16–18)

- `16_embed_single.exs` — one input through `ALLM.embed/3`.
- `17_embed_batch_chunked.exs` — 250 inputs in one call, chunked
  transparently by the façade.
- `18_embed_query_vs_document.exs` — `task_type: :search_query` vs
  `:search_document`, ranked by cosine similarity.

All three carry **no** `# Provider:` marker, so `run_all.exs` runs them
on every arm. See "Embedding scripts and `VOYAGE_API_KEY`" above for the
one extra key that implies.

## Moderation (19–20)

- `19_moderate_text.exs` — an all-strings `:input` through
  `ALLM.moderate/3`. One result per string, in input order.
- `20_moderate_image.exs` — a multimodal `:input` (one string plus one
  `%ALLM.ImagePart{}`, the checked-in kestrel PNG inlined as a `data:`
  URI). Any image present makes the whole list **one** item judged as a
  whole, so two elements in yields exactly one result out. The script
  derives that count with `ALLM.ModerationRequest.multimodal?/1` *before*
  the call and asserts it against what actually came back.

Both carry `# Provider: openai` — the mirror image of 16–18's deliberate
absence of a marker. See "Moderation scripts and the `# Provider: openai`
marker" above.

Neither script costs anything: `/v1/moderations` is free.

## Running

Single script (default — OpenAI):

```bash
OPENAI_API_KEY=sk-... mix run examples/01_plain_text.exs
```

Single script against another provider:

```bash
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/01_plain_text.exs
GEMINI_API_KEY=...           ALLM_PROVIDER=gemini    mix run examples/01_plain_text.exs
```

Full suite — run once per provider you want to validate:

```bash
OPENAI_API_KEY=sk-...        ALLM_PROVIDER=openai    mix run examples/run_all.exs
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs
GEMINI_API_KEY=...           ALLM_PROVIDER=gemini    mix run examples/run_all.exs
```

`run_all.exs` exits `0` iff every script printed `OK:` and exited `0`. The
most-recent captured stdouts are committed as `RUN_OUTPUT_OPENAI.md`,
`RUN_OUTPUT_ANTHROPIC.md`, and `RUN_OUTPUT_GEMINI.md` next to this README.

## Scripts

Scripts use a `# Provider: <names>` header marker to declare which provider
arms they support; the **Providers** column reflects that marker (absent
marker → all providers). The **Layer** column maps each script to the
public API surface it exercises — Layer C is the stateless execution
facade (`generate/3`, `stream/3`, `chat/3`, `step/3`, `generate_image/3`,
…); Layer D is the stateful continuation surface (`Session.*`).

| Script | Strategy | Layer | Providers | What it covers |
|--------|----------|-------|-----------|----------------|
| `01_plain_text.exs` | tight | C | all | `ALLM.generate/3` non-streaming round-trip |
| `02_streaming_text.exs` | tight | C | all | `ALLM.stream_generate/3` SSE consumption |
| `03_single_tool_call.exs` | tight | C | all | `ALLM.chat/3` with one tool, two turns |
| `04_parallel_tool_calls.exs` | tight | C | all | two tools called within one chat loop |
| `05_multi_turn_chat.exs` | loose | C | all | thread accumulation across two `chat/3` calls |
| `06_structured_output.exs` | tight | C | all | `response_format: ALLM.json_schema(...)` |
| `07_manual_tool_round_trip.exs` | tight | C | all | `mode: :manual` halt + caller-supplied tool result |
| `08_session_round_trip.exs` | tight | D | all | `Session` survives `:erlang.term_to_binary/1` round-trip |
| `09_ask_user.exs` | loose | D | all | `{:ask_user, _, _}` halt and follow-up turn |
| `10_generate_image.exs` | tight | C | openai, gemini | `ALLM.generate_image/3` |
| `11_edit_image.exs` | tight | C | openai, gemini | `ALLM.edit_image/4` with mask (inpaint) |
| `12_vision_input.exs` | loose | C | all | `ALLM.generate/3` with `[%TextPart{}, %ImagePart{}]` content |
| `13_image_variations.exs` | tight | C | openai | `ALLM.image_variations/3` against `dall-e-2` 256×256 |
| `14_per_tool_manual.exs` | tight | C | openai, anthropic | per-tool manual mode via `chat/3`: auto tool runs eagerly, manual tool halts with `:manual_tool_calls`, caller appends `:tool` message and re-issues |
| `15_per_tool_manual_session.exs` | tight | D | openai, anthropic | per-tool manual mode via `Session.start → submit_tool_result → continue` |
| `16_embed_single.exs` | tight | C | all | `ALLM.embed/3` with one input; asserts vector shape and `dimensions/1` agreement |
| `17_embed_batch_chunked.exs` | tight | C | all | 250 inputs through transparent chunking; asserts `chunk_count` against the adapter's `max_batch_size/0` |
| `18_embed_query_vs_document.exs` | loose | C | all | asymmetric embedding — `task_type: :search_query` vs `:search_document`, ranked by cosine similarity |
| `19_moderate_text.exs` | tight | C | openai | `ALLM.moderate/3` over an all-strings input; asserts batch cardinality, index order, and that a plain threat is flagged while a benign string is not |
| `20_moderate_image.exs` | tight | C | openai | multimodal `ALLM.moderate/3` — `ModerationRequest.multimodal?/1` derives the result count before the call, and the script asserts it against the count that came back (two elements in, one result out) |

## Image generation

`10_generate_image.exs` is a tight smoke test for `ALLM.generate_image/3`
against the active provider's image adapter. The script:

1. Builds an image-adapter engine via `ExamplesHelpers.image_engine/0`
   (sister to `ExamplesHelpers.engine/0` — looks up `:image_adapter` /
   `:image_default_model` from the provider table).
2. Calls `ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256")`
   (size honoured by OpenAI; Gemini ignores it).
3. Materializes `response.images |> hd() |> ALLM.Image.to_binary/1`.
4. Writes the bytes to `System.tmp_dir!() <> "/10_generate_image_<ts>.png"`.
5. Asserts the on-disk bytes start with the PNG magic number
   `<<137, 80, 78, 71>>`.

The script's `# Provider: openai, gemini` header tells `run_all.exs` to
skip it on Anthropic, which has no image adapter. Skipped scripts print
`[SKIP] 10_generate_image.exs (provider gate)` and do not count toward
`failed`.

## Image editing (inpaint)

`11_edit_image.exs` exercises `ALLM.edit_image/4` with a base image + mask
(inpainting). The script synthesizes a tiny 1×1 PNG for both the base and
mask, calls `ALLM.edit_image(engine, base, prompt, mask: mask, size: "1024x1024")`,
materializes the resulting image to bytes, and asserts the PNG magic
number on the on-disk bytes. Provider gating: `# Provider: openai, gemini`.

## Image variations

`13_image_variations.exs` exercises `ALLM.image_variations/3` against
`dall-e-2` 256×256 (the only OpenAI image model that supports the
variation operation). Same shape as `10_generate_image.exs`: tiny
synthesized base PNG, byte-prefix assertion. **OpenAI-only**
(`# Provider: openai`).

## Vision input

`12_vision_input.exs` exercises `ALLM.generate/3` with a multimodal user
message (`[%ALLM.TextPart{}, %ALLM.ImagePart{}]` content). The script
uses `ExamplesHelpers.engine(vision: true)` to route to the row's
`:vision_default_model` (`gpt-4o-mini` on OpenAI;
`claude-haiku-4-5-20251001` on Anthropic; `gemini-3-flash-preview` on
Gemini), sends a 1×1 transparent PNG with a "describe this image"
prompt, and asserts a non-empty `output_text` and
`finish_reason: :stop`. **Runs on all three providers**
(`# Provider: openai, anthropic, gemini`).

## Embedding scripts in detail

Scripts 16–18 exercise `ALLM.embed/3` against the active provider's
`:embed_adapter`, built by `ExamplesHelpers.embedding_engine/0`. None
carries a `# Provider:` marker, because every arm has an embedding
adapter — see "Embedding scripts and `VOYAGE_API_KEY`" above for what
that means on Anthropic.

- **`16_embed_single.exs`** — one input in, one `%ALLM.Embedding{}` out.
  Asserts cardinality, an all-float non-empty vector, `index: 0`,
  agreement between `ALLM.EmbeddingResponse.dimensions/1` and the vector
  length, and `chunk_count == 1`. Token counts are printed, never
  asserted: Gemini returns no usage metadata at all, so `total_tokens` is
  `nil` there by design.
- **`17_embed_batch_chunked.exs`** — 250 inputs in a single call. The
  count is chosen to exceed Gemini's per-request cap of 100 (that arm
  becomes three sequential requests, merged behind the façade) while
  staying inside OpenAI's 2048 and Voyage's 1000, so the same script
  covers both the multi-chunk path and the single-chunk fast path
  depending on the arm. `chunk_count` is asserted against arithmetic
  derived from the adapter's own `max_batch_size/0`, so the script stays
  correct if a provider's cap changes.
- **`18_embed_query_vs_document.exs`** — embeds two documents with
  `task_type: :search_document` and a query with `:search_query`, then
  ranks the documents by cosine similarity and asserts the on-topic one
  wins. Marked **loose**: the assertion is a ranking, never a threshold,
  since absolute similarity values are not comparable across providers.
  On OpenAI the task type is dropped (no equivalent exists on that wire,
  logged at `:debug`), so the script measures symmetric embeddings there
  — a dropped task type is never an error.

## Cost notes

Approximate per-clean-run costs for the full `run_all.exs` pass on each
provider arm. Pricing changes frequently — verify against the current
provider pricing page for any tight budget.

| Provider arm | Approx cost | Notes |
|--------------|-------------|-------|
| OpenAI (`gpt-5.4-nano` + `dall-e-2` + `gpt-image-1` + `text-embedding-3-small` + `omni-moderation-latest`) | **~$0.13 USD** | bulk of the cost is `11_edit_image.exs` (~$0.04); the moderation scripts are free |
| Anthropic (`claude-sonnet-4-6` + `voyage-3.5-lite`) | **~$0.08 USD** | drops to ~$0.01 with `ALLM_MODEL=claude-haiku-4-5` |
| Gemini (`gemini-3-flash-preview` + image preview + `gemini-embedding-001`) | **~$0.03 USD** | image scripts on Gemini skip variations |
| **All three combined** | **~$0.24 USD** | per clean dual+gemini pass |

The embedding scripts add well under $0.001 per arm — a few thousand
tokens total, and Voyage's free tier covers its share outright.

A full suite typically runs in 60–120 s per provider; the per-script
budget is 180 s, enforced by `run_all.exs`'s `Task.yield/2`.

## SaaS bring-your-own-key (BYOK)

The engine itself never carries an API key — engines round-trip through
`:erlang.term_to_binary/1` and JSON, so keys must not be persisted on
them. For multi-tenant SaaS, pass the tenant's key per-call:

    engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.4-nano")
    {:ok, response} = ALLM.generate(engine, request, api_key: tenant.openai_key)

The per-call `:api_key` opt has the highest precedence in `ALLM.Keys`'s
five-level resolution chain — it overrides any env var, app config, or
runtime store. The engine remains safe to cache, share across tenants,
and persist.

Avoid `ALLM.Keys.put/2` for BYOK — it stores the key in a globally-named
Agent, so concurrent requests from different tenants would race.

## Models

- **OpenAI default:** `gpt-5.4-nano` (a `gpt-5*`-family reasoning model
  that routes to OpenAI's Responses API; chosen for its low cost while
  still exercising the Responses-API code path).
- **Anthropic default:** `claude-sonnet-4-6` (the canonical Sonnet
  model).
- **Gemini default:** `gemini-3-flash-preview` (the cost-optimized
  flash-tier model on Google's Generative Language API).

`ALLM_MODEL` is the **chat** model, and scripts 16–18 do not read it.
The embedding scripts take their model from `ALLM_EMBEDDING_MODEL`, which
defaults per provider row to:

- **OpenAI:** `text-embedding-3-small`
- **Anthropic (via Voyage):** `voyage-3.5-lite`
- **Gemini:** `gemini-embedding-001`

Scripts 19–20 likewise ignore `ALLM_MODEL` and read
`ALLM_MODERATION_MODEL`, which defaults to `omni-moderation-latest` on
the only arm they run on. The `text-moderation-*` family was shut down on
2025-10-27 and answers a 400.

The variables are deliberately separate: a chat model id sent to an
embeddings or moderations endpoint is a guaranteed 400, so the documented
`ALLM_MODEL=…` invocations below would otherwise fail every embedding
script now that 16–18 run on every arm.

Override either at runtime independent of provider:

```bash
ALLM_MODEL=gpt-4.1-mini      mix run examples/run_all.exs
ALLM_MODEL=claude-haiku-4-5  ALLM_PROVIDER=anthropic mix run examples/run_all.exs
ALLM_MODEL=gemini-2.5-flash  ALLM_PROVIDER=gemini    mix run examples/run_all.exs

ALLM_EMBEDDING_MODEL=text-embedding-3-large mix run examples/17_embed_batch_chunked.exs
ALLM_MODERATION_MODEL=omni-moderation-2024-09-26 mix run examples/19_moderate_text.exs
```

`gpt-4.1-mini` is a non-reasoning model on the Chat Completions endpoint
and is a useful escape hatch when you want to bypass the Responses API
entirely. `claude-haiku-4-5` is roughly 5× cheaper than Sonnet for
reviewers concerned about Anthropic costs.

## Steering strategy

Scripts marked **tight** use three knobs to squeeze out model variance so
the assertion can be exact:

1. A hard system prompt that constrains the assistant to a narrow shape
   (e.g. `"Reply with exactly the word 'OK' and no other text."`).
2. Forced tool use via `tool_choice:` where applicable (`:auto` with a
   tool-forcing system prompt; `:required` for the parallel-tools
   script).
3. `params: %{temperature: 0}` baked into the helper for OpenAI and
   Anthropic; `1.0` for Gemini per Google's recommendation.

Scripts marked **loose** demonstrate natural model behaviour (multi-turn
chat, ask-user). Their assertions are shape-only — e.g. "the thread
grew", "the loop halted with `:completed`" — not exact-content matches.

Each script's header comment names its steering strategy and shows a
"natural alternative" line for users who want to swap the steering for a
free-form prompt once they understand the example.

## Tool-using scripts run natively on the Responses API (OpenAI)

Scripts 03, 04, 07, and 09 exercise tool calls. On OpenAI they run
through the Responses-API path that `gpt-5.4-nano` selects by default;
both `from_responses_response/2` and the streaming SSE handler surface
tool calls from the `output[]` array. On Anthropic these scripts route
through the Messages API with `tool_use` content blocks. On Gemini they
route through `generateContent` / `streamGenerateContent` with
`functionCall` parts.

## Structured output (script 06)

OpenAI's `:json_schema` response format uses native enforcement with
`strict: true`; the model's literal output bytes are returned in
`Response.output_text`.

Anthropic's structured-output path uses the **tool-forcing pattern**: a
synthetic `respond_with_json_<name>` tool is injected, `tool_choice`
forces it, and the tool-call's `input` map is lifted to
`Response.output_text` via `Jason.encode!/1` with
`finish_reason: :stop` and `metadata.structured_output_tool: true`. The
script asserts on the latter marker only when
`ALLM_PROVIDER == "anthropic"` since OpenAI carries no equivalent flag.

Gemini uses the wire-native `responseSchema` / `responseMimeType:
"application/json"` parameters on `generationConfig`.

The semantic content is identical across providers; the byte string may
differ (whitespace, key order, number formatting) — see the
`@moduledoc ALLM.Providers.Anthropic` paragraph "Structured output
`output_text` — semantic vs. byte equality".

## Failure modes

- **Missing `*_API_KEY`.** `ExamplesHelpers.engine/0` checks the env
  var name from the provider table BEFORE constructing the engine and
  exits with a clear error message naming the missing variable.
- **Unknown `ALLM_PROVIDER`.** `ExamplesHelpers.engine/0` raises
  `ArgumentError` listing the legal provider names.
- **Adapter module not loaded.** `Code.ensure_loaded?(adapter)` in the
  helper returns false; the helper exits with a clear message.
- **HTTP 5xx, `:rate_limited`, OR `529 Overloaded` (Anthropic).**
  `ALLM.Retry` retries up to 3 attempts with exponential backoff and
  jitter. After exhaustion the script halts. Re-run once.
- **Model unavailable.** If the configured model is decommissioned, the
  `:invalid_request` reason fires. Override via
  `ALLM_MODEL=<current-model> mix run …`.
- **Quota exceeded.** `:rate_limited` after retry exhaustion. Wait or
  use a different key.
- **Per-script timeout.** `run_all.exs` enforces a 180-second budget
  per script via `Task.yield(task, 180_000) || Task.shutdown(task,
  :brutal_kill)`. A timed-out script counts as `[FAIL]`.

## Contributing

Each example is its own test fixture. When adding a new script:

1. Number it in two-digit form (`16_<name>.exs`); `run_all.exs` picks
   them up by glob in numeric order.
2. Follow the common header-comment / engine / body / assertion-or-halt
   layout (see any of the existing scripts).
3. Use `engine = ExamplesHelpers.engine(extra_opts)` — never call
   `ALLM.Engine.new/1` directly so the script stays provider-neutral.
4. Run it standalone against every provider arm it claims to support
   (per its `# Provider:` marker), then run `run_all.exs` end-to-end
   against each, before opening a PR.
