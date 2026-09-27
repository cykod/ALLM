defmodule ALLM.Providers.Support.WebSocket.Mint do
  @moduledoc """
  The default `ALLM.Providers.Support.WebSocket` implementation, over
  `Mint.WebSocket`.

  Layer B — runtime. `Mint.WebSocket` is process-less: the socket belongs
  to the process that calls `connect/3`, and its `:tcp` / `:ssl` messages
  arrive in that process's mailbox. The streaming audio adapters call every
  function from the process that reduces the stream, so a halted stream
  owns the socket it has to close.

  ## Connecting

  `connect/3` derives the scheme, host and port from the URL:

  | URL | Transport | Default port |
  |-----|-----------|--------------|
  | `wss://…` | TLS (`:https`), upgrade scheme `:wss` | 443 |
  | `ws://…` | plain TCP (`:http`), upgrade scheme `:ws` | 80 |

  The connection is always HTTP/1. The handshake runs in the calling
  process with a `receive` that selects only this socket's messages, so no
  other message in the caller's mailbox is consumed, and it is bounded by
  `opts[:connect_timeout]` (default 10,000 ms). A response other than 101
  returns `{:error, {:upgrade_status, status, body}}`, where `body` is the
  JSON-decoded response body when it is JSON and the raw binary otherwise.

  The bundled adapters build `wss://` URLs from their `https://` base URL.
  The plain `ws://` scheme is what a `http://` base URL produces, which is
  how the tests reach a local server; TLS is exercised only by the live
  recorders, the same split as `Finch` versus the test stubs.

  ## Messages

  Every message this connection delivers is a 2- or 3-tuple whose second
  element is the socket (`message_tag/1`): `{:tcp, socket, data}`,
  `{:tcp_closed, socket}`, `{:tcp_error, socket, reason}` and their `:ssl`
  counterparts. `handle_message/2` answers a server ping with a pong
  itself and drops pongs. `flush_messages/1` removes all of them from the
  mailbox after `close/1`.
  """

  @behaviour ALLM.Providers.Support.WebSocket

  alias :"Elixir.Mint.HTTP", as: MintHTTP
  alias :"Elixir.Mint.WebSocket", as: MintWS

  @default_connect_timeout 10_000

  @enforce_keys [:conn, :ref, :websocket, :socket]
  defstruct [:conn, :ref, :websocket, :socket, pending: ""]

  @typedoc """
  An open connection. `pending` holds bytes that arrived in the same read
  as the 101 response and have not been decoded yet.
  """
  @type t :: %__MODULE__{
          conn: term(),
          ref: term(),
          websocket: term(),
          socket: term(),
          pending: binary()
        }

  # Bytes that arrived in the same read as the 101 response stay in the
  # struct's `pending` field, and the next `handle_message/2`, whatever
  # message it is given, decodes them before anything else: a TCP packet
  # that reached the mailbox after the 101 (Mint re-arms the socket as soon
  # as it reads the 101) can never be decoded ahead of them. A payload-less
  # `{@buffered, socket}` self-message wakes the owner for the case where no
  # further transport message arrives. If that same message is a transport
  # error, the error wins and the decoded pending frames are discarded: a
  # provider error frame sent with the 101 then surfaces as a transport
  # failure rather than as its own reason. (`:tcp_closed` is not an error:
  # Mint turns it into `:closed`, so the pending frames survive it.)
  @buffered __MODULE__

  @impl true
  @spec connect(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, t()} | {:error, ALLM.Providers.Support.WebSocket.connect_error()}
  def connect(url, headers, opts) when is_binary(url) and is_list(headers) do
    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, http_scheme, ws_scheme, host, port, path} <- parse_url(url),
         {:ok, conn} <- open(http_scheme, host, port, timeout),
         {:ok, conn, ref} <- upgrade(ws_scheme, conn, path, headers) do
      handshake(conn, ref, deadline)
    end
  end

  @impl true
  @spec send_frame(t(), ALLM.Providers.Support.WebSocket.frame()) ::
          {:ok, t()} | {:error, t(), term()}
  def send_frame(%__MODULE__{} = ws, frame), do: encode_and_send(ws, frame)

  # Any frame `Mint.WebSocket.encode/2` takes, pongs included.
  defp encode_and_send(ws, frame) do
    case MintWS.encode(ws.websocket, frame) do
      {:ok, websocket, data} -> stream_body(%{ws | websocket: websocket}, data)
      {:error, websocket, reason} -> {:error, %{ws | websocket: websocket}, reason}
    end
  end

  defp stream_body(ws, data) do
    case MintWS.stream_request_body(ws.conn, ws.ref, data) do
      {:ok, conn} -> {:ok, %{ws | conn: conn}}
      {:error, conn, reason} -> {:error, %{ws | conn: conn}, reason}
    end
  end

  @impl true
  @spec message_tag(t()) :: term()
  def message_tag(%__MODULE__{socket: socket}), do: socket

  @impl true
  @spec handle_message(t(), term()) ::
          {:ok, t(), [ALLM.Providers.Support.WebSocket.frame() | :closed]}
          | :unknown
          | {:error, t(), term()}
  def handle_message(%__MODULE__{pending: pending} = ws, message) when pending != "" do
    with {:ok, ws, frames} <- decode_data(%{ws | pending: ""}, pending) do
      case handle_message(ws, message) do
        {:ok, ws, more} -> {:ok, ws, frames ++ more}
        # The pending frames are this connection's even when `message` is not.
        :unknown -> {:ok, ws, frames}
        {:error, _ws, _reason} = error -> error
      end
    end
  end

  def handle_message(%__MODULE__{socket: socket} = ws, {@buffered, socket}), do: {:ok, ws, []}

  def handle_message(%__MODULE__{} = ws, message) do
    case MintWS.stream(ws.conn, message) do
      :unknown ->
        :unknown

      {:ok, conn, responses} ->
        handle_responses(%{ws | conn: conn}, responses)

      {:error, conn, %{__struct__: Mint.TransportError, reason: :closed}, _responses} ->
        {:ok, %{ws | conn: conn}, [:closed]}

      {:error, conn, reason, _responses} ->
        {:error, %{ws | conn: conn}, reason}
    end
  end

  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = ws) do
    _ = safely(fn -> send_frame(ws, {:close, 1000, ""}) end)
    _ = safely(fn -> MintHTTP.close(ws.conn) end)
    :ok
  end

  @impl true
  @spec flush_messages(t()) :: :ok
  def flush_messages(%__MODULE__{socket: socket}), do: flush(socket)

  # ---------------------------------------------------------------------------
  # Internals — connecting
  # ---------------------------------------------------------------------------

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} = uri when is_binary(host) and host != "" ->
        {:ok, :https, :wss, host, uri.port || 443, request_target(uri)}

      %URI{scheme: "ws", host: host} = uri when is_binary(host) and host != "" ->
        {:ok, :http, :ws, host, uri.port || 80, request_target(uri)}

      _ ->
        {:error, {:transport, {:invalid_url, "expected a ws:// or wss:// URL with a host"}}}
    end
  end

  defp request_target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  defp open(scheme, host, port, timeout) do
    case MintHTTP.connect(scheme, host, port,
           protocols: [:http1],
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp upgrade(ws_scheme, conn, path, headers) do
    case MintWS.upgrade(ws_scheme, conn, path, headers) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        _ = safely(fn -> MintHTTP.close(conn) end)
        {:error, {:transport, reason}}
    end
  end

  defp handshake(conn, ref, deadline) do
    socket = MintHTTP.get_socket(conn)
    acc = %{status: nil, headers: [], body: [], done?: false}

    case await_response(conn, ref, socket, deadline, acc) do
      {:ok, conn, %{status: 101} = resp} ->
        pending = IO.iodata_to_binary(resp.body)
        # The wake-up for `pending`; a failed upgrade's `flush/1` removes it.
        if pending != "", do: send(self(), {@buffered, socket})
        finish_upgrade(conn, ref, socket, resp, pending)

      {:ok, conn, resp} ->
        _ = safely(fn -> MintHTTP.close(conn) end)
        flush(socket)
        {:error, {:upgrade_status, resp.status, decode_body(resp.body)}}

      {:error, conn, reason} ->
        abort(conn, socket, reason)
    end
  end

  # Dialyzer infers that `Mint.WebSocket.new/5` can only fail:
  # `mint_web_socket` 1.0.6 types the opaque struct's `:fragment` as `tuple()`
  # (deps/mint_web_socket/lib/mint/web_socket.ex:129) while its `defstruct`
  # default is `nil` (:134), so the success value it builds does not match
  # its own type. The suppression covers only this function, which holds
  # just the `new/5` call, the struct build and the shared `abort/3`; the
  # pending-byte hand-off lives in `handshake/3`. Remove it when an upstream
  # release types `:fragment` as nullable: on a `mint_web_socket` bump, drop
  # this attribute and run `mix dialyzer`. The success path is exercised by
  # every handshake test in `test/allm/providers/support/web_socket_test.exs`.
  @dialyzer {:nowarn_function, finish_upgrade: 5}
  defp finish_upgrade(conn, ref, socket, resp, pending) do
    case MintWS.new(conn, ref, resp.status, resp.headers) do
      {:ok, conn, websocket} ->
        {:ok,
         %__MODULE__{
           conn: conn,
           ref: ref,
           websocket: websocket,
           socket: socket,
           pending: pending
         }}

      {:error, conn, reason} ->
        abort(conn, socket, reason)
    end
  end

  defp abort(conn, socket, reason) do
    _ = safely(fn -> MintHTTP.close(conn) end)
    flush(socket)
    {:error, {:transport, reason}}
  end

  # Only this socket's messages are selected, so nothing else in the
  # caller's mailbox is consumed while the handshake is in flight.
  defp await_response(conn, _ref, _socket, _deadline, %{done?: true} = acc), do: {:ok, conn, acc}

  defp await_response(conn, ref, socket, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {tag, ^socket, _} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        stream_handshake(conn, ref, socket, deadline, acc, message)

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        stream_handshake(conn, ref, socket, deadline, acc, message)
    after
      remaining -> {:error, conn, :connect_timeout}
    end
  end

  defp stream_handshake(conn, ref, socket, deadline, acc, message) do
    case MintWS.stream(conn, message) do
      {:ok, conn, responses} ->
        await_response(
          conn,
          ref,
          socket,
          deadline,
          Enum.reduce(responses, acc, &collect(&1, ref, &2))
        )

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp collect({:status, ref, status}, ref, acc), do: %{acc | status: status}
  defp collect({:headers, ref, headers}, ref, acc), do: %{acc | headers: acc.headers ++ headers}
  defp collect({:data, ref, data}, ref, acc), do: %{acc | body: [acc.body | data]}
  defp collect({:done, ref}, ref, acc), do: %{acc | done?: true}
  defp collect(_other, _ref, acc), do: acc

  defp decode_body(iodata) do
    body = IO.iodata_to_binary(iodata)

    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> body
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — frames
  # ---------------------------------------------------------------------------

  defp handle_responses(ws, responses) do
    Enum.reduce_while(responses, {:ok, ws, []}, fn
      {:data, ref, data}, {:ok, %{ref: ref} = ws, frames} ->
        case decode_data(ws, data) do
          {:ok, ws, more} -> {:cont, {:ok, ws, frames ++ more}}
          {:error, _ws, _reason} = error -> {:halt, error}
        end

      {:error, ref, _reason}, {:ok, %{ref: ref} = ws, frames} ->
        {:cont, {:ok, ws, frames ++ [:closed]}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp decode_data(ws, data) do
    case MintWS.decode(ws.websocket, data) do
      {:ok, websocket, frames} -> handle_frames(%{ws | websocket: websocket}, frames, [])
      {:error, websocket, reason} -> {:error, %{ws | websocket: websocket}, reason}
    end
  end

  defp handle_frames(ws, [], acc), do: {:ok, ws, Enum.reverse(acc)}

  defp handle_frames(ws, [{:ping, data} | rest], acc) do
    case encode_and_send(ws, {:pong, data}) do
      {:ok, ws} -> handle_frames(ws, rest, acc)
      {:error, ws, reason} -> {:error, ws, reason}
    end
  end

  defp handle_frames(ws, [{:pong, _data} | rest], acc), do: handle_frames(ws, rest, acc)

  defp handle_frames(ws, [{:error, reason} | _rest], _acc), do: {:error, ws, reason}

  defp handle_frames(ws, [{:close, code, reason} | rest], acc),
    do: handle_frames(ws, rest, [{:close, code, reason} | acc])

  defp handle_frames(ws, [{kind, _payload} = frame | rest], acc) when kind in [:text, :binary],
    do: handle_frames(ws, rest, [frame | acc])

  # ---------------------------------------------------------------------------
  # Internals — cleanup
  # ---------------------------------------------------------------------------

  defp flush(socket) do
    receive do
      {tag, ^socket, _} when tag in [:tcp, :ssl, :tcp_error, :ssl_error] -> flush(socket)
      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed, @buffered] -> flush(socket)
    after
      0 -> :ok
    end
  end

  # `catch _, _` covers the `:error` kind, so exceptions too.
  defp safely(fun) do
    fun.()
  catch
    _, _ -> :error
  end
end
