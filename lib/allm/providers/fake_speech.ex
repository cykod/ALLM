defmodule ALLM.Providers.FakeSpeech do
  @moduledoc """
  Deterministic, scripted adapter for text-to-speech testing. Implements
  `ALLM.SpeechAdapter`.

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
  message every time `synthesize/2` is invoked, BEFORE any gate runs and
  before the script is consulted:

      {ALLM.Providers.FakeSpeech, :call, %{request: request, opts: opts}}

  It does NOT affect the response.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.", format: :wav)
      iex> {:ok, resp} = ALLM.Providers.FakeSpeech.synthesize(req, [])
      iex> {ALLM.Audio.to_binary(resp.audio), resp.audio.mime_type, resp.format}
      {{:ok, "FAKE-AUDIO:Hello."}, "audio/wav", :wav}
  """

  @behaviour ALLM.SpeechAdapter

  alias ALLM.{Audio, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError

  @default_format :mp3

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
  onto `response.model`, `request.metadata` onto `response.metadata`, and
  stamps `provider: :fake`. `{:ok, %SpeechResponse{}}` script entries are
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

    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
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
  # Public helpers
  # ---------------------------------------------------------------------------

  @typedoc "One scripted speech result."
  @type script_entry ::
          {:ok, binary()}
          | {:ok, SpeechResponse.t()}
          | {:error, SpeechAdapterError.t()}
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

  defp run_scripted(%SpeechRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :speech_script, [])

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

  defp interpret_entry({:ok, %SpeechResponse{} = response}, _request, _opts), do: {:ok, response}

  defp interpret_entry({:ok, bytes}, request, opts) when is_binary(bytes),
    do: {:ok, build_response(bytes, request, opts)}

  defp interpret_entry({:error, %SpeechAdapterError{} = err}, _request, _opts), do: {:error, err}

  defp handle_retry_until_call(script, cursor, n, request, opts, adapter_opts) do
    visits = bump_retry_visits(script, cursor, adapter_opts)

    if visits < n do
      {:error,
       SpeechAdapterError.new(:rate_limited,
         message: "FakeSpeech retry_until_call hint",
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
    key = {:allm_fake_speech_retry_visits, cursor_key_id(script, adapter_opts), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  # An absent (or `[]`) script yields the default audio; a spent NON-EMPTY
  # script is a caller off-by-one and errors.
  defp spent_or_default([], request, opts), do: {:ok, build_response(nil, request, opts)}

  defp spent_or_default(_script, _request, _opts) do
    {:error,
     SpeechAdapterError.new(:unknown,
       message: "FakeSpeech script exhausted: no entry at the current cursor position",
       metadata: %{cause: :speech_script_exhausted}
     )}
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
  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeSpeech script entry: #{inspect(other)} " <>
            "(expected {:ok, binary}, {:ok, %SpeechResponse{}}, " <>
            "{:error, %SpeechAdapterError{}}, or {:retry_until_call, pos_integer})"
  end
end
