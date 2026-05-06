defmodule ALLM.Chat.PerToolManualTest do
  @moduledoc """
  Phase 18.2 — non-streaming `Chat.run/3` and `Chat.step/3` partition coverage.

  Five-cell matrix (mode × tool flags × response.tool_calls) plus error/edge
  paths. `mode: :manual` whole-loop short-circuit MUST keep winning over
  per-tool flags (Decision #5/#13). Pure-auto path MUST be byte-identical to
  the existing path (zero-behavior-change invariant).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, StepResult, Thread, Tool, ToolCall}
  alias ALLM.Error.{AdapterError, EngineError}
  alias ALLM.Test.FakeFixtures

  # ---------------------------------------------------------------------------
  # Tool fixtures
  # ---------------------------------------------------------------------------

  defp weather_tool do
    Tool.new(
      name: "weather",
      description: "",
      schema: %{},
      handler: fn _args -> {:ok, %{forecast: "sunny"}} end
    )
  end

  defp manual_charge_tool do
    Tool.new(
      name: "charge",
      description: "",
      schema: %{},
      handler: fn _args -> {:ok, "should not run"} end,
      manual: true
    )
  end

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  # ---------------------------------------------------------------------------
  # Cell 1 — :auto, all manual: false, 1 call → existing path
  # ---------------------------------------------------------------------------

  describe "Cell 1: :auto, all manual: false (existing pure-auto path)" do
    test "Chat.step/3 returns done?: false; metadata.manual_tool_calls absent" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "weather", arguments: %{"city" => "Boston"}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool()]
        )

      assert {:ok, %StepResult{} = sr} = Chat.step(engine, user_thread())
      refute Map.has_key?(sr.metadata, :manual_tool_calls)
      assert sr.metadata == %{}
      assert length(sr.tool_results) == 1
      assert hd(sr.tool_results).role == :tool
    end

    test "Chat.run/3 completes the loop normally to :completed" do
      scripts = [
        [
          {:tool_call, id: "c0", name: "weather", arguments: %{"city" => "Boston"}},
          {:finish, :tool_calls}
        ],
        [{:text, "It is sunny."}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [weather_tool()])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 2
      refute Map.has_key?(result.metadata, :manual_tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 2 — :auto, mixed bucket → auto runs, halt with manual pending
  # ---------------------------------------------------------------------------

  describe "Cell 2: :auto, mixed bucket" do
    test "Chat.step/3 runs auto tools and surfaces only the manual call" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %StepResult{} = sr} = Chat.step(engine, user_thread())

      # Auto bucket ran — exactly one tool message in the thread for "weather".
      assert [%ToolCall{id: "cm", name: "charge"}] = sr.metadata.manual_tool_calls
      refute Map.has_key?(sr.metadata, :mode)

      tool_msgs = Enum.filter(sr.thread.messages, &(&1.role == :tool))
      assert length(tool_msgs) == 1
      assert hd(tool_msgs).tool_call_id == "ca"
      # Auto-bucket result is appended; manual bucket has NO :tool message yet.
      refute Enum.any?(tool_msgs, &(&1.tool_call_id == "cm"))

      # tool_results carries only the auto-bucket messages.
      assert length(sr.tool_results) == 1
      assert hd(sr.tool_results).tool_call_id == "ca"
    end

    test "Chat.run/3 halts with :manual_tool_calls; metadata.manual_tool_calls populated" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :manual_tool_calls
      assert [%ToolCall{id: "cm", name: "charge"}] = result.metadata.manual_tool_calls
      assert result.metadata.manual_turn_index == 0
      # Whole-loop's :mode key is NOT set on per-tool path.
      refute Map.has_key?(result.metadata, :mode)
      assert length(result.steps) == 1
    end

    test "preserves input order within the manual bucket" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "m1", name: "charge", arguments: %{"amount" => 1}},
            {:tool_call, id: "ca", name: "weather", arguments: %{}},
            {:tool_call, id: "m2", name: "charge", arguments: %{"amount" => 2}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())

      ids = Enum.map(result.metadata.manual_tool_calls, & &1.id)
      assert ids == ["m1", "m2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 3 — :auto, all manual: true → pure-manual halt; no tool executed
  # ---------------------------------------------------------------------------

  describe "Cell 3: :auto, all manual: true (pure-manual)" do
    test "Chat.step/3 produces done?: false, metadata.manual_tool_calls populated, no tool runs" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      assert {:ok, %StepResult{} = sr} = Chat.step(engine, user_thread())
      assert [%ToolCall{id: "cm", name: "charge"}] = sr.metadata.manual_tool_calls
      refute Map.has_key?(sr.metadata, :mode)
      assert sr.tool_results == []
      refute sr.done?

      # Assistant message is appended; no :tool messages.
      tool_msgs = Enum.filter(sr.thread.messages, &(&1.role == :tool))
      assert tool_msgs == []
      last = List.last(sr.thread.messages)
      assert last.role == :assistant
    end

    test "Chat.run/3 halts with :manual_tool_calls and no :mode metadata" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :manual_tool_calls
      assert [%ToolCall{id: "cm"}] = result.metadata.manual_tool_calls
      assert result.metadata.manual_turn_index == 0
      refute Map.has_key?(result.metadata, :mode)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 4 — :manual, mixed bucket → whole-loop wins, ALL calls surfaced
  # ---------------------------------------------------------------------------

  describe "Cell 4: :manual, mixed bucket (whole-loop wins per Decision #5)" do
    test "Chat.run/3 ignores per-tool flags; metadata.mode == :manual; ALL calls in response" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), mode: :manual)

      assert result.halted_reason == :manual_tool_calls
      assert result.metadata == %{manual_turn_index: 0}
      # Whole-loop path: per-tool metadata key NOT set.
      refute Map.has_key?(result.metadata, :manual_tool_calls)
      # ALL tool calls (auto + manual) surface on the response.
      assert length(result.final_response.tool_calls) == 2
      # No tool ran (whole-loop manual short-circuits before any execution).
      assert hd(result.steps).tool_results == []
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 5 — :manual, all manual: false → existing whole-loop path verbatim
  # ---------------------------------------------------------------------------

  describe "Cell 5: :manual, all manual: false (existing whole-loop verbatim)" do
    test "Chat.run/3 halts with :manual_tool_calls and only :manual_turn_index metadata" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [echo_tool()]
        )

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), mode: :manual)

      assert result.halted_reason == :manual_tool_calls
      assert result.metadata == %{manual_turn_index: 0}
      refute Map.has_key?(result.metadata, :manual_tool_calls)
      assert hd(result.steps).tool_results == []
    end
  end

  # ---------------------------------------------------------------------------
  # Edge: unknown-tool name routes through preflight unchanged
  # ---------------------------------------------------------------------------

  describe "edge: unknown-tool name (preflight wins before partition)" do
    test "Chat.step/3 returns {:error, %EngineError{reason: :unknown_tool}}" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cu", name: "missing", arguments: %{}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      assert {:error, %EngineError{reason: :unknown_tool} = err} =
               Chat.step(engine, user_thread())

      assert err.metadata.tool_name == "missing"
    end

    test "Chat.run/3 surfaces the same {:error, _} engine error" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cu", name: "missing", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool()]
        )

      assert {:error, %EngineError{reason: :unknown_tool}} =
               Chat.run(engine, user_thread())
    end
  end

  # ---------------------------------------------------------------------------
  # Edge: empty response.tool_calls is a no-op (terminal step)
  # ---------------------------------------------------------------------------

  describe "edge: empty response.tool_calls" do
    test "no partition runs; falls through to terminal text step" do
      engine = FakeFixtures.engine([{:text, "hello"}, {:finish, :stop}])

      assert {:ok, %StepResult{} = sr} = Chat.step(engine, user_thread())
      assert sr.done?
      refute Map.has_key?(sr.metadata, :manual_tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge: multi-turn — turn 1 mixed-bucket halts; caller appends :tool message
  # for the manual id; turn 2 chat/3 with augmented thread completes.
  # ---------------------------------------------------------------------------

  describe "edge: multi-turn mixed-bucket flow with caller-appended tool result" do
    test "turn 2 Chat.run/3 completes after caller resolves the manual call" do
      # Turn 1 — mixed bucket; auto runs, halt with manual pending.
      engine_1 =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %ChatResult{halted_reason: :manual_tool_calls} = r1} =
               Chat.run(engine_1, user_thread())

      assert [%ToolCall{id: "cm"}] = r1.metadata.manual_tool_calls

      # Caller appends a :tool message resolving the manual id "cm".
      tool_msg = %ALLM.Message{
        role: :tool,
        content: "approved",
        tool_call_id: "cm"
      }

      augmented_thread = Thread.add_message(r1.thread, tool_msg)

      # Turn 2 — fresh engine scripted with a single text completion.
      engine_2 = FakeFixtures.engine([{:text, "done"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = r2} = Chat.run(engine_2, augmented_thread)
      assert r2.halted_reason == :completed
      assert r2.final_response.output_text == "done"
    end
  end

  # ---------------------------------------------------------------------------
  # Edge: Mixed-bucket footgun — naive re-issue without appending tool messages
  # for manual ids surfaces a Validate.thread/1 or AdapterError. (Decision #4.)
  # ---------------------------------------------------------------------------

  describe "edge: mixed-bucket footgun (naive re-issue surfaces a clear error)" do
    # Per Decision #4: naive re-issue of `chat/3` on `result.thread` without
    # appending `:tool` messages for the manual ids sends a malformed request
    # (assistant tool_calls with no matching tool results for some ids).
    # Real providers reject with `%AdapterError{reason: :invalid_request}`.
    # The Fake adapter doesn't validate wire shape, so this test asserts the
    # structural footgun is detectable from `result.thread` alone — callers
    # CAN guard against it before re-issuing chat/3 by walking the trailing
    # assistant message's tool_calls and confirming each has a matching tool
    # message later in the thread.
    test "result.thread has assistant tool_calls without matching tool messages for manual ids" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %ChatResult{halted_reason: :manual_tool_calls} = r1} =
               Chat.run(engine, user_thread())

      # The footgun: scan for assistant tool_call ids and check coverage by
      # subsequent :tool messages. The manual id "cm" is uncovered.
      assistant_msg =
        Enum.find(r1.thread.messages, fn m ->
          m.role == :assistant and Map.get(m.metadata, :tool_calls, []) != []
        end)

      assert assistant_msg, "expected an assistant message with tool_calls in metadata"
      assistant_ids = MapSet.new(assistant_msg.metadata.tool_calls, & &1.id)

      tool_msg_ids =
        r1.thread.messages
        |> Enum.filter(&(&1.role == :tool))
        |> MapSet.new(& &1.tool_call_id)

      uncovered = MapSet.difference(assistant_ids, tool_msg_ids)
      assert MapSet.size(uncovered) == 1
      assert MapSet.member?(uncovered, "cm")

      # The metadata.manual_tool_calls field surfaces exactly the uncovered id —
      # giving the caller a direct fix-list to construct :tool messages from.
      assert [%ToolCall{id: "cm"}] = r1.metadata.manual_tool_calls

      # Sanity: the bare minimum a guard would catch — uncovered ids exist iff
      # metadata.manual_tool_calls is non-empty.
      assert MapSet.size(uncovered) > 0 ==
               length(r1.metadata.manual_tool_calls || []) > 0

      # Suppress unused-alias warning when the AdapterError clause isn't asserted
      # in this Fake-driven test (kept aliased for the docstring above).
      _ = AdapterError
    end
  end
end
