# Phase 20: Embeddings — Design Document

> # ⚠ SUPERSEDED — do not implement from this document
>
> **Superseded by `steering/2026-07-28_EMBEDDINGS_DESIGN.md`**, which shipped Phase 20 in full (20.1–20.7, commits `ac5d845..`) and is the authoritative record of what was built.
>
> This document was never implemented. It is retained because the successor adopts most of its decisions verbatim — the `:embed_adapter` engine field, the `:no_embed_adapter` error atom, the `[:allm, :embed, :*]` span and its `embedding_count` measurement, the `String.t() | [String.t()] | %EmbeddingRequest{}` accept set, `[float()]` vectors over binaries, the sort-by-`index` order invariant, `:embed_adapter` as a peer to `:image_adapter` rather than a fallback, and the five-step façade error-flow ordering — and its "Adopted unchanged" section cites this file as the origin.
>
> **What the successor reverses, and where to read why:**
>
> - Scope: this document shipped OpenAI only and deferred Gemini / excluded Voyage. The successor ships all three, with `ALLM.Providers.Voyage.Embeddings` as the Anthropic track.
> - `%ALLM.EmbeddingUsage{}` does **not exist**. The successor reuses `ALLM.Usage`; the three defects in this document's Decision #4 (a field-name vocabulary split against the committed `ALLM.Usage`, a `Decimal` dependency absent from `mix.exs`, and a rationale its own moduledoc contradicts) are enumerated in the successor's divergence table.
> - `ALLM.EmbeddingRequest.input` is `[String.t()]` with no `@enforce_keys`, not a `String.t() | [String.t()]` union.
> - `ALLM.Embedding.index` is always an integer, never `nil`.
> - `supported_models/0` was dropped in favour of `max_batch_size/0`, which is load-bearing for batch chunking — a capability this document did not have.
> - The example scripts are numbered 16–18, not 14; 14 and 15 were consumed by the per-tool-manual phase.
>
> Every divergence is enumerated in the successor's **Relationship to `steering/PHASE_20_DESIGN.md`** section. Read that table before citing anything below.

