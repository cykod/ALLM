defmodule ALLM.Test.Fixtures.StubAdapter do
  @moduledoc """
  Permanent test fixture that implements both `ALLM.Adapter` and
  `ALLM.StreamAdapter`. Used by `allm_conformance`'s harness self-tests.

  The script lives on `opts[:adapter_opts]` as a keyword list. See the
  `@moduledoc` below for the full script-shape contract, which mirrors the
  contract specified in `PHASE_3_DESIGN.md` §Behaviour & Type Contracts →
  "StubAdapter script shape".

  ## Non-streaming (`script:`)

      adapter_opts: [
        script: [
          {:ok, %{output_text: "hi", request_id: "req_1"}},
          {:error, :rate_limited, retry_after_ms: 500},
          {:error, :authentication_failed, status: 401}
        ]
      ]

  `{:ok, map}` becomes `{:ok, %ALLM.Response{...}}`; `{:error, reason,
  keyword}` becomes `{:error, %ALLM.Error.AdapterError{reason: reason,
  ...opts}}`. When the indexed entry is past the script end, the call
  returns `{:error, %AdapterError{reason: :unknown, message: "stub script
  exhausted"}}`.

  By default each call reads entry 0 without advancing — the single-call
  contract used by most conformance cases. For multi-call scripting pass
  `adapter_opts[:script_cursor]` as the pid returned from
  `start_script_cursor/0`; the stub increments the cursor on every call
  so successive calls see successive entries.

  ## Streaming (`stream_script:`)

      adapter_opts: [
        stream_script: [
          [{:text_delta, "hel"}, {:text_delta, "lo"}, {:finish, :stop}],
          [{:error_event, :rate_limited, retry_after_ms: 500}],
          [{:stream_error, :cancelled}]
        ]
      ]

  Each call to `stream/2` reads the head of `stream_script` — a list of
  event specs. `{:text_delta, str}` emits a well-shaped `:text_delta` event.
  `{:finish, reason}` emits `:message_completed` + `:step_completed`.
  `{:error_event, reason, opts}` emits a terminating `{:error,
  %AdapterError{...}}`. `{:stream_error, reason, opts}` emits a terminating
  `{:error, %StreamError{...}}`.

  ## Cleanup observation

  When `adapter_opts[:cleanup_observer]` is a `:counters` ref, the
  streaming adapter increments index `1` in its `Stream.resource/3`
  `after_fun`. Halt-safety tests assert `:counters.get(ref, 1) == 1` after
  halting the stream early.

  ## Opts recording

  Callers who want to inspect the `opts` keyword that the harness passed
  to `generate/2` (e.g., to verify `:request_timeout` passthrough) supply
  `adapter_opts[:opts_recorder]` as an Agent pid from
  `start_opts_recorder/0`. The stub pushes the full `opts` list onto the
  agent on each call; `recorded_opts/1` returns the list in call order.

  ## Scope

  This fixture is permanent — it remains in `conformance/test/support/`
  indefinitely as the harness's primary self-test subject, even after
  Phase 4 adds `ALLM.Providers.Fake`.
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.{Message, Response, Usage}

  # ---------------------------------------------------------------------------
  # Helpers — script cursor + opts recorder (both Agent-backed, opt-in)
  # ---------------------------------------------------------------------------

  @doc """
  Start a cursor Agent that tracks how many script entries have been
  consumed. Pass the returned pid as `adapter_opts[:script_cursor]`.
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Start an opts recorder Agent. Pass the returned pid as
  `adapter_opts[:opts_recorder]`; then call `recorded_opts/1` to retrieve
  the recorded calls' opts (list, most recent last).
  """
  @spec start_opts_recorder() :: pid()
  def start_opts_recorder do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  @doc """
  Return the list of opts keywords that `generate/2` or `stream/2` has
  been called with, in call order (oldest first).
  """
  @spec recorded_opts(pid()) :: [keyword()]
  def recorded_opts(pid) when is_pid(pid) do
    Agent.get(pid, &Enum.reverse/1)
  end

  # ---------------------------------------------------------------------------
  # ALLM.Adapter
  # ---------------------------------------------------------------------------

  @impl ALLM.Adapter
  def generate(_request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :script, [])
    cursor = Keyword.get(adapter_opts, :script_cursor)
    recorder = Keyword.get(adapter_opts, :opts_recorder)

    record_opts(recorder, opts)
    index = advance_cursor(cursor)
    entry = Enum.at(script, index)

    case entry do
      {:ok, response_map} ->
        {:ok, build_response(response_map)}

      {:error, reason, error_opts} ->
        {:error, AdapterError.new(reason, error_opts)}

      nil ->
        {:error, AdapterError.new(:unknown, message: "stub script exhausted")}
    end
  end

  # ---------------------------------------------------------------------------
  # ALLM.StreamAdapter
  # ---------------------------------------------------------------------------

  @impl ALLM.StreamAdapter
  def stream(_request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    stream_script = Keyword.get(adapter_opts, :stream_script, [])
    observer = Keyword.get(adapter_opts, :cleanup_observer)
    cursor = Keyword.get(adapter_opts, :script_cursor)
    recorder = Keyword.get(adapter_opts, :opts_recorder)

    record_opts(recorder, opts)
    index = advance_cursor(cursor)
    entry = Enum.at(stream_script, index)

    case entry do
      {:preflight_error, reason, error_opts} ->
        {:error, AdapterError.new(reason, error_opts)}

      event_specs when is_list(event_specs) ->
        {:ok, build_stream(event_specs, observer)}

      nil ->
        {:ok, build_stream([], observer)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp record_opts(nil, _opts), do: :ok

  defp record_opts(pid, opts) when is_pid(pid) do
    Agent.update(pid, fn acc -> [opts | acc] end)
  end

  defp advance_cursor(nil), do: 0

  defp advance_cursor(pid) when is_pid(pid) do
    Agent.get_and_update(pid, fn i -> {i, i + 1} end)
  end

  defp build_response(map) when is_map(map) do
    %Response{
      id: Map.get(map, :id),
      request_id: Map.get(map, :request_id),
      model: Map.get(map, :model),
      message: Map.get(map, :message),
      output_text: Map.get(map, :output_text, Map.get(map, :text)),
      tool_calls: Map.get(map, :tool_calls, []),
      finish_reason: Map.get(map, :finish_reason, :stop),
      usage: Map.get(map, :usage, %Usage{}),
      raw: Map.get(map, :raw),
      metadata: Map.get(map, :metadata, %{})
    }
  end

  defp build_stream(event_specs, observer) do
    Stream.resource(
      fn -> event_specs end,
      fn
        [] -> {:halt, :done}
        [spec | rest] -> {[expand_event(spec)], rest}
      end,
      fn _acc ->
        # The `:counters.new/2` return value is an opaque term (a tagged
        # tuple on the current OTP, not a raw reference) — match on
        # non-nil rather than is_reference/1.
        if observer, do: :counters.add(observer, 1, 1), else: :ok
      end
    )
  end

  defp expand_event({:text_delta, delta}) when is_binary(delta),
    do: {:text_delta, %{id: nil, delta: delta}}

  defp expand_event({:tool_call, kw}) when is_list(kw) do
    id = Keyword.fetch!(kw, :id)
    name = Keyword.fetch!(kw, :name)
    arguments = Keyword.get(kw, :arguments, %{})
    raw = Keyword.get(kw, :raw_arguments, Jason.encode!(arguments))
    {:tool_call_completed, %{id: id, name: name, arguments: arguments, raw_arguments: raw}}
  end

  defp expand_event({:finish, reason}) when is_atom(reason) do
    {:message_completed, %{message: %Message{role: :assistant, content: ""}}}
  end

  defp expand_event({:error_event, reason, error_opts}) when is_atom(reason) do
    {:error, AdapterError.new(reason, error_opts)}
  end

  defp expand_event({:stream_error, reason, error_opts}) when is_atom(reason) do
    {:error, StreamError.new(reason, error_opts)}
  end

  defp expand_event({:stream_error, reason}) when is_atom(reason) do
    {:error, StreamError.new(reason)}
  end

  defp expand_event({:error_event, reason}) when is_atom(reason) do
    {:error, AdapterError.new(reason)}
  end
end
