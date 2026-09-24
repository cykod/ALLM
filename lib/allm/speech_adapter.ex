defmodule ALLM.SpeechAdapter do
  @moduledoc """
  Text-to-speech provider adapter contract.

  Layer B — runtime. Implementations take an `ALLM.SpeechRequest` plus a
  keyword opts list and return either `{:ok, %ALLM.SpeechResponse{}}` or
  `{:error, %ALLM.Error.SpeechAdapterError{}}`. An engine carries its speech
  adapter in the `:speech_adapter` slot, independently of the chat
  `:adapter` and of `:transcription_adapter`, so one engine can pair
  providers per capability.

  ## Minimum impl skeleton

      defmodule MySpeechProvider do
        @behaviour ALLM.SpeechAdapter

        @impl true
        def synthesize(%ALLM.SpeechRequest{input: ""}, _opts) do
          # Invariant 4: before any I/O and before ALLM.Keys.fetch!/2.
          {:error, ALLM.Error.SpeechAdapterError.new(:invalid_request)}
        end

        def synthesize(%ALLM.SpeechRequest{} = request, opts) do
          # Resolve the key, translate request -> HTTP body, fire via Req,
          # then wrap the returned bytes:
          audio = ALLM.Audio.from_binary(<<"...">>, "audio/mpeg")

          {:ok,
           %ALLM.SpeechResponse{
             audio: audio,
             format: ALLM.SpeechResponse.mime_to_format(audio.mime_type),
             request_id: Keyword.get(opts, :request_id),
             metadata: request.metadata
           }}
        end
      end

  ## HTTP transport guidance

  Use `Req`. Speech synthesis here is request/response: the response body is
  the finished audio file, and there is no streaming counterpart.

  ## Invariants

    1. `synthesize/2` returns exactly `{:ok, %ALLM.SpeechResponse{}}` or
       `{:error, %ALLM.Error.SpeechAdapterError{}}` — never a bare struct,
       never a three-tuple. Network failures, 4xx, and 5xx all convert to the
       error tuple. The one documented exception is `ALLM.Keys.fetch!/2`,
       which raises `%ALLM.Error.EngineError{reason: :missing_key}` by
       design; adapters do not rescue it. The speech façade enforces this
       by raising `ArgumentError` on any other shape, so the conformance
       suite cannot observe it.
    2. On success, `response.audio` is an
       `%ALLM.Audio{source: {:binary, bytes}}` with `byte_size(bytes) > 0`
       and a binary `:mime_type` beginning `audio/`. A successful HTTP
       response whose payload is not audio is `:malformed_response`.
    3. `response.format` is `nil` or a member of
       `ALLM.SpeechRequest.formats/0`. Derive it from the response content
       type with `ALLM.SpeechResponse.mime_to_format/1` rather than echoing
       the request.
    4. Empty input (`""`) is rejected with `:invalid_request` **before any
       I/O and before `ALLM.Keys.fetch!/2`**, so a keyless environment
       observes the rejection rather than
       `%ALLM.Error.EngineError{reason: :missing_key}`.
    5. `opts[:request_id]` is reflected onto `response.request_id` when
       supplied. When absent, the adapter may populate it from a
       provider-supplied correlation id.
    6. `request.metadata` round-trips onto `response.metadata` unchanged.
    7. `opts[:request_timeout]` is honoured; expiry produces
       `{:error, %ALLM.Error.SpeechAdapterError{reason: :timeout}}`. When
       absent, the adapter applies its own default and documents it in its
       `synthesize/2` `@doc`.
    8. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `synthesize/2` would fire it.

  Audio bytes live once, in `response.audio`. An adapter never copies them
  into `response.raw`.

  **Cleanup invariant: none.** There is no `Stream.resource/3` and no Finch
  ref in a speech call — `Req.request/1` owns its connection lifecycle.
  Stated explicitly so the absence reads as intent rather than omission.
  """

  @doc """
  Synthesize speech for a request.

  Returns `{:ok, %ALLM.SpeechResponse{}}` on success, or
  `{:error, %ALLM.Error.SpeechAdapterError{}}` on every failure shape. See
  `ALLM.Error.SpeechAdapterError` for the closed reason enum.
  """
  @callback synthesize(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, ALLM.SpeechResponse.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the caller
  can further customize before firing.

  Optional. When unimplemented, callers dispatch to `synthesize/2` directly.
  Per invariant 8 the returned request must be configured exactly as
  `synthesize/2` would fire it.
  """
  @callback prepare_request(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
