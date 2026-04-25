defmodule ALLM.SessionStreamReducerTest do
  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Message, Session, StepResult, StreamCollector, Thread}
  alias ALLM.Session.StreamReducer

  doctest StreamReducer

  defp empty_session do
    Session.new(thread: Thread.from_messages([%Message{role: :user, content: "hi"}]))
  end

  describe "new/2" do
    test "default mode is :chat with collector seeded from session.thread" do
      s = empty_session()
      r = StreamReducer.new(s)

      assert %StreamReducer{session: ^s, mode: :chat} = r
      assert r.collector.thread == s.thread
    end

    test "accepts mode: :step" do
      s = empty_session()
      r = StreamReducer.new(s, mode: :step)

      assert r.mode == :step
      assert r.collector.thread == s.thread
    end

    test "raises ArgumentError on unknown mode" do
      s = empty_session()

      assert_raise ArgumentError, ~r/:mode must be :chat or :step/, fn ->
        StreamReducer.new(s, mode: :bogus)
      end
    end

    test "stores the originating session verbatim" do
      s = Session.new(id: "s1", context: %{user: 42})
      r = StreamReducer.new(s)
      assert r.session == s
    end
  end

  describe "apply_event/2" do
    test "delegates to StreamCollector and updates :collector" do
      s = empty_session()

      r =
        s
        |> StreamReducer.new()
        |> StreamReducer.apply_event({:text_delta, %{id: nil, delta: "he"}})
        |> StreamReducer.apply_event({:text_delta, %{id: nil, delta: "llo"}})

      assert r.collector.current_text == "hello"
    end

    test "is a no-op on malformed events (delegated to collector catch-all)" do
      s = empty_session()
      r = StreamReducer.new(s)
      r2 = StreamReducer.apply_event(r, {:_unknown_tag, %{}})
      assert r2.collector == r.collector
    end

    test "does NOT mutate :session through any number of folds" do
      s = empty_session()

      r =
        s
        |> StreamReducer.new()
        |> StreamReducer.apply_event({:text_delta, %{id: nil, delta: "x"}})
        |> StreamReducer.apply_event({:tool_call_started, %{id: "c0", name: "echo"}})
        |> StreamReducer.apply_event(
          {:message_completed,
           %{message: %Message{role: :assistant, content: "x"}, finish_reason: :stop}}
        )

      assert r.session == s
    end
  end

  describe "finalize/1 — :chat mode" do
    test "stored chat_result branch returns the stored ChatResult and projects it" do
      s = empty_session()

      stored_thread =
        Thread.from_messages([
          %Message{role: :user, content: "hi"},
          %Message{role: :assistant, content: "yo"}
        ])

      stored = %ChatResult{
        thread: stored_thread,
        final_response: nil,
        steps: [],
        halted_reason: :completed,
        metadata: %{}
      }

      reducer =
        s
        |> StreamReducer.new()
        |> StreamReducer.apply_event({:chat_completed, %{result: stored}})

      {updated_session, returned_cr} = StreamReducer.finalize(reducer)

      assert returned_cr == stored
      assert updated_session.status == :completed
      assert updated_session.thread == stored_thread
    end

    test "no chat_completed produces a :cancelled fallback" do
      s = empty_session()

      reducer = StreamReducer.new(s)

      {updated_session, %ChatResult{} = cr} = StreamReducer.finalize(reducer)

      assert cr.halted_reason == :cancelled
      assert updated_session.status == :completed
      assert updated_session.thread == s.thread
    end
  end

  describe "finalize/1 — :step mode" do
    test "single-step terminus returns the StepResult and projects via apply_step_result" do
      s = empty_session()

      # Drive a realistic stream so the collector folds a step with done?: true.
      response = %ALLM.Response{output_text: "hi", finish_reason: :stop, metadata: %{}}

      reducer =
        s
        |> StreamReducer.new(mode: :step)
        |> StreamReducer.apply_event({:text_delta, %{id: nil, delta: "hi"}})
        |> StreamReducer.apply_event(
          {:message_completed,
           %{message: %Message{role: :assistant, content: "hi"}, finish_reason: :stop}}
        )
        |> StreamReducer.apply_event(
          {:step_completed, %{response: response, thread: s.thread, mode: :auto}}
        )

      {updated_session, %StepResult{} = sr} = StreamReducer.finalize(reducer)

      assert sr.done? == true
      assert sr.response.finish_reason == :stop
      assert updated_session.status == :completed
    end

    test "empty collector returns a :cancelled ChatResult (not a StepResult)" do
      s = empty_session()
      reducer = StreamReducer.new(s, mode: :step)

      {updated_session, result} = StreamReducer.finalize(reducer)

      assert %ChatResult{halted_reason: :cancelled} = result
      assert updated_session == s
    end
  end

  describe "finalize/1 idempotency" do
    test "calling finalize twice on the same state returns equal tuples" do
      s = empty_session()

      stored = %ChatResult{
        thread: s.thread,
        final_response: nil,
        steps: [],
        halted_reason: :completed,
        metadata: %{}
      }

      reducer =
        s
        |> StreamReducer.new()
        |> StreamReducer.apply_event({:chat_completed, %{result: stored}})

      a = StreamReducer.finalize(reducer)
      b = StreamReducer.finalize(reducer)
      assert a == b
    end
  end

  describe "session round-trip after apply_event/2" do
    test "wrapped session round-trips through term_to_binary at every fold step" do
      s = empty_session()

      r0 = StreamReducer.new(s)
      assert r0.session == r0.session |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      r1 = StreamReducer.apply_event(r0, {:text_delta, %{id: nil, delta: "x"}})
      assert r1.session == r1.session |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      r2 =
        StreamReducer.apply_event(
          r1,
          {:message_completed,
           %{message: %Message{role: :assistant, content: "x"}, finish_reason: :stop}}
        )

      assert r2.session == r2.session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "StreamCollector compatibility" do
    test "collector state matches what StreamCollector.apply_event produces directly" do
      s = empty_session()

      reducer =
        s
        |> StreamReducer.new()
        |> StreamReducer.apply_event({:text_delta, %{id: nil, delta: "hi"}})

      direct =
        s.thread
        |> StreamCollector.new()
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "hi"}})

      assert reducer.collector == direct
    end
  end
end
