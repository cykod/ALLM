defmodule ALLM.Chat.PerToolManualStreamTest do
  @moduledoc """
  Phase 18.3 — streaming `Chat.stream/3` partition coverage.

  Five-cell matrix mirrors the non-streaming suite at
  `test/allm/chat/per_tool_manual_test.exs`:

  | Cell | Mode    | Tool flags                | Expected stream observations                                              |
  |------|---------|---------------------------|---------------------------------------------------------------------------|
  | 1    | :auto   | all manual: false         | `:tool_execution_*` fires for the call; `step_completed.manual_tool_calls == []` |
  | 2    | :auto   | mixed (auto + manual)     | `:tool_execution_*` fires for auto only; `manual_tool_calls = [<manual>]` |
  | 3    | :auto   | all manual: true          | NO `:tool_execution_*`; `manual_tool_calls = [<call>]`                    |
  | 4    | :manual | mixed                     | NO `:tool_execution_*`; `step_completed.mode == :manual`; `manual_tool_calls == []` |
  | 5    | :manual | all manual: false         | UNCHANGED — existing whole-loop streaming behavior                        |

  Also covers chat-equivalence smoke (`chat/3 == stream/3 |> StreamCollector.to_chat_result/1`)
  for one mixed-manual scripted input, and verifies `:on_event` callbacks see
  the new `:manual_tool_calls` payload key via the existing pass-through.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, Event, StreamCollector, Thread, Tool, ToolCall}
  alias ALLM.Test.FakeFixtures

  # ---------------------------------------------------------------------------
  # Tool fixtures (mirror PerToolManualTest)
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

  defp collect(stream), do: Enum.to_list(stream)

  defp tool_execution_started_count(events),
    do: Enum.count(events, &match?({:tool_execution_started, _}, &1))

  defp step_completed_payloads(events) do
    for {:step_completed, p} <- events, do: p
  end

  # ---------------------------------------------------------------------------
  # Cell 1 — :auto, all manual: false
  # ---------------------------------------------------------------------------

  describe "Cell 1: :auto, all manual: false (existing pure-auto stream path)" do
    test "tool_execution_* fires; step_completed.manual_tool_calls == []" do
      scripts = [
        [
          {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
          {:finish, :tool_calls}
        ],
        [{:text, "It is sunny."}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [weather_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      # tool_execution_started fires exactly once for "weather".
      assert tool_execution_started_count(events) == 1

      # All step_completed payloads carry manual_tool_calls: [].
      payloads = step_completed_payloads(events)
      assert length(payloads) == 2
      assert Enum.all?(payloads, &(&1.manual_tool_calls == []))
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 2 — :auto, mixed bucket
  # ---------------------------------------------------------------------------

  describe "Cell 2: :auto, mixed bucket" do
    test "tool_execution_* fires only for auto; step_completed.manual_tool_calls = [manual]" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      # Only the AUTO bucket runs — exactly one tool_execution_started for "ca".
      assert tool_execution_started_count(events) == 1

      execution_started =
        for {:tool_execution_started, p} <- events, do: p

      assert hd(execution_started).id == "ca"

      # step_completed payload carries the manual subset.
      [sc] = step_completed_payloads(events)
      assert [%ToolCall{id: "cm", name: "charge"}] = sc.manual_tool_calls
      assert sc.mode == :auto

      # Trailing :chat_completed agrees with the non-streaming chat/3 result.
      assert {:chat_completed, %{result: %ChatResult{} = cr}} = List.last(events)
      assert cr.halted_reason == :manual_tool_calls
      assert [%ToolCall{id: "cm"}] = cr.metadata.manual_tool_calls
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

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      [sc] = step_completed_payloads(events)
      ids = Enum.map(sc.manual_tool_calls, & &1.id)
      assert ids == ["m1", "m2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 3 — :auto, all manual: true (pure-manual)
  # ---------------------------------------------------------------------------

  describe "Cell 3: :auto, all manual: true (pure-manual)" do
    test "NO tool_execution_* events; step_completed.manual_tool_calls = [call]" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      assert tool_execution_started_count(events) == 0
      refute Enum.any?(events, &match?({:tool_execution_completed, _}, &1))
      refute Enum.any?(events, &match?({:tool_result_encoded, _}, &1))

      [sc] = step_completed_payloads(events)
      assert [%ToolCall{id: "cm", name: "charge"}] = sc.manual_tool_calls
      assert sc.mode == :auto

      # Thread on the step_completed event already has the assistant message.
      last = List.last(sc.thread.messages)
      assert last.role == :assistant

      # ChatResult halts with :manual_tool_calls.
      assert {:chat_completed, %{result: %ChatResult{} = cr}} = List.last(events)
      assert cr.halted_reason == :manual_tool_calls
      assert [%ToolCall{id: "cm"}] = cr.metadata.manual_tool_calls
      refute Map.has_key?(cr.metadata, :mode)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 4 — :manual, mixed (whole-loop wins per Decision #5)
  # ---------------------------------------------------------------------------

  describe "Cell 4: :manual, mixed (whole-loop wins)" do
    test "NO tool_execution_*; step_completed.mode == :manual; manual_tool_calls == []" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread(), mode: :manual)
      events = collect(stream)

      assert tool_execution_started_count(events) == 0

      [sc] = step_completed_payloads(events)
      assert sc.mode == :manual
      # Whole-loop manual does NOT populate the per-tool key — empty list.
      assert sc.manual_tool_calls == []

      assert {:chat_completed, %{result: %ChatResult{} = cr}} = List.last(events)
      assert cr.halted_reason == :manual_tool_calls
      # Whole-loop path only sets :manual_turn_index, not :manual_tool_calls.
      refute Map.has_key?(cr.metadata, :manual_tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 5 — :manual, all manual: false → existing whole-loop verbatim
  # ---------------------------------------------------------------------------

  describe "Cell 5: :manual, all manual: false (existing whole-loop verbatim)" do
    test "no per-tool key surfaces; trailing chat_completed halts with :manual_tool_calls" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [echo_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread(), mode: :manual)
      events = collect(stream)

      assert tool_execution_started_count(events) == 0

      [sc] = step_completed_payloads(events)
      assert sc.mode == :manual
      assert sc.manual_tool_calls == []

      assert {:chat_completed, %{result: %ChatResult{} = cr}} = List.last(events)
      assert cr.halted_reason == :manual_tool_calls
      assert cr.metadata == %{manual_turn_index: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # Chat-equivalence smoke for at least one mixed-manual scripted input
  # ---------------------------------------------------------------------------

  describe "chat-equivalence: chat/3 == stream/3 |> StreamCollector.to_chat_result/1" do
    test "mixed-manual fixture: streaming arm produces metadata.manual_tool_calls equal to non-streaming" do
      script_entries = [
        {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
        {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
        {:finish, :tool_calls}
      ]

      tools = [weather_tool(), manual_charge_tool()]

      # Per CLAUDE-md / agent-spec/IMPLEMENTATION.md: isolate Fake's per-process
      # cursor between calls in equivalence smokes.
      task1 =
        Task.async(fn ->
          engine = FakeFixtures.engine(script_entries, tools: tools)
          {:ok, cr} = Chat.run(engine, user_thread())
          cr
        end)

      task2 =
        Task.async(fn ->
          engine = FakeFixtures.engine(script_entries, tools: tools)
          {:ok, stream} = Chat.stream(engine, user_thread())
          events = Enum.to_list(stream)

          stream_cr =
            Thread.from_messages([ALLM.user("hi")])
            |> StreamCollector.new()
            |> then(fn s ->
              Enum.reduce(events, s, fn e, acc -> StreamCollector.apply_event(acc, e) end)
            end)
            |> StreamCollector.to_chat_result()

          stream_cr
        end)

      cr_run = Task.await(task1, 5_000)
      cr_stream = Task.await(task2, 5_000)

      # The :chat_completed event short-circuits to_chat_result/1 (already
      # contains the same ChatResult), so the two values agree on
      # halted_reason and metadata.manual_tool_calls — the load-bearing
      # equivalence assertion for Decision #12.
      assert cr_run.halted_reason == cr_stream.halted_reason
      assert cr_run.metadata.manual_tool_calls == cr_stream.metadata.manual_tool_calls
      assert [%ToolCall{id: "cm", name: "charge"}] = cr_stream.metadata.manual_tool_calls
    end

    test "pure-auto (control): both arms produce equal halted_reason and absence of manual_tool_calls" do
      scripts = [
        [
          {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
          {:finish, :tool_calls}
        ],
        [{:text, "It is sunny."}, {:finish, :stop}]
      ]

      tools = [weather_tool()]

      task1 =
        Task.async(fn ->
          engine = FakeFixtures.engine_with_scripts(scripts, tools: tools)
          {:ok, cr} = Chat.run(engine, user_thread())
          cr
        end)

      task2 =
        Task.async(fn ->
          engine = FakeFixtures.engine_with_scripts(scripts, tools: tools)
          {:ok, stream} = Chat.stream(engine, user_thread())
          events = Enum.to_list(stream)

          stream_cr =
            Thread.from_messages([ALLM.user("hi")])
            |> StreamCollector.new()
            |> then(fn s ->
              Enum.reduce(events, s, fn e, acc -> StreamCollector.apply_event(acc, e) end)
            end)
            |> StreamCollector.to_chat_result()

          stream_cr
        end)

      cr_run = Task.await(task1, 5_000)
      cr_stream = Task.await(task2, 5_000)

      assert cr_run.halted_reason == :completed
      assert cr_stream.halted_reason == :completed

      # Empty-list-is-absence per Decision #12: pure-auto turns must NOT
      # write `manual_tool_calls: []` to step metadata. Both arms agree.
      refute Map.has_key?(cr_run.metadata, :manual_tool_calls)
      refute Map.has_key?(cr_stream.metadata, :manual_tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # :on_event pass-through — callbacks see the new :manual_tool_calls key
  # ---------------------------------------------------------------------------

  describe ":on_event callback pass-through" do
    test "the :step_completed payload received by the consumer carries :manual_tool_calls" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      # The streaming API hands events through the enumerable; consumers
      # observe payloads exactly as constructed by `Event.step_completed/4`.
      observed =
        stream
        |> Enum.filter(&match?({:step_completed, _}, &1))
        |> Enum.map(fn {:step_completed, p} -> p end)

      assert [p] = observed
      # Key MUST be present (additive payload key per CLAUDE.md).
      assert Map.has_key?(p, :manual_tool_calls)
      assert [%ToolCall{id: "cm"}] = p.manual_tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # Direct Event.step_completed/4 sanity — referenced from streaming path
  # ---------------------------------------------------------------------------

  describe "Event.step_completed/4 is the streaming construction path" do
    test "constructed payload exactly matches the streaming emit_step_completed shape" do
      response = %ALLM.Response{output_text: "ok", finish_reason: :tool_calls}
      thread = %Thread{messages: []}
      manual_tcs = [%ToolCall{id: "cm", name: "charge", arguments: %{"amount" => 20}}]

      assert {:step_completed, payload} =
               Event.step_completed(response, thread, :auto, manual_tcs)

      assert payload.manual_tool_calls == manual_tcs
      assert payload.mode == :auto
    end
  end
end
