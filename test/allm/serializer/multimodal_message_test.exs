defmodule ALLM.Serializer.MultimodalMessageTest do
  use ExUnit.Case, async: true

  alias ALLM.{Image, ImagePart, Message, Serializer, TextPart}

  describe "@known_modules registry" do
    test "contains TextPart and ImagePart (Phase 14.4 extension)" do
      msg = Message.new(role: :user, content: [TextPart.new("hi")])
      json = Serializer.to_json!(msg)
      assert {:ok, ^msg} = Serializer.from_json(json)
    end
  end

  describe "Message JSON round-trip with multimodal content" do
    test "single-element [%TextPart{}] content list round-trips" do
      msg = Message.new(role: :user, content: [TextPart.new("hello")])
      json = Serializer.to_json!(msg)
      assert {:ok, ^msg} = Serializer.from_json(json)
    end

    test "[%TextPart{}, %ImagePart{}] with base64-source image round-trips" do
      img = Image.from_base64("aGk=", "image/png")

      msg =
        Message.new(
          role: :user,
          content: [TextPart.new("describe this"), ImagePart.new(img, detail: :high)]
        )

      json = Serializer.to_json!(msg)
      assert {:ok, ^msg} = Serializer.from_json(json)
    end

    test "[%TextPart{}, %ImagePart{}] with URL-source image round-trips" do
      img = Image.from_url("https://example.com/cat.png")

      msg =
        Message.new(
          role: :user,
          content: [TextPart.new("describe this"), ImagePart.new(img)]
        )

      json = Serializer.to_json!(msg)
      assert {:ok, ^msg} = Serializer.from_json(json)
    end

    test "[%TextPart{}, %ImagePart{}] with binary-source image round-trips" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")

      msg =
        Message.new(
          role: :user,
          content: [TextPart.new("a"), TextPart.new("b"), ImagePart.new(img, detail: :low)]
        )

      json = Serializer.to_json!(msg)
      assert {:ok, ^msg} = Serializer.from_json(json)
    end
  end
end
