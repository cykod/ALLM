defmodule ALLM.SpeechEventTest do
  use ExUnit.Case, async: true
  doctest ALLM.SpeechEvent

  alias ALLM.Error.{SpeechAdapterError, TranscriptionAdapterError}
  alias ALLM.{SpeechEvent, Usage}

  @started %{
    request_id: "req-1",
    model: "tts-1",
    provider: :openai,
    format: :pcm,
    mime_type: "audio/pcm",
    sample_rate: 24_000
  }

  @completed %{request_id: "req-1", id: nil, usage: %Usage{}, metadata: %{}}

  describe ":speech_started" do
    test "speech_started/1 builds the event and event?/1 accepts it" do
      event = SpeechEvent.speech_started(@started)
      assert event == {:speech_started, @started}
      assert SpeechEvent.event?(event)
    end

    test "a missing required key raises ArgumentError naming it" do
      err =
        assert_raise ArgumentError, fn ->
          SpeechEvent.speech_started(Map.delete(@started, :sample_rate))
        end

      assert err.message =~ ":sample_rate"
    end
  end

  describe ":audio_delta" do
    test "audio_delta/1 builds the event and event?/1 accepts it" do
      event = SpeechEvent.audio_delta(<<0, 255>>)
      assert event == {:audio_delta, <<0, 255>>}
      assert SpeechEvent.event?(event)
    end

    test ~s[audio_delta("") raises ArgumentError] do
      assert_raise ArgumentError, fn -> SpeechEvent.audio_delta("") end
    end

    test "a non-UTF-8 delta round-trips through :erlang.term_to_binary/1" do
      event = SpeechEvent.audio_delta(<<0xFF, 0xFE, 0x00, 0x81>>)
      refute String.valid?(elem(event, 1))
      assert event == event |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe ":speech_completed" do
    test "speech_completed/1 builds the event and event?/1 accepts it" do
      event = SpeechEvent.speech_completed(@completed)
      assert event == {:speech_completed, @completed}
      assert SpeechEvent.event?(event)
    end

    test "a missing required key raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        SpeechEvent.speech_completed(Map.delete(@completed, :usage))
      end
    end
  end

  describe ":error" do
    test "event?/1 accepts a SpeechAdapterError payload" do
      assert SpeechEvent.event?({:error, SpeechAdapterError.new(:timeout)})
    end

    test "event?/1 rejects another error family's struct" do
      refute SpeechEvent.event?({:error, TranscriptionAdapterError.new(:timeout)})
    end
  end

  describe "event?/1 — rejections" do
    test "an off-shape :audio_delta, an unknown tag and a chat event are all false" do
      refute SpeechEvent.event?({:audio_delta, 1})
      refute SpeechEvent.event?({:audio_delta, ""})
      refute SpeechEvent.event?({:unknown, %{}})
      refute SpeechEvent.event?({:text_delta, %{id: nil, delta: "hi"}})
      refute SpeechEvent.event?(:speech_started)
    end
  end
end
