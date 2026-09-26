defmodule ALLM.Providers.FakeSpeech do
  @moduledoc """
  Deterministic, scripted adapter for text-to-speech testing. Implements
  `ALLM.SpeechAdapter` and `ALLM.SpeechStreamAdapter`, including the
  optional input-streaming callback.

  Layer B — runtime. FakeSpeech is the canonical testing speech adapter; it
  ships in `lib/` (not `test/support/`) because users need it for their own
  application tests, mirroring `ALLM.Providers.Fake`,
  `ALLM.Providers.FakeImages`, `ALLM.Providers.FakeEmbeddings` and
  `ALLM.Providers.FakeModeration`.

  ## What FakeSpeech is (and isn't)

  FakeSpeech produces no real audio. It inspects `:input` to enforce the
  empty-input gate every `ALLM.SpeechAdapter` must run, reads `:format` to
  pick the MIME type, and reads `:model` and `:metadata` to round-trip them
  onto the response.

  ## Default audio (no script)

  With **no script** — `adapter_opts[:speech_script]` absent or `[]` — the
  audio bytes are the deterministic `"FAKE-AUDIO:" <> input`, so two
  different inputs produce two different payloads. The response `:format` is
  `request.format || :mp3`, and the MIME type comes from
  `ALLM.SpeechResponse.format_to_mime/1`.

  ## Spent script

  A **non-empty** script whose cursor has run off the end does NOT fall back
  to the default audio — it returns

      {:error, %ALLM.Error.SpeechAdapterError{
         reason: :unknown,
         metadata: %{cause: :speech_script_exhausted}}}

  A spent script is almost always an off-by-one in the caller's expectation
  of how many times `synthesize/2` gets invoked, and a test vehicle that
  answers it with default audio hides that bug.

  ## Script shapes

  `opts[:adapter_opts][:speech_script]` accepts a list of script entries.
  See `script/1` for the full grammar.

      adapter_opts: [
        speech_script: [
          {:ok, <<"ID3...">>},
          {:ok, %ALLM.SpeechResponse{...}},
          {:error, %ALLM.Error.SpeechAdapterError{reason: :rate_limited}},
          {:retry_until_call, 3}
        ]
      ]

  `{:retry_until_call, n}` returns a synthetic
  `%ALLM.Error.SpeechAdapterError{reason: :rate_limited, retry_after_ms: 0}`
  for the first `n - 1` calls against this entry, then advances the cursor to
  the next entry on call `n`. Consecutive `{:retry_until_call, _}` entries
  **chain** into a layered budget.

  | Entry | `synthesize/2` | `stream_synthesize/2` and `stream_synthesize_input/3` |
  |-------|----------------|--------------------------------------------------------|
  | `{:ok, bytes}` | `bytes` as the audio | `:speech_started`, `bytes` in `adapter_opts[:chunk_bytes]` pieces (default 1,024), `:speech_completed`. The input form consumes all input first |
  | `{:ok, %SpeechResponse{}}` | the struct | the struct's fields and audio as events |
  | `{:error, err}` | `{:error, err}` | `:speech_started`, then `{:error, err}` |
  | `{:events, events}` | `:unknown` with `metadata.cause: :stream_only_script_entry` | `events`, verbatim (how a mid-stream error is scripted) |
  | `{:retry_until_call, n}` | `:rate_limited` error | a stream whose only event is a `:rate_limited` error |
  | absent or `[]` script | `"FAKE-AUDIO:" <> input` | the same audio; the input form emits `"FAKE-AUDIO:" <> chunk` per non-empty chunk |

  ## Streaming

  A stream callback resolves its script entry and advances the cursor **at
  call time**, before it returns `{:ok, stream}`, so two stream calls
  consume two entries even if neither stream is reduced, and a halted
  stream never replays its entry. Streams are never retried, so on a
  stream path `{:retry_until_call, n}` returns a stream holding only the
  rate-limit error while the entry's visit counter is below `n`; the
  counter is shared with `synthesize/2`.

  `stream_synthesize_input/3` reduces its input through
  `ALLM.Providers.Support.InputPump`, in another process, exactly as a real
  adapter does, so an input that reads the calling process's mailbox fails
  under the Fake the same way it would in production.

  ## Cursor behaviour

  Multi-call scripts advance a per-process cursor on every call. The cursor
  lives in the process dictionary at `{:allm_fake_speech_cursor, key_id}`,
  isolated per ExUnit test process (`async: true`), GC'd on pid-down,
  zero-setup for the common case. The `key_id` is chosen by this precedence:

    1. `adapter_opts[:script_cursor]` — an explicit Agent pid (handled
       separately; see `start_script_cursor/0`).
    2. `adapter_opts[:cursor_key]` — the engine's stable `:id`, injected by
       the façade dispatch chokepoint via `ALLM.Engine.put_cursor_key/2`.
    3. `:erlang.phash2(script)` — the content-hash fallback for direct
       adapter calls with no engine.

  At the façade the cursor keys on engine identity, so two engines built with
  content-equal `:speech_script` values each read index 0 on their first
  call, even in the same process. **The content-hash footgun remains only for
  DIRECT adapter calls** — `ALLM.Providers.FakeSpeech.synthesize(req, opts)`
  invoked without an engine receives no `:cursor_key`. Workaround for that
  path: pass distinct `adapter_opts[:script_cursor]` Agent pids from
  `start_script_cursor/0`. The `{:retry_until_call, n}` visit counter keys on
  the same identity, so content-equal engines never share a retry budget.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `synthesize/2`, `stream_synthesize/2` or
  `stream_synthesize_input/3` is invoked, BEFORE any gate runs and before
  the script is consulted:

      {ALLM.Providers.FakeSpeech, :call, %{request: request, opts: opts}}

  It does NOT affect the response.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.", format: :wav)
      iex> {:ok, resp} = ALLM.Providers.FakeSpeech.synthesize(req, [])
      iex> {ALLM.Audio.to_binary(resp.audio), resp.audio.mime_type, resp.format}
      {{:ok, "FAKE-AUDIO:Hello."}, "audio/wav", :wav}
  """

  @behaviour ALLM.SpeechAdapter
  @behaviour ALLM.SpeechStreamAdapter

  alias ALLM.{Audio, SpeechEvent, SpeechRequest, SpeechResponse, Usage, Validate}
  alias ALLM.Error.{SpeechAdapterError, ValidationError}
  alias ALLM.Providers.Support.InputPump

  require InputPump

  @default_format :mp3
  @chunk_bytes 1024
  @stream_timeout 60_000

  # ---------------------------------------------------------------------------
  # ALLM.SpeechAdapter — synthesize/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted speech request.

  Gate order, all before the script is consulted:

    1. `adapter_opts[:capture_pid]` side-channel (fires even for rejected
       calls).
    2. `input` empty or not a binary →
       `{:error, %SpeechAdapterError{reason: :invalid_request}}`.

  Otherwise reads the script from `opts[:adapter_opts][:speech_script]`,
  advances the process-local cursor, and interprets the entry. An **absent**
  script produces the default audio; a **spent non-empty** script returns
  `:speech_script_exhausted`. Both are described in the module docs.

  Propagates `opts[:request_id]` onto `response.request_id`, `request.model`
  onto `response.model`, `request.sample_rate` onto `response.sample_rate`,
  `request.metadata` onto `response.metadata`, and stamps `provider: :fake`. `{:ok, %SpeechResponse{}}` script entries are
  returned verbatim.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", metadata: %{trace: "t1"})
      iex> {:ok, resp} = ALLM.Providers.FakeSpeech.synthesize(req, request_id: "rid-1")
      iex> {resp.request_id, resp.metadata, resp.provider}
      {"rid-1", %{trace: "t1"}, :fake}

      iex> {:error, err} = ALLM.Providers.FakeSpeech.synthesize(ALLM.SpeechRequest.new(input: ""), [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.SpeechAdapter
  @spec synthesize(SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    with :ok <- gate(request) do
      case resolve_script(opts) do
        :default -> {:ok, build_response(nil, request, opts)}
        :exhausted -> {:error, exhausted_error()}
        :retry -> {:error, retry_error()}
        {:entry, entry} -> interpret_entry(entry, request, opts)
      end
    end
  end

  # Contract invariant 4 — fires before any script consult, so a direct
  # caller sees the same rejection a real adapter produces before its first
  # byte of I/O and before it resolves a key.
  defp gate(%SpeechRequest{input: input}) when is_binary(input) and input != "", do: :ok

  defp gate(%SpeechRequest{}) do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       message: "input must be a non-empty string",
       metadata: %{field: :input}
     )}
  end

  # ---------------------------------------------------------------------------
  # ALLM.SpeechStreamAdapter — stream_synthesize/2
  # ---------------------------------------------------------------------------

  @doc """
  Stream a scripted speech request as `ALLM.SpeechEvent` values.

  Runs the same gates as `synthesize/2`, then resolves and advances the
  script **at call time**, before the stream is returned, so two calls
  consume two entries even if neither stream is reduced. The events are:

    * absent script or `{:ok, bytes}` — `:speech_started`, the bytes split
      into `adapter_opts[:chunk_bytes]` pieces (default #{@chunk_bytes}) as
      `:audio_delta` events, then `:speech_completed`. The default bytes
      are `"FAKE-AUDIO:" <> input`.
    * `{:ok, %SpeechResponse{}}` — `:speech_started` built from the
      struct, its audio bytes as `:audio_delta` events, then
      `:speech_completed`. Zero-byte audio ends with `:invalid_request` and
      `metadata.cause: :empty_input`, as `{:ok, ""}` does. Audio that cannot
      be read (`nil`, or a missing file) ends with `:unknown` and
      `metadata.cause: :unreadable_script_audio`.
    * `{:error, err}` — `:speech_started`, then `{:error, err}`.
    * `{:events, events}` — `events`, verbatim.
    * inside a `{:retry_until_call, n}` budget — a stream whose only event
      is a `:rate_limited` error. Streams are never retried, so the next
      call is the next visit.
    * a spent non-empty script — the synchronous
      `:speech_script_exhausted` error.

  `:speech_started` carries `format: request.format || :mp3`, its MIME type,
  and `sample_rate: request.sample_rate`.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", format: :pcm, sample_rate: 24_000)
      iex> opts = [adapter_opts: [speech_script: [{:ok, "abcdef"}], chunk_bytes: 4]]
      iex> {:ok, events} = ALLM.Providers.FakeSpeech.stream_synthesize(req, opts)
      iex> for {:audio_delta, bytes} <- events, do: bytes
      ["abcd", "ef"]
  """
  @impl ALLM.SpeechStreamAdapter
  @spec stream_synthesize(SpeechRequest.t(), keyword()) ::
          {:ok, Enumerable.t(SpeechEvent.t())} | {:error, SpeechAdapterError.t()}
  def stream_synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    with :ok <- gate(request) do
      case resolve_script(opts) do
        :exhausted -> {:error, exhausted_error()}
        :retry -> {:ok, [{:error, retry_error()}]}
        :default -> {:ok, audio_events("FAKE-AUDIO:" <> request.input, request, opts)}
        {:entry, entry} -> {:ok, stream_entry_events(entry, request, opts)}
      end
    end
  end

  defp stream_entry_events({:ok, %SpeechResponse{} = response}, request, opts) do
    case response_bytes(response) do
      {:ok, bytes} ->
        started =
          SpeechEvent.speech_started(%{
            request_id: Keyword.get(opts, :request_id, response.request_id),
            model: response.model,
            provider: response.provider,
            format: response.format,
            mime_type: response.audio.mime_type,
            sample_rate: response.sample_rate
          })

        completed =
          SpeechEvent.speech_completed(%{
            request_id: Keyword.get(opts, :request_id, response.request_id),
            id: response.id,
            usage: response.usage,
            metadata: response.metadata
          })

        [started | body_events(bytes, completed, opts)]

      :error ->
        [started_event(request, opts), unreadable_audio_error()]
    end
  end

  defp stream_entry_events({:ok, bytes}, request, opts) when is_binary(bytes),
    do: audio_events(bytes, request, opts)

  defp stream_entry_events({:error, %SpeechAdapterError{} = err}, request, opts),
    do: [started_event(request, opts), {:error, err}]

  defp stream_entry_events({:events, events}, _request, _opts) when is_list(events), do: events

  defp response_bytes(%SpeechResponse{audio: %Audio{} = audio}) do
    case Audio.to_binary(audio) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> :error
    end
  end

  defp response_bytes(%SpeechResponse{}), do: :error

  defp audio_events(bytes, request, opts),
    do: [started_event(request, opts) | body_events(bytes, completed_event(request, opts), opts)]

  # Everything after `:speech_started`: the deltas and `completed`, or the
  # `:empty_input` terminal when there are no bytes (invariant 3). Every
  # bytes-to-events path goes through here.
  defp body_events("", _completed, _opts), do: [empty_input_error()]
  defp body_events(bytes, completed, opts), do: chunk_deltas(bytes, opts) ++ [completed]

  defp chunk_deltas(bytes, opts) do
    size = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:chunk_bytes, @chunk_bytes)
    for chunk <- split_bytes(bytes, size, []), do: SpeechEvent.audio_delta(chunk)
  end

  defp split_bytes(bytes, size, acc) when byte_size(bytes) > size do
    <<chunk::binary-size(size), rest::binary>> = bytes
    split_bytes(rest, size, [chunk | acc])
  end

  defp split_bytes("", _size, acc), do: Enum.reverse(acc)
  defp split_bytes(bytes, _size, acc), do: Enum.reverse([bytes | acc])

  defp started_event(%SpeechRequest{} = request, opts) do
    format = request.format || @default_format

    SpeechEvent.speech_started(%{
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :fake,
      format: format,
      mime_type: SpeechResponse.format_to_mime(format),
      sample_rate: request.sample_rate
    })
  end

  defp completed_event(%SpeechRequest{} = request, opts) do
    SpeechEvent.speech_completed(%{
      request_id: Keyword.get(opts, :request_id),
      id: nil,
      usage: %Usage{},
      metadata: request.metadata
    })
  end

  # ---------------------------------------------------------------------------
  # ALLM.SpeechStreamAdapter — stream_synthesize_input/3
  # ---------------------------------------------------------------------------

  @doc """
  Stream a scripted speech request whose text arrives as an enumerable of
  chunks. `request.input` is ignored.

  The request is gated synchronously with
  `ALLM.Validate.speech_request(request, input: :streamed)`: a shape error
  (for example an unknown `:format`) returns
  `{:error, %SpeechAdapterError{reason: :invalid_request}}` with the
  validator's errors on `metadata.errors`, before the script is consulted
  and before the input is touched.

  The script entry is resolved at call time, as in `stream_synthesize/2`.
  The input is reduced lazily, when the stream is, and through
  `ALLM.Providers.Support.InputPump`, exactly as a real adapter reduces it,
  so an input that reads the caller's mailbox fails here the same way.

    * absent script — one `:audio_delta` of `"FAKE-AUDIO:" <> chunk` per
      non-empty chunk, then `:speech_completed`.
    * `{:ok, bytes}` — consumes all the input, then emits `bytes` in
      `adapter_opts[:chunk_bytes]` pieces.
    * `{:error, err}`, `{:ok, %SpeechResponse{}}`, `{:events, events}` and `{:retry_until_call, n}` —
      as in `stream_synthesize/2`; the input is not reduced.

  Every stream that reduces the input obeys the input invariants of
  `ALLM.SpeechStreamAdapter`: `""` chunks are skipped; a non-binary or
  non-UTF-8 chunk ends it with `metadata.cause: :invalid_input_chunk`; an
  input with no non-empty chunk ends it with `:empty_input`; an input that
  raises ends it with `:input_raised` and one whose pump dies from an exit
  signal with `:input_crashed`, each with a string-only
  `%{kind, message}` map on the error's `:cause`. `opts[:stream_timeout]`
  (default 60,000 ms) bounds the silence between input chunks and ends the
  stream with `:timeout`. `adapter_opts[:input_window]` (default 8) is the
  pump's credit window.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "")
      iex> {:ok, events} = ALLM.Providers.FakeSpeech.stream_synthesize_input(req, ["a", "", "b"], [])
      iex> for {:audio_delta, bytes} <- events, do: bytes
      ["FAKE-AUDIO:a", "FAKE-AUDIO:b"]
  """
  @impl ALLM.SpeechStreamAdapter
  @spec stream_synthesize_input(SpeechRequest.t(), Enumerable.t(String.t()), keyword()) ::
          {:ok, Enumerable.t(SpeechEvent.t())} | {:error, SpeechAdapterError.t()}
  def stream_synthesize_input(%SpeechRequest{} = request, input, opts) when is_list(opts) do
    maybe_capture(request, opts)

    with :ok <- input_gate(request) do
      case resolve_script(opts) do
        :exhausted ->
          {:error, exhausted_error()}

        :retry ->
          {:ok, [{:error, retry_error()}]}

        :default ->
          {:ok, input_stream(request, input, opts, :echo)}

        {:entry, {:ok, bytes}} when is_binary(bytes) ->
          {:ok, input_stream(request, input, opts, {:bytes, bytes})}

        {:entry, entry} ->
          {:ok, stream_entry_events(entry, request, opts)}
      end
    end
  end

  defp input_gate(%SpeechRequest{} = request) do
    case Validate.speech_request(request, input: :streamed) do
      :ok ->
        :ok

      {:error, %ValidationError{errors: errors}} ->
        {:error,
         SpeechAdapterError.new(:invalid_request,
           message: "invalid speech request: #{inspect(errors)}",
           metadata: %{errors: errors}
         )}
    end
  end

  defp input_stream(request, input, opts, mode) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    window = Keyword.get(adapter_opts, :input_window, InputPump.default_window())
    timeout = Keyword.get(opts, :stream_timeout, @stream_timeout)

    Stream.resource(
      fn ->
        {pid, ref} = InputPump.start(input, self(), window)

        %{
          pid: pid,
          ref: ref,
          mode: mode,
          request: request,
          opts: opts,
          timeout: timeout,
          pending: [started_event(request, opts)],
          spoke?: false,
          done?: false
        }
      end,
      &next_input_events/1,
      fn state -> InputPump.stop(state.pid, state.ref) end
    )
  end

  defp next_input_events(%{pending: [_ | _] = pending} = state),
    do: {pending, %{state | pending: []}}

  defp next_input_events(%{done?: true} = state), do: {:halt, state}

  defp next_input_events(%{ref: ref} = state) do
    receive do
      message when InputPump.is_pump_message(message, ref) ->
        case InputPump.classify(message, ref) do
          {:input, chunk} ->
            InputPump.ack(state.pid, ref)
            on_chunk(chunk, state)

          :done ->
            finish(on_input_done(state), state)

          {:failed, cause, info} ->
            finish([input_failure(cause, info)], state)
        end
    after
      state.timeout ->
        err =
          SpeechAdapterError.new(:timeout,
            message: "stream_timeout exceeded waiting for input",
            metadata: %{cause: :stream_timeout}
          )

        finish([{:error, err}], state)
    end
  end

  defp on_chunk("", state), do: {[], state}

  defp on_chunk(chunk, %{mode: :echo} = state) when is_binary(chunk) do
    if String.valid?(chunk),
      do: {[SpeechEvent.audio_delta("FAKE-AUDIO:" <> chunk)], %{state | spoke?: true}},
      else: finish([invalid_chunk_error()], state)
  end

  defp on_chunk(chunk, state) when is_binary(chunk) do
    if String.valid?(chunk),
      do: {[], %{state | spoke?: true}},
      else: finish([invalid_chunk_error()], state)
  end

  defp on_chunk(_chunk, state), do: finish([invalid_chunk_error()], state)

  defp on_input_done(%{spoke?: false}), do: [empty_input_error()]

  defp on_input_done(%{mode: :echo} = state), do: [completed_event(state.request, state.opts)]

  defp on_input_done(%{mode: {:bytes, bytes}} = state),
    do: body_events(bytes, completed_event(state.request, state.opts), state.opts)

  defp finish(events, state), do: {events, %{state | done?: true}}

  defp invalid_chunk_error do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       message: "input chunks must be UTF-8 strings",
       metadata: %{cause: :invalid_input_chunk}
     )}
  end

  defp unreadable_audio_error do
    {:error,
     SpeechAdapterError.new(:unknown,
       message: "FakeSpeech {:ok, %SpeechResponse{}} script entry has no readable audio",
       metadata: %{cause: :unreadable_script_audio}
     )}
  end

  defp empty_input_error do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       message: "the input produced no text to speak",
       metadata: %{cause: :empty_input}
     )}
  end

  defp input_failure(cause, info) do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       message: "the input stream failed: #{info.message}",
       metadata: %{cause: cause},
       cause: info
     )}
  end

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @typedoc "One scripted speech result."
  @type script_entry ::
          {:ok, binary()}
          | {:ok, SpeechResponse.t()}
          | {:error, SpeechAdapterError.t()}
          | {:events, [SpeechEvent.t()]}
          | {:retry_until_call, pos_integer()}

  @doc """
  Document and validate the script grammar for `adapter_opts[:speech_script]`.

  Each entry is one of:

    * `{:ok, bytes}` — return `bytes` as the audio, with `:format` set to
      `request.format || :mp3` and the MIME type from
      `ALLM.SpeechResponse.format_to_mime/1`.
    * `{:ok, %ALLM.SpeechResponse{}}` — return the struct verbatim.
    * `{:error, %ALLM.Error.SpeechAdapterError{}}` — return the struct
      verbatim.
    * `{:events, events}` — for the streaming callbacks, emit `events`
      verbatim. `synthesize/2` answers it with `:unknown` and
      `metadata.cause: :stream_only_script_entry`.
    * `{:retry_until_call, n}` — synthetic `:rate_limited` for the first
      `n - 1` calls against this entry. Consecutive entries of this shape
      chain into a layered budget.

  Returns `:ok` when the script is well-formed; raises `ArgumentError` on the
  first invalid entry. Validation is opt-in: `synthesize/2` does not call it.

  ## Examples

      iex> ALLM.Providers.FakeSpeech.script([{:ok, "bytes"}, {:retry_until_call, 2}])
      :ok
  """
  @spec script([script_entry()]) :: :ok
  def script(entries) when is_list(entries) do
    Enum.each(entries, &validate_entry!/1)
    :ok
  end

  @doc """
  Start an Agent-backed script cursor for cross-process multi-call scripting
  and for disambiguating content-equal scripts in the same process.

  Pass the returned pid as `adapter_opts[:script_cursor]`.

  ## Examples

      iex> pid = ALLM.Providers.FakeSpeech.start_script_cursor()
      iex> ALLM.Providers.FakeSpeech.cursor_index(pid)
      0
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Read the current cursor index for an Agent-backed cursor.

  ## Examples

      iex> pid = ALLM.Providers.FakeSpeech.start_script_cursor()
      iex> req = ALLM.SpeechRequest.new(input: "x")
      iex> opts = [adapter_opts: [speech_script: [{:ok, "a"}], script_cursor: pid]]
      iex> {:ok, _} = ALLM.Providers.FakeSpeech.synthesize(req, opts)
      iex> ALLM.Providers.FakeSpeech.cursor_index(pid)
      1
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp maybe_capture(%SpeechRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Keyword.get(adapter_opts, :capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  # Resolve the script entry for this call, moving the cursor. Shared by the
  # non-streaming and both streaming callbacks, so a stream call consumes its
  # entry at call time, before the stream is returned.
  #
  # Returns `:default` (absent or `[]` script), `:exhausted` (a spent
  # non-empty script), `:retry` (inside a `{:retry_until_call, n}` budget), or
  # `{:entry, entry}`.
  defp resolve_script(opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :speech_script, [])

    # Peek WITHOUT advancing — `:retry_until_call` holds the cursor in place
    # for `n - 1` calls and only advances on call n.
    cursor = peek_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        _ = advance_cursor(script, adapter_opts)
        spent_or_default(script)

      {:retry_until_call, n} ->
        resolve_retry_until_call(script, cursor, n, adapter_opts)

      entry ->
        _ = advance_cursor(script, adapter_opts)
        {:entry, entry}
    end
  end

  defp resolve_retry_until_call(script, cursor, n, adapter_opts) do
    visits = bump_retry_visits(script, cursor, adapter_opts)

    if visits < n do
      :retry
    else
      _ = advance_cursor(script, adapter_opts)
      next_cursor = cursor + 1

      case Enum.at(script, next_cursor) do
        nil ->
          spent_or_default(script)

        {:retry_until_call, m} ->
          # Chained budgets: land ON the next retry entry and open its budget.
          resolve_retry_until_call(script, next_cursor, m, adapter_opts)

        next_entry ->
          _ = advance_cursor(script, adapter_opts)
          {:entry, next_entry}
      end
    end
  end

  defp interpret_entry({:ok, %SpeechResponse{} = response}, _request, _opts), do: {:ok, response}

  defp interpret_entry({:ok, bytes}, request, opts) when is_binary(bytes),
    do: {:ok, build_response(bytes, request, opts)}

  defp interpret_entry({:error, %SpeechAdapterError{} = err}, _request, _opts), do: {:error, err}

  defp interpret_entry({:events, _events}, _request, _opts) do
    {:error,
     SpeechAdapterError.new(:unknown,
       message: "FakeSpeech {:events, _} script entries are for the streaming callbacks only",
       metadata: %{cause: :stream_only_script_entry}
     )}
  end

  # MUST key on the SAME identity the cursor helpers use (`cursor_key_id/2`).
  # Keying on `:erlang.phash2(script)` alone would give two content-equal
  # engines separate cursors but a SHARED retry budget.
  defp bump_retry_visits(script, cursor, adapter_opts) do
    key = {:allm_fake_speech_retry_visits, cursor_key_id(script, adapter_opts), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  # An absent (or `[]`) script yields the default audio; a spent NON-EMPTY
  # script is a caller off-by-one and errors.
  defp spent_or_default([]), do: :default
  defp spent_or_default(_script), do: :exhausted

  defp exhausted_error do
    SpeechAdapterError.new(:unknown,
      message: "FakeSpeech script exhausted: no entry at the current cursor position",
      metadata: %{cause: :speech_script_exhausted}
    )
  end

  defp retry_error do
    SpeechAdapterError.new(:rate_limited,
      message: "FakeSpeech retry_until_call hint",
      retry_after_ms: 0
    )
  end

  defp build_response(bytes, %SpeechRequest{} = request, opts) do
    format = request.format || @default_format

    %SpeechResponse{
      audio:
        Audio.from_binary(
          bytes || "FAKE-AUDIO:" <> request.input,
          SpeechResponse.format_to_mime(format)
        ),
      format: format,
      sample_rate: request.sample_rate,
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :fake,
      usage: %Usage{},
      raw: nil,
      metadata: request.metadata
    }
  end

  # ---------------------------------------------------------------------------
  # Cursor management
  # ---------------------------------------------------------------------------

  defp advance_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        key = {:allm_fake_speech_cursor, cursor_key_id(script, adapter_opts)}
        current = Process.get(key, 0)
        Process.put(key, current + 1)
        current

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  defp peek_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil -> Process.get({:allm_fake_speech_cursor, cursor_key_id(script, adapter_opts)}, 0)
      pid when is_pid(pid) -> Agent.get(pid, & &1)
    end
  end

  # Single source of truth for the cursor identity, shared by the two cursor
  # helpers and `bump_retry_visits/3`: `:script_cursor` pid > `:cursor_key` >
  # `:erlang.phash2(script)`.
  defp cursor_key_id(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      pid when is_pid(pid) -> pid
      _ -> Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(script)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_entry!({:ok, bytes}) when is_binary(bytes), do: :ok
  defp validate_entry!({:ok, %SpeechResponse{}}), do: :ok
  defp validate_entry!({:error, %SpeechAdapterError{}}), do: :ok
  defp validate_entry!({:events, events}) when is_list(events), do: :ok
  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeSpeech script entry: #{inspect(other)} " <>
            "(expected {:ok, binary}, {:ok, %SpeechResponse{}}, " <>
            "{:error, %SpeechAdapterError{}}, {:events, list}, or {:retry_until_call, pos_integer})"
  end
end
