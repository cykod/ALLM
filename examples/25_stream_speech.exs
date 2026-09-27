# examples/25_stream_speech.exs
#
# Provider: openai, elevenlabs
#
# The marker is deliberate. Streaming text-to-speech is bundled for OpenAI
# (chunked `POST /v1/audio/speech`) and ElevenLabs (chunked
# `POST /v1/text-to-speech/{voice}/stream`). Gemini text-to-speech is not
# bundled and Anthropic has no audio endpoint, so `run_all.exs` SKIPS this
# script on those arms.
#
# Demonstrates: `ALLM.stream_synthesize/3` — the audio arrives as a lazy
#               stream of `ALLM.SpeechEvent`s while the provider is still
#               generating it. Asks for raw PCM (headerless 16-bit samples at
#               `sample_rate`), counts the `:audio_delta` events as they are
#               reduced, and times the first one through the
#               `[:allm, :audio, :first_chunk]` telemetry event. Asserts at
#               least two deltas (so the audio really streamed), a
#               `:speech_started` whose format is `:pcm` with a sample rate,
#               and a `:speech_completed` terminal. Folds the same events
#               into a `%ALLM.SpeechResponse{}` with
#               `ALLM.AudioStream.collect_speech/1` and writes the PCM to a
#               temp file.
# Spec section: §37.11 (streaming audio).
# Steering strategy: tight on the event grammar, silent on the audio itself.
#                    The number of deltas is the transport's business, so only
#                    "at least two" is asserted.
# Cost: well under $0.001 USD per clean run on OpenAI (one short sentence on
#       gpt-4o-mini-tts); about $0.004 on ElevenLabs (about 80 characters on
#       eleven_flash_v2_5).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/25_stream_speech.exs
#         OR:  ELEVENLABS_API_KEY=sk_... ALLM_PROVIDER=elevenlabs mix run examples/25_stream_speech.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.speech_engine()

text = "The quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun."

# The first-chunk event carries the latency from the façade call to the
# first `:audio_delta`, in native time units. The handler only forwards it to
# this process (a module function, which `:telemetry` prefers over a closure).
defmodule Example25.FirstChunk do
  @moduledoc false
  def handle(_event, %{latency: latency}, _meta, parent), do: send(parent, {:first_chunk, latency})
end

:ok =
  :telemetry.attach(
    "example-25-first-chunk",
    [:allm, :audio, :first_chunk],
    &Example25.FirstChunk.handle/4,
    self()
  )

started_at = System.monotonic_time(:millisecond)

case ALLM.stream_synthesize(engine, text, voice: ExamplesHelpers.speech_voice(), format: :pcm) do
  {:ok, stream} ->
    # Reduce the stream once, keeping every event. A real player would write
    # each `:audio_delta` to the sound card here instead.
    events = Enum.to_list(stream)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    deltas = for {:audio_delta, bytes} <- events, do: bytes

    started =
      Enum.find_value(events, fn
        {:speech_started, m} -> m
        _ -> nil
      end)

    completed? = match?({:speech_completed, _}, List.last(events))

    first_chunk_ms =
      receive do
        {:first_chunk, latency} -> System.convert_time_unit(latency, :native, :millisecond)
      after
        0 -> nil
      end

    cond do
      match?({:error, _}, List.last(events)) ->
        {:error, error} = List.last(events)
        ExamplesHelpers.fail!("the stream ended with an error: #{inspect(error)}")

      length(deltas) < 2 ->
        ExamplesHelpers.fail!("expected at least 2 audio deltas, got #{length(deltas)}")

      is_nil(started) or started.format != :pcm or not is_integer(started.sample_rate) ->
        ExamplesHelpers.fail!("unexpected :speech_started #{inspect(started)}")

      not completed? ->
        ExamplesHelpers.fail!("expected :speech_completed last, got #{inspect(List.last(events))}")

      is_nil(first_chunk_ms) ->
        ExamplesHelpers.fail!("[:allm, :audio, :first_chunk] did not fire")

      true ->
        {:ok, response} = ALLM.AudioStream.collect_speech(events)
        {:ok, bytes} = ALLM.Audio.to_binary(response.audio)

        path =
          Path.join(System.tmp_dir!(), "allm_example_25_#{System.unique_integer([:positive])}.pcm")

        File.write!(path, bytes)

        IO.puts(
          "OK: stream speech — deltas=#{length(deltas)} bytes=#{byte_size(bytes)} " <>
            "sample_rate=#{started.sample_rate} first_chunk_ms=#{first_chunk_ms} " <>
            "total_ms=#{elapsed_ms} model=#{inspect(response.model)} path=#{path}"
        )
    end

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.stream_synthesize/3 returned error #{inspect(error)}")
end
