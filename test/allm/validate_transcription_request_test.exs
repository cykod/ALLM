defmodule ALLM.ValidateTranscriptionRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, Validate}
  alias ALLM.Error.ValidationError

  @audio Audio.from_file("/nope/clip.mp3")

  defp errors_for(opts) do
    {:error, err} = Validate.transcription_request(struct!(TranscriptionRequest, opts))
    assert err.reason == :invalid_transcription_request
    err.errors
  end

  describe "transcription_request/1 — happy path" do
    test ":ok for each Audio source shape" do
      for audio <- [
            @audio,
            Audio.from_binary(<<1, 2>>, "audio/wav"),
            Audio.from_base64("aGk=", "audio/wav")
          ] do
        assert Validate.transcription_request(TranscriptionRequest.new(audio: audio)) == :ok
      end
    end

    test ":ok with every optional field set" do
      req =
        TranscriptionRequest.new(audio: @audio, model: "whisper-1", language: "en", prompt: "p")

      assert Validate.transcription_request(req) == :ok
    end

    test "a missing file is not checked here — size and existence are adapter gates" do
      assert Validate.transcription_request(TranscriptionRequest.new(audio: @audio)) == :ok
    end
  end

  describe "transcription_request/1 — field-error vocabulary" do
    test "a non-%Audio{} :audio hard-rejects with exactly [{:audio, :invalid_shape}]" do
      assert errors_for(audio: nil, model: 1, language: 2) == [{:audio, :invalid_shape}]
      assert errors_for(audio: "clip.mp3") == [{:audio, :invalid_shape}]
      assert errors_for(audio: %{source: {:binary, <<1>>}}) == [{:audio, :invalid_shape}]
    end

    test "an off-shape Audio source yields {[:audio, :source], :invalid_shape}" do
      for source <- [{:url, "https://x/a.mp3"}, {:binary, 42}, {:file, nil}, nil, "raw"] do
        assert errors_for(audio: %Audio{source: source}) == [{[:audio, :source], :invalid_shape}]
      end
    end

    test "a non-binary :model yields {:model, :invalid_shape}" do
      assert errors_for(audio: @audio, model: :whisper) == [{:model, :invalid_shape}]
    end

    test "a non-binary :language yields {:language, :invalid_shape}" do
      assert errors_for(audio: @audio, language: :en) == [{:language, :invalid_shape}]
    end

    test "a non-binary :prompt yields {:prompt, :invalid_shape}" do
      assert errors_for(audio: @audio, prompt: 1) == [{:prompt, :invalid_shape}]
    end
  end

  describe "transcription_request/1 — accumulation" do
    test "every non-hard rule accumulates into one error list" do
      errors =
        errors_for(audio: %Audio{source: {:url, "x"}}, model: 1, language: 2, prompt: 3)

      assert MapSet.new(errors) ==
               MapSet.new([
                 {[:audio, :source], :invalid_shape},
                 {:model, :invalid_shape},
                 {:language, :invalid_shape},
                 {:prompt, :invalid_shape}
               ])

      assert length(errors) == 4
    end
  end

  describe "ValidationError enum extension" do
    test ":invalid_transcription_request is a legal ValidationError reason" do
      assert %ValidationError{reason: :invalid_transcription_request} =
               ValidationError.new(:invalid_transcription_request, [])
    end
  end
end
