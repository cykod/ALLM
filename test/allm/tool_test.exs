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

  describe "new/1 :manual field (Phase 18.1)" do
    test "with manual: true sets the field" do
      tool = Tool.new(name: "w", description: "d", schema: %{}, manual: true)
      assert tool.manual == true
    end

    test "without :manual defaults to false" do
      tool = Tool.new(name: "w", description: "d", schema: %{})
      assert tool.manual == false
    end

    test "with manual: false sets the field explicitly" do
      tool = Tool.new(name: "w", description: "d", schema: %{}, manual: false)
      assert tool.manual == false
    end

    test "with manual: nil raises ArgumentError" do
      # Per Phase 18.1 design: :manual is boolean() — nil is not legal.
      # `struct!/2` would silently accept manual: nil (overwriting the
      # default), so `new/1` adds an explicit guard.
      assert_raise ArgumentError, ~r/:manual must be a boolean/, fn ->
        Tool.new(name: "w", description: "d", schema: %{}, manual: nil)
      end
    end

    test "with manual: \"true\" (string) raises ArgumentError" do
      assert_raise ArgumentError, ~r/:manual must be a boolean/, fn ->
        Tool.new(name: "w", description: "d", schema: %{}, manual: "true")
      end
    end
  end

  describe "ALLM.tool/1 keyword pass-through" do
    test "forwards :manual to Tool.new/1" do
      tool = ALLM.tool(name: "w", description: "d", schema: %{}, manual: true)
      assert %Tool{manual: true} = tool
    end

    test "preserves manual: false default when omitted" do
      tool = ALLM.tool(name: "w", description: "d", schema: %{})
      assert tool.manual == false
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

    @tag :roundtrip
    test "a Tool with manual: true round-trips preserving :manual" do
      tool =
        Tool.new(
          name: "charge_card",
          description: "Charge a credit card",
          schema: %{"type" => "object"},
          manual: true
        )

      decoded = tool |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      assert decoded == tool
      assert decoded.manual == true
    end
  end

  describe "JSON round-trip via Serializer" do
    test "a Tool with manual: true round-trips preserving :manual" do
      tool =
        Tool.new(
          name: "charge_card",
          description: "Charge a credit card",
          schema: %{"type" => "object"},
          manual: true
        )

      json = Jason.encode!(tool)
      {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert %Tool{manual: true, name: "charge_card"} = decoded
    end

    test "a Tool with manual: false (default) round-trips preserving :manual" do
      tool = Tool.new(name: "w", description: "d", schema: %{"type" => "object"})

      json = Jason.encode!(tool)
      {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert decoded.manual == false
    end
  end

  describe "__from_tagged__/1" do
    test "with missing \"manual\" key returns manual: false" do
      data = %{
        "__type" => "ALLM.Tool",
        "name" => "w",
        "description" => "d",
        "schema" => %{"type" => "object"}
      }

      tool = Tool.__from_tagged__(data)
      assert tool.manual == false
    end

    test "with explicit \"manual\": null returns manual: false" do
      data = %{
        "__type" => "ALLM.Tool",
        "name" => "w",
        "description" => "d",
        "schema" => %{"type" => "object"},
        "manual" => nil
      }

      tool = Tool.__from_tagged__(data)
      assert tool.manual == false
    end

    test "with \"manual\": true returns manual: true" do
      data = %{
        "__type" => "ALLM.Tool",
        "name" => "w",
        "description" => "d",
        "schema" => %{"type" => "object"},
        "manual" => true
      }

      tool = Tool.__from_tagged__(data)
      assert tool.manual == true
    end
  end
end
