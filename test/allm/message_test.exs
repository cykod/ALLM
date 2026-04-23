defmodule ALLM.MessageTest do
  use ExUnit.Case, async: true

  alias ALLM.Message

  doctest Message

  describe "new/1" do
    test "builds a Message with required fields" do
      msg = Message.new(role: :user, content: "hi")
      assert %Message{role: :user, content: "hi", metadata: %{}} = msg
    end

    test "accepts optional name, tool_call_id, metadata" do
      msg =
        Message.new(
          role: :tool,
          content: "result",
          name: "weather",
          tool_call_id: "call_1",
          metadata: %{source: :test}
        )

      assert msg.role == :tool
      assert msg.name == "weather"
      assert msg.tool_call_id == "call_1"
      assert msg.metadata == %{source: :test}
    end

    test "raises ArgumentError when role is omitted" do
      assert_raise ArgumentError, fn -> Message.new(content: "hi") end
    end

    test "raises ArgumentError when content is omitted" do
      assert_raise ArgumentError, fn -> Message.new(role: :user) end
    end

    test "defaults metadata to an empty map" do
      msg = Message.new(role: :system, content: "be nice")
      assert msg.metadata == %{}
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated Message round-trips to equal value" do
      msg =
        Message.new(
          role: :assistant,
          content: "hello",
          name: "bot",
          tool_call_id: nil,
          metadata: %{turn: 3}
        )

      assert msg == msg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
