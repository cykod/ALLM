defmodule ALLM.TranscriptionStreamAdapter do
  @moduledoc """
  Realtime speech-to-text contract: transcripts arrive while audio is still
  being sent.

  Layer B — runtime. A transcription adapter opts into streaming by
  implementing this behaviour **in addition to** `ALLM.TranscriptionAdapter`,
  in the same module. There is no separate engine slot: the engine's
  `:transcription_adapter` is checked with `function_exported?/3`.

  `c:stream_transcribe/3` takes an `ALLM.TranscriptionStreamRequest` (the
  session configuration) and an enumerable of audio chunks, and returns
  `{:ok, enumerable}` of `ALLM.TranscriptionEvent` values obeying the
  grammar stated in `ALLM.TranscriptionEvent`.

  ## Input elements

  Each element of the audio enumerable is either:

    * a binary of PCM16 little-endian mono samples at `request.sample_rate`,
      or
    * `:commit`, which forces the current segment to be committed under
      either commit strategy.

  ## Minimum impl skeleton

      defmodule MyRealtimeTranscription do
        @behaviour ALLM.TranscriptionAdapter
        @behaviour ALLM.TranscriptionStreamAdapter

        alias ALLM.Error.TranscriptionAdapterError

        @impl ALLM.TranscriptionAdapter
        def max_audio_bytes, do: 25 * 1024 * 1024

        @impl ALLM.TranscriptionAdapter
        def transcribe(request, opts), do: MyProvider.transcribe(request, opts)

        @impl ALLM.TranscriptionStreamAdapter
        def stream_sample_rates, do: [16_000]

        @impl ALLM.TranscriptionStreamAdapter
        def stream_transcribe(%ALLM.TranscriptionStreamRequest{} = request, audio, opts) do
          if request.sample_rate in stream_sample_rates() do
            key = ALLM.Keys.fetch!(:my_provider, opts)
            {:ok, MyProvider.realtime_stream(request, audio, key)}
          else
            # Invariant 2: before ALLM.Keys.fetch!/2.
            {:error,
             TranscriptionAdapterError.new(:invalid_request,
               metadata: %{sample_rate: request.sample_rate}
             )}
          end
        end
      end

  ## Invariants

    1. The synchronous return is exactly `{:ok, enumerable}` or
       `{:error, %ALLM.Error.TranscriptionAdapterError{}}`. The one
       documented exception is `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design.
    2. **Lazy.** No I/O happens until the enumerable is reduced. Pre-flight
       gates run synchronously **before `ALLM.Keys.fetch!/2`**. The
       per-adapter gate is `request.sample_rate in stream_sample_rates()`,
       else `:invalid_request` with `metadata.sample_rate`.
    3. The enumerable obeys the `ALLM.TranscriptionEvent` grammar: one
       `:transcription_started`, then partial and committed transcripts,
       then one `:transcription_completed`; or a failure ending in one
       `{:error, _}`. Nothing follows a terminal event.
    4. **Cleanup: halt-safe.** A consumer halt releases the transport and
       stops the input pump within 500 ms, and leaves no stream-owned
       message in the consumer's mailbox. The input's own resources are
       released by process exit, not by its after functions.
    5. `opts[:stream_timeout]` (milliseconds of silence, default 60,000) is
       honoured. The timer resets on every transport message **and** every
       input-pump message. Expiry ends the stream with
       `{:error, %ALLM.Error.TranscriptionAdapterError{reason: :timeout}}`.
    6. `opts[:request_id]` appears on `:transcription_started` and
       `:transcription_completed`. `request.metadata` appears unchanged on
       `:transcription_completed`'s `:metadata`.
    7. **Input.** An element that is neither a binary nor `:commit`, or an
       input that raises or crashes, ends the stream with
       `:invalid_request` and `metadata.cause` one of
       `:invalid_input_chunk`, `:input_raised` or `:input_crashed`. For the
       last two, the error's `:cause` field is a
       `%{kind: kind, message: message}` map (`kind` is `:error`, `:throw`
       or `:exit`, `message` a string), and the consuming process is
       never killed. **Chunk boundaries are the caller's, not the
       protocol's:** a chunk may split a 16-bit sample, and the adapter
       carries the odd byte into the next chunk. An input whose total
       length is odd ends the stream with `:invalid_input_chunk` at end of
       input; an odd-length chunk followed by one that completes the
       sample is not an error. The audio the provider receives, in order,
       equals the concatenated input.
    8. **End of input.** When the input is exhausted, the adapter commits
       any uncommitted audio and waits up to `:stream_timeout` for the
       final `:committed_transcript`, then emits `:transcription_completed`
       and closes.

  `:transcription_completed`'s `:text` is the committed segments, each
  trimmed, empties dropped, joined with one space. Its `:duration_seconds`
  is computed from the bytes sent, `bytes / (sample_rate * 2)`.

  ## Input is reduced in another process

  An adapter reduces the audio enumerable through
  `ALLM.Providers.Support.InputPump`, so the input runs in a helper
  process. An input that reads the caller's mailbox, such as a microphone
  relay built on `receive`, must be relayed from a process the caller
  controls.
  """

  @typedoc "One element of the audio enumerable fed to `c:stream_transcribe/3`."
  @type audio_chunk :: binary() | :commit

  @doc """
  Transcribe an enumerable of audio chunks as they arrive.

  Returns `{:ok, enumerable}` of `ALLM.TranscriptionEvent` values, or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}` from a pre-flight gate.
  """
  @callback stream_transcribe(
              ALLM.TranscriptionStreamRequest.t(),
              Enumerable.t(audio_chunk()),
              keyword()
            ) ::
              {:ok, Enumerable.t(ALLM.TranscriptionEvent.t())}
              | {:error, ALLM.Error.TranscriptionAdapterError.t()}

  @doc """
  Return the PCM sample rates, in Hz, `c:stream_transcribe/3` accepts.

  A caller checks it before opening a microphone, as it checks
  `c:ALLM.TranscriptionAdapter.max_audio_bytes/0` before uploading a file.
  """
  @callback stream_sample_rates() :: [pos_integer()]
end
