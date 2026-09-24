defmodule ALLM.SpeechRequestTest do
  use ExUnit.Case, async: true
  doctest ALLM.SpeechRequest

  alias ALLM.{Serializer, SpeechRequest}

  describe "new/1" do
    test "defaults" do
      req = SpeechRequest.new()

      assert %SpeechRequest{
               input: "",
               model: nil,
               voice: nil,
               format: nil,
               instructions: nil,
               speed: nil,
               options: %{},
               metadata: %{}
             } = req
    end

    test "input: \"\" is constructible (the validator rejects it, not struct!/2)" do
      assert SpeechRequest.new(input: "").input == ""
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> SpeechRequest.new(bogus: 1) end
    end
  end

  describe "formats/0" do
    test "is the closed six-atom list, in order" do
      assert SpeechRequest.formats() == [:mp3, :opus, :aac, :flac, :wav, :pcm]
    end
  end

  describe "serializability" do
    defp full_request do
      SpeechRequest.new(
        input: "Hello there.",
        model: "tts-1",
        voice: "alloy",
        format: :opus,
        instructions: "Speak slowly.",
        speed: 1.25,
        options: %{"stream_format" => "audio"},
        metadata: %{"trace" => "abc"}
      )
    end

    test "round-trips through :erlang.term_to_binary/1 with every field non-default" do
      req = full_request()
      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON with every field non-default; :format stays an atom" do
      req = full_request()
      assert {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded == req
      assert decoded.format == :opus
    end

    test "a default request round-trips through JSON" do
      req = SpeechRequest.new(input: "x")
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end
  end
end
