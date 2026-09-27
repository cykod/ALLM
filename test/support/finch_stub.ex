defmodule ALLM.Test.FinchStub do
  @moduledoc """
  Per-test seam that mimics the slice of `Finch` consumed by
  `ALLM.Providers.OpenAI.stream/2`: `async_request/3` + `cancel_async_request/1`.
  Internal test support — NOT part of the published Hex package.

  Per Phase 10 design Decision #9 + Phase 10.3 implementation guidance, the
  stub is injected via `opts[:finch_module]` (preferred over `Process.put`
  monkey-patching: explicit, no compile-time coupling, and the production
  default `Finch` module is never replaced). Each test's stub state lives in
  the test process's process dictionary keyed by a unique ref returned from
  `install/2`.

  ## Chunk vocabulary

  Each chunk in the list passed to `install/2` is one of:

    * `binary()` — sent to the caller as `{ref, {:data, chunk}}`.
    * `{:terminal_status, code}` — sends `{ref, {:status, code}}` followed by
      `{ref, {:headers, []}}`. Models a 4xx/5xx encountered mid-stream.
    * `{:terminal_error, exception}` — sends `{ref, {:error, exception}}`.
      Models a TCP/TLS transport failure.

  The stub always sends `{ref, {:status, 200}}` + `{ref, {:headers, []}}`
  BEFORE the first chunk unless the first chunk is itself a terminal_status
  or terminal_error frame (which acts as a pre-flight failure). The
  `:initial_status` and `:initial_headers` install options change those two
  leading frames.

  ## Error bodies (`:error_body`)

  With `:error_body` set (a binary, or a list of binaries), the stub models
  an HTTP error response the way Finch delivers one: the leading status and
  headers frames, then one `{ref, {:data, part}}` per body part, then
  `{ref, :done}`. The `chunks` list is not sent. Pair it with an
  `:initial_status` of 400 or above.

  After the last chunk the stub sends `{ref, :done}` unless the chunk list
  ends in a terminal frame — terminal frames implicitly close the stream.

  ## Cancellation

  `cancel_async_request/1` increments a per-ref counter; tests assert it
  fired via `cancel_count/1`. The counter is per-ref so concurrent tests
  do not collide.

  ## Async safety

  All state lives in the *test process's* process dictionary, keyed by the
  per-install ref. ExUnit `async: true` is safe — each test runs in its own
  process and its own dictionary.

  ## Agent-backed mode (`install_shared/2`)

  The default mode only works when the adapter's stream is reduced in the
  installing process. An input enumerable reduced by
  `ALLM.Providers.Support.InputPump` runs in the pump process instead, so
  `install_shared/2` keeps the state in an `Agent` whose pid is passed as
  `finch_stub_ref:` (the one stub key `ALLM.Providers.Support.Transport`
  forwards). In that mode `async_request/3` returns a fresh reference per
  call, delivers the frames to **the process that called
  `async_request/3`**, and sends them from a process `spawn_link`ed to that
  caller, as real Finch's HTTP/1 pool links its request process to the
  caller. A killed caller therefore takes the sender down with it.
  `senders/1` lists the sender pids.

  ## Worked example

      ref = ALLM.Test.FinchStub.install([
        ~s(data: {"choices":[{"delta":{"content":"hi"}}]}\\n\\n),
        ~s(data: [DONE]\\n\\n)
      ])

      {:ok, stream} = OpenAI.stream(req, finch_module: ALLM.Test.FinchStub, finch_stub_ref: ref)
      events = Enum.to_list(stream)
  """

  @typedoc "Per-install ref returned from `install/2` and threaded into adapter opts."
  @type ref :: reference()

  @typedoc "One chunk in the install/2 chunks list — see module doc."
  @type chunk ::
          binary()
          | {:terminal_status, non_neg_integer()}
          | {:terminal_error, Exception.t()}

  @doc """
  Install a stub for the calling process; returns a ref to thread into
  adapter opts (`finch_stub_ref:`).

  Options:

    * `:delay_ms` — milliseconds to sleep between chunks (default 1).
      Used by stream-timeout tests to slow the producer.
    * `:initial_status` — HTTP status to send on the leading status frame
      (default 200).
    * `:initial_headers` — the header list sent on the leading headers
      frame (default `[]`).
    * `:error_body` — a binary or list of binaries sent as the response body
      in place of `chunks`, followed by `:done` (see "Error bodies"). Default
      `nil`: the chunks are sent.
  """
  @spec install([chunk()], keyword()) :: ref()
  def install(chunks, opts) when is_list(chunks) and is_list(opts) do
    ref = make_ref()

    Process.put(
      {:allm_finch_stub, ref},
      Map.merge(frame_opts(chunks, opts), %{
        cancel_count: 0,
        captured_opts: nil,
        captured_request: nil,
        caller: self()
      })
    )

    ref
  end

  @doc """
  Install a stub whose state lives in an `Agent`, so `async_request/3` may
  be called from any process. Returns the Agent pid; pass it as
  `finch_stub_ref:`. Takes the same chunks and options as `install/2`.
  """
  @spec install_shared([chunk()], keyword()) :: pid()
  def install_shared(chunks, opts) when is_list(chunks) and is_list(opts) do
    {:ok, agent} =
      Agent.start_link(fn ->
        Map.merge(frame_opts(chunks, opts), %{
          cancel_count: 0,
          captured_opts: nil,
          captured_request: nil,
          senders: []
        })
      end)

    agent
  end

  defp frame_opts(chunks, opts) do
    %{
      chunks: chunks,
      delay_ms: Keyword.get(opts, :delay_ms, 1),
      initial_status: Keyword.get(opts, :initial_status, 200),
      initial_headers: Keyword.get(opts, :initial_headers, []),
      error_body: Keyword.get(opts, :error_body)
    }
  end

  @doc """
  The sender pids an Agent-backed stub has spawned, in call order.
  """
  @spec senders(pid()) :: [pid()]
  def senders(agent) when is_pid(agent), do: Agent.get(agent, & &1.senders)

  @doc """
  Read the cancellation counter for a stub ref (or an Agent-backed stub's
  pid).

  Returns 0 when no cancel has been recorded.
  """
  @spec cancel_count(ref() | pid()) :: non_neg_integer()
  def cancel_count(agent) when is_pid(agent), do: Agent.get(agent, & &1.cancel_count)

  def cancel_count(ref) when is_reference(ref) do
    %{cancel_count: n} = Process.get({:allm_finch_stub, ref})
    n
  end

  # ---------------------------------------------------------------------------
  # Finch-shaped API
  # ---------------------------------------------------------------------------

  @doc """
  Mimics `Finch.async_request/3`. Looks up the install state by
  `opts[:finch_stub_ref]` and spawns a sender process that delivers the
  configured chunks back to the caller process.

  Captures the full `opts` keyword list on the install state (read via
  `captured_opts/1`) so tests can assert which Finch-level options the
  adapter forwarded (e.g. `:receive_timeout`, `:request_timeout`,
  `:pool_timeout`), and the request itself (read via `captured_request/1`)
  so tests can assert the streaming request body the adapter built.
  """
  @spec async_request(any(), atom(), keyword()) :: ref()
  def async_request(req, name, opts) when is_list(opts) do
    case Keyword.fetch!(opts, :finch_stub_ref) do
      agent when is_pid(agent) -> async_request_shared(agent, req, opts)
      stub_ref -> async_request_local(req, name, stub_ref, opts)
    end
  end

  defp async_request_shared(agent, req, opts) do
    ref = make_ref()
    caller = self()

    state =
      Agent.get_and_update(agent, fn s ->
        {s, %{s | captured_opts: opts, captured_request: req}}
      end)

    sender = spawn_link(fn -> send_frames(caller, ref, state) end)

    Agent.update(agent, fn s -> %{s | senders: s.senders ++ [sender]} end)
    Process.put({:allm_finch_stub_shared, ref}, agent)
    ref
  end

  defp async_request_local(req, _name, stub_ref, opts) do
    state = Process.get({:allm_finch_stub, stub_ref}) || raise "no stub installed for ref"

    Process.put({:allm_finch_stub, stub_ref}, %{
      state
      | captured_opts: opts,
        captured_request: req
    })

    caller = state.caller
    spawn(fn -> send_frames(caller, stub_ref, state) end)

    stub_ref
  end

  @doc """
  Read the `opts` keyword list captured on the most recent
  `async_request/3` call for this ref. Returns `nil` when the adapter
  hasn't called `async_request/3` yet.
  """
  @spec captured_opts(ref() | pid()) :: keyword() | nil
  def captured_opts(agent) when is_pid(agent), do: Agent.get(agent, & &1.captured_opts)

  def captured_opts(ref) when is_reference(ref) do
    %{captured_opts: opts} = Process.get({:allm_finch_stub, ref})
    opts
  end

  @doc """
  Read the request (a `%Finch.Request{}` from a real adapter) passed to the
  most recent `async_request/3` call for this ref or Agent-backed stub.
  Returns `nil` when the adapter hasn't called `async_request/3` yet.
  """
  @spec captured_request(ref() | pid()) :: any()
  def captured_request(agent) when is_pid(agent), do: Agent.get(agent, & &1.captured_request)

  def captured_request(ref) when is_reference(ref) do
    %{captured_request: req} = Process.get({:allm_finch_stub, ref})
    req
  end

  @doc """
  Mimics `Finch.cancel_async_request/1`. Increments the per-ref cancel
  counter.
  """
  @spec cancel_async_request(ref()) :: :ok
  def cancel_async_request(ref) when is_reference(ref) do
    case Process.get({:allm_finch_stub_shared, ref}) do
      agent when is_pid(agent) ->
        Agent.update(agent, fn s -> %{s | cancel_count: s.cancel_count + 1} end)

      nil ->
        cancel_local(ref)
    end
  end

  defp cancel_local(ref) do
    state = Process.get({:allm_finch_stub, ref})
    Process.put({:allm_finch_stub, ref}, %{state | cancel_count: state.cancel_count + 1})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals — message delivery
  # ---------------------------------------------------------------------------

  defp send_frames(caller, ref, state) do
    send(caller, {ref, {:status, state.initial_status}})
    send(caller, {ref, {:headers, state.initial_headers}})

    case state.error_body do
      nil -> send_chunks(caller, ref, state.chunks, state.delay_ms)
      body -> send_chunks(caller, ref, List.wrap(body), state.delay_ms)
    end
  end

  defp send_chunks(caller, ref, [], _delay_ms) do
    send_done_via(caller, ref)
  end

  defp send_chunks(caller, ref, [{:terminal_status, code} | _rest], _delay_ms) do
    send(caller, {ref, {:status, code}})
    send(caller, {ref, {:headers, []}})
    # No :done — the terminal status acts as the closing frame.
    send_done_via(caller, ref)
  end

  defp send_chunks(caller, ref, [{:terminal_error, exception} | _rest], _delay_ms) do
    send(caller, {ref, {:error, exception}})
  end

  defp send_chunks(caller, ref, [chunk | rest], delay_ms) when is_binary(chunk) do
    Process.sleep(delay_ms)
    send(caller, {ref, {:data, chunk}})
    send_chunks(caller, ref, rest, delay_ms)
  end

  defp send_done_via(caller, ref), do: send(caller, {ref, :done})
end
