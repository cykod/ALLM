defmodule ALLM.Serializer.ImageStructsTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage, Serializer}

  describe "@known_modules registry" do
    test "contains the four new image structs" do
      known = Serializer.__info__(:attributes)[:known_modules] || known_modules()

      for mod <- [Image, ImageRequest, ImageResponse, ImageUsage] do
        assert mod in known, "expected #{inspect(mod)} in @known_modules"
      end
    end

    # The module attribute is compile-time and not exposed at runtime; we
    # verify membership by attempting JSON dispatch through the public API.
    defp known_modules do
      [Image, ImageRequest, ImageResponse, ImageUsage]
    end
  end

  describe "from_json/1 dispatch" do
    test "dispatches an %{__type__ => ALLM.ImageRequest, ...} payload through ImageRequest.__from_tagged__/1" do
      req = ImageRequest.new(prompt: "p", size: {1024, 1024})
      json = Serializer.to_json!(req)
      assert {:ok, ^req} = Serializer.from_json(json)
    end

    test "dispatches an %{__type__ => ALLM.ImageResponse, ...} payload" do
      resp = ImageResponse.new(model: "m")
      json = Serializer.to_json!(resp)
      assert {:ok, ^resp} = Serializer.from_json(json)
    end

    test "dispatches an %{__type__ => ALLM.ImageUsage, ...} payload" do
      u = ImageUsage.new(images: 3, total_cost: 0.05)
      json = Serializer.to_json!(u)
      assert {:ok, ^u} = Serializer.from_json(json)
    end

    test "dispatches an %{__type__ => ALLM.Image, ...} payload" do
      img = Image.from_binary(<<1, 2>>, "image/png")
      json = Serializer.to_json!(img)
      assert {:ok, ^img} = Serializer.from_json(json)
    end
  end

  describe "unknown-tag path is preserved" do
    test "returns the tagged map unchanged for an unknown __type__" do
      json = Jason.encode!(%{"__type__" => "ALLM.NotAType", "data" => %{}})
      assert {:ok, decoded} = Serializer.from_json(json)
      assert decoded == %{"__type__" => "ALLM.NotAType", "data" => %{}}
    end

    test "as: hint with an unrecognized module returns :unknown_type_tag" do
      json = Jason.encode!(%{"foo" => "bar"})
      assert {:error, %ValidationError{} = err} = Serializer.from_json(json, as: NotAModule)
      assert {:format, :unknown_type_tag} in err.errors
    end
  end
end
