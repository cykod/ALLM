# Phase 22: Content Moderation — Design Document

> **Goal:** Add a provider-neutral, non-streaming moderation primitive so an ALLM app can screen user-generated text and images before spending a chat call on them — or before publishing model output.
> **Outcome:** `ALLM.moderate(engine, "…user text…")` returns `{:ok, %ALLM.ModerationResponse{}}` against OpenAI's free `/v1/moderations` endpoint; `ModerationResponse.flagged?/1` answers the 95% question in one call, and `ModerationResult.category_scores` carries the provider's full per-category float map for callers who want their own threshold.
> **Spec sections:** new **§39** (Content moderation). Amends **§27** (module tree), **§29** (telemetry), **§35.7** (bundled-adapter rule — a second named beneficiary).
> **Layers touched:** A, B, C — one layer per sub-phase (22.1 = A, 22.2 = B, 22.3 = C, 22.4–22.5 = B, 22.6 = docs, 22.7 = `[CHORE]` sweep).

**Section-number collision check (verified 2026-08-31):** the highest section committed to the spec file today is **§36** (Text embeddings, `steering/allm_engine_session_streaming_spec_v0_2.md:2286`). §37 is reserved for Audio (`steering/PHASE_19_DESIGN.md`) and §38 for Bulk Batch I/O (`steering/BATCH_DESIGN.md:7`, which states the reservation explicitly: *"(§36 = Embeddings per Phase 20; §37 = Audio per Phase 19.)"*). This design takes **§39** and disturbs neither.

**Phase-number check (verified 2026-08-31):** `HISTORY.md:164-272` records Phase 20 as embeddings and `HISTORY.md:349` records Phase 21 as the Amesbury feedback rollup. **22** is free.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 22.1 | Layer A data: `ModerationRequest`, `ModerationResult`, `ModerationResponse`, `ModerationAdapterError`, validator, serializer registry, enum extensions | A | Completed |
| 22.2 | Layer B runtime: `ALLM.ModerationAdapter` behaviour, `Engine.moderation_adapter`, `FakeModeration`, conformance suite | B | Completed |
| 22.3 | Layer C façade: `ALLM.moderate/3`, `ALLM.moderation_request/2`, `:moderate` telemetry span, `Capability.preflight_moderation/2` | C | Completed |
| 22.4 | `ALLM.Providers.OpenAI.Moderation` — text input, recorder + wire probe + fixtures | B | Completed |
| 22.5 | Image input: `%ALLM.ImagePart{}` items, MIME/size gate, multimodal cardinality | B | Not Started |
| 22.6 | Spec §39, `guides/moderation.md`, examples 19–20, `mix.exs` wiring, `CHANGELOG` | — | Not Started |
| 22.7 | `[CHORE]` sweep: CLAUDE.md stale claim, `@guides` parity meta-test, images.ex redaction `[CARRY]` | — | Not Started |

**Overall Progress:** 4/7 sub-phases complete

---

## Assumptions

Each is cheap to revisit; three change the shape of the work materially and are flagged **★**.

