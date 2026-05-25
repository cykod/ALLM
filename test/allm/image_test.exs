defmodule ALLM.ImageTest do
  use ExUnit.Case, async: true
  doctest ALLM.Image

  alias ALLM.Error.ValidationError
  alias ALLM.Image

  describe "from_binary/2" do
    test "wraps bytes with explicit MIME type" do
      img = Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      assert img.source == {:binary, <<137, 80, 78, 71>>}
      assert img.mime_type == "image/png"
      assert img.metadata == %{}
    end

    test "raises FunctionClauseError when mime_type is nil" do
      assert_raise FunctionClauseError, fn ->
        Image.from_binary(<<1, 2>>, nil)
      end
    end

    test "raises FunctionClauseError when first arg is not a binary" do
      assert_raise FunctionClauseError, fn ->
        Image.from_binary(123, "image/png")
      end
    end
  end

  describe "from_base64/2" do
    test "stores the encoded string verbatim — does NOT decode" do
      img = Image.from_base64("aGk=", "image/png")
      assert img.source == {:base64, "aGk="}
      assert img.mime_type == "image/png"
    end

    test "raises FunctionClauseError when mime_type is nil" do
      assert_raise FunctionClauseError, fn ->
        Image.from_base64("aGk=", nil)
      end
    end
  end

  describe "from_data_uri/1 (Phase 21.5)" do
    test "parses a standard data:<mime>;base64,<encoded> URI" do
      img = Image.from_data_uri("data:image/png;base64,aGk=")
      assert img.source == {:base64, "aGk="}
      assert img.mime_type == "image/png"
    end

    test "supports JPEG and other common mime types" do
      img = Image.from_data_uri("data:image/jpeg;base64,QUJDRA==")
      assert img.source == {:base64, "QUJDRA=="}
      assert img.mime_type == "image/jpeg"
    end

    test "raises ArgumentError when the data: prefix is missing" do
      assert_raise ArgumentError, ~r/data:/i, fn ->
        Image.from_data_uri("image/png;base64,aGk=")
      end
    end

    test "raises ArgumentError when the ;base64, segment is missing (URL-encoded form unsupported)" do
      assert_raise ArgumentError, ~r/base64/i, fn ->
        Image.from_data_uri("data:image/png,hello%20world")
      end
    end

    test "raises ArgumentError on an empty mime segment" do
      assert_raise ArgumentError, fn ->
        Image.from_data_uri("data:;base64,aGk=")
      end
    end

    test "round-trips through to_data_uri/1" do
      uri = "data:image/png;base64,aGk="
      img = Image.from_data_uri(uri)
      assert {:ok, ^uri} = Image.to_data_uri(img)
    end
  end

  describe "from_url/1" do
    test "stores the URL with nil mime_type" do
      img = Image.from_url("https://example.com/x.png")
      assert img.source == {:url, "https://example.com/x.png"}
      assert img.mime_type == nil
    end

    test "empty URL passes through verbatim (Layer A purity)" do
      img = Image.from_url("")
      assert img.source == {:url, ""}
      assert img.mime_type == nil
    end
  end

  describe "from_file/1" do
    test ".png maps to image/png" do
      img = Image.from_file("fixtures/cat.png")
      assert img.source == {:file, "fixtures/cat.png"}
      assert img.mime_type == "image/png"
    end

    test ".JPG (uppercase) maps to image/jpeg via case-insensitive lookup" do
      img = Image.from_file("fixtures/cat.JPG")
      assert img.mime_type == "image/jpeg"
    end

    test ".jpeg maps to image/jpeg" do
      assert Image.from_file("a.jpeg").mime_type == "image/jpeg"
    end

    test ".gif maps to image/gif" do
      assert Image.from_file("a.gif").mime_type == "image/gif"
    end

    test ".webp maps to image/webp" do
      assert Image.from_file("a.webp").mime_type == "image/webp"
    end

    test "unknown extension leaves mime_type nil" do
      assert Image.from_file("fixtures/noext").mime_type == nil
      assert Image.from_file("fixtures/file.xyz").mime_type == nil
    end

    test "does NOT call File.read — accepts a missing path without error" do
      img = Image.from_file("/does/not/exist.png")
      assert img.source == {:file, "/does/not/exist.png"}
      assert img.mime_type == "image/png"
    end
  end

  describe "to_binary/1" do
    test "{:binary, b} returns {:ok, b} verbatim" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      assert Image.to_binary(img) == {:ok, <<1, 2, 3>>}
    end

    test "{:base64, valid} decodes" do
      img = Image.from_base64("aGVsbG8=", "image/png")
      assert Image.to_binary(img) == {:ok, "hello"}
    end

    test "{:base64, invalid} returns {:error, :invalid_base64}" do
      img = Image.from_base64("not~b64", "image/png")
      assert Image.to_binary(img) == {:error, :invalid_base64}
    end

    test "{:url, _} returns {:error, :remote_source}" do
      img = Image.from_url("https://example.com/x.png")
      assert Image.to_binary(img) == {:error, :remote_source}
    end

    test "{:file, valid} returns the file contents" do
      path =
        Path.join(System.tmp_dir!(), "allm_image_test_#{System.unique_integer([:positive])}.bin")

      File.write!(path, "filebytes")

      try do
        img = %Image{source: {:file, path}, mime_type: "application/octet-stream"}
        assert Image.to_binary(img) == {:ok, "filebytes"}
      after
        File.rm_rf!(path)
      end
    end

    test "{:file, missing} returns {:error, :enoent}" do
      img = %Image{source: {:file, "/does/not/exist/allm-image-test"}, mime_type: nil}
      assert Image.to_binary(img) == {:error, :enoent}
    end
  end

  describe "to_data_uri/1" do
    test "{:binary, _} with mime returns data URI with Base.encode64" do
      img = Image.from_binary("hi", "image/png")
      assert Image.to_data_uri(img) == {:ok, "data:image/png;base64,aGk="}
    end

    test "{:base64, _} with mime forwards encoded string verbatim (no decode/re-encode)" do
      img = Image.from_base64("aGVsbG8=", "image/jpeg")
      assert Image.to_data_uri(img) == {:ok, "data:image/jpeg;base64,aGVsbG8="}
    end

    test "{:file, _} with mime reads + encodes" do
      path =
        Path.join(
          System.tmp_dir!(),
          "allm_image_data_uri_#{System.unique_integer([:positive])}.bin"
        )

      File.write!(path, "hello")

      try do
        img = %Image{source: {:file, path}, mime_type: "image/png"}
        assert Image.to_data_uri(img) == {:ok, "data:image/png;base64,aGVsbG8="}
      after
        File.rm_rf!(path)
      end
    end

    test "{:url, _} returns {:error, :remote_source}" do
      img = Image.from_url("https://example.com/x.png")
      assert Image.to_data_uri(img) == {:error, :remote_source}
    end

    test "missing mime_type returns {:error, :missing_mime_type}" do
      img = %Image{source: {:binary, <<1, 2>>}, mime_type: nil}
      assert Image.to_data_uri(img) == {:error, :missing_mime_type}
    end

    test "{:file, missing} returns the File.read error tuple" do
      img = %Image{source: {:file, "/does/not/exist/allm-image-data-uri"}, mime_type: "image/png"}
      assert Image.to_data_uri(img) == {:error, :enoent}
    end
  end

  describe "ETF round-trip" do
    test "{:binary, _} preserves bytes verbatim" do
      img = Image.from_binary(<<1, 2, 3, 4, 5>>, "image/png")
      assert img == img |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "{:base64, _} preserves the encoded string" do
      img = Image.from_base64("aGVsbG8=", "image/png")
      assert img == img |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "{:url, _} preserves the URL" do
      img = Image.from_url("https://example.com/x.png")
      assert img == img |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "{:file, _} preserves the path verbatim — no I/O" do
      img = Image.from_file("fixtures/cat.png")
      assert img == img |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "all auxiliary fields round-trip" do
      img = %Image{
        source: {:binary, <<1, 2>>},
        mime_type: "image/png",
        width: 256,
        height: 128,
        prompt: "a cat",
        revised_prompt: "a polite cat",
        metadata: %{"k" => "v"}
      }

      assert img == img |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "{:binary, _} variant — bytes Base64-encoded on the wire" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      json = ALLM.Serializer.to_json!(img)

      decoded = Jason.decode!(json)
      assert decoded["__type__"] == "ALLM.Image"

      assert decoded["data"]["source"] == %{
               "type" => "binary",
               "value" => Base.encode64(<<1, 2, 3>>)
             }

      assert {:ok, ^img} = ALLM.Serializer.from_json(json)
    end

    test "{:base64, _} variant" do
      img = Image.from_base64("aGk=", "image/png")
      json = ALLM.Serializer.to_json!(img)

      decoded = Jason.decode!(json)
      assert decoded["data"]["source"] == %{"type" => "base64", "value" => "aGk="}

      assert {:ok, ^img} = ALLM.Serializer.from_json(json)
    end

    test "{:url, _} variant — URL preserved verbatim, NOT Base64-encoded" do
      img = Image.from_url("https://example.com/x.png")
      json = ALLM.Serializer.to_json!(img)

      decoded = Jason.decode!(json)

      assert decoded["data"]["source"] == %{
               "type" => "url",
               "value" => "https://example.com/x.png"
             }

      assert {:ok, ^img} = ALLM.Serializer.from_json(json)
    end

    test "{:file, _} variant — path preserved verbatim" do
      img = Image.from_file("fixtures/cat.png")
      json = ALLM.Serializer.to_json!(img)

      decoded = Jason.decode!(json)
      assert decoded["data"]["source"] == %{"type" => "file", "value" => "fixtures/cat.png"}

      assert {:ok, ^img} = ALLM.Serializer.from_json(json)
    end

    test "unknown source type tag surfaces as :atom_decode_failed" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Image",
          "data" => %{
            "source" => %{"type" => "bogus", "value" => "x"},
            "mime_type" => nil,
            "width" => nil,
            "height" => nil,
            "prompt" => nil,
            "revised_prompt" => nil,
            "metadata" => %{}
          }
        })

      assert {:error, %ValidationError{} = err} = ALLM.Serializer.from_json(json)
      assert err.reason == :invalid_request
      assert {:_unknown, :atom_decode_failed} in err.errors
    end

    test "binary source with invalid base64 surfaces as [:source, :invalid_base64]" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Image",
          "data" => %{
            "source" => %{"type" => "binary", "value" => "not~b64"},
            "mime_type" => nil,
            "width" => nil,
            "height" => nil,
            "prompt" => nil,
            "revised_prompt" => nil,
            "metadata" => %{}
          }
        })

      assert {:error, %ValidationError{} = err} = ALLM.Serializer.from_json(json)
      # The pre-built ValidationError raised inside __from_tagged__/1 escapes
      # the serializer's ArgumentError rescue and surfaces directly.
      assert err.reason == :invalid_request
      assert {[:source], :invalid_base64} in err.errors
    end
  end
end
