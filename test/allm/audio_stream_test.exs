defmodule ALLM.AudioStreamTest do
  use ExUnit.Case, async: true

  doctest ALLM.AudioStream

  alias ALLM.{
    Audio,
    AudioStream,
    Engine,
    SpeechEvent,
    SpeechResponse,
    TranscriptionEvent,
    TranscriptSpan,
    Usage
  }

  alias ALLM.Error.{SpeechAdapterError, TranscriptionAdapterError}
  alias ALLM.Providers.{Fake, FakeSpeech}

  defp started(overrides \\ %{}) do
    SpeechEvent.speech_started(
      Map.merge(
        %{
          request_id: "r1",
          model: "m1",
          provider: :fake,
          format: :pcm,
          mime_type: "audio/pcm",
          sample_rate: 24_000
        },
        overrides
      )
    )
  end

  defp completed do
    SpeechEvent.speech_completed(%{
      request_id: "r1",
      id: "clip-1",
      usage: %Usage{input_tokens: 3},
      metadata: %{"k" => "v"}
    })
  end

  defp chat_engine(stream_script) do
    Engine.new(adapter: Fake, adapter_opts: [stream_script: [stream_script]])
  end

  describe "collect_speech/1" do
    test "folds a grammar-conforming stream into the SpeechResponse" do
      events = [
        started(),
        SpeechEvent.audio_delta("ab"),
        SpeechEvent.audio_delta("cd"),
        completed()
      ]

      assert {:ok, %SpeechResponse{} = resp} = AudioStream.collect_speech(events)
      assert Audio.to_binary(resp.audio) == {:ok, "abcd"}
      assert resp.audio.mime_type == "audio/pcm"

      assert {resp.format, resp.sample_rate, resp.model, resp.provider} ==
               {:pcm, 24_000, "m1", :fake}

      assert {resp.id, resp.request_id} == {"clip-1", "r1"}
      assert resp.usage == %Usage{input_tokens: 3}
      assert resp.metadata == %{"k" => "v"}
      assert resp.raw == nil
    end

    test "an error after two 5-byte deltas returns the error with bytes_received: 10" do
      err = SpeechAdapterError.new(:network_error, metadata: %{attempt: 1})

      events = [
        started(),
        SpeechEvent.audio_delta("aaaaa"),
        SpeechEvent.audio_delta("bbbbb"),
        {:error, err}
      ]

      assert {:error, %SpeechAdapterError{reason: :network_error, metadata: metadata}} =
               AudioStream.collect_speech(events)

      assert metadata == %{attempt: 1, bytes_received: 10}
    end

    test "a stream that ends without a terminal event is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               AudioStream.collect_speech([started(), SpeechEvent.audio_delta("a")])
    end

    test "a :speech_completed without :speech_started is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               AudioStream.collect_speech([SpeechEvent.audio_delta("a"), completed()])
    end

    test "reduction stops at the terminal event" do
      events =
        Stream.concat(
          [started(), SpeechEvent.audio_delta("a"), completed()],
          Stream.map([1], fn _ -> raise "read past the terminal" end)
        )

      assert {:ok, _} = AudioStream.collect_speech(events)
    end
  end

  describe "collect_transcription/1" do
    test "takes the terminal event's text, not a re-join of the segments" do
      events = [
        TranscriptionEvent.transcription_started(%{
          request_id: "r1",
          model: "rt",
          provider: :fake,
          session_id: "sess"
        }),
        TranscriptionEvent.partial_transcript("hel"),
        TranscriptionEvent.committed_transcript("hello"),
        TranscriptionEvent.committed_transcript("world"),
        TranscriptionEvent.transcription_completed(%{
          text: "adapter text",
          language: "en",
          duration_seconds: 1.5,
          request_id: "r1",
          usage: %Usage{},
          metadata: %{"m" => 1}
        })
      ]

      assert {:ok, resp} = AudioStream.collect_transcription(events)
      assert resp.text == "adapter text"
      assert {resp.language, resp.duration_seconds, resp.request_id} == {"en", 1.5, "r1"}
      assert {resp.model, resp.provider, resp.id} == {"rt", :fake, "sess"}
      assert resp.metadata == %{"m" => 1}
      assert resp.raw == nil
    end

    test "an error returns it with the committed text so far" do
      err = TranscriptionAdapterError.new(:timeout)

      events = [
        TranscriptionEvent.committed_transcript(" hello "),
        TranscriptionEvent.committed_transcript(""),
        TranscriptionEvent.committed_transcript("world"),
        TranscriptionEvent.partial_transcript("and"),
        {:error, err}
      ]

      assert {:error, %TranscriptionAdapterError{reason: :timeout} = got} =
               AudioStream.collect_transcription(events)

      assert got.metadata.committed_text == "hello world"
    end

    test "a stream that ends without a terminal event is :malformed_response" do
      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
               AudioStream.collect_transcription([TranscriptionEvent.partial_transcript("a")])
    end

    test "a :transcription_completed without :transcription_started still succeeds, with nil start fields" do
      completed =
        TranscriptionEvent.transcription_completed(%{
          text: "hi",
          language: nil,
          duration_seconds: nil,
          request_id: "r1",
          usage: %Usage{},
          metadata: %{}
        })

      assert {:ok, resp} = AudioStream.collect_transcription([completed])
      assert resp.text == "hi"
      assert {resp.model, resp.provider, resp.id} == {nil, nil, nil}
    end
  end

  describe "collect_transcription/1 spans" do
    defp completed_with(extra) do
      %{text: "hi there", language: nil, duration_seconds: 1.0, request_id: nil}
      |> Map.merge(%{usage: %Usage{}, metadata: %{}})
      |> Map.merge(extra)
      |> TranscriptionEvent.transcription_completed()
    end

    defp two_spans do
      [
        TranscriptSpan.new(text: "hi", kind: :word, start_seconds: 0.0, end_seconds: 0.4),
        TranscriptSpan.new(text: "there", kind: :word, start_seconds: 0.5, end_seconds: 0.9)
      ]
    end

    test "a completed event without :spans collects to spans: nil" do
      assert {:ok, %{spans: nil}} = AudioStream.collect_transcription([completed_with(%{})])
    end

    test "a completed event with spans: [] collects to [] (requested, nothing spoken)" do
      assert {:ok, %{spans: []}} = AudioStream.collect_transcription([completed_with(%{spans: []})])
    end

    test "a completed event's spans are copied onto the response" do
      spans = two_spans()

      assert {:ok, %{spans: ^spans}} =
               AudioStream.collect_transcription([completed_with(%{spans: spans})])
    end

    test "committed-event spans are not folded: only completed.spans counts" do
      events = [
        TranscriptionEvent.committed_transcript("hi there", nil, two_spans()),
        completed_with(%{})
      ]

      assert {:ok, %{spans: nil}} = AudioStream.collect_transcription(events)

      events = [
        TranscriptionEvent.committed_transcript("hi there", nil, two_spans()),
        completed_with(%{spans: []})
      ]

      assert {:ok, %{spans: []}} = AudioStream.collect_transcription(events)
    end
  end

  describe "text_deltas/1" do
    test "yields exactly the scripted deltas of an ALLM.stream_generate/3 stream" do
      engine =
        chat_engine([
          {:text_delta, "Hel"},
          {:text_delta, "lo, "},
          {:text_delta, "world."},
          {:finish, :stop}
        ])

      assert {:ok, chat} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]))
      assert chat |> AudioStream.text_deltas() |> Enum.to_list() == ["Hel", "lo, ", "world."]
    end

    test "is lazy" do
      events =
        Stream.map([{:text_delta, %{id: nil, delta: "a"}}], fn e -> send(self(), :pulled) && e end)

      stream = AudioStream.text_deltas(events)
      refute_received :pulled
      assert Enum.to_list(stream) == ["a"]
      assert_received :pulled
    end

    test "a chat error ends the speech stream with :input_raised, never a successful clip" do
      engine = chat_engine([{:text, "Hel"}, {:text, "lo"}, {:error, :rate_limited}])
      assert {:ok, chat} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]))

      speech = Engine.new(speech_adapter: FakeSpeech)
      assert {:ok, events} = ALLM.stream_synthesize_input(speech, AudioStream.text_deltas(chat))

      # Falsifier: a text_deltas/1 that halts on the chat error lets the
      # speech stream complete, and this returns {:ok, %SpeechResponse{}}.
      assert {:error, %SpeechAdapterError{} = err} = AudioStream.collect_speech(events)
      assert err.reason == :invalid_request
      assert err.metadata.cause == :input_raised
      assert %{kind: :error, message: message} = err.cause
      assert message =~ "rate_limited"
      # The speech that arrived before the failure is counted, not kept.
      assert err.metadata.bytes_received == byte_size("FAKE-AUDIO:Hel") + byte_size("FAKE-AUDIO:lo")
      assert Process.alive?(self())
    end

    test "the input-failure error round-trips Jason.encode!/1 with a string-only cause" do
      engine = chat_engine([{:text, "Hi"}, {:error, :rate_limited}])
      assert {:ok, chat} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]))

      speech = Engine.new(speech_adapter: FakeSpeech)
      assert {:ok, events} = ALLM.stream_synthesize_input(speech, AudioStream.text_deltas(chat))
      assert {:error, err} = AudioStream.collect_speech(events)

      # Falsifier: the raw exception on `err.cause` (not encodable, and not
      # this map).
      assert err.metadata.cause == :input_raised
      assert %{kind: :error, message: message} = err.cause
      assert map_size(err.cause) == 2
      assert is_binary(message)

      decoded = err |> Jason.encode!() |> Jason.decode!()
      assert decoded["data"]["metadata"]["cause"] == "input_raised"
      assert decoded["data"]["cause"] == %{"kind" => "error", "message" => message}
    end
  end
end
