defmodule ALLM.TranscriptionEventTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptionEvent

  alias ALLM.Error.{SpeechAdapterError, TranscriptionAdapterError}
  alias ALLM.{TranscriptionEvent, Usage}

  @started %{request_id: nil, model: "scribe", provider: :fake, session_id: "s-1"}

  @completed %{
    text: "hello world",
    language: "en",
    duration_seconds: 1.5,
    request_id: nil,
    usage: %Usage{},
    metadata: %{}
  }

  describe ":transcription_started" do
    test "transcription_started/1 builds the event and event?/1 accepts it" do
      event = TranscriptionEvent.transcription_started(@started)
      assert event == {:transcription_started, @started}
      assert TranscriptionEvent.event?(event)
    end

    test "a missing required key raises ArgumentError naming it" do
      err =
        assert_raise ArgumentError, fn ->
          TranscriptionEvent.transcription_started(Map.delete(@started, :session_id))
        end

      assert err.message =~ ":session_id"
    end
  end

  describe ":partial_transcript" do
    test "partial_transcript/1 builds the event and event?/1 accepts it" do
      event = TranscriptionEvent.partial_transcript("hel")
      assert event == {:partial_transcript, %{text: "hel"}}
      assert TranscriptionEvent.event?(event)
    end
  end

  describe ":committed_transcript" do
    test "committed_transcript/2 builds the event and event?/1 accepts it" do
      event = TranscriptionEvent.committed_transcript("hello", "en")
      assert event == {:committed_transcript, %{text: "hello", language: "en"}}
      assert TranscriptionEvent.event?(event)
    end

    test "language defaults to nil" do
      assert TranscriptionEvent.committed_transcript("hi") ==
               {:committed_transcript, %{text: "hi", language: nil}}
    end
  end

  describe ":transcription_completed" do
    test "transcription_completed/1 builds the event and event?/1 accepts it" do
      event = TranscriptionEvent.transcription_completed(@completed)
      assert event == {:transcription_completed, @completed}
      assert TranscriptionEvent.event?(event)
    end

    test "a missing required key raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        TranscriptionEvent.transcription_completed(Map.delete(@completed, :duration_seconds))
      end
    end

    test "round-trips through :erlang.term_to_binary/1" do
      event = TranscriptionEvent.transcription_completed(@completed)
      assert event == event |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe ":error" do
    test "event?/1 accepts a TranscriptionAdapterError payload" do
      assert TranscriptionEvent.event?({:error, TranscriptionAdapterError.new(:timeout)})
    end

    test "event?/1 rejects another error family's struct" do
      refute TranscriptionEvent.event?({:error, SpeechAdapterError.new(:timeout)})
    end
  end

  describe "event?/1 — rejections" do
    test "an off-shape payload, an unknown tag, a speech event and a chat event are all false" do
      refute TranscriptionEvent.event?({:partial_transcript, %{text: 1}})
      refute TranscriptionEvent.event?({:partial_transcript, "hi"})
      refute TranscriptionEvent.event?({:unknown, %{}})
      refute TranscriptionEvent.event?({:audio_delta, "ab"})
      refute TranscriptionEvent.event?({:text_delta, %{id: nil, delta: "hi"}})
    end
  end
end
