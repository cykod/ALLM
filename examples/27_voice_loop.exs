# examples/27_voice_loop.exs
#
# Provider: elevenlabs
#
# The marker is deliberate. The loop needs realtime speech-to-text and
# text-in streaming speech, which are bundled for ElevenLabs only, so
# `run_all.exs` SKIPS this script on every other arm.
#
# The chat hop needs a chat adapter, and the ElevenLabs arm has none. So the
# script builds its chat engine explicitly, on OpenAI, from OPENAI_API_KEY.
# When that key is absent it prints a `SKIP:` line and exits with
# `ExamplesHelpers.skip_exit_status/0`, which `run_all.exs` reports as
# `[SKIP] 27_voice_loop.exs (self-skipped)`, not `[OK]`: the audio halves are
# covered by scripts 25 and 26, but `ALLM.stream_synthesize_input/3` is not.
#
# Demonstrates: the voice loop, end to end:
#                 1. `ALLM.stream_transcribe/3` hears the question
#                    (`fixtures/quick_brown_fox.wav` in 100 ms chunks, as a
#                    microphone would send it) and
#                    `ALLM.AudioStream.collect_transcription/1` waits for the
#                    committed text;
#                 2. `ALLM.stream/3` answers it on the chat engine;
#                 3. `ALLM.AudioStream.text_deltas/1` turns the chat events
#                    into text chunks, and `ALLM.stream_synthesize_input/3`
#                    speaks them over ElevenLabs' `/stream-input` WebSocket
#                    while the answer is still being generated.
#               Asserts the transcript mentions "fox", the spoken reply is at
#               least one non-empty `:audio_delta`, the speech stream ends in
#               `:speech_completed`, and `[:allm, :audio, :first_chunk]`
#               fired for both streams. Prints both first-chunk latencies.
#               Step 1 must finish before step 2 starts (the chat needs the
#               whole question); steps 2 and 3 overlap.
# Spec section: §37.11 (streaming audio).
# Steering strategy: loose — the answer is a model's; only "some audio came
#                    back" is asserted about it.
# Cost: under $0.01 USD per clean run (about 4 s of realtime audio, one short
#       chat turn on gpt-5.4-nano, and a sentence of eleven_flash_v2_5).
# Run with:    ELEVENLABS_API_KEY=sk_... OPENAI_API_KEY=sk-... ALLM_PROVIDER=elevenlabs mix run examples/27_voice_loop.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

# Both audio engines come from the ElevenLabs row (this also loads `.env`).
transcription_engine = ExamplesHelpers.transcription_engine()
speech_engine = ExamplesHelpers.speech_engine()

if System.get_env("OPENAI_API_KEY") in [nil, ""] do
  ExamplesHelpers.skip!("voice loop — OPENAI_API_KEY is not set, and the chat hop needs it")
end

chat_engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5.4-nano",
    params: %{temperature: 0}
  )

# Forward each first-chunk event to this process (a module function, which
# `:telemetry` prefers over a closure).
defmodule Example27.FirstChunk do
  @moduledoc false
  def handle(_event, %{latency: latency}, meta, parent),
    do: send(parent, {:first_chunk, meta.capability, latency})
end

:ok =
  :telemetry.attach(
    "example-27-first-chunk",
    [:allm, :audio, :first_chunk],
    &Example27.FirstChunk.handle/4,
    self()
  )

first_chunk_ms = fn capability ->
  receive do
    {:first_chunk, ^capability, latency} -> System.convert_time_unit(latency, :native, :millisecond)
  after
    0 -> nil
  end
end

# 1. Hear the question.
{rate, pcm} = ExamplesHelpers.read_pcm_wav!(Path.join([__DIR__, "fixtures", "quick_brown_fox.wav"]))

question =
  with {:ok, heard} <-
         ALLM.stream_transcribe(transcription_engine, ExamplesHelpers.pcm_chunks(pcm, rate, 100),
           sample_rate: rate
         ),
       {:ok, %ALLM.TranscriptionResponse{text: text}} <-
         ALLM.AudioStream.collect_transcription(heard) do
    text
  else
    {:error, error} -> ExamplesHelpers.fail!("transcription failed: #{inspect(error)}")
  end

unless String.contains?(String.downcase(question), "fox") do
  ExamplesHelpers.fail!("expected the transcript to mention \"fox\", got #{inspect(question)}")
end

IO.puts("  heard:  #{inspect(question)}")

# 2. Answer it, streaming.
prompt =
  "In one short sentence of at most twelve words, say which animal this sentence " <>
    "is about: " <> question

{:ok, chat} = ALLM.stream(chat_engine, [ALLM.user(prompt)])

# 3. Speak the answer while it is generated. A chat error would end the
#    speech stream with `{:error, _}` (`metadata.cause: :input_raised`), never
#    with a clip of a truncated answer.
case ALLM.stream_synthesize_input(speech_engine, ALLM.AudioStream.text_deltas(chat),
       voice: ExamplesHelpers.speech_voice(),
       format: :pcm
     ) do
  {:ok, spoken} ->
    events = Enum.to_list(spoken)
    deltas = for {:audio_delta, bytes} <- events, do: bytes
    stt_ms = first_chunk_ms.(:transcription)
    tts_ms = first_chunk_ms.(:speech)

    cond do
      match?({:error, _}, List.last(events)) ->
        {:error, error} = List.last(events)
        ExamplesHelpers.fail!("the speech stream ended with an error: #{inspect(error)}")

      deltas == [] ->
        ExamplesHelpers.fail!("expected at least one audio delta")

      not match?({:speech_completed, _}, List.last(events)) ->
        ExamplesHelpers.fail!("expected :speech_completed last, got #{inspect(List.last(events))}")

      is_nil(stt_ms) or is_nil(tts_ms) ->
        ExamplesHelpers.fail!(
          "expected a first-chunk event for both streams, got stt=#{inspect(stt_ms)} tts=#{inspect(tts_ms)}"
        )

      true ->
        {:ok, response} = ALLM.AudioStream.collect_speech(events)
        {:ok, bytes} = ALLM.Audio.to_binary(response.audio)

        IO.puts(
          "OK: voice loop — heard=#{inspect(question)} reply_deltas=#{length(deltas)} " <>
            "reply_bytes=#{byte_size(bytes)} sample_rate=#{response.sample_rate} " <>
            "stt_first_transcript_ms=#{stt_ms} tts_first_audio_ms=#{tts_ms}"
        )
    end

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.stream_synthesize_input/3 returned error #{inspect(error)}")
end
