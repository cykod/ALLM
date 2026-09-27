defmodule ALLM.Providers.Support.WebSocket.InputLoop do
  @moduledoc """
  The owner-side loop shared by the WebSocket input-stream adapters: a
  socket that speaks while an `ALLM.Providers.Support.InputPump` feeds it.

  Layer B helper. An adapter runs one `Stream.resource/3` in the reducing
  process, which owns the socket, and builds it on these functions over a
  state map made by `loop_state/3` (the adapter adds its own keys):

    * `start_pump/3` starts the input pump, after the connect and whatever
      the adapter must see first, so a refused session never reduces the
      input;
    * `next_message/1` selects the next pump or transport message of this
      stream, and nothing else in the mailbox, with a silence deadline and
      optional keep-alive and `wake_at` deadlines;
    * `timed_out?/1` tells, after `:wake`, whether the silence deadline passed;
    * `handle_transport/2` and `send_json/2` wrap the transport;
    * `stop_pump/1` and `close_loop/1` (the after function) release
      everything.

  The adapter keeps its payload handlers and builds its own errors: every
  failure here returns the transport's raw cause.

  ## Timers

  `stream_timeout` is the silence allowed before `timed_out?/1` holds, and
  both a transport message and a pump message reset it, so a slow input
  does not time out a socket whose server is waiting, and a quiet server
  does not time out while input still flows. `keepalive_ms` is how long no
  client frame may go out, while input still flows, before
  `next_message/1` wakes the adapter to send one; `:infinity` turns the
  keep-alive off, for a protocol that has none. `wake_at`, when the adapter
  sets it to a `System.monotonic_time(:millisecond)` instant, is a third
  deadline of its own (for example a bounded hold on an event): no message
  resets it, `next_message/1` returns `:wake` once it passes, and the
  adapter clears it back to `nil` when done with it. After such a wake,
  `timed_out?/1` still tells whether the silence deadline passed as well.
  """

  alias ALLM.Providers.Support.InputPump
  alias ALLM.Providers.Support.WebSocket

  require InputPump
  require WebSocket

  @typedoc "The loop state: these keys plus any the adapter adds."
  @type t :: %{
          required(:ws) => module(),
          required(:conn) => WebSocket.conn() | nil,
          required(:pump) => {pid(), reference()} | nil,
          required(:stream_timeout) => timeout(),
          required(:keepalive_ms) => timeout(),
          required(:last_activity) => integer(),
          required(:last_sent) => integer(),
          required(:input_done?) => boolean(),
          required(:wake_at) => integer() | nil,
          optional(atom()) => term()
        }

  @doc """
  A fresh loop state over the transport module `ws`, with no connection and
  no pump yet and no `wake_at` deadline. `stream_timeout` and
  `keepalive_ms` are in milliseconds, or `:infinity`.
  """
  @spec loop_state(module(), timeout(), timeout()) :: t()
  def loop_state(ws, stream_timeout, keepalive_ms) when is_atom(ws) do
    now = now_ms()

    %{
      ws: ws,
      conn: nil,
      pump: nil,
      stream_timeout: stream_timeout,
      keepalive_ms: keepalive_ms,
      last_activity: now,
      last_sent: now,
      input_done?: false,
      wake_at: nil
    }
  end

  @doc """
  Start the input pump over `input`, owned by the calling process, with
  `opts[:adapter_opts][:input_window]` (default
  `ALLM.Providers.Support.InputPump.default_window/0`) as its credit window.
  """
  @spec start_pump(t(), Enumerable.t(), keyword()) :: t()
  def start_pump(state, input, opts) do
    window =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.get(:input_window, InputPump.default_window())

    %{state | pump: InputPump.start(input, self(), window)}
  end

  @doc """
  The next message of this stream: a pump message (classified by
  `ALLM.Providers.Support.InputPump.classify/2`) or a transport message,
  with the silence clock reset, or `:wake` when the silence, keep-alive or
  `wake_at` deadline passed first. Nothing else in the mailbox is consumed.
  """
  @spec next_message(t()) ::
          {:pump, InputPump.classified(), t()} | {:transport, term(), t()} | :wake
  def next_message(state) do
    case await(state, wait_ms(state)) do
      {kind, message} -> {kind, message, %{state | last_activity: now_ms()}}
      :wake -> :wake
    end
  end

  # With no pump running, a fresh reference matches no pump message.
  defp await(state, wait) do
    tag = state.ws.message_tag(state.conn)
    ref = pump_ref(state.pump)

    receive do
      message when InputPump.is_pump_message(message, ref) ->
        {:pump, InputPump.classify(message, ref)}

      message when WebSocket.is_transport_message(message, tag) ->
        {:transport, message}
    after
      wait -> :wake
    end
  end

  defp pump_ref({_pid, ref}), do: ref
  defp pump_ref(nil), do: make_ref()

  defp wait_ms(state) do
    now = now_ms()
    silence = deadline_in(state.stream_timeout, state.last_activity, now)

    keepalive =
      if state.input_done?,
        do: :infinity,
        else: deadline_in(state.keepalive_ms, state.last_sent, now)

    case silence |> min(keepalive) |> min(wake_in(state, now)) do
      :infinity -> :infinity
      ms -> max(ms, 0)
    end
  end

  # Integers sort before atoms, so `min/2` picks any finite deadline over
  # `:infinity`.
  defp deadline_in(:infinity, _since, _now), do: :infinity
  defp deadline_in(ms, since, now), do: since + ms - now

  defp wake_in(%{wake_at: at}, now) when is_integer(at), do: at - now
  defp wake_in(_state, _now), do: :infinity

  @doc """
  After `:wake`: whether the silence deadline passed (the stream ends with a
  timeout) rather than the keep-alive one (the adapter sends its
  keep-alive) or the adapter's own `wake_at` deadline (the adapter acts on
  it, e.g. releases a held segment). More than one can have passed; an
  adapter that must not report a timeout for work the `wake_at` deadline
  completes checks that first.
  """
  @spec timed_out?(t()) :: boolean()
  def timed_out?(state) do
    state.stream_timeout != :infinity and
      now_ms() - state.last_activity >= state.stream_timeout
  end

  @doc """
  Interpret a transport message selected by `next_message/1`, keeping the
  connection the transport returns.
  """
  @spec handle_transport(t(), term()) ::
          {:ok, t(), [WebSocket.frame() | :closed]} | :unknown | {:error, t(), term()}
  def handle_transport(state, message) do
    case state.ws.handle_message(state.conn, message) do
      {:ok, conn, frames} -> {:ok, %{state | conn: conn}, frames}
      :unknown -> :unknown
      {:error, conn, cause} -> {:error, %{state | conn: conn}, cause}
    end
  end

  @doc """
  Send `message` JSON-encoded as one text frame, restarting the keep-alive
  clock. The error's third element is the transport's raw cause.
  """
  @spec send_json(t(), term()) :: {:ok, t()} | {:error, t(), term()}
  def send_json(state, message) do
    case state.ws.send_frame(state.conn, {:text, Jason.encode!(message)}) do
      {:ok, conn} -> {:ok, %{state | conn: conn, last_sent: now_ms()}}
      {:error, conn, cause} -> {:error, %{state | conn: conn}, cause}
    end
  end

  @doc "Stop the pump, if one runs, and drain its messages. Idempotent."
  @spec stop_pump(t()) :: t()
  def stop_pump(%{pump: {pid, ref}} = state) do
    InputPump.stop(pid, ref)
    %{state | pump: nil}
  end

  def stop_pump(state), do: state

  @doc """
  The `Stream.resource/3` after function: close the socket, remove its
  messages from the mailbox, and stop the pump.
  """
  @spec close_loop(t()) :: :ok
  def close_loop(state) do
    if state.conn do
      state.ws.close(state.conn)
      state.ws.flush_messages(state.conn)
    end

    _ = stop_pump(state)
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
