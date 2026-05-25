defmodule ALLM.StreamCollectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.Error.{AdapterError, StreamError}

  alias ALLM.{
    ChatResult,
    Event,
    Message,
    Response,
    StepResult,
    StreamCollector,
    Thread,
    ToolCall,
    Usage
  }

  doctest StreamCollector

  # ---------------------------------------------------------------------------
  # Per-variant fold (one test per Phase 5-relevant tag)
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — :message_started" do
    test "is a no-op (state unchanged)" do
      s0 = StreamCollector.new()
      msg = %Message{role: :assistant, content: ""}
      s1 = StreamCollector.apply_event(s0, {:message_started, %{message: msg}})
      assert s0 == s1
    end
  end

  describe "apply_event/2 — :text_delta" do
    test "single delta sets current_text" do
      s =
        StreamCollector.apply_event(StreamCollector.new(), {:text_delta, %{id: nil, delta: "hel"}})

      assert s.current_text == "hel"
    end

    test "two deltas concatenate" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "hel"}})
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "lo"}})

      assert s.current_text == "hello"
    end
  end

  describe "apply_event/2 — :text_completed" do
    test "replaces current_text verbatim (authoritative-final)" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "ignored"}})
        |> StreamCollector.apply_event({:text_completed, %{id: nil, text: "final"}})

      assert s.current_text == "final"
    end
  end

  describe "apply_event/2 — :tool_call_started" do
    test "creates entry with empty arguments/raw_arguments" do
      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:tool_call_started, %{id: "c1", name: "weather"}}
        )

      assert %ToolCall{id: "c1", name: "weather", arguments: %{}, raw_arguments: ""} =
               s.current_tool_calls["c1"]

      assert s.tool_call_order == ["c1"]
    end

    test "preserves first-seen order across multiple starts" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_call_started, %{id: "a", name: "x"}})
        |> StreamCollector.apply_event({:tool_call_started, %{id: "b", name: "y"}})
        |> StreamCollector.apply_event({:tool_call_started, %{id: "c", name: "z"}})

      assert s.tool_call_order == ["a", "b", "c"]
    end
  end

  describe "apply_event/2 — :tool_call_delta" do
    test "appends to raw_arguments on an existing tool call" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_call_started, %{id: "c1", name: "w"}})
        |> StreamCollector.apply_event({:tool_call_delta, %{id: "c1", arguments_delta: ~S({"a":)}})
        |> StreamCollector.apply_event({:tool_call_delta, %{id: "c1", arguments_delta: ~S(1})}})

      assert s.current_tool_calls["c1"].raw_arguments == ~S({"a":1})
    end

    test "creates an implicit tool call with name: \"\" when id not yet started" do
      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:tool_call_delta, %{id: "c1", arguments_delta: "abc"}}
        )

      assert %ToolCall{id: "c1", name: "", raw_arguments: "abc"} = s.current_tool_calls["c1"]
      assert s.tool_call_order == ["c1"]
    end
  end

  describe "apply_event/2 — :tool_call_completed" do
    test "replaces the entry with authoritative arguments + raw_arguments" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_call_started, %{id: "c1", name: "w"}})
        |> StreamCollector.apply_event({:tool_call_delta, %{id: "c1", arguments_delta: "garbage"}})
        |> StreamCollector.apply_event(
          {:tool_call_completed,
           %{id: "c1", name: "w", arguments: %{"x" => 1}, raw_arguments: ~S({"x":1})}}
        )

      tc = s.current_tool_calls["c1"]
      assert tc.arguments == %{"x" => 1}
      assert tc.raw_arguments == ~S({"x":1})
    end
  end

  describe "apply_event/2 — :message_completed" do
    test "with finish_reason: :stop sets state finish_reason" do
      msg = %Message{role: :assistant, content: "ok"}

      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:message_completed, %{message: msg, finish_reason: :stop}}
        )

      assert s.finish_reason == :stop
      assert s.last_message == msg
    end

    test "without finish_reason key (back-compat) preserves prior finish_reason" do
      msg = %Message{role: :assistant, content: "ok"}

      # First set finish_reason via :error event, then apply message_completed without fr.
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:error, %AdapterError{reason: :rate_limited, message: "r"}})
        |> StreamCollector.apply_event({:message_completed, %{message: msg}})

      # :error set finish_reason: :error; back-compat :message_completed (no fr) preserves it.
      assert s.finish_reason == :error
      assert s.last_message == msg
    end

    test "with finish_reason: nil preserves prior finish_reason" do
      msg = %Message{role: :assistant, content: "ok"}

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:error, %AdapterError{reason: :rate_limited, message: "r"}})
        |> StreamCollector.apply_event({:message_completed, %{message: msg, finish_reason: nil}})

      assert s.finish_reason == :error
    end

    test "message_completed/1 constructor's payload folds correctly (nil fr)" do
      msg = %Message{role: :assistant, content: "ok"}
      event = Event.message_completed(msg)
      s = StreamCollector.apply_event(StreamCollector.new(), event)
      assert s.last_message == msg
      assert s.finish_reason == nil
    end

    test "Phase 21.2: metadata.usage is copied onto state.usage" do
      msg = %Message{role: :assistant, content: "ok"}
      usage = %Usage{input_tokens: 12, output_tokens: 4, total_tokens: 16}

      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:message_completed, %{message: msg, finish_reason: :stop, metadata: %{usage: usage}}}
        )

      assert s.usage == usage
    end

    test "Phase 21.2: metadata.usage without finish_reason still lands on state" do
      msg = %Message{role: :assistant, content: "ok"}
      usage = %Usage{input_tokens: 8, output_tokens: 2}

      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:message_completed, %{message: msg, metadata: %{usage: usage}}}
        )

      assert s.usage == usage
    end

    test "Phase 21.2: metadata.usage on collected stream lands on Response.usage" do
      msg = %Message{role: :assistant, content: "ok"}
      usage = %Usage{input_tokens: 5, output_tokens: 1, total_tokens: 6}

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "ok"}})
        |> StreamCollector.apply_event(
          {:message_completed, %{message: msg, finish_reason: :stop, metadata: %{usage: usage}}}
        )

      response = StreamCollector.to_response(s)
      assert response.usage == usage
    end
  end

  describe "apply_event/2 — :raw_chunk" do
    test "{:usage, map} folds map into :usage" do
      s =
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:raw_chunk, {:usage, %{input_tokens: 5, output_tokens: 2}}}
        )

      assert %Usage{input_tokens: 5, output_tokens: 2} = s.usage
    end

    test "non-usage payload is a no-op" do
      s0 = StreamCollector.new()
      s1 = StreamCollector.apply_event(s0, {:raw_chunk, "debug-string"})
      s2 = StreamCollector.apply_event(s0, {:raw_chunk, %{anything: true}})
      assert s0 == s1
      assert s0 == s2
    end

    test "{:usage, map} with unknown keys propagates KeyError (adapter bug)" do
      assert_raise KeyError, fn ->
        StreamCollector.apply_event(
          StreamCollector.new(),
          {:raw_chunk, {:usage, %{not_a_real_field: 1}}}
        )
      end
    end
  end

  describe "apply_event/2 — :error" do
    test "%AdapterError{} sets error + finish_reason: :error" do
      err = %AdapterError{reason: :rate_limited, message: "rate_limited"}
      s = StreamCollector.apply_event(StreamCollector.new(), {:error, err})
      assert s.error == err
      assert s.finish_reason == :error
    end

    test "%StreamError{} sets error + finish_reason: :error" do
      err = %StreamError{reason: :cancelled, message: "cancelled"}
      s = StreamCollector.apply_event(StreamCollector.new(), {:error, err})
      assert s.error == err
      assert s.finish_reason == :error
    end
  end

  # ---------------------------------------------------------------------------
  # Catch-all (Non-obvious Decision #12 — representative samples only)
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — catch-all (orchestration events + malformed)" do
    test ":tool_execution_started is absorbed (state unchanged)" do
      s0 = StreamCollector.new()

      s1 =
        StreamCollector.apply_event(
          s0,
          {:tool_execution_started, %{id: "c", name: "w", arguments: %{}}}
        )

      assert s0 == s1
    end

    test ":not_even_a_tuple is absorbed" do
      s0 = StreamCollector.new()
      assert s0 == StreamCollector.apply_event(s0, :not_even_a_tuple)
    end

    test "{:tool_call_delta, :not_a_map} is absorbed (malformed — catch-all)" do
      s0 = StreamCollector.new()
      assert s0 == StreamCollector.apply_event(s0, {:tool_call_delta, :not_a_map})
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6: new fold clauses
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — :tool_result_encoded (Phase 6)" do
    test "appends %Message{role: :tool, tool_call_id: id, content: content} to tool_results" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "c0", content: "hi"}})

      assert [%Message{role: :tool, tool_call_id: "c0", content: "hi", metadata: %{}}] =
               s.tool_results
    end

    test "two :tool_result_encoded events preserve insertion order" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "a", content: "1"}})
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "b", content: "2"}})

      assert [%Message{tool_call_id: "a"}, %Message{tool_call_id: "b"}] = s.tool_results
    end

    test "does not affect halt state" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "a", content: "1"}})

      assert s.halt == nil
    end
  end

  describe "apply_event/2 — :tool_halt (Phase 6)" do
    test "sets state.halt to {:halt, reason, tool_call_id, result}" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:tool_halt, %{tool_call_id: "c0", reason: :budget_exceeded, result: %{}}}
        )

      assert s.halt == {:halt, :budget_exceeded, "c0", %{}}
    end

    test "first-halt-wins — subsequent :tool_halt events are ignored" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:tool_halt, %{tool_call_id: "c0", reason: :first, result: :first_r}}
        )
        |> StreamCollector.apply_event(
          {:tool_halt, %{tool_call_id: "c1", reason: :second, result: :second_r}}
        )

      assert s.halt == {:halt, :first, "c0", :first_r}
    end

    test "appends a sentinel %Message{role: :tool} carrying payload :content to tool_results" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:tool_halt,
           %{tool_call_id: "c0", reason: :budget, result: %{r: 1}, content: "encoded-body"}}
        )

      assert [%Message{role: :tool, tool_call_id: "c0", content: "encoded-body"}] =
               s.tool_results
    end

    test "fallback content uses inspect/1 when payload :content is absent" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:tool_halt, %{tool_call_id: "c0", reason: :x, result: %{a: 1}}}
        )

      assert [%Message{tool_call_id: "c0", content: content}] = s.tool_results
      assert content == inspect(%{a: 1})
    end
  end

  describe "apply_event/2 — :ask_user_requested (Phase 6)" do
    test "sets state.halt to {:ask_user, :ask_user, id, question, opts}" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:ask_user_requested,
           %{tool_call_id: "c0", tool_name: "echo", question: "which?", opts: [choices: [1, 2]]}}
        )

      assert s.halt == {:ask_user, :ask_user, "c0", "which?", [choices: [1, 2]]}
    end

    test "first-halt-wins — subsequent :ask_user_requested events are ignored" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:ask_user_requested, %{tool_call_id: "c0", tool_name: "e", question: "first?", opts: []}}
        )
        |> StreamCollector.apply_event(
          {:ask_user_requested,
           %{tool_call_id: "c1", tool_name: "e", question: "second?", opts: []}}
        )

      assert s.halt == {:ask_user, :ask_user, "c0", "first?", []}
    end

    test "a :tool_halt followed by :ask_user_requested preserves :tool_halt (first-halt-wins across shapes)" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:tool_halt, %{tool_call_id: "c0", reason: :x, result: :r}})
        |> StreamCollector.apply_event(
          {:ask_user_requested, %{tool_call_id: "c1", tool_name: "e", question: "q?", opts: []}}
        )

      assert s.halt == {:halt, :x, "c0", :r}
    end

    test "appends `<awaiting user response>` sentinel to tool_results" do
      s =
        StreamCollector.new()
        |> StreamCollector.apply_event(
          {:ask_user_requested,
           %{tool_call_id: "c0", tool_name: "e", question: "q?", opts: [choices: [1, 2]]}}
        )

      assert [
               %Message{
                 role: :tool,
                 tool_call_id: "c0",
                 content: "<awaiting user response>"
               }
             ] = s.tool_results
    end
  end

  # ---------------------------------------------------------------------------
  # to_response/1
  # ---------------------------------------------------------------------------

  describe "to_response/1" do
    test "on a happy state produces populated %Response{}" do
      msg = %Message{role: :assistant, content: "hello"}

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "hello"}})
        |> StreamCollector.apply_event({:tool_call_started, %{id: "c1", name: "w"}})
        |> StreamCollector.apply_event(
          {:tool_call_completed,
           %{id: "c1", name: "w", arguments: %{"x" => 1}, raw_arguments: ~S({"x":1})}}
        )
        |> StreamCollector.apply_event({:raw_chunk, {:usage, %{input_tokens: 3, output_tokens: 5}}})
        |> StreamCollector.apply_event({:message_completed, %{message: msg, finish_reason: :stop}})

      resp = StreamCollector.to_response(s)
      assert %Response{} = resp
      assert resp.output_text == "hello"
      assert resp.finish_reason == :stop
      assert resp.message == msg
      assert [%ToolCall{id: "c1", name: "w", arguments: %{"x" => 1}}] = resp.tool_calls
      assert resp.usage == %Usage{input_tokens: 3, output_tokens: 5}
    end

    test "on an empty/new collector returns %Response{output_text: \"\", finish_reason: nil, usage: %Usage{}}" do
      resp = StreamCollector.to_response(StreamCollector.new())
      assert %Response{output_text: "", finish_reason: nil, usage: %Usage{}} = resp
      assert resp.tool_calls == []
      assert resp.metadata == %{}
    end

    test "on an error state returns %Response{finish_reason: :error, metadata: %{error: struct}}" do
      err = %AdapterError{reason: :rate_limited, message: "x"}
      s = StreamCollector.apply_event(StreamCollector.new(), {:error, err})

      resp = StreamCollector.to_response(s)
      assert resp.finish_reason == :error
      assert resp.metadata == %{error: err}
    end
  end

  # ---------------------------------------------------------------------------
  # to_step_result/1 — thread required + done? / halted_reason mapping
  # ---------------------------------------------------------------------------

  describe "to_step_result/1" do
    test "with non-nil thread + finish_reason :tool_calls → done?: false" do
      msg = %Message{role: :assistant, content: ""}
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event(
          {:message_completed, %{message: msg, finish_reason: :tool_calls}}
        )

      sr = StreamCollector.to_step_result(s)
      assert %StepResult{thread: ^thread, done?: false, tool_results: []} = sr
    end

    test "with finish_reason in [:stop, :length, :content_filter, :error] → done?: true" do
      msg = %Message{role: :assistant, content: ""}
      thread = Thread.new()

      for fr <- [:stop, :length, :content_filter, :error] do
        s =
          StreamCollector.new(thread)
          |> StreamCollector.apply_event({:message_completed, %{message: msg, finish_reason: fr}})

        sr = StreamCollector.to_step_result(s)
        assert sr.done? == true, "expected done?: true for finish_reason #{inspect(fr)}"
      end
    end

    test "with finish_reason: nil → done?: false (conservative default)" do
      s = StreamCollector.new(Thread.new())
      sr = StreamCollector.to_step_result(s)
      assert sr.done? == false
    end

    test "with nil thread raises ArgumentError with helpful message" do
      assert_raise ArgumentError, ~r/requires a thread/, fn ->
        StreamCollector.to_step_result(StreamCollector.new())
      end

      assert_raise ArgumentError, ~r/to_response\/1 for thread-less collection/, fn ->
        StreamCollector.to_step_result(StreamCollector.new(nil))
      end
    end

    # -------------------------------------------------------------------------
    # Phase 6 extensions
    # -------------------------------------------------------------------------

    test "populates tool_results from :tool_result_encoded folds" do
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "a", content: "1"}})
        |> StreamCollector.apply_event({:tool_result_encoded, %{id: "b", content: "2"}})

      sr = StreamCollector.to_step_result(s)
      assert [%Message{tool_call_id: "a"}, %Message{tool_call_id: "b"}] = sr.tool_results
    end

    test "done?: true when a :tool_halt fired even if finish_reason == :tool_calls" do
      msg = %Message{role: :assistant, content: ""}
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event(
          {:message_completed, %{message: msg, finish_reason: :tool_calls}}
        )
        |> StreamCollector.apply_event({:tool_halt, %{tool_call_id: "c0", reason: :x, result: :r}})

      sr = StreamCollector.to_step_result(s)
      assert sr.done? == true
    end

    test "done?: true when :ask_user_requested fired even if finish_reason == :tool_calls" do
      msg = %Message{role: :assistant, content: ""}
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event(
          {:message_completed, %{message: msg, finish_reason: :tool_calls}}
        )
        |> StreamCollector.apply_event(
          {:ask_user_requested, %{tool_call_id: "c0", tool_name: "e", question: "q?", opts: []}}
        )

      sr = StreamCollector.to_step_result(s)
      assert sr.done? == true
    end

    test "merges halt metadata (tool_halt shape) into StepResult.metadata" do
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event(
          {:tool_halt, %{tool_call_id: "c0", reason: :budget, result: :r}}
        )

      sr = StreamCollector.to_step_result(s)
      assert sr.metadata[:halted_reason] == :budget
      assert sr.metadata[:halt_tool_call_id] == "c0"
      assert sr.metadata[:halt_result] == :r
    end

    test "merges halt metadata (ask_user shape) into StepResult.metadata" do
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event(
          {:ask_user_requested,
           %{tool_call_id: "c0", tool_name: "e", question: "which?", opts: [choices: [1, 2]]}}
        )

      sr = StreamCollector.to_step_result(s)
      assert sr.metadata[:halted_reason] == :ask_user
      assert sr.metadata[:pending_tool_call_id] == "c0"
      assert sr.metadata[:pending_question] == "which?"
      assert sr.metadata[:ask_user_opts] == [choices: [1, 2]]
    end

    test "no halt — metadata unchanged" do
      thread = Thread.new()
      s = StreamCollector.new(thread)
      sr = StreamCollector.to_step_result(s)
      assert sr.metadata == %{}
      refute Map.has_key?(sr.metadata, :halted_reason)
    end
  end

  # ---------------------------------------------------------------------------
  # to_chat_result/1 — halted_reason mapping
  # ---------------------------------------------------------------------------

  describe "to_chat_result/1" do
    test "stored chat_result short-circuits (returned verbatim)" do
      cr = %ChatResult{
        thread: Thread.new(),
        final_response: %Response{output_text: "stored"},
        halted_reason: :completed
      }

      s =
        StreamCollector.new(Thread.new())
        |> StreamCollector.apply_event({:chat_completed, %{result: cr}})

      assert StreamCollector.to_chat_result(s) == cr
    end

    test "stored chat_result short-circuits even when state.thread is nil" do
      cr = %ChatResult{
        thread: Thread.new(),
        final_response: %Response{output_text: "stored"},
        halted_reason: :completed
      }

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:chat_completed, %{result: cr}})

      assert StreamCollector.to_chat_result(s) == cr
    end

    test "fallback: zero-step cancellation → :cancelled" do
      thread = Thread.new()
      cr = StreamCollector.to_chat_result(StreamCollector.new(thread))
      assert cr.halted_reason == :cancelled
      assert cr.thread == thread
      assert cr.steps == []
    end

    test "fallback: partial-step cancellation does NOT promote to :completed" do
      # Two clean :step_completed events but no :chat_completed → still :cancelled.
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "step"}

      response = %Response{
        message: msg,
        output_text: "step",
        finish_reason: :stop
      }

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      cr = StreamCollector.to_chat_result(s)
      assert cr.halted_reason == :cancelled
      assert length(cr.steps) == 2
    end

    test "fallback: state.error != nil → :error (takes precedence over :cancelled)" do
      err = %AdapterError{reason: :rate_limited, message: "x"}

      s =
        StreamCollector.new(Thread.new())
        |> StreamCollector.apply_event({:error, err})

      cr = StreamCollector.to_chat_result(s)
      assert cr.halted_reason == :error
    end

    test "fallback final_response: last step's response when steps != []" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "first"}
      r1 = %Response{message: msg, output_text: "first", finish_reason: :stop}

      msg2 = %Message{role: :assistant, content: "last"}
      r2 = %Response{message: msg2, output_text: "last", finish_reason: :stop}

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event({:step_completed, %{response: r1, thread: thread}})
        |> StreamCollector.apply_event({:step_completed, %{response: r2, thread: thread}})

      cr = StreamCollector.to_chat_result(s)
      assert cr.final_response == r2
    end

    test "fallback final_response: to_response(state) when steps == []" do
      thread = Thread.new()

      s =
        StreamCollector.new(thread)
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "partial"}})

      cr = StreamCollector.to_chat_result(s)
      assert cr.final_response.output_text == "partial"
    end

    test "with nil chat_result and nil thread raises ArgumentError with helpful message" do
      assert_raise ArgumentError, ~r/requires a thread/, fn ->
        StreamCollector.to_chat_result(StreamCollector.new())
      end

      assert_raise ArgumentError, ~r/to_response\/1 for thread-less collection/, fn ->
        StreamCollector.to_chat_result(StreamCollector.new(nil))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 7: :step_completed and :chat_completed fold clauses
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — :step_completed (Phase 7)" do
    test "appends a %StepResult{} to state.steps with response/thread/tool_results" do
      thread = Thread.new() |> Thread.add_message(%Message{role: :user, content: "hi"})
      msg = %Message{role: :assistant, content: "hello"}
      response = %Response{message: msg, output_text: "hello", finish_reason: :stop}
      tool_msg = %Message{role: :tool, tool_call_id: "c0", content: "ok", metadata: %{}}

      s =
        %{StreamCollector.new() | tool_results: [tool_msg]}
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      assert [step_result] = s.steps
      assert %StepResult{} = step_result
      assert step_result.response == response
      assert step_result.thread == thread
      assert step_result.tool_results == [tool_msg]
    end

    test "resets per-step sub-state after the fold" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :stop}

      s0 = StreamCollector.new()

      s1 = %{
        s0
        | current_text: "x",
          current_tool_calls: %{"c0" => %ToolCall{id: "c0", name: "t", arguments: %{}}},
          tool_call_order: ["c0"],
          tool_results: [%Message{role: :tool, tool_call_id: "c0", content: "ok"}],
          halt: {:halt, :foo, "c0", :r},
          finish_reason: :stop,
          raw_finish_reason: "stop",
          last_message: msg
      }

      s2 =
        StreamCollector.apply_event(
          s1,
          {:step_completed, %{response: response, thread: thread}}
        )

      assert s2.current_text == ""
      assert s2.current_tool_calls == %{}
      assert s2.tool_call_order == []
      assert s2.tool_results == []
      assert s2.halt == nil
      assert s2.finish_reason == nil
      assert s2.raw_finish_reason == nil
      assert s2.last_message == nil
    end

    test "appended StepResult carries PRE-RESET tool_results, halt-derived metadata, and done?" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :tool_calls}
      tool_msg = %Message{role: :tool, tool_call_id: "id1", content: "x"}

      s =
        %{
          StreamCollector.new()
          | tool_results: [tool_msg],
            halt: {:halt, :foo, "id1", :result_term}
        }
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      [step_result] = s.steps
      assert step_result.tool_results == [tool_msg]
      assert step_result.metadata.halted_reason == :foo
      assert step_result.metadata.halt_tool_call_id == "id1"
      assert step_result.metadata.halt_result == :result_term
      assert step_result.done? == true
    end

    test "state.metadata is NOT reset by the fold" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :stop}

      s =
        %{StreamCollector.new() | metadata: %{adapter_meta: 1}}
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      assert s.metadata == %{adapter_meta: 1}
    end

    test "state.thread is updated to the event's thread" do
      old_thread = Thread.new()
      new_thread = Thread.new() |> Thread.add_message(%Message{role: :user, content: "next"})
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :stop}

      s =
        StreamCollector.new(old_thread)
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: new_thread}})

      assert s.thread == new_thread
    end

    test "state.error is NOT reset" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :stop}
      err = %AdapterError{reason: :rate_limited, message: "x"}

      s =
        %{StreamCollector.new() | error: err}
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      assert s.error == err
    end

    test "two :step_completed folds produce state.steps with length 2 and post-reset cleanliness" do
      thread = Thread.new()
      msg = %Message{role: :assistant, content: "x"}
      response = %Response{message: msg, output_text: "x", finish_reason: :stop}

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})
        |> StreamCollector.apply_event({:text_delta, %{id: nil, delta: "step2"}})
        |> StreamCollector.apply_event({:step_completed, %{response: response, thread: thread}})

      assert length(s.steps) == 2
      # Sub-state reset cleanly between folds.
      assert s.current_text == ""
    end
  end

  describe "apply_event/2 — :chat_completed (Phase 7)" do
    test "stores the event's :result verbatim and sets done?: true" do
      cr = %ChatResult{
        thread: Thread.new(),
        final_response: %Response{output_text: "x"},
        halted_reason: :completed
      }

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:chat_completed, %{result: cr}})

      assert s.chat_result == cr
      assert s.done? == true
    end

    test "second :chat_completed overwrites the first (last-wins)" do
      cr1 = %ChatResult{
        thread: Thread.new(),
        final_response: %Response{output_text: "first"},
        halted_reason: :completed
      }

      cr2 = %ChatResult{
        thread: Thread.new(),
        final_response: %Response{output_text: "second"},
        halted_reason: :max_turns
      }

      s =
        StreamCollector.new()
        |> StreamCollector.apply_event({:chat_completed, %{result: cr1}})
        |> StreamCollector.apply_event({:chat_completed, %{result: cr2}})

      assert s.chat_result == cr2
    end
  end

  # ---------------------------------------------------------------------------
  # Totality property (per Non-obvious Decision #8 / #12)
  # ---------------------------------------------------------------------------

  describe "totality" do
    property "apply_event/2 is total over the 16-tag closed union for arbitrary payloads" do
      # Build events that explore the full tag set. Payloads vary:
      # - For structured variants, a random map.
      # - For :raw_chunk, an arbitrary term (including a well-formed usage map).
      # - For :error, an arbitrary term.
      tags = Event.tags()

      check all(
              tag <- StreamData.member_of(tags),
              payload <-
                StreamData.one_of([
                  StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer()),
                  StreamData.term()
                ])
            ) do
        event = {tag, payload}
        state = StreamCollector.new()

        # Either returns a %StreamCollector{} (total fold) or raises the
        # documented KeyError when an unknown :usage field is present.
        try do
          result = StreamCollector.apply_event(state, event)
          assert %StreamCollector{} = result
        rescue
          e in KeyError ->
            # KeyError only legitimate for :raw_chunk with a bad :usage map.
            assert match?({:raw_chunk, {:usage, m}} when is_map(m), event),
                   "unexpected KeyError for event #{inspect(event)}: #{Exception.message(e)}"
        end
      end
    end

    test "apply_event/2 accepts every Phase-5-relevant tag without raising on well-formed payload" do
      msg = %Message{role: :assistant, content: ""}

      events = [
        {:message_started, %{message: msg}},
        {:text_delta, %{id: nil, delta: "x"}},
        {:text_completed, %{id: nil, text: "x"}},
        {:tool_call_started, %{id: "c1", name: "w"}},
        {:tool_call_delta, %{id: "c1", arguments_delta: "x"}},
        {:tool_call_completed, %{id: "c1", name: "w", arguments: %{}, raw_arguments: ""}},
        {:message_completed, %{message: msg, finish_reason: :stop}},
        {:raw_chunk, "anything"},
        {:raw_chunk, {:usage, %{input_tokens: 1}}},
        {:error, %AdapterError{reason: :rate_limited, message: "x"}}
      ]

      for event <- events do
        assert %StreamCollector{} = StreamCollector.apply_event(StreamCollector.new(), event)
      end
    end

    test "apply_event/2 accepts every Phase-6 orchestration tag without raising on well-formed payload" do
      events = [
        {:tool_result_encoded, %{id: "c0", content: "1"}},
        {:tool_halt, %{tool_call_id: "c0", reason: :x, result: :r}},
        {:ask_user_requested, %{tool_call_id: "c0", tool_name: "t", question: "q?", opts: []}}
      ]

      for event <- events do
        assert %StreamCollector{} = StreamCollector.apply_event(StreamCollector.new(), event)
      end
    end

    test "apply_event/2 accepts every Phase-7 orchestration tag without raising on well-formed payload" do
      thread = Thread.new()
      response = %Response{output_text: "x"}
      cr = %ChatResult{thread: thread, final_response: response, halted_reason: :completed}

      events = [
        {:step_completed, %{response: response, thread: thread}},
        {:chat_completed, %{result: cr}}
      ]

      for event <- events do
        assert %StreamCollector{} = StreamCollector.apply_event(StreamCollector.new(), event)
      end
    end
  end
end
