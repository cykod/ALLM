defmodule ALLM.TranscriptionAdapter do
  @moduledoc """
  Speech-to-text provider adapter contract.

  Layer B — runtime. Implementations take an `ALLM.TranscriptionRequest`
  plus a keyword opts list and return either
  `{:ok, %ALLM.TranscriptionResponse{}}` or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}`. An engine carries its
  transcription adapter in the `:transcription_adapter` slot, independently
  of the chat `:adapter` and of `:speech_adapter`.

  ## Minimum impl skeleton

      defmodule MyTranscriptionProvider do
        @behaviour ALLM.TranscriptionAdapter

        alias ALLM.Error.TranscriptionAdapterError

        @impl true
        def max_audio_bytes, do: 25 * 1024 * 1024

        @impl true
        def transcribe(%ALLM.TranscriptionRequest{audio: audio} = request, opts) do
          # Invariants 3 and 4, in this order, before any I/O and before
          # ALLM.Keys.fetch!/2.
          max = max_audio_bytes()

          case ALLM.Audio.size(audio) do
            {:error, cause} ->
              {:error,
               TranscriptionAdapterError.new(:invalid_request, metadata: %{cause: cause})}

            {:ok, count} when count > max ->
              {:error,
               TranscriptionAdapterError.new(:invalid_request,
                 metadata: %{count: count, max: max}
               )}

            {:ok, _count} ->
              # Resolve the key, upload the audio via Req, decode the text.
              {:ok,
               %ALLM.TranscriptionResponse{
                 text: "...",
                 request_id: Keyword.get(opts, :request_id),
                 metadata: request.metadata
               }}
          end
        end
      end

  ## Gate order

  Every transcription adapter runs its gates in one fixed order, all before
  `ALLM.Keys.fetch!/2`: **resolvable** (invariant 3) → **size**
  (invariant 4) → **MIME** (adapter-specific) → key resolution. MIME
  acceptance is not a behaviour invariant, because the accepted set differs
  per provider; each adapter gates its own and documents it.

  `ALLM.Audio.size/1` is the byte resolver for the first two gates. It stats
  a `{:file, path}` source without reading it.

  ## Invariants

    1. `transcribe/2` returns exactly `{:ok, %ALLM.TranscriptionResponse{}}`
       or `{:error, %ALLM.Error.TranscriptionAdapterError{}}` — never a bare
       struct, never a three-tuple. The one documented exception is
       `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design. The
       transcription façade enforces this by raising `ArgumentError` on any
       other shape, so the conformance suite cannot observe it.
    2. On success, `response.text` is a binary (possibly `""` for silence),
       and `response.usage` is an `%ALLM.Usage{}`, never `nil`.
    3. Audio whose bytes cannot be resolved (a missing file, invalid base64,
       an off-shape source) is rejected with `:invalid_request` and a
       `metadata.cause` naming why, **before any I/O and before
       `ALLM.Keys.fetch!/2`**.
    4. Audio larger than `max_audio_bytes/0` is rejected with
       `:invalid_request`, `metadata.count` (the byte count) and
       `metadata.max`, under the same ordering.
    5. `max_audio_bytes/0` returns a `pos_integer()`.
    6. `opts[:request_id]` is reflected onto `response.request_id` when
       supplied.
    7. `request.metadata` round-trips onto `response.metadata` unchanged.
    8. `opts[:request_timeout]` is honoured; expiry produces
       `{:error, %ALLM.Error.TranscriptionAdapterError{reason: :timeout}}`.
       When absent, the adapter applies its own default and documents it in
       its `transcribe/2` `@doc`.
    9. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `transcribe/2` would fire it, and is defined
       only for audio that passes invariants 3 and 4.

  **Cleanup invariant: none.** `Req.request/1` owns its connection
  lifecycle.
  """

  @doc """
  Transcribe an audio clip.

  Returns `{:ok, %ALLM.TranscriptionResponse{}}` on success, or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}` on every failure shape.
  See `ALLM.Error.TranscriptionAdapterError` for the closed reason enum.
  """
  @callback transcribe(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, ALLM.TranscriptionResponse.t()}
              | {:error, ALLM.Error.TranscriptionAdapterError.t()}

  @doc """
  Return the largest audio payload, in bytes, the adapter accepts in one
  request.

  Per-module, one number for the adapter. It is the cap the size gate
  (invariant 4) measures against, and what a caller checks a file against
  before uploading it.
  """
  @callback max_audio_bytes() :: pos_integer()

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the caller
  can further customize before firing.

  Optional. Per invariant 9 it is defined only for audio that passes the
  resolvable and size gates.
  """
  @callback prepare_request(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.TranscriptionAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
