# `ALLM.Batch` — Cross-Provider Bulk Batch Surface — Design Document

> **Goal:** Add a provider-neutral bulk-batch primitive (`ALLM.batch/3`, `ALLM.fetch_batch/3`, `ALLM.cancel_batch/3`, `ALLM.await_batch/3`) that lets callers submit MANY chat or embedding requests in a single bundle and receive results when the provider has finished processing. Targets the documented 50% cost discounts on OpenAI's `/v1/batches` and Anthropic's `/v1/messages/batches`.
> **Outcome:** A caller wraps existing `%ALLM.Request{}` (chat) or `%ALLM.EmbeddingRequest{}` structs into a `%ALLM.BatchRequest{}`, calls `ALLM.batch(engine, batch_request)`, gets back a serializable `%ALLM.BatchJob{id, status, ...}` with provider-issued id, persists the id, and later calls `ALLM.fetch_batch(engine, id)` (synchronous polling helper: `ALLM.await_batch(engine, id)`) to retrieve `%ALLM.BatchResult{}` rows. Existing v0.4 sync chat / embeddings / image / audio surfaces are unchanged. Engines without a `batch_adapter:` set return `{:error, %ALLM.Error.EngineError{reason: :no_batch_adapter}}` from any `batch/*` call.
> **Scope:** Cross-cutting Layer C surface parallel to chat/image/audio/embeddings. NOT a phase of any of those — `ALLM.Batch` is its own surface with its own behaviour and its own adapters. Composes with Phase 1+ chat (`%ALLM.Request{}`) and Phase 20 embeddings (`%ALLM.EmbeddingRequest{}`) as the carried payload types.
> **Layers touched:** A (four new structs) + B (one new behaviour + one new Fake + two new real providers) + C (four new facade functions). Three layers — split into sub-phases for incremental landing per the agent-spec/DESIGN.md "one layer per phase" rule when this gets phased.
> **Spec sections:** new §38 "Bulk Batch I/O" added to `steering/allm_engine_session_streaming_spec_v0_2.md`. (§36 = Embeddings per Phase 20; §37 = Audio per Phase 19.)

## Status

This is a design document, NOT a phase document. Phasing TBD — recommended split below under "Suggested Phasing".

| Section | Description |
|---------|-------------|
| Overview | Why bulk batch is its own surface (not folded into existing pipelines) |
| Provider landscape | OpenAI `/v1/batches`, Anthropic `/v1/messages/batches`, what's deferred |
| Layer A | `BatchRequest`, `BatchJob`, `BatchResult`, `BatchUsage` |
| Layer B | `ALLM.BatchAdapter` behaviour + `FakeBatch` + two real providers |
| Layer C | `ALLM.batch/3`, `ALLM.fetch_batch/3`, `ALLM.cancel_batch/3`, `ALLM.await_batch/3` |
| Engine wiring | `:batch_adapter` field; `:no_batch_adapter` engine error |
| Telemetry | `[:allm, :batch, :start \| :stop]` spans |
| Out of scope | Gemini Vertex BatchPredictionJob, audio batch (no provider supports), image batch (none), audio-specialist async/STT (separate from this surface — see PHASE_19) |
| Suggested phasing | 5 sub-phases, contract-first |

---

## Overview

ALLM's chat, embedding, image, and audio surfaces are all request/response primitives that return synchronously (or stream). They are designed for the latency-sensitive online path. **Bulk batch** is a different shape: callers submit many requests at once, accept a 24-hour SLA, and get a 50% cost discount in return. This is the primary cost-reduction lever for callers using ALLM in offline/batch workloads (data pipelines, dataset enrichment, eval harnesses, scheduled report generation).

Batch is **structurally distinct** from any per-pipeline async surface:

- It is **N → N** (many requests, many responses), not 1 → 1
- It crosses **multiple payload types** (chat completions AND embeddings AND completions AND responses are all batchable on OpenAI; messages on Anthropic) — folding it into any single pipeline's adapter would force that adapter to handle payload types it doesn't otherwise know about
- It produces **persistent job handles** that callers expect to outlive a process (submit at 9am, poll at 3pm, fetch overnight) — Layer A serializability is load-bearing
- It has a distinct **lifecycle vocabulary** (`validating`, `in_progress`, `finalizing`, `completed`, `failed`, `cancelled`, `expired`) that doesn't map onto the existing `Response.finish_reason` closed enum

### Why a separate behaviour, not a callback on existing adapters

A `BatchAdapter` is parallel to `Adapter` (chat), `EmbeddingAdapter`, `ImageAdapter`, `AudioAdapter` — it handles its own dedicated provider endpoint family (`/v1/batches`, `/v1/messages/batches`) which is *different* from the per-pipeline endpoints. The same provider company's chat adapter and batch adapter are different modules and may be authored independently — `ALLM.Providers.OpenAI` (chat) and `ALLM.Providers.OpenAI.Batch` are sibling modules under the same provider namespace, each implementing its own behaviour. This matches the existing topology: `ALLM.Providers.OpenAI` (chat) and `ALLM.Providers.OpenAI.Images` (image) and `ALLM.Providers.OpenAI.Audio` (audio) are already siblings.

