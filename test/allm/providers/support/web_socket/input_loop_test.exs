defmodule ALLM.Providers.Support.WebSocket.InputLoopTest do
  @moduledoc """
  Direct tests of `ALLM.Providers.Support.WebSocket.InputLoop` over
  `ALLM.Test.WebSocketStub`. The loop's composition with a real adapter
  (halt-safety, timers reset by pump messages, the keep-alive) is bound by
  `elevenlabs/speech_stream_test.exs` and
  `elevenlabs/transcription_stream_test.exs`; these rows pin the
  deadline arithmetic and the selective receive on their own.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.WebSocket.InputLoop
  alias ALLM.Test.WebSocketStub

  defp loop(stream_timeout, keepalive_ms, script \\ []) do
    stub = WebSocketStub.install(script)
    {:ok, conn} = WebSocketStub.connect("ws://stub", [], ws_stub: stub)
    {stub, %{InputLoop.loop_state(WebSocketStub, stream_timeout, keepalive_ms) | conn: conn}}
  end

  describe "next_message/1 deadlines" do
    test "keepalive_ms: :infinity leaves only the silence deadline" do
      {_stub, state} = loop(50, :infinity)

      assert :wake = InputLoop.next_message(state)
      assert InputLoop.timed_out?(state)
    end

    test "a keep-alive deadline shorter than the silence one wakes without timing out" do
      {_stub, state} = loop(5_000, 20)

      assert :wake = InputLoop.next_message(state)
      refute InputLoop.timed_out?(state)
    end

    test "after the end of input the keep-alive no longer wakes the loop" do
      {_stub, state} = loop(60, 10)
      state = %{state | input_done?: true}

      assert :wake = InputLoop.next_message(state)
      assert InputLoop.timed_out?(state)
    end

    test "stream_timeout: :infinity never times out" do
      {_stub, state} = loop(:infinity, 10)

      assert :wake = InputLoop.next_message(state)
      refute InputLoop.timed_out?(state)
    end
  end

  describe "next_message/1 selection" do
    test "a transport message is returned and resets the silence clock; other messages stay" do
      {_stub, state} = loop(1_000, :infinity, [{:after_client, :any, [{:text, "hi"}]}])
      send(self(), :unrelated)
      past = System.monotonic_time(:millisecond) - 1_000_000
      {:ok, state} = InputLoop.send_json(%{state | last_activity: past}, %{"a" => 1})

      assert {:transport, message, state} = InputLoop.next_message(state)
      assert state.last_activity > past
      assert {:ok, _state, [{:text, "hi"}]} = InputLoop.handle_transport(state, message)
      assert_received :unrelated
    end

    # Falsifier: an InputPump.stop/2 that no longer drains leaves "b" (and
    # :input_done) in the mailbox.
    test "pump messages are classified, and stop_pump/1 drains them" do
      {_stub, state} = loop(1_000, :infinity)
      state = InputLoop.start_pump(state, ["a", "b"], [])
      {_pid, ref} = state.pump

      assert {:pump, {:input, "a"}, state} = InputLoop.next_message(state)
      # "b" is already in the mailbox, unconsumed, so the drain has a subject.
      assert wait_for_mailbox(&match?({^ref, {:input, "b"}}, &1), 1_000)

      state = InputLoop.stop_pump(state)
      assert state.pump == nil
      refute_received {^ref, _}
      assert InputLoop.stop_pump(state) == state
    end
  end

  describe "wake_at" do
    test "an adapter deadline wakes the loop without timing out, and nil clears it" do
      {_stub, state} = loop(5_000, :infinity)
      state = %{state | wake_at: System.monotonic_time(:millisecond) + 20}

      assert :wake = InputLoop.next_message(state)
      refute InputLoop.timed_out?(state)
      assert InputLoop.loop_state(WebSocketStub, 1, 1).wake_at == nil
    end
  end

  describe "send_json/2 and close_loop/1" do
    test "send_json/2 records the frame and restarts the keep-alive clock" do
      {stub, state} = loop(1_000, :infinity)
      past = System.monotonic_time(:millisecond) - 1_000_000
      {:ok, state} = InputLoop.send_json(%{state | last_sent: past}, %{"text" => "x"})

      assert state.last_sent > past
      assert WebSocketStub.sent_frames(stub) == [{:text, ~s({"text":"x"})}]
    end

    test "a failed send returns the transport's raw cause" do
      stub = WebSocketStub.install([], send_error: :any)
      {:ok, conn} = WebSocketStub.connect("ws://stub", [], ws_stub: stub)
      state = %{InputLoop.loop_state(WebSocketStub, 1_000, :infinity) | conn: conn}

      assert {:error, _state, :closed} = InputLoop.send_json(state, %{})
    end

    # Falsifier: an after function that closes without flushing leaves the
    # socket's late message in the mailbox.
    test "close_loop/1 closes the socket and flushes its messages, and is a no-op without a connection" do
      {stub, state} = loop(1_000, :infinity)
      tag = WebSocketStub.message_tag(state.conn)
      send(self(), {WebSocketStub, tag, {:text, "late"}})
      send(self(), :unrelated)

      assert InputLoop.close_loop(state) == :ok
      assert WebSocketStub.close_count(stub) == 1
      refute_received {WebSocketStub, ^tag, _}
      assert_received :unrelated
      assert InputLoop.close_loop(InputLoop.loop_state(WebSocketStub, 1, 1)) == :ok
    end
  end

  # Polls the mailbox without consuming it.
  defp wait_for_mailbox(match?, budget) do
    {:messages, messages} = Process.info(self(), :messages)

    cond do
      Enum.any?(messages, match?) -> true
      budget <= 0 -> false
      true -> Process.sleep(5) && wait_for_mailbox(match?, budget - 5)
    end
  end
end
