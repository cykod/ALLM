defmodule ALLM.AudioStreamEquivalencePropertyTest do
  @moduledoc """
  The stream-first property for the audio family: over the Fakes,
  `synthesize/3` equals `stream_synthesize/3 |> AudioStream.collect_speech/1`,
  and `transcribe/3` equals
  `stream_transcribe/3 |> AudioStream.collect_transcription/1`.

  ## Fields not compared (the relaxation budget)

    * `raw` — `collect_*` always sets `nil`; the field is provider-shaped.
    * `id` — neither Fake sets a provider id, and comparing it would fail an
      unrelated property on a Fake change to one path.
    * `duration_seconds` (transcription) — the non-streaming Fake never sets
      it; the streaming Fake computes it from the bytes consumed. Pinned in
      `fake_transcription_test.exs` ("32,000 bytes at 16 kHz gives 1.0").

    * `metadata.bytes_received` on an error — `collect_speech/1` adds it to
      a stream's terminal error and `synthesize/3` has no stream to count.
      For a `{:ok, ""}` script the property asserts it is `0` and compares
      the rest of the error.

  `model` (transcription) IS compared, but only because both engines carry
  `transcription_model: nil`: `transcribe/3` stamps the engine's slot model
  and `stream_transcribe/3` deliberately does not. That divergence is pinned
  in `allm_stream_transcribe_test.exs`.

  `language` is compared but binds nothing today: neither Fake reports a
  language (the non-streaming Fake's response and the streaming Fake's
  `:transcription_completed` both carry `nil`), so a collector that dropped
  it would stay green here. `collect_transcription/1`'s own test pins it.

  ## Masking divergence

  The transcript generator emits non-empty words joined by single spaces, so
  the streaming path's trimmed single-space join and the non-streaming
  path's verbatim text agree by construction. A padded script (`" a b "`)
  would, correctly, differ; that case is pinned in
  `fake_transcription_test.exs` (a padded script gives the trimmed
  `completed.text` on the stream path).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.{Audio, AudioStream, Engine, SpeechRequest}
  alias ALLM.Providers.{FakeSpeech, FakeTranscription}

  defp metadata_gen,
    do: StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer(), max_length: 3)

  defp speech_engine(bytes, chunk_bytes, speech_model) do
    Engine.new(
      speech_adapter: FakeSpeech,
      speech_model: speech_model,
      adapter_opts: [speech_script: [{:ok, bytes}], chunk_bytes: chunk_bytes]
    )
  end

  defp transcription_engine(text) do
    Engine.new(
      transcription_adapter: FakeTranscription,
      transcription_model: nil,
      adapter_opts: [transcription_script: [{:ok, text}]]
    )
  end

  property "synthesize/3 equals stream_synthesize/3 folded by collect_speech/1" do
    check all(
            # Empty bytes are weighted in explicitly: a script entry of `{:ok, ""}`
            # must fail the same way on both paths, and a plain `binary/1`
            # generator reaches `""` too rarely to bind that.
            bytes <-
              StreamData.frequency([
                {1, StreamData.constant("")},
                {9, StreamData.binary(min_length: 1, max_length: 300)}
              ]),
            chunk_bytes <- StreamData.integer(1..64),
            format <- StreamData.member_of(SpeechRequest.formats()),
            sample_rate <-
              StreamData.one_of([StreamData.constant(nil), StreamData.integer(8_000..48_000)]),
            speech_model <-
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:alphanumeric, min_length: 1)
              ]),
            metadata <- metadata_gen(),
            max_runs: 100
          ) do
      request =
        SpeechRequest.new(
          input: "Hello.",
          format: format,
          sample_rate: sample_rate,
          metadata: metadata
        )

      # Two engines with the same script: each reads its own first entry.
      opts = [request_id: "rid-eq"]

      whole = ALLM.synthesize(speech_engine(bytes, chunk_bytes, speech_model), request, opts)

      assert {:ok, events} =
               ALLM.stream_synthesize(
                 speech_engine(bytes, chunk_bytes, speech_model),
                 request,
                 opts
               )

      folded = AudioStream.collect_speech(events)
      assert_same_speech(bytes, whole, folded)
    end
  end

  # Empty bytes are an error on both paths, and it must be the same error.
  defp assert_same_speech("", whole, folded) do
    assert {:error, %{reason: :invalid_request, metadata: %{cause: :empty_input}} = whole_err} =
             whole

    assert {:error, folded_err} = folded
    {received, folded_meta} = Map.pop!(folded_err.metadata, :bytes_received)
    assert received == 0
    assert %{folded_err | metadata: folded_meta} == whole_err
  end

  defp assert_same_speech(_bytes, whole, folded) do
    assert {:ok, whole} = whole
    assert {:ok, folded} = folded

    assert Audio.to_binary(folded.audio) == Audio.to_binary(whole.audio)
    assert folded.audio.mime_type == whole.audio.mime_type

    for field <- [:format, :sample_rate, :model, :provider, :usage, :request_id, :metadata] do
      assert Map.fetch!(folded, field) == Map.fetch!(whole, field),
             "#{inspect(field)} differs between the paths"
    end
  end

  property "transcribe/3 equals stream_transcribe/3 folded by collect_transcription/1" do
    check all(
            words <-
              StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1), max_length: 8),
            # ≤ 1,000 bytes: under FakeTranscription.max_audio_bytes/0 (1,024), which
            # gates the non-streaming path.
            samples <- StreamData.integer(1..500),
            metadata <- metadata_gen(),
            language <- StreamData.one_of([StreamData.constant(nil), StreamData.constant("en")]),
            max_runs: 100
          ) do
      text = Enum.join(words, " ")
      pcm = :binary.copy(<<0, 0>>, samples)
      opts = [request_id: "rid-eq", metadata: metadata, language: language]

      assert {:ok, whole} =
               ALLM.transcribe(
                 transcription_engine(text),
                 Audio.from_binary(pcm, "audio/wav"),
                 opts
               )

      assert {:ok, events} = ALLM.stream_transcribe(transcription_engine(text), [pcm], opts)
      assert {:ok, folded} = AudioStream.collect_transcription(events)

      for field <- [:text, :language, :model, :provider, :usage, :request_id, :metadata] do
        assert Map.fetch!(folded, field) == Map.fetch!(whole, field),
               "#{inspect(field)} differs between the paths"
      end
    end
  end
end
