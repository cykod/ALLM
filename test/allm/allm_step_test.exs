defmodule ALLM.StepTest do
  @moduledoc """
  Facade-level tests for `ALLM.step/3` (spec §4, §10.3). Pure one-line
  delegation to `ALLM.Chat.step/3` — these tests assert that delegation,
  plus the happy path + pre-flight error surface.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, Engine, StepResult, Thread, Tool}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake

  doctest ALLM, only: [step: 3]

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

  describe "step/3 — happy paths" do
    test "returns {:ok, %StepResult{}} for a Fake-backed engine with a single tool call" do
      assert {:ok, %StepResult{} = sr} = ALLM.step(single_tool_call_engine(), user_thread())
      assert sr.done? == false
      assert length(sr.tool_results) == 1
    end

    test "accepts list-of-messages input (normalised via Thread.from_messages/1)" do
      assert {:ok, %StepResult{} = sr} = ALLM.step(plain_text_engine(), [ALLM.user("hi")])
      assert sr.done? == true
      # Thread shape: [user, assistant]
      assert length(sr.thread.messages) == 2
    end
  end

  describe "step/3 — pre-flight errors" do
    test "returns {:error, %EngineError{reason: :missing_adapter}} when adapter is nil" do
      engine = Engine.new()
      assert {:error, %EngineError{reason: :missing_adapter}} = ALLM.step(engine, user_thread())
    end
  end

  describe "step/3 — delegation invariant" do
    # Fake's default per-process script cursor is keyed by
    # `:erlang.phash2(scripts)` — running facade + internal calls
    # sequentially in the same test process with content-equal scripts
    # would collide. Each call runs in its own `Task.async/1` so the
    # process-dict cursors stay isolated.
    test "ALLM.step/3 and ALLM.Chat.step/3 return equal results for identical inputs" do
      thread = user_thread()

      sr_facade =
        Task.async(fn -> ALLM.step(plain_text_engine(), thread) end)
        |> Task.await()

      sr_internal =
        Task.async(fn -> Chat.step(plain_text_engine(), thread) end)
        |> Task.await()

      assert {:ok, _} = sr_facade
      assert sr_facade == sr_internal
    end

    test "delegation preserves opts (mode: :manual surfaces tool calls without executing)" do
      thread = user_thread()

      sr_facade =
        Task.async(fn -> ALLM.step(single_tool_call_engine(), thread, mode: :manual) end)
        |> Task.await()

      sr_internal =
        Task.async(fn -> Chat.step(single_tool_call_engine(), thread, mode: :manual) end)
        |> Task.await()

      assert {:ok, %StepResult{metadata: %{mode: :manual}, tool_results: []}} = sr_facade
      assert sr_facade == sr_internal
    end
  end
end
