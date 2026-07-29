defmodule ALLM.EmbeddingAdapter do
  @moduledoc """
  Text-embedding provider adapter contract.

  Layer B — runtime. Implementations take an `ALLM.EmbeddingRequest` plus a
  keyword opts list (resolved at the call site by `ALLM.embed/3`) and return
  either `{:ok, %ALLM.EmbeddingResponse{}}` or
  `{:error, %ALLM.Error.EmbeddingAdapterError{}}`.

  ## Minimum impl skeleton

      defmodule MyEmbeddingProvider do
        @behaviour ALLM.EmbeddingAdapter

        @impl true
        def embed(%ALLM.EmbeddingRequest{input: input}, _opts) do
          cond do
            input == [] ->
              {:error, %ALLM.Error.EmbeddingAdapterError{reason: :invalid_request}}

            length(input) > max_batch_size() ->
              {:error,
               %ALLM.Error.EmbeddingAdapterError{
                 reason: :batch_too_large,
                 metadata: %{count: length(input), max: max_batch_size()}
               }}

            true ->
              # Translate request -> HTTP body, fire via Req, translate
              # response -> %ALLM.EmbeddingResponse{}.
              {:ok, %ALLM.EmbeddingResponse{}}
          end
        end

        @impl true
        def max_batch_size, do: 1_000
      end

  Both gates are mandatory (invariants 4 and 5) and both MUST run before any
  HTTP I/O — and, for an adapter that resolves credentials, before
  `ALLM.Keys.fetch!/2`, so that a keyless environment still observes the
  rejection rather than a `%ALLM.Error.EngineError{reason: :missing_key}`.

  ## HTTP transport guidance

  Use `Req` for embedding calls. Embeddings are a request/response shape —
  there is no streaming counterpart, so there is no `stream_embed/2` and no
  `ALLM.EmbeddingStreamAdapter`.

  ## Batching

  `max_batch_size/0` is the per-request input cap the provider documents.
  `ALLM.embed/3` splits an oversized call into chunks of at most that many
  inputs and merges the responses, so `embed/2` never sees more than
  `max_batch_size/0` inputs through the façade. Callers driving an adapter
  directly are responsible for their own chunking and get `:batch_too_large`
  when they exceed the cap.

  ## Invariants

    1. `embed/2` is synchronous: it returns only after the HTTP response has
       been read in full.
    2. `embed/2` never raises for HTTP-shaped failures. Network failures, 4xx,
       and 5xx all convert to
       `{:error, %ALLM.Error.EmbeddingAdapterError{reason: ..., ...}}`. The one
       documented exception is `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design; adapters do
       not rescue it.

       The return shape is enforced, not merely documented: `ALLM.embed/3`
       raises `ArgumentError` naming the adapter and this invariant when
       `embed/2` returns anything other than those two tuples. The façade does
       not launder non-conforming shapes into its own error union. Note that
       the conformance suite's error cases are pre-flight argument gates, so a
       transport, auth, or rate-limit failure that returns a raw error struct
       will pass conformance and raise in production — convert every failure
       shape.
    3. `embed/2` MUST honor `opts[:request_timeout]` if provided. Exceeding the
       timeout produces
       `{:error, %ALLM.Error.EmbeddingAdapterError{reason: :timeout}}`.
    4. `embed/2` MUST return
       `{:error, %ALLM.Error.EmbeddingAdapterError{reason: :batch_too_large,
       metadata: %{count: n, max: max_batch_size()}}}` BEFORE any HTTP I/O when
       `length(request.input) > max_batch_size()`.
    5. `embed/2` MUST return
       `{:error, %ALLM.Error.EmbeddingAdapterError{reason: :invalid_request}}`
       for `input: []` BEFORE any HTTP I/O. The bar holds at the adapter for
       direct callers even though `ALLM.embed/3` also validates.
    6. `embed/2` MUST preserve `opts[:request_id]` onto `response.request_id`
       when the response shape allows. When `opts[:request_id]` is absent, the
       adapter is free to populate it from a provider-supplied id.
    7. `embed/2` MUST round-trip `request.metadata` onto `response.metadata`
       UNCHANGED when the adapter has no use for it. (The library treats
       request/response metadata as opaque.)
    8. `embed/2` MUST return exactly `length(request.input)` embeddings on
       success, with `:index` values `0..length-1`, each vector the same
       non-zero length.
    9. `max_batch_size/0` is per-module and constant — NOT per-model. Per-model
       limits are the adapter's internal concern.
   10. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `embed/2` would fire it, and is defined only for
       `length(input) <= max_batch_size()`. Callers may mutate the returned
       request before firing.

  **Cleanup invariant: none.** There is no `Stream.resource/3` and no Finch
  ref in an embeddings call — `Req.request/1` owns its connection lifecycle.
  Stated explicitly so the absence reads as intent rather than omission.
  """

  @doc """
  Execute an embedding request against the provider synchronously.

  Returns `{:ok, %ALLM.EmbeddingResponse{}}` on success, or
  `{:error, %ALLM.Error.EmbeddingAdapterError{}}` on every failure shape.
  See `ALLM.Error.EmbeddingAdapterError` for the closed reason enum and the
  per-reason recovery table.
  """
  @callback embed(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, ALLM.EmbeddingResponse.t()}
              | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @doc """
  Return the maximum number of inputs the provider accepts in a single
  request.

  Per-module (one number for the adapter), NOT per-call-with-model-arg.
  Per-model caps are the adapter's internal concern.

  `ALLM.embed/3` reads this to size its chunks. Callers who need bounded
  retry or wall-clock budgets read it too, and drive `embed/2` a chunk at a
  time themselves.
  """
  @callback max_batch_size() :: pos_integer()

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the caller
  can further customize (headers, retries, middleware) before firing.

  Optional. When unimplemented, callers must dispatch to `embed/2` directly.
  """
  @callback prepare_request(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
