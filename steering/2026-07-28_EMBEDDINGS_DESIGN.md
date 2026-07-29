# Phase 20: Text Embeddings — Design Document

> **Supersedes `steering/PHASE_20_DESIGN.md`** (0/5 sub-phases, `Not Started`). That document scoped embeddings to OpenAI only and explicitly deferred Gemini (Decision #11) and excluded Anthropic/Voyage (Out of scope). This design covers all three provider tracks the request names, adds batch chunking, and reverses two of its recorded decisions — every divergence is enumerated in **Relationship to PHASE_20_DESIGN.md** below. Phase number and spec section are inherited, not re-reserved.
>
> **Goal:** Add a provider-neutral, non-streaming embeddings primitive so downstream apps can populate a local `pgvector` store without dropping to a provider SDK.
> **Outcome:** `ALLM.embed(engine, ["chunk one", "chunk two"])` returns `{:ok, %ALLM.EmbeddingResponse{}}` against OpenAI, Google (Gemini), and the Anthropic-recommended Voyage AI endpoint; `EmbeddingResponse.vectors/1` hands back `[[float()]]` ready for a `vector(N)` column.
> **Spec sections:** new **§36** (Text embeddings — the number PHASE_20_DESIGN.md reserved). Amends **§32.5**, **§33**, **§35.7** (bundled-adapter rule), **§27** (module tree), **§29** (telemetry).
> **Layers touched:** A, B, C — one layer per sub-phase (20.1 = A, 20.2 = B, 20.3 = C, 20.4–20.6 = B, 20.7 = docs).

**Section-number collision check (verified 2026-07-28):** §36 = Embeddings (this design), §37 = Audio (`steering/PHASE_19_DESIGN.md:942` renumbered itself to resolve an earlier collision with §36), §38 = Batch (`steering/BATCH_DESIGN.md:5-6`). Highest section committed to the spec file today is §35 (`steering/allm_engine_session_streaming_spec_v0_2.md:1907`). This design takes §36 and does not disturb §37/§38.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 20.1 | Layer A data: `Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, validator, serializer registry | A | Completed |
| 20.2 | Layer B runtime: `ALLM.EmbeddingAdapter` behaviour, `EmbeddingAdapterError`, `Engine.embed_adapter`, `FakeEmbeddings`, conformance suite | B | Not Started |
| 20.3 | Layer C façade: `ALLM.embed/3`, `ALLM.EmbeddingBatch` chunk/merge, `:embed` telemetry span, `Capability.preflight_embedding/2` | C | Not Started |
| 20.4 | `ALLM.Providers.OpenAI.Embeddings` | B | Not Started |
| 20.5 | `ALLM.Providers.Gemini.Embeddings` | B | Not Started |
| 20.6 | `ALLM.Providers.Voyage.Embeddings` (Anthropic track) | B | Not Started |
| 20.7 | Spec §36, `guides/embeddings.md`, examples 16–18, `mix.exs` wiring | — | Not Started |

**Overall Progress:** 1/7 sub-phases complete

---

## Relationship to `steering/PHASE_20_DESIGN.md`

That design is inherited wholesale except where listed. Naming, gate ordering, telemetry conventions, and the fixture/recorder discipline are adopted verbatim so no churn is introduced against a document already reviewed.

### Adopted unchanged

`:embed_adapter` engine field · `:no_embed_adapter` error atom · `[:allm, :embed, :*]` telemetry span with an `embedding_count` measurement · `ALLM.embed/3` accepting `String.t() | [String.t()] | %EmbeddingRequest{}` (its Decision #1) · `[float()]` vectors, not binaries (Decision #2) · sort-by-`index` order invariant (Decision #3) · `:embed_adapter` as a peer to `:image_adapter`, never a fallback (Decision #5) · `embedding_count` naming (Decision #6) · `preflight_embedding/2` no-op without `llm_db` (Decision #7) · `text-embedding-3-small` for fixture recording (Decision #8) · spec §36 landing in the same commit as the code (Decision #9) · `embedding_engine/1` raising on a missing adapter (Decision #10) · the five-step façade error-flow ordering (`PHASE_20_DESIGN.md:273`), including **validating at the façade** — which deliberately differs from `generate_image/3`'s no-validate policy (`lib/allm.ex:753-758`), and is right here because an empty-string input is a guaranteed provider 400 and should not be discovered on chunk 50 of 50.

### Divergences

| # | PHASE_20 decision | This design | Why |
|---|-------------------|-------------|-----|
| D1 | Decision #11: Gemini deferred to v0.5; Out-of-scope: no Anthropic/Voyage adapter | Ships OpenAI **+ Gemini + Voyage** | The request names all three tracks. Voyage is the Anthropic track (Assumption 1). |
| D2 | Decision #4: a distinct `%ALLM.EmbeddingUsage{prompt_tokens, total_tokens, cost: Decimal.t()}` — "resist reusing `ALLM.Usage`" | Reuse **`ALLM.Usage`**; no `EmbeddingUsage` module | Three concrete defects in the original: (a) `prompt_tokens`/`total_tokens` contradicts the committed `ALLM.Usage` field names `input_tokens`/`output_tokens` (`lib/allm/usage.ex:29-33`), introducing a second vocabulary for the same quantity; (b) `cost: Decimal.t()` would be the codebase's first `Decimal` and there is **no `:decimal` dep in `mix.exs`** — `ALLM.Usage` costs are `float()` (`lib/allm/usage.ex:26`) and `ImageUsage` explicitly justifies float over Decimal (`lib/allm/image_usage.ex:9-16`); (c) the stated rationale — "`Usage` carries `completion_tokens` which has no embedding-side meaning" — is answered by `ALLM.Usage`'s own moduledoc: "Every numeric field is optional and `nil`-able because not every provider returns every counter" (`lib/allm/usage.ex:5-8`). `ImageUsage` earns its separate existence by counting *images*; embeddings bill in tokens, which `Usage` already models. **Resolved 2026-07-29 in favour of reuse — see Resolved Question 2.** |
| D3 | `encoding_format: :float \| :base64` on Layer A, adapters decode base64 back to floats | **Out of scope**; no `:encoding_format` field | Not provider-neutral: Gemini's `batchEmbedContents` has no base64 form (verified 2026-07-28), so the field would be meaningless on one of the three bundled adapters. It is a transport optimization that changes no Layer A value. Revisit if bulk-ingest profiling shows JSON float parsing dominating. |
| D4 | `Embedding.index` is `nil` for single-input, integer for batch | `:index` is **always** a `non_neg_integer()` | Batch chunking (Decision #5 below) rebases indices across chunk boundaries; a sometimes-nil field would make the rebase arithmetic conditional and `vectors/1`'s sort unstable. Uniform indexing costs nothing. |
| D5 | `@callback supported_models() :: [String.t()] \| nil` (optional) | Dropped; replaced by `@callback max_batch_size() :: pos_integer()` | `supported_operations/0` earns its place on `ImageAdapter` by gating a closed three-member operation enum. There is no analogous embeddings enum, and a per-module model allowlist goes stale on every provider model release — a hard-coded list would reject a valid new model. `max_batch_size/0` is load-bearing for chunking. |
| D6 | `:user` as a first-class `EmbeddingRequest` field (OpenAI's request-level identifier) | Folded into `:options` | OpenAI-only. `:options` is already the documented home for provider-specific opaque opts (`PHASE_20_DESIGN.md:137`). |
| D7 | `examples/14_embed_text.exs` | `examples/16–18` | 14 and 15 were consumed by Phase 18's per-tool-manual scripts. |
| D8 | "embeddings ship in v0.4" | **v0.5.0** | v0.4.3 is already released (`mix.exs:4`) without embeddings. |
| D9 | No batching | `ALLM.EmbeddingBatch` chunks transparently | Gemini caps a batch at 100; the pgvector use case routinely exceeds it (Assumption 2). |
| D10 | `EmbeddingRequest`: `@enforce_keys [:input]`, `input :: String.t() \| [String.t()]` | No `@enforce_keys`; `input: [String.t()]` defaulting to `[]` | The union type would push `List.wrap/1` into every adapter and every validator arm. Normalizing once at `embedding_request/2` gives the struct a single shape (contract invariant). `@enforce_keys` is then wrong: `input: []` must be *constructible* so the validator — not `struct!/2` — is what rejects it, which is what makes the `{:input, :empty}` field-error row reachable. |
| D11 | `EmbeddingResponse`: `@enforce_keys [:embeddings]` | No `@enforce_keys`; `embeddings: []` default | Matches `ImageResponse`, which enforces nothing and defaults `images: []` (`lib/allm/image_response.ex:28-36`). `EmbeddingBatch.merge/1` builds accumulator responses incrementally. |
| D12 | Decision #10: the Anthropic `run_all.exs` arm **skips** the embedding script | Scripts 16–18 carry no `# Provider:` marker and run on all three arms | Consequence of D1 — there *is* an Anthropic-arm embedding adapter now. **This makes `VOYAGE_API_KEY` a hard requirement for `ALLM_PROVIDER=anthropic mix run examples/run_all.exs`**, because `ensure_key_present!/1` halts on a missing key (`examples/_helpers.exs:183-187`). `examples/README.md`'s key-requirements table must say so. |
| — | `run_all.exs` extension listed as a 20.5 deliverable | **No change needed** | `run_all.exs` globs `[0-9][0-9]_*.exs` and gates on a `# Provider:` marker comment; a new script is picked up automatically. |

---

## Assumptions

Each is cheap to revisit; two change the shape of the work materially and are flagged **★**.

1. **★ "Anthropic" means "the Anthropic track", not "an Anthropic endpoint."** Anthropic ships no embeddings API and has not for the life of the product; they direct users to Voyage AI as their preferred embeddings partner ([Anthropic cookbook, `third_party/VoyageAI/how_to_create_embeddings.md`](https://github.com/anthropics/claude-cookbooks/blob/main/third_party/VoyageAI/how_to_create_embeddings.md), verified 2026-07-28). `PHASE_20_DESIGN.md:74` independently reached the same finding. This design ships `ALLM.Providers.Voyage.Embeddings` so an Anthropic-stack app has a first-party embeddings path, and adds no module named `ALLM.Providers.Anthropic.Embeddings` — naming a Voyage client after Anthropic would misrepresent the wire. See Alternative A and **Resolved Question 1**.
2. **★ Bulk ingestion is the primary workload.** "pgvector stores" implies embedding thousands of document chunks. Google caps `batchEmbedContents` at 100 requests per call, so a one-request-per-call API is unusable for the stated goal. The façade therefore chunks (Decision #5). See Alternative C.
3. **Embeddings are non-streaming.** Same reasoning as images (spec §35.1 item 2): request/response, no token stream. No `ALLM.EmbeddingStreamAdapter`, no `stream_embed/3`.
4. **Storage stays out of the library.** ALLM returns `[[float()]]`. It does not depend on `Ecto`, `postgrex`, or `pgvector`, and ships no repo/migration helpers. The pgvector integration is documented in `guides/embeddings.md` as a worked example against the caller's own repo.
5. **Text only.** Voyage and Gemini both offer multimodal embedding endpoints. Out of scope.
6. **Model strings stay late-resolved (§6.3).** `llm_db` is still not a dependency (`mix.exs:38` comment), so `Capability.preflight_embedding/2` is a no-op in practice today — exactly as `PHASE_20_DESIGN.md` Decision #7 anticipated.
7. **v0.5.0 via `scripts/release.exs minor`.** New Layer A structs, a new behaviour, and a new `Engine` field are additive but wide. Per CLAUDE.md, `mix.exs @version` is never hand-edited.

---

## Alternatives Considered

### A. How to deliver the "Anthropic" arm

| Option | Trade-off |
|--------|-----------|
| **A1 — ship `ALLM.Providers.Voyage.Embeddings` in-tree (chosen)** | Delivers a working Anthropic-stack embeddings path in one `mix deps.get`. **Cost:** breaks the letter of the §35.7 bundled-adapter rule — Voyage's translator shares nothing with the Anthropic chat adapter, so its maintenance does not amortize. Requires a scoped §35.7 amendment (Decision #2). |
| A2 — OpenAI + Gemini only; Anthropic users pick another provider | Cleanest against §35.7, and what `PHASE_20_DESIGN.md:74` chose. Fails the literal ask and leaves the most common ALLM configuration (Anthropic chat) with no in-tree embeddings. |
| A3 — `ALLM.Providers.Anthropic.Embeddings` proxying Voyage | Delivers the ask by name. Rejected: the module name asserts an endpoint that does not exist, the key resolves from `VOYAGE_API_KEY` not `ANTHROPIC_API_KEY`, and the moduledoc would spend its first paragraph retracting its own name. |

### B. `[[float()]]` vs a per-item `%ALLM.Embedding{}` struct

Chosen: **`%ALLM.Embedding{}`**, matching `PHASE_20_DESIGN.md:106-117`. A bare `[[float()]]` is simpler and is what pgvector wants — but under Decision #5 the façade splits one logical request across N HTTP calls, and the merge needs a per-item index that survives chunk boundaries to guarantee `Enum.at(response.embeddings, i)` corresponds to `Enum.at(request.input, i)`. Reconstructing that from list position alone is correct only if every chunk succeeds *and* every provider returns items in request order — OpenAI documents an `index` field precisely because order is not contractual. `EmbeddingResponse.vectors/1` recovers the flat `[[float()]]` in one call.

### C. Where batch chunking lives

| Option | Trade-off |
|--------|-----------|
| **C1 — façade chunks; adapters see ≤ `max_batch_size/0` (chosen)** | One implementation in `ALLM.EmbeddingBatch`. Adapters stay thin. Retry and telemetry wrap per-chunk, which is what a rate-limited provider wants. |
| C2 — each adapter chunks internally | Three copies of the same loop; the conformance suite cannot assert chunking uniformly because `prepare_request/2` becomes undefined for oversized input. |
| C3 — no chunking; reject oversized input | Simplest and honest — and what PHASE_20 implicitly assumed. Rejected as the default because Gemini's 100-item cap would push the loop into every caller. Retained as the *escape hatch*: `max_batch_size/0` is public, and `:batch_too_large` still fires for direct adapter calls. |

### E. Bounding the aggregate retry / time budget of a chunked call

Chosen: **per-chunk budgets, documented, with no new API.** `Retry.run/3` wraps each chunk independently, so a 50-chunk ingest's worst case is `50 × max_attempts` requests and an unbounded wall clock. The alternatives were an aggregate `:max_total_attempts` opt and a total `:deadline` opt; both were rejected for v0.5 as speculative configurability (no throughput data yet) and because the escape hatch already exists — a caller who chunks against `max_batch_size/0` gets per-call control of both budgets for free, using the same loop the resumability recipe needs. The obligation this creates is documentary, not structural: `@doc ALLM.embed/3` must state the multiplication in a table rather than leaving it to be discovered. **Resolved 2026-07-29 in favour of per-chunk budgets — see Resolved Question 3.**

### D. Partial results on a mid-batch failure

Chosen: **fail the whole call**. Chunk 7 of 50 failing returns `{:error, %EmbeddingAdapterError{}}` with `metadata.completed_chunks` and `metadata.completed_inputs` for diagnostics; no vectors are returned. An `{:ok, response, error}` triple or a partially-filled response is barred by AGENT_DESIGN_SPEC.md's "Don't overload return shapes." Callers needing resumability chunk themselves against `max_batch_size/0`; `guides/embeddings.md` shows that loop.

---

## Overview

Embeddings are the last capability an ALLM app has to leave the library for. §32.5 and §33 both list them as out of scope — prose written when ALLM had no non-chat primitive at all. Phases 13–17 built the image capability, establishing the pattern this phase reuses: a Layer A request/response pair, a dedicated adapter behaviour with its own closed error enum, one `Engine` field, one façade function, one telemetry span, one `Fake*` adapter, one conformance suite. Embeddings are a *strictly simpler* instance — no operations enum, no multipart, no binary payloads, no streaming.

The one place embeddings are harder than images is batching: the three target providers cap a single request at 2048, 100, and 1000 inputs respectively, and bulk-loading a pgvector table routinely exceeds all three. That asymmetry is absorbed once, in `ALLM.EmbeddingBatch`, behind the façade.

### Deliverables

**Layer A (new):** `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse`, `ALLM.Error.EmbeddingAdapterError`.
**Layer A (modified):** `ALLM.Error.EngineError` (+`:no_embed_adapter`), `ALLM.Error.ValidationError` (+`:invalid_embedding_request`), `ALLM.Serializer` (+4 registry entries), `ALLM.Validate` (+`embedding_request/1`).
**Layer B (new):** `ALLM.EmbeddingAdapter`; `ALLM.Providers.FakeEmbeddings`; `ALLM.Providers.OpenAI.Embeddings`; `ALLM.Providers.Gemini.Embeddings`; `ALLM.Providers.Voyage.Embeddings`; `ALLM.Test.EmbeddingAdapterConformance`.
**Layer B (modified):** `ALLM.Engine` (+`:embed_adapter` across five sites) — 20.2.
**Layer B support, landed with the Layer C façade that consumes them:** `ALLM.Capability` (+`preflight_embedding/2`), `ALLM.Telemetry` (+`:embed` span name) — 20.3. Both are pure additions to existing Layer B modules with no Layer C dependency; they ship in 20.3 because 20.3 is their only caller and a phase must be independently shippable.
**Layer C (new):** `ALLM.embed/3`, `ALLM.embedding_request/2`, `ALLM.EmbeddingBatch`.

### Spec coverage

Implements new **§36**. Amends **§32.5** / **§33** (strike "embeddings" from the out-of-scope lists, pointing to §36). Note §35 shipped image generation in v0.3 but never struck it from §33's v0.2 non-goals list (`steering/allm_engine_session_streaming_spec_v0_2.md:1887` still reads `embeddings, audio input/output, image generation`); 20.7 corrects the line for embeddings AND image generation in one edit, leaving audio, **§35.7** (scope the bundled-adapter rule, Decision #2), **§27** (module tree), **§29** (telemetry event names).

### Layer demonstration

**Layer A** — build and serialize a request with no engine, no adapter, no network:

```elixir
req = ALLM.embedding_request(["a kestrel", "a cedar branch"], task_type: :search_document)
:ok = ALLM.Validate.embedding_request(req)
json = ALLM.Serializer.to_json!(req)
{:ok, ^req} = ALLM.Serializer.from_json(json)
```

**Layer B** — call an adapter directly, bypassing the façade entirely:

```elixir
req = ALLM.EmbeddingRequest.new(input: ["hello"], model: "text-embedding-3-small")
{:ok, %ALLM.EmbeddingResponse{embeddings: [%ALLM.Embedding{vector: v}]}} =
  ALLM.Providers.OpenAI.Embeddings.embed(req, api_key: "sk-...")
1536 = length(v)
```

**Layer C** — the façade, with chunking and telemetry:

```elixir
engine = ALLM.Engine.new(embed_adapter: ALLM.Providers.OpenAI.Embeddings, model: "text-embedding-3-small")
{:ok, resp} = ALLM.embed(engine, Enum.map(1..5_000, &"chunk #{&1}"))   # 3 HTTP calls, merged
5_000 = length(resp.embeddings)
[[_ | _] | _] = ALLM.EmbeddingResponse.vectors(resp)                    # ready for pgvector
```

There is deliberately **no Layer D**: embeddings carry no conversation state, so `ALLM.Session` is untouched.

### Prerequisites

- Phases 13–17 image capability: `lib/allm/image_adapter.ex`, `lib/allm/image_request.ex`, `lib/allm/providers/openai/images.ex`, `conformance/lib/allm/test/image_adapter_conformance.ex`.
- `ALLM.Retry` (`lib/allm/retry.ex`), `ALLM.Keys` (`lib/allm/keys.ex`), `ALLM.Telemetry.span/3` (`lib/allm/telemetry.ex:116-119` docs, `:168-173` implementation).
- A `VOYAGE_API_KEY` for the 20.6 live gate. Voyage's free tier covers the examples budget.
- No new deps. `Req` handles the synchronous JSON POST; no streaming, no multipart, no direct `Finch`.

### Out of scope

| Excluded | Why |
|----------|-----|
| Multimodal / image embeddings | Different endpoint, different input union. Separate phase. |
| `encoding_format: "base64"` | Divergence D3 — not provider-neutral (Gemini has no base64 form). |
| `output_dtype: int8/binary` (Voyage-only) | Quantized embeddings need a `vector` vs `halfvec` vs `bit` decision on the pgvector side that belongs to the caller's schema. |
| Reranking (Voyage/Cohere `/rerank`) | Different primitive, different result shape (scores, not vectors). |
| Token counting / pre-truncation | Requires a tokenizer per provider. `truncate: true` (the provider-side default) covers the common case. |
| pgvector/Ecto integration code | Assumption 4 — documented in a guide, not shipped as code. |
| `ALLM.Session` integration | Embeddings carry no conversation state. |
| Streaming | Assumption 3. |
| Local models (Ollama, llama.cpp) | Separate package per §32. |
| Multi-vector / ColBERT | Provider matrix doesn't support it. |
| Audio | `steering/PHASE_19_DESIGN.md` (§37). |
| Parallel chunk dispatch | Decision #6 — sequential is the safe default under provider rate limits. |

### Non-obvious decisions

1. **No `ALLM.Providers.Anthropic.Embeddings`; `ALLM.Providers.Voyage.Embeddings` is the Anthropic track.** Assumption 1. Naming a Voyage client after Anthropic would assert a wire that does not exist. *Docs target: `@moduledoc ALLM.Providers.Voyage.Embeddings` + `guides/embeddings.md` "Which provider?" table + spec §36.7.*
2. **§35.7's bundled-adapter rule is scoped, not broken.** The rule ("in-tree adapters are the ones whose maintenance overlaps with their provider's already-bundled chat adapter") was written for image generation, where every candidate had a chat-adapter sibling. Voyage has none. The amendment adds a second, explicit admission criterion: *an adapter may be bundled when it is the provider's own officially-recommended path for a capability that provider does not offer.* A one-off carve-out with a named beneficiary — Cohere/Mistral/Jina embeddings remain out-of-core. *Docs target: spec §35.7 amendment + §36.7.*
3. **`ALLM.Usage` is reused; no `EmbeddingUsage`.** Divergence D2, with the three defects in PHASE_20's Decision #4 cited there. Adapters populate `:input_tokens` and `:total_tokens`; `:output_tokens` is always `nil`. Gemini reports only `usageMetadata.promptTokenCount` and Voyage only `usage.total_tokens`, so one of the two fields is `nil` on those providers — documented per-adapter. *Docs target: `@doc ALLM.EmbeddingResponse` usage section + each adapter's wire-field table.*
4. **`:task_type` is a provider-neutral closed enum that OpenAI ignores.** Asymmetric embedding (encode queries differently from documents) measurably improves retrieval on Gemini (`taskType`) and Voyage (`input_type`), and is the highest-leverage knob for the RAG use case this phase targets. OpenAI has no equivalent, so `ALLM.Providers.OpenAI.Embeddings` drops the field and logs at `:debug` via the deferred form (`Logger.debug(fn -> ... end)`, per CLAUDE.md). A dropped-not-errored field matches the contract images set for `response_format` on `gpt-image-1` (`lib/allm/providers/openai/images.ex:42-51`). *Docs target: `@doc ALLM.EmbeddingRequest.new/1` + each adapter's wire-field table.*
5. **The façade chunks; adapters never see more than `max_batch_size/0` inputs.** Alternative C. `ALLM.EmbeddingBatch.run/4` splits, dispatches sequentially under `Retry.run/3` per chunk, rebases each chunk's embeddings by `offset + item.index`, and sums usage. *Docs target: `@doc ALLM.embed/3` "Batching" section + `guides/embeddings.md`.*
6. **Chunks dispatch sequentially, not in parallel.** A 5,000-input ingest is 50 Gemini calls; firing those concurrently is the fastest way to a 429 storm, and `Retry.run/3` would then serialize them anyway with backoff attached. *Docs target: `@doc ALLM.embed/3`.*
7. **Gemini vectors are L2-normalized in-adapter whenever `:dimensions` is set to anything other than 3072 — unconditionally across models, by design.** Google documents that `gemini-embedding-001` returns pre-normalized vectors at its native 3072 dimensions but **not** at truncated dimensionalities, while the newer `gemini-embedding-2` auto-normalizes truncated dimensions too ([ai.google.dev/gemini-api/docs/embeddings](https://ai.google.dev/gemini-api/docs/embeddings), verified 2026-07-28; batch endpoint re-verified via context7 on 2026-07-29). The adapter does **not** branch on model id. Re-normalizing an already-unit vector is a no-op to within `1.0e-9` (the `normalize/1` idempotency invariant), so the unconditional rule is safe on `gemini-embedding-2` and correct on `-001`, and it does not go stale when Google ships `-3`. A model-conditional rule would be a hard-coded allow-list that silently mis-handles every future model — the failure mode CLAUDE.md's closed-enum guidance warns about. pgvector's `vector_cosine_ops` tolerates unnormalized input but `<#>` (inner product) silently returns wrong rankings, and a mixed-normalization table is unrecoverable after the fact. Normalizing in-adapter makes every ALLM-produced vector unit-length regardless of provider or model. *Docs target: `@moduledoc ALLM.Providers.Gemini.Embeddings` + `guides/embeddings.md` + spec §36.6. **Resolved Question 4**.*
8. **`ALLM.Embedding.__from_tagged__/1` coerces integer vector elements to floats.** `Jason` round-trips `0.0` as `0.0`, but a hand-built `%Embedding{vector: [0, 1]}` decodes to integers, breaking the `[float()]` type and any `Enum.sum/1`-based normalization downstream. The decoder applies `* 1.0`. Same class as `ImageRequest.decode_size/1`'s shape restoration (`lib/allm/image_request.ex:120-128`). *Docs target: `@doc false` on `__from_tagged__/1` + serializability test.*
9. **`EmbeddingResponse.vectors/1` sorts by `:index` before flattening.** Guarantees `Enum.at(vectors, i)` ↔ `Enum.at(request.input, i)` even when a provider returns out-of-order items or a chunk merge interleaves. Implements PHASE_20's Decision #3 order invariant. *Docs target: `@doc ALLM.EmbeddingResponse.vectors/1`.*
10. **`:batch_too_large` exists even though the façade never triggers it.** Direct adapter calls (Layer B composability) bypass chunking. Per AGENT_DESIGN_SPEC.md rule 13, its current-phase use sites are each adapter's `embed/2` pre-flight guard (20.4–20.6 checklists) and conformance case 3. *Docs target: `ALLM.Error.EmbeddingAdapterError` reason table.*
11. **Adapters use the `:gemini` and `:voyage` key atoms.** `ALLM.Keys`'s table maps `:google → "GOOGLE_API_KEY"` (`lib/allm/keys.ex:55-62`), but every committed Gemini adapter calls `Keys.fetch!(:gemini, opts)` (`lib/allm/providers/gemini.ex:207`, `lib/allm/providers/gemini/images.ex:487`), falling through to the `"GEMINI_API_KEY"` default. The embeddings adapter matches its siblings, not the table. `:voyage` is a new atom taking the same fallback to `"VOYAGE_API_KEY"`; no `@env_var_table` edit needed. *Docs target: each adapter's `@moduledoc` key-resolution line.*
12. **The façade validates; `generate_image/3` does not.** Adopted from `PHASE_20_DESIGN.md:273`'s error-flow ordering. The asymmetry with `lib/allm.ex:753-758` is deliberate: an empty-string input is a guaranteed provider 400, and in a chunked call it should fail before 49 successful HTTP round-trips are spent. *Docs target: `@doc ALLM.embed/3` "Validation policy" section.*

---

## Behaviour & Type Contracts

### Layer A — `ALLM.Embedding`

```elixir
defmodule ALLM.Embedding do
  @enforce_keys [:vector]
  defstruct [:vector, index: 0, metadata: %{}]

  @type t :: %__MODULE__{
          vector: [float()],
          index: non_neg_integer(),
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "L2-normalize the vector. Returns the embedding unchanged when the magnitude is 0.0."
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{} = embedding)

  @doc "Euclidean norm of the vector."
  @spec magnitude(t()) :: float()
  def magnitude(%__MODULE__{})

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end

defimpl Jason.Encoder, for: ALLM.Embedding do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**Idioms named.** `@enforce_keys [:vector]` (adopted from `PHASE_20_DESIGN.md:109`) is what makes `ALLM.Embedding.new([])` raise — **`ArgumentError`, not `KeyError`**. `struct!/2` raises `ArgumentError` ("the following keys must also be given when building struct") when an `@enforce_keys` field is absent, and `KeyError` when an *unknown* key is supplied. `@enforce_keys [:vector]` alongside `defstruct [:vector, index: 0, metadata: %{}]` compiles cleanly. *(All three verified in IEx on 2026-07-28, Elixir 1.17.3 / OTP 27.)* Both exception shapes are asserted separately in the Test Plan. `:index` defaults to `0` rather than `nil` (divergence D4). `__from_tagged__/1` coerces integer elements via `* 1.0` (Decision #8).

**`@enforce_keys` does NOT reject an explicit `nil`.** `struct!(ALLM.Embedding, vector: nil)` *succeeds* (verified in IEx on 2026-07-28) — enforcement is on key *absence*, not value. `:vector` is left unguarded: the only construction paths are adapter decoders, which always supply a list, and the `:malformed_response` rule below covers the degenerate case. This is a deliberate application of CLAUDE.md's "Layer-A constructors are `struct!/2` pass-throughs by default; runtime type validation is the exception" — no `is_list/1` guard, unlike the documented `Tool.new/1` exception (`lib/allm/tool.ex:105-121` — this cite was inherited from `CLAUDE.md` as `:90-99`, which at HEAD is the `@doc` examples block, not the guard; re-verified 2026-07-29).

**Invariants:**
- `normalize/1` is idempotent to within `1.0e-9`.
- `normalize/1` returns the input unchanged whenever `magnitude/1` is `0.0` — which covers `vector: []`, an all-zero vector, **and** a vector whose components underflow (`[1.0e-200, 1.0e-200]` squares to `0.0`; verified in IEx on 2026-07-28). No `ArithmeticError`, no `NaN`.
- `magnitude/1` **raises `ArithmeticError` on float overflow.** Erlang's `*` raises `badarith` rather than producing infinity — `1.0e200 * 1.0e200` raises (verified in IEx on 2026-07-28). No embedding provider returns components anywhere near `1.0e150`, so the naïve `:math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))` is correct for every real input; the contract documents the bound rather than paying for max-scaling. The property test's generator is bounded accordingly.
- An adapter that would construct `%Embedding{vector: []}` from a provider response returns `%EmbeddingAdapterError{reason: :malformed_response}` instead (`PHASE_20_DESIGN.md:121`).

### Layer A — `ALLM.EmbeddingRequest`

```elixir
defmodule ALLM.EmbeddingRequest do
  @type task_type ::
          :search_document | :search_query | :classification | :clustering | :similarity

  @type t :: %__MODULE__{
          input: [String.t()],
          model: String.t() | nil,
          dimensions: pos_integer() | nil,
          task_type: task_type() | nil,
          truncate: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :dimensions,
    :task_type,
    input: [],
    truncate: true,
    options: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**Idioms named.** `:task_type` is a closed atom enum decoded with `ALLM.Serializer.to_atom_field/1`; an unknown value raises `ArgumentError` and surfaces as `{:_unknown, :atom_decode_failed}` per the serializer's rescue contract — identical to `ImageRequest`'s `:operation` handling (`lib/allm/image_request.ex:32-35`). **Adapter authors (20.4–20.6): a decoded `:task_type` is NOT guaranteed enum-legal.** `to_atom_field/1` is `String.to_existing_atom/1`, so it rejects a never-defined atom but admits any *already-loaded* one — `"task_type": "erlang"` decodes to `:erlang`. Only the opt-in `Validate.embedding_request/1` narrows it to the five-member enum. Each adapter must therefore map through the closed enum with an exhaustive `to_<provider>_task_type/1` (falling through to omit), never `Atom.to_string/1` the field onto the wire. No `keyword()`-typed field, so no kwlist pre-pass. No tuple-typed field, so the `Jason.Encoder` impl is a plain `encode_tagged/2` delegate with **no** pre-pass (contrast `ImageRequest`'s `:size`, `lib/allm/image_request.ex:152-155`). No `@enforce_keys` here — `input: []` is a legal default that the validator rejects, which is what lets `ALLM.embedding_request/2` build incrementally.

**Invariants:**
- `:input` is always a list on the struct. The bare-string form is normalized at `ALLM.embedding_request/2`, never on the struct.
- `:truncate` defaults to `true`, matching the provider-side default on all three targets, so the field is omitted from the wire body when `true` and sent explicitly only when `false`.

### Layer A — `ALLM.EmbeddingResponse`

```elixir
defmodule ALLM.EmbeddingResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          embeddings: [ALLM.Embedding.t()],
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :raw,
    embeddings: [],
    usage: %ALLM.Usage{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "Vectors sorted by `:index`, flattened for direct insertion into a `vector(N)` column."
  @spec vectors(t()) :: [[float()]]
  def vectors(%__MODULE__{})

  @doc "Length of the first vector, or `nil` when `:embeddings` is empty. Use to size a `vector(N)` column."
  # non_neg_integer(), NOT pos_integer(): the body is `length(vector)` and a
  # caller can hand-build `%Embedding{vector: []}`, so 0 is reachable. Only
  # adapters are bound by the `:malformed_response` rule, and Dialyzer will
  # not flag a narrowing that merely overlaps.
  @spec dimensions(t()) :: non_neg_integer() | nil
  def dimensions(%__MODULE__{})

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**Idioms named.** `:usage` defaults to `%ALLM.Usage{}`, never `nil` — mirrors `ImageResponse`'s `usage: %ImageUsage{}` default (`lib/allm/image_response.ex:34`) and its `hydrate_usage/1` fallback (`lib/allm/image_response.ex:68-77`). `:raw` carries the same caller-responsibility contract as `ALLM.Response.raw`: a non-JSON-encodable `:raw` raises `Jason.EncodeError` at encode time (`lib/allm/image_response.ex:10-13`).

**Invariants:**
- **Order correspondence:** `Enum.at(vectors(response), i)` is the embedding of `Enum.at(request.input, i)` for every `i`. Preserved across chunk merges by Decision #5's rebasing and Decision #9's sort.
- **Uniform dimensionality:** every vector in `:embeddings` has the same length. Asserted in the conformance suite, not enforced by the constructor.
- **Cardinality:** `length(response.embeddings) == length(request.input)` on success.

### Layer A — `ALLM.Error.EmbeddingAdapterError`

Shape mirrors `ALLM.Error.ImageAdapterError` (`lib/allm/error/image_adapter_error.ex:45-53`) exactly — same fields, same `@legal_reasons ~w(...)a` mirror, same `new/2` raising `ArgumentError` on an unlisted atom, same `defexception` + three-clause `message/1`, same `__from_tagged__/1`.

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

@type t :: %__MODULE__{
        reason: reason(),
        message: String.t(),
        provider: atom() | nil,
        status: pos_integer() | nil,
        retry_after_ms: non_neg_integer() | nil,
        cause: term() | nil,
        metadata: map()
      }
```

**Delta vs `ImageAdapterError`'s 12 atoms** (`lib/allm/error/image_adapter_error.ex:31-43`): `−:content_filter` and `−:unsupported_operation` (both per `PHASE_20_DESIGN.md:32`), `+:batch_too_large` (new — Decision #10). Count: **11**. This module DOES carry a `legal_reasons/0` accessor and a `length(...) == 11` doctest, matching `ImageAdapterError` (`lib/allm/error/image_adapter_error.ex:82`).

**Rule-13 use sites for every atom.** Nine are exercised by the HTTP status→reason mapping tables in 20.4–20.6. The two that are not:

- **`:batch_too_large`** — each adapter's pre-flight guard (invariant 4) and conformance case 3.
- **`:unsupported_feature`** — `ALLM.Providers.OpenAI.Embeddings`' pre-flight rejection of `dimensions:` on `text-embedding-ada-002`. OpenAI documents `dimensions` as supported "only in `text-embedding-3` and later models" ([openai.com/index/new-embedding-models-and-api-updates](https://openai.com/index/new-embedding-models-and-api-updates/), verified 2026-07-28); sending it to `ada-002` is a request the adapter can see is malformed without a round-trip. `metadata: %{feature: :dimensions, model: model}`. Test bullet in 20.4.

**Idiom named:** `defexception` with a `message/1` catch-all for a struct built by hand rather than through `new/2` — copy `lib/allm/error/image_adapter_error.ex:139-148` verbatim, substituting `"embedding adapter error"`.

### Layer A — closed-enum extensions to committed modules

Both atoms are verified absent from the committed enums and are added as scoped amendments:

| Module | File:line of committed enum | Added atom | Current-phase use site (rule 13) |
|--------|-----------------------------|------------|----------------------------------|
| `ALLM.Error.EngineError` | `lib/allm/error/engine_error.ex:13-21` (8 atoms) | `:no_embed_adapter` | `ALLM.do_embed_body/5`'s `%Engine{embed_adapter: nil}` head (20.3) |
| `ALLM.Error.ValidationError` | `lib/allm/error/validation_error.ex:31-39` (8 atoms) | `:invalid_embedding_request` | `ALLM.Validate.embedding_request/1` (20.1) |

**Each atom goes in TWO places per module** — `@type reason` and the private `@legal_reasons ~w(…)a` mirror consumed by `new/2`'s `unless reason in @legal_reasons` guard. Adding to `@type reason` alone leaves `EngineError.new(:no_embed_adapter)` raising `ArgumentError` at runtime (`PHASE_20_DESIGN.md:396` names the same trap).

**There is nothing to bump.** Unlike `AdapterError` and `ImageAdapterError`, neither `EngineError` nor `ValidationError` exposes a `legal_reasons/0` accessor or carries a length doctest — `def legal_reasons` exists only at `lib/allm/error/adapter_error.ex:82` and `lib/allm/error/image_adapter_error.ex:82` (verified 2026-07-28). Do not add accessors to these two modules as a side effect of this phase.

### Layer A — serializer registration (part of the contract)

`@known_modules` (`lib/allm/serializer.ex:65-91`, 25 entries) gains four **across two sub-phases** — the Module Tree is authoritative on the split, and registering the 20.2 entry early compiles silently (an undefined module atom in a list literal produces no warning, and no test asserts registry membership against loadable modules), so it would sit dangling until 20.2 lands:

```elixir
  ALLM.Error.EmbeddingAdapterError,  # 20.2 — module does not exist until 20.2
  ALLM.Embedding,                    # 20.1
  ALLM.EmbeddingRequest,             # 20.1
  ALLM.EmbeddingResponse             # 20.1
```

`@type_tag_index` (`lib/allm/serializer.ex:93`) derives from `@known_modules`, so no second edit. Note this is **four**, not the five `PHASE_20_DESIGN.md` implied — `EmbeddingUsage` does not exist (divergence D2), and `ALLM.Usage` is already registered at `lib/allm/serializer.ex:75`.

### Layer B — `ALLM.EmbeddingAdapter`

```elixir
defmodule ALLM.EmbeddingAdapter do
  @callback embed(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, ALLM.EmbeddingResponse.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @callback max_batch_size() :: pos_integer()

  @callback prepare_request(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
```

Each callback traces to a user-visible operation (behaviour-checklist rule 1): `embed/2` is `ALLM.embed/3`'s dispatch target; `max_batch_size/0` is read by `ALLM.EmbeddingBatch.run/4` *and* by callers doing resumable chunking (`guides/embeddings.md`); `prepare_request/2` is the §7.1 escape hatch, optional exactly as on `ALLM.ImageAdapter` (`lib/allm/image_adapter.ex:103`).

**Note on `prepare_request/2`'s return type:** `{:ok, Req.Request.t()}`, matching `ALLM.ImageAdapter` (`lib/allm/image_adapter.ex:85-86`). `PHASE_20_DESIGN.md:226-227` typed it `{:ok, ALLM.EmbeddingRequest.t()}` — that is a transcription slip; the whole point of the escape hatch is handing back an unfired HTTP request (§7.1).

**Invariants** (what the conformance suite asserts — mirrors `lib/allm/image_adapter.ex:35-63`):

1. `embed/2` is synchronous: returns only after the HTTP response is read in full.
2. `embed/2` never raises for HTTP-shaped failures. Network failures, 4xx, and 5xx all convert to `{:error, %EmbeddingAdapterError{}}`. **Exception:** `ALLM.Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented design (`lib/allm/keys.ex:126-131`); adapters do not rescue it, matching `lib/allm/providers/openai/images.ex:468-472`.
3. `embed/2` MUST honor `opts[:request_timeout]`; exceeding it produces `{:error, %EmbeddingAdapterError{reason: :timeout}}`.
4. `embed/2` MUST return `{:error, %EmbeddingAdapterError{reason: :batch_too_large, metadata: %{count: n, max: max_batch_size()}}}` BEFORE any HTTP I/O when `length(request.input) > max_batch_size()`.
5. `embed/2` MUST return `{:error, %EmbeddingAdapterError{reason: :invalid_request}}` for `input: []` before any HTTP I/O (`PHASE_20_DESIGN.md:239` — the bar holds at the adapter for direct-adapter callers even though the façade also validates).
6. `embed/2` MUST preserve `opts[:request_id]` onto `response.request_id` when the response shape allows.
7. `embed/2` MUST round-trip `request.metadata` onto `response.metadata` UNCHANGED when the adapter has no use for it.
8. `embed/2` MUST return exactly `length(request.input)` embeddings on success, with `:index` values `0..length-1`, each vector the same non-zero length.
9. `max_batch_size/0` is per-module and constant — not per-model. Per-model limits are the adapter's internal concern (mirrors `supported_operations/0`'s per-module contract, `lib/allm/image_adapter.ex:88-101`).
10. `prepare_request/2` returns an unfired `Req.Request` configured exactly as `embed/2` would fire it, and is defined only for `length(input) <= max_batch_size()`.

**Cleanup invariant:** none. There is no `Stream.resource/3` and no Finch ref — `Req.request/1` owns its connection lifecycle. Stated explicitly per behaviour-checklist rule 4 so the absence reads as intent.

**Invariant → conformance-case mapping.** The suite does *not* assert one case per invariant; invariants 1, 2, 3, 9, and 10 are either unobservable from outside (1, 2) or exercised in the adapters' own test files (3, 9, 10). The mapping is explicit so neither list drifts:

| Case | Asserts |
|------|---------|
| 1 | `max_batch_size/0` returns a `pos_integer()` (invariant 9, shape only) |
| 2 | single input → one embedding with `index: 0` (invariant 8, degenerate case) |
| 3 | `length(input) > max_batch_size()` → `:batch_too_large` before HTTP I/O (invariant 4) |
| 4 | `input: []` → `:invalid_request` before HTTP I/O (invariant 5) |
| 5 | exactly `length(input)` embeddings (invariant 8) |
| 6 | `:index` values are exactly `0..length-1` (invariant 8) |
| 7 | all vectors identical, non-zero length (`EmbeddingResponse` uniform-dimensionality invariant) |
| 8 | `request.metadata` round-trips unchanged (invariant 7) |
| 9 | `opts[:request_id]` preserved onto `response.request_id` (invariant 6) |
| 10 | `response.usage` is a `%ALLM.Usage{}`, never `nil` (`EmbeddingResponse` default) |

Invariant 3 (`request_timeout` → `:timeout`) is asserted per-adapter, not in the suite — it needs a hanging transport the suite cannot portably provide. Each of 20.4/20.5/20.6 carries an explicit bullet for it.

**Conformance-suite surface:** the suite calls only `embed/2` and `max_batch_size/0` — no `impl.script/0`-style introspection (rule 3). `@case_count 10` with a `case_count/0` accessor and a meta-test asserting the injected `describe/2` produces exactly 10 `test` cases (rule 7).

**How real adapters are driven through the suite — NOT `Req.Test`.** The `conformance/` directory is a separate Mix project whose deps are `{:allm, path: ".."}`, `:jason`, `:credo`, `:dialyxir` (`conformance/mix.exs:29-40`) — **`:plug` is absent**, so `Req.Test.stub/2` is unavailable inside the injected `using` macro. The committed mechanism is instead an **in-`lib/` test-injection short-circuit**, exactly as the image adapters do it:

```elixir
# lib/allm/providers/openai/images.ex:251-253 — the pattern to copy
def generate(%ImageRequest{} = request, opts) when is_list(opts) do
  case fetch_image_script(opts) do
    nil -> do_generate(request, opts)
    _script -> FakeImages.generate(request, opts)
  end
end
```

Each real embeddings adapter therefore ships `adapter_opts[:embedding_script]` support in `lib/`, delegating to `ALLM.Providers.FakeEmbeddings.embed/2` **before any gate runs**, documented in a "## Test-injection escape hatch" `@moduledoc` section (`lib/allm/providers/openai/images.ex:103-111` is the model). This is a production-code deliverable, listed in the 20.4, 20.5, and 20.6 checklists.

**Consequence for cases 3 and 4.** Because the script short-circuit fires *before* the gates, a scripted adapter can never reach its own `:batch_too_large` / `:invalid_request` guards. Cases 3 and 4 are therefore driven by a **sister stub** that implements the behaviour with real gates and a scripted success path — mirroring how the image suite uses `conformance/test/support/fixtures/scripted_image_stub.ex` for its gate-ordering case. `conformance/test/support/fixtures/scripted_embedding_stub.ex` is the embeddings analogue and is listed in the Module Tree.

### Layer B — `ALLM.Engine` extension

`:embed_adapter` must be added at **five** sites. All five are part of the contract; missing any one produces a silent failure rather than a compile error. (`PHASE_20_DESIGN.md:245-249` enumerated three and folded `restore_module/1` into the third; the `@module_fields` guard is the one it missed.)

| Site | File:line | Edit |
|------|-----------|------|
| `@type t` | `lib/allm/engine.ex:90-103` | `embed_adapter: module() \| nil` |
| `defstruct` | `lib/allm/engine.ex:106-120` | `:embed_adapter` in the nil-default group |
| `@engine_field_keys` | `lib/allm/engine.ex:129-143` | `:embed_adapter` — **consumer/producer symmetry:** this deny-list is what keeps the field out of `resolve_params/2`'s adapter-bound params map. Omitting it leaks the module atom into every provider's wire body. |
| `@module_fields` | `lib/allm/engine.ex:150` | `:embed_adapter` — enables the `is_atom/1` construction guard in `validate_module_fields!/1` (`lib/allm/engine.ex:204-219`) |
| `__from_tagged__/1` | `lib/allm/engine.ex:476-495` | `embed_adapter: restore_module(data["embed_adapter"])`, mirroring `:image_adapter` at `lib/allm/engine.ex:488` |

### Layer B — `ALLM.Capability` extension

```elixir
@type embedding_preflight_result :: :ok | {:error, ALLM.Error.ValidationError.t()}

@spec preflight_embedding(model_ref_or_string(), ALLM.EmbeddingRequest.t()) ::
        embedding_preflight_result()
def preflight_embedding(model, request)
```

2-arity with no rewrite branch — symmetric with `preflight_image/2` (`lib/allm/capability.ex:261-273`), **not** with the chat `preflight/3` (`lib/allm/capability.ex:179-193`), which returns a `{:ok, Request.t()}` rewrite arm. Returns `:ok` unconditionally when `catalog_loaded?/0` is false.

**Two** gates, both following the established both-key-shapes pattern (`lib/allm/capability.ex:437-447`) — the second is inherited from `PHASE_20_DESIGN.md:324` and is what makes the validator's silence about per-model dimension caps correct rather than a hole:

```elixir
defp check_embeddings_enabled(acc, %ModelRef{capabilities: caps}) do
  case caps do
    %{embeddings_enabled: false} -> [{[:embeddings_enabled], :embeddings_disabled} | acc]
    %{"embeddings_enabled" => false} -> [{[:embeddings_enabled], :embeddings_disabled} | acc]
    _ -> acc
  end
end

defp check_dimensions_max(acc, _caps, %EmbeddingRequest{dimensions: nil}), do: acc

defp check_dimensions_max(acc, %ModelRef{capabilities: caps}, %EmbeddingRequest{dimensions: d}) do
  case caps do
    %{dimensions_max: m} when is_integer(m) and d > m -> [{[:dimensions], :exceeds_max} | acc]
    %{"dimensions_max" => m} when is_integer(m) and d > m -> [{[:dimensions], :exceeds_max} | acc]
    _ -> acc
  end
end
```

Missing key ⇒ no rejection, per the module-wide graceful-degradation rule. Because `llm_db` is not a dependency today (Assumption 6), **both gates are inert in practice** — a `dimensions: 99_999` request reaches the provider and earns a 400 mapped to `:invalid_request`. That is the intended degradation, and it is why the field-error vocabulary deliberately omits a dimension-cap row: the cap is model-specific data the validator does not have.

### Layer B — `ALLM.Telemetry` extension

`@type span_name` and `@valid_span_names` (`lib/allm/telemetry.ex:68-70`) both gain `:embed`. Events: `[:allm, :embed, :start]` / `[:allm, :embed, :stop]`. Uses the 3-tuple `span/3` return (`lib/allm/telemetry.ex:116-119`, implemented at `:168-173`) for numeric measurements, exactly as `:image` does.

- **`:start`** — measurements `system_time`; metadata `request_id`, `engine`, `model`, `input_count`.
- **`:stop`** — measurements `duration`, `embedding_count`, `chunk_count`; metadata `request_id`, `model`, `usage`, `response`, `error` (nil on success).

`embedding_count` is absent from measurements on error paths, matching `image_count` (`PHASE_20_DESIGN.md` Decision #6). `chunk_count` is the observability payoff for Decision #5 — it is the only signal that one `ALLM.embed/3` call became 50 HTTP requests.

### Layer C — façade

```elixir
defmodule ALLM do
  @spec embedding_request(String.t() | [String.t()], keyword()) :: ALLM.EmbeddingRequest.t()
  def embedding_request(input, opts \\ [])

  @spec embed(
          ALLM.Engine.t(),
          String.t() | [String.t()] | ALLM.EmbeddingRequest.t(),
          keyword()
        ) ::
          {:ok, ALLM.EmbeddingResponse.t()}
          | {:error,
             ALLM.Error.EngineError.t()
             | ALLM.Error.ValidationError.t()
             | ALLM.Error.EmbeddingAdapterError.t()}
  def embed(engine, input_or_request, opts \\ [])
end
```

**Cross-layer accept-set reconciliation (rule 11).** `embed/3`'s public accept set is `String.t() | [String.t()] | EmbeddingRequest.t()`. The boundary transform is `embedding_request/2`, which normalizes a bare `String.t()` to `[String.t()]`. Every downstream consumer (`Validate.embedding_request/1`, `EmbeddingBatch.run/4`, each adapter's `embed/2`) sees `input: [String.t()]` only. No consumer's accept set is narrower than the public one.

**`embedding_request/2` filters opts before `struct!/2` — this is load-bearing, not incidental.** `EmbeddingRequest.new/1` is a bare `struct!/2`, which raises `KeyError` on *any* unknown key (verified in IEx on 2026-07-28). `ALLM.embed/3`'s `opts` legitimately carries `:request_id`, `:request_timeout`, `:retry`, `:adapter_opts`, `:api_key`, `:telemetry_metadata`, and `:stream` — none of which are `EmbeddingRequest` fields. Without a filter, `ALLM.embed(engine, "hi", request_id: "x")` raises. The transform is an explicit **allow-list**, not a deny-list, so a new façade opt can never leak into the struct:

```elixir
@request_field_opts [:model, :dimensions, :task_type, :truncate, :options, :metadata]

def embedding_request(input, opts \\ []) do
  opts
  |> Keyword.take(@request_field_opts)
  |> Keyword.put(:input, List.wrap(input))
  |> ALLM.EmbeddingRequest.new()
end
```

**Consumer/producer symmetry.** `@request_field_opts` must equal the `EmbeddingRequest` field set minus `:input`. A field added to the struct without a matching entry here is silently unreachable from the string/list call shape. Asserted by a test that diffs `@request_field_opts` against `Map.keys(Map.from_struct(%EmbeddingRequest{})) -- [:input]`.

This is the same shape as `PHASE_20_DESIGN.md:280-290`'s per-field `Keyword.get/2` build, expressed as a single `Keyword.take/2`. Note that `drop_embedding_request_opts/1` (20.3 checklist) is the **outbound** analogue — it strips request-control opts before the adapter call, mirroring `drop_request_opts/1` at `lib/allm.ex:943-954`. The two filters are independent and neither substitutes for the other.

**Dispatch order** — the five-gate ordering from `PHASE_20_DESIGN.md:273`, expanded to nine numbered steps by the telemetry wrapper and the batch step:

1. Mint `request_id = opts[:request_id] || ALLM.Telemetry.request_id()`; `Engine.resolve_model(engine, opts)`.
2. Open `ALLM.Telemetry.span(:embed, ...)` around everything, so `:start` fires even when the adapter is missing.
3. **Adapter-presence gate FIRST** — `%Engine{embed_adapter: nil}` head returns `{:error, EngineError.new(:no_embed_adapter)}`. Load-bearing ordering, per the comment at `lib/allm.ex:990-992`: a missing adapter must surface `:no_embed_adapter`, not `:unsupported_capability`.
4. `ALLM.Validate.embedding_request/1` → `{:error, %ValidationError{reason: :invalid_embedding_request}}` (Decision #12).
5. `Capability.preflight_embedding/2` → `{:error, %ValidationError{reason: :unsupported_capability}}`.
6. Stamp `request.model || resolved_model` onto the request (`lib/allm.ex:1010` precedent).
7. adapter_opts concat + `Engine.put_cursor_key/2` — `engine.adapter_opts ++ call_adapter_opts`, so **engine wins** on collision (`Keyword.get/2` returns the first occurrence; NOT `Keyword.merge/2`, which has opposite precedence — `lib/allm.ex:1025-1027`).
8. `ALLM.EmbeddingBatch.run/4` — chunk, dispatch each chunk under `Retry.run/3` (key resolution happens inside the adapter, so `:missing_key` raises here), merge.
9. Fill `response.request_id` iff the adapter left it `nil`.

**Retry vocabulary.** `ALLM.Retry`'s default `retry_on` is HTTP-status-coded (`[429, 500, 502, 503, 504, :timeout]`, `lib/allm/retry.ex:138-147`) but adapter errors carry closed-enum atoms. Embeddings copy the **image** convention — widen the policy at the call site (`augment_image_retry_policy/1`, `lib/allm.ex:1078-1088`) and have adapters return real reason atoms — rather than the older chat convention of swapping `reason` to the HTTP status and stashing the real error under `metadata.final_error`:

```elixir
@retryable_embedding_reasons [:rate_limited, :provider_unavailable, :timeout, :network_error]
```

**Retry and timeout budgets are PER-CHUNK, and `ALLM.embed/3` has no total-time bound.** This is the direct consequence of Decision #5 and must be documented on the public function, not discovered in production:

| Budget | Scope | Worst case for a 5,000-input Gemini ingest (50 chunks) |
|--------|-------|--------------------------------------------------------|
| `Retry` `max_attempts` (default `3`, `lib/allm/retry.ex:138-147`) | per chunk | **150 HTTP requests** |
| `opts[:request_timeout]` | per chunk | 50 × the value |
| `Retry` backoff (`base_delay_ms: 500`, `max_delay_ms: 30_000`, `respect_retry_after: true`) | per chunk | tens of minutes of wall clock under sustained 429s |
| Telemetry `:embed` span `duration` | **whole call** — covers every chunk, every retry | one number for the entire ingest |

No `:max_total_attempts` and no total deadline are introduced (Alternative E). `@doc ALLM.embed/3` states the multiplication explicitly and directs callers wanting a bound to chunk themselves against `max_batch_size/0` and wrap each call — the loop `guides/embeddings.md` already shows for resumability serves double duty as the deadline-control recipe. `chunk_count` on the `:stop` measurement is what makes the multiplier observable after the fact.

### Layer C — `ALLM.EmbeddingBatch`

```elixir
defmodule ALLM.EmbeddingBatch do
  @moduledoc false

  @spec run(ALLM.EmbeddingRequest.t(), module(), keyword(), map()) ::
          {:ok, ALLM.EmbeddingResponse.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}
  def run(request, adapter, dispatch_opts, telemetry_metadata)

  @doc false
  @spec chunk(ALLM.EmbeddingRequest.t(), pos_integer()) ::
          [{non_neg_integer(), ALLM.EmbeddingRequest.t()}]
  def chunk(request, max_batch_size)

  @doc false
  @spec merge([ALLM.EmbeddingResponse.t()]) :: ALLM.EmbeddingResponse.t()
  def merge(responses)
end
```

`chunk/2` and `merge/1` are `@doc false` + `@spec` public test seams — the CLAUDE.md pattern for helpers with nontrivial branching worth exercising without a full HTTP round-trip (precedent: nine such seams in `lib/allm/providers/openai/images.ex`).

**Cross-function invariants (rule 6c — shape-distinguishing).** `chunk/2` returns `{offset, sub_request}` pairs where `offset` is the index of the chunk's first input in the original `:input` list. `merge/1` consumes responses whose `:index` values have **already been rebased** by `run/4` (`%{e | index: offset + e.index}`) — `merge/1` itself does no rebasing and assumes globally-unique indices. Splitting rebase (in `run/4`) from merge is what lets `merge/1` be tested against hand-built responses.

Merge semantics:

| Field | Rule |
|-------|------|
| `:embeddings` | Concatenated, then sorted by `:index` |
| `:usage` | `:input_tokens` and `:total_tokens` summed across chunks, skipping `nil`; result is `nil` only if every chunk was `nil`. `:output_tokens` stays `nil`. |
| `:model` | First non-nil |
| `:id` / `:request_id` | First non-nil |
| `:raw` | First chunk's `:raw` only, with `metadata.chunk_count` recording how many were discarded |
| `:metadata` | First chunk's, plus `:chunk_count` |

**Single-chunk fast path:** when `length(input) <= max_batch_size()`, `run/4` dispatches once and returns the adapter's response with `metadata.chunk_count = 1` — no merge, so `:raw` is preserved intact for the overwhelmingly common case.

**Testing chunking requires a variable-batch stub.** `max_batch_size/0` is a zero-arity per-module constant (invariant 9), and `ALLM.Providers.FakeEmbeddings.max_batch_size/0` returns `2048` — so no chunking is observable through it, and a property quantifying over `max_batch_size in 1..500` has nothing to vary. `test/support/variable_batch_embedding_stub.ex` closes the gap:

```elixir
defmodule ALLM.Test.VariableBatchEmbeddingStub do
  @behaviour ALLM.EmbeddingAdapter

  @doc "Set the batch size for the calling process. Process-dict scoped, so `async: true` is safe."
  def put_max_batch_size(n) when is_integer(n) and n > 0,
    do: Process.put(__MODULE__, n)

  @impl true
  def max_batch_size, do: Process.get(__MODULE__, 100)

  @impl true
  defdelegate embed(request, opts), to: ALLM.Providers.FakeEmbeddings
end
```

Process-dictionary scoping (not `Application.put_env/3`) is deliberate: application env is global and would race across `async: true` test modules — the same class of foot-gun CLAUDE.md documents for `Logger.configure/1` and `:telemetry.attach/4`. It also mirrors `Fake`'s own process-dict cursor (`lib/allm/providers/fake.ex`'s `advance_process_dict_cursor/2`). The stub lives in `test/support/`, not `lib/` — unlike `FakeEmbeddings`, no user needs it.

---

## Module Tree

Every NEW/MODIFY file the phase touches, tagged with its sub-phase (completeness invariant).

```
lib/
├── allm.ex                                       (MODIFY — 20.3, embed/3 + embedding_request/2 + retry augmentation)
├── allm/
│   ├── embedding.ex                              (NEW — 20.1)
│   ├── embedding_request.ex                      (NEW — 20.1)
│   ├── embedding_response.ex                     (NEW — 20.1)
│   ├── embedding_adapter.ex                      (NEW — 20.2)
│   ├── embedding_batch.ex                        (NEW — 20.3)
│   ├── engine.ex                                 (MODIFY — 20.2, :embed_adapter across 5 sites)
│   ├── validate.ex                               (MODIFY — 20.1, add embedding_request/1)
│   ├── serializer.ex                             (MODIFY — 20.1 +3 entries, 20.2 +1 for EmbeddingAdapterError)
│   ├── capability.ex                             (MODIFY — 20.3, add preflight_embedding/2)
│   ├── telemetry.ex                              (MODIFY — 20.3, +:embed span name)
│   ├── error/
│   │   ├── embedding_adapter_error.ex            (NEW — 20.2)
│   │   ├── engine_error.ex                       (MODIFY — 20.2, +:no_embed_adapter to BOTH @type reason and the
│   │   │                                                    private @legal_reasons mirror; no legal_reasons/0 accessor
│   │   │                                                    and no length doctest exist on this module — do not add
│   │   │                                                    either. See the Layer A closed-enum note below.)
│   │   └── validation_error.ex                   (MODIFY — 20.1, +:invalid_embedding_request to BOTH @type reason and
│   │                                                        the private @legal_reasons mirror; same — no accessor, no
│   │                                                        length doctest to bump.)
│   └── providers/
│       ├── fake_embeddings.ex                    (NEW — 20.2, top level, mirroring fake_images.ex)
│       ├── openai/embeddings.ex                  (NEW — 20.4)
│       ├── gemini/embeddings.ex                  (NEW — 20.5)
│       └── voyage/embeddings.ex                  (NEW — 20.6, creates providers/voyage/)

conformance/lib/allm/test/
└── embedding_adapter_conformance.ex              (NEW — 20.2, @case_count 10)

conformance/test/
├── allm/test/
│   └── embedding_adapter_conformance_test.exs    (NEW — 20.2, case_count/0 meta-test; mirrors image_adapter_conformance_test.exs)
└── support/fixtures/
    └── scripted_embedding_stub.ex                (NEW — 20.2, real-gate stub driving conformance cases 3 and 4)

test/allm/
├── embedding_test.exs                            (NEW — 20.1)
├── embedding_request_test.exs                    (NEW — 20.1)
├── embedding_response_test.exs                   (NEW — 20.1)
├── embedding_serialization_test.exs              (NEW — 20.1)
├── embedding_property_test.exs                   (NEW — 20.1)
├── validate_embedding_request_test.exs           (NEW — 20.1)
├── embedding_adapter_test.exs                    (NEW — 20.2)
├── engine_embed_adapter_test.exs                 (NEW — 20.2)
├── embedding_batch_test.exs                      (NEW — 20.3)
├── allm_embed_test.exs                           (NEW — 20.3)
├── capability_embedding_test.exs                 (NEW — 20.3)
├── error/
│   └── embedding_adapter_error_test.exs          (NEW — 20.2)
└── providers/
    ├── fake_embeddings_test.exs                  (NEW — 20.2)
    ├── openai/embeddings_test.exs                (NEW — 20.4)
    ├── openai/embeddings_wire_test.exs           (NEW — 20.4)
    ├── openai/embeddings_conformance_test.exs    (NEW — 20.4, mirrors images_conformance_test.exs)
    ├── gemini/embeddings_test.exs                (NEW — 20.5)
    ├── gemini/embeddings_wire_test.exs           (NEW — 20.5)
    ├── gemini/embeddings_conformance_test.exs    (NEW — 20.5)
    ├── voyage/embeddings_test.exs                (NEW — 20.6)
    ├── voyage/embeddings_wire_test.exs           (NEW — 20.6)
    └── voyage/embeddings_conformance_test.exs    (NEW — 20.6)

test/support/
├── fake_embedding_fixtures.ex                    (NEW — 20.2, mirrors fake_image_fixtures.ex)
├── variable_batch_embedding_stub.ex              (NEW — 20.3, process-dict-scoped max_batch_size/0 for chunking tests)
├── openai_fixtures.ex                            (MODIFY — 20.4, embeddings loader + drop_comment/1)
├── gemini_fixtures.ex                            (MODIFY — 20.5, embeddings loader)
└── voyage_fixtures.ex                            (NEW — 20.6, loader mirroring OpenAITestFixtures)

test/fixtures/
├── openai/embeddings/recorded/                   (NEW — 20.4)
│   ├── single_input.json
│   ├── batch_input.json
│   └── reduced_dimensions.json
├── openai/embeddings/synthesized/                (NEW — 20.4)
│   ├── error_401.json
│   ├── error_429.json
│   ├── error_400_too_many_tokens.json
│   └── shuffled_index_order.json
├── gemini/embeddings/recorded/                   (NEW — 20.5)
│   ├── batch_embed_contents.json
│   └── reduced_dimensions.json
├── gemini/embeddings/synthesized/                (NEW — 20.5)
│   ├── error_400.json
│   └── error_429.json
├── voyage/embeddings/recorded/                   (NEW — 20.6)
│   ├── single_input.json
│   └── batch_input.json
└── voyage/embeddings/synthesized/                (NEW — 20.6)
    ├── error_401.json
    └── error_429.json

scripts/
├── record_openai_embeddings_fixtures.exs         (NEW — 20.4)
├── record_gemini_embeddings_fixtures.exs         (NEW — 20.5)
└── record_voyage_embeddings_fixtures.exs         (NEW — 20.6)

examples/
├── _helpers.exs                                  (MODIFY — 20.7, +embedding_engine/1 and per-row embedding fields)
├── README.md                                     (MODIFY — 20.7, per-script table + per-provider key/cost tables)
├── 16_embed_single.exs                           (NEW — 20.7)
├── 17_embed_batch_chunked.exs                    (NEW — 20.7)
└── 18_embed_query_vs_document.exs                (NEW — 20.7)

test/
└── guides_doctest_test.exs                       (MODIFY — 20.7, +doctest_file("guides/embeddings.md"))

guides/
└── embeddings.md                                 (NEW — 20.7, includes the pgvector worked example)

steering/
├── allm_engine_session_streaming_spec_v0_2.md    (MODIFY — 20.7, new §36; amend §32.5/§33/§35.7/§27/§29)
└── PHASE_20_DESIGN.md                            (MODIFY — 20.7, superseded-by banner pointing here)

mix.exs                                           (MODIFY — 20.1, docs groups_for_modules for the three Layer A structs;
                                                             20.2, +EmbeddingAdapter/EmbeddingAdapterError/FakeEmbeddings;
                                                             20.4–20.6, +provider adapters; 20.7, @guides + docs extras)
CHANGELOG.md                                      (MODIFY — 20.7)
```

**`mix.exs` `groups_for_modules` is a per-sub-phase obligation, not a 20.7 one** (corrected during 20.1). `test/groups_for_modules_audit_test.exs` (the Phase 12.3 audit gate) asserts every public `lib/` module appears in exactly one `docs.groups_for_modules` entry, so **every sub-phase that adds a public `lib/` module must add its group entry in the same commit** or `mix test` fails immediately. Only `@guides` / `docs.extras` / `package.files` (which carry `guides/embeddings.md`) remain 20.7's obligation.

**Deliberately NOT touched:** `README.md` (not in this Module Tree — per CLAUDE.md's blocking pre-commit invariant, `git stash README.md` at phase start if it drifts; note `PHASE_20_DESIGN.md:16` listed a README "Embeddings" section, which this design moves to `guides/embeddings.md` for exactly that reason). `examples/run_all.exs` (its glob + `# Provider:` marker pick up new scripts automatically). `examples/RUN_OUTPUT_*.md` (snapshot-defer policy). `lib/allm/session.ex`, `lib/allm/chat.ex`, `lib/allm/stream_runner.ex`, `lib/allm/runner.ex`, `lib/allm/stream_collector.ex`, and every existing chat or image adapter — embeddings share no code path with chat orchestration.

**Path-existence sanity check (verified 2026-07-28).** `lib/allm/providers/openai/`, `lib/allm/providers/gemini/`, `test/fixtures/openai/`, `test/fixtures/gemini/`, `test/allm/providers/openai/`, `test/allm/providers/gemini/`, `conformance/lib/allm/test/`, `scripts/`, `guides/`, and `examples/` all exist. `lib/allm/providers/voyage/`, `test/allm/providers/voyage/`, `test/fixtures/voyage/`, and `test/fixtures/*/embeddings/` are new directories created by their sub-phases. Fixtures are `.json`, loaded via `Jason.decode!/1`, per the Phase 14/15 convention. `fake_embeddings.ex` sits at `providers/` top level, not `providers/fake/embeddings.ex`, matching `providers/fake_images.ex`.

**Completeness check: 77 files.** Counting convention: 68 tagged `(NEW|MODIFY)` rows, minus the 6 rows that are fixture *directories* (containers, not files), plus the 15 individually-listed `.json` fixture leaves = **62 code/doc files + 15 fixtures = 77**. `git diff --stat <pre-20>..<post-20.7> | wc -l` should land at 77 ± 1, the ±1 being `git diff --stat`'s own summary line.

---

## Phases

### Phase 20.1 — Layer A embedding data types

**Goal:** Ship `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse`, the validator, and serializer registration. No engine, no adapter, no network.

**Layer:** A. **Spec sections:** §36.2, §16.

#### 20.1.1 Test Plan (write first)

`test/allm/embedding_test.exs` (NEW):
- `new/1 with vector and index builds the struct`
- `new/1 without :vector raises ArgumentError` — `@enforce_keys` behaviour, **not** `KeyError`
- `new/1 with an unknown key raises KeyError` — `struct!/2` behaviour for unknown keys
- `new/1 defaults :index to 0`
- `magnitude/1 returns the Euclidean norm`
- `normalize/1 produces a unit vector (magnitude within 1.0e-9 of 1.0)`
- `normalize/1 on an all-zero vector returns the input unchanged`
- `normalize/1 on an empty vector returns the input unchanged`
- `normalize/1 is idempotent within 1.0e-9`

`test/allm/embedding_request_test.exs` (NEW):
- `new/1 defaults input to [], truncate to true, task_type to nil`
- `new/1 with each task_type atom round-trips` (5 cases, one per closed-union member)
- `new/1 with an unknown key raises KeyError`

`test/allm/embedding_response_test.exs` (NEW):
- `new/1 defaults usage to %ALLM.Usage{} not nil`
- `vectors/1 returns vectors sorted by :index` — build with indices `[2, 0, 1]`, assert output order matches `[0, 1, 2]`
- `vectors/1 on an empty response returns []`
- `dimensions/1 returns the length of the first vector`
- `dimensions/1 on an empty response returns nil`

`test/allm/validate_embedding_request_test.exs` (NEW) — one case per row of the field-error vocabulary table, plus:
- `embedding_request/1 on a valid request returns :ok`
- `embedding_request/1 accumulates multiple field errors in one ValidationError`
- `embedding_request/1 hard-rejects a non-list :input without evaluating element rules`

`test/allm/embedding_serialization_test.exs` (NEW):
- Each of the three structs round-trips `:erlang.term_to_binary/1` → `binary_to_term/1`
- Each round-trips `Serializer.to_json!/1` → `from_json/1`
- `%Embedding{vector: [0, 1]}` (integer elements) decodes to `[0.0, 1.0]` — Decision #8
- `%EmbeddingRequest{task_type: :search_query}` restores the atom, not the string
- `%EmbeddingRequest{}` decoded from JSON with `"task_type" => "nonsense"` surfaces `{:_unknown, :atom_decode_failed}` per the serializer rescue contract
- `%EmbeddingResponse{}` decoded from JSON with `"usage" => null` hydrates to `%ALLM.Usage{}`, not `nil`

`test/allm/embedding_property_test.exs` (NEW, `StreamData`):
- For any list of floats drawn from a bounded generator (`StreamData.float(min: -1.0e6, max: 1.0e6)` — unbounded floats overflow `magnitude/1` into `ArithmeticError`, verified 2026-07-28), `normalize/1 |> magnitude/1` is within `1.0e-9` of `1.0`, **or `magnitude/1` of the input is `0.0`** (covering the empty, all-zero, and underflowing-component cases)
- For any `%EmbeddingResponse{}` with shuffled indices, `vectors/1` returns them in index order

#### 20.1.2 Implementation Checklist

- [x] `lib/allm/embedding.ex` — `@enforce_keys [:vector]`, struct, `new/1`, `normalize/1`, `magnitude/1`, `__from_tagged__/1` with float coercion, `Jason.Encoder` impl
- [x] `lib/allm/embedding_request.ex` — struct, `new/1`, `__from_tagged__/1` with `to_atom_field/1` for `:task_type`, `Jason.Encoder` impl (plain delegate, no pre-pass)
- [x] `lib/allm/embedding_response.ex` — struct, `new/1`, `vectors/1`, `dimensions/1`, `__from_tagged__/1` with `hydrate_usage/1`, `Jason.Encoder` impl
- [x] `lib/allm/error/validation_error.ex` — add `:invalid_embedding_request` to BOTH `@type reason` and the private `@legal_reasons` mirror. No `legal_reasons/0` accessor and no length doctest exist on this module — do not add either.
- [x] `lib/allm/validate.ex` — `embedding_request/1` implementing the field-error vocabulary with hard-reject on `{:input, :invalid_shape}` (bare-atom path, committed vocabulary — see the Exhaustive table below)
- [x] `lib/allm/serializer.ex` — add `ALLM.Embedding`, `ALLM.EmbeddingRequest`, `ALLM.EmbeddingResponse` to `@known_modules`
- [x] `mix.exs` — the three new public modules added to `docs.groups_for_modules` `"Data types"` (see the Module Tree's 20.1 row; forced by the committed Phase 12.3 audit gate, not deferrable to 20.7)
- [x] `test/layer_a_docs_test.exs` — add the three new structs to the hand-maintained `@layer_a` list. This gate **fails open**: an unregistered module is silently never scanned, so `mix test` passing proves nothing about registration. Missed at first pass; the three moduledocs shipped with banned `spec §…` tokens as a result.
- [x] `@spec` + `@doc` with a runnable doctest on every public function
- [x] `mix run scripts/audit_user_docs.exs <new files>` returns zero hits. **No `@moduledoc`/`@doc` on a `lib/` module may carry a `spec §N` or `§N` marker** — the committed precedent is `lib/allm/image_request.ex:2-3`, which reads "…— Layer A serializable data." with no cite. Spec-section attribution lives in this design doc and the commit message, never in hexdocs-facing prose.

**Implementation Notes (20.1).**

- `[structural, documented]` **`mix.exs` `groups_for_modules` moved from 20.7 to 20.1.** `test/groups_for_modules_audit_test.exs` (Phase 12.3 audit gate) asserts every public `lib/` module appears in exactly one `docs.groups_for_modules` entry. Landing three new public Layer A modules therefore fails `mix test` immediately, which 20.1.3's own success criterion forbids. Only the three group entries were added; `@guides`, `docs.extras`, and `package.files` remain untouched and stay 20.7's obligation.
- `[tactical] EmbeddingRequest.__from_tagged__/1` decodes `:truncate` through a `decode_truncate(nil) -> true` helper rather than the `data["truncate"] || true` idiom used for other defaulted fields — the idiom would silently flip an explicit `false` back to the default. Pinned by a test.
- `[tactical] Embedding.normalize/1` branches on `magnitude == 0.0` via a `when magnitude == 0.0` guard rather than a literal `0.0` pattern. The reason is **compiler-forced, not defensive**: under Erlang/OTP 27+ a literal `0.0` pattern matches only `+0.0` and the compiler emits `pattern matching on 0.0 is equivalent to matching only on +0.0`, which the Definition of Done's zero-warnings bar makes a hard failure. A `-0.0` magnitude is in fact unreachable — `magnitude/1` folds `component * component` into an accumulator seeded at `0.0`, every square is `+0.0` or positive, and `:math.sqrt(0.0) == 0.0` — so do not preserve or propagate this guard on `-0.0` grounds. Design prose reading "when the magnitude is `0.0`" does NOT transcribe to a pattern.
- `[tactical]` `Embedding.__from_tagged__/1`'s `decode_vector/1` passes a non-list `:vector` and non-numeric elements through verbatim rather than repairing them, matching `ImageRequest.decode_size/1`'s fall-through style. Both defensive arms carry tests.
- `[tactical] EmbeddingResponse.dimensions/1` is spec'd `non_neg_integer() | nil`, not the `pos_integer() | nil` this design originally carried. The body is `length(vector)` and `%EmbeddingResponse{}` is public Layer A data a caller can hand-build, so `%Embedding{vector: []}` reaches it and returns `0`. Dialyzer does not flag the narrower spec (the two types overlap, so the contract is merely unguaranteed, not impossible). Widening is preferred over a `[] -> nil` clause, which would overload `nil`'s single current meaning ("no embeddings"). The `@doc` names the adapter-side `:malformed_response` rule as the gate that keeps `0` off the provider path, and a test pins the `0`.
- `[tactical] Embedding.decode_component/1` rescues `ArithmeticError` and passes the value through un-coerced. A JSON integer literal wider than a float decodes to a BEAM bignum, and `bignum * 1.0` raises; `Serializer.hydrate_with/2` rescues only `ValidationError` and `ArgumentError`, so the raise would escape `Serializer.from_json/2`, whose `@spec` promises `{:ok, struct()} | {:error, ValidationError.t()}`. Pass-through (rather than a new `:out_of_range` field error) keeps Decision #8's don't-repair contract and coins no atom outside the committed vocabulary. The float path needs no guard — `Jason` rejects a `1e400` literal outright, so a "huge number" test written with a float literal misses this entirely.
- Reported coverage for `ALLM.EmbeddingResponse` is 92.86%; the single line `cover` marks unhit is the multi-line `defstruct [` header. Every function and branch is exercised. `ALLM.Embedding` and `ALLM.EmbeddingRequest` report 100%.

#### 20.1.3 Verification

```bash
mix test test/allm/embedding_test.exs test/allm/embedding_request_test.exs \
         test/allm/embedding_response_test.exs \
         test/allm/validate_embedding_request_test.exs \
         test/allm/embedding_serialization_test.exs \
         test/allm/embedding_property_test.exs
mix test && mix credo --strict && mix dialyzer && mix format --check-formatted
```

**Success criterion:** all six new files pass; `mix test` reports zero failures; `%ALLM.EmbeddingResponse{embeddings: [%ALLM.Embedding{index: 0, vector: [0.1, 0.2]}]}` survives a `to_json!/1` → `from_json/1` round-trip unchanged.

---

### Phase 20.2 — Layer B behaviour, error type, engine field, Fake

**Goal:** Ship the `ALLM.EmbeddingAdapter` behaviour, its error type, the `Engine` field, a scripted fake, and a conformance suite the fake passes.

**Layer:** B. **Spec sections:** §36.3, §36.4, §36.8.

#### 20.2.1 Test Plan (write first)

`test/allm/error/embedding_adapter_error_test.exs` (NEW):
- `legal_reasons/0 returns 11 atoms`
- `new/2 with each legal reason builds the struct` (11 cases)
- `new/2 with an illegal reason raises ArgumentError` *(pattern verified at `lib/allm/error/image_adapter_error.ex:119-123`)*
- `Exception.message/1 on a hand-built struct with message: nil falls back to the reason-derived default`
- `Exception.message/1 with a :provider set includes the provider in the default`
- round-trips `term_to_binary/1` and `to_json!/1`

`test/allm/engine_embed_adapter_test.exs` (NEW):
- `Engine.new(embed_adapter: SomeModule) sets the field`
- `Engine.new(embed_adapter: "not an atom") raises ArgumentError` *(via `validate_module_fields!/1`, `lib/allm/engine.ex:204-219`)*
- `resolve_params/2 does NOT forward :embed_adapter to the adapter params map` — the `@engine_field_keys` symmetry invariant
- `Engine` JSON round-trip restores `:embed_adapter` as a module atom

`test/allm/providers/fake_embeddings_test.exs` (NEW):
- returns scripted vectors in order across successive calls
- exhausting the script returns `{:error, %EmbeddingAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_embedding}}}` — mirrors `FakeImages`' `:no_scripted_image` precedent (`lib/allm/providers/fake_images.ex:297-299`)
- `max_batch_size/0` returns a positive integer
- honors `adapter_opts[:cursor_key]` so two content-equal engines do not share a cursor
- honors `adapter_opts[:capture_pid]`, sending the request before any gate — the `async: true` seam from `FakeImages` (`lib/allm/providers/fake_images.ex:75-91`)
- a scripted `{:error, %EmbeddingAdapterError{}}` entry is returned verbatim
- `{:retry_until_call, n}` returns a synthetic `:rate_limited` for the first `n-1` calls

`conformance/lib/allm/test/embedding_adapter_conformance.ex` (NEW) — `@case_count 10`, per the invariant→case mapping table in the contract section:
1. `max_batch_size/0` returns a `pos_integer()`
2. `embed/2` with one input returns one embedding with `index: 0`
3. `embed/2` with `length(input) > max_batch_size()` returns `:batch_too_large` **before any HTTP I/O** (a `Req.Test` stub fails the test if called)
4. `embed/2` with `input: []` returns `:invalid_request` before any HTTP I/O
5. `embed/2` returns exactly `length(input)` embeddings
6. `:index` values are exactly `0..length-1`
7. all vectors have identical, non-zero length
8. `request.metadata` round-trips onto `response.metadata` unchanged
9. `opts[:request_id]` is preserved onto `response.request_id`
10. `response.usage` is a `%ALLM.Usage{}`, never `nil`

Plus a meta-test asserting the injected `describe/2` yields exactly `@case_count` cases.

`test/allm/embedding_adapter_test.exs` (NEW):
- `ALLM.Providers.FakeEmbeddings` passes the full conformance suite
- `prepare_request/2` is optional: a module implementing only `embed/2` + `max_batch_size/0` compiles without warning

#### 20.2.2 Implementation Checklist

- [ ] `lib/allm/error/embedding_adapter_error.ex` — 11-atom closed enum, `@legal_reasons`, `legal_reasons/0`, `new/2`, `defexception`, three-clause `message/1`, `__from_tagged__/1`, `Jason.Encoder`
- [ ] `lib/allm/error/engine_error.ex` — add `:no_embed_adapter` to BOTH `@type reason` and the private `@legal_reasons` mirror. No `legal_reasons/0` accessor and no length doctest exist on this module — do not add either.
- [ ] `lib/allm/embedding_adapter.ex` — three `@callback`s, `@optional_callbacks prepare_request: 2`, moduledoc carrying the ten invariants
- [ ] `lib/allm/engine.ex` — `:embed_adapter` at all five sites from the contract table
- [ ] `lib/allm/serializer.ex` — add `ALLM.Error.EmbeddingAdapterError` to `@known_modules`
- [ ] `lib/allm/providers/fake_embeddings.ex` — `@behaviour ALLM.EmbeddingAdapter`, three-tier cursor precedence (`:script_cursor` > `:cursor_key` > `phash2`), `:capture_pid`, `{:retry_until_call, n}`, `max_batch_size/0` → `2048`
- [ ] `test/support/fake_embedding_fixtures.ex` — deterministic scripted vector helpers
- [ ] `conformance/lib/allm/test/embedding_adapter_conformance.ex` — `@case_count 10` + `case_count/0`

#### 20.2.3 Verification

```bash
mix test test/allm/error/embedding_adapter_error_test.exs \
         test/allm/engine_embed_adapter_test.exs \
         test/allm/providers/fake_embeddings_test.exs \
         test/allm/embedding_adapter_test.exs
mix test && mix credo --strict && mix dialyzer
```

**Success criterion:** `FakeEmbeddings` passes all 10 conformance cases; the meta-test confirms exactly 10; `Engine.resolve_params/2` on an engine with `embed_adapter:` set returns a map not containing `:embed_adapter`.

---

### Phase 20.3 — Layer C façade, batching, telemetry, capability pre-flight

**Goal:** `ALLM.embed/3` end-to-end over `FakeEmbeddings`, including transparent chunking.

**Layer:** C. **Spec sections:** §36.5, §36.6, §29.

#### 20.3.1 Test Plan (write first)

`test/allm/embedding_batch_test.exs` (NEW) — driving the `@doc false` seams directly:
- `chunk/2 with 250 inputs and max 100 returns 3 pairs with offsets [0, 100, 200]`
- `chunk/2 with input length exactly max returns one pair with offset 0`
- `chunk/2 with input length max+1 returns two pairs`
- `chunk/2 with [] returns []`
- `merge/1 concatenates embeddings and sorts by :index`
- `merge/1 sums :input_tokens and :total_tokens across chunks`
- `merge/1 with all-nil usage fields leaves them nil` (not `0`)
- `merge/1 with one chunk nil and another 10 yields 10`
- `merge/1 takes :model / :id / :request_id from the first non-nil`
- `merge/1 keeps only the first chunk's :raw and stamps metadata.chunk_count`

`test/allm/allm_embed_test.exs` (NEW) — façade over `FakeEmbeddings`:
- `embed/3 with a bare string returns one embedding`
- `embed/3 with a list of 3 strings returns 3 embeddings in input order`
- `embed/3 with a pre-built %EmbeddingRequest{} dispatches verbatim`
- `embed/3 on an engine with no embed_adapter returns {:error, %EngineError{reason: :no_embed_adapter}}`
- `embed/3 fires :no_embed_adapter even when the request would also fail validation` — gate-ordering assertion
- `embed/3 with input: [""] returns {:error, %ValidationError{reason: :invalid_embedding_request}}` — Decision #12
- **`embed/3 with 250 inputs against ALLM.Test.VariableBatchEmbeddingStub at max_batch_size: 100 makes exactly 3 adapter calls and returns 250 embeddings in input order`** — the core chunking assertion, calls counted via `:capture_pid`
- `embed/3 single-chunk path preserves :raw` (chunk_count == 1)
- `embed/3 multi-chunk path sets metadata.chunk_count == 3`
- `embed/3 mid-batch failure on chunk 2 of 3 returns {:error, _} with metadata.completed_chunks == 1 and no partial vectors` — Alternative D
- `embed/3 stamps the engine-resolved model when request.model is nil`
- `embed/3 preserves an explicitly-set request.model over the engine model`
- `embed/3 fills response.request_id when the adapter left it nil`
- `embed/3 preserves an adapter-populated response.request_id`
- `embed/3 with engine.adapter_opts and call-site adapter_opts: engine wins on key collision`
- `embed/3 with :stream in opts silently drops it`
- `embedding_request/2 normalizes a bare string to a one-element list`

Telemetry (same file, using `test/support/telemetry_capture.ex` for per-process filtering — **not** a bare global `:telemetry.attach/4` in an `async: true` module, per CLAUDE.md):
- `:start` fires with `input_count` in metadata
- `:stop` fires with `duration`, `embedding_count`, `chunk_count` measurements
- `:start` fires even when the adapter is missing, and `:stop` carries `error`
- `embedding_count` is absent from measurements on the error path
- `chunk_count` is 3 for a 250-input / max-100 run

`test/allm/capability_embedding_test.exs` (NEW):
- `preflight_embedding/2 returns :ok when the catalog is absent`
- `preflight_embedding/2 returns :ok when capabilities lack an embeddings_enabled key`
- `preflight_embedding/2 rejects with {[:embeddings_enabled], :embeddings_disabled} for atom-keyed false`
- same for string-keyed `"embeddings_enabled" => false` (JSON-rehydrated `%ModelRef{}` tolerance)

Retry (same file):
- a chunk failing `:rate_limited` with `retry_after_ms` is retried and succeeds on attempt 2
- `:invalid_request` is NOT retried
- `retry: false` on the engine disables retry

#### 20.3.2 Implementation Checklist

- [ ] `lib/allm/embedding_batch.ex` — `run/4`, `chunk/2`, `merge/1`; sequential dispatch; per-chunk `Retry.run/3`; index rebasing in `run/4`; single-chunk fast path
- [ ] `lib/allm.ex` — `embedding_request/2` (normalizing bare string), `embed/3` with three input-shape heads, `do_embed/3` + `do_embed_body/5` (adapter-nil head first), `@retryable_embedding_reasons`, `augment_embedding_retry_policy/1`, `embed_stop_extras/1`, `drop_embedding_request_opts/1`
- [ ] `lib/allm/capability.ex` — `preflight_embedding/2` + `check_embeddings_enabled/2` + `@type embedding_preflight_result`
- [ ] `lib/allm/telemetry.ex` — `:embed` in `@type span_name` and `@valid_span_names`
- [ ] `@spec` + `@doc` with runnable doctests using `FakeEmbeddings` on both public façade functions
- [ ] `test/allm_facade_doctest_inventory_test.exs` — add `ALLM.embed/3` (and `embedding_request/2`) to the hand-maintained `@public_facade` list. That gate **fails open**: an unregistered function is silently never checked, so `mix test` passing is not evidence the registration happened.
- [ ] Re-run `mix docs` and confirm the two forward-reference warnings 20.1 left behind have cleared: `ALLM.embedding_request/2` (from `lib/allm/embedding_request.ex:11`) and `ALLM.Capability.preflight_embedding/2` (from `lib/allm/embedding_request.ex:39` and `lib/allm/validate.ex:317`). Both resolve once this sub-phase lands the functions; if either persists, the docstring cite is wrong.

#### 20.3.3 Verification

```bash
mix test test/allm/embedding_batch_test.exs test/allm/allm_embed_test.exs \
         test/allm/capability_embedding_test.exs
mix test && mix credo --strict lib/allm.ex lib/allm/embedding_batch.ex && mix dialyzer
mix run scripts/audit_user_docs.exs lib/allm.ex lib/allm/embedding_batch.ex lib/allm/capability.ex
```

**Success criterion:** `ALLM.embed(engine, Enum.map(1..250, &"chunk #{&1}"))` against `ALLM.Test.VariableBatchEmbeddingStub` at `max_batch_size: 100` returns 250 embeddings whose `vectors/1` order matches the input order, emits `chunk_count: 3`, and makes exactly 3 adapter calls.

---

### Phase 20.4 — `ALLM.Providers.OpenAI.Embeddings`

**Goal:** Wire OpenAI's `POST /v1/embeddings`.

**Layer:** B. **Spec sections:** §36.6, §36.7.

#### Wire-field map — OpenAI

Verified against [developers.openai.com/api/reference/resources/embeddings/methods/create](https://developers.openai.com/api/reference/resources/embeddings/methods/create) on 2026-07-28.

| Concern | OpenAI |
|---------|--------|
| Endpoint | `POST https://api.openai.com/v1/embeddings` |
| Base URL | `@base_url "https://api.openai.com/v1"` module attribute, matching `lib/allm/providers/openai/images.ex:145`. **Not overridable** — the OpenAI adapters hardcode; only the Gemini adapters honor `adapter_opts[:endpoint]`. |
| Auth | `authorization: Bearer <key>` via `OpenAIHeaders.json_headers/2` (`lib/allm/providers/support/openai_headers.ex:45`) |
| Input field | `input` — string or array of strings |
| Model field | `model` (required) |
| Dimensions | `dimensions` (integer; `text-embedding-3-*` only) |
| Task type | **none** — `:task_type` dropped, `Logger.debug(fn -> ... end)` (Decision #4) |
| Truncate | **none** — over-length input is a 400, not silent truncation. `:truncate` is a no-op either way; documented, not an error. |
| Vector field path | `data[].embedding` |
| Index field path | `data[].index` |
| Usage location | top-level `usage` → `{prompt_tokens, total_tokens}` |
| `Usage` mapping | `input_tokens ← prompt_tokens`; `total_tokens ← total_tokens`; `output_tokens = nil` |
| Batch cap | **2048** array items; 8192 tokens/input; 300,000 tokens summed per request |
| `max_batch_size/0` | `2048` |
| Error envelope | `{"error": {"message", "type", "code"}}` — identical to the chat/images envelope, so the private `classify_embedding_reason/4` copies `classify_image_reason/4` (`lib/allm/providers/openai/images.ex:1089-1107`) minus the two `:content_filter` arms, plus a `:context_length_exceeded` arm. The `@doc false` public seam wrapping it is `to_embedding_adapter_error/4`, mirroring `to_image_adapter_error/4` (`lib/allm/providers/openai/images.ex:1065`) |

**Token-budget caveat:** the 300,000-token-per-request cap can be hit well below 2048 inputs. A 400 carrying `code: "max_tokens_per_request"` maps to `:context_length_exceeded`, and the moduledoc directs callers to lower the batch size via their own chunking loop rather than the library guessing token counts without a tokenizer (Out of Scope).

#### 20.4.1 Test Plan (write first)

`test/allm/providers/openai/embeddings_test.exs` (NEW) — request-shape via `@doc false` seams:
- `to_json_body/2 emits input as an array even for a single input`
- `to_json_body/2 includes :dimensions when set, omits when nil`
- `to_json_body/2 omits :task_type entirely` (Decision #4)
- `to_json_body/2 omits :truncate entirely`
- `max_batch_size/0 returns 2048`
- `embed/2 with 2049 inputs returns :batch_too_large before any HTTP I/O` (Req.Test stub asserts not-called)
- `embed/2 with input: [] returns :invalid_request before any HTTP I/O`
- `to_embedding_adapter_error/4` maps 401→`:authentication_failed`, 403→`:authentication_failed`, 429→`:rate_limited` (+`retry_after_ms` from the header), 400→`:invalid_request`, 400 + `code: "max_tokens_per_request"`→`:context_length_exceeded`, 500/502/503/504→`:provider_unavailable`, 418→`:unknown`
- `decode_response/4 sorts data by :index`
- `decode_response/4 maps usage.prompt_tokens to Usage.input_tokens and leaves output_tokens nil`
- `decode_response/4 on a body missing "data" returns :malformed_response`
- `decode_response/4 on an entry with "embedding": [] returns :malformed_response` (`PHASE_20_DESIGN.md:121`)
- `embed/2 with dimensions: 512 and model "text-embedding-ada-002" returns :unsupported_feature before any HTTP I/O`, with `metadata: %{feature: :dimensions, model: "text-embedding-ada-002"}` — the rule-13 use site for `:unsupported_feature`
- `embed/2 honors opts[:request_timeout] and returns :timeout` — behaviour invariant 3, driven by a `Req.Test` stub that sleeps past the timeout
- passes the full `EmbeddingAdapterConformance` suite (driven via `adapter_opts[:embedding_script]`, in `test/allm/providers/openai/embeddings_conformance_test.exs`)

`test/allm/providers/openai/embeddings_wire_test.exs` (NEW) — seven fixtures:
- `single_input.json` decodes to one embedding of the fixture's dimensionality
- `batch_input.json` decodes to N embeddings in index order
- `reduced_dimensions.json` decodes to vectors of the reduced length
- **`shuffled_index_order.json`** — a `data` array deliberately out of order decodes to index-sorted embeddings (`PHASE_20_DESIGN.md` Decision #3's required test)
- `error_401.json` → `:authentication_failed`; `error_429.json` → `:rate_limited`; `error_400_too_many_tokens.json` → `:context_length_exceeded`
- every synthesized fixture carries the `_comment: "Synthesized (Phase 20.4)…"` marker; tests strip it via `drop_comment/1`

#### 20.4.2 Implementation Checklist

- [ ] `lib/allm/providers/openai/embeddings.ex` — `@behaviour ALLM.EmbeddingAdapter`; `@base_url`; `embed/2`, `max_batch_size/0`, `prepare_request/2`
- [ ] `@doc false` + `@spec` test seams: `to_json_body/2`, `decode_response/4`, `to_embedding_adapter_error/4`
- [ ] **`adapter_opts[:embedding_script]` test-injection short-circuit in `lib/`** — `embed/2` delegates to `ALLM.Providers.FakeEmbeddings.embed/2` BEFORE any gate when the key is present; `prepare_request/2` returns a stub error instead (the deliberate asymmetry at `lib/allm/providers/openai/images.ex:247-255`, `:266-270`). Documented in a `## Test-injection escape hatch` `@moduledoc` section. This is what lets the conformance suite drive a real adapter without `:plug`.
- [ ] Gate order: `:invalid_request` (empty input) → `:batch_too_large` → key resolution → HTTP. Key resolution runs AFTER the gates, per `lib/allm/providers/openai/images.ex:195-197`
- [ ] Key via `Keys.fetch!(:openai, opts)`; headers via `OpenAIHeaders.json_headers/2`; `maybe_apply_req_test_stub/2` + `maybe_apply_request_timeout/2` copied from the images adapter
- [ ] Retry: `classify_http_error/4` returns real reason atoms in the `{:retry, delay, err}` / `{:error, err}` shape (image convention, `lib/allm/providers/openai/images.ex:1043-1053`), NOT the chat adapters' `final_error` token-swap
- [ ] `Logger.debug(fn -> ... end)` deferred form for the dropped `:task_type`
- [ ] `scripts/record_openai_embeddings_fixtures.exs` — idempotent; refuses to overwrite files lacking the `_comment` marker
- [ ] `test/support/openai_fixtures.ex` — embeddings loader + `drop_comment/1`
- [ ] Naming-parity comment block enumerating identical vs divergent helper names across the three embeddings adapters, mirroring `lib/allm/providers/gemini/images.ex:159-197`

#### 20.4.3 Verification

```bash
mix test test/allm/providers/openai/embeddings_test.exs \
         test/allm/providers/openai/embeddings_wire_test.exs
mix test && mix credo --strict && mix dialyzer

# BLOCKING gates (require OPENAI_API_KEY):
mix run scripts/record_openai_embeddings_fixtures.exs
mix run examples/16_embed_single.exs        # after 20.7
```

**Success criterion:** the adapter passes all 10 conformance cases via the `adapter_opts[:embedding_script]` short-circuit; all seven wire fixtures decode to the asserted shapes; the recorder script's second run is a no-op.

---

### Phase 20.5 — `ALLM.Providers.Gemini.Embeddings`

**Goal:** Wire Google's `batchEmbedContents`.

**Layer:** B. **Spec sections:** §36.6, §36.7.

#### Wire-field map — Gemini

Verified against [ai.google.dev/api/embeddings](https://ai.google.dev/api/embeddings) and [ai.google.dev/gemini-api/docs/embeddings](https://ai.google.dev/gemini-api/docs/embeddings) on 2026-07-28.

| Concern | Gemini |
|---------|--------|
| Endpoint | `POST {base}/models/<model>:batchEmbedContents` |
| Base URL | `@base_url "https://generativelanguage.googleapis.com/v1beta"`, **overridable** via `adapter_opts[:endpoint]` — matching `lib/allm/providers/gemini/images.ex:503-511` |
| Auth | `x-goog-api-key: <key>` via `GeminiHeaders.headers/1` (`lib/allm/providers/support/gemini_headers.ex:29`) — header form, not `?key=`, keeping the key out of access logs |
| Body shape | `{"requests": [{"model": "models/<model>", "content": {"parts": [{"text": "..."}]}, "taskType": ..., "outputDimensionality": ...}]}` |
| **Per-item `model`** | **Required on every sub-request**, prefixed `models/`. Omitting it is a 400. The highest-risk wire divergence in the phase. |
| Dimensions | `outputDimensionality` (camelCase) |
| Task type | `taskType` — enum: `TASK_TYPE_UNSPECIFIED`, `RETRIEVAL_QUERY`, `RETRIEVAL_DOCUMENT`, `SEMANTIC_SIMILARITY`, `CLASSIFICATION`, `CLUSTERING`, `QUESTION_ANSWERING`, `FACT_VERIFICATION`, `CODE_RETRIEVAL_QUERY` |
| Truncate | `autoTruncate`, **per sub-request**, nested inside that sub-request's `embedContentConfig` object — NOT a top-level sibling of `requests`. Omitted entirely when `truncate: true` (the provider default); emitted as `false` otherwise. **⚠ Under-verified:** `embedContentConfig` is documented on the single-item `:embedContent` request; Google's published `batchEmbedContents` sub-request schema enumerates only `model` and `content` (re-checked via context7 on 2026-07-29, which returned the same two-field shape). Placement on the batch path is inferred, not confirmed. The 20.5 recorder script MUST issue one live `truncate: false` call and record the accepted body before the `to_batch_body/2` test is written; if the field is rejected there, `:truncate` becomes a documented no-op on Gemini exactly as it is on OpenAI, and the test bullet flips to `omits autoTruncate entirely`. |
| Vector field path | `embeddings[].values` — **`values`, not `embedding`** |
| Index field path | **none** — order is positional; the adapter assigns `index` by list position |
| Usage location | `usageMetadata.promptTokenCount` |
| `Usage` mapping | `input_tokens ← promptTokenCount`; `total_tokens ← promptTokenCount`; `output_tokens = nil` |
| Batch cap | **100** requests per batch |
| `max_batch_size/0` | `100` |
| Normalization | `gemini-embedding-001` returns normalized vectors at 3072 only; truncated dimensionalities are **not** normalized. `gemini-embedding-2` auto-normalizes truncated dimensions. The adapter normalizes unconditionally when `dimensions != nil and dimensions != 3072` — safe on both, and stale-proof (Decision #7). |
| Error envelope | `{"error": {"code", "message", "status"}}` — **reuse `ALLM.Providers.Gemini.classify_error/3`** and translate the reason atom, exactly as `lib/allm/providers/gemini/images.ex:588-608` does. Do NOT duplicate the table. |

**`:task_type` mapping:** `:search_document → "RETRIEVAL_DOCUMENT"`, `:search_query → "RETRIEVAL_QUERY"`, `:classification → "CLASSIFICATION"`, `:clustering → "CLUSTERING"`, `:similarity → "SEMANTIC_SIMILARITY"`, `nil → omit`.

#### 20.5.1 Test Plan (write first)

`test/allm/providers/gemini/embeddings_test.exs` (NEW):
- `to_batch_body/2 emits one sub-request per input`
- `to_batch_body/2 sets "model" on EVERY sub-request, prefixed "models/"` — the highest-risk divergence
- `to_batch_body/2 does not double-prefix a model already carrying "models/"`
- `to_batch_body/2 maps each task_type atom to its Gemini enum string` (5 cases)
- `to_batch_body/2 omits taskType when nil`
- `to_batch_body/2 emits outputDimensionality (camelCase) when :dimensions is set`
- `to_batch_body/2 omits autoTruncate when truncate: true` and `emits embedContentConfig.autoTruncate == false per sub-request when truncate: false`
- `to_batch_body/2 with request.model == nil returns :invalid_request before any HTTP I/O` — the nil-model policy below
- `embed/2 honors opts[:request_timeout] and returns :timeout` — behaviour invariant 3
- `max_batch_size/0 returns 100`
- `embed/2 with 101 inputs returns :batch_too_large before any HTTP I/O`
- `decode_response/4 reads embeddings[].values, not [].embedding`
- `decode_response/4 assigns :index by list position`
- `decode_response/4 maps usageMetadata.promptTokenCount to both input_tokens and total_tokens`
- **normalization (Decision #7):**
  - `decode_response/4 with :dimensions nil leaves vectors untouched` (assert equality with the fixture values)
  - `decode_response/4 with :dimensions 3072 leaves vectors untouched`
  - `decode_response/4 with :dimensions 768 returns unit-magnitude vectors (within 1.0e-9)`
- `to_embedding_adapter_error/4 delegates to Gemini.classify_error/3` — 400→`:invalid_request`, 401/403→`:authentication_failed`, 404→`:invalid_request`, 429→`:rate_limited`, 500/503→`:provider_unavailable`
- `endpoint_url/2 honors adapter_opts[:endpoint]`
- passes the full `EmbeddingAdapterConformance` suite (driven via `adapter_opts[:embedding_script]`, in `test/allm/providers/gemini/embeddings_conformance_test.exs`)

`test/allm/providers/gemini/embeddings_wire_test.exs` (NEW) — four fixtures, same structure as 20.4.

#### 20.5.2 Implementation Checklist

- [ ] `lib/allm/providers/gemini/embeddings.ex` — `@behaviour ALLM.EmbeddingAdapter`; `@base_url`; `embed/2`, `max_batch_size/0` → `100`, `prepare_request/2`
- [ ] `@doc false` + `@spec` seams: `to_batch_body/2`, `to_gemini_task_type/1`, `decode_response/4`, `to_embedding_adapter_error/4`, `maybe_normalize/2`, `endpoint_url/2`
- [ ] **`adapter_opts[:embedding_script]` short-circuit in `lib/`**, mirroring 20.4 (`lib/allm/providers/gemini/images.ex:135-137` is the Gemini-side precedent)
- [ ] Per-sub-request `model` stamping with `models/` prefix idempotency
- [ ] **Nil-model policy.** Both the URL (`{base}/models/<model>:batchEmbedContents`) and every sub-request's required `model` field derive from `request.model`, which is `nil` until the façade stamps it (dispatch step 6). A direct Layer-B call with `model: nil` therefore CANNOT build a legal request. Return `{:error, %EmbeddingAdapterError{reason: :invalid_request, metadata: %{field: :model}}}` before any HTTP I/O rather than substituting a hardcoded default — deliberately diverging from `lib/allm/providers/gemini/images.ex:510`'s `model || "gemini-3.1-flash-image-preview"` fallback, because a silently-wrong embedding model produces vectors in the wrong space, which is unrecoverable once written to pgvector, whereas a wrong image model is merely a wrong picture. Invariant 10 holds: `embed/2` and `prepare_request/2` reject nil identically.
- [ ] `maybe_normalize/2` — normalize iff `dimensions != nil and dimensions != 3072`; delegate to `ALLM.Embedding.normalize/1`
- [ ] `to_embedding_adapter_error/4` delegates to `ALLM.Providers.Gemini.classify_error/3` and translates the reason
- [ ] Key via `Keys.fetch!(:gemini, opts)` (Decision #11); headers via `GeminiHeaders.headers/1`
- [ ] `scripts/record_gemini_embeddings_fixtures.exs` — **includes the `truncate: false` live probe resolving the `autoTruncate` placement question flagged in the wire-field map, before `to_batch_body/2` is finalized**
- [ ] `test/support/gemini_fixtures.ex` — embeddings loader

#### 20.5.3 Verification

```bash
mix test test/allm/providers/gemini/embeddings_test.exs \
         test/allm/providers/gemini/embeddings_wire_test.exs
mix test && mix credo --strict && mix dialyzer

# BLOCKING gates (require GEMINI_API_KEY):
mix run scripts/record_gemini_embeddings_fixtures.exs
ALLM_PROVIDER=gemini mix run examples/16_embed_single.exs   # after 20.7
```

**Success criterion:** conformance passes; a `dimensions: 768` request yields vectors whose magnitude is within `1.0e-9` of `1.0`; a `dimensions: nil` request yields vectors equal to the fixture values.

---

### Phase 20.6 — `ALLM.Providers.Voyage.Embeddings` (Anthropic track)

**Goal:** Wire Voyage AI's `POST /v1/embeddings` — Anthropic's officially recommended embeddings path.

**Layer:** B. **Spec sections:** §36.6, §36.7.

#### Wire-field map — Voyage

Verified against [docs.voyageai.com/reference/embeddings-api](https://docs.voyageai.com/reference/embeddings-api) on 2026-07-28.

| Concern | Voyage |
|---------|--------|
| Endpoint | `POST https://api.voyageai.com/v1/embeddings` |
| Base URL | `@base_url "https://api.voyageai.com/v1"`, not overridable (OpenAI convention) |
| Auth | `Authorization: Bearer <key>` — OpenAI-shaped |
| Input field | `input` — string or array (max **1000** items) |
| Model field | `model` (required) |
| Dimensions | `output_dimension` (snake_case) — `256 \| 512 \| 1024 \| 2048` on supporting models |
| Task type | `input_type` — `null \| "query" \| "document"` **only** |
| Truncate | `truncation` (boolean, default `true`) |
| Vector field path | `data[].embedding` |
| Index field path | `data[].index` |
| Usage location | `usage.total_tokens` — **`total_tokens` only, no `prompt_tokens`** |
| `Usage` mapping | `total_tokens ← total_tokens`; `input_tokens = nil`; `output_tokens = nil` |
| Batch cap | **1000** items |
| `max_batch_size/0` | `1000` |
| Key atom / env var | `:voyage` → `VOYAGE_API_KEY` via `ALLM.Keys`' unknown-provider fallback (`lib/allm/keys.ex:203`) |

**`:task_type` mapping — lossy, and documented as such:** `:search_document → "document"`, `:search_query → "query"`. `:classification`, `:clustering`, and `:similarity` have no Voyage equivalent and map to an **omitted** `input_type` (Voyage's documented `null` behaviour: no retrieval prompt is prepended, the correct semantic for symmetric tasks). Logged at `:debug` via the deferred form.

#### 20.6.1 Test Plan (write first)

`test/allm/providers/voyage/embeddings_test.exs` (NEW):
- `to_json_body/2 emits input as an array`
- `to_json_body/2 maps :search_query to input_type "query"` and `:search_document` to `"document"`
- `to_json_body/2 omits input_type for :classification / :clustering / :similarity` (3 cases)
- `to_json_body/2 emits output_dimension (snake_case) when :dimensions is set`
- `to_json_body/2 omits truncation when true, emits false when false`
- `max_batch_size/0 returns 1000`
- `embed/2 with 1001 inputs returns :batch_too_large before any HTTP I/O`
- `decode_response/4 maps usage.total_tokens to Usage.total_tokens and leaves input_tokens nil` — the Voyage-specific asymmetry
- `decode_response/4 sorts data by :index`
- error mapping: 401→`:authentication_failed`, 429→`:rate_limited`, 400→`:invalid_request`, 5xx→`:provider_unavailable`
- `embed/2 honors opts[:request_timeout] and returns :timeout` — behaviour invariant 3
- passes the full `EmbeddingAdapterConformance` suite (driven via `adapter_opts[:embedding_script]`, in `test/allm/providers/voyage/embeddings_conformance_test.exs`)

`test/allm/providers/voyage/embeddings_wire_test.exs` (NEW) — four fixtures.

#### 20.6.2 Implementation Checklist

- [ ] `lib/allm/providers/voyage/embeddings.ex` — `@behaviour ALLM.EmbeddingAdapter`; `@base_url`; `embed/2`, `max_batch_size/0` → `1000`, `prepare_request/2`
- [ ] Moduledoc opens by stating plainly that Anthropic ships no embeddings endpoint and that this adapter is Anthropic's recommended path — with the cookbook link (Decision #1)
- [ ] `@doc false` + `@spec` seams: `to_json_body/2`, `to_voyage_input_type/1`, `decode_response/4`, `to_embedding_adapter_error/4`
- [ ] **`adapter_opts[:embedding_script]` short-circuit in `lib/`**, mirroring 20.4
- [ ] Inline `Bearer` headers — **no** shared `VoyageHeaders` support module. One caller; a support module at n=1 is the abstraction CLAUDE.md's Rule of 3 warns against. `OpenAIHeaders` exists because two adapters share it.
- [ ] Key via `Keys.fetch!(:voyage, opts)`
- [ ] `scripts/record_voyage_embeddings_fixtures.exs`
- [ ] `test/support/voyage_fixtures.ex` — loader mirroring `OpenAITestFixtures`

#### 20.6.3 Verification

```bash
mix test test/allm/providers/voyage/embeddings_test.exs \
         test/allm/providers/voyage/embeddings_wire_test.exs
mix test && mix credo --strict && mix dialyzer

# BLOCKING gates (require VOYAGE_API_KEY):
mix run scripts/record_voyage_embeddings_fixtures.exs
ALLM_PROVIDER=anthropic mix run examples/16_embed_single.exs   # after 20.7
```

**Success criterion:** conformance passes; a response decoded from `single_input.json` has `usage.total_tokens` set and `usage.input_tokens == nil`.

---

### Phase 20.7 — Spec §36, guide, examples, docs wiring

**Goal:** Make the capability discoverable and prove it live on all three providers.

**Layer:** documentation + examples. No `lib/` changes.

#### 20.7.1 Test Plan (write first)

- `guides/embeddings.md` is registered in `test/guides_doctest_test.exs` via `doctest_file("guides/embeddings.md")`. **Without that line, zero doctests run from the guide.** `doctest_file/1` executes `iex>` blocks only — fence type is irrelevant (` ```elixir ` blocks are ignored regardless), per `test/guides_doctest_test.exs:5-9`. So `FakeEmbeddings` examples use `iex>` prompts; the pgvector example, which references a caller-owned `Repo`, does not.
- `test/guides_test.exs` additionally requires every guide to exceed 2 KB and contain at least one `iex>` block.
- **Banned-token audit.** `scripts/audit_user_docs.exs:17-29` rejects `Phase N`, `§N`, `spec §N`, `Decision #N`, `Non-obvious Decision`, `steering/`, `PHASE_*.md`, `retro F<n>`, `RELEASE_PLAN`, and `PROJECT_PHASING` in shipped docs. `guides/embeddings.md` must contain none of them — the `Docs target:` annotations throughout this design point at spec sections and Decision numbers for the *implementer*, and must be paraphrased into user-facing language in the guide itself.
- `mix.exs` `package[:files]` is a superset of `docs[:extras]` — verified with `tar -tzf`, not just `mix hex.build` exit code (CLAUDE.md worked example: the v0.3.0 CHANGELOG omission)
- `test/readme_getting_started_test.exs` (note: no `allm/` segment) remains green and untouched

#### 20.7.2 Implementation Checklist

- [ ] Spec §36 (new), mirroring §35's ten-subsection structure: `36.1` design goals, `36.2` data model, `36.3` `ALLM.EmbeddingAdapter`, `36.4` engine integration, `36.5` public API, `36.6` batching + normalization, `36.7` provider adapters in v0.5, `36.8` testing, `36.9` telemetry, `36.10` out of scope
- [ ] Spec §32.5 + §33: strike "embeddings" from the out-of-scope lists, pointing to §36. §33's line currently reads `embeddings, audio input/output, image generation (see §32.5)` (`steering/allm_engine_session_streaming_spec_v0_2.md:1887`) — image generation shipped in v0.3 and was never struck, so this edit corrects both and leaves audio
- [ ] Spec §35.7: scoped bundled-adapter amendment (Decision #2)
- [ ] Spec §27 module tree + §29 telemetry event names. **Note when amending §29** that the spec writes the namespace `[:llm, …]` while the code and §35.9 use `[:allm, …]` — a pre-existing spec bug; §36.9 uses `[:allm, …]` and does not propagate the error
- [ ] Every amendment block opens with `> **Phase 20 amendment (commits <first-sha>..<last-sha>).**` per AGENT_DESIGN_SPEC.md rule 21
- [ ] `steering/PHASE_20_DESIGN.md` — add a superseded-by banner pointing at this document
- [ ] `guides/embeddings.md` — provider table, task-type guidance, batching + resumable-chunking loop, normalization, and the pgvector worked example (`CREATE EXTENSION vector`, `vector(N)` sizing via `EmbeddingResponse.dimensions/1`, cosine-distance query)
- [ ] `examples/_helpers.exs` — `embedding_engine/1` mirroring `image_engine/1` (raises `ArgumentError` when the row has no embedding adapter); per-row `:embed_adapter` / `:embedding_default_model` / `:embedding_key_env`. Anthropic's row points at `ALLM.Providers.Voyage.Embeddings` with `embedding_key_env: "VOYAGE_API_KEY"`, and the moduledoc states plainly why
- [ ] `examples/16_embed_single.exs`, `17_embed_batch_chunked.exs` (250 inputs — forces ≥3 chunks on Gemini), `18_embed_query_vs_document.exs`; each with the standard header block and no `# Provider:` marker (all three arms are supported)
- [ ] `test/guides_doctest_test.exs` — add `doctest_file("guides/embeddings.md")`. Without it the guide's `iex>` blocks never execute
- [ ] `examples/README.md` — add rows 16–18 to the per-script table and update the per-provider key-requirements table to note that the **Anthropic arm now needs `VOYAGE_API_KEY`** (divergence D12)
- [ ] `mix run scripts/audit_user_docs.exs` clean for `guides/embeddings.md` — no `Phase N`, `§N`, `Decision #N`, `steering/`, or `PHASE_*.md` tokens
- [ ] `mix.exs` — `guides/embeddings.md` in `@guides`; `ALLM.EmbeddingAdapter` under `Behaviours`; the four new provider modules under `Providers`; `ALLM.Embedding` / `EmbeddingRequest` / `EmbeddingResponse` under `Data types`; `ALLM.Error.EmbeddingAdapterError` under `Errors`
- [ ] `CHANGELOG.md` — one line per public-API change; flag any live-gate deferral honestly rather than paraphrasing the future post-record state
- [ ] **Do NOT** regenerate `examples/RUN_OUTPUT_*.md` unless the live run happens in this commit (snapshot-defer policy)

#### 20.7.3 Verification

```bash
mix test && mix format --check-formatted && mix credo --strict && mix dialyzer
mix docs                              # renders guides/embeddings.md without warnings
mix hex.build && tar -tzf allm-*.tar  # confirm guides/embeddings.md is in the source tarball

# BLOCKING live gate — ~$0.01 total
ALLM_PROVIDER=openai    mix run examples/run_all.exs
ALLM_PROVIDER=gemini    mix run examples/run_all.exs
ALLM_PROVIDER=anthropic mix run examples/run_all.exs
```

**Live-gate deferral note.** Per CLAUDE.md's "blocked-by-pre-existing-failure" rule: OpenAI's `run_all.exs` currently halts at script 13 (`dall-e-2` 404, originating commit `a7b934b`, inherited through PHASE_18.5). That failure is **not in this phase's scope**. The gate is satisfied for OpenAI by running scripts 16–18 individually with verifiable success, leaving script 13 in place, and NOT regenerating `RUN_OUTPUT_OPENAI.md`. The commit message and retrospective must flag the deferral with its originating phase + commit.

**Success criterion:** `mix docs` renders the guide; `tar -tzf` lists `guides/embeddings.md`; scripts 16–18 exit 0 on all three provider arms.

---

## Test Plan (cross-phase)

### Coverage strategy by category

| Category | Where | Floor |
|----------|-------|-------|
| **Unit** | one file per module, 1:1 mirror | every public function has ≥1 happy-path and ≥1 error-path test; the `task_type` and `reason` unions get one test per variant (5 and 11) |
| **Behaviour conformance** | `conformance/lib/allm/test/embedding_adapter_conformance.ex`, `@case_count 10` | `FakeEmbeddings` is the reference; all three real adapters reuse the identical suite via the `adapter_opts[:embedding_script]` short-circuit (NOT `Req.Test` — `:plug` is not a `conformance/` dep). Third-party adapters (Cohere, Jina) add `:allm_conformance` as a test-only dep and `use` it. |
| **Integration** | `test/allm/allm_embed_test.exs` | façade → batch → `FakeEmbeddings`, never HTTP mocks (CLAUDE.md non-negotiable) |
| **Property** (`StreamData`) | `test/allm/embedding_property_test.exs`, `embedding_batch_test.exs` | normalization magnitude invariant; `vectors/1` ordering under shuffled indices; batch-equivalence (below) |
| **Doctests** | every public function in `Embedding`, `EmbeddingRequest`, `EmbeddingResponse`, `ALLM.embed/3`, `embedding_request/2`, and the behaviour callbacks | runnable against `FakeEmbeddings` — no real provider |
| **Serializability** | `test/allm/embedding_serialization_test.exs` | all three Layer A structs + the error struct round-trip both `term_to_binary/1` and `to_json!/1`; **blocking** |
| **Wire fixtures** | `test/allm/providers/*/embeddings_wire_test.exs` | 3 recorded + 4 synthesized (OpenAI), 2 + 2 (Gemini), 2 + 2 (Voyage) |
| **Live validation** | `examples/16–18` × 3 providers | BLOCKING per CLAUDE.md's bundled-adapter rule |

### Stream-equivalence: not applicable

There is no streaming counterpart to `ALLM.embed/3` (Assumption 3), so no `f(args) ≡ stream_f(args) |> collect` property exists and the **relaxation budget is empty**. Stated explicitly so the absence reads as intent rather than oversight.

### Batch-equivalence property (the analogue that does apply)

Asserted as a `StreamData` property in `test/allm/embedding_batch_test.exs`:

> For any input list of length 1..500 and any `max_batch_size` in 1..500 (varied via `ALLM.Test.VariableBatchEmbeddingStub.put_max_batch_size/1`), `ALLM.embed/3` returns embeddings identical (same order, same vectors) to a single unchunked call against the same scripted fake.

**Relaxation set:**

| Relaxation | Justification | Risk |
|------------|---------------|------|
| `:raw` compared only when `chunk_count == 1` | Multi-chunk `:raw` keeps the first chunk only, by design (Decision #5 merge table) | tolerable — contract-defined, not a divergence |
| `metadata.chunk_count` excluded from equality | It is the field that necessarily differs | tolerable |

Neither row is a masking-divergence: both are contract-defined differences with a named code path (`EmbeddingBatch.merge/1`'s `:raw` and `:metadata` rules), not an assertion loosened to hide a bug.

### Test-vehicle attribution (rule: test-bullet-vs-test-vehicle)

| Test bullet class | Vehicle | Error-producing path |
|-------------------|---------|----------------------|
| Façade orchestration, chunking, telemetry, retry | `ALLM.Providers.FakeEmbeddings` | scripted `{:error, %EmbeddingAdapterError{}}` entries and `{:retry_until_call, n}` |
| Adapter request-shape and response-decode | `@doc false` seams called directly (no HTTP) | n/a |
| Adapter HTTP status → reason mapping | `Req.Test` stub + synthesized fixtures | `to_embedding_adapter_error/4` |
| `:batch_too_large`, `:invalid_request` pre-flight | Real adapter + `Req.Test` stub asserting not-called | each adapter's gate chain |
| `:missing_key` raise | Real adapter with `ALLM.Keys.Store.clear()` | `ALLM.Keys.fetch!/2` (`lib/allm/keys.ex:163-171`) |
| Per-model rejections, real token accounting, real dimensionality | **live-only** — routed to the examples gate | provider |

### Coverage threshold

`mix.exs:19` sets `test_coverage: [summary: [threshold: 80]]`. This design does not lower it. New code lands at **≥90%**.

### Live-API cost estimation

Per-clean-run, using each provider's cheapest current embedding model:

| Provider | Model | Tokens/run (scripts 16–18) | Price / 1M | Cost / clean run |
|----------|-------|---------------------------|------------|------------------|
| OpenAI | `text-embedding-3-small` | ~3,500 | $0.02 | < $0.001 |
| Gemini | `gemini-embedding-001` | ~3,500 | $0.15 | < $0.001 |
| Voyage | `voyage-3.5-lite` | ~3,500 | $0.02 (free tier covers it) | ~$0.000 |

**Per-clean-run total: < $0.01.** **First-implementation cost (3× for debugging passes): < $0.03.** Fixture recording adds three single-call runs (~$0.001 total, consistent with `PHASE_20_DESIGN.md` Decision #8). The implementer report must cite actuals against this estimate.

Script 17 embeds 250 short inputs specifically to force ≥3 chunks on Gemini's 100-item cap — the only script whose token count is non-trivial, and still ~2,500 tokens.

---

## Error Contract

### Per-function error table

| Function | Error | Reason | Recovery guidance |
|----------|-------|--------|-------------------|
| `ALLM.embed/3` | `EngineError` | `:no_embed_adapter` | Engine has no `:embed_adapter`; recoverable by passing one. Fires before every other gate. |
| `ALLM.embed/3` | `ValidationError` | `:invalid_embedding_request` | Request failed `Validate.embedding_request/1`; see the field-error vocabulary. No retry. |
| `ALLM.embed/3` | `ValidationError` | `:unsupported_capability` | Model catalog says embeddings are disabled for this model; pick another model. |
| `ALLM.embed/3` | `EngineError` | `:missing_key` (**raised**, not returned) | Raised by `ALLM.Keys.fetch!/2` per its documented contract (`lib/allm/keys.ex:126-131`). Not rescued by adapters. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:authentication_failed` | 401/403. Surface to user; no retry. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:rate_limited` | 429. Retried automatically; `:retry_after_ms` populated from `Retry-After`. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:invalid_request` | 400, or an empty input reaching a direct adapter call. Fix the request; no retry. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:context_length_exceeded` | A single input exceeds the model's token limit, or the batch exceeds a per-request token cap. Chunk smaller or shorten inputs; no retry. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:provider_unavailable` | 5xx. Retried automatically. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:timeout` | `opts[:request_timeout]` exceeded. Retried automatically. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:network_error` | TCP/TLS/DNS. Retried automatically. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:malformed_response` | 200 with an unparseable body, or an entry whose vector is `[]`. No retry; file a bug. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:unsupported_feature` | Request combined features the adapter cannot express. No retry. |
| `ALLM.embed/3` | `EmbeddingAdapterError` | `:unknown` | Unclassifiable shape. No retry. |
| `EmbeddingAdapter.embed/2` (direct) | `EmbeddingAdapterError` | `:batch_too_large` | `length(input) > max_batch_size()`. Unreachable via `ALLM.embed/3` (the façade chunks); recoverable by chunking. `metadata: %{count:, max:}`. |

**Mid-batch failure metadata.** When chunk *k* of *n* fails, the returned `EmbeddingAdapterError` is that chunk's own error with two keys merged into `:metadata`: `completed_chunks: k-1` and `completed_inputs: (k-1) * max_batch_size`. No partial vectors are returned (Alternative D).

### Field-error atom vocabulary — `ALLM.Validate.embedding_request/1`

Exhaustive. The implementer should never have to invent an atom.

**Field-path and atom conventions are inherited from committed `ALLM.Validate`, not invented.** Top-level fields use a **bare atom** path (`{:input, :empty}`), and only nested/indexed paths use a list (`{[:input, 2], :not_a_string}`) — verified against `lib/allm/validate.ex:289` (`{:messages, :empty}`), `:328` (`{:max_tokens, :must_be_positive}`), `:531` (`{:n, :must_be_positive}`) versus `:190` (`{[:messages, 0, :role], :unknown}`). The list-form-for-top-level shape belongs to `ALLM.Capability`, not `ALLM.Validate`. Reason atoms reuse the committed vocabulary — `:empty` (`validate.ex:289`, `:374`), `:must_be_positive` (`validate.ex:328`, `:531`), and bare `:unknown` for closed enums (`validate.ex:349`, `:402`, `:528`, `:534`) — rather than coining `:empty_string` / `:not_positive` / `:unknown_task_type`.

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `:input` | `:invalid_shape` | **yes** | `:input` is not a list — shape precondition; element rules would be meaningless |
| `:input` | `:empty` | no | `:input == []` |
| `[:input, idx]` | `:not_a_string` | no | element at `idx` is not a binary |
| `[:input, idx]` | `:empty` | no | element at `idx` is `""` — OpenAI rejects empty strings with a 400 |
| `:dimensions` | `:must_be_positive` | no | `:dimensions` is set and is an integer `<= 0` |
| `:dimensions` | `:invalid_shape` | no | `:dimensions` is set and not an integer |
| `:task_type` | `:unknown` | no | `:task_type` is not `nil` and not in the closed 5-atom enum |
| `:truncate` | `:invalid_shape` | no | `:truncate` is not a boolean |
| `:model` | `:invalid_shape` | no | `:model` is set and not a binary |

**Hard-reject semantics.** Only `{:input, :invalid_shape}` short-circuits — a non-list `:input` returns immediately as the sole error. Note the short-circuit is a separate `embedding_request/1` function head, so it suppresses **every** subsequent rule, not merely the `[:input, idx]` element rules that motivate it: a request with a bare-string `:input` *plus* an invalid `:dimensions`, `:task_type`, `:truncate`, and `:model` reports only `[input: :invalid_shape]`. That is deliberate — the shape precondition is reported first and alone, and the caller re-validates after fixing it. Everything else accumulates into one `%ValidationError{reason: :invalid_embedding_request, errors: [...]}`, matching the module-wide fold-and-accumulate default. Per-model dimension caps (e.g. `text-embedding-3-small` ≤ 1536) are **not** validated here — that is `Capability.preflight_embedding/2`'s `check_dimensions_max/3` gate, which has the model metadata the validator lacks.

---

## Streaming & Backpressure

**Not applicable — and that is a design decision, not an omission.**

Embeddings are request/response (Assumption 3, spec §35.1 item 2 precedent). Consequences, stated explicitly so a future reader does not go looking:

- **No `Stream.resource/3`, so no `after_fun` cleanup invariant.** `Req.request/1` owns its connection lifecycle. The `ALLM.EmbeddingAdapter` contract says so in as many words.
- **No Finch usage.** The `:http1` pin in `lib/allm/application.ex:8-18` exists for SSE streaming and is irrelevant here.
- **No consumer-side cancellation.** `ALLM.embed/3` is a blocking call. The nearest control is `opts[:request_timeout]`, honored per-chunk (invariant 3).
- **Backpressure is the chunk loop.** Sequential chunk dispatch (Decision #6) is itself the flow-control mechanism: at most one in-flight HTTP request per `ALLM.embed/3` call, so a 5,000-input ingest cannot open 50 concurrent sockets.

The one bounded-time property worth asserting is that a 250-input / max-100 run makes exactly 3 adapter calls and no more — covered in 20.3's Test Plan.

---

## Definition of Done

- [ ] All 7 sub-phases marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings vs. the prior PLT
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest — except `ALLM.EmbeddingBatch`, which is `@moduledoc false` internal machinery whose three functions carry `@spec` + `@doc false` (the `chat.ex` / `stream_runner.ex` precedent for Layer C internals)
- [ ] Every new Layer A struct has a serializability round-trip test (both ETF and JSON)
- [ ] `ALLM.Providers.FakeEmbeddings` passes all 10 `EmbeddingAdapterConformance` cases; the `@case_count` meta-test confirms exactly 10
- [ ] All three real adapters pass the same 10 cases via the `adapter_opts[:embedding_script]` short-circuit, each in its own `*_conformance_test.exs`
- [ ] Batch-equivalence property passes at ≥100 `StreamData` iterations with only the two contract-defined relaxations
- [ ] `:no_embed_adapter` and `:invalid_embedding_request` each added to BOTH `@type reason` and `@legal_reasons`; `EmbeddingAdapterError.legal_reasons/0` doctest asserts 11
- [ ] Wire fixtures recorded live for the `recorded/` directories; each `synthesized/` file carries its `_comment: "Synthesized (Phase 20.N)…"` marker
- [ ] All three recorder scripts run idempotently (second run is a no-op)
- [ ] `examples/16–18` exit 0 on all three provider arms — **with any deferral flagged per the live-gate note in 20.7.3**
- [ ] Spec §36 written; §32.5, §33, §35.7, §27, §29 amended, each block stamped with the Phase 20 commit range
- [ ] `steering/PHASE_20_DESIGN.md` carries a superseded-by banner
- [ ] `guides/embeddings.md` renders under `mix docs` and appears in the `tar -tzf` source tarball
- [ ] `mix.exs` `package[:files]` remains a superset of `docs[:extras]`
- [ ] `CHANGELOG.md` updated with one line per public-API change
- [ ] `README.md` unmodified (not in this Module Tree)
- [ ] Spec §-numbers in commit messages match the Overview
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md`

---

## Resolved Questions

Four decisions were escalated during design review and are now settled. They are recorded here because each has a live counter-proposal a future reader will re-raise; the resolution and its cost are on the record so the argument is not re-litigated from scratch.

1. **Deliver the "Anthropic" arm as `ALLM.Providers.Voyage.Embeddings`.** *(Resolved 2026-07-29 — Alternative A1.)* Anthropic has no embeddings endpoint; `PHASE_20_DESIGN.md:74` independently reached that finding and chose to ship nothing for the Anthropic arm. Voyage ships in-tree instead. **Accepted cost:** a scoped amendment to the §35.7 bundled-adapter rule (Decision #2), and `VOYAGE_API_KEY` becomes a hard requirement for the Anthropic `run_all.exs` arm (divergence D12). **Counter-proposal on the record:** A2 — OpenAI + Gemini only, Anthropic users route elsewhere.
2. **Reuse `ALLM.Usage`; ship no `EmbeddingUsage`.** *(Resolved 2026-07-29 — reverses `PHASE_20_DESIGN.md` Decision #4.)* Divergence D2 documents the three defects in the original: a field-name vocabulary split against `lib/allm/usage.ex:29-33`, a `Decimal` dependency absent from `mix.exs`, and a rationale contradicted by `ALLM.Usage`'s own moduledoc. **Accepted cost:** the widest-blast-radius change in this design — one fewer Layer A type than PHASE_20 planned, four serializer registry entries instead of five, and a usage-mapping row in every adapter's wire-field table. **Counter-proposal on the record:** keep `EmbeddingUsage` but correct it to `input_tokens`/`total_tokens` + `float` costs.
3. **Retry and time budgets stay per-chunk, documented rather than bounded.** *(Resolved 2026-07-29 — Alternative E.)* A 50-chunk ingest can issue 150 HTTP requests and block for tens of minutes with no caller-side ceiling, and the telemetry span reports one duration for all of it. No `:max_total_attempts` or `:deadline` opt is added in v0.5. **Accepted cost:** the ceiling is documentary — `@doc ALLM.embed/3` must carry the budget table, and callers wanting a real bound chunk themselves against `max_batch_size/0`. **Counter-proposal on the record:** add the opts once throughput data exists.
4. **The Gemini adapter L2-normalizes truncated-dimension vectors.** *(Resolved during review — Decision #7.)* A mixed-normalization pgvector table is unrecoverable after the fact. **Accepted cost:** a `dimensions: 768` response differs from a raw `curl`, which the adapter moduledoc and the guide both call out.
