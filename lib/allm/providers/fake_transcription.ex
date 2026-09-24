defmodule ALLM.Providers.FakeTranscription do
  @moduledoc """
  Deterministic, scripted adapter for speech-to-text testing. Implements
  `ALLM.TranscriptionAdapter`.

  Layer B — runtime. FakeTranscription is the canonical testing
  transcription adapter; it ships in `lib/` (not `test/support/`) because
  users need it for their own application tests, mirroring
  `ALLM.Providers.FakeSpeech` and `ALLM.Providers.FakeModeration`.

  ## What FakeTranscription is (and isn't)

  FakeTranscription never listens to the audio. It measures `:audio` to run
  the resolvable and size gates every `ALLM.TranscriptionAdapter` must run,
  and reads `:model` and `:metadata` to round-trip them onto the response.
  It has no MIME gate: accepted MIME types are a real provider's concern.

  ## Size cap

  `max_audio_bytes/0` returns `1024`, deliberately small so a test crosses
  the boundary cheaply. The gate measures against
  `adapter_opts[:max_audio_bytes] || max_audio_bytes()`. A real adapter that
  hands a scripted call off to this Fake passes its own cap under that key,
  so a scripted run with a real multi-kilobyte clip is not rejected by the
  Fake's small default.

  ## Default transcript (no script)

  With **no script** — `adapter_opts[:transcription_script]` absent or `[]`
  — the response carries `text: ""` and `usage: %ALLM.Usage{}`.

  ## Spent script

  A **non-empty** script whose cursor has run off the end does NOT fall back
  to the default — it returns

      {:error, %ALLM.Error.TranscriptionAdapterError{
         reason: :unknown,
         metadata: %{cause: :transcription_script_exhausted}}}

  ## Script shapes

  `opts[:adapter_opts][:transcription_script]` accepts a list of script
  entries. See `script/1` for the full grammar.

      adapter_opts: [
        transcription_script: [
          {:ok, "The quick brown fox."},
          {:ok, %ALLM.TranscriptionResponse{...}},
          {:error, %ALLM.Error.TranscriptionAdapterError{reason: :rate_limited}},
          {:retry_until_call, 3}
        ]
      ]

  `{:retry_until_call, n}` returns a synthetic
  `%ALLM.Error.TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 0}`
  for the first `n - 1` calls against this entry, then advances to the next
  entry on call `n`. Consecutive entries of this shape chain.

  ## Cursor behaviour

  Multi-call scripts advance a per-process cursor on every call. The cursor
  lives in the process dictionary at
  `{:allm_fake_transcription_cursor, key_id}`, isolated per ExUnit test
  process (`async: true`), GC'd on pid-down, zero-setup for the common case.
  The `key_id` is chosen by this precedence:

    1. `adapter_opts[:script_cursor]` — an explicit Agent pid (handled
       separately; see `start_script_cursor/0`).
    2. `adapter_opts[:cursor_key]` — the engine's stable `:id`, injected by
       the façade dispatch chokepoint via `ALLM.Engine.put_cursor_key/2`.
    3. `:erlang.phash2(script)` — the content-hash fallback for direct
       adapter calls with no engine.

  At the façade the cursor keys on engine identity, so two engines built with
  content-equal `:transcription_script` values each read index 0 on their
  first call, even in the same process. **The content-hash footgun remains
  only for DIRECT adapter calls** —
  `ALLM.Providers.FakeTranscription.transcribe(req, opts)` invoked without an
  engine receives no `:cursor_key`. Workaround for that path: pass distinct
  `adapter_opts[:script_cursor]` Agent pids from `start_script_cursor/0`. The
  `{:retry_until_call, n}` visit counter keys on the same identity, so
  content-equal engines never share a retry budget.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `transcribe/2` is invoked, BEFORE any gate runs and
  before the script is consulted:

      {ALLM.Providers.FakeTranscription, :call, %{request: request, opts: opts}}

  ## Examples

      iex> audio = ALLM.Audio.from_binary(<<0, 1, 2>>, "audio/mpeg")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio)
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "Hello."}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeTranscription.transcribe(req, opts)
      iex> resp.text
      "Hello."
  """

  @behaviour ALLM.TranscriptionAdapter

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError

  @max_audio_bytes 1024

  # ---------------------------------------------------------------------------
  # ALLM.TranscriptionAdapter — max_audio_bytes/0
  # ---------------------------------------------------------------------------

  @doc """
  Return the largest audio payload FakeTranscription accepts, in bytes.

  Deliberately **not** a provider-shaped number: 1024 bytes lets a test cross
  the size boundary without allocating megabytes. Override per call with
  `adapter_opts[:max_audio_bytes]`.

  ## Examples

      iex> ALLM.Providers.FakeTranscription.max_audio_bytes()
      1024
  """
  @impl ALLM.TranscriptionAdapter
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  # ---------------------------------------------------------------------------
  # ALLM.TranscriptionAdapter — transcribe/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted transcription request.

  Gate order, all before the script is consulted:

    1. `adapter_opts[:capture_pid]` side-channel (fires even for rejected
       calls).
    2. **Resolvable** — `ALLM.Audio.size/1` on `request.audio`. A missing
       file, invalid base64, or a value that is not an `%ALLM.Audio{}` →
       `{:error, %TranscriptionAdapterError{reason: :invalid_request}}` with
       `metadata.cause` (`:enoent`, `:eisdir`, `:invalid_base64`,
       `:invalid_source`, …).
    3. **Size** — more than `adapter_opts[:max_audio_bytes] || max_audio_bytes()`
       bytes → `:invalid_request` with `metadata.count` and `metadata.max`.

  Otherwise reads the script from
  `opts[:adapter_opts][:transcription_script]`, advances the process-local
  cursor, and interprets the entry. An **absent** script produces the
  default empty transcript; a **spent non-empty** script returns
  `:transcription_script_exhausted`.

  Propagates `opts[:request_id]`, `request.model` and `request.metadata`
  onto the response and stamps `provider: :fake`.
  `{:ok, %TranscriptionResponse{}}` script entries are returned verbatim.

  ## Examples

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_binary("abc", "audio/mpeg"))
      iex> {:ok, resp} = ALLM.Providers.FakeTranscription.transcribe(req, request_id: "rid-1")
      iex> {resp.text, resp.request_id, resp.usage}
      {"", "rid-1", %ALLM.Usage{}}

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("/nonexistent.mp3"))
      iex> {:error, err} = ALLM.Providers.FakeTranscription.transcribe(req, [])
      iex> {err.reason, err.metadata.cause}
      {:invalid_request, :enoent}
  """
  @impl ALLM.TranscriptionAdapter
  @spec transcribe(TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def transcribe(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case gate(request, Keyword.get(adapter_opts, :max_audio_bytes) || max_audio_bytes()) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  # Contract invariants 3 and 4, in that order — both before any script
  # consult, as a real adapter runs them before I/O and key resolution.
  defp gate(%TranscriptionRequest{audio: audio}, max) do
    case measure(audio) do
      {:error, cause} ->
        {:error,
         TranscriptionAdapterError.new(:invalid_request,
           message: "audio bytes cannot be resolved: #{inspect(cause)}",
           metadata: %{field: :audio, cause: cause}
         )}

      {:ok, count} when count > max ->
        {:error,
         TranscriptionAdapterError.new(:invalid_request,
           message: "audio is #{count} bytes, exceeding max_audio_bytes #{max}",
           metadata: %{field: :audio, count: count, max: max}
         )}

      {:ok, _count} ->
        :ok
    end
  end

  defp measure(%Audio{} = audio), do: Audio.size(audio)
  defp measure(_other), do: {:error, :invalid_source}

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @typedoc "One scripted transcription result."
  @type script_entry ::
          {:ok, String.t()}
          | {:ok, TranscriptionResponse.t()}
          | {:error, TranscriptionAdapterError.t()}
          | {:retry_until_call, pos_integer()}

  @doc """
  Document and validate the script grammar for
  `adapter_opts[:transcription_script]`.

  Each entry is one of:

    * `{:ok, text}` — return `text` as the transcript, with
      `usage: %ALLM.Usage{}`.
    * `{:ok, %ALLM.TranscriptionResponse{}}` — return the struct verbatim.
    * `{:error, %ALLM.Error.TranscriptionAdapterError{}}` — return the struct
      verbatim.
    * `{:retry_until_call, n}` — synthetic `:rate_limited` for the first
      `n - 1` calls against this entry. Consecutive entries of this shape
      chain into a layered budget.

  Returns `:ok` when the script is well-formed; raises `ArgumentError` on the
  first invalid entry. Validation is opt-in: `transcribe/2` does not call it.

  ## Examples

      iex> ALLM.Providers.FakeTranscription.script([{:ok, "text"}, {:retry_until_call, 2}])
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

      iex> pid = ALLM.Providers.FakeTranscription.start_script_cursor()
      iex> ALLM.Providers.FakeTranscription.cursor_index(pid)
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

      iex> pid = ALLM.Providers.FakeTranscription.start_script_cursor()
      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_binary("x", "audio/mpeg"))
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "a"}], script_cursor: pid]]
      iex> {:ok, _} = ALLM.Providers.FakeTranscription.transcribe(req, opts)
      iex> ALLM.Providers.FakeTranscription.cursor_index(pid)
      1
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp maybe_capture(%TranscriptionRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Keyword.get(adapter_opts, :capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  defp run_scripted(%TranscriptionRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :transcription_script, [])

    # Peek WITHOUT advancing — `:retry_until_call` holds the cursor in place
    # for `n - 1` calls and only advances on call n.
    cursor = peek_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        _ = advance_cursor(script, adapter_opts)
        spent_or_default(script, request, opts)

      {:retry_until_call, n} ->
        handle_retry_until_call(script, cursor, n, request, opts, adapter_opts)

      entry ->
        _ = advance_cursor(script, adapter_opts)
        interpret_entry(entry, request, opts)
    end
  end

  defp interpret_entry({:ok, %TranscriptionResponse{} = response}, _request, _opts),
    do: {:ok, response}

  defp interpret_entry({:ok, text}, request, opts) when is_binary(text),
    do: {:ok, build_response(text, request, opts)}

  defp interpret_entry({:error, %TranscriptionAdapterError{} = err}, _request, _opts),
    do: {:error, err}

  defp handle_retry_until_call(script, cursor, n, request, opts, adapter_opts) do
    visits = bump_retry_visits(script, cursor, adapter_opts)

    if visits < n do
      {:error,
       TranscriptionAdapterError.new(:rate_limited,
         message: "FakeTranscription retry_until_call hint",
         retry_after_ms: 0
       )}
    else
      _ = advance_cursor(script, adapter_opts)
      next_cursor = cursor + 1

      case Enum.at(script, next_cursor) do
        nil ->
          spent_or_default(script, request, opts)

        {:retry_until_call, m} ->
          # Chained budgets: land ON the next retry entry and open its budget.
          handle_retry_until_call(script, next_cursor, m, request, opts, adapter_opts)

        next_entry ->
          _ = advance_cursor(script, adapter_opts)
          interpret_entry(next_entry, request, opts)
      end
    end
  end

  # MUST key on the SAME identity the cursor helpers use (`cursor_key_id/2`).
  # Keying on `:erlang.phash2(script)` alone would give two content-equal
  # engines separate cursors but a SHARED retry budget.
  defp bump_retry_visits(script, cursor, adapter_opts) do
    key = {:allm_fake_transcription_retry_visits, cursor_key_id(script, adapter_opts), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  # An absent (or `[]`) script yields the default empty transcript; a spent
  # NON-EMPTY script is a caller off-by-one and errors.
  defp spent_or_default([], request, opts), do: {:ok, build_response("", request, opts)}

  defp spent_or_default(_script, _request, _opts) do
    {:error,
     TranscriptionAdapterError.new(:unknown,
       message: "FakeTranscription script exhausted: no entry at the current cursor position",
       metadata: %{cause: :transcription_script_exhausted}
     )}
  end

  defp build_response(text, %TranscriptionRequest{} = request, opts) do
    %TranscriptionResponse{
      text: text,
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
        key = {:allm_fake_transcription_cursor, cursor_key_id(script, adapter_opts)}
        current = Process.get(key, 0)
        Process.put(key, current + 1)
        current

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  defp peek_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        Process.get({:allm_fake_transcription_cursor, cursor_key_id(script, adapter_opts)}, 0)

      pid when is_pid(pid) ->
        Agent.get(pid, & &1)
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

  defp validate_entry!({:ok, text}) when is_binary(text), do: :ok
  defp validate_entry!({:ok, %TranscriptionResponse{}}), do: :ok
  defp validate_entry!({:error, %TranscriptionAdapterError{}}), do: :ok
  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeTranscription script entry: #{inspect(other)} " <>
            "(expected {:ok, text}, {:ok, %TranscriptionResponse{}}, " <>
            "{:error, %TranscriptionAdapterError{}}, or {:retry_until_call, pos_integer})"
  end
end
