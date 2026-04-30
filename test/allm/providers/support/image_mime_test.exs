defmodule ALLM.Providers.Support.ImageMimeTest do
  @moduledoc """
  Phase 17.1 — `ALLM.Providers.Support.ImageMime` helper unit tests.
  See spec §35.6 and Phase 17 design §3.1.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}
  alias ALLM.Providers.Support.ImageMime

  doctest ALLM.Providers.Support.ImageMime

  describe "accept_mimes/1" do
    test ":openai accept-set" do
      assert ImageMime.accept_mimes(:openai) ==
               ~w(image/png image/jpeg image/webp image/gif)
    end

    test ":anthropic accept-set" do
      assert ImageMime.accept_mimes(:anthropic) ==
               ~w(image/png image/jpeg image/webp image/gif)
    end
  end

  describe "validate/2" do
    test "returns :ok for image/png within 20 MB (binary source)" do
      part = %ImagePart{image: Image.from_binary("hi", "image/png")}
      assert ImageMime.validate(part, ["image/png"]) == :ok
    end

    test "returns {:error, {:unsupported_image_format, mime}} for unsupported MIME" do
      part = %ImagePart{image: Image.from_binary("<svg/>", "image/svg+xml")}

      assert ImageMime.validate(part, ImageMime.accept_mimes(:openai)) ==
               {:error, {:unsupported_image_format, "image/svg+xml"}}
    end

    test "returns {:error, {:image_too_large, byte_size}} for oversize binary" do
      bytes = :binary.copy(<<0>>, 22 * 1024 * 1024)
      part = %ImagePart{image: Image.from_binary(bytes, "image/png")}
      assert {:error, {:image_too_large, size}} = ImageMime.validate(part, ["image/png"])
      assert size == 22 * 1024 * 1024
    end

    test "URL source skips size check" do
      part = %ImagePart{image: Image.from_url("https://example.com/cat.png")}
      assert ImageMime.validate(part, ImageMime.accept_mimes(:openai)) == :ok
    end

    test "missing MIME on non-URL source returns :missing_mime_type" do
      part = %ImagePart{image: %Image{source: {:base64, "aGk="}, mime_type: nil}}

      assert ImageMime.validate(part, ImageMime.accept_mimes(:openai)) ==
               {:error, :missing_mime_type}
    end

    test "encode-decode-validate keeps byte_size invariant" do
      original = "hello world"
      part = %ImagePart{image: Image.from_base64(Base.encode64(original), "image/png")}
      # validate succeeds (decoded size is 11 bytes, well under 20MB)
      assert ImageMime.validate(part, ImageMime.accept_mimes(:openai)) == :ok
    end

    test "base64 source decodes for size check" do
      bytes = :binary.copy(<<0>>, 100)
      encoded = Base.encode64(bytes)
      part = %ImagePart{image: Image.from_base64(encoded, "image/png")}
      assert ImageMime.validate(part, ImageMime.accept_mimes(:openai)) == :ok
    end
  end

  describe "validate_request/2" do
    defp text_msg, do: %Message{role: :user, content: "hi"}

    defp img_msg(image, opts \\ []) do
      %Message{
        role: :user,
        content: [
          %TextPart{text: "look"},
          %ImagePart{
            image: image,
            detail: Keyword.get(opts, :detail, :auto)
          }
        ]
      }
    end

    test "returns :ok on a request with no ImagePart" do
      req = Request.new([text_msg()])
      assert ImageMime.validate_request(req, :openai) == :ok
    end

    test "returns :ok on a request with valid ImageParts across multiple messages" do
      m1 = img_msg(Image.from_binary("a", "image/png"))
      m2 = img_msg(Image.from_url("https://example.com/x.jpg"))
      req = Request.new([m1, m2])
      assert ImageMime.validate_request(req, :openai) == :ok
      assert ImageMime.validate_request(req, :anthropic) == :ok
    end

    test "returns {:error, %ValidationError{}} for unsupported MIME with [:content, msg_idx, part_idx] path" do
      m = img_msg(Image.from_binary("<svg/>", "image/svg+xml"))
      req = Request.new([m])

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               ImageMime.validate_request(req, :openai)

      assert {[:content, 0, 1], :unsupported_image_format} in errors
    end

    test "returns error for a 21 MB image" do
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      m = img_msg(Image.from_binary(bytes, "image/png"))
      req = Request.new([m])

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               ImageMime.validate_request(req, :openai)

      assert {[:content, 0, 1], :image_too_large} in errors
    end

    test "returns :ok for a 21 MB URL-source image (size unverifiable, defer)" do
      m = img_msg(Image.from_url("https://example.com/big.png"))
      req = Request.new([m])
      assert ImageMime.validate_request(req, :openai) == :ok
    end

    test "missing MIME on non-URL source surfaces :missing_mime_type" do
      part = %ImagePart{image: %Image{source: {:base64, "aGk="}, mime_type: nil}}
      m = %Message{role: :user, content: [%TextPart{text: "x"}, part]}
      req = Request.new([m])

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               ImageMime.validate_request(req, :openai)

      assert {[:content, 0, 1], :missing_mime_type} in errors
    end

    test "accumulates per-image errors across multiple violations" do
      m1 = img_msg(Image.from_binary("<svg/>", "image/svg+xml"))
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      m3 = img_msg(Image.from_binary(bytes, "image/png"))
      req = Request.new([m1, text_msg(), m3])

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               ImageMime.validate_request(req, :openai)

      assert {[:content, 0, 1], :unsupported_image_format} in errors
      assert {[:content, 2, 1], :image_too_large} in errors
      assert length(errors) == 2
    end

    test ":openai vs :anthropic produce identical errors today (accept-sets identical)" do
      m = img_msg(Image.from_binary("<svg/>", "image/svg+xml"))
      req = Request.new([m])

      assert {:error, %ValidationError{errors: openai_errs}} =
               ImageMime.validate_request(req, :openai)

      assert {:error, %ValidationError{errors: anthropic_errs}} =
               ImageMime.validate_request(req, :anthropic)

      assert openai_errs == anthropic_errs
    end
  end
end
