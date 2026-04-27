defmodule ALLM.TextPartTest do
  use ExUnit.Case, async: true

  alias ALLM.{Serializer, TextPart}

  doctest TextPart

  describe "new/2" do
    test "wraps text with default empty metadata" do
      tp = TextPart.new("hello")
      assert tp.text == "hello"
      assert tp.metadata == %{}
    end

    test "accepts empty text — validation is upstream" do
      tp = TextPart.new("")
      assert tp.text == ""
    end

    test "accepts metadata keyword" do
      tp = TextPart.new("hi", metadata: %{source: :test})
      assert tp.metadata == %{source: :test}
    end

    test "raises FunctionClauseError when text is not a binary" do
      assert_raise FunctionClauseError, fn -> TextPart.new(123) end
    end
  end

  describe "term_to_binary round-trip" do
    @tag :roundtrip
    test "round-trips a fully populated TextPart" do
      tp = %TextPart{text: "hi", metadata: %{turn: 3}}
      assert tp == tp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips an empty-text TextPart" do
      tp = %TextPart{text: ""}
      assert tp == tp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "round-trips through tagged-JSON encoding (string-keyed metadata)" do
      # JSON serialization stringifies atom map keys/values in :metadata; the
      # struct field-types don't enforce atoms here so the round-trip equality
      # is over the string-keyed shape.
      tp = TextPart.new("hi", metadata: %{"source" => "test"})
      json = Serializer.to_json!(tp)
      assert {:ok, ^tp} = Serializer.from_json(json)
    end

    test "round-trips a TextPart with no metadata" do
      tp = TextPart.new("hello")
      json = Serializer.to_json!(tp)
      assert {:ok, ^tp} = Serializer.from_json(json)
    end

    test "round-trips a TextPart with empty metadata" do
      tp = %TextPart{text: "hello"}
      json = Serializer.to_json!(tp)
      assert {:ok, ^tp} = Serializer.from_json(json)
    end
  end

  describe "@enforce_keys" do
    test "raises ArgumentError when :text is omitted" do
      assert_raise ArgumentError, fn ->
        struct!(TextPart, metadata: %{})
      end
    end
  end
end
