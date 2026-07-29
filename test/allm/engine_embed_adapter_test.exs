defmodule ALLM.EngineEmbedAdapterTest do
  @moduledoc """
  Covers the five `:embed_adapter` sites on `ALLM.Engine`: the `@type t` /
  `defstruct` pair, the `@engine_field_keys` deny-list consumed by
  `resolve_params/2`, the `@module_fields` construction guard, and
  `__from_tagged__/1`'s `restore_module/1` call.
  """

  use ExUnit.Case, async: true

  alias ALLM.Engine
  alias ALLM.Providers.FakeEmbeddings

  describe "construction" do
    test "new/1 with embed_adapter: SomeModule sets the field" do
      engine = Engine.new(embed_adapter: FakeEmbeddings)
      assert engine.embed_adapter == FakeEmbeddings
    end

    test "the field defaults to nil" do
      assert Engine.new().embed_adapter == nil
    end

    test "new/1 with a non-atom embed_adapter raises ArgumentError" do
      assert_raise ArgumentError, ~r/embed_adapter/, fn ->
        Engine.new(embed_adapter: "not an atom")
      end
    end

    test "embed_adapter is a peer of image_adapter, not a fallback" do
      engine = Engine.new(image_adapter: ALLM.Providers.FakeImages)
      assert engine.embed_adapter == nil
    end
  end

  describe "resolve_params/2 deny-list symmetry" do
    test "does NOT forward :embed_adapter to the adapter params map" do
      engine = Engine.new(embed_adapter: FakeEmbeddings)
      params = Engine.resolve_params(engine, embed_adapter: FakeEmbeddings)

      refute Map.has_key?(params, :embed_adapter)
    end

    test "still forwards unknown provider-specific keys alongside it" do
      engine = Engine.new(embed_adapter: FakeEmbeddings)
      params = Engine.resolve_params(engine, embed_adapter: FakeEmbeddings, dimensions: 512)

      assert params == %{dimensions: 512}
    end
  end

  describe "serializability" do
    test "term_to_binary round-trip preserves :embed_adapter" do
      engine = Engine.new(embed_adapter: FakeEmbeddings, model: "text-embedding-3-small")
      assert engine == engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "JSON round-trip restores :embed_adapter as a module atom" do
      engine = Engine.new(embed_adapter: FakeEmbeddings, model: "text-embedding-3-small")

      json = ALLM.Serializer.to_json!(engine)
      assert {:ok, %Engine{} = decoded} = ALLM.Serializer.from_json(json)
      assert decoded.embed_adapter == FakeEmbeddings
      assert is_atom(decoded.embed_adapter)
    end

    test "a serialized engine with no :embed_adapter decodes to nil" do
      engine = Engine.new(adapter: ALLM.Providers.Fake)

      json = ALLM.Serializer.to_json!(engine)
      assert {:ok, %Engine{embed_adapter: nil}} = ALLM.Serializer.from_json(json)
    end
  end
end
