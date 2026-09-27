# examples/23_synthesize_speech.exs
#
# Provider: openai, elevenlabs
#
# The marker is deliberate. Text-to-speech is bundled for OpenAI and
# ElevenLabs only: Gemini text-to-speech works but is not bundled yet, and
# Anthropic ships no audio endpoint. `run_all.exs` therefore SKIPS this
# script on the Gemini and Anthropic arms instead of halting the run on
# `speech_engine/1`'s ArgumentError.
#
# Demonstrates: the simplest `ALLM.synthesize/3` call — one sentence in, one
#               `%ALLM.Audio{}` out. The engine carries the speech model on
#               its own `:speech_model` field (not the chat `:model`), and the
#               voice comes from the provider row (`ExamplesHelpers.speech_voice/0`),
#               because voices are provider strings: OpenAI's are names,
#               ElevenLabs' are ids. Writes the audio to a temp file you can
#               play, and asserts a non-empty payload, `response.format == :mp3`
#               (derived from the response Content-Type, not echoed from the
#               request), the MIME type `SpeechResponse.format_to_mime(:mp3)`
#               maps it to, and an MP3 signature on the first bytes.
# Spec section: §37 (audio), §37.5 (public API).
# Steering strategy: tight on shape, silent on content — the bytes are a
#                    model's rendering and differ run to run, so nothing about
#                    the audio itself is asserted beyond "it is an MP3".
# Cost: well under $0.001 USD per clean run on OpenAI (one short sentence on
#       gpt-4o-mini-tts); about $0.002 on ElevenLabs (44 characters on
#       eleven_flash_v2_5).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/23_synthesize_speech.exs
#         OR:  ELEVENLABS_API_KEY=sk_... ALLM_PROVIDER=elevenlabs mix run examples/23_synthesize_speech.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.speech_engine()

text = "The quick brown fox jumps over the lazy dog."

mp3_signature? = fn
  <<"ID3", _::binary>> -> true
  <<0xFF, second, _::binary>> when second >= 0xE0 -> true
  _ -> false
end

expected_mime = ALLM.SpeechResponse.format_to_mime(:mp3)

case ALLM.synthesize(engine, text, voice: ExamplesHelpers.speech_voice(), format: :mp3) do
  {:ok, %ALLM.SpeechResponse{audio: %ALLM.Audio{} = audio, format: format} = resp} ->
    {:ok, bytes} = ALLM.Audio.to_binary(audio)

    cond do
      byte_size(bytes) == 0 ->
        ExamplesHelpers.fail!("expected non-empty audio bytes")

      format != :mp3 ->
        ExamplesHelpers.fail!("expected response.format :mp3, got #{inspect(format)}")

      audio.mime_type != expected_mime ->
        ExamplesHelpers.fail!(
          "expected mime_type #{inspect(expected_mime)}, got #{inspect(audio.mime_type)}"
        )

      not mp3_signature?.(bytes) ->
        ExamplesHelpers.fail!(
          "expected an MP3 signature, got first bytes #{inspect(binary_part(bytes, 0, min(4, byte_size(bytes))))}"
        )

      true ->
        path =
          Path.join(System.tmp_dir!(), "allm_example_23_#{System.unique_integer([:positive])}.mp3")

        File.write!(path, bytes)

        IO.puts(
          "OK: synthesize speech — bytes=#{byte_size(bytes)} format=#{inspect(format)} " <>
            "mime=#{audio.mime_type} model=#{inspect(resp.model)} path=#{path}"
        )
    end

  {:ok, other} ->
    ExamplesHelpers.fail!("unexpected response shape #{inspect(other)}")

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.synthesize/3 returned error #{inspect(error)}")
end
