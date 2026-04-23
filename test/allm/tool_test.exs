defmodule ALLM.ToolTest do
  use ExUnit.Case, async: true

  alias ALLM.Tool

  doctest Tool

  describe "new/1" do
    test "builds a Tool with required fields" do
      tool = Tool.new(name: "weather", description: "weather by city", schema: %{type: "object"})

      assert %Tool{name: "weather", description: "weather by city", schema: %{type: "object"}} =
               tool
    end

    test "accepts an optional handler" do
      handler = fn _ -> {:ok, "sunny"} end
      tool = Tool.new(name: "w", description: "d", schema: %{}, handler: handler)
      assert is_function(tool.handler, 1)
    end

    test "raises ArgumentError when name is omitted" do
      assert_raise ArgumentError, fn -> Tool.new(description: "d", schema: %{}) end
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a Tool without a handler round-trips to equal value" do
      tool =
        Tool.new(
          name: "weather",
          description: "weather by city",
          schema: %{"type" => "object"},
          metadata: %{version: 1}
        )

      assert tool == tool |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
