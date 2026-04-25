defmodule ALLM.StreamTest do
  @moduledoc """
  Facade-level tests for `ALLM.stream/3` (spec §4, §10.6). Pure one-line
  delegation to `ALLM.Chat.stream/3`. Doctest is registered on this
  module so the `@doc` example runs as part of the test suite (and
  asserts exactly one `:chat_completed`).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, Engine, Thread, Tool}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  doctest ALLM, only: [stream: 3]

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp tool_call_then_text_scripts do
    [
      [
        {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
        {:finish, :tool_calls}
      ],
      [{:text, "done"}, {:finish, :stop}]
    ]
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  describe "stream/3 — happy paths" do
    test "single-turn text emits exactly one :chat_completed event" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, stream} = ALLM.stream(engine, user_thread())
      events = Enum.to_list(stream)

      assert Enum.count(events, &match?({:chat_completed, _}, &1)) == 1
      {:chat_completed, %{result: %ChatResult{halted_reason: :completed}}} = List.last(events)
    end

    test "two-turn tool-call → text emits exactly one terminal :chat_completed" do
      engine =
        FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      assert {:ok, stream} = ALLM.stream(engine, user_thread())
      events = Enum.to_list(stream)

      assert Enum.count(events, &match?({:chat_completed, _}, &1)) == 1
      assert match?({:chat_completed, _}, List.last(events))
    end

    test "accepts list-of-messages input" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, stream} = ALLM.stream(engine, [ALLM.user("hi")])
      events = Enum.to_list(stream)
      assert Enum.count(events, &match?({:chat_completed, _}, &1)) == 1
    end
  end

  describe "stream/3 — pre-flight errors" do
    test "returns {:error, %EngineError{reason: :missing_adapter}} when adapter is nil" do
      engine = Engine.new()

      assert {:error, %EngineError{reason: :missing_adapter}} =
               ALLM.stream(engine, user_thread())
    end
  end

  describe "stream/3 — delegation invariant" do
    # Cursor isolation: same pattern as allm_step_test.exs / allm_chat_test.exs.
    test "ALLM.stream/3 and ALLM.Chat.stream/3 produce identical event sequences" do
      thread = user_thread()

      build_engine = fn ->
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )
      end

      events_facade =
        Task.async(fn ->
          {:ok, stream} = ALLM.stream(build_engine.(), thread)
          Enum.to_list(stream)
        end)
        |> Task.await()

      events_internal =
        Task.async(fn ->
          {:ok, stream} = Chat.stream(build_engine.(), thread)
          Enum.to_list(stream)
        end)
        |> Task.await()

      assert events_facade == events_internal
    end
  end
end
