defmodule ALLM.ImagePartTest do
  use ExUnit.Case, async: true

  alias ALLM.{Image, ImagePart, Serializer}

  doctest ImagePart

  describe "new/2" do
    test "wraps an Image with default :auto detail and empty metadata" do
      img = Image.from_url("https://example.com/cat.png")
      part = ImagePart.new(img)
      assert part.image == img
      assert part.detail == :auto
      assert part.metadata == %{}
    end

    test "accepts :detail keyword for :high" do
      img = Image.from_url("https://example.com/cat.png")
      assert ImagePart.new(img, detail: :high).detail == :high
    end

    test "accepts :detail keyword for :low" do
      img = Image.from_url("https://example.com/cat.png")
      assert ImagePart.new(img, detail: :low).detail == :low
    end

    test "accepts :metadata keyword" do
      img = Image.from_url("https://example.com/cat.png")
      part = ImagePart.new(img, metadata: %{source: :test})
      assert part.metadata == %{source: :test}
    end

    test "raises FunctionClauseError when image is not an %Image{}" do
      assert_raise FunctionClauseError, fn ->
        ImagePart.new(%{not: :an_image})
      end
    end
  end

  describe "term_to_binary round-trip" do
    @tag :roundtrip
    test "round-trips with a URL-source image" do
      part = ImagePart.new(Image.from_url("https://example.com/x.png"), detail: :high)
      assert part == part |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips with a binary-source image" do
      part = ImagePart.new(Image.from_binary(<<1, 2, 3>>, "image/png"))
      assert part == part |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips with a base64-source image" do
      part = ImagePart.new(Image.from_base64("aGk=", "image/png"), detail: :low)
      assert part == part |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips with a file-source image" do
      part = ImagePart.new(Image.from_file("/tmp/cat.png"))
      assert part == part |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "round-trips with a URL-source image and :auto detail" do
      part = ImagePart.new(Image.from_url("https://example.com/x.png"))
      json = Serializer.to_json!(part)
      assert {:ok, ^part} = Serializer.from_json(json)
    end

    test "round-trips with a binary-source image and :high detail" do
      part = ImagePart.new(Image.from_binary(<<1, 2>>, "image/png"), detail: :high)
      json = Serializer.to_json!(part)
      assert {:ok, ^part} = Serializer.from_json(json)
    end

    test "round-trips with a base64-source image and :low detail" do
      part = ImagePart.new(Image.from_base64("aGk=", "image/png"), detail: :low)
      json = Serializer.to_json!(part)
      assert {:ok, ^part} = Serializer.from_json(json)
    end

    test "round-trips with a file-source image" do
      part = ImagePart.new(Image.from_file("/tmp/cat.png"))
      json = Serializer.to_json!(part)
      assert {:ok, ^part} = Serializer.from_json(json)
    end
  end

  describe "@enforce_keys" do
    test "raises ArgumentError when :image is omitted" do
      assert_raise ArgumentError, fn ->
        struct!(ImagePart, detail: :auto)
      end
    end
  end
end
