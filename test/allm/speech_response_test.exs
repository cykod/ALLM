defmodule ALLM.SpeechResponseTest do
  use ExUnit.Case, async: true
  doctest ALLM.SpeechResponse

  alias ALLM.{Audio, Serializer, SpeechRequest, SpeechResponse, Usage}

  @format_mime [
    mp3: "audio/mpeg",
    opus: "audio/opus",
    aac: "audio/aac",
    flac: "audio/flac",
    wav: "audio/wav",
    pcm: "audio/pcm"
  ]

  describe "new/1" do
    test "defaults usage to %ALLM.Usage{}, never nil" do
      resp = SpeechResponse.new()
      assert resp.usage == %Usage{}
      assert resp.metadata == %{}
      assert resp.audio == nil
      assert resp.format == nil
      assert resp.raw == nil
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> SpeechResponse.new(bogus: 1) end
    end
  end

  describe "format_to_mime/1" do
    for {format, mime} <- @format_mime do
      test "#{format} → #{mime}" do
        assert SpeechResponse.format_to_mime(unquote(format)) == unquote(mime)
      end
    end

    test "mime_to_format(format_to_mime(f)) == f for every f in formats/0" do
      for f <- SpeechRequest.formats() do
        assert SpeechResponse.mime_to_format(SpeechResponse.format_to_mime(f)) == f
      end
    end
  end

  describe "mime_to_format/1" do
    for {format, mime} <- @format_mime do
      test "#{mime} → #{format}" do
        assert SpeechResponse.mime_to_format(unquote(mime)) == unquote(format)
      end
    end

    test "strips parameters after ';'" do
      assert SpeechResponse.mime_to_format("audio/wav; codecs=1") == :wav
    end

    test "an off-table mime is nil" do
      assert SpeechResponse.mime_to_format("video/mp4") == nil
    end

    test "nil is nil" do
      assert SpeechResponse.mime_to_format(nil) == nil
    end
  end

  describe "serializability" do
    defp full_response do
      SpeechResponse.new(
        audio: Audio.from_binary(<<0, 255, 1, 200>>, "audio/mpeg"),
        format: :mp3,
        id: "sp-1",
        request_id: "req-1",
        model: "tts-1",
        provider: :openai,
        usage: %Usage{input_tokens: 27},
        raw: nil,
        metadata: %{"trace" => "abc"}
      )
    end

    test "round-trips through :erlang.term_to_binary/1" do
      resp = full_response()
      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON with non-UTF-8 audio; provider stays an atom, usage a struct" do
      resp = full_response()
      assert {:ok, decoded} = resp |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.provider == :openai
      assert %Usage{input_tokens: 27} = decoded.usage
      assert decoded.format == :mp3
      assert decoded == resp
    end

    test ~s("usage": null, or a tagged non-Usage value, decodes to %Usage{}) do
      for usage <- [nil, %{"__type__" => "ALLM.Message", "data" => %{"role" => "user"}}] do
        json =
          Jason.encode!(%{
            "__type__" => "ALLM.SpeechResponse",
            "data" => %{"usage" => usage, "metadata" => %{}}
          })

        assert {:ok, %SpeechResponse{usage: %Usage{}}} = Serializer.from_json(json)
      end
    end

    test "an untagged usage value passes through verbatim" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.SpeechResponse",
          "data" => %{"usage" => %{"input_tokens" => 3}}
        })

      assert {:ok, %SpeechResponse{usage: %{"input_tokens" => 3}}} = Serializer.from_json(json)
    end

    test ~s(a JSON payload without "usage" decodes to %Usage{}, not nil) do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.SpeechResponse",
          "data" => %{"format" => "wav", "metadata" => %{}}
        })

      assert {:ok, %SpeechResponse{usage: %Usage{}, format: :wav}} = Serializer.from_json(json)
    end
  end
end
