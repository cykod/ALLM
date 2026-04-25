defmodule ALLM.ModelRefTest do
  use ExUnit.Case, async: true

  alias ALLM.ModelRef

  doctest ModelRef

  describe "new/1" do
    test "constructs from a complete keyword list" do
      ref =
        ModelRef.new(
          provider: :openai,
          id: "gpt-4.1-mini",
          capabilities: %{tools: %{enabled: true}, json_native: true},
          limits: %{context: 128_000, output: 16_000},
          pricing: %{input: 0.15, output: 0.6},
          metadata: %{source: :unit}
        )

      assert ref.provider == :openai
      assert ref.id == "gpt-4.1-mini"
      assert ref.capabilities == %{tools: %{enabled: true}, json_native: true}
      assert ref.limits == %{context: 128_000, output: 16_000}
      assert ref.pricing == %{input: 0.15, output: 0.6}
      assert ref.metadata == %{source: :unit}
    end

    test "defaults metadata to an empty map" do
      ref = ModelRef.new(provider: :local, id: "x")
      assert ref.metadata == %{}
    end

    test "raises KeyError on unknown opts" do
      assert_raise KeyError, fn ->
        ModelRef.new(provider: :openai, id: "x", bogus: :nope)
      end
    end
  end

  describe ":erlang.term_to_binary/1 round-trip" do
    test "byte-identical for a fully populated ref" do
      ref =
        ModelRef.new(
          provider: :anthropic,
          id: "claude-3-haiku",
          capabilities: %{tools: %{enabled: true}, json_native: true},
          pricing: %{input: 0.25, output: 1.25}
        )

      assert ref == ref |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips with nil pricing and minimal fields" do
      ref = ModelRef.new(provider: :local, id: "no-pricing")
      assert ref == ref |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "Jason round-trip via ALLM.Serializer" do
    test "to_json! / from_json round-trips" do
      ref =
        ModelRef.new(
          provider: :openai,
          id: "gpt-4.1-mini",
          capabilities: %{"tools" => %{"enabled" => true}, "json_native" => true},
          limits: %{"context" => 128_000, "output" => 16_000},
          pricing: %{"input" => 0.15, "output" => 0.6},
          metadata: %{"source" => "fake"}
        )

      json = ALLM.Serializer.to_json!(ref)
      {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert decoded == ref
    end

    test "tagged JSON includes the __type__ marker" do
      ref = ModelRef.new(provider: :openai, id: "x")
      json = ALLM.Serializer.to_json!(ref)
      decoded = Jason.decode!(json)
      assert decoded["__type__"] == "ALLM.ModelRef"
    end
  end

  describe "__from_tagged__/1" do
    test "hydrates each field; restores :provider via String.to_existing_atom/1" do
      data = %{
        "provider" => "openai",
        "id" => "gpt-4.1-mini",
        "capabilities" => %{"tools" => %{"enabled" => true}},
        "limits" => %{"context" => 128_000},
        "pricing" => %{"input" => 0.15, "output" => 0.6},
        "metadata" => %{"k" => "v"}
      }

      ref = ModelRef.__from_tagged__(data)
      assert ref.provider == :openai
      assert ref.id == "gpt-4.1-mini"
      assert ref.capabilities == %{"tools" => %{"enabled" => true}}
      assert ref.limits == %{"context" => 128_000}
      assert ref.pricing == %{"input" => 0.15, "output" => 0.6}
      assert ref.metadata == %{"k" => "v"}
    end

    test "missing provider stays nil; missing metadata defaults to %{}" do
      ref = ModelRef.__from_tagged__(%{"id" => "x"})
      assert ref.provider == nil
      assert ref.id == "x"
      assert ref.metadata == %{}
    end
  end
end
