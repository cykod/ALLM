defmodule ALLM.ChatTest do
  @moduledoc """
  Facade-level tests for `ALLM.chat/3` (spec §4, §10.5). Pure one-line
  delegation to `ALLM.Chat.run/3` — these tests assert that delegation,
  plus the happy path + pre-flight error surface. Doctest is registered
  on this module so the `@doc` example runs as part of the test suite.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, Engine, Thread, Tool}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  doctest ALLM, only: [chat: 3]

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

  describe "chat/3 — happy paths" do
    test "single-turn text returns {:ok, %ChatResult{halted_reason: :completed}}" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} = ALLM.chat(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 1
    end

    test "two-turn tool-call → text returns {:ok, %ChatResult{}} with two steps" do
      engine =
        FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} = ALLM.chat(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 2
    end

    test "accepts list-of-messages input (normalised via Thread.from_messages/1)" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} = ALLM.chat(engine, [ALLM.user("hi")])
      assert result.halted_reason == :completed
    end
  end

  describe "chat/3 — pre-flight errors" do
    test "returns {:error, %EngineError{reason: :missing_adapter}} when adapter is nil" do
      engine = Engine.new()
      assert {:error, %EngineError{reason: :missing_adapter}} = ALLM.chat(engine, user_thread())
    end
  end

  describe "chat/3 — delegation invariant" do
    # Fake's default per-process script cursor is keyed by
    # `:erlang.phash2(scripts)` — running facade + internal calls
    # sequentially in the same test process with content-equal scripts
    # would collide. Each call runs in its own `Task.async/1` so the
    # process-dict cursors stay isolated.
    test "ALLM.chat/3 and ALLM.Chat.run/3 return equal results for identical inputs" do
      thread = user_thread()

      build_engine = fn ->
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )
      end

      r_facade =
        Task.async(fn -> ALLM.chat(build_engine.(), thread) end)
        |> Task.await()

      r_internal =
        Task.async(fn -> Chat.run(build_engine.(), thread) end)
        |> Task.await()

      assert {:ok, _} = r_facade
      assert r_facade == r_internal
    end

    test "delegation preserves opts (max_turns: 1 surfaces as halted_reason :max_turns)" do
      thread = user_thread()

      build_engine = fn ->
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "echo", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [echo_tool()]
        )
      end

      r_facade =
        Task.async(fn -> ALLM.chat(build_engine.(), thread, max_turns: 1) end)
        |> Task.await()

      r_internal =
        Task.async(fn -> Chat.run(build_engine.(), thread, max_turns: 1) end)
        |> Task.await()

      assert {:ok, %ChatResult{halted_reason: :max_turns}} = r_facade
      assert r_facade == r_internal
    end
  end
end
