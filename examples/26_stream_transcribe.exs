# examples/26_stream_transcribe.exs
#
# Provider: elevenlabs
#
# The marker is deliberate. Realtime speech-to-text is bundled for ElevenLabs
# only (its `/v1/speech-to-text/realtime` WebSocket). OpenAI's and Gemini's
# transcription adapters are request/response, so `run_all.exs` SKIPS this
# script on every other arm.
#
# Demonstrates: `ALLM.stream_transcribe/3` — PCM audio goes in as a stream
#               of chunks, and `ALLM.TranscriptionEvent`s come out while the
#               audio is still being sent. The input here is
#               `fixtures/quick_brown_fox.wav` cut into 100 ms chunks, the way
#               a microphone would deliver it. Prints each partial transcript
#               (a partial REPLACES the previous one) and each committed
#               segment (final, appended), then folds the events into a
#               `%ALLM.TranscriptionResponse{}` with
#               `ALLM.AudioStream.collect_transcription/1` and asserts the
#               text mentions "fox".
#
#               The WAV fixture is a *streaming* WAV: its RIFF size and its
#               `data` chunk size are both `0xFFFFFFFF` ("unknown length"),
#               so a reader must take the data chunk to the end of the file.
#               It is 24 kHz mono 16-bit PCM, 182,400 data bytes; 24,000 Hz
#               is one of the adapter's `stream_sample_rates/0`.
#               `ExamplesHelpers.read_pcm_wav!/1` handles that case; it is a
#               few lines, not a library.
#
#               The chunks are sent as fast as the socket takes them, not in
#               real time. ElevenLabs accepts that (a 3.8 s clip uploaded in
#               about 0.3 s when this was measured); a live microphone paces
#               itself.
# Spec section: §37.11 (streaming audio).
# Steering strategy: loose on wording — the one content assertion is a
#                    case-insensitive "fox".
# Cost: well under $0.001 USD per clean run (about 4 s of audio on
#       scribe_v2_realtime).
# Run with:    ELEVENLABS_API_KEY=sk_... ALLM_PROVIDER=elevenlabs mix run examples/26_stream_transcribe.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.transcription_engine()

{rate, pcm} = ExamplesHelpers.read_pcm_wav!(Path.join([__DIR__, "fixtures", "quick_brown_fox.wav"]))
# A whole number of 100 ms chunks; the few trailing bytes are dropped.
chunks = ExamplesHelpers.pcm_chunks(pcm, rate, 100)

# `engine.transcription_model` ("scribe_v2", the batch model) is deliberately
# NOT used here: the realtime endpoint takes its own model, and the adapter
# fills in its realtime default.
case ALLM.stream_transcribe(engine, chunks, sample_rate: rate) do
  {:ok, stream} ->
    events =
      stream
      |> Stream.each(fn
        {:partial_transcript, %{text: text}} -> IO.puts("  partial:   #{inspect(text)}")
        {:committed_transcript, %{text: text}} -> IO.puts("  committed: #{inspect(text)}")
        _ -> :ok
      end)
      |> Enum.to_list()

    case ALLM.AudioStream.collect_transcription(events) do
      {:ok, %ALLM.TranscriptionResponse{text: text} = resp} ->
        if String.contains?(String.downcase(text), "fox") do
          IO.puts(
            "OK: stream transcribe — text=#{inspect(text)} model=#{inspect(resp.model)} " <>
              "chunks=#{length(chunks)} sample_rate=#{rate} " <>
              "duration_seconds=#{inspect(resp.duration_seconds)}"
          )
        else
          ExamplesHelpers.fail!("expected the transcript to mention \"fox\", got #{inspect(text)}")
        end

      {:error, error} ->
        ExamplesHelpers.fail!("the stream ended with an error: #{inspect(error)}")
    end

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.stream_transcribe/3 returned error #{inspect(error)}")
end