1. **★ `text-moderation-*` is dead and is not in scope.** The request named `text-moderation-latest`. OpenAI's deprecations page lists it, `text-moderation-stable`, and `text-moderation-007` with **Shutdown Date `2025-10-27`** and **Recommended Replacement `omni-moderation`** ([developers.openai.com/api/docs/deprecations](https://developers.openai.com/api/docs/deprecations.md), fetched 2026-08-31 — the table row is quoted verbatim in Alternative A). That date is ten months in the past. Shipping a code path for a model the provider has switched off would be shipping a guaranteed 404 with a doctest asserting it works. The adapter targets `omni-moderation-latest` and `omni-moderation-2024-09-26` only. See **Alternative A**.
2. **★ Moderation is a single-provider family, and that is a stable property of the market, not a gap to be filled later.** Anthropic ships no moderation endpoint. Google exposes safety ratings *inline on `generateContent`* — `promptFeedback.safetyRatings` and `candidates[].safetyRatings`, four `HARM_CATEGORY_*` values scored on an ordinal `NEGLIGIBLE | LOW | MEDIUM | HIGH` enum ([ai.google.dev/gemini-api/docs/safety-settings](https://ai.google.dev/gemini-api/docs/safety-settings), fetched 2026-08-31) — which is a property of a *generation call*, not a standalone classification endpoint, and therefore cannot implement a `moderate/2` callback without inventing a generation call to attach itself to. This asymmetry drives the score-map decision (Decision #2) and the §35.7 amendment (Decision #3). See **Alternative B**.
3. **★ The library does not decide what "unsafe" means.** ALLM returns the provider's `flagged` boolean and the provider's per-category scores. It ships no default threshold, no policy DSL, and no `block?/2`. A moderation threshold is a product decision that varies by jurisdiction, audience, and appetite; a library default would be quietly wrong for most callers and would be read as an endorsement. `guides/moderation.md` shows the threshold loop against `ModerationResult.score/2`.
4. **Moderation is non-streaming.** Same reasoning as images (spec §35.1 item 2) and embeddings (§36). Request/response, no token stream. No `ALLM.ModerationStreamAdapter`, no `stream_moderate/3`.
5. **Model strings stay late-resolved (§6.3).** `llm_db` is still not a dependency (`mix.exs:38` comment), so `Capability.preflight_moderation/2` is inert in practice today — exactly as `preflight_embedding/2` is (`lib/allm/capability.ex:331-342`).
6. **No usage, no cost.** The endpoint is free — *"The moderation endpoint is free to use, and image files can be up to 20 MB"* ([developers.openai.com/api/docs/guides/moderation](https://developers.openai.com/api/docs/guides/moderation), fetched 2026-08-31) — and returns no `usage` object. `%ModerationResponse{}` therefore has **no `:usage` field**, diverging from `EmbeddingResponse` and `ImageResponse`. See Decision #6.
7. **v0.6.0 via `scripts/release.exs minor`.** New Layer A structs, a new behaviour, and a new `Engine` field are additive but wide. Per CLAUDE.md, `mix.exs @version` is never hand-edited.

---

## Alternatives Considered

### A. What to do about `text-moderation-latest`

The deprecations table, quoted verbatim from [developers.openai.com/api/docs/deprecations](https://developers.openai.com/api/docs/deprecations.md) (fetched 2026-08-31):

```
| Shutdown date | Model / system           | Recommended replacement |
| ------------- | ------------------------ | ----------------------- |
| 2025-10-27    | `text-moderation-007`    | `omni-moderation`       |
| 2025-10-27    | `text-moderation-stable` | `omni-moderation`       |
| 2025-10-27    | `text-moderation-latest` | `omni-moderation`       |
```

| Option | Trade-off |
|--------|-----------|
| **A1 — omni only (chosen)** | The only option that ships working code. `@default_model "omni-moderation-latest"`; the adapter sends no `model` field when `request.model` is `nil`, letting OpenAI pick its own current default rather than pinning a name ALLM would have to chase. |
| A2 — support both, decode the legacy 11-category shape | Ships a branch no live call can reach. The legacy response shape's only observable difference — 11 categories instead of 13, and no `category_applied_input_types` — is *already* absorbed by the string-keyed map of Decision #2, so there is nothing to branch on even if the model returned. Pure cost. |
| A3 — accept the model string, return `:unsupported_feature` pre-flight | Considered and rejected as paternalistic: OpenAI's own 404 is a clearer, more current error than a hard-coded denylist that goes stale the moment a new model ships. The adapter forwards whatever `model` the caller sets. |

**A1 is chosen and it contradicts the literal request.** Flagged here rather than silently absorbed.

### B. Provider-shaped vs normalized category map

| Option | Trade-off |
|--------|-----------|
| **B1 — provider-shaped, string-keyed (chosen)** | `categories: %{String.t() => boolean()}`, `category_scores: %{String.t() => float()}`, keys exactly as the wire spells them (`"self-harm/intent"`, `"illicit/violent"`). Lossless. Survives OpenAI adding a category without an ALLM release. No atom-table growth from provider-controlled strings. **Cost:** a caller reading `scores["violence"]` is writing OpenAI-specific code, and the compiler will not catch a typo. |
| B2 — normalized closed atom enum | Would require a cross-provider taxonomy. There is exactly one bundled provider, and the only plausible second (Gemini) reports a 4-member ordinal enum on a different call shape (Assumption 2) — mapping 13 slash-named floats onto `NEGLIGIBLE\|LOW\|MEDIUM\|HIGH` is lossy in both directions and would be *invented*, not derived. Per agent-spec/DESIGN.md rule 13, a closed enum with no second implementation to constrain it is speculative vocabulary. |
| B3 — provider-shaped map **plus** a normalized `flagged` boolean | **This is what B1 actually is.** `:flagged` is the one field whose meaning is genuinely cross-provider ("the provider says this trips its policy"), so it is promoted to a first-class typed field, and everything below it stays provider-shaped. |

**Why string keys and not atoms, specifically.** Three independent reasons, any one sufficient: (a) `"self-harm/intent"` is not a bare atom literal, so an atom-keyed map costs every caller `:"self-harm/intent"` quoting; (b) `String.to_atom/1` on a provider-controlled key set is exactly the untrusted-input atom growth CLAUDE.md's stdlib-ban rule scopes against, and `String.to_existing_atom/1` needs a safelist that silently drops any category OpenAI adds; (c) string keys make `__from_tagged__/1` a total identity on these two fields — no decode hook, no round-trip hazard.

### C. Result cardinality and the multimodal wart

OpenAI's own multimodal example, quoted verbatim from [developers.openai.com/api/docs/guides/moderation](https://developers.openai.com/api/docs/guides/moderation) (fetched 2026-08-31):

```json
{
  "model": "omni-moderation-latest",
  "input": [
    { "type": "text", "text": "...text to classify goes here..." },
    {
      "type": "image_url",
      "image_url": {
        "url": "https://example.com/image.png"
      }
    }
  ]
}
```

That request returns **one** `results` entry. A flat array of *strings*, by contrast, returns one entry per string. So the wire's `input` array is overloaded: an array of strings is a batch of N items; an array of content-part objects is a single multimodal item.

| Option | Trade-off |
|--------|-----------|
| **C1 — one `:input` list, cardinality derived from element types (chosen)** | `input: [String.t() \| ImagePart.t()]`. All-strings → N results, `index` 0..N-1. Any `%ImagePart{}` present → the whole list is ONE multimodal item → exactly one result at `index: 0`. `ModerationRequest.multimodal?/1` makes the cardinality derivable *before* the call, and `Validate.moderation_request/1` has nothing to reject. **Cost:** the wart is real and must be documented loudly, in the struct's `@moduledoc`, `@doc ALLM.moderate/3`, and the guide. |
| C2 — reject mixed input; images one-at-a-time | Loses the documented text+image combined call above, which is the endpoint's whole reason for accepting a mixed array. |
| C3 — a separate `ALLM.moderate_multimodal/3` | Two public functions over one endpoint, and the union type still has to exist on the struct. Rejected per "function arity matters" — a second name for the same call is a permanent API cost to hide a documentation problem. |
| C4 — nested list (`input: [["text", img], "other"]`) | Would express both cardinalities unambiguously in one field, and is the only option that could batch several *multimodal* items. Rejected: **the wire cannot express it** — there is no documented way to send two multimodal items in one call — so ALLM would be modelling a request it can never send. |

### D. Batch chunking

Chosen: **no chunker.** `ALLM.embed/3` chunks transparently via `ALLM.EmbeddingBatch` (`lib/allm/embedding_batch.ex`); `ALLM.moderate/3` deliberately does not, and the parity gap is documented.

Four reasons, in descending weight:

1. **Merging is not well-defined.** OpenAI returns exactly one `id` per HTTP call (`"id": "modr-970d409ef3bef3b70c73d8232df86e7d"`). Merging N chunks produces N ids with nowhere to put them. `EmbeddingResponse` had no per-response identity to lose; `ModerationResponse` does. A merged response would have to invent an id, drop N−1 of them, or grow an id list — all three worse than not merging.
2. **The cost pressure that justified chunking is absent.** Embeddings chunking exists because a pgvector ingest is thousands of items against a 100-item Gemini cap. Moderation is free and the dominant workload is one user message at a time.
3. **The cap is undocumented.** Neither the guide nor the API reference states a maximum `input` array length. Sizing a chunker against a guessed cap is precisely the failure CLAUDE.md warns about ("a cap too high 400s a call the guide promised and a cap too low silently doubles the user's request count forever"). The 22.4 wire probe determines the real number before any code depends on it.
4. **The escape hatch is already the pattern.** `max_batch_size/0` is public on the behaviour, the adapter raises `:batch_too_large` above it, and `guides/moderation.md` shows the caller-side `Enum.chunk_every/2` loop. This is `Alternative C3` from the embeddings design (`steering/2026-07-28_EMBEDDINGS_DESIGN.md:90`) — retained there as the escape hatch, promoted here to the default.

Revisit if usage shows callers writing the chunk loop routinely.

### E. Whether image input belongs in this phase

Chosen: **in scope, as a severable sub-phase (22.5).**

Deferring is cheaper *now* but expensive later: widening `input`'s element type from `[String.t()]` to `[String.t() | ImagePart.t()]` after release changes every adapter's and validator's accept set, and Decision C1's cardinality rule would arrive as a behaviour change to an already-documented function. The pieces it needs already exist and are reused rather than written: `%ALLM.ImagePart{}` (`lib/allm/image_part.ex`), and `ALLM.Providers.Support.ImageMime.validate/2` (`lib/allm/providers/support/image_mime.ex:94-116`), whose `@max_bytes 20 * 1024 * 1024` (`:58`) is **exactly** OpenAI's documented 20 MB moderation image limit.

**22.5 is severable in effort, not in contract — dropping it is a real edit, not a deletion.** 22.1 already ships `@type item :: String.t() | ALLM.ImagePart.t()` on a public Layer A struct, a validator arm accepting `%ImagePart{}`, `multimodal?/1`, and the normative cardinality invariant; 22.2 ships conformance case 10 asserting the multimodal arm. Shipping those without 22.5 would release a public type union with no adapter able to send it — the opposite of clean. A reviewer who wants moderation text-only must also prune the `ImagePart` arm from `item()`, the `%ImagePart{}` arm from the validator, `multimodal?/1`, the cardinality invariant's second half, and conformance case 10 (dropping `@case_count` to 9). That is a bounded, enumerated edit — which is the actual claim being made here — and 22.5 additionally modifies four files 22.1–22.4 ship (`lib/allm/providers/openai/moderation.ex`, `scripts/record_openai_moderation_fixtures.exs`, `test/allm/allm_moderate_test.exs`, and the wire-field map), all tagged in the Module Tree.

---

## Overview

Moderation is the smallest well-defined capability ALLM does not have. An app that accepts user text and forwards it to a chat model today has three choices: send it unscreened, hand-roll an HTTP client against `/v1/moderations`, or react to a `:content_filter` finish reason *after* paying for the generation. ALLM already models that third path as first-class data — `:content_filter` is a `Response.finish_reason` value (`lib/allm/response.ex:36`) and an `AdapterError` reason mapped from OpenAI's own signals (`lib/allm/providers/openai.ex:683-687`) — but that is reactive and post-hoc. This phase adds the proactive half.

It is a *strictly simpler* instance of the pattern Phases 13–17 (images) and 20 (embeddings) established: a Layer A request/response pair, a dedicated adapter behaviour with its own closed error enum, one `Engine` field, one façade function, one telemetry span, one `Fake*` adapter, one conformance suite. Against embeddings it drops batching, drops usage, drops cost population, and drops two of the three provider adapters. Against images it drops multipart, binary payloads, and the operations enum. What it adds that neither has is a **result** type whose per-category map is deliberately not normalized (Decision #2), and an **input union whose cardinality is type-dependent** (Decision #4) — the two places a reviewer should look hardest.

### Deliverables

**Layer A (new):** `ALLM.ModerationRequest`, `ALLM.ModerationResult`, `ALLM.ModerationResponse`, `ALLM.Error.ModerationAdapterError`.
**Layer A (modified):** `ALLM.Error.EngineError` (+`:no_moderation_adapter`), `ALLM.Error.ValidationError` (+`:invalid_moderation_request`), `ALLM.Serializer` (+4 `@known_modules` entries), `ALLM.Validate` (+`moderation_request/1`).
**Layer B (new):** `ALLM.ModerationAdapter`; `ALLM.Providers.FakeModeration`; `ALLM.Providers.OpenAI.Moderation`; `ALLM.Test.ModerationAdapterConformance`.
**Layer B (modified):** `ALLM.Engine` (+`:moderation_adapter` at every site in the Engine-extension table) — 22.2.
**Layer B support, landed with the Layer C façade that consumes them:** `ALLM.Capability` (+`preflight_moderation/2`), `ALLM.Telemetry` (+`:moderate` span name) — 22.3. Both are pure additions to existing Layer B modules with no Layer C dependency; they ship in 22.3 because 22.3 is their only caller and a phase must be independently shippable.
**Layer C (new):** `ALLM.moderate/3`, `ALLM.moderation_request/2`.

### Spec coverage

Implements new **§39**. Amends **§27** (module tree), **§29** (telemetry event names), and **§35.7** (bundled-adapter rule — Decision #3). §32.5 and §33 are **not** touched: neither list names moderation (verified 2026-08-31, `grep -n "moderat" steering/allm_engine_session_streaming_spec_v0_2.md` returns no hit), so there is nothing to strike.

§35's own out-of-scope list contains an adjacent line worth reconciling in §39's prose — *"image classification / object detection as distinct primitives — users build these on top of chat + vision"* (`steering/allm_engine_session_streaming_spec_v0_2.md:2280`). Moderation *is* a classification primitive, so §39 must say why it is admitted where object detection is not: it has a dedicated, free, single-call endpoint that no amount of chat + vision composition reproduces, and it is the gate a safety-conscious app runs *before* the chat call it would otherwise be built on.

### Layer demonstration

**Layer A** — build, validate, and serialize a request with no engine, no adapter, no network:

```elixir
req = ALLM.moderation_request(["is this ok?", "and this?"])
:ok = ALLM.Validate.moderation_request(req)
json = ALLM.Serializer.to_json!(req)
{:ok, ^req} = ALLM.Serializer.from_json(json)
```

**Layer B** — call an adapter directly, bypassing the façade entirely:

```elixir
req = ALLM.ModerationRequest.new(input: ["hello"], model: "omni-moderation-latest")
{:ok, %ALLM.ModerationResponse{results: [%ALLM.ModerationResult{flagged: false}]}} =
  ALLM.Providers.OpenAI.Moderation.moderate(req, api_key: "sk-…")
```

**Layer C** — the façade, with the telemetry span and the gates:

```elixir
engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.OpenAI.Moderation)
{:ok, resp} = ALLM.moderate(engine, user_text)
if ALLM.ModerationResponse.flagged?(resp), do: reject(ALLM.ModerationResponse.flagged_categories(resp))
```

There is deliberately **no Layer D**: a moderation verdict carries no conversation state, so `ALLM.Session` is untouched.

### Prerequisites

- Phase 20 embeddings family, the structural template throughout: `lib/allm/embedding_adapter.ex`, `lib/allm/embedding_request.ex`, `lib/allm/error/embedding_adapter_error.ex`, `lib/allm/providers/openai/embeddings.ex`, `conformance/lib/allm/test/embedding_adapter_conformance.ex`.
- Phase 17 vision data types, for 22.5 only: `lib/allm/image_part.ex`, `lib/allm/image.ex`, `lib/allm/providers/support/image_mime.ex`.
- `ALLM.Retry` (`lib/allm/retry.ex`), `ALLM.Keys` (`lib/allm/keys.ex`), `ALLM.Telemetry.span/3` (`lib/allm/telemetry.ex:169-175`), `ALLM.Providers.Support.OpenAIHeaders.json_headers/2` (`lib/allm/providers/support/openai_headers.ex:45`).
- An `OPENAI_API_KEY` for the 22.4 and 22.6 live gates. **The endpoint is free**, so the live-gate cost is $0.00 (Decision #10).
- No new deps. `Req` handles the synchronous JSON POST; no streaming, no multipart, no direct `Finch`.

### Out of scope

| Excluded | Why |
|----------|-----|
| `text-moderation-*` models | Assumption 1 — shut down 2025-10-27. |
| A normalized cross-provider category taxonomy | Alternative B — one bundled provider, and the plausible second reports a different shape on a different call. |
| A default "unsafe" threshold, `block?/2`, or a policy DSL | Assumption 3 — a product decision, not a library one. |
| `ALLM.Providers.Gemini.Moderation` | Assumption 2 — Gemini's safety ratings ride `generateContent`; there is no standalone endpoint to implement `moderate/2` against. Surfacing them belongs on `Response.metadata` in a chat-adapter phase, not here. |
| `ALLM.Providers.Anthropic.Moderation` | No endpoint exists. Unlike embeddings/Voyage, Anthropic names no partner for this capability, so there is no honest module to ship (contrast `steering/2026-07-28_EMBEDDINGS_DESIGN.md:60`). |
| Mistral / AWS Comprehend / Perspective API moderation | Out-of-core per §35.7, same as Cohere/Jina embeddings. |
| Transparent batch chunking | Alternative D. |
| Automatic moderation inside `chat/3` / `generate/3` | A hidden second HTTP call per turn, doubling latency and silently changing `chat/3`'s error union. If wanted, it is a caller-side two-liner or a telemetry-handler concern (§29). |
| `ALLM.Session` integration | Moderation carries no conversation state. |
| Streaming | Assumption 4. |
| Moderating tool results / assistant output as a distinct API | Same call, different input string. No new surface needed. |

### Non-obvious decisions

1. **`omni-moderation-latest` only; `text-moderation-*` is not implemented.** Assumption 1 and Alternative A, with the deprecation table quoted. The adapter omits `model` from the wire body entirely when `request.model` is `nil`, letting OpenAI's own default apply rather than pinning a name ALLM must chase. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Moderation` + `guides/moderation.md` + CHANGELOG.*
2. **Category maps are provider-shaped and string-keyed; only `:flagged` is normalized.** Alternative B, with all three anti-atom arguments. `categories` and `category_scores` round-trip as identity through `__from_tagged__/1` — no decode hook, no safelist, no drift when OpenAI adds a category. *Docs target: `@moduledoc ALLM.ModerationResult` + spec §39.2.*
3. **§35.7's bundled-adapter rule takes a second scoped beneficiary.** Phase 20 amended §35.7 to admit an adapter that is *"the provider's own officially-recommended path for a capability that provider does not offer"* (`steering/2026-07-28_EMBEDDINGS_DESIGN.md:179`). Moderation needs a different carve-out: a **capability only one bundled provider offers at all**. The amendment states that a single-provider capability family is admissible when the provider is already bundled for chat — `ALLM.Providers.OpenAI` is — and that the family's absence on the other bundled providers is documented rather than backfilled with a proxy. *Docs target: spec §35.7 amendment + §39.7.*
4. **`:input` cardinality is type-dependent, and `multimodal?/1` makes it derivable before the call.** Alternative C, with OpenAI's own mixed-array example quoted. Stated once normatively on `@moduledoc ALLM.ModerationRequest`; every other mention cites it. *Docs target: `@moduledoc ALLM.ModerationRequest` + `@doc ALLM.moderate/3` "Result cardinality" + `guides/moderation.md`.*
5. **No transparent chunking, unlike `embed/3`.** Alternative D. The parity gap is a documented divergence, not an oversight: `@doc ALLM.moderate/3` carries a "Batching" section that names `embed/3`, says moderation does not chunk, and shows the caller loop. *Docs target: `@doc ALLM.moderate/3` + `guides/moderation.md`.*
6. **`%ModerationResponse{}` has no `:usage` field.** Assumption 6 — the endpoint is free and returns no usage object. But the `[:allm, :moderate, :stop]` metadata **does** carry `usage: nil` unconditionally, because a stable metadata key set across capability spans is what a metrics backend wants and is the documented rationale for `embed_stop_extras/1`'s uniform key set (`lib/allm.ex:1457-1489` — the comment block at `:1457-1465` argues it for the *measurements*; the error clause at `:1482-1485` is where `usage: nil` is actually emitted). A handler written against `:embed` must not `KeyError` when pointed at `:moderate`. *Docs target: `@moduledoc ALLM.ModerationResponse` + `@moduledoc ALLM.Telemetry` table row.*
7. **`ModerationAdapter.moderate/2` returns only `ModerationAdapterError`, never `ValidationError`.** This matches `c:ALLM.ImageAdapter.generate/2` (`lib/allm/image_adapter.ex:74-75`) and `c:ALLM.EmbeddingAdapter.embed/2` (`lib/allm/embedding_adapter.ex:118-120`), and deliberately does **not** copy `ALLM.Providers.OpenAI.generate/2`, whose concrete `@spec` widens beyond its own `@callback` to `{:error, AdapterError.t() | ValidationError.t()}` (`lib/allm/providers/openai.ex:526-527`) in order to surface `ImageMime.validate_request/2`. 22.5's image gate therefore converts MIME and byte-size failures into `%ModerationAdapterError{reason: :invalid_request}` with the detail on `:metadata`, rather than widening the union. *Docs target: `@moduledoc ALLM.ModerationAdapter` invariant 2 + `@doc ALLM.Providers.OpenAI.Moderation.moderate/2`.*
8. **`ImagePart.detail` is dropped for moderation, with a deferred-form `:debug` log.** The moderations wire example carries `"image_url": {"url": …}` with **no** `detail` key (Alternative C's quoted payload), and no OpenAI documentation mentions detail control on this endpoint. Sending an undocumented field would be the negative-control failure the 22.4 probe exists to catch. A dropped-not-errored field matches the contract images set for `response_format` on `gpt-image-1` (`lib/allm/providers/openai/images.ex:42-51`) and vision's Anthropic-side detail drop. The log uses the deferred form per CLAUDE.md: `Logger.debug(fn -> … end)`. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Moderation` wire-field table.*
9. **`to_openai_content_blocks/1` and `part_to_block/1` are local to the moderation adapter, not extracted from `lib/allm/providers/openai.ex`.** The chat translator's same-named helpers are `defp` at `openai.ex:1839-1892` and take an endpoint atom (`/2`) because chat has two endpoints; moderation has one, so the moderation pair is `/1`. Per CLAUDE.md's cross-provider alignment rule, names align byte-for-byte modulo the arity difference driven by that invariant, exactly as `Anthropic`'s `/1` forms align with `OpenAI`'s `/2` forms. This is **not** a second-caller promotion trigger: the bodies differ (no `detail`, no `:responses` arm), so per `agent-spec/IMPLEMENTATION.md:68` the semantic-clone test fails and no extraction is owed. Recorded here so a future reviewer does not re-litigate it. *Docs target: `@doc false` on the moderation-side pair.*
10. **The live gate is free, so it is unconditionally BLOCKING with no cost caveat.** Every prior provider phase carried a per-call token budget and a projected dollar cost (agent-spec/DESIGN.md rule 19). Moderation's is $0.00 by provider policy (Assumption 6), which removes the usual reason to run the probe sparingly. 22.4's recorder is therefore free to run its full arm ladder including the `max_batch_size` search. *Docs target: internal — no user-facing docs needed.*
11. **`Validate.moderation_request/1` runs at the façade, matching `embed/3` and diverging from `generate_image/3`.** Adopted from the embeddings error-flow ordering — `do_embed_body/5`'s `with`-chain, `lib/allm.ex:1410-1411`. An empty-string input is a guaranteed provider 400, and an empty `:input` list is a guaranteed 400 — both should fail before the HTTP round-trip. *Docs target: `@doc ALLM.moderate/3` "Validation policy" section.*
12. **`ModerationResult.index` is always a `non_neg_integer()`, never `nil`.** Mirrors `Embedding.index` (`lib/allm/embedding.ex:44-51`) and preserves `Enum.at(response.results, i) ↔ Enum.at(request.input, i)` for the all-strings shape. In the multimodal shape there is exactly one result and its index is `0`. *Docs target: `@moduledoc ALLM.ModerationResult`.*

---

## Behaviour & Type Contracts

Every signature, wire shape, and invariant below is stated normatively **once**. Later sections cite; they do not restate.

### Layer A — `ALLM.ModerationRequest`

```elixir
defmodule ALLM.ModerationRequest do
  @type item :: String.t() | ALLM.ImagePart.t()

  @type t :: %__MODULE__{
          input: [item()],
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:model, input: [], options: %{}, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "True when any element is an `%ALLM.ImagePart{}` — see the cardinality rule."
  @spec multimodal?(t()) :: boolean()
  def multimodal?(request)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end

defimpl Jason.Encoder, for: ALLM.ModerationRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**Constructor discipline.** Bare `struct!/2` pass-through, no `@enforce_keys`, no runtime guards — the default per CLAUDE.md's Layer-A constructor rule, matching `EmbeddingRequest.new/1` (`lib/allm/embedding_request.ex:92-93`). `input: []` **must be constructible** so that `Validate.moderation_request/1`, not `struct!/2`, is what rejects it; that is what makes the `{:input, :empty}` field-error row reachable.

**Constructor-raise reconciliation across the three structs** (agent-spec/DESIGN.md rule 27 — every `raise X` Test Plan bullet checked against the constructor body that must produce it). The two exception shapes are not interchangeable: `struct!/2` raises `KeyError` on an *unknown* key and `ArgumentError` on a missing `@enforce_keys` key, and it accepts an explicit `nil` for a defaulted field by silently overwriting the default. Both behaviours are stated in committed code — `lib/allm/embedding.ex:56-57`: *"A missing `:vector` raises `ArgumentError` (`@enforce_keys`); an unknown key raises `KeyError` (`struct!/2`)."*

| Struct | `@enforce_keys` | `ArgumentError` bullet? | `KeyError` bullet? |
|--------|-----------------|-------------------------|--------------------|
| `ModerationRequest` | none | **no** — nothing is enforced, so none is reachable | yes (unknown key) |
| `ModerationResult` | `[:flagged]` | **yes** — 22.1 asserts `new/1` without `:flagged` raises | — |
| `ModerationResponse` | none | **no** | — |

No constructor in this design carries a runtime type guard. `Tool.new/1`'s `is_boolean/1` guard (`lib/allm/tool.ex:105-121`) remains the tree's single documented exception.

**`__from_tagged__/1` decode hooks.** `input` needs one: elements are a union of binaries and `%ImagePart{}`, and the `%ImagePart{}` arm must route through `ALLM.Serializer.hydrate/1`. Specify `decode_input/1` as an explicit two-clause private (`is_list` → `Enum.map(&decode_item/1)`, else pass through verbatim), matching `Embedding`'s `decode_vector/1` pass-through-don't-repair contract (`lib/allm/embedding.ex:130-131`). `model` / `options` / `metadata` use the `data["k"] || default` idiom, which is safe here because every default is `nil` or `%{}` — none is truthy (CLAUDE.md's `decode_<field>` rule).

**`multimodal?/1` must not raise on a non-list `:input`.** It is called from `ALLM.moderate/3`'s `:start` telemetry metadata, which is built **before** `Validate.moderation_request/1` runs — the same hazard `input_count/1` is written around (`lib/allm.ex:1384-1388`). The natural body, `Enum.any?(input, &is_struct(&1, ImagePart))`, raises `Protocol.UndefinedError` on `input: 42` and returns `false` on `input: %{}`, giving two behaviours for one "not a list" class on a *public* function. Specify it as a guarded pair: `def multimodal?(%__MODULE__{input: input}) when is_list(input), do: Enum.any?(input, &is_struct(&1, ImagePart))` and `def multimodal?(%__MODULE__{}), do: false`.

**Cardinality invariant (the normative home).** `:input` is a list of items. If `multimodal?/1` is `false`, the request is a batch of `length(input)` independent items and a conforming adapter returns exactly that many results, with `index` values `0..length-1`. If `multimodal?/1` is `true`, the entire `:input` list is **one** multimodal item and a conforming adapter returns exactly **one** result at `index: 0`. This is a property of the provider wire (Alternative C), not an ALLM choice.

### Layer A — `ALLM.ModerationResult`

```elixir
defmodule ALLM.ModerationResult do
  @type t :: %__MODULE__{
          flagged: boolean(),
          categories: %{String.t() => boolean()},
          category_scores: %{String.t() => float()},
          applied_input_types: %{String.t() => [String.t()]},
          index: non_neg_integer(),
          metadata: map()
        }

  @enforce_keys [:flagged]
  defstruct [
    :flagged,
    categories: %{},
    category_scores: %{},
    applied_input_types: %{},
    index: 0,
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "Category names whose `categories` value is `true`, sorted."
  @spec flagged_categories(t()) :: [String.t()]
  def flagged_categories(result)

  @doc "Score for one category, or `nil` when the provider did not report it."
  @spec score(t(), String.t()) :: float() | nil
  def score(result, category)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end

defimpl Jason.Encoder, for: ALLM.ModerationResult do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**`__from_tagged__/1` decode contract.** `categories`, `category_scores`, `applied_input_types`, and `metadata` take the `data["k"] || %{}` idiom — safe, because every one of those defaults is `%{}`, not a truthy value (CLAUDE.md's `decode_<field>` rule). `index` takes `|| 0`, also safe. **`:flagged` needs an explicit clause and does not get the `||` idiom**: `@enforce_keys [:flagged]` constrains `struct!/2` at the constructor and does **not** constrain a literal `%__MODULE__{flagged: data["flagged"]}` inside `__from_tagged__/1`, so a truncated payload would yield `flagged: nil` and silently violate the declared `boolean()` type. Specify `decode_flagged/1` as `decode_flagged(v) when is_boolean(v), do: v` / `decode_flagged(_), do: false` — fail-closed on a malformed payload is the only safe direction for a moderation verdict, and it is the one place in this design where decode repairs rather than passes through. State that inversion of `decode_vector/1`'s pass-through-don't-repair contract (`lib/allm/embedding.ex:130-131`) in the `@doc false`, because it is deliberate and would otherwise read as a copy error.

`@enforce_keys [:flagged]` mirrors `Embedding`'s `@enforce_keys [:vector]` (`lib/allm/embedding.ex:44`): the field without which the struct means nothing. `new/1` takes no default argument, also matching `Embedding.new/1` (`lib/allm/embedding.ex:67`).

**`applied_input_types` is `%{}` when the provider omits it.** The key is present on omni responses (Alternative C's quoted response) and absent on legacy ones. An empty map is the honest representation of "not reported" and needs no decode hook beyond `|| %{}`.

**The field name drops the wire's `category_` prefix; its two siblings do not.** The wire key is `category_applied_input_types`, and `decode_response/4` reads it under that name. Dropping the prefix on the struct is deliberate — inside a per-category map the prefix is redundant, and `applied_input_types["violence"]` reads better than `category_applied_input_types["violence"]`. It is called out here because `categories` and `category_scores` *do* keep their wire spelling, so the inconsistency is otherwise a trap for a reader diffing the decoder against a recorded fixture. The `@type t` line carries `# wire: category_applied_input_types`.

**Nullable category booleans.** The API reference types `illicit` and `illicit/violent` as **`"boolean or null"`** ([developers.openai.com/api/docs/api-reference/moderations](https://developers.openai.com/api/docs/api-reference/moderations), fetched 2026-08-31 — quoted in the wire-field map). The decoder therefore must not assume `is_boolean/1` on map values. `categories` is typed `%{String.t() => boolean()}` and the **adapter** drops null-valued keys at decode time rather than propagating `nil` into a typed map; the dropped key is then simply absent, which `flagged_categories/1` and `score/2` already handle. Pinned by a synthesized fixture (22.4 Test Plan).

**`category_scores` values are floats.** A JSON `0` would decode to an integer and break the `float()` type, the same hazard `Embedding.decode_component/1` handles (`lib/allm/embedding.ex:141-147`). The adapter coerces with `* 1.0`; **`__from_tagged__/1` does not** — per Decision #2 these maps round-trip as identity, and a serialization-time coercion would be a second place the rule lives. The 22.1 serializability fixture pins a non-integral score so the identity is observable.

### Layer A — `ALLM.ModerationResponse`

```elixir
defmodule ALLM.ModerationResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          results: [ALLM.ModerationResult.t()],
          raw: term(),
          metadata: map()
        }

  defstruct [:id, :request_id, :model, :provider, :raw, results: [], metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "True when ANY result is flagged."
  @spec flagged?(t()) :: boolean()
  def flagged?(response)

  @doc "Union of every result's flagged categories, deduplicated and sorted."
  @spec flagged_categories(t()) :: [String.t()]
  def flagged_categories(response)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end

defimpl Jason.Encoder, for: ALLM.ModerationResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**`__from_tagged__/1` decode contract.** Two fields need more than the `||` idiom:

* **`:results`** routes through `ALLM.Serializer.hydrate/1` to rebuild the nested `%ModerationResult{}` structs — `hydrate(data["results"] || [])`, exactly as `EmbeddingResponse` does for `:embeddings` (`lib/allm/embedding_response.ex:127-136`). Without it the field decodes to a list of raw maps and the round-trip test fails on struct identity.
* **`:provider`** is an `atom()` on a serializable struct, so it decodes through `ALLM.Serializer.to_atom_field/1` (`lib/allm/serializer.ex:196-200`), which is `String.to_existing_atom/1` with `nil`/non-binary pass-through and whose raise is rescued by `Serializer.hydrate_with/2` into `{:_unknown, :atom_decode_failed}`. A bare `String.to_atom/1` here would be untrusted-input atom growth — the same hazard Alternative B's argument (b) invokes to justify string category keys, and it would be inconsistent to bar it there and permit it one struct away.

No `:usage` field (Decision #6). `:provider` is the provider atom (`:openai`), populated by the adapter — present on this struct and not on `EmbeddingResponse` because a moderation verdict is routinely persisted alongside the content it judged, and "which policy engine said this" is the field an auditor asks for six months later.

**Cardinality invariant.** `length(response.results) == length(request.input)` when `ModerationRequest.multimodal?/1` is false; `== 1` when it is true. Stated normatively at `ModerationRequest`; repeated here only as a cross-reference.

**Accessor placement.** `flagged?/1` and `flagged_categories/1` on the response, `flagged_categories/1` and `score/2` on the result — the same convenience-reader pattern `EmbeddingResponse.vectors/1` and `dimensions/1` establish (`lib/allm/embedding_response.ex:90-95`, `:123-125`). The name `flagged_categories/1` intentionally appears on both structs with the same meaning at different scopes.

### Layer A — `ALLM.Error.ModerationAdapterError`

Eleven reasons — **the `EmbeddingAdapterError` enum verbatim** (`lib/allm/error/embedding_adapter_error.ex:28-39`), with `:batch_too_large` retained (Alternative D keeps `max_batch_size/0`) and no additions:

```elixir
@type reason ::
        :authentication_failed
        | :rate_limited
        | :invalid_request
        | :context_length_exceeded
        | :provider_unavailable
        | :timeout
        | :network_error
        | :malformed_response
        | :unsupported_feature
        | :batch_too_large
        | :unknown
```

**`:content_filter` is deliberately absent** — a moderation call is never itself content-filtered; classifying harmful text is the endpoint's purpose. `:unsupported_operation` is absent for the same reason it is absent from `EmbeddingAdapterError`: there is no operations enum.

Structural shape copies the embeddings sibling exactly: moduledoc reason table, `@type reason` union, a duplicate `@legal_reasons ~w(…)a` runtime list, `legal_reasons/0` with a doctest asserting `length == 11`, `defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]`, `new/2` raising `ArgumentError` on an off-enum reason, three-clause `message/1`, `default_message/2`, `__from_tagged__/1`, and a trailing `defimpl Jason.Encoder` (**not** `@derive`) — see `lib/allm/error/embedding_adapter_error.ex:79-164` for the shape being mirrored.

### Layer A — closed-enum extensions to committed modules

| Module | File:line of the committed enum | Addition | Use site in this phase |
|--------|--------------------------------|----------|------------------------|
| `ALLM.Error.EngineError` | `lib/allm/error/engine_error.ex:13-22` (`@type reason`) and `:33-42` (`@legal_reasons`) | `:no_moderation_adapter` | `do_moderate_body/5`'s nil-adapter clause (22.3) |
| `ALLM.Error.ValidationError` | `lib/allm/error/validation_error.ex:31-40` and `:49-59` | `:invalid_moderation_request` | `Validate.moderation_request/1` (22.1) |
| `ALLM.Telemetry` | `lib/allm/telemetry.ex:74` (`@type span_name`) and `:76` (`@valid_span_names`) | `:moderate` | `do_moderate/3`'s span (22.3) |

Every atom has a named current-phase use site, per agent-spec/DESIGN.md rule 13. **Both** the type union and the runtime `~w()a` / list literal must be edited in each case — they are separate declarations of the same set.

### Layer A — serializer registration (part of the contract)

`lib/allm/serializer.ex` `@known_modules` (`:65-95`) gains four entries. Three land in 22.1 with their structs; the fourth (`ModerationAdapterError`) also lands in 22.1, since the error module is a 22.1 deliverable:

```elixir
  ALLM.Error.ModerationAdapterError,
  ALLM.ModerationRequest,
  ALLM.ModerationResult,
  ALLM.ModerationResponse
```

`@type_tag_index` (`serializer.ex:97`) derives from the list and needs no separate edit. **All four land in one sub-phase**, avoiding the silent-early-registration hazard of PHASE_20's split (agent-spec/DESIGN.md rule 25).

### Layer A — `ALLM.Validate.moderation_request/1`

```elixir
@spec moderation_request(ModerationRequest.t()) :: :ok | {:error, ValidationError.t()}
```

Two clauses, mirroring `embedding_request/1` (`lib/allm/validate.ex:332-349`): a hard-reject head clause guarded `when not is_list(input)`, then an accumulating clause folding per-field rules through the shared `finalize/3` (`lib/allm/validate.ex:535-541`).

**Field-error vocabulary — exhaustive.** The implementer never invents an atom.

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `:input` | `:invalid_shape` | **yes** | `:input` is not a list — every `[:input, idx]` rule presupposes one |
| `:input` | `:empty` | no | `input == []` — a guaranteed provider 400 |
| `[:input, idx]` | `:empty` | no | element is `""` |
| `[:input, idx]` | `:invalid_item` | no | element is neither a binary nor an `%ALLM.ImagePart{}` |
| `:model` | `:invalid_shape` | no | `:model` is neither `nil` nor a binary |

Five rows. `[:input, idx] :invalid_item` is the moderation-side counterpart of embeddings' `:not_a_string`, renamed because the accept set is a union rather than a single type. **In 22.1 the `%ImagePart{}` arm of `:invalid_item` accepts `%ImagePart{}` already** — the validator is written union-aware from the start so 22.5 changes no validator code; only the adapter and the wire translator are 22.5 deliverables. Per-item MIME and byte-size rules are **not** here: they are provider-specific and live in the adapter (Decision #7), exactly as embeddings' per-model dimension cap lives in `Capability`, not `Validate` (`lib/allm/validate.ex:316-318`).

### Layer B — `ALLM.ModerationAdapter`

```elixir
@callback moderate(ALLM.ModerationRequest.t(), keyword()) ::
            {:ok, ALLM.ModerationResponse.t()}
            | {:error, ALLM.Error.ModerationAdapterError.t()}

@callback max_batch_size() :: pos_integer()

@callback prepare_request(ALLM.ModerationRequest.t(), keyword()) ::
            {:ok, Req.Request.t()} | {:error, ALLM.Error.ModerationAdapterError.t()}

@optional_callbacks prepare_request: 2
```

Three callbacks, one optional — structurally identical to `ALLM.EmbeddingAdapter` (`lib/allm/embedding_adapter.ex:118-144`), with `embed` → `moderate`. Each traces to a user-visible operation: `moderate/2` is `ALLM.moderate/3`'s dispatch target; `max_batch_size/0` is what `:batch_too_large` is measured against and what the guide's chunk loop reads; `prepare_request/2` is the documented escape hatch every adapter behaviour in the tree carries.

**Moduledoc structure** copies the embeddings behaviour: summary + Layer-B framing → `## Minimum impl skeleton` (a full compilable example) → `## HTTP transport guidance` → `## Batching` → `## Invariants` (a **numbered** list, cited by number from the façade) → a closing bolded **"Cleanup invariant: none."** paragraph stating the absence as intent.

**Numbered invariants** (the normative list):

1. `max_batch_size/0` returns a `pos_integer()` and is per-module, not per-call-with-model-arg.
2. `moderate/2` returns exactly `{:ok, %ModerationResponse{}}` or `{:error, %ModerationAdapterError{}}` — never a bare struct, never a three-tuple. **Enforced, not merely documented:** `ALLM.moderate/3` raises `ArgumentError` naming the adapter and this invariant on any other shape, rather than laundering it into the façade's error union. Copy the wording and the raise from `ALLM.EmbeddingBatch.dispatch_chunk/2` (`lib/allm/embedding_batch.ex:140-156`).
3. Result cardinality follows `ModerationRequest`'s normative rule.
4. `:index` values are exactly `0..length(results)-1`.
5. Oversized input is rejected with `:batch_too_large` **before any I/O** and, for an adapter that resolves credentials, **before `ALLM.Keys.fetch!/2`** — so a keyless environment observes the rejection rather than `%EngineError{reason: :missing_key}`. This is Phase 20.2's forward-binding constraint (`lib/allm/embedding_adapter.ex:39-43`) inherited verbatim. **The gate measures the *item* count invariant 3 defines, NOT `length(request.input)`:** `length(request.input)` for an all-strings `:input`, and exactly `1` for an `:input` carrying any `%ImagePart{}`, because the whole list is one multimodal item. `metadata.count` carries that item count. Stating it as raw list length would put invariants 3 and 5 in contradiction — observable at `max_batch_size() == 1`, where a two-element multimodal request (conformance case 10) would be rejected by a *correct* adapter. Amended in the 22.2 fix pass from functional-review finding F2, **before 22.5 writes image input against it**; the reference `gate/1`, `ScriptedModerationStub.gate/1` and the behaviour's published skeleton all measure items.
6. Empty input (`input == []`) is rejected with `:invalid_request`, under the same before-I/O and before-key ordering.
7. `opts[:request_id]` is reflected onto `response.request_id` unchanged when supplied.
8. `request.metadata` round-trips onto `response.metadata` unchanged.
9. `moderate/2` honours `opts[:request_timeout]`; exceeding it produces `{:error, %ModerationAdapterError{reason: :timeout}}`. Wording from `lib/allm/embedding_adapter.ex:78-80`. Without this, `:timeout` is published by the error enum and listed in 22.3's `@retryable_moderation_reasons` while no conforming adapter is obliged to emit it.
10. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `moderate/2` would fire it, and is defined only for a request whose item count is `<= max_batch_size()`. Wording from `lib/allm/embedding_adapter.ex:104-107`.

Invariants **9 and 10 were appended in the 22.2 fix pass** (code review finding F5 — the two obligations dropped from the embeddings sibling without replacement). They are appended rather than slotted in because 1–8 are cited by number from the conformance case names and from 22.2.4's forward-binding notes.

**Cleanup invariant: none.** No `Stream.resource/3` and no Finch ref — `Req.request/1` owns its connection lifecycle. Stated so the absence reads as intent.

### Layer B — `ALLM.Engine` extension

**This table is the single source of truth for the site count.** Every other mention of it in this document (Deliverables, Module Tree row, 22.2 checklist) references the table rather than re-quoting a numeral, per agent-spec/DESIGN.md rule 24. Every site verified 2026-08-31 by locating `embed_adapter` in the committed file.

| # | Site | File:line | What |
|---|------|-----------|------|
| 1 | `@type t` | `lib/allm/engine.ex:98-99` | `moderation_adapter: module() \| nil` |
| 2 | `defstruct` | `lib/allm/engine.ex:113-114` | add to the `nil`-default group |
| 3 | `@engine_field_keys` | `lib/allm/engine.ex:138-139` | `resolve_params/2` deny-list |
| 4 | `@module_fields` | `lib/allm/engine.ex:157-158` | `new/1` module validation |
| 5 | `__from_tagged__/1` | `lib/allm/engine.ex:498-499` | `restore_module(data["moderation_adapter"])` |
| 6 | moduledoc serializability bullet | `lib/allm/engine.ex:38-43` | add to the module-typed field list |
| 7 | `new/1` `@doc` prose | `lib/allm/engine.ex:170` | the sentence enumerating module-typed fields |
| 8 | `resolve_params/2` `@doc` prose | `lib/allm/engine.ex:456-459` | the parenthesized deny-list enumerated in prose — *"(`:adapter`, `:adapter_opts`, `:model`, `:tools`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter`, `:embed_adapter`, `:params`, …)"* |

**Eight sites: five code, three documentation.** Site 8 is the one a `grep` for the attribute name misses — it is prose that duplicates `@engine_field_keys` by hand, so it drifts silently.

**Naming: `:moderation_adapter`, not `:moderate_adapter`.** The tree is already inconsistent — `:image_adapter` is a noun, `:embed_adapter` a verb — so neither precedent binds. The noun form is chosen because it matches the behaviour module name (`ALLM.ModerationAdapter`) and the error atom (`:no_moderation_adapter`); the verb form would match only the façade function. Two of three beats one of three.

There is deliberately **no `Engine.moderation_adapter/1` accessor**: the façade pattern-matches `%Engine{moderation_adapter: adapter}` directly, as every other capability does.

### Layer B — `ALLM.Capability.preflight_moderation/2`

```elixir
@typedoc "Two-shape result of `preflight_moderation/2` (no rewrite branch)."
@type moderation_preflight_result :: :ok | {:error, ValidationError.t()}

@spec preflight_moderation(model_ref_or_string(), ModerationRequest.t()) ::
        moderation_preflight_result()
```

Body is the family `cond` verbatim (`lib/allm/capability.ex:333-342`): `not catalog_loaded?() -> :ok`, `not is_struct(model_ref_or_string, ModelRef) -> :ok`, else `check_moderation_capabilities/2`.

**One rejection rule**, not two:

* `{[:moderation_enabled], :moderation_disabled}` — fires when `model_ref.capabilities.moderation_enabled == false`.

There is no second rule. Embeddings' `:dimensions`/`dimensions_max` pairing has no moderation analogue — moderation has no numeric knob a catalog could cap. Per agent-spec/DESIGN.md rule 13 the single atom has a named use site (the check itself, plus a 22.3 test), so nothing is speculative.

The check must tolerate JSON-rehydrated `%ModelRef{}` values with **string-keyed** capabilities, matching `check_embeddings_enabled/2`'s two-arm `case` (`lib/allm/capability.ex:562-570`). A missing key is never a rejection.

Also: the moduledoc's "Five helpers" list (`lib/allm/capability.ex:1-23`) becomes **six** and gains a bullet. The count is prose in a bulleted list — re-read the list when editing rather than trusting the numeral.

### Layer C — façade

```elixir
@spec moderation_request(String.t() | [ModerationRequest.item()], keyword()) ::
        ModerationRequest.t()

@spec moderate(
        Engine.t(),
        String.t() | [ModerationRequest.item()] | ModerationRequest.t(),
        keyword()
      ) ::
        {:ok, ModerationResponse.t()}
        | {:error,
           EngineError.t() | ValidationError.t() | ModerationAdapterError.t()}
```

`moderate/3` has a head with a default plus **three** clauses, mirroring `embed/3` (`lib/allm.ex:1119-1131`): `%ModerationRequest{}` dispatched verbatim; `is_binary(input)` and `is_list(input)` both routed through `moderation_request/2`.

**Opt-lifting allow-list.** `@moderation_request_field_opts [:model, :options, :metadata]` — an explicit **allow**-list, never a deny-list, so a new façade opt can never leak into `ModerationRequest.new/1` (a bare `struct!/2` that `KeyError`s on unknown keys). **Consumer/producer symmetry invariant:** this list must equal the `%ModerationRequest{}` field set minus `:input`, or the missing field is silently unreachable from the string/list call shape. Pinned by a test (22.3). Its outbound counterpart `drop_moderation_request_opts/1` strips the same keys from the opts handed to the adapter. Both directions are the pattern at `lib/allm.ex:937-954` and `:1352-1356`.

**Gate order inside the span** — normative, and identical in shape to `do_embed/3`'s gate-order comment (`lib/allm.ex:1358-1366`) and `do_embed_body/5`'s `with`-chain (`:1410-1411`):

1. Adapter-presence gate — a **pattern match** on `%Engine{moderation_adapter: nil}` in the first function clause, not a conditional. Fires FIRST so a missing adapter plus a moderation-disabled model surfaces `:no_moderation_adapter`, not `:unsupported_capability`.
2. `ALLM.Validate.moderation_request/1` (Decision #11).
3. `ALLM.Capability.preflight_moderation/2` (inert without a catalog).
4. Model stamping: `request = %{request | model: request.model || resolved_model}`, preserving an explicitly-set request model.
5. `ALLM.Retry.run/3`-wrapped dispatch to `adapter.moderate/2`.

**Key resolution does not happen at the façade.** There is no `Keys.fetch!` in the façade body; `:api_key` is forwarded in the dispatch opts and the adapter calls `ALLM.Keys.fetch!(:openai, opts)` itself, *after* its own gates (invariant 5). Verified against `lib/allm/providers/openai/embeddings.ex:531-535`.

**Retry — follows the image convention, not the embeddings one.** `@retryable_moderation_reasons [:rate_limited, :provider_unavailable, :timeout, :network_error]` — the same four the image and embedding sides use. The policy is materialized by the **existing shared** `augment_retry_policy/2` (`lib/allm.ex:1281-1291`), which already takes the reason list as its second argument; **no new helper, and no edit to that function.**

The two siblings place the wrap and the policy differently, and moderation follows images:

| | `Retry.run/3` lives in | Policy travels via |
|---|---|---|
| `generate_image/3` | `do_generate_image_body/5`'s body (`lib/allm.ex:1259-1262`) | a local `policy` binding (`:1257`) |
| `embed/3` | `EmbeddingBatch.dispatch_chunk/2` (`lib/allm/embedding_batch.ex:140-156`) | `dispatch_opts[:retry_policy]` (`lib/allm.ex:1449`), because the batcher reads `ctx.policy` |
| **`moderate/3`** | **`do_moderate_body/5`'s body**, mirroring `:1259-1262` | **a local binding** — there is no batcher to read an opts key |

**`build_moderate_dispatch_opts/3` MUST inject `adapter_opts[:cursor_key]`.** Its last step is
`(engine.adapter_opts ++ call_site_adapter_opts) |> Engine.put_cursor_key(engine)`, exactly as the
embeddings façade does at `lib/allm.ex:1433-1450` (`:1439-1442` is the `put_cursor_key/2` call).
Without it, `ALLM.Providers.FakeModeration`'s documented precedence source 2 never fires at the
façade, every façade-driven script falls back to `:erlang.phash2(script)`, and two content-equal
engines silently share one process-dict cursor slot **and** one retry budget — the footgun
`fake_moderation.ex`'s `## Cursor behaviour` section says is confined to direct adapter calls.
The failure is silent: a green test suite with the wrong verdicts. Added in the 22.2 fix pass from
code review finding F3.

So `build_moderate_dispatch_opts/3` **does not** put `:retry_policy` into the adapter opts; following the embeddings convention would leak an unread key into every adapter call. `dispatch_moderate_attempt/3` is the **per-attempt closure** passed to `Retry.run/3` — not the wrap itself — shaped like `dispatch_image_attempt/3` (`lib/allm.ex:1297-1310`, whose own comment reads *"Per-attempt closure for `Retry.run/3`"*), extended with the invariant-2 `raise` clause copied from `embedding_batch.ex:145-152`.

**Telemetry — `[:allm, :moderate, :start | :stop | :exception]`.**

| Key | Kind | On `:start` | On `:stop` (ok) | On `:stop` (error) |
|-----|------|-------------|-----------------|--------------------|
| `request_id`, `engine`, `model` | metadata | ✓ | ✓ | ✓ |
| `input_count` | metadata | ✓ | ✓ | ✓ |
| `multimodal` | metadata | ✓ | ✓ | ✓ |
| `usage` | metadata | — | `nil` | `nil` |
| `response` / `error` | metadata | — | response / `nil` | `nil` / error |
| `result_count` | measurement | — | `length(results)` | `0` |
| `flagged_count` | measurement | — | count of flagged results | `0` |

Both measurements present on **both** paths (Decision #6's stability rule). `input_count/1` is computed by a two-clause private that tolerates a non-list `:input`, because `:start` metadata is built **before** validation runs — the exact hazard documented at `lib/allm.ex:1384-1388`.

**`:stream` is silently dropped**, matching `embed/3` (`lib/allm.ex:1094-1097`). Passing `stream: true` does not error.

### Wire-field map — OpenAI

**Endpoint:** `POST https://api.openai.com/v1/moderations`. **Auth:** `Authorization: Bearer <key>` via `ALLM.Providers.Support.OpenAIHeaders.json_headers/2` (`lib/allm/providers/support/openai_headers.ex:45`). **Key atom:** `:openai`, resolved by `ALLM.Keys.fetch!/2` after the gates.

Each row is marked **confirmed** (quoted from OpenAI documentation in this design) or **inferred** (must be falsified or confirmed by the 22.4 probe, per CLAUDE.md's four-part-probe rule).

| Concern | Wire | Status |
|---------|------|--------|
| Request: text batch | `{"input": ["a", "b"], "model": "omni-moderation-latest"}` | **confirmed** — API reference, `input` typed *"string, array of strings, or array of multi-modal objects"* |
| Request: multimodal | `{"input": [{"type":"text","text":…},{"type":"image_url","image_url":{"url":…}}]}` | **confirmed** — quoted verbatim in Alternative C |
| Request: `model` omitted | server default applies | **CONFIRMED 2026-08-31** — response echoed `omni-moderation-latest` |
| Response: envelope | `{"id": "modr-…", "model": …, "results": [...]}` | **confirmed** — quoted in Alternative C |
| Response: `results[].flagged` | boolean | **confirmed** |
| Response: `categories` | 13 slash-named keys; `illicit` / `illicit/violent` typed **`"boolean or null"`** | **confirmed** — API reference response schema |
| Response: `category_scores` | 13 float keys | **confirmed** |
| Response: `category_applied_input_types` | 13 keys → array of `"text"` / `"image"`, possibly `[]` | **CONFIRMED 2026-08-31** — present on every recorded omni 200 |
| Response: usage | **absent** | **CONFIRMED 2026-08-31** — no `usage` key in any recorded body; Assumption 6 holds |
| Error envelope | `{"error": {"message", "type", "param", "code"}}` | **CONFIRMED 2026-08-31** — `recorded/error_400_bad_model.json` |
| Correlation header | `x-request-id` | **CONFIRMED 2026-08-31** — observed on a 200 |
| `max_batch_size` | **undocumented by OpenAI** | **MEASURED 2026-08-31 — 1000 is a FLOOR, not a cap.** Ladder `[1, 32, 100, 128, 1000]` all returned 200 with `length(results) == n`; no upper bound was found |
| `detail` on `image_url` | not accepted | **STILL INFERRED** — Decision #8. 22.5 owns it, but see the control result in 22.4.5: this endpoint **ignores** unknown fields, so a 200 on a `detail`-bearing request would prove nothing either way |
| Image limit | 20 MB | **confirmed** — *"image files can be up to 20 MB"* |
| Pricing | free | **confirmed** — *"The moderation endpoint is free to use"* |

Every **inferred** row gets a probe arm in 22.4.

### Layer B — `ALLM.Providers.OpenAI.Moderation`

```elixir
@behaviour ALLM.ModerationAdapter

@base_url "https://api.openai.com/v1"
@endpoint "/moderations"
@default_model "omni-moderation-latest"
```

Public/`@doc false` seams, each carrying `@spec` so Dialyzer binds them and tests can drive them without an HTTP round-trip (the pattern CLAUDE.md documents for `openai/images.ex`'s nine seams):

| Function | Purpose | Sub-phase |
|----------|---------|-----------|
| `moderate/2` | `@impl`; script short-circuit → gates → key → HTTP → decode | 22.4 |
| `max_batch_size/0` | `@impl`; returns `@adapter_max_batch_size` | 22.4 |
| `prepare_request/2` | `@impl`; unfired `%Req.Request{}` | 22.4 |
| `to_json_body/2` `@doc false` | `(request, opts)` → wire map; returns bare `map()` | 22.4 |
| `decode_response/4` `@doc false` | `(body, headers, request, opts)` → `{:ok, ModerationResponse.t()}` \| `{:error, …}` | 22.4 |
| `to_moderation_adapter_error/4` `@doc false` | `(status, body, headers, opts)` → `%ModerationAdapterError{}` | 22.4 |
| `to_openai_content_blocks/1` `@doc false` | `[item()]` → `[map()]` | 22.5 |
| `part_to_block/1` `@doc false` | one item → one wire block | 22.5 |
| `reject_oversized_images/1` `@doc false` | per-part MIME + byte gate | 22.5 |

**Argument orders are the family's, not invented:** `decode_response/4` is `(body, headers, request, opts)` and `to_<capability>_adapter_error/4` is `(status, body, headers, opts)`, matching `lib/allm/providers/openai/embeddings.ex:380-384` and `:351-359` respectively.

**Test-injection escape hatch (required, not optional).** `moderate/2` opens with a script short-circuit exactly as `OpenAI.Embeddings.embed/2` does (`lib/allm/providers/openai/embeddings.ex:243-248`):

```elixir
def moderate(%ModerationRequest{} = request, opts) when is_list(opts) do
  case fetch_moderation_script(opts) do
    nil -> do_moderate(request, opts)
    _script -> FakeModeration.moderate(request, opts)
  end
end
```

This is what lets `test/allm/providers/openai/moderation_conformance_test.exs` drive the real adapter through the shared harness. It is also why conformance cases 3 and 4 must pass **no** script: a scripted adapter short-circuits ahead of its own gates, so those two cases are the only ones that reach this adapter's `:batch_too_large` / `:invalid_request` guards — and the reason those guards must fire ahead of `ALLM.Keys.fetch!/2` (invariant 5), so a keyless CI observes the rejection.

**The moderation adapter carries the family's test-seam naming banner** — the comment block at `lib/allm/providers/openai/embeddings.ex:286-334` that enumerates which seam names are byte-identical to the sibling capability and which are renamed per-capability. Moderation's banner records: `decode_response/4` and `to_json_body/2` identical to both siblings; `to_moderation_adapter_error/4` ↔ embeddings' `to_embedding_adapter_error/4` ↔ images' `to_image_adapter_error/4`; `classify_moderation_reason/4`; `fetch_moderation_script/1`; and `max_batch_size/0` shared with embeddings in the same per-module-constant role that images fills with `supported_operations/0`.

**`to_json_body/2` returns a bare `map()`**, aligning with the *capability* family (`OpenAI.Embeddings.to_json_body/2`) rather than the Gemini-shaped `{:ok, map()} | {:error, _}`. Per CLAUDE.md's provider-vs-capability adjudication rule, the capability family wins by default and only a per-provider invariant overrides it; there is none here, because unlike Gemini's embeddings the model is not required in the URL path and body construction cannot fail.

**`redact_key_material/1` and `sanitize_cause/1` are per-adapter privates**, not shared, matching all three embeddings adapters. The OpenAI pattern is inherited **verbatim** because the provider is the same one — `~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/`, copied from `lib/allm/providers/openai/embeddings.ex:695-699`. This is the one case where inheriting a sibling's regex is correct rather than a silent no-op; the accompanying test asserts the *Gemini* and *Voyage* patterns match nothing in the same fixture, per CLAUDE.md's companion-test rule.

**No `body_preview` on the error struct**, and `sanitize_cause/1` blanks `Jason.DecodeError`'s `:data`. This ships *safer* than the released `lib/allm/providers/openai/images.ex`, which still puts raw provider messages and 200-char body previews into a `Jason.Encoder`-derived struct — a `[CARRY]` line naming that file:line is filed in `ASKS.md` in the same pass, per CLAUDE.md.

### Layer B — `ALLM.Providers.FakeModeration`

Mirrors `ALLM.Providers.FakeEmbeddings` (`lib/allm/providers/fake_embeddings.ex`), including its cursor contract.

```elixir
@type script_entry ::
        {:ok, [ALLM.ModerationResult.t()]}
        | {:flagged, [String.t()]}
        | {:error, ALLM.Error.ModerationAdapterError.t()}
        | {:retry_until_call, pos_integer()}
```

`{:flagged, categories}` is the one entry with no embeddings counterpart: it synthesizes a single flagged result with those category names `true` and score `1.0`, so the overwhelmingly common test ("assert the app rejects flagged content") is a one-liner rather than a hand-built `%ModerationResult{}`.

**Default behaviour with no script:** every input yields an unflagged result with the 13 omni category names present, all `false`, all scores `0.0`. Deterministic — no randomness, no hashing of input text. **"No script" means `:moderation_script` absent or `[]` — and only that.** A **non-empty** script whose cursor has run off the end returns `{:error, %ModerationAdapterError{reason: :unknown, metadata: %{cause: :moderation_script_exhausted}}}`, mirroring `FakeEmbeddings`' exhaustion shape. The two are different caller mistakes: "I didn't script anything" is a convenience request; "my script ran out" is almost always an off-by-one in the caller's expectation of the call count, and a clean verdict would make that bug pass green. Split in the 22.2 fix pass from code review finding F4; RECORDS deviation 1 is amended accordingly.

**Cursor:** `adapter_opts[:cursor_key]` (the engine's stable `:id`, injected by the façade via `ALLM.Engine.put_cursor_key/2`, `lib/allm/engine.ex:231-243`), falling back to the script hash. Copy the moduledoc's two-source explanation verbatim from `fake_embeddings.ex:56-67`.

**Pre-flight gates fire before the script**, matching `FakeEmbeddings` (`fake_embeddings.ex:130-139`): `input: []` → `:invalid_request`; over `max_batch_size/0` → `:batch_too_large` with `metadata` carrying `:count` and `:max`.

**`@adapter_max_batch_size 32`** — deliberately NOT the sibling's provider-shaped number. `FakeEmbeddings` mirrors OpenAI's real 2048 (`lib/allm/providers/fake_embeddings.ex:101`), which forces conformance case 3 to build a 2049-element list on every run. Moderation's real cap is not even known until the 22.4 ladder probe and could land at 1000, so a mirrored constant would be both expensive and a guess. 32 is large enough to be plausible and small enough that the `:batch_too_large` boundary is cheap to cross. **Conformance case 3 must build its oversized input from the callback** — `List.duplicate("x", adapter.max_batch_size() + 1)` — never from a literal, so the case stays correct for a third-party adapter whose cap is 1 or 100_000. `ScriptedModerationStub` keeps its own `@max_batch_size 4` for the harness's self-test.

### Layer B — `ALLM.Test.ModerationAdapterConformance`

`conformance/` is a **second Mix project**; its gates are not covered by the main project's. Structure copies `conformance/lib/allm/test/embedding_adapter_conformance.ex`: `use ExUnit.CaseTemplate`, a `@case_count` attribute, a `case_count/0` introspection function, a `using/1` macro injecting one `describe/2`, and a harness self-test asserting the injected block produces exactly `@case_count` cases.

**Ten cases:** eight invariant cases — invariant 3 twice, once per cardinality arm — plus two shape checks. `@case_count 10`. **Invariant 2 is deliberately unbound by this suite:** its enforcement lives at the façade (`ALLM.moderate/3` raises `ArgumentError`), not inside any adapter, so a conformance run cannot observe it. It is bound by `test/allm/allm_moderate_test.exs`'s *"an adapter returning a bare map raises ArgumentError"* bullet (22.3). Say so in the `## What this suite does NOT bind` section — a third-party adapter author certified only by this published suite otherwise gets no signal on the one invariant the behaviour moduledoc bolds as *"Enforced, not merely documented."*

1. `max_batch_size/0` returns a `pos_integer()` — invariant 1
2. single string input returns exactly one result at `index: 0`
3. input longer than `max_batch_size/0` is rejected with `:batch_too_large` **before I/O** — invariant 5
4. empty input is rejected with `:invalid_request` **before I/O** — invariant 6
5. an all-strings batch returns exactly `length(input)` results — invariant 3
6. `:index` values are exactly `0..length-1` — invariant 4
7. every result's `:flagged` is a boolean, and `categories`/`category_scores` are maps with binary keys
8. `request.metadata` round-trips onto `response.metadata` unchanged — invariant 8
9. `opts[:request_id]` is preserved onto `response.request_id` — invariant 7
10. a multimodal input (one text + one `%ImagePart{}`) returns exactly one result — invariant 3, multimodal arm

**Every case is driven by the caller-supplied implementation and asserts unconditionally.** No case body may be gated on an optional fixture: per agent-spec/DESIGN.md rule 26, `if fixture = optional() do … end` compiles to an assertion-free test that ExUnit reports green, and this package is *published*. Case 10's `%ImagePart{}` is built inline from `ALLM.Image.from_binary/2` — no fixture file, no `Req.Test` stub, no sister-module lookup.

**Compilation constraint** (`embedding_adapter_conformance.ex:56-62`): this package compiles **before** `allm` in a consuming project's build, so the harness module body must not reference `ALLM.*` functions directly — every such call happens inside the `using/1` `quote`.

**The moduledoc carries a `## What this suite does NOT bind` section**, copying the honesty of its embeddings sibling (`embedding_adapter_conformance.ex:40-54`). For any adapter whose `moderate/2` short-circuits to a script — `FakeModeration` and `ALLM.Providers.OpenAI.Moderation` — the success path returns the harness's own results verbatim and **never reaches that adapter's `decode_response/4`**. Cases 2 and 5–10 therefore do not bind invariants 3 and 4 for those adapters; they bind them only for an adapter that implements `moderate/2` itself. Invariant 3/4 conformance for the OpenAI adapter is bound instead by the `decode_response/4` fixture tests in 22.4. The section must say so in the same words: *do not read a green run of this suite as evidence that a provider's decoder indexes its response correctly.*

**Three companion files ship with the harness**, matching the embeddings family exactly:

| File | Role |
|------|------|
| `conformance/test/support/fixtures/scripted_moderation_stub.ex` | The harness's own self-test vehicle. `@max_batch_size 4` — deliberately small, mirroring the embedding stub's `8` (`scripted_embedding_stub.ex:44`), so the `:batch_too_large` boundary is exercisable without building a large list. Unlike a scripted provider adapter, this stub evaluates its gates **ahead of** the script. |
| `conformance/test/allm/test/moderation_adapter_conformance_test.exs` | The three harness meta-invariants: `case_count/0 == 10`; the injected `describe` block defines exactly `case_count/0` tests (via `__ex_unit__().tests` filtered on the describe name); `using/1` raises `KeyError` when `:moderation_adapter` is missing. |
| `test/allm/providers/openai/moderation_conformance_test.exs` | The main-repo invocation — a `use ExUnit.Case, async: true` + `use ALLM.Test.ModerationAdapterConformance, moderation_adapter: ALLM.Providers.OpenAI.Moderation` two-liner whose `@moduledoc` states which invariants it does and does not bind for this adapter. |

---

## Module Tree

Every file the phase touches, with its sub-phase. Test files mirror source 1:1.

```
lib/allm/
├── moderation_request.ex                      (NEW — 22.1)
├── moderation_result.ex                       (NEW — 22.1)
├── moderation_response.ex                     (NEW — 22.1)
├── moderation_adapter.ex                      (NEW — 22.2)
├── error/
│   ├── moderation_adapter_error.ex            (NEW — 22.1)
│   ├── engine_error.ex                        (MODIFY — 22.1, +:no_moderation_adapter in both lists)
│   └── validation_error.ex                    (MODIFY — 22.1, +:invalid_moderation_request in both lists)
├── serializer.ex                              (MODIFY — 22.1, +4 @known_modules entries)
├── validate.ex                                (MODIFY — 22.1, +moderation_request/1 + rule block)
├── engine.ex                                  (MODIFY — 22.2, +:moderation_adapter at every site in the Engine-extension table)
├── capability.ex                              (MODIFY — 22.3, +preflight_moderation/2 + private block + moduledoc bullet)
├── telemetry.ex                               (MODIFY — 22.3, +:moderate span name + moduledoc table row)
└── providers/
    ├── fake_moderation.ex                     (NEW — 22.2)
    └── openai/
        └── moderation.ex                      (NEW — 22.4; MODIFY — 22.5, image blocks + MIME gate)

lib/allm.ex                                    (MODIFY — 22.3, moderate/3 + moderation_request/2 + internals)

conformance/
├── lib/allm/test/
│   └── moderation_adapter_conformance.ex      (NEW — 22.2)
└── test/
    ├── support/fixtures/
    │   └── scripted_moderation_stub.ex        (NEW — 22.2, @max_batch_size 4, gates before script)
    └── allm/test/
        └── moderation_adapter_conformance_test.exs  (NEW — 22.2, three harness meta-invariants)

test/allm/
├── moderation_request_test.exs                (NEW — 22.1)
├── moderation_result_test.exs                 (NEW — 22.1)
├── moderation_response_test.exs               (NEW — 22.1)
├── error/moderation_adapter_error_test.exs    (NEW — 22.1)
├── validate_moderation_request_test.exs       (NEW — 22.1)
├── moderation_adapter_test.exs                (NEW — 22.2, FakeModeration conformance invocation + behaviour surface)
├── allm_moderate_test.exs                     (NEW — 22.3; MODIFY — 22.5, multimodal cardinality + telemetry)
├── capability_moderation_test.exs             (NEW — 22.3)
└── providers/
    ├── fake_moderation_test.exs               (NEW — 22.2)
    └── openai/
        ├── moderation_test.exs                (NEW — 22.4, seam units)
        ├── moderation_wire_test.exs           (NEW — 22.4, Req.Test + provenance)
        ├── moderation_conformance_test.exs    (NEW — 22.4, harness invocation two-liner)
        └── moderation_vision_test.exs         (NEW — 22.5)

test/allm/engine_test.exs                      (MODIFY — 22.2, :moderation_adapter accept/reject/round-trip)

test/support/
├── fake_moderation_fixtures.ex                (NEW — 22.2)
└── openai_fixtures.ex                         (MODIFY — 22.4, moderation_recorded/1 + moderation_synthesized/1,
                                                reusing the single drop_comment/1 at openai_fixtures.ex:165)

test/fixtures/openai/README.md                  (MODIFY — 22.4, add a moderations section)

test/fixtures/openai/moderations/
├── recorded/
│   ├── single_clean.json                      (NEW — 22.4, recorder-written)
│   ├── batch_mixed.json                       (NEW — 22.4, recorder-written)
│   ├── flagged_violence.json                  (NEW — 22.4, recorder-written)
│   ├── error_400_bad_model.json               (NEW — 22.4, recorder-written)
│   └── multimodal_text_image.json             (NEW — 22.5, recorder-written)
└── synthesized/
    ├── null_illicit_categories.json           (NEW — 22.4, `_comment` marker)
    ├── missing_applied_input_types.json       (NEW — 22.4, `_comment` marker)
    ├── error_401.json                         (NEW — 22.4, `_comment` marker, planted key token)
    └── error_429.json                         (NEW — 22.4, `_comment` marker)

scripts/
└── record_openai_moderation_fixtures.exs      (NEW — 22.4; MODIFY — 22.5, multimodal arm)

test/
├── layer_a_docs_test.exs                      (MODIFY — 22.1, +3 @layer_a entries)
├── allm_facade_doctest_inventory_test.exs     (MODIFY — 22.3, +moderate: 3, moderation_request: 2)
├── guides_test.exs                            (MODIFY — 22.6, +moderation.md in @guides)
└── guides_doctest_test.exs                    (MODIFY — 22.6, +doctest_file/1 line)

guides/moderation.md                           (NEW — 22.6)
examples/
├── 19_moderate_text.exs                       (NEW — 22.6, `# Provider: openai`)
├── 20_moderate_image.exs                      (NEW — 22.6, `# Provider: openai`)
├── _helpers.exs                               (MODIFY — 22.6, +moderation_adapter/moderation_default_model)
└── README.md                                  (MODIFY — 22.6, @providers table + script list)

mix.exs                                        (MODIFY — 22.1/22.2/22.4/22.6, see the gate table below)
ASKS.md                                        (MODIFY — 22.4 [CARRY] ticket, 22.6 @guides-divergence ticket)
CHANGELOG.md                                   (MODIFY — 22.6)
steering/allm_engine_session_streaming_spec_v0_2.md  (MODIFY — 22.6, §39 + §27/§29/§35.7 amendments)
```

### Repo-wide audit-gate obligations

Per agent-spec/DESIGN.md, checked against every new artifact. A row deferred to a later sub-phase is structurally wrong.

| Gate | Fails | Fires in | Row |
|------|-------|----------|-----|
| `test/groups_for_modules_audit_test.exs` | **closed** | 22.1, 22.2, 22.4 | `mix.exs` `docs.groups_for_modules` — **six** modules across **four** groups: `ModerationRequest`/`Result`/`Response` → `"Data types"` (`mix.exs:142-164`); `ALLM.Error.ModerationAdapterError` → `Errors` (`:182-191`); `ALLM.ModerationAdapter` → `Behaviours` (`:111-118`); `ALLM.Providers.OpenAI.Moderation` + `ALLM.Providers.FakeModeration` → `Providers` (`:119-137`). The gate is a **bidirectional set difference** (`groups_for_modules_audit_test.exs:47-61`), so an entry naming a module that does not yet exist fails just as loudly as a missing one — register each module in the sub-phase that creates it, never earlier. |
| `test/layer_a_docs_test.exs` | **open** | 22.1 | `@layer_a` (`test/layer_a_docs_test.exs:14-36`) — three struct entries. **PHASE_20 shipped three Layer A structs unregistered here, all three carrying banned tokens, fully green.** |
| `test/allm_facade_doctest_inventory_test.exs` | **open** | 22.3 | `@public_facade` (`test/allm_facade_doctest_inventory_test.exs:16-40`) — `moderate: 3`, `moderation_request: 2`. **The gate is one-directional**: it asserts `@public_facade ⊆ ALLM.__info__(:functions)` (`:58-66`) and never the converse, so `moderate/3` added without touching the literal ships undoctested and green. |
| `test/package_files_extras_consistency_test.exs` | **closed** | 22.6 | `mix.exs` `@guides` (`:65-76`) → flows into `docs.extras` (`:82`); `package.files` (`:61`) already names the `guides` directory wholesale |
| `test/guides_test.exs` + `test/guides_doctest_test.exs` | **open** | 22.6 | each file's own list — `test/guides_test.exs:18-28` and `test/guides_doctest_test.exs:10-18` |

**Pre-existing divergence, observed not fixed (2026-08-31):** `mix.exs`'s `@guides` (`:65-76`) contains `guides/fakes.md`; `test/guides_test.exs`'s `@guides` (`:18-28`) does not. Two lists with the same name and different membership, exactly the fail-open hazard CLAUDE.md describes. Out of this phase's tree — filed as an `/asks` ticket in 22.6 with the self-scoring predicate: *`mix.exs @guides` and `test/guides_test.exs @guides` must name the same set*.

### Path-existence sanity check

Run before locking. Every parent directory of a NEW path must already exist except the one `mkdir` below.

```bash
ls -d lib/allm lib/allm/error lib/allm/providers lib/allm/providers/openai \
      conformance/lib/allm/test conformance/test/support/fixtures conformance/test/allm/test \
      test/allm test/allm/error test/allm/providers \
      test/allm/providers/openai test/support scripts guides examples test/fixtures/openai
```

**Run 2026-08-31: all sixteen exist.** `test/fixtures/openai/moderations/{recorded,synthesized}` are the only directories this phase creates.

Fixtures are **`.json`, not `.exs`** — the convention since Phase 14/15 (`test/fixtures/openai/embeddings/{recorded,synthesized}/*.json`).

---

## Phases

**`README.md` is out of tree for all seven sub-phases.** CLAUDE.md makes this a blocking pre-commit invariant after six consecutive recurrences, and a phase that adds a whole capability family is exactly the shape that tempts a README rewrite. At 22.1 start, run `git stash push -- README.md`. Any README change is a stand-alone `[DOC]` commit or an `/asks` ticket.

### Phase 22.1 — Layer A moderation data types (Layer A)

**Goal:** Three serializable structs, one error type, one validator, the registry and enum edits — with no adapter, no engine field, and no façade.

#### 22.1.1 Test Plan (write first)

`test/allm/moderation_request_test.exs` (NEW):
- `new/1 defaults input to [], model to nil, options and metadata to %{}`
- `new/1 with an unknown key raises KeyError`
- `new/1 accepts input: [] — the validator, not the constructor, rejects it`
- `multimodal?/1 is false for an all-strings input`
- `multimodal?/1 is true when any element is an %ImagePart{}`
- `multimodal?/1 is false for input: []`
- `multimodal?/1 returns false for a non-list :input (42, %{}, "raw") without raising` — it runs in `:start` telemetry metadata before validation

`test/allm/moderation_result_test.exs` (NEW):
- `new/1 without :flagged raises ArgumentError` — `@enforce_keys`, the idiom named in the contract
- `flagged_categories/1 returns only true-valued keys, sorted`
- `flagged_categories/1 returns [] when nothing is flagged`
- `score/2 returns the float for a present category`
- `score/2 returns nil for an absent category`

`test/allm/moderation_response_test.exs` (NEW):
- `flagged?/1 is true when any result is flagged`
- `flagged?/1 is false for an empty results list`
- `flagged_categories/1 unions across results, deduplicated and sorted`

`test/allm/error/moderation_adapter_error_test.exs` (NEW):
- `legal_reasons/0 returns 11 atoms`
- `new/2 with an off-enum reason raises ArgumentError naming the legal set`
- `Exception.message/1 on a struct built without :message returns the default`
- `Exception.message/1 on a raw %ModerationAdapterError{} struct returns a fallback` — the `message/1` catch-all clause
- `new/2 with :provider set produces the provider-suffixed default message`

`test/allm/validate_moderation_request_test.exs` (NEW) — one test per vocabulary row plus accumulation:
- `:ok for a valid all-strings request`
- `:ok for a valid request containing an %ImagePart{}` — the union arm is live from 22.1
- `input: %{} hard-rejects with exactly [{:input, :invalid_shape}] and no other errors`
- `input: [] yields {:input, :empty}`
- `input: ["", "ok"] yields {[:input, 0], :empty}`
- `input: [42] yields {[:input, 0], :invalid_item}`
- `model: 42 yields {:model, :invalid_shape}`
- `two independent violations accumulate into one error list`

Serializability (in the three struct test files) — **blocking**, per Layer A rules:
- each struct round-trips `:erlang.term_to_binary/1 |> :erlang.binary_to_term/1`
- each struct round-trips `Serializer.to_json!/1 |> Serializer.from_json/1`
- **a `%ModerationRequest{}` whose `:input` contains an `%ImagePart{}` round-trips through JSON** — pins `decode_input/1`'s `hydrate/1` routing
- **a `%ModerationResult{}` with a non-integral score (`0.37701736389561064`) and a `nil`-free 13-key category map round-trips byte-identically** — pins Decision #2's identity claim
- **a `%ModerationResponse{}` carrying two nested `%ModerationResult{}` structs round-trips through JSON as structs, not raw maps** — pins `decode_results/1`'s `Serializer.hydrate/1` routing
- **a `%ModerationResponse{provider: :openai}` round-trips with `:provider` still an atom** — pins `to_atom_field/1`
- `a JSON payload whose "flagged" key is absent decodes to flagged: false, not nil` — pins `decode_flagged/1`'s fail-closed repair
- `%ModerationAdapterError{}` round-trips through both

Doctests: every public function per the Definition of Done.

#### 22.1.2 Implementation Checklist

- [ ] `lib/allm/moderation_request.ex` per the contract block, including `decode_input/1` and `multimodal?/1`
- [ ] `lib/allm/moderation_result.ex` per the contract block, including `@enforce_keys [:flagged]`
- [ ] `lib/allm/moderation_response.ex` per the contract block
- [ ] `lib/allm/error/moderation_adapter_error.ex`, structurally mirroring `lib/allm/error/embedding_adapter_error.ex:1-164`
- [ ] Extend `EngineError` and `ValidationError` enums — **both the `@type` union and the runtime list** in each (per the enum-extension table)
- [ ] `Validate.moderation_request/1` + the `# Internal: moderation_request rules` block at the file bottom
- [ ] Register all four modules in `Serializer.@known_modules`
- [ ] Add three entries to `test/layer_a_docs_test.exs` `@layer_a` — **fail-open gate**
- [ ] `mix.exs` `docs.groups_for_modules`: three entries in `"Data types"` (`:142-164`) and `ALLM.Error.ModerationAdapterError` in `Errors` (`:182-191`) — **fail-closed gate**, and bidirectional, so register exactly the modules this sub-phase creates
- [ ] `@moduledoc`s carry no banned tokens (`mix run scripts/audit_user_docs.exs | grep moderation` — must be empty; the bare script exits **1** pre-existing on `main`, see 22.1.3)

#### 22.1.3 Verification

```bash
mix test test/allm/moderation_request_test.exs test/allm/moderation_result_test.exs \
         test/allm/moderation_response_test.exs \
         test/allm/error/moderation_adapter_error_test.exs \
         test/allm/validate_moderation_request_test.exs
mix test                        # full suite green
mix test --seed 0               # ordering-stable
mix format --check-formatted
mix credo --strict
mix dialyzer

# Self-scoring predicate — must come back empty.
mix run scripts/audit_user_docs.exs | grep moderation
```

> **CORRECTED 2026-08-31 (fix pass, functional review F2):** this block
> originally listed `mix run scripts/audit_user_docs.exs` bare, among gates that
> must exit 0. **It cannot pass.** The script exits **1 pre-existing on `main`**
> — 10 hits across 5 files (`guides/fakes.md` 4, `lib/allm/engine.ex` 3,
> `lib/allm/providers/fake.ex` 1, `lib/allm/providers/fake_images.ex` 1,
> `lib/allm/validate.ex:19` 1), all outside this phase, and 22.7 separately owns
> cleaning `guides/fakes.md`. A gate that can only ever be red teaches every
> implementer to ignore its exit status. Per CLAUDE.md's self-scoring-predicate
> rule the gate is now `… | grep moderation`, which must be **empty** — it means
> something, it survives any change to the standing baseline, and it does not
> decay the way "diff against the recorded hit set" does. The same predicate is
> the one 22.2–22.7 should use; a non-zero exit from the bare script is not a
> sub-phase's own regression. (The bare form appeared **only** here, not in
> every sub-phase Verification block — F2's wider claim was re-measured and does
> not hold. `grep -n audit_user_docs steering/2026-08-31_PHASE_22_moderation.md`
> returns three lines: this one, the 22.1.2 checklist item, and 22.6.1's
> guide-structural gate, which is correctly scoped to `moderation.md` alone.)

**Success criterion:** all five new test files pass; `mix test` reports zero failures and zero warnings; `test/layer_a_docs_test.exs` and `test/groups_for_modules_audit_test.exs` both pass **with the new modules registered**, verified by temporarily removing one entry and confirming the gate goes red.

> **CORRECTED 2026-08-31 (22.1):** the remove-an-entry check binds only for
> `test/groups_for_modules_audit_test.exs`. That gate is fail-CLOSED and
> bidirectional, and dropping `ALLM.ModerationResult` from `mix.exs` does go
> red (`Public lib/ modules missing from groups_for_modules:
> [ALLM.ModerationResult]`). `test/layer_a_docs_test.exs` is fail-OPEN — as
> this document's own obligations table says — so dropping an entry from
> `@layer_a` produces *silence*, not a failure: the suite stays green and only
> the test count moves (25 → 24). Registration there is verified by counting
> the generated per-module tests, never by removing an entry. The same
> correction applies to the Definition-of-Done line "each fail-open gate
> verified by temporarily removing an entry and confirming it goes red" —
> which is unsatisfiable as written for every fail-open gate in the table.

#### 22.1.4 Binding on later sub-phases

* **The `item()` union is written multimodal-aware in 22.1, so 22.5 changes no Layer A or validator code.** `@type item :: String.t() | ALLM.ImagePart.t()`, the `%ImagePart{}` arm of `[:input, idx] :invalid_item`, `multimodal?/1`, and the cardinality invariant all land here. Binds **22.5**, whose Module Tree therefore lists no `lib/allm/moderation_request.ex` or `lib/allm/validate.ex` row — and binds **Alternative E**, whose severability claim is scoped by exactly this list.
* **`ModerationResult.decode_flagged/1` repairs where every sibling passes through.** Binds any later sub-phase or phase adding a `__from_tagged__/1` clause to these structs: the fail-closed repair is deliberate and scoped to `:flagged` alone.

---

### Phase 22.2 — Behaviour, engine field, Fake, conformance (Layer B)

**Goal:** The runtime contract and its reference implementation, with no façade.

#### 22.2.1 Test Plan (write first)

`test/allm/moderation_adapter_test.exs` (NEW):
- `behaviour_info(:callbacks) contains moderate/2, max_batch_size/0, prepare_request/2`
- `behaviour_info(:optional_callbacks) == [prepare_request: 2]`

`test/allm/providers/fake_moderation_test.exs` (NEW):
- `with no script, returns one unflagged result per input`
- `with no script, every result carries the 13 omni category names`
- `{:ok, results} entry returns those results verbatim`
- `{:flagged, ["violence"]} synthesizes one flagged result with that category true`
- `{:error, err} entry returns the struct verbatim`
- `{:retry_until_call, 3} returns :rate_limited for calls 1-2 then succeeds` — driven against `moderate/2` **directly** with an explicit `adapter_opts[:cursor_key]`, never through the façade, whose `Retry.run/3` collapses the sequence (CLAUDE.md). A leading non-error entry is load-bearing: it forces `advance` to WRITE the slot `peek` later READS.
- `input: [] returns :invalid_request before consuming a script entry`
- `over max_batch_size returns :batch_too_large with metadata.count and metadata.max`
- `two content-equal engines with distinct :id values do not share a cursor`
- `multimodal input returns exactly one result`

`test/allm/engine_test.exs` (MODIFY):
- `new/1 accepts moderation_adapter: SomeModule`
- `new/1 with moderation_adapter: {Mod, []} raises ArgumentError` — `@module_fields`
- `an engine carrying :moderation_adapter round-trips through JSON` — `restore_module/1`
- `resolve_params/2 does not leak :moderation_adapter into params` — `@engine_field_keys`

`test/allm/moderation_adapter_test.exs` (NEW) — mirrors `test/allm/embedding_adapter_test.exs`, which holds **both** the behaviour-surface tests and the reference-implementation conformance invocation (`use ALLM.Test.ModerationAdapterConformance, moderation_adapter: ALLM.Providers.FakeModeration` at the top of the module, `embedding_adapter_test.exs:9`):
- `ALLM.Providers.FakeModeration passes all 10 conformance cases` — the reference-implementation certification
- `behaviour_info(:callbacks) contains moderate/2, max_batch_size/0, prepare_request/2`
- `behaviour_info(:optional_callbacks) == [prepare_request: 2]`
- `a module implementing only moderate/2 + max_batch_size/0 compiles without warning` — via `ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)`, the third surface test the sibling carries (`embedding_adapter_test.exs:28-45`) that pins `@optional_callbacks` from the implementer's side

Conformance harness self-test (`conformance/test/allm/test/moderation_adapter_conformance_test.exs`), driven by `ScriptedModerationStub`, never by `FakeModeration`:
- `case_count/0 == 10`
- `the injected describe block defines exactly case_count/0 tests`
- `using/1 raises KeyError when the :moderation_adapter opt is missing`

#### 22.2.2 Implementation Checklist

- [ ] `lib/allm/moderation_adapter.ex` — three callbacks, the numbered invariant list, the `## Minimum impl skeleton`, the **"Cleanup invariant: none."** paragraph
- [ ] `lib/allm/engine.ex` — `:moderation_adapter` at **every** site in the Engine-extension table, site 8 (`resolve_params/2`'s hand-maintained prose deny-list) included
- [ ] `lib/allm/providers/fake_moderation.ex` — script vocabulary, pre-flight gates before script consumption, the two-source cursor
- [ ] `test/support/fake_moderation_fixtures.ex` — engine + script builders
- [ ] `conformance/lib/allm/test/moderation_adapter_conformance.ex` — `@case_count 10`, `case_count/0`, `using/1`, the `## What this suite does NOT bind` section; **no case body gated on an optional fixture**
- [ ] `conformance/test/support/fixtures/scripted_moderation_stub.ex` (`@max_batch_size 4`, gates ahead of the script) and `conformance/test/allm/test/moderation_adapter_conformance_test.exs` (three meta-invariants)
- [ ] `mix.exs` `groups_for_modules`: `ALLM.ModerationAdapter` → `Behaviours`, `ALLM.Providers.FakeModeration` → `Providers`
- [ ] Confirm no `async: true` module in this sub-phase calls `Keys.put/2`, `Logger.configure/1`, `System.put_env/2`, or `:telemetry.attach/4`

#### 22.2.3 Verification

```bash
mix test test/allm/moderation_adapter_test.exs \
         test/allm/providers/fake_moderation_test.exs test/allm/engine_test.exs
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer

# conformance/ is a SECOND Mix project — the main project's gates do not cover
# it, and this sub-phase's Module Tree touches it.
cd conformance && mix test && mix credo --strict && mix format --check-formatted

# Process-global-mutation audit — must list only `async: false` modules.
grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/
```

**CLAUDE.md's "pre-existing `conformance/` format failure" no longer exists — do not act on it.** CLAUDE.md states that `conformance/lib/allm/test/image_adapter_conformance.ex:91-92` has failed `mix format --check-formatted` since Phase 14.1 (`b18ebeb`) and must be fixed as a separate `[CHORE]` commit. Verified 2026-08-31: `cd conformance && mix format --check-formatted` exits **0**, and `git log -- conformance/lib/allm/test/image_adapter_conformance.ex` shows `6282322 [OTHR] Clean all compile, test, docs, and conformance warnings` landed after `b18ebeb`. Lines 91-92 are an `if unsupported do` / `ImageRequest.new(...)` pair, not a formatting defect. Acting on the instruction would produce an empty `[CHORE]` commit. The stale claim is struck from CLAUDE.md in 22.6 — this is itself an instance of CLAUDE.md's own rule that *"a file:line cite inherited from an instruction file or a prior design is not pre-verified."*

**Success criterion:** `FakeModeration` passes all 10 conformance cases; both Mix projects are green on all four gates with **no** `[CHORE]` commit needed; the process-global grep returns only `async: false` modules.

#### 22.2.4 Binding on later sub-phases

* **Behaviour invariants 5 and 6 require both gates ahead of `ALLM.Keys.fetch!/2`.** Inherited verbatim from Phase 20.2's constraint (`lib/allm/embedding_adapter.ex:39-43`). Binds **22.4**, whose `moderate/2` gate order is `empty-input → batch-size → key → HTTP`, and whose conformance cases 3 and 4 run with **no key in the environment**. A 22.4 implementation resolving the key first passes its own wire tests and fails conformance only in a keyless CI.
* **`@case_count 10` and the case-to-invariant mapping are frozen here.** Binds **22.5**: case 10 is the multimodal arm, written in 22.2 against `FakeModeration` and re-run unchanged in 22.5. Adding a case without bumping the attribute breaks the harness self-test.
* **`build_moderate_dispatch_opts/3` must inject `adapter_opts[:cursor_key]` via `ALLM.Engine.put_cursor_key/2`.** Binds **22.3**. `FakeModeration`'s moduledoc (`lib/allm/providers/fake_moderation.ex:70-73`) publishes the engine's `:id` as precedence source 2 for the script cursor *and* (after the 22.2 fix pass) for the `{:retry_until_call, n}` budget; the façade is the only thing that can supply it. Mirror `lib/allm.ex:1433-1450`. Omitting it makes every façade-driven moderation script share one cursor slot across content-equal engines, silently.
* **Behaviour invariants 9 and 10 (`request_timeout` → `:timeout`; `prepare_request/2` semantics) were appended in the 22.2 fix pass.** Binds **22.4**: the real adapter must honour `opts[:request_timeout]` and convert the expiry to `:timeout`, which is the reason `ALLM.Error.ModerationAdapterError` publishes and 22.3's `@retryable_moderation_reasons` retries. 1–8 stay frozen; anything further is appended at 11.
* **Invariant 5 measures ITEMS, not raw list elements.** Binds **22.5**: a multimodal `:input` is one item, so the batch gate never rejects it, and conformance case 10's two-element list is deliberately unclamped. Binds **22.4** too — its `moderate/2` gate must not read `length(request.input)`.
* **Conformance cases 5, 6 and 7 size their input as `min(<wanted>, adapter.max_batch_size())`.** Binds **22.4**: whatever the ladder probe returns — including `1` — the published suite certifies a conforming adapter rather than failing it on its own correct `:batch_too_large`. Before the 22.2 fix pass those cases used literals `4`/`3`/`2` and went red at caps 3/2/1 respectively (measured). Do **not** reintroduce a literal input size in any case.
* **`FakeModeration.@adapter_max_batch_size 32` is the number conformance case 3 crosses; the OpenAI adapter's is independent.** Binds **22.4**, whose `@adapter_max_batch_size` comes from the ladder probe and may differ by orders of magnitude. Nothing may assume the two are equal — which is why case 3 derives its oversized input from `adapter.max_batch_size()`.

---

### Phase 22.3 — Façade, telemetry, capability pre-flight (Layer C)

**Goal:** `ALLM.moderate/3` end-to-end over `FakeModeration`, with the gate order, the retry wrap, and the span.

#### 22.3.1 Test Plan (write first)

`test/allm/allm_moderate_test.exs` (NEW):

*Input shapes*
- `moderate/3 with a binary wraps it into a one-element batch`
- `moderate/3 with a list of binaries dispatches them as a batch`
- `moderate/3 with a %ModerationRequest{} dispatches it verbatim and does NOT merge opts onto it`

*Gate order* — each asserted in isolation and then in combination, since the ordering is the contract:
- `nil adapter returns {:error, %EngineError{reason: :no_moderation_adapter}}`
- `nil adapter PLUS an invalid request still returns :no_moderation_adapter` — gate 1 precedes gate 2
- `input: [] returns {:error, %ValidationError{reason: :invalid_moderation_request}}`
- `the :start telemetry event fires even when the adapter is missing`
- `the :start event fires with a non-list :input without raising` — `input_count/1`'s tolerant clause

*Opt handling*
- `:model / :options / :metadata lift onto the built request`
- `an unknown opt is forwarded to the adapter untouched`
- `a request-field opt is NOT forwarded to the adapter` — `drop_moderation_request_opts/1`
- `stream: true is silently dropped and does not error`
- `opts[:request_id] wins over the auto-generated id and lands on response.request_id`
- `an adapter-populated response.request_id is preserved`
- **`@moderation_request_field_opts equals the %ModerationRequest{} field set minus :input`** — the consumer/producer symmetry invariant, asserted against `Map.keys(%ModerationRequest{})`, not a hand-copied list

*Retry and invariant enforcement*
- `a :rate_limited error retries and then succeeds` — via `FakeModeration`'s `{:retry_until_call, n}` through the façade
- `a :invalid_request error does NOT retry`
- `an adapter returning a bare map raises ArgumentError naming the adapter and invariant 2`

*Telemetry* — via `test/support/telemetry_capture.ex` (per-process filter; **never** a bare `:telemetry.attach/4` in an `async: true` module):
- `:stop measurements carry result_count and flagged_count on success`
- `:stop measurements carry result_count: 0 and flagged_count: 0 on error` — the stability rule
- `:stop metadata carries usage: nil on BOTH paths` — Decision #6
- `:exception fires when the adapter raises`

`test/allm/capability_moderation_test.exs` (NEW):
- `preflight_moderation/2 returns :ok when the catalog is absent` — via the `:force_capability_absent` override
- `preflight_moderation/2 returns :ok for a bare model string`
- `moderation_enabled: false yields {[:moderation_enabled], :moderation_disabled}`
- `a string-keyed "moderation_enabled" => false capability map yields the same error` — JSON-rehydrated tolerance
- `a missing moderation_enabled key is not a rejection`

#### 22.3.2 Implementation Checklist

- [ ] `ALLM.moderation_request/2` + `@moderation_request_field_opts` allow-list
- [ ] `ALLM.moderate/3` — `@doc` with the sections named in Decisions #4, #5, #6, #11 plus two doctests (happy path over `FakeModeration`; the `:no_moderation_adapter` gate), `@spec`, head + three clauses
- [ ] Internals: `@retryable_moderation_reasons`, `drop_moderation_request_opts/1`, `do_moderate/3`, `do_moderate_body/5` (nil-adapter clause **first**; the `Retry.run/3` wrap in its body per the contract's placement table), `build_moderate_dispatch_opts/3` (**no** `:retry_policy` key; **must** end with `Engine.put_cursor_key(engine)` — see the Layer C contract), `dispatch_moderate_attempt/3` (per-attempt closure + invariant-2 raise), `fill_moderation_request_id/2`, `moderate_stop_extras/1`
- [ ] Reuse the existing `augment_retry_policy/2` (`lib/allm.ex:1281-1291`) — **do not add a third variant**
- [ ] `ALLM.Capability.preflight_moderation/2` + the `# Private — moderation preflight` block + moduledoc bullet (the "Five helpers" list becomes six)
- [ ] `ALLM.Telemetry` — `:moderate` in both `@type span_name` and `@valid_span_names`, plus the moduledoc table row
- [ ] `lib/allm.ex` — "When to reach for what" table row and both alias blocks
- [ ] `test/allm_facade_doctest_inventory_test.exs` `@public_facade` — **fail-open gate**

#### 22.3.3 Verification

```bash
mix test test/allm/allm_moderate_test.exs test/allm/capability_moderation_test.exs
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
```

**Success criterion:** every gate-order test passes in isolation *and* in combination; the symmetry test computes its expectation from `Map.keys/1` rather than a literal; both façade doctests run green under `mix test`.

#### 22.3.4 Binding on later sub-phases

* **The façade's retry budget and the adapter's own `ALLM.Retry.run/3` loop NEST, and the two budgets multiply.** `build_moderate_dispatch_opts/3` drops only `:stream` and the three request-field opts — `opts[:retry]` is forwarded to the adapter verbatim — and every existing ALLM adapter reads it and wraps its own HTTP call (`lib/allm/providers/openai/embeddings.ex:522`, `lib/allm/providers/voyage/embeddings.ex:749`, `lib/allm/providers/openai.ex:539`). Binds **22.4**: `moderate/3`'s `## Retry` `@doc` now states the nesting and its per-reason arithmetic (with the default 3-attempt policy at each layer, a reason retryable at *both* costs up to **9** adapter calls; one retryable at only one layer costs up to **3**) instead of promising a single attempt count. If 22.4's adapter runs its own `Retry.run/3`, that `@doc` is already correct and must not be re-flattened to "3 attempts"; if 22.4 deliberately does **not** retry internally, amend the paragraph rather than leaving the multiplier claim standing. This is CLAUDE.md's documented `embed/3` hazard (`:timeout` costs 9 attempts per chunk while every other retryable reason costs 3) arriving on the moderation path. *(Added by the 22.3 fix pass, from code review F5.)*
* **The `@public_facade` gate is still one-directional after 22.3.** The row in "Repo-wide audit-gate obligations" above is unchanged: `test/allm_facade_doctest_inventory_test.exs` asserts `@public_facade ⊆ ALLM.__info__(:functions)` and never the converse. 22.3 added `moderate: 3` and `moderation_request: 2` to the literal but did not close the fail-open direction. Deferred to **22.7** as a `[CHORE]`: add a converse test grouping `ALLM.__info__(:functions)` by name (default-arity heads make a bare arity comparison wrong) with an explicit `@excluded %{name => "reason"}` map, self-scored by *removing `moderate: 3` from `@public_facade` must turn the suite red*. *(Added by the 22.3 fix pass, from code review F4.)*

---

### Phase 22.4 — `ALLM.Providers.OpenAI.Moderation`, text input (Layer B)

**Goal:** The real adapter against `/v1/moderations`, with every **inferred** wire-field-map row falsified or confirmed by a live probe.

#### 22.4.1 Test Plan (write first)

`test/allm/providers/openai/moderation_test.exs` (NEW) — pure seam units, no HTTP:
- `to_json_body/2 emits input as an array of strings`
- `to_json_body/2 omits "model" entirely when request.model is nil`
- `to_json_body/2 includes "model" when set`
- `to_json_body/2 merges request.options onto the body`
- `decode_response/4 builds one %ModerationResult{} per results entry with sequential indices`
- `decode_response/4 coerces an integral score to a float`
- `decode_response/4 drops null-valued category keys` — against `synthesized/null_illicit_categories.json`
- `decode_response/4 yields applied_input_types: %{} when the key is absent` — against `synthesized/missing_applied_input_types.json`
- `decode_response/4 populates provider: :openai`
- `decode_response/4 falls back to the x-request-id header when opts[:request_id] is absent`
- `to_moderation_adapter_error/4 maps 401 → :authentication_failed, 429 → :rate_limited (with retry_after_ms), 400 → :invalid_request, 500 → :provider_unavailable`
- `max_batch_size/0 returns a pos_integer`
- `moderate/2 rejects input: [] with :invalid_request before resolving a key` — asserted with **no key in the environment**, per invariant 5/6
- `moderate/2 rejects oversized input with :batch_too_large before resolving a key`

`test/allm/providers/openai/moderation_wire_test.exs` (NEW) — `Req.Test` stubs + provenance:
- `moderate/2 sends POST to https://api.openai.com/v1/moderations`
- `moderate/2 sends Authorization: Bearer <key>`
- `a clean recorded response decodes to flagged: false` — `recorded/single_clean.json`
- `a flagged recorded response decodes with "violence" in flagged_categories/1` — `recorded/flagged_violence.json`
- `a batch recorded response decodes to N results in index order` — `recorded/batch_mixed.json`
- `a recorded 400 decodes to :invalid_request` — `recorded/error_400_bad_model.json`
- `redact_key_material/1 replaces an sk- token in a 401 message` — `synthesized/error_401.json`, whose planted key-shaped token is the redactor's target
- **`the Gemini and Voyage key patterns match nothing in the same 401 fixture`** — the companion test that makes an inherited-verbatim regex fail loudly
- **Per-file negative provenance, one test per `recorded/` fixture:** `File.read!/1 |> Jason.decode!/1` then `refute Map.has_key?(raw, "_comment")`, with a failure message naming the recorder invocation. Read the **raw bytes** — an assertion made through the loader calls `drop_comment/1` and is tautological.
- **Positive provenance, one test per `synthesized/` fixture:** raw read, `assert Map.has_key?(raw, "_comment")`

#### 22.4.2 The live wire probe — four required parts

`scripts/record_openai_moderation_fixtures.exs`, modelled on `scripts/record_voyage_embeddings_fixtures.exs` (the canonical four-part implementation).

1. **Negative control.** Every "the API accepts X" arm is paired, in the same run, with an invented-field arm (`{"input": "hi", "not_a_real_field": true}`). Acceptance is evidence of schema membership only once the API is shown to reject unknown fields.

> **CORRECTED 2026-08-31 (22.4 probe).** This clause said "If the invented field is *accepted*, every acceptance arm in the run is void and the script halts saying so." The probe ran and **the invented field IS accepted** — `/v1/moderations` returns 200 and silently ignores unknown top-level fields. Halting would make the recorder permanently unrunnable against a permissive-by-design endpoint, so the arm's expectation was inverted to the observed truth (`expect: 200`) and it now guards the *opposite* transition: the day OpenAI starts validating unknown arguments, the recorder fails. The substantive consequence stands and is stronger than the original wording — at this endpoint, **request acceptance can never confirm a wire-field-map row**; only an observable in the *response* can. See 22.4.5.
2. **Assert, don't narrate.** Each arm declares an expected status; any mismatch prints a want/got table to stderr and `System.halt(1)`s **before a single fixture is written**. `Req.Test`-stubbed wire tests assert what the *adapter* emits and stay green forever when the provider changes.
3. **Record the body, not the status.** Every arm whose response shape a fixture asserts writes that body to `recorded/` — error envelopes included.
4. **Run behind the overwrite guard.** Check every target path first; a fully-recorded tree costs zero live calls. Refuse to overwrite any file lacking the `_comment` marker.

**Arms — one per inferred row, plus the control:**

| Arm | Asserts |
|-----|---------|
| control | invented top-level field is **rejected** |
| `model` omitted | 200; record which model the response echoes |
| clean single string | 200; `flagged == false`; **no `usage` key anywhere in the body** |
| flagged string | 200; `flagged == true`; `category_applied_input_types` **present** |
| batch of 3 strings | 200; exactly 3 results |
| bad model name | 4xx; record the error envelope; confirm `error.message` / `error.type` / `error.code` shape |
| header capture | `x-request-id` present on a 200 |
| **`max_batch_size` ladder** | `n ∈ [1, 32, 100, 128, 1000]`; record the largest accepted `n` and the status of the first rejected one |
| bad key | 401; record whether the message echoes key material |

**`@adapter_max_batch_size` is determined by the ladder, not by this design.** The design deliberately does not state a number — Alternative D's reason 3. 22.4's Implementation Notes record the observed value and the moduledoc states it with the observation date. If the ladder's top rung (1000) is accepted, cap at 1000 and note that no upper bound was found.

#### 22.4.3 Implementation Checklist

- [ ] `lib/allm/providers/openai/moderation.ex` — `@behaviour`, the seam table's 22.4 rows, `@impl` callbacks
- [ ] Gate order inside `moderate/2`: empty-input gate → batch-size gate → `Keys.fetch!(:openai, opts)` → `Req` POST → `decode_response/4`
- [ ] `redact_key_material/1` (OpenAI pattern, verbatim from `lib/allm/providers/openai/embeddings.ex:695-699`) and `sanitize_cause/1`; **no `body_preview`**
- [ ] `scripts/record_openai_moderation_fixtures.exs` with all four probe parts and every arm above
- [ ] **Eight** fixture files (four `recorded/`, four `synthesized/`); every `synthesized/` one carries `_comment: "Synthesized for Phase 22.4 …"`. `multimodal_text_image.json` is a 22.5 deliverable and is not written here.
- [ ] Extend `test/support/openai_fixtures.ex` with `moderation_recorded/1` + `moderation_synthesized/1`, **delegating to** the single `drop_comment/1` (`test/support/openai_fixtures.ex:165`) rather than copying it — it reached three copies once already and was consolidated there
- [ ] `test/allm/providers/openai/moderation_conformance_test.exs` — the harness invocation, with a `@moduledoc` naming which invariants it does and does not bind for this adapter
- [ ] Add a moderations section to `test/fixtures/openai/README.md`, which today documents `chat_completions/`, `responses/`, and `synthesized/` but **not** `embeddings/` — do not replicate that omission
- [ ] `mix.exs` `groups_for_modules`: `ALLM.Providers.OpenAI.Moderation` → `Providers`
- [ ] File the `[CARRY]` ticket in `ASKS.md` naming `lib/allm/providers/openai/images.ex`'s `body_preview` + un-redacted message, per Decision's safer-than-sibling rule

#### 22.4.4 Verification

```bash
mix test test/allm/providers/openai/moderation_test.exs \
         test/allm/providers/openai/moderation_wire_test.exs
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer

# BLOCKING live gate. The key lives in a gitignored project-root `.env`; a bare
# `System.get_env/1` reports "not set" in a fully-provisioned checkout, so the
# invocation is written as it actually runs.
set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs
```

**Cost: $0.00** — the endpoint is free (Assumption 6, Decision #10). There is no budget reason to skip or narrow the probe.

**Success criterion:** the recorder exits 0 with every arm's expected status matched; all **four** of 22.4's `recorded/` fixtures exist and contain no `_comment` key; the per-file provenance tests pass; `@adapter_max_batch_size` is set from the observed ladder result and both the moduledoc and 22.4.5 Implementation Notes state it with the observation date.

#### 22.4.5 Implementation Notes

**Live probe ran 2026-08-31 against `POST https://api.openai.com/v1/moderations`. Cost $0.00** (the endpoint is free). All four `recorded/` fixtures are genuine live bodies — verified by raw-byte read: none carries a `_comment` key.

**1. The negative control came back POSITIVE, and that is the most important result of this batch.** `{"model": …, "input": "hi", "not_a_real_field": true}` returns **200**, not 400 — `/v1/moderations` **silently ignores unknown top-level fields**. The arm was kept and its expectation inverted to the observed truth, so the day OpenAI starts validating unknown arguments the recorder fails loudly.

> **Consequence, and it propagates:** acceptance is **not** evidence of schema membership at this endpoint. The design's probe rule ("every 'the provider accepts X' arm is paired with an invented-field arm, because acceptance is evidence of schema membership only once the API is shown to reject unknown fields") assumed a rejecting API. It does not reject. Therefore **no wire-field-map row may be promoted from `inferred` to `confirmed` on the strength of a 200 alone** — only rows confirmed by an observable in the *response* qualify. Rows resting on request acceptance stay `inferred` and are marked so.

**2. `max_batch_size` ladder — no upper bound found.** All five rungs (`n ∈ [1, 32, 100, 128, 1000]`) returned 200 with `length(results) == n`. `@adapter_max_batch_size` is therefore **1000**, documented in the moduledoc as *a floor, not a cap*: it is the largest value observed to work, not a provider-stated maximum. Per 22.4.6 this number binds 22.6's guide, which must read it from `max_batch_size/0` rather than hard-code it.

> **CORRECTED 2026-09-01 (22.4 fix pass; code review F2).** As first written, this note was **unbacked at the time it was written**. The ladder's verdict function was `verify_result_count_matches_input(%{body: body})`, which never received `n` and asserted only `is_list(Map.get(body, "results"))` — a response returning one result for a 1000-input batch would have passed every rung. The `length(results) == n` half of the sentence above described a comparison the recorder did not perform, and the same unbacked claim sits in the wire-field map row for `max_batch_size`.
>
> The verifier now closes over the rung's `n` and compares (`scripts/record_openai_moderation_fixtures.exs`, `verify_result_count_matches_input/1` returning a closure), and **the ladder was re-run live on 2026-09-01 with the corrected verifier**: all five rungs returned 200 **and** `length(results) == n` for each, `largest accepted n: 1000`, `rejected rungs: (none)`, "Schema holds: every asserted arm matched". `@adapter_max_batch_size 1000` therefore stands, and the claim above is now true **and** measured rather than asserted.
>
> The corrected verifier was itself proven load-bearing by mutation: flipping the comparison to `length(results) == n + 1` on a single-rung ladder turned the arm red and fired `halt_unless_schema_holds/1` (diagnostic line `ladder n=1  <- 1 results for 1 inputs`) before any fixture was written. Under the pre-fix verifier that mutation was not expressible, because `n` was never in scope.

**3. Row-by-row disposition:**

| Row | Before | After | Evidence |
|-----|--------|-------|----------|
| No `usage` object | inferred | **confirmed** | absent from every recorded 200 body |
| Response envelope `{id, model, results}` | confirmed | confirmed | `recorded/single_clean.json` |
| `category_applied_input_types` present on omni | inferred | **confirmed** | present in `recorded/flagged_violence.json` |
| Error envelope `{error: {message, type, param, code}}` | inferred | **confirmed** | `recorded/error_400_bad_model.json` |
| `x-request-id` correlation header | inferred | **confirmed** | observed on a 200 |
| `model` omitted → server default | inferred | **confirmed** | response echoed `omni-moderation-latest` |
| `max_batch_size` | inferred | **measured (floor)** | the ladder above |
| `detail` inside `image_url` not accepted | inferred | **still inferred** — 22.5 owns it, and note the control result above means a 200 on a `detail`-bearing request would prove nothing | — |

**4. `text-moderation-latest` is dead — confirmed on the wire, not just in the deprecations table.** The request returns **400**:

```json
{"error": {"code": null, "param": "model", "type": "invalid_request_error",
  "message": "Invalid value for 'model' = text-moderation-latest. Please check the OpenAI documentation and try again."}}
```

Recorded at `test/fixtures/openai/moderations/recorded/error_400_bad_model.json`. **Assumption 1 and Alternative A are now empirically settled** — the phase's most contentious decision, which deliberately contradicted the literal request, is correct against the live API.

**5. Security answer to the carried-forward `response.raw` question: benign for this endpoint.** The response body contains **no free-text echo of the submitted input** — a recursive walk of `recorded/single_clean.json` finds no string value longer than the `"modr-…"` id and the model name. Only `id`, `model`, and per-category booleans/floats/arrays. So `response.raw` riding into `:stop` telemetry metadata does not leak moderated user content. **Re-check if OpenAI ever adds an input echo.**

#### 22.4.6 Binding on later sub-phases

* **The observed `max_batch_size` from the ladder arm is the number every later artifact quotes.** Binds **22.6**'s `guides/moderation.md` chunk-loop example and its provider table, and the `@moduledoc`'s stated cap. Quote it from `ALLM.Providers.OpenAI.Moderation.max_batch_size/0` in an `iex>` block rather than hard-coding a literal, exactly as `guides/embeddings.md:117-124` does for all three embeddings adapters.
* **`to_json_body/2`'s all-strings shape is the branch 22.5 adds an arm to, not one it replaces.** Binds **22.5**: the `input` value becomes `to_openai_content_blocks/1`'s output only when `ModerationRequest.multimodal?/1` is true; the all-strings path must stay byte-identical, pinned by 22.4's `to_json_body/2` tests still passing unchanged.
* **The recorder's four-part structure (control arm, assert-don't-narrate halt, body recording, overwrite guard) is extended, never rewritten.** Binds **22.5**, which adds a multimodal arm. **But note what 22.4's probe established: this endpoint ignores unknown fields, so a paired control cannot settle `detail`'s disposition either** — a 200 on a `detail`-bearing `image_url` proves nothing. 22.5 must decide `detail` on the documented request shape (OpenAI's own multimodal example carries no `detail` key) and record it as *inferred*, not confirm it by acceptance.

---

### Phase 22.5 — Image input (Layer B)

**Goal:** `%ALLM.ImagePart{}` items reach the wire as `image_url` blocks, with the MIME and 20 MB gates and the multimodal cardinality rule.

#### 22.5.1 Test Plan (write first)

`test/allm/providers/openai/moderation_vision_test.exs` (NEW):
- `part_to_block/1 on a TextPart-equivalent binary emits {"type":"text","text":…}`
- `part_to_block/1 on a URL-sourced ImagePart emits {"type":"image_url","image_url":{"url":<url>}}` — the URL fast-path, never `to_data_uri/1` (which returns `{:error, :remote_source}` for `{:url, _}`, `lib/allm/providers/openai.ex:1853-1862`)
- `part_to_block/1 on a binary-sourced ImagePart emits a data: URI`
- **`part_to_block/1 emits NO "detail" key`** — Decision #8, and the negative-control arm's assertion in code
- `to_openai_content_blocks/1 preserves item order`
- `moderate/2 with an unsupported MIME returns :invalid_request with metadata naming the MIME`
- `moderate/2 with an image over 20 MB returns :invalid_request with metadata carrying the byte size`
- `moderate/2 with an ImagePart lacking a mime_type returns :invalid_request naming the item index`
- `all three image gates fire before Keys.fetch!/2` — asserted with no key in the environment
- `a multimodal recorded response decodes to exactly one result at index: 0` — `recorded/multimodal_text_image.json`
- `dropping ImagePart.detail logs at :debug` — via `capture_log([level: :debug], fn -> … end)`, **never** `Logger.configure/1` inside a `Task.async` (the PHASE_17.2 foot-gun)

`test/allm/allm_moderate_test.exs` (MODIFY):
- `moderate/3 with a mixed list returns exactly one result` — the cardinality rule at the façade
- `the :start telemetry metadata carries multimodal: true for a mixed list`

Conformance case 10 (already written in 22.2) now runs against the real adapter's shape via `FakeModeration`; no conformance edit.

#### 22.5.2 Implementation Checklist

- [ ] `to_openai_content_blocks/1` + `part_to_block/1` in `lib/allm/providers/openai/moderation.ex` — `/1` arity, names aligned with the chat translator's `/2` pair modulo the endpoint argument (Decision #9)
- [ ] `reject_oversized_images/1` calling `ALLM.Providers.Support.ImageMime.validate/2` per part with `ImageMime.accept_mimes(:openai)`; convert **all three** of its error shapes into `%ModerationAdapterError{reason: :invalid_request}` with the detail on `:metadata` (Decision #7 — **do not** widen the error union): `{:error, {:unsupported_image_format, mime}}`, `{:error, {:image_too_large, bytes}}`, and `{:error, :missing_mime_type}` (`lib/allm/providers/support/image_mime.ex:105-107`). The third is reachable — `ALLM.Image.from_url/1` infers no MIME type — and leaving it unmatched surfaces a `CaseClauseError` from inside `moderate/2`, which is ALLM's own bundled adapter violating invariant 2
- [ ] `to_json_body/2` routes through `to_openai_content_blocks/1` when `ModerationRequest.multimodal?/1`
- [ ] `Logger.debug(fn -> … end)` — deferred form — on the dropped `detail`
- [ ] Extend the recorder with the multimodal arm and its negative control (`detail` inside `image_url`)
- [ ] Update the wire-field map's two image rows from **inferred** to **confirmed**/falsified

#### 22.5.3 Verification

```bash
mix test test/allm/providers/openai/moderation_vision_test.exs test/allm/allm_moderate_test.exs
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer

# BLOCKING live gate — multimodal arm. $0.00.
set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs
```

**Success criterion:** the multimodal recorder arm exits 0 and writes `recorded/multimodal_text_image.json` containing exactly one `results` entry; the `detail` negative-control arm confirms the field's disposition and Decision #8 is amended in-commit if it is falsified.

---

### Phase 22.6 — Spec §39, guide, examples, docs wiring

**Goal:** The capability becomes discoverable and the release is publishable.

#### 22.6.1 Test Plan (write first)

`test/guides_test.exs` (MODIFY):
- `moderation.md` added to `@guides`, inheriting the structural gates (>2 KB, at least one `iex>` block, zero `scripts/audit_user_docs.exs` hits)
- the fenced-API denylist is extended if this phase removed any public name (it does not — additive only)

`test/guides_doctest_test.exs` (MODIFY):
- `doctest_file("guides/moderation.md")` — every `iex>` block in the guide executes

`test/package_files_extras_consistency_test.exs` — passes unmodified once `mix.exs @guides` gains the entry (fail-closed).

#### 22.6.2 Implementation Checklist

- [ ] Spec **§39** — Content moderation, with subsections mirroring §36's structure: data types (§39.2), behaviour (§39.3), engine slot (§39.4), façade (§39.5), adapter notes (§39.6), provider matrix and the §35.7 carve-out (§39.7). Include the §35-line reconciliation named in **Spec coverage** above.
- [ ] Spec amendments to **§27** (module tree), **§29** (telemetry event names), **§35.7** (Decision #3). Each opens with `> **Phase 22 amendment (commits <first-sha>..<last-sha>).**` — a commit **range**, not a single sha, since implementation spans seven sub-phases.
- [ ] `guides/moderation.md` — **`iex>` blocks wherever `FakeModeration` can run the example** (they are drift-protected by `doctest_file/1`); ` ```elixir ` fences only for the live-key and threshold-policy snippets that genuinely cannot run. Sections: quick start; `flagged?/1` vs per-category thresholds; the caller-side chunk loop against `max_batch_size/0` (Decision #5); moderating images; the provider matrix and why it has one row; testing with `FakeModeration`.
- [ ] `examples/19_moderate_text.exs` and `20_moderate_image.exs`, each with a `# Provider: openai` marker so `run_all.exs` scopes them to the OpenAI arm (`examples/run_all.exs:34-37`)
- [ ] `examples/_helpers.exs` — `moderation_adapter:` and `moderation_default_model:` keys on all three `@providers` rows (`nil` for anthropic and gemini), plus a `moderation_engine/1` constructor shaped like `embedding_engine/1` (`examples/_helpers.exs:179-222`), raising `ArgumentError` naming the provider when the row has no moderation adapter. Unlike the embedding scripts — which carry **no** `# Provider:` marker because all three arms have an adapter (`examples/16_embed_single.exs:3-8`) — the moderation scripts **do** carry one, so `run_all.exs` skips them on the anthropic and gemini arms rather than halting. `run_all.exs` itself needs no edit: it auto-discovers via `Path.wildcard("[0-9][0-9]_*.exs")` (`examples/run_all.exs:40-41`).
- [ ] `examples/README.md` — the `@providers` block and the script list
- [ ] `mix.exs` `@guides` (`:65-76`) + `test/guides_test.exs` `@guides` + `test/guides_doctest_test.exs`
- [ ] `CHANGELOG.md` — entries derived from `git diff v0.5.0..HEAD lib/`, **never** from this document's prose
- [ ] File the `/asks` ticket for the `@guides` divergence with its self-scoring grep predicate — **actioned in 22.7**, not left open
- [ ] Release via `mix run scripts/release.exs minor` → v0.6.0. **Never hand-edit `mix.exs @version`.**

#### 22.6.3 Verification

```bash
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
mix docs                        # zero broken autolinks

# BLOCKING live gate. $0.00 for the two new scripts.
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/19_moderate_text.exs
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/20_moderate_image.exs
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/run_all.exs
```

**Blocked-arm re-characterization (required, not inherited).** The OpenAI arm has a *history* of halting mid-run. `run_all.exs` runs every script in one VM and each script `System.halt(1)`s, so the first failure kills the run and every script after it is **unobserved, not passing**. Do not inherit a prior phase's account of where it halts. Run the scripts **individually past the halt**, record the full per-script line (e.g. `01–09 OK, 10 FAIL, 11–20 OK`), and re-test the deferral precondition against the failure actually **observed**: the error, the script, and the commit documenting it must all resolve. Any failure that does not resolve is filed as a new `[BUG]` with its own reproducer. **`examples/RUN_OUTPUT_OPENAI.md` is regenerated only in the same commit as a clean full run, or not touched at all.**

**Success criterion:** `mix docs` emits zero broken-autolink warnings; both new example scripts print `OK:` and exit 0 when run individually; `guides/moderation.md` passes all four structural gates and every `iex>` block executes green under `doctest_file/1`.

---

### Phase 22.7 — `[CHORE]` sweep

**Goal:** Close this phase's out-of-tree debt inside the phase, rather than filing tickets that outlive it.

agent-spec/DESIGN.md rule 32 exists because the Phase 20 build *"closed at 16 tickets filed / 1 resolved, with all three tickets naming 20.7 as their deadline unactioned, because 20.7's Module Tree was docs-only."* 22.6's Module Tree is likewise docs-only, so the three items below get their own sub-phase with its own tree rather than an `/asks` ticket and a hope.

#### 22.7.1 Module Tree

```
CLAUDE.md                                      (MODIFY — 22.7, strike the stale conformance-format claim)
test/guides_test.exs                           (MODIFY — 22.7, @guides parity + meta-test)
lib/allm/providers/openai/images.ex            (MODIFY — 22.7, redaction + drop body_preview)
lib/allm/providers/gemini/images.ex            (MODIFY — 22.7, redaction + drop body_preview)
test/allm/providers/openai/images_test.exs     (MODIFY — 22.7, redaction tests)
test/allm/providers/gemini/images_test.exs     (MODIFY — 22.7, redaction tests)
ASKS.md                                        (MODIFY — 22.7, close the two tickets)
```

#### 22.7.2 Test Plan (write first)

`test/guides_test.exs` (MODIFY):
- **`mix.exs`'s `@guides` and this file's `@guides` name the same set`** — the meta-test CLAUDE.md prescribes for a hand-maintained audit literal. It fails today: `mix.exs:65-76` contains `guides/fakes.md`; `test/guides_test.exs:18-28` does not, so `fakes.md` is gated on nothing. Adding `fakes.md` here also subjects it to the four per-guide gates and to `doctest_file/1`, which may surface real defects in a guide that has never been checked — fixing those is in scope for this sub-phase.
- an `@excluded %{"name" => "reason"}` map keeps opt-out possible and visible, per CLAUDE.md.

`test/allm/providers/{openai,gemini}/images_test.exs` (MODIFY):
- `a 401 message echoing key material is redacted before it reaches the error struct` — one per provider, each with its **own** pattern (`sk-|rk-|org-` for OpenAI, `AIza…|ya29.…` for Gemini); an inherited-verbatim regex is a silent no-op
- `the sibling provider's pattern matches nothing in the same fixture` — the companion test that makes inheritance fail loudly
- `no error struct field carries a body preview` — `refute Map.has_key?(err.metadata, :body_preview)`

#### 22.7.3 Implementation Checklist

- [ ] Strike CLAUDE.md's `conformance/lib/allm/test/image_adapter_conformance.ex:91-92` format-failure claim — verified clean at HEAD (F1 above). Replace it with the general lesson it is now an instance of, not a second stale cite.
- [ ] `test/guides_test.exs`: add `fakes.md` + `moderation.md`, add the `mix.exs`-parity meta-test and the `@excluded` map; fix whatever the newly-gated `fakes.md` surfaces
- [ ] `lib/allm/providers/openai/images.ex` and `lib/allm/providers/gemini/images.ex`: add `redact_key_material/1` + `sanitize_cause/1`, drop `body_preview` from the error metadata. These structs derive `Jason.Encoder` and downstream apps persist them — the [CARRY] this phase incurred by shipping safer than its own siblings (22.4)
- [ ] Close both `ASKS.md` tickets, each with the grep predicate that scores it

#### 22.7.4 Verification

```bash
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
cd conformance && mix test && mix credo --strict && mix format --check-formatted

# Self-scoring predicates — both must come back clean.
diff <(grep -oE 'guides/[a-z_]+\.md' mix.exs | sort -u) \
     <(grep -oE '[a-z_]+\.md' test/guides_test.exs | sed 's|^|guides/|' | sort -u)
grep -rn 'body_preview' lib/allm/providers/     # expected: empty
```

**Success criterion:** both predicates come back clean; `mix test` green including the newly-gated `fakes.md`; the two `ASKS.md` tickets are closed rather than re-dated.

**Cross-phase note.** This sub-phase edits released code (`openai/images.ex`, `gemini/images.ex`) that Phase 22 did not otherwise touch. That is in scope *here and only here* — a `[CHORE]` sweep sub-phase with its own Module Tree is the mechanism CLAUDE.md's cross-phase discipline provides for exactly this, and the alternative it was written against is a ticket nobody actions.

---

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `ALLM.moderate/3` | `%EngineError{reason: :no_moderation_adapter}` | Engine has no `:moderation_adapter`. Recoverable by setting one. |
| `ALLM.moderate/3` | `%ValidationError{reason: :invalid_moderation_request}` | Request violated a field rule; `:errors` carries the exhaustive `{path, atom}` list. Fix the request; no retry. |
| `ALLM.moderate/3` | `%ValidationError{reason: :unsupported_capability}` | Catalog says the model has `moderation_enabled: false`. Pick another model. Inert without `llm_db`. |
| `ALLM.moderate/3` | `ArgumentError` (**raised**, not returned) | Adapter violated invariant 2. A library bug or a third-party adapter defect; not caller-recoverable. Raises rather than returning so the `@spec`'s union stays honest and names the offending module. |
| `moderate/2` | `:authentication_failed` (401/403) | Key missing or invalid. Surface to the user; no retry. |
| `moderate/2` | `:rate_limited` (429) | Quota exceeded; `:retry_after_ms` populated from `Retry-After`. Retried automatically. |
| `moderate/2` | `:invalid_request` (400) | Request shape rejected; empty input; unsupported image MIME; image over 20 MB. `:metadata` carries the specific detail. Fix the request; no retry. |
| `moderate/2` | `:context_length_exceeded` (400) | A single input exceeds the model's token limit. Shorten it; no retry. |
| `moderate/2` | `:provider_unavailable` (5xx) | Provider-side failure. Retried automatically. |
| `moderate/2` | `:timeout` | `request_timeout` exceeded. Retried automatically. |
| `moderate/2` | `:network_error` | TCP/TLS/DNS failure. Retried automatically. |
| `moderate/2` | `:malformed_response` | 200 with an unparseable body, or a `results` entry missing `flagged`. No retry; file a bug. |
| `moderate/2` | `:unsupported_feature` | Request used a field this adapter cannot express; `metadata.feature` names it. No retry. |
| `moderate/2` | `:batch_too_large` | `length(input) > max_batch_size()`; `:metadata` carries `:count` and `:max`. Recoverable by chunking — see `guides/moderation.md`. |
| `moderate/2` | `:unknown` | Unclassifiable shape. No retry. |

`{:error, term()}` appears in no `@spec` in this design.

---

## Definition of Done

- [ ] All seven sub-phases marked `Completed`
- [ ] `mix test` zero failures, zero warnings; coverage ≥80% globally and ≥90% on new code
- [ ] `mix test --seed 0` green
- [ ] `mix credo --strict` zero issues; `mix dialyzer` zero new warnings; `mix format --check-formatted` passes
- [ ] `cd conformance && mix test && mix credo --strict && mix format --check-formatted` all green
- [ ] Every new public function has `@spec` + `@doc` with at least one runnable doctest
- [ ] Every new Layer A struct has both serializability round-trip tests, including the `%ImagePart{}`-bearing request and the non-integral-score result
- [ ] `ALLM.Providers.FakeModeration` passes every case in `ALLM.Test.ModerationAdapterConformance`, and the harness self-test confirms the injected block defines exactly `case_count/0` tests
- [ ] All five audit gates in the obligations table pass **with the new artifacts registered** — each fail-open gate verified by temporarily removing an entry and confirming it goes red
- [ ] The process-global-mutation grep lists only `async: false` modules
- [ ] Every **inferred** wire-field-map row is resolved by a probe arm; falsified rows are amended in the map in the same commit
- [ ] Every `recorded/` fixture passes its per-file negative provenance test (raw read, `refute Map.has_key?(raw, "_comment")`)
- [ ] The live gates ran; the OpenAI `run_all.exs` arm is re-characterized with a per-script line, not inherited
- [ ] `git diff --stat HEAD -- README.md` is empty across all seven sub-phases (CLAUDE.md's blocking pre-commit invariant)
- [ ] 22.7's two self-scoring predicates come back clean, and both `ASKS.md` tickets are closed rather than re-dated
- [ ] `CHANGELOG.md` updated from `git diff v0.5.0..HEAD lib/`
- [ ] Spec §39 + the §27/§29/§35.7 amendments land in the 22.6 commit with a commit-**range** provenance stamp
- [ ] Released as v0.6.0 via `mix run scripts/release.exs minor`
- [ ] Reviewed via `/functional-review` (see `agent-spec/REVIEW.md`)

**Ticked-with-caveats requires a linked finding.** Any item ticked with a known caveat must link to a retro finding or an `ASKS.md` ticket.

---

## Records

Per-sub-phase deviations, corrections, closure ledgers, and verification transcripts go to `steering/2026-08-31_PHASE_22_moderation_RECORDS.md`, created on first need. This document holds contracts and checklists only and must not grow materially after approval.
