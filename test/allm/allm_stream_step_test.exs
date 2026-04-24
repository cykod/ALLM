defmodule ALLM.StreamStepTest do
  @moduledoc """
  Facade-level tests for `ALLM.stream_step/3` (spec §4, §10.4). Pure
  one-line delegation to `ALLM.Chat.stream_step/3`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, Engine, Thread, Tool}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake

  doctest ALLM, only: [stream_step: 3]

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp single_tool_call_engine do
    Engine.new(
      adapter: Fake,
      adapter_opts: [
        script: [
          {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
          {:finish, :tool_calls}
        ]
      ],
      tools: [echo_tool()]
    )
  end

  defp plain_text_engine do
    Engine.new(
      adapter: Fake,
      adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  describe "stream_step/3 — happy paths" do
    test "returns {:ok, stream} ending in one :step_completed event" do
      {:ok, stream} = ALLM.stream_step(single_tool_call_engine(), user_thread())
      events = Enum.to_list(stream)
      assert List.last(events) |> elem(0) == :step_completed
      assert Enum.count(events, &match?({:step_completed, _}, &1)) == 1
    end

    test "accepts list-of-messages input" do
      {:ok, stream} = ALLM.stream_step(plain_text_engine(), [ALLM.user("hi")])
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?({:step_completed, _}, &1))
    end
  end

  describe "stream_step/3 — pre-flight errors" do
    test "returns {:error, %EngineError{reason: :missing_adapter}} when adapter is nil" do
      engine = Engine.new()

      assert {:error, %EngineError{reason: :missing_adapter}} =
               ALLM.stream_step(engine, user_thread())
    end
  end

  describe "stream_step/3 — delegation invariant" do
    # Isolate Fake's per-process cursor via Task.async — the two calls
    # use content-equal scripts that would collide on a shared process
    # dictionary cursor.
    test "ALLM.stream_step/3 and ALLM.Chat.stream_step/3 emit the same events" do
      thread = user_thread()

      facade_events =
        Task.async(fn ->
          {:ok, stream} = ALLM.stream_step(plain_text_engine(), thread)
          Enum.to_list(stream)
        end)
        |> Task.await()

      internal_events =
        Task.async(fn ->
          {:ok, stream} = Chat.stream_step(plain_text_engine(), thread)
          Enum.to_list(stream)
        end)
        |> Task.await()

      assert facade_events == internal_events
    end
  end
end
