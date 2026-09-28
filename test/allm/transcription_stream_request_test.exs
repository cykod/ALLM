defmodule ALLM.TranscriptionStreamRequestTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptionStreamRequest

  alias ALLM.{Serializer, TranscriptionStreamRequest}

  describe "new/1" do
    test "defaults are 16_000 / :vad" do
      assert %TranscriptionStreamRequest{
               model: nil,
               language: nil,
               sample_rate: 16_000,
               commit_strategy: :vad,
               timestamps: false,
               logprobs: false,
               options: %{},
               metadata: %{}
             } = TranscriptionStreamRequest.new()
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> TranscriptionStreamRequest.new(bogus: 1) end
    end

    test "fields are unguarded: bad values construct, the validator rejects them" do
      cfg = TranscriptionStreamRequest.new(sample_rate: 0, commit_strategy: :never, model: 1)
      assert %TranscriptionStreamRequest{sample_rate: 0, commit_strategy: :never} = cfg
      assert {:error, _} = ALLM.Validate.transcription_stream_request(cfg)
    end
  end

  describe "commit_strategies/0" do
    test "is [:vad, :manual]" do
      assert TranscriptionStreamRequest.commit_strategies() == [:vad, :manual]
    end
  end

  describe "serializability" do
    defp non_default do
      TranscriptionStreamRequest.new(
        model: "scribe_v2_realtime",
        language: "en",
        sample_rate: 8_000,
        commit_strategy: :manual,
        timestamps: true,
        logprobs: true,
        options: %{"vad_threshold" => 0.4},
        metadata: %{"trace" => "abc"}
      )
    end

    test "round-trips through :erlang.term_to_binary/1" do
      cfg = non_default()
      assert cfg == cfg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON with non-default sample_rate and commit_strategy" do
      cfg = non_default()
      assert {:ok, decoded} = cfg |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.sample_rate == 8_000
      assert decoded.commit_strategy == :manual
      assert decoded == cfg
    end

    test "timestamps: true and logprobs: true survive a JSON round-trip (non-default pin)" do
      cfg = non_default()
      assert {:ok, decoded} = cfg |> Serializer.to_json!() |> Serializer.from_json()
      assert {decoded.timestamps, decoded.logprobs} == {true, true}
    end

    test "a JSON payload lacking both keys decodes to the defaults" do
      json =
        Jason.encode!(%{"__type__" => "ALLM.TranscriptionStreamRequest", "data" => %{}})

      assert {:ok,
              %TranscriptionStreamRequest{
                sample_rate: 16_000,
                commit_strategy: :vad,
                timestamps: false,
                logprobs: false
              }} = Serializer.from_json(json)
    end
  end
end
