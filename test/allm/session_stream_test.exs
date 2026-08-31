defmodule ALLM.SessionStreamTest do
  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Engine, Message, Session, StepResult, Thread, Tool}
  alias ALLM.Error.{EngineError, SessionError, ValidationError}
  alias ALLM.Providers.Fake
  alias ALLM.Session.StreamReducer
  alias ALLM.Test.FakeFixtures

  import ALLM.Test.AsyncHelpers, only: [wait_for: 2]

  defp engine_with_text(text \\ "ok") do
    Engine.new(
      adapter: Fake,
      adapter_opts: [script: [{:text, text}, {:finish, :stop}]]
    )
  end

  defp engine_with_tool_call(name \\ "echo", args \\ %{"x" => 1}) do
    tool = Tool.new(name: name, description: "", schema: %{}, handler: fn a -> {:ok, a} end)

    Engine.new(
      adapter: Fake,
      adapter_opts: [
        script: [
          {:tool_call, id: "call_0", name: name, arguments: args},
          {:finish, :tool_calls}
        ]
      ],
      tools: [tool]
    )
  end

  # Inline; Batch 3 will lift to FakeFixtures.ask_user_then_resume/1.
  defp engine_with_ask_user_then_resume do
    tool =
      Tool.new(
        name: "ask",
        description: "",
        schema: %{},
        handler: fn _ -> {:ask_user, "Are you sure?"} end
      )

    Engine.new(
      adapter: Fake,
      adapter_opts: [
        scripts: [
          [{:tool_call, id: "call_0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          [{:text, "resumed"}, {:finish, :stop}]
        ]
      ],
      tools: [tool]
    )
  end

  defp tags(events), do: Enum.map(events, fn e -> elem(e, 0) end)

  defp count_tag(events, tag), do: Enum.count(events, &match?({^tag, _}, &1))

  # ===========================================================================
  # stream_start/3
  # ===========================================================================

  describe "stream_start/3" do
    test "happy path: returns {:ok, stream}; consuming yields adapter events plus exactly one :chat_completed" do
      engine = engine_with_text("hello")

      assert {:ok, stream} = Session.stream_start(engine, [ALLM.user("hi")])

      events = Enum.to_list(stream)

      assert count_tag(events, :chat_completed) == 1
      assert {:chat_completed, %{result: %ChatResult{}}} = List.last(events)
    end

    test "pre-flight error (missing :adapter) returns {:error, %EngineError{}} synchronously" do
      engine = %Engine{}

      assert {:error, %EngineError{reason: :missing_adapter}} =
               Session.stream_start(engine, [ALLM.user("hi")])
    end

    test "pre-flight error from coerce_session_input/1 returns {:error, %ValidationError{}} synchronously" do
      engine = engine_with_text()

      assert {:error, %ValidationError{reason: :invalid_session_input}} =
               Session.stream_start(engine, {:not, "valid"})
    end

    test "stream filters: emit_text_deltas: false drops :text_delta events" do
      engine = engine_with_text("hello")

      assert {:ok, stream} =
               Session.stream_start(engine, [ALLM.user("hi")], emit_text_deltas: false)

      events = Enum.to_list(stream)

      refute Enum.any?(tags(events), &(&1 == :text_delta))
      assert count_tag(events, :chat_completed) == 1
    end

    test ":error-status session returns {:error, %SessionError{}} synchronously" do
      engine = engine_with_text()
      seed = %Session{status: :error, metadata: %{error: :boom}}

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.stream_start(engine, seed)
    end
  end

  # ===========================================================================
  # stream_reply/4
  # ===========================================================================

  describe "stream_reply/4" do
    test "happy path: builds user message, dispatches" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:text, "first"}, {:finish, :stop}],
              [{:text, "second"}, {:finish, :stop}]
            ]
          ]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])

      assert {:ok, stream} = Session.stream_reply(engine, s, "more")

      events = Enum.to_list(stream)

      assert count_tag(events, :chat_completed) == 1
    end

    test "on :awaiting_user: post-finalize session has cleared pending fields" do
      engine = engine_with_ask_user_then_resume()

      {:ok, s1, _} = Session.start(engine, [ALLM.user("hi")])
      assert s1.status == :awaiting_user
      assert s1.pending_question == "Are you sure?"

      {:ok, stream} = Session.stream_reply(engine, s1, "yes")

      {s2, _r} =
        stream
        |> Enum.reduce(StreamReducer.new(s1), fn e, acc -> StreamReducer.apply_event(acc, e) end)
        |> StreamReducer.finalize()

      assert s2.pending_question == nil
      assert s2.pending_tool_call_id == nil
    end

    test "on :awaiting_tools raises ArgumentError synchronously (BEFORE constructing stream)" do
      engine = engine_with_tool_call()
      {:ok, s, _} = Session.start(engine, [ALLM.user("echo")], mode: :manual)
      assert s.status == :awaiting_tools

      assert_raise ArgumentError, fn ->
        Session.stream_reply(engine, s, "no can do")
      end
    end

    test "on :error returns {:error, %SessionError{reason: :session_in_error_state}} synchronously" do
      engine = engine_with_text()
      s = %Session{status: :error, metadata: %{error: :boom}}

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.stream_reply(engine, s, "hi")
    end
  end

  # ===========================================================================
  # stream_step/3
  # ===========================================================================

  describe "stream_step/3" do
    test "happy path: stream yields :step_completed (NOT :chat_completed) terminal" do
      engine = engine_with_text("hello")
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      assert {:ok, stream} = Session.stream_step(engine, s)

      events = Enum.to_list(stream)

      assert count_tag(events, :step_completed) == 1
      assert count_tag(events, :chat_completed) == 0
    end

    test "folded with StreamReducer.new(session, mode: :step), finalize/1 returns {session, %StepResult{}}" do
      engine = engine_with_text("hello")
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      {:ok, stream} = Session.stream_step(engine, s)

      result =
        stream
        |> Enum.reduce(StreamReducer.new(s, mode: :step), fn e, acc ->
          StreamReducer.apply_event(acc, e)
        end)
        |> StreamReducer.finalize()

      assert match?({_, %StepResult{}}, result)
    end

    test "pre-flight error (missing :adapter) returns {:error, %EngineError{}} synchronously" do
      engine = %Engine{}
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      assert {:error, %EngineError{}} = Session.stream_step(engine, s)
    end

    test "raises ArgumentError on :awaiting_user" do
      engine = engine_with_text()
      s = %Session{status: :awaiting_user, pending_question: "?"}

      assert_raise ArgumentError, fn -> Session.stream_step(engine, s) end
    end

    test "on :error returns {:error, %SessionError{}} synchronously" do
      engine = engine_with_text()
      s = %Session{status: :error}

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.stream_step(engine, s)
    end
  end

  # ===========================================================================
  # Stream cancellation
  # ===========================================================================

  describe "stream cancellation" do
    test "Enum.take(stream, 1) halts early; upstream resource released within 500ms" do
      observer = :counters.new(1, [:atomics])

      engine =
        Engine.new(
          adapter: Fake,
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

      {:ok, stream} = Session.stream_start(engine, [ALLM.user("hi")])

      taken = Enum.take(stream, 1)
      assert length(taken) == 1
      refute Enum.any?(taken, &match?({:chat_completed, _}, &1))

      assert wait_for(fn -> :counters.get(observer, 1) >= 1 end, 500)
    end

    test "stream_step/3 cancellation also releases upstream resource" do
      observer = :counters.new(1, [:atomics])

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:text, "a"},
              {:text, "b"},
              {:finish, :stop}
            ],
            cleanup_observer: observer
          ]
        )

      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))
      {:ok, stream} = Session.stream_step(engine, s)

      _ = Enum.take(stream, 1)

      assert wait_for(fn -> :counters.get(observer, 1) >= 1 end, 500)
    end
  end

  # ===========================================================================
  # Reducer integration: stream_start ≡ start (ad-hoc fixtures; full property in 8.4)
  # ===========================================================================

  describe "reducer integration" do
    test "stream_start/3 + StreamReducer mode :chat ≡ Session.start/3 (single-turn text)" do
      input = [ALLM.user("hi")]

      # Per agent-spec/IMPLEMENTATION.md: isolate Fake's per-process cursor.
      {s_sync, r_sync} =
        Task.async(fn ->
          engine = engine_with_text("hello")
          {:ok, s, r} = Session.start(engine, input)
          {s, r}
        end)
        |> Task.await()

      {s_stream, r_stream} =
        Task.async(fn ->
          engine = engine_with_text("hello")
          {:ok, stream} = Session.stream_start(engine, input)

          stream
          |> Enum.reduce(StreamReducer.new(Session.new()), fn e, acc ->
            StreamReducer.apply_event(acc, e)
          end)
          |> StreamReducer.finalize()
        end)
        |> Task.await()

      assert s_stream.status == s_sync.status
      assert s_stream.thread.messages == s_sync.thread.messages
      assert r_stream.halted_reason == r_sync.halted_reason
    end

    test "stream_start/3 with manual-mode tool-call halts session as :awaiting_tools after finalize" do
      input = [ALLM.user("echo me")]

      {s_stream, r_stream} =
        Task.async(fn ->
          engine = engine_with_tool_call()
          {:ok, stream} = Session.stream_start(engine, input, mode: :manual)
          seed = Session.new()

          stream
          |> Enum.reduce(StreamReducer.new(seed), fn e, acc ->
            StreamReducer.apply_event(acc, e)
          end)
          |> StreamReducer.finalize()
        end)
        |> Task.await()

      assert s_stream.status == :awaiting_tools
      assert [%ALLM.ToolCall{id: "call_0"}] = s_stream.pending_tool_calls
      assert r_stream.halted_reason == :manual_tool_calls
    end
  end

  # ===========================================================================
  # Mid-stream error
  # ===========================================================================

  describe "mid-stream error" do
    test "mid-stream :error event → :chat_completed.result.halted_reason == :error → session :error" do
      engine = FakeFixtures.engine([{:text, "partial"}, {:error, :rate_limited}])

      {:ok, stream} = Session.stream_start(engine, [ALLM.user("hi")])

      events = Enum.to_list(stream)

      assert {:chat_completed, %{result: %ChatResult{halted_reason: :error}}} =
               List.last(events)

      seed = Session.new()

      {s, cr} =
        events
        |> Enum.reduce(StreamReducer.new(seed), fn e, acc ->
          StreamReducer.apply_event(acc, e)
        end)
        |> StreamReducer.finalize()

      assert s.status == :error
      assert cr.halted_reason == :error
    end
  end

  # ===========================================================================
  # Ask-user thread asymmetry (inherited from Phase 7)
  # ===========================================================================

  describe "ask-user thread asymmetry" do
    test "stream_start/3 against ask-user fixture: :step_completed.thread excludes question; :chat_completed.result.thread includes it" do
      engine = engine_with_ask_user_then_resume()

      {:ok, stream} = Session.stream_start(engine, [ALLM.user("hi")])

      events = Enum.to_list(stream)

      step_completed = Enum.find(events, &match?({:step_completed, _}, &1))
      chat_completed = Enum.find(events, &match?({:chat_completed, _}, &1))

      assert step_completed
      assert chat_completed

      {:step_completed, %{thread: step_thread}} = step_completed
      {:chat_completed, %{result: %ChatResult{thread: chat_thread}}} = chat_completed

      step_assistants_with_question =
        step_thread.messages
        |> Enum.filter(fn %Message{role: r, content: c} ->
          r == :assistant and is_binary(c) and c =~ "Are you sure?"
        end)

      chat_assistants_with_question =
        chat_thread.messages
        |> Enum.filter(fn %Message{role: r, content: c} ->
          r == :assistant and is_binary(c) and c =~ "Are you sure?"
        end)

      # Step's thread does NOT include the assistant question; chat's does.
      assert step_assistants_with_question == []
      assert chat_assistants_with_question != []

      # StreamReducer.finalize/1's session.thread mirrors chat_completed.result.thread.
      seed = Session.new()

      {final_session, _r} =
        events
        |> Enum.reduce(StreamReducer.new(seed), fn e, acc ->
          StreamReducer.apply_event(acc, e)
        end)
        |> StreamReducer.finalize()

      assert final_session.thread == chat_thread
    end
  end
end
