defmodule ALLM.ValidateTranscriptionStreamRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{TranscriptionStreamRequest, Validate}

  defp errors_for(opts) do
    {:error, err} = Validate.transcription_stream_request(struct!(TranscriptionStreamRequest, opts))
    assert err.reason == :invalid_transcription_request
    err.errors
  end

  describe "transcription_stream_request/1 — happy path" do
    test ":ok for the defaults" do
      assert Validate.transcription_stream_request(TranscriptionStreamRequest.new()) == :ok
    end

    test ":ok with every field set, for each commit strategy" do
      for strategy <- TranscriptionStreamRequest.commit_strategies() do
        cfg =
          TranscriptionStreamRequest.new(
            model: "m",
            language: "en",
            sample_rate: 48_000,
            commit_strategy: strategy,
            options: %{"a" => 1},
            metadata: %{"b" => 2}
          )

        assert Validate.transcription_stream_request(cfg) == :ok
      end
    end
  end

  # One test per row of the field-error vocabulary table.
  describe "transcription_stream_request/1 — field-error vocabulary" do
    test "a non-positive-integer :sample_rate yields {:sample_rate, :out_of_range}" do
      for rate <- [0, -8_000, nil, 16_000.0, "16000"] do
        assert errors_for(sample_rate: rate) == [{:sample_rate, :out_of_range}]
      end
    end

    test "an off-enum :commit_strategy yields {:commit_strategy, :unknown}" do
      for strategy <- [:never, nil, "vad"] do
        assert errors_for(commit_strategy: strategy) == [{:commit_strategy, :unknown}]
      end
    end

    test "a non-binary :model yields {:model, :invalid_shape}" do
      assert errors_for(model: 1) == [{:model, :invalid_shape}]
    end

    test "a non-binary :language yields {:language, :invalid_shape}" do
      assert errors_for(language: :en) == [{:language, :invalid_shape}]
    end

    test "a non-map :options yields {:options, :invalid_shape}" do
      assert errors_for(options: nil) == [{:options, :invalid_shape}]
    end

    test "a non-map :metadata yields {:metadata, :invalid_shape}" do
      assert errors_for(metadata: [a: 1]) == [{:metadata, :invalid_shape}]
    end
  end

  describe "transcription_stream_request/1 — span flags" do
    test "true and false are both :ok for each flag" do
      for ts <- [true, false], lp <- [true, false] do
        cfg = TranscriptionStreamRequest.new(timestamps: ts, logprobs: lp)
        assert Validate.transcription_stream_request(cfg) == :ok
      end
    end

    test ~s(timestamps: "yes" yields {:timestamps, :invalid_shape}) do
      assert errors_for(timestamps: "yes") == [{:timestamps, :invalid_shape}]
    end

    test "logprobs: nil yields {:logprobs, :invalid_shape}" do
      assert errors_for(logprobs: nil) == [{:logprobs, :invalid_shape}]
    end

    test "both flag errors accumulate with an existing field error" do
      assert errors_for(language: 1, timestamps: "yes", logprobs: nil) == [
               {:language, :invalid_shape},
               {:timestamps, :invalid_shape},
               {:logprobs, :invalid_shape}
             ]
    end
  end

  describe "transcription_stream_request/1 — accumulation" do
    test "every rule accumulates into one error list, in field order" do
      assert errors_for(
               sample_rate: 0,
               commit_strategy: :never,
               model: 1,
               language: 2,
               timestamps: 3,
               logprobs: 4,
               options: nil,
               metadata: nil
             ) == [
               {:sample_rate, :out_of_range},
               {:commit_strategy, :unknown},
               {:model, :invalid_shape},
               {:language, :invalid_shape},
               {:timestamps, :invalid_shape},
               {:logprobs, :invalid_shape},
               {:options, :invalid_shape},
               {:metadata, :invalid_shape}
             ]
    end
  end
end
