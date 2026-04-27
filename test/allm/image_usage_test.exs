defmodule ALLM.ImageUsageTest do
  use ExUnit.Case, async: true
  doctest ALLM.ImageUsage

  alias ALLM.ImageUsage

  describe "new/1" do
    test "no opts produces images: 0 with every other field nil" do
      u = ImageUsage.new()
      assert u.images == 0
      assert u.size == nil
      assert u.quality == nil
      assert u.input_tokens == nil
      assert u.output_tokens == nil
      assert u.input_cost == nil
      assert u.output_cost == nil
      assert u.total_cost == nil
    end

    test "opts populate fields" do
      u = ImageUsage.new(images: 4, size: "1024x1024", input_tokens: 100, total_cost: 0.04)
      assert u.images == 4
      assert u.size == "1024x1024"
      assert u.input_tokens == 100
      assert u.total_cost == 0.04
    end

    test "unknown key raises KeyError" do
      assert_raise KeyError, fn -> ImageUsage.new(bogus: 1) end
    end
  end

  describe "ETF round-trip" do
    test "preserves every field including nils" do
      u = ImageUsage.new()
      assert u == u |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "preserves a fully-populated usage" do
      u =
        ImageUsage.new(
          images: 2,
          size: "1024x1024",
          quality: "high",
          input_tokens: 100,
          output_tokens: 200,
          input_cost: 0.012,
          output_cost: 0.024,
          total_cost: 0.036
        )

      assert u == u |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip" do
    test "with input_cost: 0.012 preserves the float value (no Decimal — Decision #1)" do
      u = ImageUsage.new(input_cost: 0.012)
      json = ALLM.Serializer.to_json!(u)
      assert {:ok, ^u} = ALLM.Serializer.from_json(json)
    end

    test "with all-nil cost fields produces same struct after decode" do
      u = ImageUsage.new()
      json = ALLM.Serializer.to_json!(u)
      assert {:ok, ^u} = ALLM.Serializer.from_json(json)
    end

    test "fully-populated usage round-trips" do
      u =
        ImageUsage.new(
          images: 3,
          size: "512x512",
          quality: "standard",
          input_tokens: 50,
          output_tokens: 100,
          input_cost: 0.001,
          output_cost: 0.002,
          total_cost: 0.003
        )

      json = ALLM.Serializer.to_json!(u)
      assert {:ok, ^u} = ALLM.Serializer.from_json(json)
    end
  end

  describe "__from_tagged__/1" do
    test "missing images key defaults to 0" do
      decoded = ImageUsage.__from_tagged__(%{})
      assert decoded.images == 0
      assert decoded.size == nil
    end

    test "fully-populated map hydrates every field" do
      decoded =
        ImageUsage.__from_tagged__(%{
          "images" => 7,
          "size" => "1024x1024",
          "quality" => "high",
          "input_tokens" => 100,
          "output_tokens" => 200,
          "input_cost" => 0.012,
          "output_cost" => 0.024,
          "total_cost" => 0.036
        })

      assert decoded.images == 7
      assert decoded.size == "1024x1024"
      assert decoded.quality == "high"
      assert decoded.input_tokens == 100
      assert decoded.output_tokens == 200
      assert decoded.input_cost == 0.012
      assert decoded.output_cost == 0.024
      assert decoded.total_cost == 0.036
    end
  end
end