### Why `ALLM.Batch` is the right level of generality

The surface accepts a list of `%ALLM.Request{}` (chat) OR a list of `%ALLM.EmbeddingRequest{}` (embeddings) per submission — never mixed. Each adapter's `supported_input_types/0` declares which payload struct types it accepts:

- `OpenAI.Batch.supported_input_types/0` → `[ALLM.Request, ALLM.EmbeddingRequest]`
- `Anthropic.Batch.supported_input_types/0` → `[ALLM.Request]` (Anthropic batches messages only)

Mixing types within a single batch is rejected by the validator BEFORE I/O. This matches the OpenAI Batch wire constraint (one `endpoint:` parameter per batch) and the Anthropic Batch reality (only one endpoint exists). The `BatchRequest` itself does NOT carry a `target:` enum — the target is inferred from the homogeneous request type.

### Layer demonstration

**Layer A — Batch data:**

```elixir
chat_reqs = [
  %ALLM.Request{model: "gpt-4o-mini", thread: %ALLM.Thread{messages: [%ALLM.Message{role: :user, content: "Question 1"}]}},
  %ALLM.Request{model: "gpt-4o-mini", thread: %ALLM.Thread{messages: [%ALLM.Message{role: :user, content: "Question 2"}]}}
]

batch_req = ALLM.batch_request(chat_reqs, completion_window: "24h", metadata: %{"job" => "eval-2026-05-06"})
:ok = ALLM.Validate.batch_request(batch_req)
^batch_req = batch_req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
```

**Layer B — Adapter behaviour + Fake:**

```elixir
ALLM.Providers.FakeBatch.script(submit: [
  {:ok, %ALLM.BatchJob{id: "batch_demo", status: :in_progress, provider: ALLM.Providers.FakeBatch}}
])

engine = ALLM.Engine.new(batch_adapter: ALLM.Providers.FakeBatch)
{:ok, %ALLM.BatchJob{id: id, status: :in_progress}} = ALLM.batch(engine, batch_req)
```

**Layer C — Submit / fetch / await:**

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, batch_adapter: ALLM.Providers.OpenAI.Batch)

{:ok, %ALLM.BatchJob{id: id, status: :validating}} = ALLM.batch(engine, batch_req)

# Persist the id; come back later (24h SLA)
{:ok, %ALLM.BatchJob{status: :completed, results: results}} = ALLM.await_batch(engine, id, timeout_ms: 25 * 60 * 60 * 1000)

for %ALLM.BatchResult{custom_id: cid, response: %ALLM.Response{} = resp} <- results do
  IO.puts("#{cid}: #{ALLM.Response.text(resp)}")
