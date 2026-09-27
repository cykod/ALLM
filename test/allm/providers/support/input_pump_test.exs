defmodule ALLM.Providers.Support.InputPumpTest do
  @moduledoc """
  Composition behaviours 2–7 of `ALLM.Providers.Support.InputPump`, one
  named test each (behaviour 1 needs a socket-owning resource and lives with
  the WebSocket adapter's tests), plus the message protocol and `stop/2`'s
  idempotence.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.OpenAITestFixtures
  alias ALLM.Providers.Support.InputPump
  alias ALLM.Test.FinchStub

  doctest InputPump

  # Poll until `fun` is true, for at most `ms` milliseconds.
  defp eventually(fun, ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(5)
        do_eventually(fun, deadline)
    end
  end

  # An input that links a sleeping process to whoever reduces it, then
  # yields that pid forever.
  defp linked_sleeper_input do
    Stream.resource(
      fn -> spawn_link(fn -> Process.sleep(:infinity) end) end,
      fn pid -> {[pid], pid} end,
      fn _ -> :ok end
    )
  end

  describe "message protocol" do
    test "delivers each element, then :input_done, then a :normal :DOWN" do
      {pid, ref} = InputPump.start(["a", "b"], self(), 8)

      assert_receive {^ref, {:input, "a"}}
      assert_receive {^ref, {:input, "b"}}
      assert_receive {^ref, :input_done}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "the pump is not linked to the process that starts it" do
      {pid, ref} = InputPump.start(linked_sleeper_input(), self(), 1)
      assert_receive {^ref, {:input, _}}

      {:links, links} = Process.info(self(), :links)
      refute pid in links

      InputPump.stop(pid, ref)
    end
  end

  describe "is_pump_message/2 and classify/2" do
    require InputPump

    test "classify/2 names each pump message the owner receives" do
      {pid, ref} = InputPump.start(["a"], self(), 8)
      assert_receive {^ref, {:input, "a"}} = m1
      assert_receive {^ref, :input_done} = m2
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert InputPump.classify(m1, ref) == {:input, "a"}
      assert InputPump.classify(m2, ref) == :done

      {_pid, ref} = InputPump.start(Stream.map([1], fn _ -> raise "kaboom" end), self(), 8)
      assert_receive {^ref, {:input_error, _}} = m3, 1_000
      assert {:failed, :input_raised, %{kind: :error, message: msg}} = InputPump.classify(m3, ref)
      assert msg =~ "kaboom"

      down = {:DOWN, ref, :process, self(), {:crash, self()}}

      assert {:failed, :input_crashed, %{kind: :exit, message: "** (exit) {:crash, #PID<" <> _}} =
               InputPump.classify(down, ref)
    end

    test "is_pump_message/2 admits only this ref's messages" do
      ref = make_ref()
      other = make_ref()
      pump? = fn m -> InputPump.is_pump_message(m, ref) end

      assert pump?.({ref, :input_done})
      assert pump?.({:DOWN, ref, :process, self(), :boom})
      refute pump?.({other, :input_done})
      refute pump?.({:DOWN, other, :process, self(), :boom})
      refute pump?.({:ssl, :sock, "data"})
      refute pump?.(:not_a_tuple)
      refute pump?.({ref, :a, :b})
    end
  end

  describe "composition behaviour 2" do
    test "an input that raises becomes a string-only :input_error and the owner survives" do
      input = Stream.map([1], fn _ -> raise ArgumentError, "bad chunk source" end)
      {pid, ref} = InputPump.start(input, self(), 8)

      assert_receive {^ref, {:input_error, %{kind: :error, message: message}}}, 1_000
      assert message =~ "ArgumentError"
      assert message =~ "bad chunk source"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Process.alive?(self())
    end

    test "a throw and an exit inside the input are reported with their kind" do
      {_pid, ref} = InputPump.start(Stream.map([1], fn _ -> throw(:oops) end), self(), 8)
      assert_receive {^ref, {:input_error, %{kind: :throw, message: message}}}, 1_000
      assert message =~ ":oops"

      {_pid, ref} = InputPump.start(Stream.map([1], fn _ -> exit(:gone) end), self(), 8)
      assert_receive {^ref, {:input_error, %{kind: :exit, message: message}}}, 1_000
      assert message =~ ":gone"
    end
  end

  describe "composition behaviour 3" do
    test "stop/2 kills the pump and every process linked to it, and leaves the owner's mailbox clean" do
      {pid, ref} = InputPump.start(linked_sleeper_input(), self(), 1)

      # Wait for the first element without consuming it, so stop/2 has a
      # real pump message to drain.
      assert eventually(fn -> match?({:messages, [_ | _]}, Process.info(self(), :messages)) end)
      {:links, linked} = Process.info(pid, :links)
      assert length(linked) >= 2, "premise: the watchdog and the input's process are linked"

      assert :ok = InputPump.stop(pid, ref)

      assert eventually(fn -> not Enum.any?([pid | linked], &Process.alive?/1) end)
      refute_received {^ref, _}
      refute_received {:DOWN, ^ref, :process, _, _}
      assert Process.alive?(self())
    end

    test "stop/2 is idempotent, including after the pump finished on its own" do
      {pid, ref} = InputPump.start(["a"], self(), 8)
      assert_receive {^ref, :input_done}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert :ok = InputPump.stop(pid, ref)
      assert :ok = InputPump.stop(pid, ref)
      refute_received {^ref, _}
    end
  end

  describe "composition behaviour 4" do
    test "at most window elements are unacknowledged" do
      {pid, ref} = InputPump.start(1..1000, self(), 8)

      for n <- 1..8, do: assert_receive({^ref, {:input, ^n}})
      refute_receive {^ref, {:input, _}}, 100

      :ok = InputPump.ack(pid, ref)
      assert_receive {^ref, {:input, 9}}
      refute_receive {^ref, {:input, _}}, 50

      InputPump.stop(pid, ref)
      refute_received {^ref, _}
    end
  end

  describe "composition behaviour 5" do
    test "a killed consumer takes the pump down through the watchdog" do
      test_pid = self()

      consumer =
        spawn(fn ->
          {pid, _ref} = InputPump.start(Stream.repeatedly(fn -> :tick end), self(), 1)
          send(test_pid, {:pump, pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:pump, pump}
      assert Process.alive?(pump)

      Process.exit(consumer, :kill)
      assert eventually(fn -> not Process.alive?(pump) end)
    end
  end

  describe "composition behaviour 6" do
    test "an ALLM.stream_generate/3 input is reduced by the pump, whose Finch messages never reach the owner" do
      agent =
        FinchStub.install_shared(OpenAITestFixtures.stream_chunks(:happy_text_stream),
          delay_ms: 100
        )

      engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4o-mini")

      {:ok, chat} =
        ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: agent
        )

      {pump, ref} = InputPump.start(chat, self(), 1)

      assert_receive {^ref, {:input, {:message_started, _}}}, 1_000
      assert [sender] = FinchStub.senders(agent)
      {:links, links} = Process.info(pump, :links)
      assert sender in links, "the stub's sender must be linked to the async_request/3 caller"

      :ok = InputPump.ack(pump, ref)
      events = collect(pump, ref, [])
      assert Enum.any?(events, &match?({:text_delta, _}, &1))
      assert List.last(events) |> elem(0) == :message_completed

      refute_received {_, {:status, _}}
      refute_received {_, {:headers, _}}
      refute_received {_, {:data, _}}
      refute_received {_, :done}
    end

    test "halting the pump mid-request kills the linked sender" do
      agent =
        FinchStub.install_shared(OpenAITestFixtures.stream_chunks(:happy_text_stream),
          delay_ms: 1_000
        )

      engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4o-mini")

      {:ok, chat} =
        ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: agent
        )

      {pump, ref} = InputPump.start(chat, self(), 1)
      assert_receive {^ref, {:input, {:message_started, _}}}, 1_000
      [sender] = FinchStub.senders(agent)

      InputPump.stop(pump, ref)
      assert eventually(fn -> not Process.alive?(sender) end)
    end
  end

  describe "FinchStub install modes" do
    test "the default install/2 mode is unchanged: frames go to the installer, and only the installer may call" do
      ref = FinchStub.install(["chunk"], [])
      assert ^ref = FinchStub.async_request(:req, ALLM.Finch, finch_stub_ref: ref)

      assert_receive {^ref, {:status, 200}}
      assert_receive {^ref, {:data, "chunk"}}
      assert_receive {^ref, :done}

      task =
        Task.async(fn ->
          catch_error(FinchStub.async_request(:req, ALLM.Finch, finch_stub_ref: ref))
        end)

      assert %RuntimeError{message: "no stub installed for ref"} = Task.await(task)
    end

    test "install_shared/2 delivers to whichever process calls async_request/3, from a linked sender" do
      agent = FinchStub.install_shared(["chunk"], delay_ms: 200)
      test_pid = self()

      spawn(fn ->
        ref = FinchStub.async_request(:req, ALLM.Finch, finch_stub_ref: agent)
        {:links, links} = Process.info(self(), :links)
        send(test_pid, {:caller_links, links})

        receive do
          {^ref, {:data, chunk}} -> send(test_pid, {:caller_got, chunk})
        end

        :ok = FinchStub.cancel_async_request(ref)
        send(test_pid, :cancelled)
      end)

      assert_receive {:caller_links, links}
      assert [sender] = FinchStub.senders(agent)
      assert sender in links
      assert_receive {:caller_got, "chunk"}, 1_000
      refute_received {_, {:data, _}}
      assert FinchStub.captured_opts(agent) == [finch_stub_ref: agent]
      assert_receive :cancelled
      assert FinchStub.cancel_count(agent) == 1
    end
  end

  describe "composition behaviour 7" do
    test "a process linked inside the input that exits :boom kills the pump, not the owner" do
      input =
        Stream.resource(
          fn -> spawn_link(fn -> exit(:boom) end) end,
          fn pid ->
            receive do
            after
              :infinity -> {[pid], pid}
            end
          end,
          fn _ -> :ok end
        )

      {pid, ref} = InputPump.start(input, self(), 8)

      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}
      assert Process.alive?(self())
      assert InputPump.crash_info(:boom) == %{kind: :exit, message: "** (exit) :boom"}
    end
  end

  defp collect(pump, ref, acc) do
    receive do
      {^ref, {:input, event}} ->
        InputPump.ack(pump, ref)
        collect(pump, ref, [event | acc])

      {^ref, :input_done} ->
        InputPump.stop(pump, ref)
        Enum.reverse(acc)
    after
      5_000 -> flunk("pump did not finish: #{inspect(Enum.reverse(acc))}")
    end
  end
end
