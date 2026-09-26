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
               sample_rate: nil,
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

    test "sample_rate is unguarded: a bad value constructs, the validator rejects it" do
      req = SpeechRequest.new(input: "x", sample_rate: -1)
      assert req.sample_rate == -1

      assert {:error, %{errors: [{:sample_rate, :out_of_range}]}} =
               ALLM.Validate.speech_request(req)
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
        sample_rate: 44_100,
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

    test "sample_rate: 24_000 survives JSON" do
      req = SpeechRequest.new(input: "x", format: :pcm, sample_rate: 24_000)

      assert {:ok, %SpeechRequest{sample_rate: 24_000}} =
               req |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "an absent sample_rate key decodes to nil" do
      json = Jason.encode!(%{"__type__" => "ALLM.SpeechRequest", "data" => %{"input" => "x"}})
      assert {:ok, %SpeechRequest{sample_rate: nil}} = Serializer.from_json(json)
    end

    test "a default request round-trips through JSON" do
      req = SpeechRequest.new(input: "x")
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end
  end
end
