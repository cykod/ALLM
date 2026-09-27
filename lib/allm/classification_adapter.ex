defmodule ALLM.ClassificationAdapter do
  @moduledoc """
  Typed-classification provider adapter contract.

  Layer B — runtime. Implementations take an `ALLM.ClassificationRequest`
  (one piece of state plus N named `ALLM.ClassificationQuestion`s) and a
  keyword opts list, and return either `{:ok, %ALLM.ClassificationResponse{}}`
  or `{:error, %ALLM.Error.ClassificationAdapterError{}}`.

  Classification is a capability of its own, not a use of a chat model: the
  provider answers closed-form questions (pick one option, score on a scale,
  yes/no) with calibrated probabilities and generates no text. It is also
  request/response only, so there is no streaming counterpart.

  ## Minimum impl skeleton

      defmodule MyClassificationProvider do
        @behaviour ALLM.ClassificationAdapter

        @impl true
        def classify(%ALLM.ClassificationRequest{questions: questions} = request, opts) do
          if questions == %{} do
            {:error, %ALLM.Error.ClassificationAdapterError{reason: :invalid_request}}
          else
            # Translate request -> HTTP body, fire via Req, translate
            # response -> one %ALLM.ClassificationAnswer{} per question id.
            {:ok,
             %ALLM.ClassificationResponse{
               request_id: Keyword.get(opts, :request_id),
               metadata: request.metadata
             }}
          end
        end
      end

  The empty-questions gate is mandatory (invariant 6) and MUST run before any
  HTTP I/O and, for an adapter that resolves credentials, before
  `ALLM.Keys.fetch!/2`, so a keyless environment still observes the rejection
  rather than a `%ALLM.Error.EngineError{reason: :missing_key}`. Any
  provider-specific limit (a maximum option count, a maximum level count) is
  enforced the same way, as `:invalid_request`, ahead of the key.

  ## HTTP transport guidance

  Use `Req` for classification calls. Make one HTTP attempt per call: the
  façade already retries retryable reasons, so an inner retry loop would
  multiply the attempt count. Populate `retry_after_ms` on
  `:rate_limited` errors so callers who drive the adapter directly can retry
  themselves.

  ## Invariants

    1. `classify/2` returns exactly `{:ok, %ALLM.ClassificationResponse{}}` or
       `{:error, %ALLM.Error.ClassificationAdapterError{}}` — never a bare
       struct, never a three-tuple. Network failures, 4xx and 5xx all convert
       to the error tuple. The one documented exception is
       `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design; adapters do
       not rescue it. The conformance suite cannot observe this invariant:
       the check lives at the call site that dispatches to the adapter, so a
       green conformance run is not evidence that every failure shape has
       been converted.
    2. On `{:ok, response}`, `Map.keys(response.answers)` equals
       `Map.keys(request.questions)` as sets: one answer per question id, no
       extras.
    3. Each answer's `:type` equals its question's `:type`, and its fields are
       populated as the `ALLM.ClassificationAnswer` field table says for that
       type.
    4. A `:choice` answer's `:choice` is one of the question's criteria keys,
       and its `:probabilities` keys equal the criteria keys.
    5. A `:score` answer's `:probabilities` and `:legend` each have one entry
       per level (`length(question.criteria)`).
    6. Empty questions (`questions: %{}`) are rejected with `:invalid_request`
       **before any I/O and before `ALLM.Keys.fetch!/2`**.
    7. `request.metadata` round-trips onto `response.metadata` unchanged, and
       `opts[:request_id]` is reflected onto `response.request_id` unchanged.
    8. `opts[:request_timeout]` is honoured. Exceeding it yields
       `{:error, %ALLM.Error.ClassificationAdapterError{reason: :timeout}}`.
    9. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `classify/2` would fire it. Callers may mutate
       it before firing.

  **Cleanup invariant: none.** There is no `Stream.resource/3` and no Finch
  ref in a classification call — `Req.request/1` owns its connection
  lifecycle. Stated explicitly so the absence reads as intent rather than
  omission.
  """

  @doc """
  Answer every question in a classification request synchronously.

  Returns `{:ok, %ALLM.ClassificationResponse{}}` carrying one
  `%ALLM.ClassificationAnswer{}` per question id, or
  `{:error, %ALLM.Error.ClassificationAdapterError{}}` on every failure shape.
  See `ALLM.Error.ClassificationAdapterError` for the closed reason enum.
  """
  @callback classify(ALLM.ClassificationRequest.t(), keyword()) ::
              {:ok, ALLM.ClassificationResponse.t()}
              | {:error, ALLM.Error.ClassificationAdapterError.t()}

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the caller
  can further customize (headers, retries, middleware) before firing.

  Optional. When unimplemented, callers dispatch to `classify/2` directly.
  Per invariant 9 the returned request must be configured exactly as
  `classify/2` would fire it.
  """
  @callback prepare_request(ALLM.ClassificationRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ClassificationAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
