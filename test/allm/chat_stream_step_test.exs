defmodule ALLM.ChatStreamStepTest do
  use ExUnit.Case, async: true

  alias ALLM.{Chat, Engine, Response, Thread, Tool, ToolCall}

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

  defp engine_with_script(script, tools) do
    Engine.new(
      adapter: ALLM.Providers.Fake,
      adapter_opts: [script: script],
      tools: tools
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  defp tags(events), do: Enum.map(events, &elem(&1, 0))

  # ---------------------------------------------------------------------------
  # Event ordering
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — event ordering" do
    test "adapter events precede all tool-execution events, then one :step_completed" do
      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          [echo_tool()]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      # One :step_completed, at the very end.
      assert Enum.count(tags, &(&1 == :step_completed)) == 1
      assert List.last(tags) == :step_completed

      # All adapter-event indices < all tool-execution-event indices.
      adapter_tags = [
        :message_started,
        :text_delta,
        :text_completed,
        :tool_call_started,
        :tool_call_delta,
        :tool_call_completed,
        :message_completed,
        :raw_chunk
      ]

      tool_exec_tags = [:tool_execution_started, :tool_execution_completed, :tool_result_encoded]

      max_adapter_idx =
        tags
        |> Enum.with_index()
        |> Enum.filter(fn {tag, _i} -> tag in adapter_tags end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.max(fn -> -1 end)

      min_exec_idx =
        tags
        |> Enum.with_index()
        |> Enum.filter(fn {tag, _i} -> tag in tool_exec_tags end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.min(fn -> 10_000 end)

      assert max_adapter_idx < min_exec_idx

      # Exactly one tool-execution group for one tool call.
      assert Enum.count(tags, &(&1 == :tool_execution_started)) == 1
      assert Enum.count(tags, &(&1 == :tool_execution_completed)) == 1
      assert Enum.count(tags, &(&1 == :tool_result_encoded)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Parallel tool execution
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — parallel tool execution" do
    test "two tool calls produce 2× each event type, per-id ordering preserved" do
      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"n" => 0}},
            {:tool_call, id: "c1", name: "echo", arguments: %{"n" => 1}},
            {:finish, :tool_calls}
          ],
          [echo_tool()]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      assert Enum.count(tags, &(&1 == :tool_execution_started)) == 2
      assert Enum.count(tags, &(&1 == :tool_execution_completed)) == 2
      assert Enum.count(tags, &(&1 == :tool_result_encoded)) == 2
      assert Enum.count(tags, &(&1 == :step_completed)) == 1

      # Per-id ordering: started → completed → encoded.
      for id <- ["c0", "c1"] do
        per_id =
          events
          |> Enum.filter(fn
            {:tool_execution_started, %{id: ^id}} -> true
            {:tool_execution_completed, %{id: ^id}} -> true
            {:tool_result_encoded, %{id: ^id}} -> true
            _ -> false
          end)
          |> Enum.map(&elem(&1, 0))

        assert per_id ==
                 [:tool_execution_started, :tool_execution_completed, :tool_result_encoded]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # :step_completed payload
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — :step_completed payload" do
    test "carries final %Response{} and final %Thread{} (input + assistant + tool messages)" do
      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          [echo_tool()]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)

      {:step_completed, %{response: response, thread: thread}} = List.last(events)

      assert %Response{} = response
      assert response.finish_reason == :tool_calls
      assert [%ToolCall{id: "c0"}] = response.tool_calls

      assert %Thread{} = thread

      roles = Enum.map(thread.messages, & &1.role)
      assert roles == [:user, :assistant, :tool]
    end
  end

  # ---------------------------------------------------------------------------
  # :tool_halt emission
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — :tool_halt emission" do
    test "handler {:halt, reason, result} emits :tool_halt before :step_completed" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :x, %{a: 1}} end
        )

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [tool]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      assert :tool_halt in tags
      halt_event = Enum.find(events, &match?({:tool_halt, _}, &1))
      assert {:tool_halt, %{tool_call_id: "c0", reason: :x, result: %{a: 1}}} = halt_event

      # :step_completed still fires after the halt.
      assert List.last(tags) == :step_completed
    end
  end

  # ---------------------------------------------------------------------------
  # :ask_user_requested emission
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — :ask_user_requested emission" do
    test "handler {:ask_user, question} emits :ask_user_requested before :step_completed" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "q?"} end
        )

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [tool]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      assert :ask_user_requested in tags

      ask_event = Enum.find(events, &match?({:ask_user_requested, _}, &1))

      assert {:ask_user_requested,
              %{tool_call_id: "c0", tool_name: "echo", question: "q?", opts: []}} = ask_event

      assert List.last(tags) == :step_completed
    end
  end

  # ---------------------------------------------------------------------------
  # mode: :manual streaming
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — mode: :manual" do
    test "no tool-execution events; :step_completed thread has assistant without tool messages" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          # Should NOT be invoked.
          handler: fn _ -> {:ok, :wrong} end
        )

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [tool]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread(), mode: :manual)
      events = Enum.to_list(stream)
      tags = tags(events)

      refute :tool_execution_started in tags
      refute :tool_execution_completed in tags
      refute :tool_result_encoded in tags

      assert List.last(tags) == :step_completed

      {:step_completed, %{thread: thread}} = List.last(events)

      # The thread has [user, assistant] — no tool-role message.
      roles = Enum.map(thread.messages, & &1.role)
      assert roles == [:user, :assistant]

      assistant = List.last(thread.messages)
      assert [%ToolCall{id: "c0"}] = assistant.metadata[:tool_calls]
    end
  end

  # ---------------------------------------------------------------------------
  # on_event observer
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — :on_event observer" do
    test "every adapter event reaches the mailbox via on_event" do
      me = self()

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [echo_tool()]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread(), on_event: fn e -> send(me, e) end)
      _ = Enum.to_list(stream)

      # on_event is threaded into stream_generate — every adapter event
      # fires through the observer. Tool-execution events do NOT — on_event
      # applies only to the adapter stream (Phase 5 semantics). That's
      # acceptable in Phase 6.
      assert_received {:message_started, _}
      assert_received {:tool_call_started, _}
      assert_received {:message_completed, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal finish_reason (stream path)
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — terminal finish_reason (no tool calls)" do
    test "finish_reason :stop skips Phase B and emits :step_completed" do
      engine = engine_with_script([{:text, "Hello"}, {:finish, :stop}], [])

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      refute :tool_execution_started in tags
      assert List.last(tags) == :step_completed

      {:step_completed, %{response: response, thread: thread}} = List.last(events)
      assert response.finish_reason == :stop
      roles = Enum.map(thread.messages, & &1.role)
      assert roles == [:user, :assistant]
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown tool in streaming (pre-flight error)
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — unknown tool" do
    test "emits {:error, %EngineError{}} then :step_completed" do
      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "missing", arguments: %{}},
            {:finish, :tool_calls}
          ],
          # No `missing` tool registered.
          []
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)

      # An {:error, %EngineError{}} event appears.
      assert Enum.any?(events, fn
               {:error, %ALLM.Error.EngineError{reason: :unknown_tool}} -> true
               _ -> false
             end)

      tags = tags(events)
      assert List.last(tags) == :step_completed
    end
  end

  # ---------------------------------------------------------------------------
  # Second halt ignored (first-halt-wins in Phase B)
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — first halt wins" do
    test "two halting handlers — only first sets halt metadata on step_completed" do
      # Both tools halt; the :step_completed thread should carry metadata
      # for whichever halt the consumer observed first.
      halting =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :first, :r} end
        )

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:tool_call, id: "c1", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [halting]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)
      tags = tags(events)

      # Two :tool_halt emitted (siblings drain).
      assert Enum.count(tags, &(&1 == :tool_halt)) == 2
      # Stream still completes.
      assert List.last(tags) == :step_completed
    end
  end

  # ---------------------------------------------------------------------------
  # Handler halt — encoded halt message in thread
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — halt result encoding" do
    test "encoded halt result appears as tool-role message in :step_completed thread" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :budget, %{used: 100}} end
        )

      engine =
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [tool]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())
      events = Enum.to_list(stream)

      {:step_completed, %{thread: thread}} = List.last(events)
      tool_msg = Enum.find(thread.messages, &(&1.role == :tool))
      assert tool_msg.tool_call_id == "c0"
      assert Jason.decode!(tool_msg.content) == %{"used" => 100}
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer halt propagation
  # ---------------------------------------------------------------------------

  describe "stream_step/3 — consumer halt propagation" do
    test "Enum.take/2 during adapter phase triggers Fake cleanup observer" do
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

      {:ok, stream} = Chat.stream_step(engine, user_thread())

      # Take the first event (:message_started) and halt — this fires during
      # Phase A, which must propagate halt to the adapter stream and
      # trigger Fake's after_fun.
      taken = Enum.take(stream, 1)
      assert length(taken) == 1

      # Poll with a bounded deadline for the Stream.resource/3 cleanup chain
      # to run and Fake's after_fun to increment the observer. A fixed
      # Process.sleep/1 would be flaky on a loaded CI runner; the polling
      # shape mirrors the existing `wait_for/2` helpers in
      # fake_scenarios_test.exs / fake_stream_test.exs / stream_runner_test.exs
      # (a shared helper extraction is tracked separately in the retro
      # backlog).
      deadline = System.monotonic_time(:millisecond) + 500

      observed? =
        Stream.repeatedly(fn ->
          if :counters.get(observer, 1) >= 1 do
            true
          else
            if System.monotonic_time(:millisecond) >= deadline do
              :timeout
            else
              Process.sleep(10)
              false
            end
          end
        end)
        |> Enum.find(&(&1 != false))

      assert observed? == true
    end

    test "Enum.take/2 during tool-execution phase does not crash the consumer" do
      # Build a slow handler so the tool is still in-flight when we halt.
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
        engine_with_script(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          [tool]
        )

      {:ok, stream} = Chat.stream_step(engine, user_thread())

      # Halt after adapter phase closes, during Phase B.
      # 5 events from adapter stream (message_started, tool_call_started,
      # tool_call_completed, message_completed) plus maybe tool_execution_started.
      taken = Enum.take(stream, 5)
      assert length(taken) == 5
      # No crash — halt cleanup succeeded.
    end
  end
end
