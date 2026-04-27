defmodule ALLM.ImageAdapter do
  @moduledoc """
  Image-generation provider adapter contract. See spec §35.3.

  Layer B — runtime. Implementations take an `ALLM.ImageRequest` plus a
  keyword opts list (resolved at the call site by `ALLM.generate_image/3`
  in Phase 14.2) and return either `{:ok, %ALLM.ImageResponse{}}` or
  `{:error, %ALLM.Error.ImageAdapterError{}}`.

  ## HTTP transport guidance

  Use `Req` for non-streaming image calls. Image generation is a
  request/response shape — there is no streaming counterpart in v0.3
  (per phasing principle #2).

  ## Invariants

    1. `generate/2` is synchronous: it returns only after the HTTP response
       has been read in full and any binary image bytes resolved.
    2. `generate/2` never raises for HTTP-shaped failures. Network failures,
       4xx, and 5xx all convert to
       `{:error, %ALLM.Error.ImageAdapterError{reason: ..., ...}}`. Only
       programmer errors (invalid request shape reaching the adapter, which
       the validator should have caught) may raise.
    3. `generate/2` MUST honor `opts[:request_timeout]` if provided.
       Exceeding the timeout produces
       `{:error, %ImageAdapterError{reason: :timeout}}`.
    4. `generate/2` MUST return
       `{:error, %ImageAdapterError{reason: :unsupported_operation,
       metadata: %{operation: op}}}` BEFORE any HTTP I/O when
       `request.operation not in supported_operations()`. This is the
       entry-point gate; per-model gating (e.g., dall-e-3 only supports
       `:generate`) is the adapter's internal concern.
    5. `generate/2` MUST preserve `opts[:request_id]` onto
       `response.request_id` when the response shape allows. When
       `opts[:request_id]` is absent, the adapter is free to populate
       `response.request_id` from a provider-supplied id (e.g.,
       `x-request-id` HTTP header).
    6. `generate/2` MUST round-trip `request.metadata` onto
       `response.metadata` UNCHANGED when the adapter has no use for it.
       (§35.2.2/§35.2.3 metadata invariant — opaque to the library.)
    7. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `generate/2` would fire it. Callers may
       mutate the returned request before firing.
  """

  @doc """
  Execute an image request against the provider synchronously.

  Returns `{:ok, %ALLM.ImageResponse{}}` on success, or
  `{:error, %ALLM.Error.ImageAdapterError{}}` on every failure shape.
  See `ALLM.Error.ImageAdapterError` for the closed reason enum and the
  per-reason recovery table.
  """
  @callback generate(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, ALLM.ImageResponse.t()} | {:error, ALLM.Error.ImageAdapterError.t()}

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the
  caller can further customize (headers, retries, middleware) before
  firing.

  Optional. When unimplemented, callers must dispatch to `generate/2`
  directly.
  """
  @callback prepare_request(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ImageAdapterError.t()}

  @doc """
  Return the closed list of operations the adapter can perform.

  Per-module (one list for the adapter), NOT per-call-with-model-arg —
  per-Phase 14.1 Decision #3. Per-model gating (e.g., `dall-e-3` is
  generate-only while `gpt-image-1` does generate+edit) is the adapter's
  internal concern, asserted separately in the adapter's own tests.

  The conformance suite asserts that requests whose `:operation` is not
  in this list are rejected with
  `{:error, %ALLM.Error.ImageAdapterError{reason: :unsupported_operation,
  metadata: %{operation: op}}}` BEFORE any HTTP I/O.
  """
  @callback supported_operations() :: [ALLM.ImageRequest.operation()]

  @optional_callbacks prepare_request: 2
end
