defmodule ALLM.Test.WSTestServer do
  @moduledoc """
  A minimal RFC 6455 WebSocket server on `:gen_tcp`, for testing
  `ALLM.Providers.Support.WebSocket.Mint` without a network or a new
  dependency. Internal test support — NOT part of the published Hex package.

  Each `start/2` listens on an OS-assigned port on `127.0.0.1` (port 0),
  so concurrent `async: true` tests never share a server. It accepts one
  connection, answers the upgrade, runs a script, then keeps reading client
  frames until the client closes.

  ## Handshake

  With the default `status: 101` the server answers with
  `Sec-WebSocket-Accept` (base64 of SHA-1 over the client key and the RFC
  GUID). Any other `:status` is answered as a plain HTTP response carrying
  `:body` (default `""`) with `content-type: application/json`, and the
  connection is closed. `status: :hangup` closes the connection without
  answering the upgrade at all.

  ## Script

  Steps run in order after the handshake:

    * `{:send, frame}` — send an unmasked server frame: `{:text, s}`,
      `{:binary, b}`, `{:ping, data}`, `{:pong, data}`,
      `{:close, code, reason}`, or `{:frame, opcode, payload, fin?}` for a
      raw data frame (opcode 0 is a continuation; `fin?: false` leaves the
      message open for the next fragment).
    * `:recv` — wait for the next client frame (it is reported like every
      other).
    * `{:sleep, ms}` — pause.
    * `{:raw, bytes}` — send bytes as they are (e.g. a malformed frame, or
      one part of `encode_frame/1`'s output, to split a frame across TCP
      reads).
    * `:close_tcp` — close the TCP connection without a close frame.

  ## Reports

  Every event is sent to the owner (`opts[:owner]`, default the caller of
  `start/2`) as `{ALLM.Test.WSTestServer, ref, event}`:

    * `{:handshake, request_target, headers}` — the upgrade request.
    * `{:frame, frame}` — each client frame, unmasked, including pongs and
      close frames.
    * `:closed` — the client closed the TCP connection.
  """

  import Bitwise

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @typedoc "What `start/2` returns."
  @type t :: %{port: :inet.port_number(), ref: reference(), pid: pid()}

  @doc """
  Start a server. Options: `:status` (default 101), `:body` (default `""`),
  `:owner` (default `self()`), `:accept` (a `Sec-WebSocket-Accept` value
  to send instead of the correct one), and `:greeting`, a server frame (or
  `{:raw, bytes}`) sent in the same write as the 101 response (so the
  client reads both in one TCP read).
  """
  @spec start(list(), keyword()) :: t()
  def start(script, opts \\ []) when is_list(script) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(parent, {ref, :port, port})
        serve(listen, owner, ref, script, opts)
      end)

    port =
      receive do
        {^ref, :port, port} -> port
      after
        5_000 -> raise "WSTestServer did not start"
      end

    %{port: port, ref: ref, pid: pid}
  end

  @doc "The `ws://` URL of `server` for `path`."
  @spec url(t(), String.t()) :: String.t()
  def url(%{port: port}, path \\ "/"), do: "ws://127.0.0.1:#{port}#{path}"

  # ---------------------------------------------------------------------------
  # Server process
  # ---------------------------------------------------------------------------

  defp serve(listen, owner, ref, script, opts) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        :gen_tcp.close(listen)
        handshake(socket, owner, ref, script, opts)

      {:error, _reason} ->
        :gen_tcp.close(listen)
    end
  end

  defp handshake(socket, owner, ref, script, opts) do
    {:ok, request} = read_request(socket, "")
    [request_line | header_lines] = String.split(request, "\r\n", trim: true)
    [_method, target | _] = String.split(request_line, " ")

    headers =
      for line <- header_lines, [k, v] = String.split(line, ":", parts: 2) do
        {String.downcase(String.trim(k)), String.trim(v)}
      end

    send(owner, {__MODULE__, ref, {:handshake, target, headers}})

    case Keyword.get(opts, :status, 101) do
      :hangup ->
        :gen_tcp.close(socket)

      101 ->
        key = :proplists.get_value("sec-websocket-key", headers)

        accept =
          Keyword.get_lazy(opts, :accept, fn ->
            :crypto.hash(:sha, key <> @guid) |> Base.encode64()
          end)

        greeting =
          case Keyword.get(opts, :greeting) do
            nil -> ""
            {:raw, bytes} -> bytes
            frame -> encode(frame)
          end

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n" <>
              "connection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n" <> greeting
          )

        if run(script, socket, owner, ref) == :ok, do: read_loop(socket, owner, ref)

      status ->
        body = Keyword.get(opts, :body, "")

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        :gen_tcp.close(socket)
    end
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        error -> error
      end
    end
  end

  defp run([], _socket, _owner, _ref), do: :ok

  # A client that already closed makes the send fail. The rest of the
  # script is skipped instead of crashing the linked test process, and the
  # read loop still reports whatever the client sent before it closed.
  defp run([{:send, frame} | rest], socket, owner, ref) do
    case :gen_tcp.send(socket, encode(frame)) do
      :ok -> run(rest, socket, owner, ref)
      {:error, _reason} -> :ok
    end
  end

  defp run([{:raw, bytes} | rest], socket, owner, ref) do
    case :gen_tcp.send(socket, bytes) do
      :ok -> run(rest, socket, owner, ref)
      {:error, _reason} -> :ok
    end
  end

  defp run([:close_tcp | _rest], socket, _owner, _ref) do
    :gen_tcp.close(socket)
    :closed
  end

  defp run([{:sleep, ms} | rest], socket, owner, ref) do
    Process.sleep(ms)
    run(rest, socket, owner, ref)
  end

  defp run([:recv | rest], socket, owner, ref) do
    case read_frame(socket, owner, ref) do
      :ok -> run(rest, socket, owner, ref)
      :closed -> :closed
    end
  end

  defp read_loop(socket, owner, ref) do
    case read_frame(socket, owner, ref) do
      :ok -> read_loop(socket, owner, ref)
      :closed -> :ok
    end
  end

  defp read_frame(socket, owner, ref) do
    with {:ok, <<_fin::1, _rsv::3, opcode::4, masked::1, len7::7>>} <- recv(socket, 2),
         {:ok, len} <- payload_length(socket, len7),
         {:ok, mask} <- if(masked == 1, do: recv(socket, 4), else: {:ok, nil}),
         {:ok, payload} <- recv(socket, len) do
      frame = to_frame(opcode, unmask(payload, mask))
      send(owner, {__MODULE__, ref, {:frame, frame}})
      after_frame(frame, socket, owner, ref)
    else
      _ ->
        send(owner, {__MODULE__, ref, :closed})
        :closed
    end
  end

  defp after_frame({:close, code, _reason}, socket, owner, ref) do
    _ = :gen_tcp.send(socket, encode({:close, code || 1000, ""}))
    :gen_tcp.close(socket)
    send(owner, {__MODULE__, ref, :closed})
    :closed
  end

  defp after_frame(_frame, _socket, _owner, _ref), do: :ok

  defp recv(_socket, 0), do: {:ok, ""}
  defp recv(socket, n), do: :gen_tcp.recv(socket, n, 10_000)

  defp payload_length(socket, 126) do
    with {:ok, <<len::16>>} <- recv(socket, 2), do: {:ok, len}
  end

  defp payload_length(socket, 127) do
    with {:ok, <<len::64>>} <- recv(socket, 8), do: {:ok, len}
  end

  defp payload_length(_socket, len), do: {:ok, len}

  defp unmask(payload, nil), do: payload

  defp unmask(payload, <<_::binary-size(4)>> = mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> bxor(byte, Enum.at(mask_bytes, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp to_frame(1, payload), do: {:text, payload}
  defp to_frame(2, payload), do: {:binary, payload}
  defp to_frame(8, <<code::16, reason::binary>>), do: {:close, code, reason}
  defp to_frame(8, _payload), do: {:close, nil, ""}
  defp to_frame(9, payload), do: {:ping, payload}
  defp to_frame(10, payload), do: {:pong, payload}
  defp to_frame(opcode, payload), do: {:opcode, opcode, payload}

  @doc """
  The bytes of an unmasked server frame, as `{:send, frame}` writes them
  (a 7-, 16- or 64-bit payload length by size). Split the result into
  `{:raw, part}` steps to deliver one frame over several TCP reads.
  """
  @spec encode_frame(tuple()) :: binary()
  def encode_frame(frame), do: encode(frame)

  defp encode({:text, s}), do: frame(1, s, true)
  defp encode({:binary, b}), do: frame(2, b, true)
  defp encode({:ping, d}), do: frame(9, d, true)
  defp encode({:pong, d}), do: frame(10, d, true)
  defp encode({:close, code, reason}), do: frame(8, <<code::16, reason::binary>>, true)
  defp encode({:frame, opcode, payload, fin?}), do: frame(opcode, payload, fin?)

  defp frame(opcode, payload, fin?) do
    len = byte_size(payload)
    fin = if fin?, do: 1, else: 0

    header =
      cond do
        len < 126 -> <<fin::1, 0::3, opcode::4, 0::1, len::7>>
        len < 65_536 -> <<fin::1, 0::3, opcode::4, 0::1, 126::7, len::16>>
        true -> <<fin::1, 0::3, opcode::4, 0::1, 127::7, len::64>>
      end

    header <> payload
  end
end
