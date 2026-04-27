defmodule ALLM.ResponseTest do
  use ExUnit.Case, async: true

  alias ALLM.{Message, Response, TextPart, ToolCall, Usage}

  doctest Response

  describe "new/1" do
    test "builds a Response with defaults" do
      resp = Response.new([])
      assert %Response{tool_calls: [], usage: %Usage{}, metadata: %{}} = resp
    end

    test "accepts all documented fields" do
      msg = %Message{role: :assistant, content: "hi"}
      tc = %ToolCall{id: "c1", name: "n", arguments: %{}}
      usage = %Usage{input_tokens: 1, output_tokens: 2}

      resp =
        Response.new(
          id: "resp_1",
          request_id: "req_1",
          model: "fake:gpt-test",
          message: msg,
          output_text: "hi",
          tool_calls: [tc],
          finish_reason: :stop,
          raw_finish_reason: "stop",
          usage: usage,
          raw: %{"raw" => "payload"},
          metadata: %{foo: :bar}
        )

      assert resp.id == "resp_1"
      assert resp.request_id == "req_1"
      assert resp.model == "fake:gpt-test"
      assert resp.message == msg
      assert resp.output_text == "hi"
      assert resp.tool_calls == [tc]
      assert resp.finish_reason == :stop
      assert resp.raw_finish_reason == "stop"
      assert resp.usage == usage
      assert resp.raw == %{"raw" => "payload"}
      assert resp.metadata == %{foo: :bar}
    end
  end

  describe "text/1" do
    test "returns output_text when present" do
      resp = Response.new(output_text: "direct")
      assert Response.text(resp) == "direct"
    end

    test "falls back to message.content when output_text is nil and message has a string body" do
      msg = %Message{role: :assistant, content: "from-message"}
      resp = Response.new(message: msg)
      assert Response.text(resp) == "from-message"
    end

    test "returns nil when both output_text and message are nil" do
      resp = Response.new([])
      assert Response.text(resp) == nil
    end

    test "returns nil when message.content is a list (not a binary)" do
      msg = %Message{role: :assistant, content: [%TextPart{text: "x"}]}
      resp = Response.new(message: msg)
      assert Response.text(resp) == nil
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated Response round-trips to equal value" do
      resp =
        Response.new(
          id: "resp_1",
          model: "fake:gpt-test",
          message: %Message{role: :assistant, content: "hi"},
          output_text: "hi",
          finish_reason: :stop,
          usage: %Usage{input_tokens: 1, output_tokens: 2, total_tokens: 3}
        )

      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
