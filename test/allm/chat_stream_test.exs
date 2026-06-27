defmodule ALLM.ChatStreamTest do
  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, Engine, Message, StepResult, Thread, Tool, ToolCall}
  alias ALLM.Error.{EngineError, ValidationError}
  alias ALLM.Test.{FakeFixtures, TelemetryCapture}

  import ALLM.Test.AsyncHelpers, only: [wait_for: 2]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp tags(events), do: Enum.map(events, &elem(&1, 0))

  defp collect(stream), do: Enum.to_list(stream)

  # ---------------------------------------------------------------------------
  # Event ordering across turns
  # ---------------------------------------------------------------------------

  describe "stream/3 — event ordering across turns" do
    test "all step 1 events precede all step 2 events; exactly one :chat_completed last" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)
      ts = tags(events)

      # Exactly one :chat_completed and it is the last event.
      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed

      # Two :step_completed (one per turn).
      assert Enum.count(ts, &(&1 == :step_completed)) == 2

      step1_idx =
        ts
        |> Enum.with_index()
        |> Enum.find(fn {tag, _i} -> tag == :step_completed end)
        |> elem(1)

      # Every event at index <= step1_idx (step 1) precedes every event at
      # index > step1_idx (step 2). Sanity: step 2 starts with adapter events
      # (e.g., :message_started) which appear AFTER step1_idx.
      step2_first_message_idx =
        ts
        |> Enum.with_index()
        |> Enum.find(fn {tag, i} -> tag == :message_started and i > step1_idx end)
        |> elem(1)

      assert step1_idx < step2_first_message_idx

      # :chat_completed payload carries a ChatResult with halted_reason :completed.
      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :completed
      assert length(result.steps) == 2
    end

    test "single-turn text fixture emits adapter events + :step_completed + :chat_completed" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)
      ts = tags(events)

      assert Enum.count(ts, &(&1 == :step_completed)) == 1
      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed
    end
  end

  # ---------------------------------------------------------------------------
  # Single terminal :chat_completed
  # ---------------------------------------------------------------------------

  describe "stream/3 — single terminal :chat_completed" do
    test "exactly one :chat_completed across any natural-termination fixture" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())
      ts = stream |> collect() |> tags()

      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer halt
  # ---------------------------------------------------------------------------

  describe "stream/3 — consumer halt" do
    test "Enum.take/2 mid-step does NOT emit :chat_completed and triggers Fake cleanup" do
      observer = :counters.new(1, [])

      engine =
        Engine.new(
          adapter: ALLM.Providers.Fake,
          adapter_opts: [
            script: [
              {:text, "a"},
              {:text, "b"},
              {:text, "c"},
              {:finish, :stop}
            ],
            cleanup_observer: observer
          ]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())

      taken = Enum.take(stream, 1)
      assert length(taken) == 1
      refute Enum.any?(taken, &match?({:chat_completed, _}, &1))

      # Cleanup chain — Chat.stream/3 after_fun → step_cont halt →
      # stream_step/3 after_fun → adapter_cont halt → Fake after_fun.
      assert wait_for(fn -> :counters.get(observer, 1) >= 1 end, 500)
    end

    test "Stream.take_while/2 ending right after first :step_completed — no second step, no :chat_completed" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())

      events =
        stream
        |> Stream.take_while(fn e -> not match?({:step_completed, _}, e) end)
        |> Enum.to_list()

      ts = tags(events)

      refute Enum.any?(ts, &(&1 == :step_completed))
      refute Enum.any?(ts, &(&1 == :chat_completed))
    end
  end

  # ---------------------------------------------------------------------------
  # Ask-user
  # ---------------------------------------------------------------------------

  describe "stream/3 — ask-user" do
    test "emits adapter + tool-execution + :ask_user_requested + :step_completed + :chat_completed" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which city?", choices: ["A", "B"]} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)
      ts = tags(events)

      assert :tool_execution_started in ts
      assert :tool_execution_completed in ts
      assert :ask_user_requested in ts
      assert Enum.count(ts, &(&1 == :step_completed)) == 1
      assert List.last(ts) == :chat_completed

      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :ask_user
      assert result.pending_question == "which city?"
      assert result.pending_tool_call_id == "c0"
      assert result.metadata.ask_user_opts == [choices: ["A", "B"]]

      last_msg = List.last(result.thread.messages)
      assert last_msg.role == :assistant
      assert last_msg.content == "which city?"
      assert last_msg.metadata == %{ask_user: true, tool_call_id: "c0"}
    end

    test "streaming ask-user thread asymmetry: :step_completed.thread lacks the question; :chat_completed.result.thread has it" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which city?"} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      {:step_completed, %{thread: step_thread}} =
        Enum.find(events, &match?({:step_completed, _}, &1))

      {:chat_completed, %{result: %ChatResult{thread: chat_thread}}} =
        List.last(events)

      step_last = List.last(step_thread.messages)
      refute step_last.metadata[:ask_user] == true

      chat_last = List.last(chat_thread.messages)
      assert chat_last.metadata[:ask_user] == true
      assert chat_last.content == "which city?"

      # Cross-path equality: streaming ChatResult.thread == non-streaming Chat.run/3 thread.
      # Since the §31 fix, Fake's façade-driven cursor keys on `engine.id`
      # (injected as `adapter_opts[:cursor_key]` by `StreamRunner`); the run
      # path builds its own engine via `FakeFixtures.engine/2`, so it gets a
      # distinct cursor key from the streaming path and never collides.
      # `Task.async/await` is retained as defensive process isolation
      # (belt-and-suspenders), no longer the collision guard.
      run_result =
        Task.async(fn ->
          run_engine =
            FakeFixtures.engine(
              [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
              tools: [tool]
            )

          {:ok, result} = Chat.run(run_engine, user_thread())
          result
        end)
        |> Task.await(5_000)

      assert chat_thread == run_result.thread
    end
  end

  # ---------------------------------------------------------------------------
  # Manual mode
  # ---------------------------------------------------------------------------

  describe "stream/3 — mode: :manual" do
    test "no tool-execution events; terminates after first :step_completed + :chat_completed" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      {:ok, stream} = Chat.stream(engine, user_thread(), mode: :manual)
      events = collect(stream)
      ts = tags(events)

      refute :tool_execution_started in ts
      refute :tool_execution_completed in ts
      refute :tool_result_encoded in ts

      assert Enum.count(ts, &(&1 == :step_completed)) == 1
      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed

      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :manual_tool_calls
      assert [%ToolCall{id: "c0", name: "echo"}] = result.final_response.tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # halt_when mid-loop
  # ---------------------------------------------------------------------------

  describe "stream/3 — halt_when" do
    test "halt_when fires after step 1 — emits step 1 events + :chat_completed; no step 2 adapter events" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      halt_when = fn sr -> sr.tool_results != [] end
      {:ok, stream} = Chat.stream(engine, user_thread(), halt_when: halt_when)
      events = collect(stream)
      ts = tags(events)

      # Exactly one :step_completed.
      assert Enum.count(ts, &(&1 == :step_completed)) == 1
      assert List.last(ts) == :chat_completed

      step_completed_idx =
        ts
        |> Enum.with_index()
        |> Enum.find(fn {tag, _i} -> tag == :step_completed end)
        |> elem(1)

      chat_completed_idx = length(ts) - 1

      # No adapter events between :step_completed and :chat_completed (i.e.
      # nothing from a hypothetical step 2). Adjacent indices ⇒ no slice.
      assert step_completed_idx + 1 == chat_completed_idx

      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :halt_when
      assert result.metadata == %{halt_when_step_index: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # max_turns mid-loop
  # ---------------------------------------------------------------------------

  describe "stream/3 — max_turns" do
    test "max_turns: 2 emits exactly 2 :step_completed events + :chat_completed" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c1", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c2", name: "echo", arguments: %{}}, {:finish, :tool_calls}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread(), max_turns: 2)
      events = collect(stream)
      ts = tags(events)

      assert Enum.count(ts, &(&1 == :step_completed)) == 2
      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed

      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :max_turns
      assert result.metadata == %{max_turns: 2}
      assert length(result.steps) == 2
    end

    test "max_turns: 0 raises ArgumentError synchronously before any stream" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: 0/, fn ->
        Chat.stream(engine, user_thread(), max_turns: 0)
      end
    end

    test "max_turns: 1.5 raises ArgumentError" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: 1.5/, fn ->
        Chat.stream(engine, user_thread(), max_turns: 1.5)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  describe "stream/3 — errors" do
    test "adapter pre-flight error → {:error, struct} synchronously; no stream" do
      engine = %Engine{Engine.new(adapter: ALLM.Providers.Fake) | adapter: nil}

      assert {:error, %EngineError{reason: :missing_adapter}} =
               Chat.stream(engine, user_thread())
    end

    test "empty thread → {:error, ValidationError} synchronously" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert {:error, %ValidationError{}} = Chat.stream(engine, [])
    end

    test "mid-loop adapter error → step 1 events + step 2 :error + :step_completed (finish_reason :error) + :chat_completed (:error)" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:error, :rate_limited}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)
      ts = tags(events)

      assert Enum.count(ts, &(&1 == :step_completed)) == 2
      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert :error in ts

      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :error
      assert length(result.steps) == 2
      last_step = List.last(result.steps)
      assert last_step.response.finish_reason == :error
    end
  end

  # ---------------------------------------------------------------------------
  # No synthetic message_started/message_completed for ask-user question
  # ---------------------------------------------------------------------------

  describe "stream/3 — no synthetic message events for ask-user question" do
    test "message_started count equals message_completed count" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?"} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      ts = stream |> collect() |> tags()

      assert Enum.count(ts, &(&1 == :message_started)) ==
               Enum.count(ts, &(&1 == :message_completed))
    end
  end

  # ---------------------------------------------------------------------------
  # State-boundary ownership: StepResult tool_results match executed tool messages
  # ---------------------------------------------------------------------------

  describe "stream/3 — state-boundary ownership" do
    test "ChatResult.steps[0].tool_results matches the executed tool messages (non-empty)" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      {:chat_completed, %{result: %ChatResult{steps: [step1 | _]}}} = List.last(events)

      assert [%Message{role: :tool, tool_call_id: "c0"}] = step1.tool_results
      assert step1.done? == false
      assert step1.metadata == %{}
    end

    test "ChatResult.steps[0].tool_results matches when ask-user halts the step" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?"} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())
      events = collect(stream)

      {:chat_completed, %{result: %ChatResult{steps: [%StepResult{} = step1 | _]}}} =
        List.last(events)

      assert step1.metadata.halted_reason == :ask_user
      assert step1.metadata.pending_question == "which?"
      # tool_results is always a list — confirm the field's shape rather
      # than its size (the awaiting-response message lives there but the
      # exact count is part of Phase 6's tested fold contract).
      assert is_list(step1.tool_results)
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup tests for halt_when / max_turns / ask-user halts
  # ---------------------------------------------------------------------------

  describe "stream/3 — consumer-halt cleanup at terminal :chat_completed" do
    test "halt right before :chat_completed still terminates without raise" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = Chat.stream(engine, user_thread())

      # Halt before :chat_completed by stopping right after :step_completed.
      events =
        stream
        |> Stream.take_while(fn e -> not match?({:chat_completed, _}, e) end)
        |> Enum.to_list()

      refute Enum.any?(events, &match?({:chat_completed, _}, &1))
    end

    test "Enum.take/2 mid-tool-execution triggers Fake cleanup observer" do
      observer = :counters.new(1, [])

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ ->
            Process.sleep(200)
            {:ok, :ok}
          end
        )

      engine =
        Engine.new(
          adapter: ALLM.Providers.Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "echo", arguments: %{}},
              {:finish, :tool_calls}
            ],
            cleanup_observer: observer
          ],
          tools: [tool]
        )

      {:ok, stream} = Chat.stream(engine, user_thread())

      # Pull enough to enter Phase B (tool execution started), then halt.
      _ = Enum.take(stream, 5)

      assert wait_for(fn -> :counters.get(observer, 1) >= 1 end, 500)
    end
  end

  # ---------------------------------------------------------------------------
  # Chat-equivalence sanity (informal — formal property test in batch 4)
  # ---------------------------------------------------------------------------

  describe "stream/3 — informal chat-equivalence" do
    test "stream/3 |> collect == run/3 for a happy 2-turn fixture" do
      stream_engine =
        FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      run_engine =
        FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(stream_engine, user_thread())
      events = collect(stream)

      {:chat_completed, %{result: stream_result}} = List.last(events)

      assert {:ok, run_result} = Chat.run(run_engine, user_thread())

      assert stream_result.halted_reason == run_result.halted_reason
      assert stream_result.thread == run_result.thread
      assert stream_result.final_response.output_text == run_result.final_response.output_text
      assert length(stream_result.steps) == length(run_result.steps)
    end

    # Phase 7 retro F1 canary: fold the streaming events through a fresh
    # `StreamCollector` (the shape batch 4's chat-equivalence property
    # uses) and assert the resulting ChatResult equals `Chat.run/3`'s
    # result. Pre-fix, the StreamCollector's `:step_completed` fold built a
    # `%StepResult{}` lacking `metadata.mode = :manual`, so this assertion
    # would have diverged on the manual-mode case (the steps' metadata
    # field would differ between the two paths).
    test "stream/3 |> StreamCollector.to_chat_result/1 == run/3 for manual mode" do
      thread = user_thread()

      stream_engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      {:ok, stream} = Chat.stream(stream_engine, thread, mode: :manual)

      collector =
        Enum.reduce(stream, ALLM.StreamCollector.new(thread), fn ev, c ->
          ALLM.StreamCollector.apply_event(c, ev)
        end)

      stream_result = ALLM.StreamCollector.to_chat_result(collector)

      # Run on a fresh process — Fake's per-process cursor would otherwise be
      # exhausted by the streaming call above (see Fake's cursor docs).
      run_result =
        Task.async(fn ->
          run_engine =
            FakeFixtures.engine(
              [
                {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
                {:finish, :tool_calls}
              ],
              tools: [echo_tool()]
            )

          {:ok, r} = Chat.run(run_engine, thread, mode: :manual)
          r
        end)
        |> Task.await(5_000)

      # The load-bearing assertion: the per-step metadata maps must agree.
      # Pre-F1-fix, run-side step had `%{mode: :manual}`; stream-side step
      # had `%{}`, and this would diverge.
      stream_step_metas = Enum.map(stream_result.steps, & &1.metadata)
      run_step_metas = Enum.map(run_result.steps, & &1.metadata)
      assert stream_step_metas == run_step_metas

      # Whole-result equivalence on observable fields.
      assert stream_result.halted_reason == run_result.halted_reason
      assert stream_result.halted_reason == :manual_tool_calls
      assert stream_result.thread == run_result.thread
      assert stream_result.final_response.output_text == run_result.final_response.output_text
      assert stream_result.final_response.tool_calls == run_result.final_response.tool_calls
      assert length(stream_result.steps) == length(run_result.steps)
    end

    # Companion canary for the auto-mode happy path — same shape, drives the
    # collector-fold equivalence so future regressions in either fold path
    # surface together with the manual-mode case above.
    test "stream/3 |> StreamCollector.to_chat_result/1 == run/3 for auto mode (2-turn)" do
      thread = user_thread()

      stream_engine =
        FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      {:ok, stream} = Chat.stream(stream_engine, thread)

      collector =
        Enum.reduce(stream, ALLM.StreamCollector.new(thread), fn ev, c ->
          ALLM.StreamCollector.apply_event(c, ev)
        end)

      stream_result = ALLM.StreamCollector.to_chat_result(collector)

      run_result =
        Task.async(fn ->
          run_engine =
            FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(),
              tools: [echo_tool()]
            )

          {:ok, r} = Chat.run(run_engine, thread)
          r
        end)
        |> Task.await(5_000)

      stream_step_metas = Enum.map(stream_result.steps, & &1.metadata)
      run_step_metas = Enum.map(run_result.steps, & &1.metadata)
      assert stream_step_metas == run_step_metas

      assert stream_result.halted_reason == run_result.halted_reason
      assert stream_result.thread == run_result.thread
      assert stream_result.final_response.output_text == run_result.final_response.output_text
      assert length(stream_result.steps) == length(run_result.steps)
    end
  end

  describe "stream/3 — telemetry (Phase 9.1)" do
    test "emits [:allm, :chat, :start | :stop] with :request_id, :engine; :chat_result is nil on stream" do
      TelemetryCapture.attach([
        [:allm, :chat, :start],
        [:allm, :chat, :stop]
      ])

      engine = FakeFixtures.engine([{:text, "hello"}, {:finish, :stop}])
      assert {:ok, stream} = Chat.stream(engine, user_thread())
      _ = Enum.to_list(stream)

      events = TelemetryCapture.events()
      TelemetryCapture.detach()

      assert {[:allm, :chat, :start], _, start_meta} =
               Enum.find(events, &match?({[:allm, :chat, :start], _, _}, &1))

      assert is_binary(start_meta.request_id)
      assert start_meta.engine == engine

      assert {[:allm, :chat, :stop], _, stop_meta} =
               Enum.find(events, &match?({[:allm, :chat, :stop], _, _}, &1))

      assert stop_meta.request_id == start_meta.request_id
      # Lazy-enumerable carve-out — :chat_result is nil on stream span :stop.
      assert Map.get(stop_meta, :chat_result) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.4 — structured_finalize two-pass orchestration (stream)
  # ---------------------------------------------------------------------------

  describe "stream/3 — structured_finalize two-pass" do
    setup do
      on_exit(fn -> Application.delete_env(:allm, :structured_finalize_nudge) end)
      :ok
    end

    defp json_schema_rf do
      %{type: :json_schema, name: "g", schema: %{type: "object"}, strict: true}
    end

    defp finalize_scripts_stream do
      [
        # Pass 1 turn 1 — tool call.
        [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}}, {:finish, :tool_calls}],
        # Pass 1 turn 2 — terminal text.
        [{:text, "tool done"}, {:finish, :stop}],
        # Pass 2 turn 1 — structured JSON.
        [{:text, ~s({"answer": "ok"})}, {:finish, :stop}]
      ]
    end

    test "two-pass stream emits exactly one :chat_completed (pass 1's is suppressed)" do
      engine =
        FakeFixtures.engine_with_scripts(finalize_scripts_stream(), tools: [echo_tool()])

      {:ok, stream} =
        Chat.stream(engine, user_thread(),
          structured_finalize: true,
          response_format: json_schema_rf()
        )

      events = collect(stream)
      ts = tags(events)

      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      assert List.last(ts) == :chat_completed

      # The terminal :chat_completed carries the merged ChatResult.
      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :completed
      assert result.metadata.structured_finalize.pass_1_halted == :completed
      assert result.final_response.output_text == ~s({"answer": "ok"})
    end

    test "stream-equivalence: chat/3 ≡ stream/3 |> StreamCollector.to_chat_result/1" do
      run_engine =
        FakeFixtures.engine_with_scripts(finalize_scripts_stream(), tools: [echo_tool()])

      stream_engine =
        FakeFixtures.engine_with_scripts(finalize_scripts_stream(), tools: [echo_tool()])

      {:ok, run_result} =
        Chat.run(run_engine, user_thread(),
          structured_finalize: true,
          response_format: json_schema_rf()
        )

      {:ok, stream} =
        Chat.stream(stream_engine, user_thread(),
          structured_finalize: true,
          response_format: json_schema_rf()
        )

      events = collect(stream)
      {:chat_completed, %{result: stream_result}} = List.last(events)

      # Tight equivalence on the user-observable fields.
      assert run_result.halted_reason == stream_result.halted_reason
      assert run_result.final_response.output_text == stream_result.final_response.output_text
      assert run_result.metadata.structured_finalize == stream_result.metadata.structured_finalize
      assert length(run_result.steps) == length(stream_result.steps)
    end

    test "pass-1 :ask_user halt skips pass 2 and emits a single :chat_completed" do
      ask_tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _args -> {:ask_user, "Which one?"} end
        )

      scripts = [
        [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, ~s({"answer": "x"})}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [ask_tool])

      {:ok, stream} =
        Chat.stream(engine, user_thread(),
          structured_finalize: true,
          response_format: json_schema_rf()
        )

      events = collect(stream)
      ts = tags(events)

      assert Enum.count(ts, &(&1 == :chat_completed)) == 1
      {:chat_completed, %{result: %ChatResult{} = result}} = List.last(events)
      assert result.halted_reason == :ask_user
      assert result.metadata.structured_finalize.pass_1_halted == :ask_user
    end
  end
end
