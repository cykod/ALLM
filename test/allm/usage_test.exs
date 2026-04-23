defmodule ALLM.UsageTest do
  use ExUnit.Case, async: true

  alias ALLM.Usage

  doctest Usage

  describe "new/1" do
    test "builds a Usage with defaults" do
      usage = Usage.new([])

      assert %Usage{
               input_tokens: nil,
               output_tokens: nil,
               cached_input_tokens: nil,
               reasoning_tokens: nil,
               total_tokens: nil,
               input_cost: nil,
               output_cost: nil,
               total_cost: nil,
               tool_usage: %{},
               extra: %{}
             } = usage
    end

    test "accepts every documented field" do
      usage =
        Usage.new(
          input_tokens: 10,
          output_tokens: 20,
          cached_input_tokens: 5,
          reasoning_tokens: 3,
          total_tokens: 30,
          input_cost: 0.001,
          output_cost: 0.002,
          total_cost: 0.003,
          tool_usage: %{"weather" => 1},
          extra: %{provider: "fake"}
        )

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
      assert usage.tool_usage == %{"weather" => 1}
      assert usage.extra == %{provider: "fake"}
    end
  end

  describe "total_tokens/1" do
    test "returns total_tokens when set" do
      assert Usage.total_tokens(Usage.new(total_tokens: 42)) == 42
    end

    test "falls back to input + output when total_tokens is nil" do
      u = Usage.new(input_tokens: 10, output_tokens: 20)
      assert Usage.total_tokens(u) == 30
    end

    test "returns nil when both total_tokens and (input or output) are nil" do
      assert Usage.total_tokens(Usage.new([])) == nil
      assert Usage.total_tokens(Usage.new(input_tokens: 5)) == nil
      assert Usage.total_tokens(Usage.new(output_tokens: 5)) == nil
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated Usage round-trips to equal value" do
      usage =
        Usage.new(
          input_tokens: 10,
          output_tokens: 20,
          total_tokens: 30,
          input_cost: 0.001,
          output_cost: 0.002,
          total_cost: 0.003,
          tool_usage: %{"weather" => 1},
          extra: %{provider: "fake"}
        )

      assert usage == usage |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
