defmodule ALLM.ModerationAdapter do
  @moduledoc """
  Content-moderation provider adapter contract.

  Layer B — runtime. Implementations take an `ALLM.ModerationRequest` plus a
  keyword opts list (resolved at the call site by `ALLM.moderate/3`)
  and return either `{:ok, %ALLM.ModerationResponse{}}` or
  `{:error, %ALLM.Error.ModerationAdapterError{}}`.

  ## Minimum impl skeleton

      defmodule MyModerationProvider do
        @behaviour ALLM.ModerationAdapter

        @impl true
        def moderate(%ALLM.ModerationRequest{input: input} = request, _opts) do
          # Invariant 5 measures ITEMS: a multimodal input is one item.
          count = if ALLM.ModerationRequest.multimodal?(request), do: 1, else: length(input)

          cond do
            input == [] ->
              {:error, %ALLM.Error.ModerationAdapterError{reason: :invalid_request}}

            count > max_batch_size() ->
              {:error,
               %ALLM.Error.ModerationAdapterError{
                 reason: :batch_too_large,
                 metadata: %{count: count, max: max_batch_size()}
               }}

            true ->
              # Translate request -> HTTP body, fire via Req, translate
              # response -> %ALLM.ModerationResponse{}.
              {:ok, %ALLM.ModerationResponse{}}
          end
        end

        @impl true
        def max_batch_size, do: 32
      end

  Both gates are mandatory (invariants 5 and 6) and both MUST run before any
  HTTP I/O — and, for an adapter that resolves credentials, before
  `ALLM.Keys.fetch!/2`, so that a keyless environment still observes the
  rejection rather than a `%ALLM.Error.EngineError{reason: :missing_key}`.

  ## HTTP transport guidance

  Use `Req` for moderation calls. Moderation is a request/response shape —
  there is no streaming counterpart, so there is no `stream_moderate/2` and
  no `ALLM.ModerationStreamAdapter`.

  ## Batching

  `max_batch_size/0` is the per-request input cap the provider documents.
  Unlike the embeddings family, the moderation façade does **not** chunk an
  oversized call transparently: one HTTP call produces exactly one provider
  response id, and merging N chunks would have N ids and nowhere to put
  them. Callers who need more inputs than the cap chunk with
  `Enum.chunk_every/2` themselves and get `:batch_too_large` when they
  exceed it.

  ## Invariants

    1. `max_batch_size/0` returns a `pos_integer()` and is per-module — one
       number for the adapter, NOT per-call-with-model-arg. Per-model limits
       are the adapter's internal concern.
    2. `moderate/2` returns exactly `{:ok, %ALLM.ModerationResponse{}}` or
       `{:error, %ALLM.Error.ModerationAdapterError{}}` — never a bare
       struct, never a three-tuple. Network failures, 4xx, and 5xx all
       convert to the error tuple. The one documented exception is
       `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design; adapters do
       not rescue it.

       **Enforced, not merely documented:** `ALLM.moderate/3` raises
       `ArgumentError` naming the adapter and this invariant on any other
       shape, rather than laundering a non-conforming return into its own
       error union. Note that the conformance suite cannot observe this
       invariant — the enforcement lives at the façade, not inside any
       adapter — so a green conformance run is not evidence that every
       failure shape has been converted.
    3. Result cardinality follows `ALLM.ModerationRequest`'s normative rule:
       for an all-strings `:input`, exactly `length(request.input)` results;
       for an `:input` containing any `%ALLM.ImagePart{}`, exactly **one**
       result, because the whole list is one multimodal item.
    4. `:index` values on the returned results are exactly
       `0..length(results)-1`.
    5. `moderate/2` MUST return
       `{:error, %ALLM.Error.ModerationAdapterError{reason: :batch_too_large,
       metadata: %{count: n, max: max_batch_size()}}}` when the request's
       **item count** exceeds `max_batch_size()`, **before any I/O** and —
       for an adapter that resolves credentials — **before**
       `ALLM.Keys.fetch!/2`, so a keyless environment observes the rejection
       rather than `%ALLM.Error.EngineError{reason: :missing_key}`.

       The item count is the one invariant 3 defines, NOT the raw list
       length: `length(request.input)` for an all-strings `:input`, and
       exactly `1` for an `:input` containing any `%ALLM.ImagePart{}`,
       because the whole list is one multimodal item. `metadata.count`
       carries that item count. A multimodal request therefore never trips
       this gate, `max_batch_size/0` being a `pos_integer()` — which is what
       keeps conformance case 10 correct for an adapter whose cap is `1`.
    6. `moderate/2` MUST return
       `{:error, %ALLM.Error.ModerationAdapterError{reason: :invalid_request}}`
       for `input: []`, under the same before-I/O and before-key ordering.
       The bar holds at the adapter for direct callers even though the façade
       also validates.
    7. `moderate/2` MUST preserve `opts[:request_id]` onto
       `response.request_id` when supplied. When `opts[:request_id]` is
       absent, the adapter is free to populate it from a provider-supplied
       correlation id.
    8. `moderate/2` MUST round-trip `request.metadata` onto
       `response.metadata` UNCHANGED. (The library treats request/response
       metadata as opaque.)
    9. `moderate/2` MUST honour `opts[:request_timeout]` if provided.
       Exceeding the timeout produces
       `{:error, %ALLM.Error.ModerationAdapterError{reason: :timeout}}` —
       the reason `ALLM.Error.ModerationAdapterError` publishes as *"adapter
       `request_timeout` exceeded"* and the one the moderation façade retries
       automatically. Without this obligation nothing in a conforming adapter
       would ever emit `:timeout` and the façade's retry policy would cover a
       reason no implementation produces.
   10. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `moderate/2` would fire it, and is defined only
       for a request whose item count (invariant 5) is
       `<= max_batch_size()`. Callers may mutate the returned request before
       firing.

  (Invariants 9 and 10 were **appended** rather than slotted in: 1–8 are
  cited by number from the conformance suite's case names and from the
  design's forward-binding notes, so the existing numbering is frozen.)

  **Cleanup invariant: none.** There is no `Stream.resource/3` and no Finch
  ref in a moderation call — `Req.request/1` owns its connection lifecycle.
  Stated explicitly so the absence reads as intent rather than omission.
  """

  @doc """
  Classify a moderation request against the provider synchronously.

  Returns `{:ok, %ALLM.ModerationResponse{}}` on success, or
  `{:error, %ALLM.Error.ModerationAdapterError{}}` on every failure shape.
  See `ALLM.Error.ModerationAdapterError` for the closed reason enum and the
  per-reason recovery table.
  """
  @callback moderate(ALLM.ModerationRequest.t(), keyword()) ::
              {:ok, ALLM.ModerationResponse.t()}
              | {:error, ALLM.Error.ModerationAdapterError.t()}

  @doc """
  Return the maximum number of inputs the provider accepts in a single
  request.

  Per-module (one number for the adapter), NOT per-call-with-model-arg.
  Per-model caps are the adapter's internal concern.

  Callers that need to moderate more inputs than the cap chunk the list
  themselves — the moderation façade does not chunk transparently. See the
  `## Batching` section of the module docs.
  """
  @callback max_batch_size() :: pos_integer()

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the caller
  can further customize (headers, retries, middleware) before firing.

  Optional. When unimplemented, callers must dispatch to `moderate/2`
  directly. Per invariant 10 the returned request must be configured exactly
  as `moderate/2` would fire it, and the callback is defined only for a
  request whose item count is `<= max_batch_size()`.
  """
  @callback prepare_request(ALLM.ModerationRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ModerationAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