end
```

**Layer D — Sessions are unchanged.** Batch operates on stateless requests; session continuation is orthogonal. A caller can submit a batch of N chat completions where each chat is a continuation of a different session — the batch adapter does not see the session, only the snapshot `%Request{}`.

---

## Provider landscape (verified via context7 on 2026-05-06)

### OpenAI `/v1/batches`

- **File-based.** Caller uploads a JSONL file via `POST /v1/files` with `purpose: "batch"`, gets a `file_id`, then `POST /v1/batches` with `{file_id, endpoint, completion_window: "24h"}`.
- **Each JSONL line:** `{"custom_id": "<unique>", "method": "POST", "url": "/v1/chat/completions", "body": {<request>}}` — `body` is the full request payload that would normally hit the synchronous endpoint.
- **Supported endpoints:** `/v1/chat/completions`, `/v1/embeddings`, `/v1/completions`, `/v1/responses`. **NOT `/v1/audio/*`, NOT `/v1/images/*`.**
- **Discount:** 50% off the synchronous price.
- **SLA:** 24 hours.
- **Status enum:** `validating → in_progress → finalizing → completed | failed | cancelling → cancelled | expired`.
- **Result retrieval:** when `status: :completed`, the `BatchJob` carries `output_file_id` (and `error_file_id` if any). Caller `GET /v1/files/<file_id>/content` to stream JSONL of `{custom_id, response | error}` rows.
- **Cancellation:** `POST /v1/batches/<id>/cancel`; status → `cancelling` → `cancelled`. In-flight requests are NOT refunded.
- **Limits:** 50,000 requests per batch; 200 MB file size; 100 enqueued tokens limit per workspace (varies by tier).
- **Listing:** `GET /v1/batches` paginated.

### Anthropic `/v1/messages/batches`

- **Inline-array.** Caller `POST /v1/messages/batches` with `{"requests": [{"custom_id": "<unique>", "params": <messages-body>}, ...]}`. No file upload.
- **Supported endpoints:** `/v1/messages` only. **No embeddings (Anthropic has none); no audio.**
- **Discount:** 50% off the synchronous Messages price.
- **SLA:** 24 hours (typically completes in minutes for small batches).
- **Status enum:** Anthropic uses `processing_status: "in_progress" | "ended"` — collapsed at the `BatchJob` level into the same closed enum as OpenAI to keep callers' code uniform; the adapter maps `"in_progress" → :in_progress` and `"ended"` to one of `:completed | :failed | :cancelled` based on `request_counts` and `cancel_initiated_at`.
- **Result retrieval:** when terminal, `GET /v1/messages/batches/<id>/results` returns a JSONL stream of `{custom_id, result: {type: "succeeded", message: <Message>} | {type: "errored", error: <error>}}` rows. Anthropic's beta API requires the `anthropic-beta: message-batches-2024-09-24` header.
- **Cancellation:** `POST /v1/messages/batches/<id>/cancel`; in-flight requests are NOT refunded.
- **Limits:** 100,000 requests per batch; results retained for 29 days.
- **Listing:** `GET /v1/messages/batches` paginated.

### Out of scope (initial bundle)

- **Gemini Vertex `BatchPredictionJob`.** Different I/O model — input is BigQuery table OR Cloud Storage file, output goes to BQ/GCS. State enum is `JOB_STATE_QUEUED | JOB_STATE_PENDING | JOB_STATE_RUNNING | JOB_STATE_SUCCEEDED | JOB_STATE_FAILED`. Adapting this to ALLM's `BatchRequest{requests: [%Request{}]}` shape requires either (a) ALLM owning a GCS/BQ I/O glue layer or (b) the adapter writing inline-array submissions to a temporary GCS bucket on the caller's behalf — both warrant a separate design pass. **Defer.** The `BatchAdapter` behaviour ships in a shape that does not preclude future Gemini support (Decision #5 below).
- **Audio batch.** No provider supports it. OpenAI Batch does not support `/v1/audio/*` (verified 2026-05-06). Out of scope.
- **Image batch.** No provider supports it. OpenAI Batch does not support `/v1/images/*`. Out of scope.
- **Single-input async-STT.** AssemblyAI / AWS Transcribe / GCP `LongRunningRecognize` / Azure Speech / Deepgram are speech-only vendors with audio-specialist APIs that don't fit ALLM's LLM-provider-neutral abstraction. They are out of scope per `steering/PHASE_19_DESIGN.md` Decision #14 and NOT modeled here.
- **Mixed-payload batches.** A caller cannot submit a batch where some rows are `%Request{}` and some are `%EmbeddingRequest{}`. Validator rejects pre-I/O. Provider wires don't support it either (OpenAI's `endpoint:` parameter is per-batch).

---

## Non-obvious decisions

1. **`%BatchRequest{requests: [Request.t() | EmbeddingRequest.t()]}` carries homogeneous request structs — NOT raw maps.** The OpenAI wire requires `body: <request-shape>` per JSONL row; Anthropic's wire requires `params: <messages-shape>` per array entry. The natural temptation is to model `BatchRequest.requests` as `[%{custom_id: String.t(), body: map()}]` — pre-stringified provider-specific payloads. Don't. Use the existing Layer A request structs (`%ALLM.Request{}`, `%ALLM.EmbeddingRequest{}`) so the same validator + capability pre-flight + serialization logic applies. Adapters translate to provider-specific JSONL/JSON at submit time, identical to what they already do in the synchronous surface. **Concretely:** `ALLM.Providers.OpenAI.Batch.submit/2` reuses `ALLM.Providers.OpenAI.to_openai_messages/1` (chat translator) and `ALLM.Providers.OpenAI.Embeddings.to_request_body/1` (when available) per-row. *Docs target:* `@moduledoc ALLM.BatchRequest`; spec §38.2.

2. **`custom_id` is caller-supplied, NOT auto-generated.** Both providers require `custom_id` to be unique per batch. Auto-generating means callers who lose track of which result corresponds to which input have no recovery path. Enforce caller-supplied: `BatchRequest.requests` is `[{custom_id :: String.t(), Request.t() | EmbeddingRequest.t()}]` — a tagged tuple, not a struct field, because `Request` already has its own `metadata:` and we don't want `custom_id` to bleed into the synchronous surface. Validator rejects empty `custom_id`, duplicate `custom_id` within a batch, and `custom_id` longer than 64 characters (OpenAI's documented cap). *Docs target:* `@spec ALLM.batch_request/2`; spec §38.2.

3. **`%BatchJob{}` is the persistence-key Layer A struct.** Round-trips ETF + JSON. `:provider` is the adapter module atom (decoded via `restore_module/1` on JSON, matching `Engine.audio_adapter` / `Engine.image_adapter` patterns). `:created_at` and `:completed_at` are `DateTime.t()` in memory, ISO-8601 strings on JSON. `:results` is `nil` until terminal, then `[%BatchResult{}]` (potentially long — adapters may stream from the JSONL endpoint and materialize the full list lazily for callers asking for `await_batch/3`). *Docs target:* `@moduledoc ALLM.BatchJob`; spec §38.2.

4. **`%BatchResult{}` carries either `:response` OR `:error`, never both.** Each row in the JSONL output corresponds to one `custom_id`. Either the request succeeded (`response: %Response{} | %EmbeddingResponse{}`) or it failed (`error: %AdapterError{} | %EmbeddingAdapterError{} | %BatchAdapterError{}`). Validator enforces mutual exclusion. *Docs target:* `@moduledoc ALLM.BatchResult`; spec §38.2.

5. **Status enum is closed and provider-normalized.** `:validating | :in_progress | :finalizing | :completed | :failed | :cancelled | :expired`. OpenAI maps directly. Anthropic maps `"in_progress" → :in_progress`, `"ended"` to one of `:completed | :failed | :cancelled` based on `request_counts.errored` count + `cancel_initiated_at` presence. Future Gemini adapter will map `JOB_STATE_QUEUED → :validating`, `JOB_STATE_PENDING → :validating`, `JOB_STATE_RUNNING → :in_progress`, `JOB_STATE_SUCCEEDED → :completed`, `JOB_STATE_FAILED → :failed`. The mapping table is in each adapter's `@doc`, not a global lookup, so providers don't drift toward a least-common-denominator vocabulary. *Docs target:* `@type ALLM.BatchJob.status`; spec §38.2.

6. **`completion_window:` is optional, defaults `"24h"`.** Both providers currently accept only `"24h"` per their public docs as of 2026-05-06. Modeling it as a free `String.t()` (not an enum) future-proofs against a future `"7d"` or `"1h"` tier without a breaking change. *Docs target:* `@type ALLM.BatchRequest.completion_window`; spec §38.2.

7. **`ALLM.await_batch/3` is a polling helper, NOT an adapter callback.** Polling intervals are application-level policy. Implemented in pure `lib/allm.ex` as a `Stream.iterate/Enum.reduce_while` loop calling `fetch_batch/3` with backoff. Default backoff: `[5_000, 15_000, 60_000, 300_000, 600_000]` ms then steady-state 600s (10 min). Default cap: 25 hours wall-clock (1h slack on the 24h SLA). Both overridable via `opts[:poll_intervals_ms]` and `opts[:timeout_ms]`. Surfaces `{:error, %BatchAdapterError{reason: :timeout}}` on cap exceed. The longer-than-audio defaults reflect that batches aren't latency-sensitive. *Docs target:* `@doc ALLM.await_batch/3`; spec §38.6.

8. **Engine `:batch_adapter` is a separate field from `:adapter`.** A caller using the OpenAI chat adapter for sync work and the Anthropic batch adapter for offline cost savings is a real pattern. Don't conflate. The synchronous chat path goes through `engine.adapter`; the batch path goes through `engine.batch_adapter`. They can point at different providers. The `BatchAdapter` validates that `BatchRequest.requests` are shaped for ITS provider (e.g., `Anthropic.Batch` rejects `%Request{}` whose `model:` is an OpenAI model — pre-flight `:model_not_supported` check, not a wire round-trip). *Docs target:* `@doc ALLM.Engine`; spec §38.4.

9. **`%BatchUsage{}` aggregates per-row usage across the entire batch.** Each `%BatchResult{response: %Response{usage: %Usage{}}}` carries its own per-row usage; `%BatchJob{usage: %BatchUsage{}}` is the sum-rollup populated when the job lands terminal. Fields: `:input_tokens, :output_tokens, :total_tokens, :input_cost, :output_cost, :total_cost, :request_counts: %{total: n, completed: n, failed: n}`. Cost reflects the 50% discount when the adapter knows it; otherwise `nil` (depend on `llm_db` per existing `Usage.cost` pattern). The discount factor is provider-specific (`OpenAI.Batch` and `Anthropic.Batch` both currently 0.5) and lives in the adapter, not Layer A. *Docs target:* `@moduledoc ALLM.BatchUsage`; spec §38.2.

10. **No streaming variant in v0.4.** Both providers support batch results download as a stream (the JSONL output file is large for big batches), but the result is by definition not real-time — there's no analogue to chat's SSE. `fetch_batch/3` returns the full `%BatchJob{results: [...]}` once terminal. Adapters MAY internally stream-decode the JSONL file to avoid loading 200MB into memory, materializing the `[%BatchResult{}]` list lazily — this is an implementation detail of the adapter, not a public surface concern. *Docs target:* `@doc false` on `lazy_decode_results/1` if exposed.

11. **`BatchAdapter.supported_input_types/0` declares the legal request struct types.** OpenAI accepts `[ALLM.Request, ALLM.EmbeddingRequest]`; Anthropic accepts `[ALLM.Request]`. The facade `ALLM.batch/3` validates that all rows are of a single supported type BEFORE I/O. Mixed types raise `:mixed_input_types`; types not in `supported_input_types/0` raise `:unsupported_input_type`. *Docs target:* `@callback ALLM.BatchAdapter.supported_input_types/0`; spec §38.3.

12. **Anthropic batch is a beta API requiring a header.** As of 2026-05-06 the Anthropic Messages Batches API requires `anthropic-beta: message-batches-2024-09-24`. The `Anthropic.Batch` adapter sets this header automatically; callers do not. Document the beta status in the adapter `@moduledoc` AND in the README so callers know the API may evolve. When the API GAs the adapter drops the header — no caller code change. *Docs target:* `@moduledoc ALLM.Providers.Anthropic.Batch`; CHANGELOG note at GA time.

13. **OpenAI batch requires a two-step submit (file upload then batch create).** The adapter's `submit/2` does both atomically: builds the JSONL in memory, POSTs to `/v1/files` with `purpose: "batch"`, captures the `file_id`, POSTs to `/v1/batches` with the `file_id`. If step 2 fails, the uploaded file is leaked (no cleanup) — this is a documented limitation of the OpenAI API and not something ALLM can fix at this layer. The adapter logs a `Logger.warning(fn -> ... end)` (deferred form per CLAUDE.md) with the orphan `file_id` so callers can clean up via `DELETE /v1/files/<id>` if they care. *Docs target:* `@doc ALLM.Providers.OpenAI.Batch.submit/2`.

14. **`fetch_batch/3` accepts either `%BatchJob{}` or a raw `String.t()` job id.** The string form uses `engine.batch_adapter` as the resolver. The struct form uses `job.provider` as the resolver — letting a caller hold a job from one engine and resolve it via another engine that points at the same adapter module. Same pattern as Phase 19's audio facade Decision #14 (which was reverted along with the entire async-STT surface — but the polymorphic-resolver pattern survives here because batch ACTUALLY needs cross-engine resume across days, not minutes). *Docs target:* `@doc ALLM.fetch_batch/3`.

---

## Behaviour & Type Contracts

### `ALLM.BatchRequest` (Layer A)

```elixir
defmodule ALLM.BatchRequest do
  @type completion_window :: String.t()  # currently "24h"; freeform for forward-compat

  @type entry ::
          {custom_id :: String.t(), ALLM.Request.t() | ALLM.EmbeddingRequest.t()}

  @type t :: %__MODULE__{
          requests: [entry()],
          completion_window: completion_window(),
          metadata: map()
        }

  @enforce_keys [:requests]
  defstruct [
    :requests,
    completion_window: "24h",
    metadata: %{}
  ]

  @spec new([entry()], keyword()) :: t()
end
```

**Invariants:**

- `requests` is non-empty (validator rejects `[]`).
- All entries' second-element struct types match (validator rejects mixed `%Request{}` and `%EmbeddingRequest{}` in the same batch).
- All `custom_id` values are unique within the batch (validator deduplicates).
- Each `custom_id` is non-empty and ≤ 64 characters.
- ETF + JSON round-trip preserved.

### `ALLM.BatchJob` (Layer A)

```elixir
defmodule ALLM.BatchJob do
  @type status ::
          :validating
          | :in_progress
          | :finalizing
          | :completed
          | :failed
          | :cancelled
          | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          provider: module(),
          status: status(),
          completion_window: String.t() | nil,
          request_counts: %{total: non_neg_integer(), completed: non_neg_integer(), failed: non_neg_integer()},
          created_at: DateTime.t() | nil,
          in_progress_at: DateTime.t() | nil,
          finalizing_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          expired_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          results: [ALLM.BatchResult.t()] | nil,
          usage: ALLM.BatchUsage.t() | nil,
          error: ALLM.Error.BatchAdapterError.t() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :provider, :status]
  defstruct [
    :id,
    :provider,
    :status,
    :completion_window,
    :created_at,
    :in_progress_at,
    :finalizing_at,
    :completed_at,
    :failed_at,
    :expired_at,
    :cancelled_at,
    :results,
    :usage,
    :error,
    request_counts: %{total: 0, completed: 0, failed: 0},
    metadata: %{}
  ]
end
```

**Invariants:**

- `id` is the provider's batch identifier — opaque string. Persist this for cross-process resume.
- `status` ∈ closed enum above. Terminal: `:completed | :failed | :cancelled | :expired`.
- `results` is `nil` UNLESS `status == :completed` OR (`status == :failed` AND the provider returned a partial-results file).
- `error` is `nil` UNLESS `status == :failed` (job-level failure, not per-row failures — those live on each `%BatchResult{}.error`).
- `usage` is `nil` until terminal; populated on `:completed`.
- `provider` is the adapter module atom; round-tripped through `restore_module/1`.
- DateTime fields encode as ISO-8601 on JSON.
- ETF + JSON round-trip preserved.

### `ALLM.BatchResult` (Layer A)

```elixir
defmodule ALLM.BatchResult do
  @type t :: %__MODULE__{
          custom_id: String.t(),
          response: ALLM.Response.t() | ALLM.EmbeddingResponse.t() | nil,
          error: term() | nil,
          metadata: map()
        }

  @enforce_keys [:custom_id]
  defstruct [:custom_id, :response, :error, metadata: %{}]
end
```

**Invariants:**

- Exactly one of `:response` or `:error` is non-nil; both `nil` AND both populated are rejected by `Validate.batch_result/1`.
- `:error` is provider-specific — typed `term()` because OpenAI returns `%{code: String.t(), message: String.t()}` whereas Anthropic returns a richer error object. Adapters MAY wrap into `%BatchAdapterError{}` for uniformity; this is encouraged but not required.
- ETF + JSON round-trip preserved.

### `ALLM.BatchUsage` (Layer A)

```elixir
defmodule ALLM.BatchUsage do
  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          input_cost: float() | nil,
          output_cost: float() | nil,
          total_cost: float() | nil,
          discount_factor: float() | nil,
          request_counts: %{total: non_neg_integer(), completed: non_neg_integer(), failed: non_neg_integer()}
        }

  defstruct [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    discount_factor: 0.5,
    request_counts: %{total: 0, completed: 0, failed: 0}
  ]
end
```

**Invariants:**

- `discount_factor` defaults `0.5` matching both OpenAI and Anthropic public pricing as of 2026-05-06.
- Token + cost fields populate from per-row `%Response{usage: %Usage{}}` aggregation when the adapter has them; `nil` otherwise.

### `ALLM.BatchAdapter` (Layer B)

```elixir
defmodule ALLM.BatchAdapter do
  @callback submit(ALLM.BatchRequest.t(), keyword()) ::
              {:ok, ALLM.BatchJob.t()}
              | {:error, ALLM.Error.BatchAdapterError.t()}

  @callback fetch(ALLM.BatchJob.t() | String.t(), keyword()) ::
              {:ok, ALLM.BatchJob.t()}
              | {:error, ALLM.Error.BatchAdapterError.t()}

  @callback cancel(ALLM.BatchJob.t() | String.t(), keyword()) ::
              {:ok, ALLM.BatchJob.t()}
              | {:error, ALLM.Error.BatchAdapterError.t()}

  @callback supported_input_types() :: [module()]

  @callback list(keyword()) ::
              {:ok, [ALLM.BatchJob.t()], cursor :: String.t() | nil}
              | {:error, ALLM.Error.BatchAdapterError.t()}

  @optional_callbacks list: 1
end
```

**Invariants:**

1. `submit/2` validates `request.requests`'s entry types against `supported_input_types/0` BEFORE I/O. Mixed or unsupported types yield `{:error, %BatchAdapterError{reason: :unsupported_input_type | :mixed_input_types}}`.
2. `submit/2` is synchronous (HTTP submit completes before return). Returns immediately with status `:validating` or `:in_progress` — does NOT block until terminal.
3. `fetch/2` is synchronous (one HTTP round-trip).
4. `cancel/2` is idempotent on terminal-state jobs (returns the job unchanged with no error).
5. All callbacks honor `opts[:request_timeout]` (default 60s).
6. `list/1` is OPTIONAL. Adapters that don't implement it return `{:error, %BatchAdapterError{reason: :unsupported_operation}}` from `ALLM.list_batches/2` (if exposed at facade level — see "Optional facade extensions" below).

### `ALLM.batch/3`, `ALLM.fetch_batch/3`, `ALLM.cancel_batch/3`, `ALLM.await_batch/3` (Layer C)

```elixir
@spec batch(Engine.t(), BatchRequest.t() | [entry()], keyword()) ::
        {:ok, BatchJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | BatchAdapterError.t()}

@spec fetch_batch(Engine.t(), BatchJob.t() | String.t(), keyword()) ::
        {:ok, BatchJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | BatchAdapterError.t()}

@spec cancel_batch(Engine.t(), BatchJob.t() | String.t(), keyword()) ::
        {:ok, BatchJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | BatchAdapterError.t()}

@spec await_batch(Engine.t(), BatchJob.t() | String.t(), keyword()) ::
        {:ok, BatchJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | BatchAdapterError.t()}
```

**Dispatch invariants:**

- All four gate FIRST on `engine.batch_adapter == nil → {:error, %EngineError{reason: :no_batch_adapter}}`.
- `batch/3` accepts a bare `[entry()]` list as a sugar second arg; constructs a default `%BatchRequest{}` internally (with `completion_window: "24h"`).
- `fetch_batch/3` / `cancel_batch/3` / `await_batch/3` accept `%BatchJob{}` OR `String.t()` raw id. Struct form uses `job.provider` as resolver; string form uses `engine.batch_adapter`.
- `await_batch/3` is a polling helper. Default backoff `[5_000, 15_000, 60_000, 300_000, 600_000]` ms then steady-state 600s. Default cap 25h. Surfaces `:timeout` BatchAdapterError on exceed.
- All four fire telemetry `:batch` spans with `:operation ∈ [:submit, :fetch, :cancel, :await]` and `:job_id`, `:provider`, `:request_count` metadata.
- Per-attempt `Retry.run/3` wraps `submit/3` and `fetch/3` with the batch-side retry policy (`@retryable_batch_reasons = [:rate_limited, :provider_unavailable, :timeout, :network_error]`).

---

## Engine wiring

```elixir
%ALLM.Engine{
  adapter: nil | module(),
  embed_adapter: nil | module(),
  image_adapter: nil | module(),
  audio_adapter: nil | module(),
  batch_adapter: nil | module(),  # NEW
  ...
}
```

`audio_adapter:` decode site at `lib/allm/engine.ex:395` extends to `batch_adapter:` — same `restore_module/1` pattern. Engine round-trips ETF + JSON with `batch_adapter` populated; backwards-compatible with engines that omit it (defaults to `nil`).

---

## Telemetry

`[:allm, :batch, :start | :stop]` spans wrap every Layer C dispatch.

**Start measurements:** `system_time`.
**Start metadata:** `:operation` ∈ `[:submit, :fetch, :cancel, :await]`, `:provider`, `:request_id`, `:job_id` (nil for `:submit`), `:request_count` (for `:submit` only).

**Stop measurements:** `:duration` (microseconds).
**Stop metadata:** all start keys plus `:job_status`, `:result` (the `%BatchJob{}` on success; `nil` on error), `:error` (the error struct on failure).

`:await` is wrapped as a single span over the entire poll loop; per-poll `:fetch` spans fire as nested children. Telemetry consumers that aggregate batch wall-time should subscribe to `:await` not `:fetch`.

---

## Error contract

`ALLM.Error.BatchAdapterError` reason enum (closed):

| Reason | Recovery guidance |
|--------|--------------------|
| `:rate_limited` | Provider 429; retry with backoff via `ALLM.Retry`. Surface `:retry_after_ms` if header present. |
| `:provider_unavailable` | 5xx; retry with backoff. |
| `:timeout` | Per-call timeout exceeded, OR `await_batch/3` cap exceeded. |
| `:network_error` | Transport error. Retry. |
| `:unsupported_operation` | `cancel/2` on a job from a provider whose adapter doesn't support it; `list/1` on an adapter without `list/1`. Caller bug. |
| `:unsupported_input_type` | `BatchRequest.requests` contains a struct type not in `supported_input_types/0` (e.g., `%EmbeddingRequest{}` to `Anthropic.Batch`). |
| `:mixed_input_types` | `BatchRequest.requests` contains mixed `%Request{}` and `%EmbeddingRequest{}`. |
| `:duplicate_custom_id` | Two entries with the same `custom_id` within a batch. |
| `:invalid_request` | 400 — provider rejected the batch shape. Inspect `metadata.cause`. |
| `:authentication_failed` | 401 — key invalid. |
| `:job_not_found` | 404 on `fetch/2` or `cancel/2`. Job id corruption, OR provider's retention window expired (Anthropic: 29 days). |
| `:job_expired` | Job lived past retention; results are no longer fetchable. Re-submit if the source data is still available. |
| `:request_too_large` | Batch exceeds provider limits (OpenAI: 50,000 requests OR 200 MB; Anthropic: 100,000 requests). Caller splits client-side. |
| `:internal_error` | Catch-all for malformed responses or unexpected adapter state. |
| `:no_scripted_response` | `FakeBatch` script queue exhausted. Test-only. |

`ALLM.Error.EngineError` enum extension:

| Reason | When |
|--------|------|
| `:no_batch_adapter` | `engine.batch_adapter == nil` and `batch/3`, `fetch_batch/3`, `cancel_batch/3`, or `await_batch/3` called. |

`ALLM.Error.ValidationError` extensions for batch:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:batch, :requests]` | `:empty` | yes | `requests == []` |
| `[:batch, :requests]` | `:mixed_input_types` | yes | rows contain mixed struct types |
| `[:batch, :custom_id]` | `:empty` | yes | any entry's `custom_id == ""` |
| `[:batch, :custom_id]` | `:duplicate` | yes | two entries share a `custom_id` |
| `[:batch, :custom_id]` | `:too_long` | yes | `String.length(custom_id) > 64` |
| `[:batch, :completion_window]` | `:invalid` | no | empty string |

---

## Suggested phasing

When this design is turned into phase docs, recommended split (5 sub-phases, contract-first):

| Phase | Description | Layer |
|-------|-------------|-------|
| **20.X.1** | Layer A — `BatchRequest`, `BatchJob`, `BatchResult`, `BatchUsage`, validators. | A |
| **20.X.2** | `ALLM.BatchAdapter` behaviour + conformance harness + `ALLM.Providers.FakeBatch` reference impl. | B |
| **20.X.3** | Engine `:batch_adapter` field + Layer C facade (`batch/3`, `fetch_batch/3`, `cancel_batch/3`, `await_batch/3`) + telemetry + capability pre-flight. | B + C |
| **20.X.4** | `ALLM.Providers.OpenAI.Batch` real adapter — file upload + `/v1/batches` + JSONL result decoding. Recorded fixtures + recorder script. Live smoke test. | B |
| **20.X.5** | `ALLM.Providers.Anthropic.Batch` real adapter — inline-array submit + JSONL result decoding + beta header. Recorded fixtures. Live smoke test. | B |
| **20.X.6** | Examples (`examples/N_batch_chat.exs` + `examples/N_batch_embed.exs`) + spec amendment §38 + CHANGELOG + README "Batch" section. | A/B/C |

Phase numbers depend on what's already shipped at the time the design lands — could be Phase 21+ if Phase 20 (Embeddings) ships first.

**Hard dependency:** Phase 20 (Embeddings) MUST be merged before sub-phase 20.X.4 because `OpenAI.Batch` reuses `OpenAI.Embeddings.to_request_body/1` for embedding rows. Phase 1+ chat is already shipped at HEAD.

**Live-API cost estimate per `/review`:** ~$0.02 OpenAI (small batch of 5 chat completions × 50% off) + ~$0.01 Anthropic (small batch of 5 messages × 50% off) ≈ $0.03 per clean run.

---

## Optional facade extensions (post-initial-bundle)

Defer to a follow-on phase:

- **`ALLM.list_batches/2`** — paginated list of in-flight + recent batches. Useful for resuming work after a process crash without persisting job ids client-side. Both OpenAI and Anthropic support listing; the facade is straightforward but adds API surface area. Defer until a caller asks.
- **Webhook ingestion helper** — neither provider offers webhooks for batch completion as of 2026-05-06. Anthropic has roadmapped them. When they ship, add a separate `ALLM.BatchWebhookHandler` Plug-style helper that callers mount in their Phoenix app and dispatch into a user-supplied callback. Not in scope for the initial bundle.
- **Batch retries at result granularity** — when a batch lands `:completed` with N successful rows and M failed rows, the caller often wants to re-submit JUST the M failed rows. A `ALLM.retry_failed/2` helper would build a new `%BatchRequest{}` from a `%BatchJob{results: [...]}` filtered to failed entries. Build when there's a real ask.
- **Gemini Vertex `BatchPredictionJob` adapter** — needs a separate design pass for the BQ/GCS I/O model. Not blocked by anything in this design — `ALLM.BatchAdapter` is shape-compatible with a future Gemini adapter that owns its own GCS upload / BQ insert internally.

---

## Cross-document consistency check

- Composes with **Phase 1+ chat** (uses `%ALLM.Request{}` as a row payload) — no chat-side changes required.
- Composes with **Phase 20 embeddings** (uses `%ALLM.EmbeddingRequest{}` as a row payload) — no embeddings-side changes required. Phase 20 must merge before `OpenAI.Batch` adapter.
- Does NOT touch **Phase 19 audio** (audio is sync-only per Phase 19 Decision #14; OpenAI Batch does not support `/v1/audio/*`).
- Does NOT touch **image surface** (no provider supports image batch).
- Spec section claim: **§38** ("Bulk Batch I/O"). Does NOT collide with §36 (Embeddings, claimed by Phase 20) or §37 (Audio, claimed by Phase 19).
- Uses the same Layer A discipline as every other ALLM struct: ETF + JSON round-trip; no PIDs / refs / funs / API keys; provider atom decoded via `restore_module/1`.
- Adapter behaviour pattern matches `ImageAdapter` / `AudioAdapter` / `EmbeddingAdapter` (one provider module, one behaviour, optional callbacks for less-universal operations like `list/1`).
- Error type pattern matches `ImageAdapterError` / `AudioAdapterError` / `EmbeddingAdapterError` (closed reason enum, `defexception`, ETF + JSON round-trip).
- Telemetry span pattern matches `:image` / `:audio` / `:embed` (atom for the surface; `:operation` as metadata field).
- All API-shape claims verified via context7 against `developers.openai.com/api/reference/resources/batches/methods/create` and `anthropics/anthropic-sdk-python` on 2026-05-06.