> **Goal:** Add a provider-neutral embeddings primitive (`ALLM.embed/3`) that mirrors the image pipeline's Layer A/B/C split, ships against `ALLM.Providers.FakeEmbeddings` as the test vehicle, and lands `ALLM.Providers.OpenAI.Embeddings` as the first real adapter.
> **Outcome:** A user constructs an engine with `embed_adapter:` set, calls `ALLM.embed(engine, "two roads diverged in a yellow wood")`, and receives `{:ok, %ALLM.EmbeddingResponse{embeddings: [%ALLM.Embedding{vector: [0.0123, …]}], usage: %ALLM.EmbeddingUsage{prompt_tokens: 9, total_tokens: 9, cost: …}}}`. Engines without an `embed_adapter:` return `{:error, %ALLM.Error.EngineError{reason: :no_embed_adapter}}`. Existing v0.3 callers (chat, image) are unchanged.
> **Spec sections:** §36 (new — embeddings; lifted out of §32.5 / §33's "callers drop down to a provider SDK directly" non-goal). Cross-references §6.3 (`llm_db` capability pre-flight), §6.4 (`ALLM.Keys`), §29 (telemetry as the extension point).
> **Layers touched:** A (data) + B (behaviour + adapters) + C (facade). Each sub-phase touches a single layer; the multi-layer scope of the *aggregate* phase decomposes into single-layer sub-phases — same shape as Phase 13 (Layer A) → Phase 14 (Layer B+facade) → Phase 15 (real provider) for images.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 20.1 | Layer A — `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse`, `ALLM.EmbeddingUsage`, facade constructor `ALLM.embedding_request/2`, `ALLM.Validate.embedding_request/1` | A | Not Started |
| 20.2 | `ALLM.EmbeddingAdapter` behaviour + conformance harness + `ALLM.Providers.FakeEmbeddings` | B | Not Started |
| 20.3 | Engine `:embed_adapter` field wiring, `ALLM.embed/3` facade, telemetry span `[:allm, :embed, :*]`, capability pre-flight `Capability.preflight_embedding/2` | B + C | Not Started |
| 20.4 | `ALLM.Providers.OpenAI.Embeddings` real adapter + recorded fixtures + recorder script | B | Not Started |
| 20.5 | `examples/14_embed_text.exs` + `examples/_helpers.exs` `embedding_engine/1` + `run_all.exs` extension + `README.md` "Embeddings" section + `CHANGELOG.md` rollup + version bump | — | Not Started |

**Overall Progress:** 0/5 sub-phases complete

---

## Overview

Embeddings is a single-operation, request/response primitive on a parallel pipeline to chat and images, exactly as §35 envisions for image generation: a separate behaviour, a separate adapter slot on `ALLM.Engine`, no entanglement with the chat `Adapter`/`StreamAdapter` pipeline. The design reuses the image pipeline's pattern wholesale — Layer A structs that round-trip serialization, a `FakeEmbeddings` test vehicle implementing the new behaviour, a thin Layer C facade dispatching to `engine.embed_adapter`, and a real `OpenAI.Embeddings` adapter as the first bundled implementation. Anthropic ships no first-party embeddings endpoint (Voyage AI is a separate vendor); §36 names this asymmetry and the OpenAI-only bundling for v0.4 is explicit, not an oversight.

The phase widens the spec — §32.5 / §33 previously listed embeddings as out-of-scope ("callers drop down to a provider SDK directly"). Phase 20 reverses that for embeddings only and claims §36 (the next unused section); the spec amendment lands as part of Phase 20.1 alongside the data structs, not as a doc-only follow-up. Audio remains out of scope.

- **Deliverables**
  - Layer A: `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse`, `ALLM.EmbeddingUsage` structs; `ALLM.embedding_request/2` constructor; `ALLM.Validate.embedding_request/1` validator; `:embedding_request` field-error vocabulary.
  - Layer B: `ALLM.EmbeddingAdapter` behaviour with `embed/2` + `supported_models/0` (optional) + optional `prepare_request/2`; `ALLM.Providers.FakeEmbeddings` (scripted); `ALLM.Providers.OpenAI.Embeddings` (real, against `/v1/embeddings`); behaviour conformance harness under `test/support/`.
  - Layer C: `ALLM.embed/3` facade in `lib/allm.ex`; `ALLM.Engine` extended with `:embed_adapter` field; telemetry span `:embed` mirroring `:image`; `ALLM.Capability.preflight_embedding/2`.
  - Errors: `ALLM.Error.EmbeddingAdapterError` (10-atom reason enum cloned from `ImageAdapterError` minus `:unsupported_operation` and `:content_filter`); `ALLM.Error.EngineError.reason` extends with `:no_embed_adapter` (also extends the parallel `@legal_reasons` ~w-list at `lib/allm/error/engine_error.ex:31-40`); `ALLM.Error.ValidationError` `:invalid_embedding_request` umbrella + per-field reasons.
  - Examples + release polish: `examples/14_embed_text.exs`; `_helpers.exs.embedding_engine/1`; `run_all.exs` extended; README "Embeddings" section; CHANGELOG rollup.
  - Spec amendment: new §36 (Embeddings) committed in Phase 20.1.

- **Spec coverage**
  - **New §36** (lands in Phase 20.1 as a scoped spec amendment): §36.1 Overview + design goals, §36.2 Data shapes (`Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, `EmbeddingUsage`), §36.3 `ALLM.EmbeddingAdapter` behaviour, §36.4 `Engine.embed_adapter`, §36.5 Public API (`ALLM.embed/3`, `ALLM.embedding_request/2`), §36.6 Bundled providers (OpenAI), §36.7 Telemetry, §36.8 `FakeEmbeddings`, §36.9 Out of scope (Anthropic — no first-party endpoint; audio; reranking).
  - **Refines** §6.3 (capability pre-flight extends to embeddings), §6.4 (key resolution reused unchanged), §29 (telemetry events extend the closed event-name union).
  - **Reverses** §32.5 / §33 "embeddings — out of scope" prose; the sentence is amended to "embeddings ship in v0.4 — see §36; audio remains out of scope".

- **Layer demonstration** — every layer is independently usable.

  *Layer A (data only, no engine, no I/O):*
  ```elixir
  req = ALLM.embedding_request("two roads diverged", model: "text-embedding-3-small", dimensions: 256)
  :ok = ALLM.Validate.embedding_request(req)
  bin = :erlang.term_to_binary(req)
  ^req = :erlang.binary_to_term(bin)
  ```

  *Layer B (behaviour + Fake, no facade):*
  ```elixir
  ALLM.Providers.FakeEmbeddings.script([{:ok, [%ALLM.Embedding{vector: [0.1, 0.2, 0.3]}], %ALLM.EmbeddingUsage{prompt_tokens: 3, total_tokens: 3}}])
  {:ok, %ALLM.EmbeddingResponse{embeddings: [%ALLM.Embedding{vector: vec}]}} =
    ALLM.Providers.FakeEmbeddings.embed(req, request_id: "demo-1")
  ```

  *Layer C (facade over engine):*
  ```elixir
  engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake, embed_adapter: ALLM.Providers.FakeEmbeddings, model: "text-embedding-3-small")
  {:ok, %ALLM.EmbeddingResponse{embeddings: [emb]}} = ALLM.embed(engine, "two roads diverged")
  emb.vector  # [0.1, 0.2, 0.3]
  ```

  No Layer D demonstration: embeddings is intentionally stateless. A future caller wanting to attach an embedding to a session writes their own glue — the embedding is a value, not a turn.

- **Prerequisites**
  - Phase 13 (image Layer A) — establishes the constructor/validator/round-trip pattern this phase mirrors verbatim. (`lib/allm/image_request.ex`, `lib/allm/validate.ex:215-260`.)
  - Phase 14.3 (image Layer C facade + telemetry + capability) — establishes the `:image_count` measurement convention and the `image_stop_extras/1` 3-tuple span return form Phase 20.3 will mirror as `:embedding_count` and `embed_stop_extras/1`. (`lib/allm.ex:644-975` covers `generate_image/3` head through `image_stop_extras/1`, `lib/allm/telemetry.ex:8-179`, `lib/allm/capability.ex:266-278`.)
  - Phase 15 (real OpenAI Images adapter) — establishes the recorded-fixture + recorder-script + `_comment`-marker convention Phase 20.4 reuses. (`scripts/record_openai_image_fixtures.exs`, `test/fixtures/openai/images/recorded/`.)
  - No new deps. `Req` (already present) handles the synchronous JSON POST; no streaming, no multipart, no `Finch` direct path needed.

- **Out of scope**
  - **Anthropic embedding adapter** — Anthropic ships no first-party embeddings endpoint as of 2026-05; their docs route users to Voyage AI as a separate vendor. A Voyage adapter is a third-party package per §32, not bundled. Documented in §36.9 and CHANGELOG.
  - **Streaming embeddings** — neither OpenAI nor any major provider streams partial vectors; embedding endpoints are synchronous request/response. The §3 stream-first invariant doesn't bind here, exactly as it didn't bind to images per Principle #2 of `RELEASE_0_3_PHASING.md`.
  - **Audio (speech-to-text, text-to-speech)** — listed as a separate v0.4 candidate in `RELEASE_0_3_PHASING.md`'s "What Comes After"; deserves its own design phase with its own Layer A surface (`ALLM.AudioInput`, `ALLM.transcribe/3`).
  - **Embedding reranking** (Cohere `rerank`, Voyage `rerank`) — different shape (pair-scoring, not vector-extraction); separate primitive.
  - **Binary `<<f32, f32, ...>>` vector encoding on Layer A** — `Embedding.vector` is a list of floats. `EmbeddingRequest.encoding_format: :base64` (passed to OpenAI) is supported; the adapter base64-decodes back to a float list before constructing the response struct. Binary-tagged in-memory form is a v0.5 micro-optimization.
  - **Multi-vector embeddings** (ColBERT-style) — provider matrix doesn't support; defer.
  - **Local embedding models** (sentence-transformers via Ollama, llama.cpp) — separate package per §32.
  - **`ALLM.Session` integration / "embed-this-thread" sugar** — embeddings is a stateless primitive; sessions don't grow an embedding cache in this phase.

- **Non-obvious decisions**

  1. **`ALLM.embed/3` accepts `String.t() | [String.t()] | %ALLM.EmbeddingRequest{}` as the second argument.** OpenAI's `/v1/embeddings` accepts `input: string | [string]` and returns `data: [{embedding, index}, ...]` in either case. Forcing the user to wrap a string in a list-of-one for batch ergonomics, or building a `embed_batch/3` sister, both fail the "would the user write this without reading the source" test. The single function dispatches: string → 1-element batch internally; list-of-strings → batch directly; explicit struct → passthrough. *Docs target: `@doc ALLM.embed/3`, `@moduledoc ALLM.EmbeddingRequest`.*
  2. **`Embedding.vector` is `[float()]`, not `<<f32, f32, ...>>` binary.** List-of-floats round-trips through Jason without a custom encoder; binary form would force a `Jason.Encoder` impl on every Layer A struct that transitively contains an `Embedding`. The provider-side `encoding_format: :base64` is an OpenAI wire-format toggle for transport efficiency, not a Layer A storage choice — `Embeddings` adapter base64-decodes back to floats before constructing the struct. *Docs target: `@moduledoc ALLM.Embedding`, CHANGELOG entry only.*
  3. **`EmbeddingResponse.embeddings` preserves request order.** OpenAI's response carries a per-element `index` field; the adapter MUST sort by `index` before constructing the struct (the API does not guarantee ordering — verified against OpenAI docs 2026-05; the field exists precisely to permit out-of-order responses for parallelism). The contract: `Enum.zip(request.input, response.embeddings)` is a valid pairing. Test in 20.4 with a synthesized fixture whose `data` array is shuffled. *Docs target: `@moduledoc ALLM.EmbeddingResponse` ("Order invariant" §).*
  4. **`EmbeddingUsage` shape mirrors chat's `Usage`, not image's `ImageUsage`.** Embeddings is purely token-priced (no per-image unit). Fields: `prompt_tokens`, `total_tokens`, `cost: Decimal.t() | nil` populated from `llm_db` when present (§6.3) and `nil` otherwise. No `:images` count, no per-element charges. The shape is close enough to `ALLM.Usage` that an obvious refactor is "reuse `ALLM.Usage`"; resist it — `ALLM.Usage` carries `completion_tokens` which has no embedding-side meaning. Distinct types > shared type with nilable fields. *Docs target: `@moduledoc ALLM.EmbeddingUsage`.*
  5. **Engine `:embed_adapter` field is a peer to `:image_adapter`, not a fallback for `:adapter`.** Same anti-pattern bar as image: a phase proposing "if `:embed_adapter` is nil, fall back to `:adapter` and check `embed/2` is exported" is wrong-shaped (Principle #1 of `RELEASE_0_3_PHASING.md`). `nil` → `{:error, %EngineError{reason: :no_embed_adapter}}`, full stop. *Docs target: `@doc ALLM.Engine.new/1`, CHANGELOG entry only.*
  6. **Telemetry measurement is `embedding_count`, not `vector_count`.** Mirrors `:image_count` from `image_stop_extras/1` for parallel structure across observability dashboards. The count is `length(response.embeddings)` (what was returned), matching Phase 14.3 Decision #8 for images. On error paths, `embedding_count` is absent from measurements — same handling as `image_count`. *Docs target: `@moduledoc ALLM.Telemetry` ("Embedding events" §).*
  7. **`Capability.preflight_embedding/2` is a no-op when `llm_db` is absent**, mirroring `preflight_image/2`'s pattern at `lib/allm/capability.ex:266-278`. The check fires only when the model entry has an `embeddings_enabled` boolean OR a `dimensions` constraint; missing entry → no-op. The dep-free smoke test from Phase 9 / image Phase 14.3 extends with an embedding row. *Docs target: `@doc ALLM.Capability.preflight_embedding/2`.*
  8. **Recorded fixtures use `text-embedding-3-small` for live recording.** Cheapest priced OpenAI embedding (~$0.020/M tokens) — a 100-token recording costs ~$0.000002. Fixtures cover `text-embedding-3-small`, `text-embedding-3-large` (1536 vs 3072 dims), `text-embedding-ada-002` (legacy, 1536 dims), single-input vs batch, `dimensions:` reduction, `encoding_format: :base64` round-trip, 429 with `Retry-After`, 401 invalid key, 400 input-too-long. Total live re-record cost ~$0.001 per `mix run scripts/record_openai_embeddings_fixtures.exs`. *Docs target: internal — no user-facing docs needed.*
  9. **Spec section §36 lands in the same commit as Phase 20.1's Layer A structs**, not as a separate doc-only commit. The Behaviour-Design-Doc Checklist Rule 6d ("Decision text drift is a known failure mode") + the CLAUDE.md "PHASE_14 Decision #14 was authored with five file:line cites and shipped zero drift" hard-won lesson both point the same way: spec changes ride with the code that demands them. *Docs target: `steering/allm_engine_session_streaming_spec_v0_2.md` §36.*
  10. **`embedding_engine/1` in `_helpers.exs` raises on missing adapter, mirroring `image_engine/1`.** OpenAI is the only bundled provider with embeddings; an `ALLM_PROVIDER=anthropic mix run examples/14_embed_text.exs` invocation MUST fail loudly with `ArgumentError`, not silently no-op. The `run_all.exs` Anthropic arm skips the embedding script (mirrors how image scripts are skipped on Anthropic). *Docs target: `@doc ExamplesHelpers.embedding_engine/1`, CHANGELOG entry only.*
  11. **Phase 20 does NOT add embeddings to Gemini Phase 18.** Gemini ships an embeddings endpoint (`/v1beta/models/{model}:embedContent`); wiring it is a separate phase analogous to "Phase X: Gemini Embeddings" in v0.5. Phase 20 ships OpenAI only to keep the per-phase blast radius tight. The Gemini phase reuses `EmbeddingRequest`/`EmbeddingResponse`/`EmbeddingUsage` structs unchanged — verifying this is a correctness check on the Phase 20.1 contract design, not a Phase 20 deliverable. *Docs target: `RELEASE_0_3_PHASING.md` "What Comes After" entry; CHANGELOG entry only.*

---

## Behaviour & Type Contracts

All five contracts below MUST land in Phase 20.1 (Layer A) and Phase 20.2 (behaviour) before any subsequent sub-phase begins. Conformance Rule 1 traceability: every callback / public function below cites the §-section and at least one user story (drawn from the Layer demonstration above).

### `ALLM.Embedding` (Layer A — serializable)

```elixir
defmodule ALLM.Embedding do
  @moduledoc "A single embedding vector returned by an embedding adapter (§36.2)."

  @enforce_keys [:vector]
  defstruct [:vector, :index, metadata: %{}]

  @type t :: %__MODULE__{
          vector: [float()],          # never nil; provider always returns at least one float
          index: non_neg_integer() | nil,  # request-side index; preserved by the adapter for batch attribution
          metadata: map()              # adapter-set provider-specific keys, e.g. %{"truncated" => false}
        }
end
```

Invariants:
- `vector` is non-empty; an adapter returning `[]` constructs `%EmbeddingAdapterError{reason: :malformed_response}` instead.
- `index` is `nil` for single-input requests; non-nil for batch requests, equal to the request input's position (0-based).

### `ALLM.EmbeddingRequest` (Layer A — serializable)

```elixir
defmodule ALLM.EmbeddingRequest do
  @moduledoc "An embedding request (§36.2)."

  @enforce_keys [:input]
  defstruct [
    :input,                            # String.t() | [String.t()]
    :model,                            # String.t() | nil — late-resolved per §6.3
    :dimensions,                       # pos_integer() | nil — provider-side reduction (text-embedding-3-* only)
    encoding_format: :float,           # :float | :base64 — wire transport, normalized back to float list on the way in
    user: nil,                         # String.t() | nil — OpenAI's request-level user identifier
    options: %{},                      # map() — provider-specific opaque opts (e.g., Voyage's input_type)
    metadata: %{}                      # map() — caller-supplied; round-tripped onto response unchanged
  ]

  @type t :: %__MODULE__{
          input: String.t() | [String.t()],
          model: String.t() | nil,
          dimensions: pos_integer() | nil,
          encoding_format: :float | :base64,
          user: String.t() | nil,
          options: map(),
          metadata: map()
        }
end
```

Invariants:
- `input` is either a non-empty `String.t()` or a non-empty `[String.t()]` of length ≥1; validator rejects `[]` and `""`.
- `dimensions`, when set, is `> 0`; cap (model-specific; e.g., `text-embedding-3-small` ≤ 1536) is checked by capability pre-flight, not the validator.
- `encoding_format` defaults to `:float`; an adapter receiving `:base64` MUST decode back to floats before constructing the response struct (Decision #2).

### `ALLM.EmbeddingResponse` (Layer A — serializable)

```elixir
defmodule ALLM.EmbeddingResponse do
  @moduledoc "An embedding response (§36.2)."

  @enforce_keys [:embeddings]
  defstruct [
    :embeddings,                       # [Embedding.t()] — order matches request.input order
    :model,                            # String.t() | nil — provider-echoed; nil if absent
    :id,                               # String.t() | nil — provider-side request id (OpenAI doesn't return one for /v1/embeddings)
    :request_id,                       # String.t() | nil — caller's request_id from opts
    usage: %ALLM.EmbeddingUsage{},
    raw: nil,                          # term() — opaque provider response for debugging
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          embeddings: [ALLM.Embedding.t()],
          model: String.t() | nil,
          id: String.t() | nil,
          request_id: String.t() | nil,
          usage: ALLM.EmbeddingUsage.t(),
          raw: term(),
          metadata: map()
        }
end
```

Invariants:
- `length(embeddings) == length(List.wrap(request.input))` (Decision #3 order invariant).
- `usage` is never `nil`; always a `%EmbeddingUsage{}` (mirrors `ImageResponse.usage`'s `%ImageUsage{}` default at `lib/allm/image_response.ex:18-36`).

### `ALLM.EmbeddingUsage` (Layer A — serializable)

```elixir
defmodule ALLM.EmbeddingUsage do
  @moduledoc "Token usage for an embedding request (§36.2)."

  defstruct prompt_tokens: 0, total_tokens: 0, cost: nil

  @type t :: %__MODULE__{
          prompt_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost: Decimal.t() | nil
        }
end
```

Invariants:
- `prompt_tokens` and `total_tokens` default to `0`; an adapter unable to extract usage from a provider response MUST still return `%EmbeddingUsage{}` (zeros), never `nil`.
- `cost` is `nil` when `llm_db` is absent OR when the resolved model has no priced row; otherwise `Decimal.t()` per §6.3.

### `ALLM.EmbeddingAdapter` (Layer B — behaviour)

```elixir
defmodule ALLM.EmbeddingAdapter do
  @moduledoc "Behaviour for embedding-only providers (§36.3)."

  @callback embed(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, ALLM.EmbeddingResponse.t()}
              | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @doc "Optional: returns the list of model strings this adapter implements. nil = no per-model gate."
  @callback supported_models() :: [String.t()] | nil
  @optional_callbacks supported_models: 0

  @doc "Optional escape hatch — same shape as ImageAdapter.prepare_request/2; rarely needed for embeddings."
  @callback prepare_request(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, ALLM.EmbeddingRequest.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}
  @optional_callbacks prepare_request: 2
end
```

Conformance invariants (asserted by `conformance/lib/allm/test/embedding_adapter_conformance.ex`, alongside the existing `image_adapter_conformance.ex` in the separate `conformance/` Mix project):
1. `embed/2` returns `{:ok, %ALLM.EmbeddingResponse{}}` or `{:error, %ALLM.Error.EmbeddingAdapterError{}}` — never bare structs, never `:ok`.
2. The returned `response.request_id` equals the caller's `opts[:request_id]` if set, else `nil`.
3. `request.metadata` round-trips onto `response.metadata` unchanged when the adapter doesn't have a use for it.
4. `length(response.embeddings) == length(List.wrap(request.input))` for every successful response.
5. `response.embeddings |> Enum.with_index() |> Enum.all?(fn {e, i} -> e.index == nil or e.index == i end)` — Decision #3 order invariant.
6. When `supported_models/0` is implemented and returns a non-nil list, an `embed/2` call with a model not in the list returns `{:error, %EmbeddingAdapterError{reason: :unsupported_feature}}` *before* HTTP I/O.
7. `embed/2` with `request.input == ""` or `request.input == []` returns `{:error, %EmbeddingAdapterError{reason: :invalid_request}}` — never reaches the wire. (The Layer C facade also validates upstream; the conformance bar holds at the adapter for direct-adapter callers.)

The conformance suite is a `defmacro __using__` module under `conformance/lib/allm/test/`, mirroring image's `conformance/lib/allm/test/image_adapter_conformance.ex`. The `conformance/` directory is a separate Mix project (per the existing repo layout — verified 2026-05-03 against `conformance/lib/allm/test/{adapter,stream_adapter,image_adapter,tool_executor,tool_result_encoder}_conformance.ex`); downstream third-party adapters (Voyage, Cohere) add `:allm_conformance` as a test-only dep and `use ALLM.Test.EmbeddingAdapterConformance` in their own test files.

### `ALLM.Engine` extension (Layer B — runtime)

Three coordinated extensions to `lib/allm/engine.ex`:

1. `@type t` block at line 67-79 — add `embed_adapter: module() | nil` alongside `image_adapter` at line 74.
2. `defstruct` at line 82-95 — add `:embed_adapter` alongside `:image_adapter` at line 87.
3. `@engine_field_keys` at line 111 — add `:embed_adapter` so `resolve_params/2` (line 375-383) excludes it from the params merge — same treatment as `:image_adapter`. Also extend the `restore_module/1` round-trip path at line 395 with the new key so JSON-rehydrated engines populate `embed_adapter` correctly.

### `ALLM.embed/3` (Layer C — facade)

```elixir
# lib/allm.ex
@spec embed(ALLM.Engine.t(), String.t() | [String.t()] | ALLM.EmbeddingRequest.t(), keyword()) ::
        {:ok, ALLM.EmbeddingResponse.t()}
        | {:error,
           ALLM.Error.ValidationError.t()
           | ALLM.Error.EngineError.t()
           | ALLM.Error.EmbeddingAdapterError.t()}
def embed(engine, input_or_request, opts \\ [])
def embed(engine, %ALLM.EmbeddingRequest{} = req, opts), do: do_embed_body(engine, req, opts)
def embed(engine, input, opts) when is_binary(input) or is_list(input),
  do: do_embed_body(engine, ALLM.embedding_request(input, opts), opts)
```

Invariants:
- `request_id` is generated once at the top of `do_embed_body/3` via `Keyword.get(opts, :request_id) || ALLM.Telemetry.request_id()` (matching `lib/allm.ex:816`'s inline pattern in `do_generate_image/3`) and propagates onto `EmbeddingResponse.request_id`.
- `merge_opts/2` from `ALLM.Engine` is the single point where call-site opts combine with engine defaults, including `:model` resolution — `model:` on the `EmbeddingRequest` overrides `engine.model`.
- The facade drops request-control opts (`:request_id`, `:request_timeout`, `:retry`, `:adapter_opts`) before passing through to the adapter — same `drop_request_opts/2` helper at `lib/allm.ex:794-810`, extended with embedding-specific keys.
- Telemetry: wraps the entire body in `ALLM.Telemetry.span(:embed, %{engine: engine, request: req, request_id: rid}, fn -> ... end)`. `embed_stop_extras/1` returns `{extras, measurements}` with `:embedding_count`, `:usage`, `:error: nil` on success — same 3-tuple shape as `image_stop_extras/1` at `lib/allm.ex:954-975`.
- Capability pre-flight: `ALLM.Capability.preflight_embedding/2` is called *before* the adapter dispatch; on failure returns `{:error, %ValidationError{reason: :unsupported_capability}}`. Per `lib/allm/stream_runner.ex:122` and the CLAUDE.md "Capability pre-flight runs in `StreamRunner` and `ALLM.*` facade helpers, NOT inside adapter `generate/2`" rule, the gate lives in the facade, not in `OpenAI.Embeddings`.
- Error-flow ordering (mirrors image facade per Phase 14.3 Decision #15): adapter-presence (`:no_embed_adapter`) → validate request (`:invalid_embedding_request`) → capability pre-flight (`:unsupported_capability`) → key resolution (`:missing_key`) → adapter dispatch.

### `ALLM.embedding_request/2` (Layer A — facade constructor)

```elixir
@spec embedding_request(String.t() | [String.t()], keyword()) :: ALLM.EmbeddingRequest.t()
def embedding_request(input, opts \\ [])
def embedding_request(input, opts) when is_binary(input) or is_list(input) do
  %ALLM.EmbeddingRequest{
    input: input,
    model: Keyword.get(opts, :model),
    dimensions: Keyword.get(opts, :dimensions),
    encoding_format: Keyword.get(opts, :encoding_format, :float),
    user: Keyword.get(opts, :user),
    options: Keyword.get(opts, :options, %{}),
    metadata: Keyword.get(opts, :metadata, %{})
  }
end
```

Pure data; no validation, no I/O. The validator runs at facade dispatch time.

### `ALLM.Validate.embedding_request/1`

```elixir
@spec embedding_request(ALLM.EmbeddingRequest.t()) :: :ok | {:error, ALLM.Error.ValidationError.t()}
def embedding_request(%ALLM.EmbeddingRequest{} = req) do
  errors =
    []
    |> validate_embedding_input(req.input)
    |> validate_embedding_dimensions(req.dimensions)
    |> validate_embedding_encoding_format(req.encoding_format)
    |> Enum.reverse()

  finalize(:invalid_embedding_request, errors)
end
```

Mirrors `lib/allm/validate.ex:215-260`'s `image_request/1` shape. Field-error vocabulary in §Error Contract below.

### `ALLM.Capability.preflight_embedding/2`

```elixir
@spec preflight_embedding(String.t() | map() | nil, ALLM.EmbeddingRequest.t()) ::
        :ok | {:error, ALLM.Error.ValidationError.t()}
def preflight_embedding(model_ref, %ALLM.EmbeddingRequest{} = req)
```

Behaviour:
- `model_ref == nil` OR `llm_db` not loaded → `:ok` (no-op, mirrors `preflight_image/2`).
- Model entry has `embeddings_enabled: false` → `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:embeddings_enabled], :embeddings_disabled}]}}`.
- Model entry has `dimensions_max:` AND `req.dimensions > dimensions_max` → `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:dimensions], :exceeds_max}]}}`.
- Tolerates JSON-rehydrated maps (atom-keyed and string-keyed shapes), per `lib/allm/capability.ex:242-243`.

### `ALLM.Error.EmbeddingAdapterError`

Field shape mirrors `ALLM.Error.ImageAdapterError` byte-for-byte (`lib/allm/error/image_adapter_error.ex:84-92`) so a single retry policy / observability handler works uniformly across adapter-error types — `:retry_after_ms` in particular is consumed by `ALLM.Retry`'s 429 handling and MUST be present.

```elixir
defmodule ALLM.Error.EmbeddingAdapterError do
  @typedoc "Closed set of embedding-adapter error reasons (§36.3)."
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
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    authentication_failed
    rate_limited
    invalid_request
    context_length_exceeded
    provider_unavailable
    timeout
    network_error
    malformed_response
    unsupported_feature
    unknown
  )a

  @spec legal_reasons() :: [reason()]
  def legal_reasons, do: @legal_reasons

  defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason)

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m
  def message(%__MODULE__{reason: r}) when is_atom(r) and not is_nil(r), do: "embedding adapter error: #{r}"
  def message(%__MODULE__{}), do: "embedding adapter error"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data)
