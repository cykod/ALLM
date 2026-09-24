defmodule ALLM.ValidateSpeechRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError
  alias ALLM.{SpeechRequest, Validate}

  defp errors_for(opts) do
    {:error, err} = Validate.speech_request(struct!(SpeechRequest, opts))
    assert err.reason == :invalid_speech_request
    err.errors
  end

  describe "speech_request/1 — happy path" do
    test ":ok for a minimal request" do
      assert Validate.speech_request(SpeechRequest.new(input: "Hello.")) == :ok
    end

    test ":ok with every optional field set" do
      req =
        SpeechRequest.new(
          input: "Hello.",
          model: "tts-1",
          voice: "alloy",
          format: :wav,
          instructions: "calm",
          speed: 1.5
        )

      assert Validate.speech_request(req) == :ok
    end

    test ":ok for every format in formats/0" do
      for f <- SpeechRequest.formats() do
        assert Validate.speech_request(SpeechRequest.new(input: "x", format: f)) == :ok
      end
    end

    test "provider speed ranges are not validated — 5 passes" do
      assert Validate.speech_request(SpeechRequest.new(input: "x", speed: 5)) == :ok
    end
  end

  # One test per row of the field-error vocabulary table.
  describe "speech_request/1 — field-error vocabulary" do
    test "a non-binary :input hard-rejects with exactly [{:input, :invalid_shape}]" do
      assert errors_for(input: nil, model: 42, format: :ogg, speed: -1) ==
               [{:input, :invalid_shape}]

      assert errors_for(input: 42) == [{:input, :invalid_shape}]
    end

    test ~s(input: "" yields {:input, :empty}) do
      assert errors_for(input: "") == [{:input, :empty}]
    end

    test "a non-UTF-8 :input yields {:input, :invalid_encoding}" do
      assert errors_for(input: <<0xFF, 0xFE>>) == [{:input, :invalid_encoding}]
    end

    test "a non-binary :model yields {:model, :invalid_shape}" do
      assert errors_for(input: "x", model: :tts) == [{:model, :invalid_shape}]
    end

    test "a non-binary :voice yields {:voice, :invalid_shape}" do
      assert errors_for(input: "x", voice: :alloy) == [{:voice, :invalid_shape}]
    end

    test "a non-binary :instructions yields {:instructions, :invalid_shape}" do
      assert errors_for(input: "x", instructions: 1) == [{:instructions, :invalid_shape}]
    end

    test "an off-enum :format yields {:format, :unknown}" do
      assert errors_for(input: "x", format: :ogg) == [{:format, :unknown}]
      assert errors_for(input: "x", format: "mp3") == [{:format, :unknown}]
    end

    test "a non-positive or non-numeric :speed yields {:speed, :out_of_range}" do
      assert errors_for(input: "x", speed: 0) == [{:speed, :out_of_range}]
      assert errors_for(input: "x", speed: -0.5) == [{:speed, :out_of_range}]
      assert errors_for(input: "x", speed: "fast") == [{:speed, :out_of_range}]
    end
  end

  describe "speech_request/1 — accumulation" do
    test "every non-hard rule accumulates into one error list" do
      errors =
        errors_for(
          input: "",
          model: 1,
          voice: 2,
          format: :ogg,
          instructions: 3,
          speed: 0
        )

      assert MapSet.new(errors) ==
               MapSet.new([
                 {:input, :empty},
                 {:model, :invalid_shape},
                 {:voice, :invalid_shape},
                 {:format, :unknown},
                 {:instructions, :invalid_shape},
                 {:speed, :out_of_range}
               ])

      assert length(errors) == 6
    end
  end

  describe "ValidationError enum extension" do
    test ":invalid_speech_request is a legal ValidationError reason" do
      assert %ValidationError{reason: :invalid_speech_request} =
               ValidationError.new(:invalid_speech_request, [])
    end
  end
end
