defmodule ALLM.ImageRequestTest do
  use ExUnit.Case, async: true
  doctest ALLM.ImageRequest

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImageRequest}

  describe "new/1" do
    test "with prompt and operation: :generate sets fields and inherits defaults" do
      req = ImageRequest.new(prompt: "a cat", operation: :generate)
      assert req.prompt == "a cat"
      assert req.operation == :generate
      assert req.n == 1
      assert req.response_format == :binary
      assert req.input_images == []
      assert req.options == %{}
      assert req.metadata == %{}
    end

    test "with size: {1024, 1024} preserves the tuple" do
      req = ImageRequest.new(prompt: "x", size: {1024, 1024})
      assert req.size == {1024, 1024}
    end

    test "unknown key raises KeyError via struct!/2" do
      assert_raise KeyError, fn ->
        ImageRequest.new(prompt: "x", bogus: true)
      end
    end

    test "no opts returns struct with defaults" do
      req = ImageRequest.new()
      assert req.operation == :generate
      assert req.n == 1
      assert req.response_format == :binary
    end
  end

  describe "ETF round-trip" do
    test "every operation × source-variant combination" do
      for op <- [:generate, :edit, :variation],
          src_image <- [
            Image.from_binary(<<1, 2>>, "image/png"),
            Image.from_base64("aGk=", "image/png"),
            Image.from_url("https://example.com/x.png"),
            Image.from_file("a.png")
          ] do
        req =
          ImageRequest.new(
            operation: op,
            prompt: if(op == :variation, do: nil, else: "p"),
            input_images: if(op == :generate, do: [], else: [src_image])
          )

        assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      end
    end

    test "preserves options/metadata maps and mask" do
      req =
        ImageRequest.new(
          prompt: "x",
          mask: Image.from_binary(<<9>>, "image/png"),
          options: %{"foo" => "bar"},
          metadata: %{"k" => 1}
        )

      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip — :size" do
    test "size: {1024, 1024} emits [1024, 1024] and decodes back to tuple" do
      req = ImageRequest.new(prompt: "x", size: {1024, 1024})
      json = ALLM.Serializer.to_json!(req)
      decoded = Jason.decode!(json)
      assert decoded["data"]["size"] == [1024, 1024]
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "size: :auto round-trips via the closed atom branch" do
      req = ImageRequest.new(prompt: "x", size: :auto)
      json = ALLM.Serializer.to_json!(req)
      assert Jason.decode!(json)["data"]["size"] == "auto"
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "size: \"1024x1024\" (binary) passes through verbatim — proves binary fall-through" do
      req = ImageRequest.new(prompt: "x", size: "1024x1024")
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "size: nil round-trips as nil" do
      req = ImageRequest.new(prompt: "x", size: nil)
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end
  end

  describe "JSON round-trip — :quality" do
    test "quality: :high (closed atom) decodes via closed-set restoration" do
      req = ImageRequest.new(prompt: "x", quality: :high)
      json = ALLM.Serializer.to_json!(req)
      assert Jason.decode!(json)["data"]["quality"] == "high"
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "quality: \"custom-tier\" (binary) passes through verbatim — binary fall-through" do
      req = ImageRequest.new(prompt: "x", quality: "custom-tier")
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "every closed quality atom round-trips" do
      for q <- [:low, :standard, :high, :hd, :auto] do
        req = ImageRequest.new(prompt: "x", quality: q)
        json = ALLM.Serializer.to_json!(req)
        assert {:ok, decoded} = ALLM.Serializer.from_json(json)
        assert decoded.quality == q
      end
    end

    test "quality: nil round-trips" do
      req = ImageRequest.new(prompt: "x", quality: nil)
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end
  end

  describe "JSON round-trip — closed-atom fields" do
    test "operation: :variation round-trips" do
      req = ImageRequest.new(operation: :variation)
      json = ALLM.Serializer.to_json!(req)
      assert Jason.decode!(json)["data"]["operation"] == "variation"
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "style: :natural round-trips via to_atom_field/1" do
      req = ImageRequest.new(prompt: "x", style: :natural)
      json = ALLM.Serializer.to_json!(req)
      assert Jason.decode!(json)["data"]["style"] == "natural"
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "style: nil round-trips" do
      req = ImageRequest.new(prompt: "x", style: nil)
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "background: :transparent round-trips" do
      req = ImageRequest.new(prompt: "x", background: :transparent)
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "every closed response_format atom round-trips" do
      for rf <- [:binary, :base64, :url] do
        req = ImageRequest.new(prompt: "x", response_format: rf)
        json = ALLM.Serializer.to_json!(req)
        assert {:ok, decoded} = ALLM.Serializer.from_json(json)
        assert decoded.response_format == rf
      end
    end
  end

  describe "JSON round-trip — nested images" do
    test "input_images list with binary-source image hydrates back to %Image{}" do
      img = Image.from_binary(<<1, 2>>, "image/png")
      req = ImageRequest.new(prompt: "p", operation: :edit, input_images: [img])
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end

    test "mask hydrates back to %Image{}" do
      mask = Image.from_binary(<<9>>, "image/png")
      req = ImageRequest.new(prompt: "p", mask: mask)
      json = ALLM.Serializer.to_json!(req)
      assert {:ok, ^req} = ALLM.Serializer.from_json(json)
    end
  end

  describe "__from_tagged__/1 — decoder fall-through arms" do
    # These tests exercise the non-binary fall-through arms of `decode_size/1`
    # and `decode_quality/1` directly. JSON-natural inputs (binary, list,
    # nil, "auto") all match earlier clauses; the trailing `defp
    # decode_size(other), do: other` and `defp decode_quality(other), do: other`
    # arms only fire if a caller hands `__from_tagged__/1` a raw map with a
    # non-binary, non-list, non-"auto" value (e.g., an integer or atom).

    test "decode_size/1 fall-through arm passes through a non-list non-binary value" do
      data = %{
        "operation" => "generate",
        "size" => 42,
        "response_format" => "binary"
      }

      decoded = ImageRequest.__from_tagged__(data)
      assert decoded.size == 42
    end

    test "decode_quality/1 fall-through arm passes through a non-binary value" do
      data = %{
        "operation" => "generate",
        "quality" => 99,
        "response_format" => "binary"
      }

      decoded = ImageRequest.__from_tagged__(data)
      assert decoded.quality == 99
    end

    test "decode_quality/1 binary fall-through preserves an unknown atom string" do
      # Hits `String.to_existing_atom/1` rescue in `decode_quality/1`.
      data = %{
        "operation" => "generate",
        "quality" => "this_quality_atom_does_not_exist_anywhere_xyz",
        "response_format" => "binary"
      }

      decoded = ImageRequest.__from_tagged__(data)
      assert decoded.quality == "this_quality_atom_does_not_exist_anywhere_xyz"
    end
  end

  describe "JSON decode — error path" do
    test "unknown operation atom returns {:_unknown, :atom_decode_failed}" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.ImageRequest",
          "data" => %{
            "operation" => "this_atom_definitely_does_not_exist_anywhere_xyz",
            "model" => nil,
            "prompt" => "x",
            "n" => 1,
            "size" => nil,
            "quality" => nil,
            "style" => nil,
            "background" => nil,
            "response_format" => "binary",
            "input_images" => [],
            "mask" => nil,
            "options" => %{},
            "metadata" => %{}
          }
        })

      assert {:error, %ValidationError{} = err} = ALLM.Serializer.from_json(json)
      assert err.reason == :invalid_request
      assert {:_unknown, :atom_decode_failed} in err.errors
    end
  end
end
