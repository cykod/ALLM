defmodule ALLM.ImageResponseTest do
  use ExUnit.Case, async: true
  doctest ALLM.ImageResponse

  alias ALLM.{Image, ImageResponse, ImageUsage}

  describe "new/1" do
    test "no opts produces defaults: images: [], usage: %ImageUsage{images: 0}, raw: nil" do
      resp = ImageResponse.new()
      assert resp.images == []
      assert resp.usage == %ImageUsage{}
      assert resp.usage.images == 0
      assert resp.raw == nil
      assert resp.metadata == %{}
    end

    test "opts populate the fields" do
      img = Image.from_binary(<<1>>, "image/png")
      resp = ImageResponse.new(model: "m", request_id: "req-1", images: [img])
      assert resp.model == "m"
      assert resp.request_id == "req-1"
      assert resp.images == [img]
    end

    test "unknown key raises KeyError" do
      assert_raise KeyError, fn -> ImageResponse.new(bogus: 1) end
    end
  end

  describe "ETF round-trip" do
    test "with images list and populated usage" do
      img = Image.from_binary(<<1, 2>>, "image/png")

      resp =
        ImageResponse.new(
          id: "id-1",
          request_id: "req-1",
          model: "gpt-image-1",
          images: [img],
          usage: ImageUsage.new(images: 1, input_tokens: 10),
          metadata: %{"k" => "v"}
        )

      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip" do
    test "with images list (binary source) preserves byte equality" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      resp = ImageResponse.new(model: "m", images: [img], usage: ImageUsage.new(images: 1))
      json = ALLM.Serializer.to_json!(resp)
      assert {:ok, ^resp} = ALLM.Serializer.from_json(json)
    end

    test "with default usage (zero images)" do
      resp = ImageResponse.new()
      json = ALLM.Serializer.to_json!(resp)
      assert {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert decoded.usage == %ImageUsage{}
    end

    test "raw containing a non-encodable value raises Protocol.UndefinedError" do
      resp = ImageResponse.new(raw: %{pid: self()})

      assert_raise Protocol.UndefinedError, fn ->
        ALLM.Serializer.to_json!(resp)
      end
    end
  end

  describe "__from_tagged__/1 — hydrate_usage/1 arms" do
    # These tests exercise the three `hydrate_usage/1` clauses directly.
    # JSON-natural payloads always carry a tagged `%{"__type__" => ...}`
    # usage map; the `nil` and "untagged-other" arms only fire if a caller
    # hands `__from_tagged__/1` a raw map whose `"usage"` is `nil` or a
    # plain (non-tagged) map.

    test "hydrate_usage/1 nil arm produces default %ImageUsage{}" do
      data = %{"id" => "id-1", "usage" => nil}
      decoded = ImageResponse.__from_tagged__(data)
      assert decoded.usage == %ImageUsage{}
    end

    test "hydrate_usage/1 missing-key arm produces default %ImageUsage{}" do
      # `data["usage"]` returns nil for a missing key — same arm as above.
      data = %{"id" => "id-1"}
      decoded = ImageResponse.__from_tagged__(data)
      assert decoded.usage == %ImageUsage{}
    end

    test "hydrate_usage/1 untagged-other arm passes the value through verbatim" do
      # A raw plain map (no `__type__` tag) hits the trailing `hydrate_usage(other)`
      # arm and is returned verbatim. This is a defensive arm — well-formed
      # serialized payloads always carry the `__type__` tag — but exercise it
      # so a future refactor doesn't silently lose the fall-through.
      data = %{"id" => "id-1", "usage" => %{"images" => 5}}
      decoded = ImageResponse.__from_tagged__(data)
      assert decoded.usage == %{"images" => 5}
    end

    test "hydrate_usage/1 tagged-but-non-ImageUsage payload falls back to default" do
      # The `case Serializer.hydrate(tagged)` clause's `_ -> %ImageUsage{}`
      # branch fires when the tagged hydration produces something other than
      # `%ImageUsage{}` — e.g., a tagged ALLM.Image. This is defensive but
      # exercised here so the branch is covered.
      tagged_image = %{
        "__type__" => "ALLM.Image",
        "data" => %{
          "source" => %{"type" => "binary", "value" => Base.encode64("hi")},
          "mime_type" => "image/png",
          "metadata" => %{}
        }
      }

      data = %{"id" => "id-1", "usage" => tagged_image}
      decoded = ImageResponse.__from_tagged__(data)
      assert decoded.usage == %ImageUsage{}
    end
  end
end
