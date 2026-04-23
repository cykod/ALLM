defmodule ALLM.ToolCallTest do
  use ExUnit.Case, async: true

  alias ALLM.ToolCall

  doctest ToolCall

  describe "new/1" do
    test "builds a ToolCall with required fields" do
      tc = ToolCall.new(id: "call_1", name: "weather", arguments: %{"city" => "SFO"})

      assert %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "SFO"}} = tc
    end

    test "accepts optional raw_arguments and metadata" do
      tc =
        ToolCall.new(
          id: "call_1",
          name: "weather",
          arguments: %{"city" => "SFO"},
          raw_arguments: ~S({"city":"SFO"}),
          metadata: %{idx: 0}
        )

      assert tc.raw_arguments == ~S({"city":"SFO"})
      assert tc.metadata == %{idx: 0}
    end

    test "raises ArgumentError when id is omitted" do
      assert_raise ArgumentError, fn ->
        ToolCall.new(name: "weather", arguments: %{})
      end
    end

    test "raises ArgumentError when name is omitted" do
      assert_raise ArgumentError, fn ->
        ToolCall.new(id: "x", arguments: %{})
      end
    end

    test "raises ArgumentError when arguments is omitted" do
      assert_raise ArgumentError, fn ->
        ToolCall.new(id: "x", name: "n")
      end
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated ToolCall round-trips to equal value" do
      tc =
        ToolCall.new(
          id: "call_1",
          name: "weather",
          arguments: %{"city" => "SFO"},
          raw_arguments: ~S({"city":"SFO"}),
          metadata: %{}
        )

      assert tc == tc |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
