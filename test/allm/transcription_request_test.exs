defmodule ALLM.TranscriptionRequestTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptionRequest

  alias ALLM.{Audio, Serializer, TranscriptionRequest}

  describe "new/1" do
    test "defaults" do
      assert %TranscriptionRequest{
               audio: nil,
               model: nil,
               language: nil,
               prompt: nil,
               timestamps: false,
               logprobs: false,
               options: %{},
               metadata: %{}
             } = TranscriptionRequest.new()
    end

    test "audio: nil is constructible (the validator rejects it, not struct!/2)" do
      assert TranscriptionRequest.new(audio: nil).audio == nil
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> TranscriptionRequest.new(bogus: 1) end
    end
  end

  describe "serializability" do
    defp full_request do
      TranscriptionRequest.new(
        audio: Audio.from_binary(<<0, 255, 1, 128>>, "audio/mpeg"),
        model: "gpt-4o-mini-transcribe",
        language: "en",
        prompt: "A fox and a dog.",
        timestamps: true,
        logprobs: true,
        options: %{"temperature" => 0},
        metadata: %{"trace" => "abc"}
      )
    end

    test "round-trips through :erlang.term_to_binary/1 with every field non-default" do
      req = full_request()
      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON; :audio comes back an %ALLM.Audio{} struct, not a map" do
      req = full_request()
      assert {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert %Audio{} = decoded.audio
      assert decoded == req
    end

    test "timestamps: true and logprobs: true survive a JSON round-trip (non-default pin)" do
      req = full_request()
      assert {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert {decoded.timestamps, decoded.logprobs} == {true, true}
    end

    test ~s(a JSON payload lacking "timestamps" and "logprobs" decodes both to false) do
      json = Jason.encode!(%{"__type__" => "ALLM.TranscriptionRequest", "data" => %{}})

      assert {:ok, %TranscriptionRequest{timestamps: false, logprobs: false}} =
               Serializer.from_json(json)
    end

    test "a default request (audio: nil) round-trips through JSON" do
      req = TranscriptionRequest.new()
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end
  end
end