end

defimpl Jason.Encoder, for: ALLM.Error.EmbeddingAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

Atoms (10) cloned from `ImageAdapterError` (`lib/allm/error/image_adapter_error.ex:31-43`) minus `:unsupported_operation` (no operation matrix) minus `:content_filter` (embedding endpoints don't content-filter; if a future provider does, extend then). The full module shape — `@legal_reasons` parallel list, runtime `new/2` validation, `__from_tagged__/1` decoder, `defimpl Jason.Encoder` — mirrors `ImageAdapterError` per Behaviour-Design-Doc Checklist Rule "When a design adds a new type to an existing serializer, the registration is part of the contract."

### `ALLM.Error.EngineError` extension

`EngineError` keeps a parallel pair: a `@type reason ::` enum (`lib/allm/error/engine_error.ex:13-21`) AND a `@legal_reasons` ~w-atom list (`lib/allm/error/engine_error.ex:31-40`) that `new/2` runtime-validates against. **Both must be extended** with `:no_embed_adapter` — adding to `@type reason` alone leaves `EngineError.new(:no_embed_adapter)` raising `ArgumentError` from the `unless reason in @legal_reasons` guard at line 70. Single-line scoped amendment to each; CHANGELOG entry per the per-public-API-change rule.

### Wire-field map — OpenAI `/v1/embeddings`

Per Behaviour-Design-Doc Checklist Rule 15. (Cited at design time so the implementer doesn't hand-derive at fixture-write time, as Phase 11.2 had to with Anthropic's `partial_json`.)

| Concern | OpenAI wire field | Notes |
|---------|-------------------|-------|
| Request body | `{"model": "...", "input": "..." OR [...], "encoding_format": "float"|"base64", "dimensions": int?, "user": str?}` | `dimensions` and `user` omitted from body when `nil`. |
| Response body — vector | `data[i].embedding` | List of floats when `encoding_format: "float"`; base64 string when `"base64"` (decode to floats per Decision #2). |
| Response body — index | `data[i].index` | Provider does not guarantee order; sort by `index` per Decision #3. |
| Response body — model | `model` (top-level) | Echoed by OpenAI; populates `EmbeddingResponse.model`. |
| Response body — id | (none) | `/v1/embeddings` does NOT return an `id` field. `EmbeddingResponse.id` stays `nil`. |
| Response body — usage | `usage.prompt_tokens`, `usage.total_tokens` | No `completion_tokens` for embeddings. |
| 429 retry | `Retry-After` header | Same parser as chat-side retry. Reuse `ALLM.Retry`. |
| 400 input-too-long | Body `error.code: "context_length_exceeded"` OR `error.message ~= "maximum context length"` | Map to `:context_length_exceeded`. |
| 401 invalid key | HTTP 401 + body `error.code: "invalid_api_key"` | Map to `:authentication_failed`. |

### Closed-set verification (Behaviour-Design-Doc Checklist Rule 5)

Every reason atom named in this design is verified against committed source on 2026-05-03:
- `EmbeddingAdapterError` atoms (10 of 10): cloned from `lib/allm/error/image_adapter_error.ex:31-43` (12 atoms) minus `:unsupported_operation` and `:content_filter` — explicit reduction documented above.
- `EngineError.reason` extension: `:no_embed_adapter` is NEW; lands in Phase 20.3 as a scoped amendment with a CHANGELOG entry.
- `ValidationError.reason`: `:invalid_embedding_request` and `:unsupported_capability` are new and reused respectively. Per-field reasons (`:empty`, `:must_be_positive`, `:invalid_value`) all exist in `lib/allm/validate.ex` from prior phases.
- Telemetry event names: `:embed` is NEW; lands in Phase 20.3 as a scoped extension to `lib/allm/telemetry.ex:60`'s span-name union.

### Newly-added atom use sites (Behaviour-Design-Doc Checklist Rule 13)

- `:no_embed_adapter` — used at `lib/allm.ex:embed/3` adapter-presence gate (Phase 20.3).
- `:invalid_embedding_request` — used at `ALLM.Validate.embedding_request/1` finalize (Phase 20.1).
- `:embeddings_disabled`, `:exceeds_max` — used at `ALLM.Capability.preflight_embedding/2` (Phase 20.3).

No orphan atoms.

---

## Module Tree

```
lib/allm/
├── embedding.ex                                         (NEW — 20.1)
├── embedding_request.ex                                 (NEW — 20.1)
├── embedding_response.ex                                (NEW — 20.1)
├── embedding_usage.ex                                   (NEW — 20.1)
├── embedding_adapter.ex                                 (NEW — 20.2, behaviour)
├── allm.ex                                              (MODIFY — 20.1 adds embedding_request/2; 20.3 adds embed/3 + drop_request_opts extension + embed_stop_extras/1)
├── engine.ex                                            (MODIFY — 20.3 adds :embed_adapter to @type t at line 74, defstruct at line 87, @engine_field_keys at line 111, restore_module/1 path at line 395)
├── validate.ex                                          (MODIFY — 20.1 adds embedding_request/1 + helpers)
├── capability.ex                                        (MODIFY — 20.3 adds preflight_embedding/2)
├── telemetry.ex                                         (MODIFY — 20.3 extends span-name union with :embed at line 60; adds :embed metadata schema at lines 8-19)
├── error/
│   ├── embedding_adapter_error.ex                       (NEW — 20.1, defexception)
│   └── engine_error.ex                                  (MODIFY — 20.3 adds :no_embed_adapter to reason enum)
└── providers/
    ├── fake_embeddings.ex                               (NEW — 20.2)
    └── openai/
        └── embeddings.ex                                (NEW — 20.4)

test/allm/
├── embedding_test.exs                                   (NEW — 20.1, struct + serializability)
├── embedding_request_test.exs                           (NEW — 20.1)
├── embedding_response_test.exs                          (NEW — 20.1)
├── embedding_usage_test.exs                             (NEW — 20.1)
├── allm_embedding_request_test.exs                      (NEW — 20.1, facade constructor)
├── validate_embedding_request_test.exs                  (NEW — 20.1, validator)
├── allm_embed_test.exs                                  (NEW — 20.3, facade integration against FakeEmbeddings)
├── capability_embedding_test.exs                        (NEW — 20.3, preflight_embedding/2)
├── telemetry_embed_test.exs                             (NEW — 20.3, span event assertions)
└── providers/
    ├── fake_embeddings_test.exs                         (NEW — 20.2, scripted Fake)
    └── openai/
        ├── embeddings_test.exs                          (NEW — 20.4, recorded-fixture wire tests)
        ├── embeddings_live_test.exs                     (NEW — 20.4, gated on OPENAI_API_KEY)
        └── embeddings_wire_test.exs                     (NEW — 20.4, request-body shape contracts)

test/support/
└── fake_embedding_fixtures.ex                           (NEW — 20.2, named scripts)

conformance/lib/allm/test/
└── embedding_adapter_conformance.ex                     (NEW — 20.2, defmacro __using__; alongside image_adapter_conformance.ex)

conformance/test/allm/test/
└── embedding_adapter_conformance_test.exs               (NEW — 20.2, meta-test asserting case_count/0 == @case_count)

test/fixtures/openai/embeddings/
├── recorded/
│   ├── single_input_3_small.json                        (NEW — 20.4, recorded)
│   ├── batch_input_3_small.json                         (NEW — 20.4, recorded)
│   ├── single_input_3_large.json                        (NEW — 20.4, recorded)
│   ├── single_input_ada_002.json                        (NEW — 20.4, recorded)
│   ├── dimensions_reduced_3_small.json                  (NEW — 20.4, recorded; dimensions: 256)
│   └── encoding_base64.json                             (NEW — 20.4, recorded; encoding_format: base64)
└── synthesized/
    ├── shuffled_data_array.json                         (NEW — 20.4, synthesized; carries _comment marker)
    ├── error_429_rate_limited.json                      (NEW — 20.4, synthesized)
    ├── error_401_invalid_key.json                       (NEW — 20.4, synthesized)
    ├── error_400_context_length.json                    (NEW — 20.4, synthesized)
    └── malformed_missing_data.json                      (NEW — 20.4, synthesized)

scripts/
└── record_openai_embeddings_fixtures.exs                (NEW — 20.4, idempotent re-record; refuses to overwrite recorded files lacking _comment marker)

examples/
├── _helpers.exs                                         (MODIFY — 20.5, adds embedding_engine/1; @providers row adds :embedding_adapter, :embedding_default_model)
├── 14_embed_text.exs                                    (NEW — 20.5)
├── run_all.exs                                          (MODIFY — 20.5, OpenAI arm adds 14_embed_text.exs; Anthropic arm skips)
└── RUN_OUTPUT_openai.md                                 (MODIFY — 20.5, regenerated when live gate fires; deferred-when-keys-absent)

steering/
└── allm_engine_session_streaming_spec_v0_2.md           (MODIFY — 20.1, adds §36 Embeddings; amends §32.5/§33 out-of-scope prose)

CHANGELOG.md                                             (MODIFY — 20.1/20.3/20.4/20.5, one entry per public-API change)
README.md                                                (MODIFY — 20.5, adds "Embeddings" section)
mix.exs                                                  (MODIFY — 20.5, version bump if cutting a release; otherwise unchanged — Phase 20 may ship as a 0.4.0-rc.1)
```

**Path-existence sanity-check** (per CLAUDE.md / Module Tree completeness invariant): all parent directories exist on disk except `test/fixtures/openai/embeddings/recorded/` and `test/fixtures/openai/embeddings/synthesized/`, which are created in Phase 20.4. Verified 2026-05-03 via `ls test/fixtures/openai/`.

**Completeness invariant**: post-phase, `git diff --stat <pre-phase>..<post-phase>` should enumerate the files above ± 1 (CHANGELOG.md being the typical off-by-one across sub-phase commits).

---

## Phases

### Phase 20.1 — Layer A: Embedding Data Structs + Facade Constructor + Validator

**Goal:** Land four serializable structs, the facade constructor `ALLM.embedding_request/2`, and the validator `ALLM.Validate.embedding_request/1`. No engine wiring; no adapter dispatch. Spec §36 lands in the same commit (Decision #9).

**Spec sections:** §36.2, §36.5 (constructor part)
**Layer:** A

#### 20.1.1 Test Plan (write first)

`test/allm/embedding_test.exs`:
- `Embedding.t() round-trips through :erlang.term_to_binary/1`
- `Embedding.t() round-trips through Jason.encode!/1 |> ALLM.Serializer.from_json/1` (with module hint)
- `@enforce_keys [:vector] raises ArgumentError on missing :vector` (verified in IEx 2026-05-03: `struct!(ALLM.Embedding, %{}) → ArgumentError`)

`test/allm/embedding_request_test.exs`:
- Round-trip serializability for both `input: String.t()` and `input: [String.t()]` shapes
- `@enforce_keys [:input]` raises on missing `:input`
- `encoding_format` defaults to `:float`
- `options` and `metadata` default to `%{}`

`test/allm/embedding_response_test.exs`:
- Round-trip serializability with non-empty `embeddings` list
- `usage` defaults to `%EmbeddingUsage{}` (never nil)
- `@enforce_keys [:embeddings]` raises on missing

`test/allm/embedding_usage_test.exs`:
- Defaults: `prompt_tokens: 0`, `total_tokens: 0`, `cost: nil`
- Round-trip with `cost: Decimal.new("0.000123")`

`test/allm/allm_embedding_request_test.exs`:
- `ALLM.embedding_request("hello")` returns `%EmbeddingRequest{input: "hello", encoding_format: :float, options: %{}, metadata: %{}}`
- `ALLM.embedding_request(["a", "b"], model: "text-embedding-3-small", dimensions: 256)` returns the populated struct
- `ALLM.embedding_request("x", encoding_format: :base64)` honored
- Constructor performs no validation (passes `""` and `[]` through unchanged)

`test/allm/validate_embedding_request_test.exs`:
- `validate.embedding_request/1` accepts `input: "hello"` → `:ok`
- Accepts `input: ["a", "b"]` → `:ok`
- Rejects `input: ""` → `{:error, %ValidationError{reason: :invalid_embedding_request, errors: [{[:input], :empty}]}}`
- Rejects `input: []` → same
- Rejects `input: ["a", ""]` → `{:error, %ValidationError{errors: [{[:input, 1], :empty}]}}`
- Rejects `dimensions: 0` → `{:error, errors: [{[:dimensions], :must_be_positive}]}`
- Rejects `dimensions: -1` → same
- Rejects `encoding_format: :gzip` → `{:error, errors: [{[:encoding_format], :invalid_value}]}`
- Accumulates: `input: "", dimensions: 0` → both errors in one ValidationError

#### 20.1.2 Implementation Checklist

- [ ] Author §36 in `steering/allm_engine_session_streaming_spec_v0_2.md` (sub-sections §36.1–§36.9 per Spec coverage above); amend §32.5/§33 out-of-scope prose
- [ ] Create `lib/allm/embedding.ex` with `@enforce_keys`, `@type`, `@moduledoc`, doctest
- [ ] Create `lib/allm/embedding_request.ex` with `@enforce_keys [:input]`, defaults, `@type`, `@moduledoc`, doctest
- [ ] Create `lib/allm/embedding_response.ex` with `@enforce_keys [:embeddings]`, `usage: %EmbeddingUsage{}` default
- [ ] Create `lib/allm/embedding_usage.ex` with `Decimal.t() | nil` cost field
- [ ] Create `lib/allm/error/embedding_adapter_error.ex` mirroring `lib/allm/error/image_adapter_error.ex` byte-for-byte modulo: 10-atom `@type reason` + matching `@legal_reasons` ~w-list, runtime `new/2` validation against `@legal_reasons`, `__from_tagged__/1` decoder, `defimpl Jason.Encoder` (the four-piece pattern from `image_adapter_error.ex:55-167`)
- [ ] Add `embedding_request/2` to `lib/allm.ex` with `@spec` and runnable doctest
- [ ] Add `embedding_request/1` to `lib/allm/validate.ex` with field-error helpers (`validate_embedding_input/2`, `validate_embedding_dimensions/2`, `validate_embedding_encoding_format/2`)
- [ ] Register the four new structs AND `EmbeddingAdapterError` in `ALLM.Serializer`'s `@known_modules` at `lib/allm/serializer.ex:64` (per Behaviour-Design-Doc Checklist Rule "When a design adds a new type to an existing serializer, the registration is part of the contract")
- [ ] Verify each Layer A struct round-trips via `ALLM.Serializer.from_json/1` test-by-test; pure structs without atom-keyed reasons typically need no custom decoder, but `EmbeddingAdapterError` (atom-keyed `:reason` and `:provider`) needs the explicit `__from_tagged__/1` per the mirror above
- [ ] CHANGELOG entry: "Add embedding data structs, EmbeddingAdapterError, and facade constructor (§36.2)"

#### 20.1.3 Verification

```bash
mix test test/allm/embedding_test.exs test/allm/embedding_request_test.exs \
         test/allm/embedding_response_test.exs test/allm/embedding_usage_test.exs \
         test/allm/allm_embedding_request_test.exs test/allm/validate_embedding_request_test.exs
mix test                              # full suite still green
mix credo --strict
mix dialyzer
mix format --check-formatted
# Spec amendment lands in same commit:
git show HEAD --stat | grep -E '(embedding|spec_v0_2)'
```

---

### Phase 20.2 — Layer B: `ALLM.EmbeddingAdapter` Behaviour + Conformance + `FakeEmbeddings`

**Goal:** Define the behaviour, ship the deterministic `FakeEmbeddings` adapter, and publish a conformance harness future adapters reuse.

**Spec sections:** §36.3, §36.8
**Layer:** B

#### 20.2.1 Test Plan (write first)

`test/allm/providers/fake_embeddings_test.exs`:
- `script([{:ok, [%Embedding{vector: [0.1, 0.2]}], %EmbeddingUsage{prompt_tokens: 1}}])` followed by `embed(req, [])` returns the scripted response
- `script([{:error, %EmbeddingAdapterError{reason: :rate_limited}}])` returns the error
- Exhausted script: `embed(req, [])` after script exhaustion returns `{:error, %EmbeddingAdapterError{reason: :unknown, message: "no_scripted_response"}}`
- `request.metadata` round-trips onto `response.metadata` unchanged
- `opts[:request_id]` propagates onto `response.request_id`
- Batch input: `request.input == ["a", "b", "c"]` + scripted `[%Embedding{vector: [0.1]}, %Embedding{vector: [0.2]}, %Embedding{vector: [0.3]}]` returns embeddings in order with `index: 0/1/2`
- `supported_models/0` returns `nil` by default (no per-model gate); `script(supported_models: ["text-embedding-3-small"])` returns the list
- Process-isolation: `Task.async(fn -> script(...) end) |> Task.await; embed(...)` returns `{:error, :no_scripted_response}` (per-process state)

`conformance/lib/allm/test/embedding_adapter_conformance.ex` (the harness; tested transitively via `FakeEmbeddings` passing it):
- `__using__` macro injects ≥7 `test` cases covering invariants 1–7 from §Behaviour & Type Contracts
- `@case_count 7` attribute + `case_count/0` introspection + meta-test asserting `length(injected_tests) == @case_count` (Behaviour-Design-Doc Checklist Rule 7)

#### 20.2.2 Implementation Checklist

- [ ] Create `lib/allm/embedding_adapter.ex` behaviour with `@callback embed/2`, `@callback supported_models/0` (optional), `@callback prepare_request/2` (optional)
- [ ] Create `lib/allm/providers/fake_embeddings.ex` implementing the behaviour; uses `Process.put({__MODULE__, :script}, ...)` for per-process scripting (mirrors `lib/allm/providers/fake_images.ex:1-420` pattern)
- [ ] Add `:capture_pid` seam to `FakeEmbeddings` (mirrors `fake_images.ex:244-255` per the cross-phase retro-driven seam from Phase 14.2 Finding 3)
- [ ] Create `conformance/lib/allm/test/embedding_adapter_conformance.ex` `defmacro __using__(opts)` injecting the 7 cases; expose `case_count/0` (mirrors `conformance/lib/allm/test/image_adapter_conformance.ex` location and module-namespace pattern `ALLM.Test.EmbeddingAdapterConformance`)
- [ ] Create `conformance/test/allm/test/embedding_adapter_conformance_test.exs` meta-test asserting `length(injected_tests) == @case_count`
- [ ] Create `test/support/fake_embedding_fixtures.ex` with named fixtures: `:single`, `:batch`, `:rate_limited_then_ok`, `:malformed`, `:unsupported_model`, `:base64_round_trip`, `:large_dimensions`
- [ ] `FakeEmbeddings` `use ALLM.Test.EmbeddingAdapterConformance` in its test file
- [ ] CHANGELOG entry: "Add ALLM.EmbeddingAdapter behaviour and FakeEmbeddings (§36.3, §36.8)"

#### 20.2.3 Verification

```bash
mix test test/allm/providers/fake_embeddings_test.exs
mix test test/allm/embedding_adapter_test.exs
mix test                              # full suite green
mix credo --strict
mix dialyzer
```

---

### Phase 20.3 — Layer C: Engine Wiring + `ALLM.embed/3` + Telemetry + Capability

**Goal:** First user-visible value. An engine constructed with `embed_adapter: ALLM.Providers.FakeEmbeddings` produces real `%EmbeddingResponse{}` values from `ALLM.embed/3`. Telemetry fires; capability pre-flight gates unsupported models.

**Spec sections:** §36.4, §36.5 (facade), §36.7 (telemetry), §6.3 (capability)
**Layer:** B (engine field) + C (facade) — single sub-phase because the engine field is one-liner that has no behavioural surface without the facade dispatch.

#### 20.3.1 Test Plan (write first)

`test/allm/allm_embed_test.exs`:
- Happy path: engine with `embed_adapter: FakeEmbeddings` + scripted single embedding → `{:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: [_ | _]}], request_id: rid}}` where `rid` is the auto-generated request_id
- String input sugar: `ALLM.embed(engine, "hello")` builds `%EmbeddingRequest{input: "hello"}`
- List input: `ALLM.embed(engine, ["a", "b"])` builds `%EmbeddingRequest{input: ["a", "b"]}`
- Explicit struct: `ALLM.embed(engine, %EmbeddingRequest{input: "x", model: "y"})` passthrough
- Adapter-presence: engine without `:embed_adapter` returns `{:error, %EngineError{reason: :no_embed_adapter}}`
- Validation: `ALLM.embed(engine, "")` returns `{:error, %ValidationError{reason: :invalid_embedding_request}}` BEFORE adapter dispatch (assert via FakeEmbeddings call-counter)
- Capability: engine with `model:` whose `llm_db` row has `embeddings_enabled: false` returns `{:error, %ValidationError{reason: :unsupported_capability}}`
- Capability: engine with no `llm_db` loaded → `:ok` no-op (dep-free smoke test extends Phase 9's pattern)
- Model resolution precedence: `request.model` > `opts[:model]` > `engine.model` (test all three orderings)
- `opts[:request_id]` overrides auto-generated request_id
- `request.metadata` round-trips onto `response.metadata`
- Adapter error propagation: scripted `{:error, %EmbeddingAdapterError{reason: :rate_limited}}` returns same tuple from facade

`test/allm/capability_embedding_test.exs`:
- `preflight_embedding/2` with `nil` model_ref → `:ok`
- With `llm_db` not loaded → `:ok`
- With `embeddings_enabled: false` → `{:error, ValidationError{errors: [{[:embeddings_enabled], :embeddings_disabled}]}}`
- With `dimensions_max: 1536, req.dimensions: 2048` → `{:error, errors: [{[:dimensions], :exceeds_max}]}`
- Tolerates string-keyed `%{"embeddings_enabled" => false}` map (JSON-rehydrated)

`test/allm/telemetry_embed_test.exs`:
- `:telemetry_test.attach_event_handlers(self(), [[:allm, :embed, :start], [:allm, :embed, :stop]])` then `ALLM.embed/3` succeeds → both events received in order
- `:start` measurements include `system_time`; metadata includes `request_id`, `engine`, `model`, `input_count`
- `:stop` measurements include `duration`, `embedding_count: 1`; metadata includes `usage`, `error: nil`
- On adapter error: `:stop` event still fires; metadata `error` is the `%EmbeddingAdapterError{}`
- On validation failure: `:stop` event still fires; metadata `error` is the `%ValidationError{}` (uniform success/failure path per CLAUDE.md telemetry contract)
- `embedding_count` measurement is `length(response.embeddings)`, not `length(request.input)` (per Decision #6 mirroring image's `:image_count` choice)

#### 20.3.2 Implementation Checklist

- [ ] Add `:embed_adapter` to `lib/allm/engine.ex` `@type t` at line 74, `defstruct` at line 87, `@engine_field_keys` at line 111, and `restore_module/1` JSON-rehydrate path at line 395 (four coordinated extensions; verified 2026-05-03 against current file)
- [ ] Engine round-trip serializability test: `ALLM.Engine.new(embed_adapter: FakeEmbeddings) |> :erlang.term_to_binary/1 |> :erlang.binary_to_term/1` round-trips AND `Jason`-rehydrates correctly via `ALLM.Serializer`; the round-tripped engine still returns `{:ok, _}` from `ALLM.embed/3`
- [ ] Add `:no_embed_adapter` to BOTH `lib/allm/error/engine_error.ex:13-21` (`@type reason`) AND `lib/allm/error/engine_error.ex:31-40` (`@legal_reasons` ~w-list — runtime `new/2` validates against this list at line 70 and raises `ArgumentError` for atoms missing here, even if present in `@type reason`); add a unit test in `test/allm/error/engine_error_test.exs` asserting `EngineError.new(:no_embed_adapter)` does not raise
- [ ] Add `preflight_embedding/2` to `lib/allm/capability.ex` (mirror of `preflight_image/2` at lines 266-278)
- [ ] Extend `lib/allm/telemetry.ex:60` span-name union with `:embed`; document the event schema at lines 8-19; extend the 3-tuple span return-form list (currently `:image`-only at lines 107-111) to include `:embed`
- [ ] Implement `ALLM.embed/3` in `lib/allm.ex` with `@spec` matching contract verbatim
- [ ] Implement `embed_stop_extras/1` helper mirroring `image_stop_extras/1` at `lib/allm.ex:954-975`
- [ ] Extend `drop_request_opts/2` at `lib/allm.ex:794-810` with embed-specific keys (none new beyond the shared set; verify the helper is reused as-is and add an embed-marker comment in the function for the contract-flip audit)
- [ ] Add doctests on `ALLM.embed/3` using `FakeEmbeddings` (no real provider required)
- [ ] CHANGELOG entries: "Add Engine.embed_adapter field", "Add ALLM.embed/3 facade", "Add :embed telemetry span", "Add Capability.preflight_embedding/2"

#### 20.3.3 Verification

```bash
mix test test/allm/allm_embed_test.exs test/allm/capability_embedding_test.exs test/allm/telemetry_embed_test.exs
mix test                              # full suite green; capability dep-free smoke test still passes
mix credo --strict
mix dialyzer
# Doctest verification:
mix test --only doctest
```

---

### Phase 20.4 — `ALLM.Providers.OpenAI.Embeddings` Real Adapter + Recorded Fixtures + Recorder Script

**Goal:** First real network adapter for embeddings against `/v1/embeddings`. Recorded fixtures cover the happy-path matrix; synthesized fixtures cover error/edge classes; live smoke test gated on `OPENAI_API_KEY` is the BLOCKING `/review` gate.

**Spec sections:** §36.6
**Layer:** B

#### 20.4.1 Test Plan (write first)

`test/allm/providers/openai/embeddings_test.exs` (recorded-fixture dispatch):
- `text-embedding-3-small`, `input: "hello"` → response with 1536-dim vector matching recorded fixture
- `text-embedding-3-small`, `input: ["a", "b"]` → 2 embeddings, ordered by `index`
- `text-embedding-3-large`, `input: "hello"` → 3072-dim vector
- `text-embedding-ada-002`, `input: "hello"` → 1536-dim vector (legacy)
- `text-embedding-3-small`, `dimensions: 256` → 256-dim vector
- `text-embedding-3-small`, `encoding_format: :base64` → base64 wire format decoded back to floats; `Embedding.vector` is `[float()]` regardless of the wire encoding
- Synthesized: `data` array shuffled (e.g., index `[2, 0, 1]`) → `EmbeddingResponse.embeddings` reordered by `index` matching request order (per Decision #3)
- Synthesized 429 with `Retry-After: 2` header → after retry, success; `ALLM.Retry` reused
- Synthesized 401 → `{:error, %EmbeddingAdapterError{reason: :authentication_failed, status: 401}}`
- Synthesized 400 with `error.code: "context_length_exceeded"` → `{:error, reason: :context_length_exceeded}`
- Synthesized malformed (missing `data` key) → `{:error, reason: :malformed_response}`

`test/allm/providers/openai/embeddings_wire_test.exs` (request-shape contracts):
- Request body for `input: "hello"` is exactly `%{"model" => "...", "input" => "hello", "encoding_format" => "float"}`
- Request body for `input: ["a", "b"]` carries the array form
- Request body omits `dimensions` and `user` when nil
- `Authorization: Bearer ...` header set via `OpenAIHeaders.json_headers/2`
- POST URL is `https://api.openai.com/v1/embeddings`

`test/allm/providers/openai/embeddings_live_test.exs` (gated on `OPENAI_API_KEY`):
- `@moduletag :live` and `@moduletag :openai_live` (excluded by default in `test/test_helper.exs`)
- `text-embedding-3-small`, `input: "hello world"` → vector with non-zero floats; cost ≈ $0.0000004

`test/allm/providers/openai/embeddings_test.exs` `use ALLM.Test.EmbeddingAdapterConformance` — passes the 7-case conformance suite

#### 20.4.2 Implementation Checklist

- [ ] Create `lib/allm/providers/openai/embeddings.ex` implementing `ALLM.EmbeddingAdapter`
  - [ ] `embed/2` dispatches: build body → POST → parse → construct `%EmbeddingResponse{}`
  - [ ] Body builder handles `dimensions:`, `encoding_format:`, `user:` (omit nil keys)
  - [ ] Response decoder sorts `data` by `index` before constructing `embeddings` list (Decision #3)
  - [ ] Response decoder base64-decodes vectors when `encoding_format: :base64` was sent (Decision #2)
  - [ ] Reuses `ALLM.Providers.Support.OpenAIHeaders.json_headers/2`
  - [ ] Reuses `ALLM.Retry` for 429 + `Retry-After` parsing
  - [ ] `request_id` from `opts` propagates onto `response.request_id` (conformance invariant 2)
  - [ ] `request.metadata` propagates onto `response.metadata` (conformance invariant 3)
  - [ ] Public `@doc false` + `@spec` test seams: `to_request_body/1`, `decode_response/2`, `to_embedding_adapter_error/3`, `decode_base64_vector/1` (per CLAUDE.md "Public-test-seam helpers carry `@doc false` + `@spec`" rule)
- [ ] Create `scripts/record_openai_embeddings_fixtures.exs` mirroring `scripts/record_openai_image_fixtures.exs` structure
  - [ ] `@recorded_dir = "test/fixtures/openai/embeddings/recorded"`
  - [ ] `@specs` list of 6 recording targets
  - [ ] Refuses to overwrite recorded files lacking `_comment` marker (idempotent guard)
  - [ ] Gated on `System.get_env("OPENAI_API_KEY")`; `IO.warn` + `System.halt(1)` if absent
- [ ] Synthesize 5 fixtures under `test/fixtures/openai/embeddings/synthesized/` with `_comment: "Synthesized for Phase 20.4 — <description>"` marker; tests strip the marker via `drop_comment/1` helper (reused from `OpenAITestFixtures` module)
- [ ] Run the recorder script live: `mix run scripts/record_openai_embeddings_fixtures.exs` (cost ~$0.001)
- [ ] Run the live smoke test: `mix test test/allm/providers/openai/embeddings_live_test.exs --include live` (cost ~$0.0000004)
- [ ] CHANGELOG entry: "Add ALLM.Providers.OpenAI.Embeddings (§36.6) — supports text-embedding-3-small, -3-large, -ada-002"

#### 20.4.3 Verification

```bash
mix test test/allm/providers/openai/embeddings_test.exs
mix test test/allm/providers/openai/embeddings_wire_test.exs
mix test                              # full suite still green
mix credo --strict
mix dialyzer
# Live gate (BLOCKING for /review):
mix run scripts/record_openai_embeddings_fixtures.exs    # idempotent re-record; no-op if already recorded
mix test test/allm/providers/openai/embeddings_live_test.exs --include live
# Confirm conformance suite passes:
mix test test/allm/providers/openai/embeddings_test.exs --only conformance
```

**Live-gate honesty:** if the implementer's environment lacks `OPENAI_API_KEY`, the live test and recorder script defer per the CLAUDE.md "synthesized vs recorded wire-fixture policy" rule; the deferral is flagged in the CHANGELOG entry honestly ("recorded fixtures captured against `text-embedding-3-small` on YYYY-MM-DD" once the live run actually fires; not paraphrased pre-record).

---

### Phase 20.5 — Examples + Release Polish

**Goal:** A user can run `ALLM_PROVIDER=openai mix run examples/14_embed_text.exs` and see real embeddings printed. README has a "Embeddings" section. CHANGELOG rolls up the v0.4 (or 0.3.x) delta.

**Spec sections:** §34 (release polish; same as image Phase 9)
**Layer:** — (release engineering, not library code)

#### 20.5.1 Test Plan (write first)

`test/allm/examples_helpers_test.exs` (extends existing):
- `ExamplesHelpers.embedding_engine()` with `ALLM_PROVIDER=openai` returns engine with `embed_adapter: ALLM.Providers.OpenAI.Embeddings`, `model: "text-embedding-3-small"`
- With `ALLM_PROVIDER=anthropic` → raises `ArgumentError` with message naming "no embedding adapter bundled"
- With `ALLM_PROVIDER=unknown` → raises `ArgumentError`
- With missing `OPENAI_API_KEY` env → raises with `:missing_key` message
- `extra_opts` keyword merges onto baseline (`temperature: 0` is irrelevant for embed; user-supplied opts pass through)

`examples/14_embed_text.exs` is a runnable script, not a test file; correctness is verified by:
- Executing under `mix run examples/14_embed_text.exs` with `OPENAI_API_KEY` set → exit 0
- Output contains a recognizable header line (e.g., `"Embedding for: ..."`) followed by a vector preview (first 3 floats)
- Vector length matches the model's expected dimensions (1536 for `text-embedding-3-small`)
- Failure path: `ALLM_PROVIDER=anthropic mix run examples/14_embed_text.exs` exits 1 with stderr message naming the missing adapter

`examples/run_all.exs` (modify): OpenAI arm extends to include `14_embed_text.exs`; Anthropic arm skips (mirrors how `10_generate_image.exs` is OpenAI-only)

#### 20.5.2 Implementation Checklist

- [ ] Extend `examples/_helpers.exs` `@providers` row with `:embedding_adapter` and `:embedding_default_model` keys
- [ ] Add `embedding_engine/1` helper (mirror of `image_engine/1` at `examples/_helpers.exs:127-150`)
- [ ] Create `examples/14_embed_text.exs` with header comment block (Provider: openai; Demonstrates: ALLM.embed/3; Spec section: §36.5; Cost note: ~$0.000001/run)
- [ ] Extend `examples/run_all.exs` OpenAI arm to include `14_embed_text.exs`; Anthropic arm: no-op (skip)
- [ ] Update `README.md` with "Embeddings" section (≤15 lines; minimal example using `FakeEmbeddings` so the snippet runs without an API key)
- [ ] Update `CHANGELOG.md` rollup: one bullet per public-API change from Phases 20.1–20.4; note Anthropic out-of-scope; note OpenAI-only bundling
- [ ] If cutting a release: `mix.exs` version bump (`0.3.0 → 0.4.0` if going semver-major-feature, OR `0.3.0 → 0.3.1` if patch-bundling the embeddings as additive — defer the choice to release-cut time)
- [ ] `mix hex.build` dry-run; verify `tar -tzf allm-<version>.tar` includes new lib files but excludes `scripts/`, `test/`, `conformance/`, `examples/`
- [ ] If live gate fires (i.e., implementer has keys): regenerate `examples/RUN_OUTPUT_openai.md` snapshot in same commit (per CLAUDE.md "Snapshot files MUST be regenerated in the same commit as the live run that produced them, OR not modified at all")
- [ ] Final `/review` per `AGENT_REVIEW_SPEC.md`

#### 20.5.3 Verification

```bash
mix test test/allm/examples_helpers_test.exs
mix run examples/14_embed_text.exs    # requires OPENAI_API_KEY; exit 0
ALLM_PROVIDER=openai mix run examples/run_all.exs   # exit 0; BLOCKING /review gate
mix hex.build                          # dry-run; clean
tar -tzf allm-*.tar | grep embedding   # confirms new lib files included
tar -tzf allm-*.tar | grep -E '(scripts|test|examples)' && exit 1 || true   # confirms test/scripts/examples excluded
```

---

## Test Plan (cross-phase)

### Unit tests (per module)

- One happy-path + one error-path per public function in `Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, `EmbeddingUsage`, `EmbeddingAdapter`, `FakeEmbeddings`, `OpenAI.Embeddings`, `Validate`, `Capability`, `ALLM.embed/3`, `ALLM.embedding_request/2`.
- One test per atom in `EmbeddingAdapterError.reason` (10 atoms → 10 dispatch tests across `OpenAI.Embeddings` synthesized fixtures).

### Behaviour conformance tests

- `conformance/lib/allm/test/embedding_adapter_conformance.ex` `defmacro __using__` injecting 7 cases (invariants 1–7 from §Behaviour & Type Contracts).
- `FakeEmbeddings` and `OpenAI.Embeddings` both `use ALLM.Test.EmbeddingAdapterConformance` in their respective test files.
- `@case_count 7` + `case_count/0` + meta-test in `conformance/test/allm/test/embedding_adapter_conformance_test.exs` asserting `length(injected_tests) == 7` (Behaviour-Design-Doc Checklist Rule 7).

### Integration tests

- `test/allm/allm_embed_test.exs` — facade against `FakeEmbeddings` covering all 11 listed test bullets in 20.3.1.
- Cross-layer: serializability of an engine with `embed_adapter: FakeEmbeddings` set (Phase 20.3 Implementation Checklist).

### Property tests (StreamData)

- Round-trip: for any `%EmbeddingRequest{input: input, dimensions: dims, encoding_format: ef, options: opts, metadata: md}` with input in `String.t() | non_empty_list(String.t())`, dims in `1..3072 | nil`, ef in `:float | :base64`, opts and md being maps of binary keys to scalars: `req |> :erlang.term_to_binary/1 |> :erlang.binary_to_term/1 == req`.
- Round-trip: same for `%EmbeddingResponse{}` with non-empty embeddings list of vectors of floats in `[-1.0, 1.0]`.

### Doctests

- `@doc` on `ALLM.embed/3`, `ALLM.embedding_request/2`, `ALLM.Validate.embedding_request/1`, `ALLM.Capability.preflight_embedding/2`, `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse`, `ALLM.EmbeddingUsage`, `ALLM.EmbeddingAdapter`, `ALLM.Providers.FakeEmbeddings.script/1`, `ALLM.Providers.OpenAI.Embeddings.embed/2`. Each must include at least one runnable example. Doctests on facade functions use `FakeEmbeddings` so they run under `mix test` without an API key.

### Serializability tests (Layer A)

- Every Layer A struct (`Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, `EmbeddingUsage`) round-trips through `:erlang.term_to_binary/1` AND `Jason.encode!/1 |> ALLM.Serializer.from_json/1` (with module hint).
- Engine round-trip (Phase 20.3): `ALLM.Engine.new(embed_adapter: FakeEmbeddings, model: "text-embedding-3-small")` round-trips through both serializers; the round-tripped engine still returns `{:ok, _}` from `ALLM.embed/3`.

### Stream-equivalence tests

- **N/A** — embeddings is non-streaming. Per Decision #2 of `RELEASE_0_3_PHASING.md` (carried verbatim from images), the §3 stream-first invariant is silent here. No `stream_embed/3` exists; no equivalence property to assert.

### Coverage threshold

- Global `mix.exs` threshold remains 80%; new code lands at ≥90% (Phase 20.1–20.4 each independently).

---

## Error Contract

### Function × reason × recovery table

| Function | Error reason | Type | Recovery guidance |
|----------|--------------|------|-------------------|
| `ALLM.embed/3` | `:no_embed_adapter` | `EngineError` | Engine constructed without `:embed_adapter`; caller passes one (e.g., `ALLM.Providers.OpenAI.Embeddings`). |
| `ALLM.embed/3` | `:invalid_embedding_request` | `ValidationError` | Validator rejected request shape; see `errors:` list for per-field reasons. |
| `ALLM.embed/3` | `:unsupported_capability` | `ValidationError` | Resolved model has `embeddings_enabled: false` OR `dimensions` exceeds model max. Caller picks a different model. |
| `ALLM.embed/3` | `:missing_key` | `EngineError` | `ALLM.Keys.get!/2` returned no key for the resolved adapter. Caller sets the env var. |
| `ALLM.embed/3` (via adapter) | `:authentication_failed` | `EmbeddingAdapterError` | Provider rejected the key (401). Surface to user; no retry. |
| `ALLM.embed/3` (via adapter) | `:rate_limited` | `EmbeddingAdapterError` | Provider 429. `ALLM.Retry` already retried per engine `:retry` policy; final tuple = exhausted. |
| `ALLM.embed/3` (via adapter) | `:invalid_request` | `EmbeddingAdapterError` | Provider 400 not matching a more specific atom. Caller fixes the request. |
| `ALLM.embed/3` (via adapter) | `:context_length_exceeded` | `EmbeddingAdapterError` | Input exceeded model's context window. Caller chunks the input. |
| `ALLM.embed/3` (via adapter) | `:provider_unavailable` | `EmbeddingAdapterError` | Provider 503. Retry later. |
| `ALLM.embed/3` (via adapter) | `:timeout` | `EmbeddingAdapterError` | Request exceeded `:request_timeout` opt. Caller raises the timeout or retries. |
| `ALLM.embed/3` (via adapter) | `:network_error` | `EmbeddingAdapterError` | Transport failed (DNS, connection refused). Caller checks connectivity. |
| `ALLM.embed/3` (via adapter) | `:malformed_response` | `EmbeddingAdapterError` | Provider returned a body the adapter couldn't decode. Likely an upstream provider bug; report. |
| `ALLM.embed/3` (via adapter) | `:unsupported_feature` | `EmbeddingAdapterError` | `supported_models/0` rejected the resolved model before HTTP I/O. Caller picks a supported model. |
| `ALLM.embed/3` (via adapter) | `:unknown` | `EmbeddingAdapterError` | Adapter caught an unclassified error. `cause:` carries the raw term. |

### Field-error atom vocabulary (`ValidationError` for `:invalid_embedding_request`)

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:input]` | `:empty` | no | `req.input == ""` or `req.input == []` |
| `[:input, idx]` | `:empty` | no | element of input list is `""` |
| `[:input, idx]` | `:invalid_type` | no | element of input list is not a binary |
| `[:input]` | `:invalid_type` | no | input is neither binary nor list of binaries |
| `[:dimensions]` | `:must_be_positive` | no | `dimensions <= 0` |
| `[:dimensions]` | `:invalid_type` | no | dimensions not an integer |
| `[:encoding_format]` | `:invalid_value` | no | not in `[:float, :base64]` |
| `[:embeddings_enabled]` | `:embeddings_disabled` | no | (capability) model row says embeddings disabled |
| `[:dimensions]` | `:exceeds_max` | no | (capability) `req.dimensions > model.dimensions_max` |

No hard-reject errors in this phase — embeddings has no analogue of image's `:vision_not_in_v0_2` placeholder rejection.

### Consumer/producer symmetry (Behaviour-Design-Doc Checklist Rule "Consumer/producer symmetry for filter keys")

- `drop_request_opts/2` at `lib/allm.ex:794-810` filters opts going from facade to adapter. The current set: `:request_id, :stream, :mask, :adapter_opts, :request_timeout, :retry`.
- For embeddings, the facade-handled key is `:request_id` (auto-generated then propagated). No new keys are *consumed* by the facade beyond what image already drops.
- The contract: every key the facade reads in `do_embed_body/3` must appear in `drop_request_opts/2`'s drop list (so it doesn't leak to the adapter as an opaque opt). Verified: `:request_id` is in the drop list.

---

## Streaming & Backpressure

**N/A — embeddings is synchronous.** No `Stream.resource/3`, no Finch direct-streaming path, no SSE parsing, no consumer cancellation contract. The §8 design-spec rules do not apply. `Req` (the existing non-streaming HTTP client) handles the entire lifecycle.

---

## Definition of Done

- [ ] All five sub-phases (20.1–20.5) marked `Completed` in §Status table
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on Phase 20.1–20.4 new code
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings vs. prior PLT
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest
- [ ] Every Layer A struct (`Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, `EmbeddingUsage`) has a serializability round-trip test (term_to_binary AND Jason via `ALLM.Serializer`)
- [ ] `EmbeddingAdapter` conformance suite under `conformance/lib/allm/test/` exists and `FakeEmbeddings` + `OpenAI.Embeddings` both pass it
- [ ] Spec amendment: §36 added to `steering/allm_engine_session_streaming_spec_v0_2.md`; §32.5/§33 prose amended; commit message cites §36
- [ ] Engine round-trip serializability test asserts `embed_adapter:` doesn't break v0.2 invariants
- [ ] Capability dep-free smoke test extended for embeddings (asserts no-op when `llm_db` absent)
- [ ] Telemetry assertion tests cover happy path, validation failure, adapter error
- [ ] Recorder script `scripts/record_openai_embeddings_fixtures.exs` exists and is idempotent (refuses to overwrite recorded files lacking `_comment` marker)
- [ ] Live smoke test gated on `OPENAI_API_KEY` exists; live re-record + live test exit 0 (BLOCKING `/review` gate; deferred-when-keys-absent honestly noted in CHANGELOG)
- [ ] Examples: `14_embed_text.exs` exits 0 against OpenAI; `_helpers.exs.embedding_engine/1` raises on Anthropic
- [ ] `examples/run_all.exs` OpenAI arm exits 0 with the embedding script included (BLOCKING `/review` gate)
- [ ] If snapshot regen fires: `examples/RUN_OUTPUT_openai.md` regenerated in same commit as the live run
- [ ] `README.md` "Embeddings" section under 15 lines, runs against `FakeEmbeddings` without an API key
- [ ] `CHANGELOG.md` updated with one entry per public-API change; honest about live-gate deferral if it fires
- [ ] `mix.exs` `package.files` MUST include all new `lib/allm/embedding*.ex` and `lib/allm/providers/openai/embeddings.ex` files (verified via `tar -tzf allm-*.tar | grep embedding`); `docs.extras` unchanged (CHANGELOG already present per CLAUDE.md `mix.exs` `package[:files]` invariant)
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md`
- [ ] If cutting a release: version bump in `mix.exs`; `mix hex.build` dry-run clean; `mix hex.publish` is a separate release event
