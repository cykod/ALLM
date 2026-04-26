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
  or terminal_error frame (which acts as a pre-flight failure).

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
      (default 200). When set to a 4xx/5xx, no `{:data, _}` frames follow —
      the synthetic-status pre-flight failure path.
  """
  @spec install([chunk()], keyword()) :: ref()
  def install(chunks, opts) when is_list(chunks) and is_list(opts) do
    ref = make_ref()

    Process.put({:allm_finch_stub, ref}, %{
      chunks: chunks,
      delay_ms: Keyword.get(opts, :delay_ms, 1),
      initial_status: Keyword.get(opts, :initial_status, 200),
      cancel_count: 0,
      caller: self()
    })

    ref
  end

  @doc """
  Read the cancellation counter for a stub ref.

  Returns 0 when no cancel has been recorded.
  """
  @spec cancel_count(ref()) :: non_neg_integer()
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
  """
  @spec async_request(any(), atom(), keyword()) :: ref()
  def async_request(_req, _name, opts) when is_list(opts) do
    stub_ref = Keyword.fetch!(opts, :finch_stub_ref)
    state = Process.get({:allm_finch_stub, stub_ref}) || raise "no stub installed for ref"

    caller = state.caller
    chunks = state.chunks
    delay_ms = state.delay_ms
    initial_status = state.initial_status

    spawn(fn ->
      send_initial_frames(caller, stub_ref, initial_status)
      send_chunks(caller, stub_ref, chunks, delay_ms)
    end)

    stub_ref
  end

  @doc """
  Mimics `Finch.cancel_async_request/1`. Increments the per-ref cancel
  counter.
  """
  @spec cancel_async_request(ref()) :: :ok
  def cancel_async_request(ref) when is_reference(ref) do
    state = Process.get({:allm_finch_stub, ref})
    Process.put({:allm_finch_stub, ref}, %{state | cancel_count: state.cancel_count + 1})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals — message delivery
  # ---------------------------------------------------------------------------

  defp send_initial_frames(caller, ref, status) do
    send(caller, {ref, {:status, status}})
    send(caller, {ref, {:headers, []}})
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
