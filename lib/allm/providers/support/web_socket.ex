defmodule ALLM.Providers.Support.WebSocket do
  @moduledoc """
  The WebSocket transport seam the streaming audio adapters are written
  against.

  Layer B — runtime. An adapter takes the implementing module from
  `opts[:ws_module]` (default `ALLM.Providers.Support.WebSocket.Mint`),
  exactly as the HTTP stream adapters take `opts[:finch_module]`, so a test
  can substitute a scripted stub without a network.

  ## Transport rule

  A WebSocket is opened over an HTTP/1 connection in the process that
  reduces the stream, and every function of this behaviour is called from
  that process. The connection is process-less: its transport messages
  arrive in the reducing process's mailbox, next to any input-pump
  messages, and a halted stream closes the socket and drains those
  messages in its after function. The API key goes in the upgrade
  request's headers, never in the URL, because URLs reach logs and
  telemetry.

  ## Receiving selectively

  The owner must not consume messages that are not its own, so it selects
  transport messages in its `receive` by tag: every message a connection
  delivers is a 2- or 3-tuple whose second element is `message_tag/1` of
  that connection (for the Mint implementation, the socket). The
  `is_transport_message/2` guard selects exactly those, and a matching
  message goes to `handle_message/2`:

      require ALLM.Providers.Support.WebSocket, as: WebSocket
      tag = ws.message_tag(conn)

      receive do
        message when WebSocket.is_transport_message(message, tag) ->
          ws.handle_message(conn, message)
      end

  `handle_message/2` still returns `:unknown` for a message that carries
  the tag but is not a transport message, so a caller that passes it
  anything else gets a plain answer.

  ## Frames

  Control frames never leave the implementation. A server ping is answered
  with a pong by `handle_message/2` itself, and pongs are dropped, so
  `t:frame/0` has only data and close variants. `:closed` in a
  `handle_message/2` result means the transport closed without a close
  frame.
  """

  alias ALLM.Providers.Support.InputPump

  require InputPump

  @typedoc "An open connection. Opaque to the adapter; only this behaviour's functions read it."
  @type conn :: term()

  @typedoc "A data or close frame, sent or received."
  @type frame ::
          {:text, String.t()}
          | {:binary, binary()}
          | {:close, non_neg_integer() | nil, String.t()}

  @typedoc """
  Why `connect/3` failed: the server answered the upgrade with a status
  other than 101 (with the response body, JSON-decoded when it is JSON), or
  the transport failed before a response.
  """
  @type connect_error ::
          {:upgrade_status, pos_integer(), map() | list() | binary()}
          | {:transport, term()}

  @doc """
  Open a WebSocket to `url` (`wss://` or `ws://`) with `headers` on the
  upgrade request, and drive the handshake to completion in the calling
  process. Honours `opts[:connect_timeout]` (milliseconds).
  """
  @callback connect(url :: String.t(), headers :: [{String.t(), String.t()}], opts :: keyword()) ::
              {:ok, conn()} | {:error, connect_error()}

  @doc "Send one frame."
  @callback send_frame(conn(), frame()) :: {:ok, conn()} | {:error, conn(), term()}

  @doc """
  The tag every transport message of `conn` carries as its second element.
  """
  @callback message_tag(conn()) :: term()

  @doc """
  Interpret one message selected by `message_tag/1`. Returns the data and
  close frames it carried (answering pings itself), `:unknown` for a
  message that is not this connection's, or an error.
  """
  @callback handle_message(conn(), message :: term()) ::
              {:ok, conn(), [frame() | :closed]} | :unknown | {:error, conn(), term()}

  @doc """
  Close the connection: a best-effort close frame, then the transport.
  Idempotent; never raises.
  """
  @callback close(conn()) :: :ok

  @doc """
  Remove every transport message of `conn` from the calling process's
  mailbox. Call it after `close/1`.
  """
  @callback flush_messages(conn()) :: :ok

  @doc """
  Guard: `message` is a transport message of the connection whose
  `message_tag/1` is `tag` (a 2- or 3-tuple whose second element is
  `tag`). Use it to select transport messages in a selective `receive`, so
  no other message in the owner's mailbox is consumed.
  """
  defguard is_transport_message(message, tag)
           when is_tuple(message) and tuple_size(message) in [2, 3] and
                  elem(message, 1) == tag

  # ---------------------------------------------------------------------------
  # The owner-side input loop, shared by the WebSocket input-stream adapters
  #
  # An adapter that speaks over a socket while an `InputPump` feeds it runs
  # one `Stream.resource/3` in the reducing process. These helpers are its
  # transport-neutral skeleton over a state map built by `loop_state/3`
  # (the adapter adds its own keys): select pump and socket messages with a
  # silence and keep-alive deadline, send JSON text frames, and close,
  # drain and stop everything in the after function. The adapter keeps its
  # payload handlers and its own error construction.
  # ---------------------------------------------------------------------------

  @typedoc false
  @type loop :: %{
          required(:ws) => module(),
          required(:conn) => conn() | nil,
          required(:pump) => {pid(), reference()} | nil,
          required(:stream_timeout) => timeout(),
          required(:keepalive_ms) => non_neg_integer(),
          required(:last_activity) => integer(),
          required(:last_sent) => integer(),
          required(:input_done?) => boolean(),
          optional(atom()) => term()
        }

  @doc false
  # The loop's own keys. `stream_timeout` is the silence (no transport
  # message and no pump message) allowed before `timed_out?/1` holds;
  # `keepalive_ms` is how long no client frame may go out while input is
  # still flowing before `next_message/1` wakes the adapter to send one.
  @spec loop_state(module(), timeout(), non_neg_integer()) :: loop()
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
      input_done?: false
    }
  end

  @doc false
  # Start the input pump over `input`, owned by the calling process, with
  # `opts[:adapter_opts][:input_window]` (default
  # `InputPump.default_window/0`) as its credit window. Call it only after
  # the connect and the initial message, so a failed upgrade never reduces
  # the input.
  @spec start_pump(loop(), Enumerable.t(), keyword()) :: loop()
  def start_pump(state, input, opts) do
    window =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.get(:input_window, InputPump.default_window())

    %{state | pump: InputPump.start(input, self(), window)}
  end

  @doc false
  # The next message of this stream: a pump message (classified) or a
  # transport message, with `last_activity` reset, or `:wake` when the
  # silence or keep-alive deadline passed first. Nothing else in the
  # mailbox is consumed.
  @spec next_message(loop()) ::
          {:pump, InputPump.classified(), loop()} | {:transport, term(), loop()} | :wake
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

      message when is_transport_message(message, tag) ->
        {:transport, message}
    after
      wait -> :wake
    end
  end

  defp pump_ref({_pid, ref}), do: ref
  defp pump_ref(nil), do: make_ref()

  defp wait_ms(state) do
    now = now_ms()

    silence =
      if state.stream_timeout == :infinity,
        do: :infinity,
        else: state.last_activity + state.stream_timeout - now

    keepalive =
      if state.input_done?, do: :infinity, else: state.last_sent + state.keepalive_ms - now

    case min(silence, keepalive) do
      :infinity -> :infinity
      ms -> max(ms, 0)
    end
  end

  @doc false
  # After `:wake`: whether the silence deadline passed (the stream ends with
  # a timeout) rather than the keep-alive one (the adapter sends its
  # keep-alive).
  @spec timed_out?(loop()) :: boolean()
  def timed_out?(state) do
    state.stream_timeout != :infinity and
      now_ms() - state.last_activity >= state.stream_timeout
  end

  @doc false
  # Interpret a transport message selected by `next_message/1`, keeping the
  # connection the transport returns.
  @spec handle_transport(loop(), term()) ::
          {:ok, loop(), [frame() | :closed]} | :unknown | {:error, loop(), term()}
  def handle_transport(state, message) do
    case state.ws.handle_message(state.conn, message) do
      {:ok, conn, frames} -> {:ok, %{state | conn: conn}, frames}
      :unknown -> :unknown
      {:error, conn, cause} -> {:error, %{state | conn: conn}, cause}
    end
  end

  @doc false
  # Send `message` JSON-encoded as one text frame, resetting the keep-alive
  # clock. The error's third element is the transport's raw cause; the
  # adapter builds its own error from it.
  @spec send_json(loop(), term()) :: {:ok, loop()} | {:error, loop(), term()}
  def send_json(state, message) do
    case state.ws.send_frame(state.conn, {:text, Jason.encode!(message)}) do
      {:ok, conn} -> {:ok, %{state | conn: conn, last_sent: now_ms()}}
      {:error, conn, cause} -> {:error, %{state | conn: conn}, cause}
    end
  end

  @doc false
  # Stop the pump (if one runs) and drain its messages. Idempotent.
  @spec stop_pump(loop()) :: loop()
  def stop_pump(%{pump: {pid, ref}} = state) do
    InputPump.stop(pid, ref)
    %{state | pump: nil}
  end

  def stop_pump(state), do: state

  @doc false
  # The `Stream.resource/3` after function: close the socket, remove its
  # messages from the mailbox, and stop the pump.
  @spec close_loop(loop()) :: :ok
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
