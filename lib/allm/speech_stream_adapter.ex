defmodule ALLM.SpeechStreamAdapter do
  @moduledoc """
  Streaming text-to-speech contract: audio arrives as it is synthesized.

  Layer B — runtime. A speech adapter opts into streaming by implementing
  this behaviour **in addition to** `ALLM.SpeechAdapter`, in the same module.
  There is no separate engine slot: the engine's `:speech_adapter` is
  checked with `function_exported?/3`, the same way the chat `:adapter` is
  checked for `c:ALLM.StreamAdapter.stream/2`. A slot adapter that does not
  export the callback cannot stream.

  Two callbacks, one per input shape:

    * `c:stream_synthesize/2` — the whole text is known up front, the audio
      streams back.
    * `c:stream_synthesize_input/3` (optional) — the text itself arrives as
      an enumerable of chunks, for example the text deltas of a chat stream,
      and audio streams back while text is still arriving.

  Each returns `{:ok, enumerable}` of `ALLM.SpeechEvent` values. The
  enumerable obeys the grammar stated in `ALLM.SpeechEvent`.

  ## Minimum impl skeleton

      defmodule MyStreamingSpeech do
        @behaviour ALLM.SpeechAdapter
        @behaviour ALLM.SpeechStreamAdapter

        alias ALLM.Error.SpeechAdapterError
        alias ALLM.SpeechEvent

        @impl ALLM.SpeechAdapter
        def synthesize(request, opts), do: MyProvider.synthesize(request, opts)

        @impl ALLM.SpeechStreamAdapter
        def stream_synthesize(%ALLM.SpeechRequest{input: ""}, _opts) do
          # Invariant 2: gates run before ALLM.Keys.fetch!/2 and before the
          # enumerable is returned.
          {:error, SpeechAdapterError.new(:invalid_request)}
        end

        def stream_synthesize(%ALLM.SpeechRequest{} = request, opts) do
          key = ALLM.Keys.fetch!(:my_provider, opts)

          stream =
            Stream.resource(
              fn -> MyProvider.open(request, key) end,
              fn conn -> MyProvider.next_events(conn) end,
              # Invariant 4: release the transport, drain its messages.
              fn conn -> MyProvider.close(conn) end
            )

          {:ok, stream}
        end
      end

  ## Invariants

    1. The synchronous return is exactly `{:ok, enumerable}` or
       `{:error, %ALLM.Error.SpeechAdapterError{}}`. The one documented
       exception is `ALLM.Keys.fetch!/2`, which raises
       `%ALLM.Error.EngineError{reason: :missing_key}` by design.
    2. **Lazy.** No I/O happens until the enumerable is reduced. Pre-flight
       gates run synchronously and return `{:error, _}` **before
       `ALLM.Keys.fetch!/2`**: for `c:stream_synthesize/2` the empty-input
       gate, then per-adapter gates; for `c:stream_synthesize_input/3` the
       request shape checks of
       `ALLM.Validate.speech_request(request, input: :streamed)`, then
       per-adapter gates. A keyless environment therefore observes the
       rejection, not a missing-key raise.
    3. The enumerable obeys the `ALLM.SpeechEvent` grammar: one
       `:speech_started`, one or more `:audio_delta`, one
       `:speech_completed`; or a failure ending in one `{:error, _}`.
       Nothing follows a terminal event. A stream that reaches its end with
       zero audio bytes, including a `c:stream_synthesize_input/3` input
       that yields no non-empty chunk, ends with `:invalid_request` and
       `metadata.cause: :empty_input`.
    4. **Cleanup: halt-safe.** A consumer halt (`Enum.take/2`) releases the
       transport (the HTTP request is cancelled, or the WebSocket is closed
       and the input pump stopped) within 500 ms. The after function stops
       the pump with `ALLM.Providers.Support.InputPump.stop/2` and drains
       the transport's messages. On a WebSocket or input-pump path no
       stream-owned message is left in the consumer's mailbox. On an HTTP
       path the drain is best-effort: messages already queued at the halt
       are removed, but the HTTP client cancels asynchronously, so one late
       message from the cancelled request can still arrive afterwards. The
       input's own resources are released by process exit, not by its
       after functions.
    5. `opts[:stream_timeout]` (milliseconds of silence, default 60,000) is
       honoured. The timer resets on every transport message **and** every
       input-pump message, so a slow input does not time out a socket whose
       server is waiting for text, and a silent server does not time out
       while input still flows. Expiry ends the stream with
       `{:error, %ALLM.Error.SpeechAdapterError{reason: :timeout}}`.
    6. `opts[:request_id]` appears on `:speech_started` and
       `:speech_completed`. `request.metadata` appears unchanged on
       `:speech_completed`'s `:metadata`.
    7. **Input chunks** (`c:stream_synthesize_input/3`). A non-binary or
       non-UTF-8 element ends the stream with `:invalid_request` and
       `metadata.cause: :invalid_input_chunk`. An empty string element is
       skipped. An input that raises, throws or exits ends the stream with
       `:invalid_request` and `metadata.cause: :input_raised`; an input
       whose reducing process dies from an exit signal ends it with
       `metadata.cause: :input_crashed`. In both cases the error's `:cause`
       field is a `%{kind: kind, message: message}` map (`kind` is
       `:error`, `:throw` or `:exit`, `message` a string), never the raw
       exception or exit term, and the consuming process is never
       killed.
    8. Concatenating every `:audio_delta` payload gives non-empty audio,
       and the `:mime_type` on `:speech_started` begins `audio/`.
    9. **Ordering of I/O.** Key resolution runs synchronously, after the
       gates and before the enumerable is returned. A transport that must
       be opened before input flows (a WebSocket) is opened in the
       enumerable's start function, and the input is only reduced after
       the connection is established, so a failed connection never
       consumes the input.

  ## Input is reduced in another process

  An adapter reduces the input of `c:stream_synthesize_input/3` through
  `ALLM.Providers.Support.InputPump`, so the input runs in a helper
  process. An input that depends on the caller's mailbox or process
  dictionary must be relayed.

  ## Backpressure

  Transport messages arrive in the consumer's mailbox at the provider's
  generation rate, as on the chat streaming path; a slow consumer grows
  its mailbox. On the input side the pump's credit window (default 8,
  `adapter_opts[:input_window]`) bounds how much unsent input waits in
  the consumer's mailbox.
  """

  @typedoc "One chunk of text fed to `c:stream_synthesize_input/3`."
  @type text_chunk :: String.t()

  @doc """
  Stream the synthesis of `request.input`.

  Returns `{:ok, enumerable}` of `ALLM.SpeechEvent` values, or
  `{:error, %ALLM.Error.SpeechAdapterError{}}` from a pre-flight gate.
  """
  @callback stream_synthesize(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, Enumerable.t(ALLM.SpeechEvent.t())}
              | {:error, ALLM.Error.SpeechAdapterError.t()}

  @doc """
  Stream the synthesis of text that itself arrives as an enumerable of
  chunks. `request.input` is ignored.

  Optional. Returns `{:ok, enumerable}` of `ALLM.SpeechEvent` values, or
  `{:error, %ALLM.Error.SpeechAdapterError{}}` from a pre-flight gate.
  """
  @callback stream_synthesize_input(ALLM.SpeechRequest.t(), Enumerable.t(text_chunk()), keyword()) ::
              {:ok, Enumerable.t(ALLM.SpeechEvent.t())}
              | {:error, ALLM.Error.SpeechAdapterError.t()}

  @optional_callbacks stream_synthesize_input: 3
end
