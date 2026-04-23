defmodule ALLM.EventTest do
  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Event, Message, Response, Thread}

  doctest Event

  @map_payload_tags ~w(
    message_started text_delta text_completed
    tool_call_started tool_call_delta tool_call_completed
    tool_execution_started tool_execution_completed tool_result_encoded
    ask_user_requested tool_halt
    message_completed step_completed chat_completed
  )a

  describe "tags/0" do
    test "returns all 16 tag atoms" do
      tags = Event.tags()
      assert length(tags) == 16
      assert :raw_chunk in tags
      assert :error in tags

      for t <- @map_payload_tags do
        assert t in tags, "expected #{inspect(t)} in Event.tags/0"
      end
    end
  end

  describe "event?/1 — true cases" do
    test "every variant constructor returns a term that passes event?/1" do
      assert Event.event?(Event.text_delta("id-1", "hel"))
      assert Event.event?(Event.text_completed("id-1", "hello"))
      assert Event.event?(Event.tool_call_started("c1", "weather"))
      assert Event.event?(Event.tool_call_delta("c1", "{\"ci"))
      assert Event.event?(Event.tool_call_completed("c1", "weather", %{"city" => "SFO"}, "{}"))
      assert Event.event?(Event.tool_execution_started("c1", "weather", %{"city" => "SFO"}))
      assert Event.event?(Event.tool_execution_completed("c1", "weather", "sunny"))
      assert Event.event?(Event.tool_result_encoded("c1", "sunny"))
      assert Event.event?(Event.ask_user_requested("c1", "weather", "which city?", []))
      assert Event.event?(Event.tool_halt("c1", :not_found, %{}))
      assert Event.event?(Event.message_started(%Message{role: :assistant, content: ""}))
      assert Event.event?(Event.message_completed(%Message{role: :assistant, content: "ok"}))

      assert Event.event?(
               Event.step_completed(
                 %Response{output_text: "ok"},
                 %Thread{messages: []}
               )
             )

      assert Event.event?(
               Event.chat_completed(%ChatResult{
                 thread: %Thread{},
                 final_response: %Response{},
                 halted_reason: :completed
               })
             )
    end

    test "raw_chunk accepts any payload" do
      assert Event.event?({:raw_chunk, "string"})
      assert Event.event?({:raw_chunk, %{anything: true}})
      assert Event.event?({:raw_chunk, nil})
      assert Event.event?({:raw_chunk, 42})
    end

    test "error accepts any payload" do
      assert Event.event?({:error, :boom})
      assert Event.event?({:error, "str"})
      assert Event.event?({:error, %RuntimeError{message: "boom"}})
      assert Event.event?({:error, nil})
    end
  end

  describe "event?/1 — false cases" do
    test "rejects non-tuples" do
      assert Event.event?(:not_an_event) == false
      assert Event.event?(nil) == false
      assert Event.event?(%{}) == false
      assert Event.event?("text") == false
      assert Event.event?([:text_delta, %{}]) == false
    end

    test "rejects tuples of wrong arity" do
      assert Event.event?({:text_delta}) == false
      assert Event.event?({:text_delta, %{}, :extra}) == false
      assert Event.event?({}) == false
      assert Event.event?({1, 2}) == false
    end

    test "rejects string tags" do
      assert Event.event?({"text_delta", %{}}) == false
    end

    test "rejects unknown tags" do
      assert Event.event?({:unknown_tag, %{}}) == false
      assert Event.event?({:foo, %{}}) == false
    end

    test "rejects map-payload tags with non-map payloads" do
      for tag <- @map_payload_tags do
        assert Event.event?({tag, "not a map"}) == false,
               "expected #{inspect(tag)} with non-map payload to be rejected"

        assert Event.event?({tag, 42}) == false
        assert Event.event?({tag, nil}) == false
      end
    end
  end

  describe "variant constructors" do
    test "text_delta/2 returns the correct tagged tuple" do
      assert {:text_delta, %{id: "a", delta: "b"}} = Event.text_delta("a", "b")
    end

    test "text_completed/2" do
      assert {:text_completed, %{id: "a", text: "hello"}} = Event.text_completed("a", "hello")
    end

    test "tool_call_started/2" do
      assert {:tool_call_started, %{id: "c1", name: "w"}} = Event.tool_call_started("c1", "w")
    end

    test "tool_call_delta/2" do
      assert {:tool_call_delta, %{id: "c1", arguments_delta: "{"}} =
               Event.tool_call_delta("c1", "{")
    end

    test "tool_call_completed/4" do
      assert {:tool_call_completed,
              %{id: "c1", name: "w", arguments: %{"x" => 1}, raw_arguments: "{}"}} =
               Event.tool_call_completed("c1", "w", %{"x" => 1}, "{}")
    end

    test "tool_execution_started/3" do
      assert {:tool_execution_started, %{id: "c1", name: "w", arguments: %{}}} =
               Event.tool_execution_started("c1", "w", %{})
    end

    test "tool_execution_completed/3" do
      assert {:tool_execution_completed, %{id: "c1", name: "w", result: "ok"}} =
               Event.tool_execution_completed("c1", "w", "ok")
    end

    test "tool_result_encoded/2" do
      assert {:tool_result_encoded, %{id: "c1", content: "sunny"}} =
               Event.tool_result_encoded("c1", "sunny")
    end

    test "ask_user_requested/4" do
      assert {:ask_user_requested, %{tool_call_id: "c1", tool_name: "w", question: "?", opts: []}} =
               Event.ask_user_requested("c1", "w", "?", [])
    end

    test "tool_halt/3" do
      assert {:tool_halt, %{tool_call_id: "c1", reason: :not_found, result: %{}}} =
               Event.tool_halt("c1", :not_found, %{})
    end

    test "message_started/1" do
      msg = %Message{role: :assistant, content: ""}
      assert {:message_started, %{message: ^msg}} = Event.message_started(msg)
    end

    test "message_completed/1" do
      msg = %Message{role: :assistant, content: "ok"}
      assert {:message_completed, %{message: ^msg}} = Event.message_completed(msg)
    end

    test "step_completed/2" do
      resp = %Response{output_text: "ok"}
      thread = %Thread{messages: []}

      assert {:step_completed, %{response: ^resp, thread: ^thread}} =
               Event.step_completed(resp, thread)
    end

    test "chat_completed/1" do
      result = %ChatResult{
        thread: %Thread{},
        final_response: %Response{},
        halted_reason: :completed
      }

      assert {:chat_completed, %{result: ^result}} = Event.chat_completed(result)
    end
  end
end
