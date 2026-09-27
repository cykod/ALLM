defmodule ALLM.Providers.Support.WebSocketTest do
  @moduledoc """
  `ALLM.Providers.Support.WebSocket.Mint` against `ALLM.Test.WSTestServer`,
  a local RFC 6455 server on `:gen_tcp` (plain `ws://`). TLS (`wss://`) is
  exercised only by the live recorder.

  Each test starts its own server on an OS-assigned port, so the module is
  safe under `async: true`.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.WebSocket
  alias ALLM.Providers.Support.WebSocket.Mint, as: WSMint
  alias ALLM.Test.WSTestServer

  require WebSocket

  @moduletag timeout: 15_000

  # The next transport message of `conn`, selected by its tag the way the
  # adapters select it, then interpreted.
  defp next(conn, timeout \\ 2_000) do
    tag = WSMint.message_tag(conn)

    receive do
      message when WebSocket.is_transport_message(message, tag) ->
        WSMint.handle_message(conn, message)
    after
      timeout -> flunk("no transport message within #{timeout} ms")
    end
  end

  # Reads transport messages until one carries frames.
  defp next_frames(conn) do
    case next(conn) do
      {:ok, conn, []} -> next_frames(conn)
      {:ok, conn, frames} -> {conn, frames}
      other -> flunk("unexpected #{inspect(other)}")
    end
  end

  defp server_event(server, timeout \\ 2_000) do
    ref = server.ref

    receive do
      {WSTestServer, ^ref, event} -> event
    after
      timeout -> flunk("no server event within #{timeout} ms")
    end
  end

  describe "the WebSocket behaviour" do
    test "WebSocket.Mint implements every callback" do
      assert Code.ensure_loaded?(WSMint)

      for {name, arity} <- WebSocket.behaviour_info(:callbacks) do
        assert function_exported?(WSMint, name, arity), "missing #{name}/#{arity}"
      end
    end
  end

  describe "connect/3" do
    test "a 101 handshake gives a connection, and a server text frame arrives as {:text, _}" do
      server = WSTestServer.start([{:send, {:text, "hello"}}])

      assert {:ok, conn} =
               WSMint.connect(WSTestServer.url(server, "/a/b?x=1"), [{"xi-api-key", "k"}], [])

      assert {:handshake, "/a/b?x=1", headers} = server_event(server)
      assert {"xi-api-key", "k"} in headers
      assert {_conn, [{:text, "hello"}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "a 401 upgrade response gives {:upgrade_status, 401, body} with the JSON body decoded" do
      body = ~s({"detail":{"type":"authentication_error","code":"unauthorized"}})
      server = WSTestServer.start([], status: 401, body: body)

      assert {:error, {:upgrade_status, 401, decoded}} =
               WSMint.connect(WSTestServer.url(server), [], [])

      assert decoded == %{
               "detail" => %{"type" => "authentication_error", "code" => "unauthorized"}
             }

      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
    end

    test "a non-JSON upgrade body is returned as the raw binary" do
      server = WSTestServer.start([], status: 503, body: "busy")

      assert {:error, {:upgrade_status, 503, "busy"}} =
               WSMint.connect(WSTestServer.url(server), [], [])
    end

    test "a refused TCP connection is a transport error" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, {:transport, _}} = WSMint.connect("ws://127.0.0.1:#{port}/", [], [])
    end

    test "a server that never answers the upgrade times out at :connect_timeout" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)

      assert {:error, {:transport, :connect_timeout}} =
               WSMint.connect("ws://127.0.0.1:#{port}/", [], connect_timeout: 100)

      :gen_tcp.close(listen)
    end

    test "a server that hangs up before answering the upgrade is a transport error" do
      server = WSTestServer.start([], status: :hangup)
      assert {:error, {:transport, _}} = WSMint.connect(WSTestServer.url(server), [], [])
      refute_received {:tcp_closed, _}
    end

    test "a wss:// URL is connected over TLS on the given port (a refused port is a transport error)" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, {:transport, _}} = WSMint.connect("wss://127.0.0.1:#{port}/", [], [])
    end

    test "a 101 with a wrong Sec-WebSocket-Accept is refused, and the socket's messages are drained" do
      server = WSTestServer.start([], accept: "bm90IHRoZSByaWdodCBub25jZQ==")
      assert {:error, {:transport, _}} = WSMint.connect(WSTestServer.url(server), [], [])
      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
    end

    test "a URL that is not ws:// or wss:// is refused without I/O" do
      assert {:error, {:transport, {:invalid_url, _}}} =
               WSMint.connect("https://example.com/", [], [])
    end

    test "the handshake consumes no other message in the caller's mailbox" do
      server = WSTestServer.start([])
      send(self(), :unrelated)
      assert {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      assert_received :unrelated
      WSMint.close(conn)
    end
  end

  describe "handle_message/2" do
    test "a server ping is answered with a pong the server observes, and no frame reaches the caller" do
      server = WSTestServer.start([{:send, {:ping, "are-you-there"}}, :recv])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      assert {:handshake, _, _} = server_event(server)

      assert {:ok, conn, []} = next(conn)
      assert {:frame, {:pong, "are-you-there"}} = server_event(server)
      WSMint.close(conn)
    end

    test "a server close with code 1011 surfaces as {:close, 1011, reason}" do
      server = WSTestServer.start([{:send, {:close, 1011, "internal"}}])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {_conn, [{:close, 1011, "internal"}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "a frame that arrives in the same TCP read as the 101 is still delivered, once" do
      server = WSTestServer.start([], greeting: {:text, "early"})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {conn, [{:text, "early"}]} = next_frames(conn)
      WSMint.close(conn)
      WSMint.flush_messages(conn)
      refute_received {WSMint, _}
    end

    # Mint re-arms the socket as soon as it reads the 101, so a later packet
    # can reach the mailbox before anything the handshake queues. The test
    # forces that order: every one of the socket's messages is taken out
    # and put back with the `:tcp` ones first. Falsifier: bytes read with
    # the 101 that are decoded after the next packet (the frame's tail is
    # then read as a header, and the frame is lost or an error).
    test "a greeting split across the 101's read and a later packet is one intact frame, in any mailbox order" do
      bytes = WSTestServer.encode_frame({:text, String.duplicate("g", 300)})
      <<head::binary-size(10), tail::binary>> = bytes
      server = WSTestServer.start([{:sleep, 50}, {:raw, tail}], greeting: {:raw, head})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      assert_wait(fn -> tcp_message_queued?(socket) end)
      {tcp, others} = socket |> take_messages() |> Enum.split_with(&match?({:tcp, _, _}, &1))
      Enum.each(tcp ++ others, &send(self(), &1))

      assert {conn, [{:text, text}]} = next_frames(conn)
      assert text == String.duplicate("g", 300)
      WSMint.close(conn)
      WSMint.flush_messages(conn)
      refute_received {WSMint, _}
    end

    test "bytes read with the 101 are decoded first even when the next message is not this connection's" do
      server = WSTestServer.start([], greeting: {:text, "early"})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {:ok, conn, [{:text, "early"}]} = WSMint.handle_message(conn, {:something, :else})
      assert WSMint.handle_message(conn, {:something, :else}) == :unknown
      WSMint.close(conn)
      WSMint.flush_messages(conn)
    end

    test "bytes read with the 101 followed by a socket error: the error wins" do
      server = WSTestServer.start([], greeting: {:text, "early"})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      assert {:error, _conn, _reason} =
               WSMint.handle_message(conn, {:tcp_error, socket, :econnreset})

      WSMint.close(conn)
      WSMint.flush_messages(conn)
    end

    test "bytes read with the 101 followed by :tcp_closed keep their frames" do
      server = WSTestServer.start([], greeting: {:text, "early"})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      assert {:ok, conn, [{:text, "early"} | _]} =
               WSMint.handle_message(conn, {:tcp_closed, socket})

      WSMint.close(conn)
      WSMint.flush_messages(conn)
    end

    test "a malformed frame read with the 101 is an error on the first message" do
      server = WSTestServer.start([], greeting: {:raw, <<0x83, 0x01, ?x>>})
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {:error, _conn, _reason} = next(conn)
      WSMint.close(conn)
      WSMint.flush_messages(conn)
    end

    test "a 10 KB text frame split over two TCP reads is one intact frame" do
      payload = String.duplicate("0123456789", 1_024)
      <<first::binary-size(1_000), rest::binary>> = WSTestServer.encode_frame({:text, payload})
      server = WSTestServer.start([{:sleep, 20}, {:raw, first}, {:sleep, 20}, {:raw, rest}])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {conn, [{:text, ^payload}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "a frame whose header is split from its 64-bit extended length is one intact frame" do
      payload = :binary.copy(<<7>>, 70_000)
      bytes = WSTestServer.encode_frame({:binary, payload})
      <<header::binary-size(2), length_head::binary-size(5), rest::binary>> = bytes
      assert <<_::1, _::3, 2::4, 0::1, 127::7>> = header

      server =
        WSTestServer.start([
          {:sleep, 20},
          {:raw, header},
          {:sleep, 20},
          {:raw, length_head},
          {:sleep, 20},
          {:raw, rest}
        ])

      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {conn, [{:binary, ^payload}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "a two-fragment text message (FIN=0, then a continuation) is one reassembled frame" do
      server =
        WSTestServer.start([
          {:sleep, 20},
          {:send, {:frame, 1, "Hel", false}},
          {:sleep, 20},
          {:send, {:frame, 0, "lo", true}}
        ])

      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {conn, [{:text, "Hello"}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "binary frames pass through and unsolicited pongs are dropped" do
      server = WSTestServer.start([{:send, {:pong, "x"}}, {:send, {:binary, <<1, 2, 3>>}}])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {_conn, [{:binary, <<1, 2, 3>>}]} = next_frames(conn)
      WSMint.close(conn)
    end

    test "the server closing TCP without a close frame surfaces as :closed" do
      server = WSTestServer.start([{:sleep, 20}, :close_tcp])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {_conn, frames} = next_frames(conn)
      assert List.last(frames) == :closed
      WSMint.close(conn)
    end

    test "a socket error message is an error" do
      server = WSTestServer.start([])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      assert {:error, _conn, _reason} =
               WSMint.handle_message(conn, {:tcp_error, socket, :econnreset})

      WSMint.close(conn)
    end

    test "send_frame/2 on a closed connection is an error, not a raise" do
      server = WSTestServer.start([])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      WSMint.close(conn)
      assert {:error, _conn, _reason} = WSMint.send_frame(conn, {:text, "late"})
    end

    test "a malformed server frame is an error, not a frame" do
      # Opcode 3 is reserved by RFC 6455.
      server = WSTestServer.start([{:sleep, 20}, {:raw, <<0x83, 0x01, ?x>>}])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert {:error, _conn, _reason} = next(conn)
      WSMint.close(conn)
    end

    test "a message that is not this connection's is :unknown" do
      server = WSTestServer.start([])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      assert WSMint.handle_message(conn, {:something, :else}) == :unknown
      WSMint.close(conn)
    end

    test "send_frame/2 delivers a masked text frame the server reads back" do
      server = WSTestServer.start([:recv])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      assert {:handshake, _, _} = server_event(server)

      assert {:ok, _conn} = WSMint.send_frame(conn, {:text, ~s({"text":"Hi"})})
      assert {:frame, {:text, ~s({"text":"Hi"})}} = server_event(server)
      WSMint.close(conn)
    end
  end

  describe "close/1 and flush_messages/1" do
    test "close/1 called twice returns :ok both times and raises nothing" do
      server = WSTestServer.start([])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])

      assert WSMint.close(conn) == :ok
      assert WSMint.close(conn) == :ok
    end

    test "close/1 sends a close frame the server observes" do
      server = WSTestServer.start([])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      assert {:handshake, _, _} = server_event(server)

      WSMint.close(conn)
      assert {:frame, {:close, 1000, ""}} = server_event(server)
    end

    test "after close/1 and flush_messages/1 the mailbox holds no :tcp message for the socket" do
      # The pause keeps the frames out of the handshake's own TCP read.
      frames = for i <- 1..5, do: {:send, {:text, "frame #{i}"}}
      server = WSTestServer.start([{:sleep, 50} | frames])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      # Premise guard: a transport message for this socket is queued, so the
      # refutes below are not vacuous.
      assert_wait(fn -> tcp_message_queued?(socket) end)

      WSMint.close(conn)
      WSMint.flush_messages(conn)

      refute_received {:tcp, ^socket, _}
      refute_received {:tcp_closed, ^socket}
      refute_received {:tcp_error, ^socket, _}
    end

    test "flush_messages/1 also drains a queued :tcp_closed" do
      server = WSTestServer.start([:close_tcp])
      {:ok, conn} = WSMint.connect(WSTestServer.url(server), [], [])
      socket = WSMint.message_tag(conn)

      assert_wait(fn ->
        {:messages, messages} = Process.info(self(), :messages)
        Enum.member?(messages, {:tcp_closed, socket})
      end)

      WSMint.close(conn)
      WSMint.flush_messages(conn)
      refute_received {:tcp_closed, ^socket}
    end
  end

  # Removes and returns every transport message of `socket` in the
  # mailbox, in arrival order.
  defp take_messages(socket, acc \\ []) do
    receive do
      message when WebSocket.is_transport_message(message, socket) ->
        take_messages(socket, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tcp_message_queued?(socket) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.any?(messages, &match?({:tcp, ^socket, _}, &1))
  end

  defp assert_wait(fun, deadline \\ 2_000) do
    cond do
      fun.() ->
        :ok

      deadline <= 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        assert_wait(fun, deadline - 10)
    end
  end
end
