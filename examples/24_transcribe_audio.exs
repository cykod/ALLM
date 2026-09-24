# examples/24_transcribe_audio.exs
#
# Provider: openai, gemini
#
# The marker is deliberate. Speech-to-text is bundled for OpenAI
# (`/v1/audio/transcriptions`) and Gemini (prompted `generateContent`);
# Anthropic ships no audio endpoint, so `run_all.exs` SKIPS this script on
# the Anthropic arm instead of halting on `transcription_engine/1`'s
# ArgumentError.
#
# Demonstrates: `ALLM.transcribe/3` over an `ALLM.Audio.from_file/1` clip —
#               `examples/fixtures/quick_brown_fox.mp3`, one spoken sentence
#               ("The quick brown fox jumps over the lazy dog."). The engine
#               carries the transcription model on its own
#               `:transcription_model` field. Asserts the transcript is a
#               non-empty string containing "fox" and that `response.usage`
#               is an `%ALLM.Usage{}` (never nil, even when the provider bills
#               by the second and reports `duration_seconds` instead).
# Spec section: §37 (audio), §37.5 (public API), §37.7 (provider adapters).
# Steering strategy: loose on wording — Gemini's transcript is a language
#                    model's answer and may differ in punctuation or case, so
#                    the one content assertion is a case-insensitive "fox".
# Cost: well under $0.001 USD per clean run on either arm (a ~3-second clip).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/24_transcribe_audio.exs
#         OR:  GEMINI_API_KEY=...   ALLM_PROVIDER=gemini mix run examples/24_transcribe_audio.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.transcription_engine()

audio = ALLM.Audio.from_file(Path.join([__DIR__, "fixtures", "quick_brown_fox.mp3"]))

case ALLM.transcribe(engine, audio) do
  {:ok, %ALLM.TranscriptionResponse{text: text, usage: usage} = resp} ->
    cond do
      not is_binary(text) or String.trim(text) == "" ->
        ExamplesHelpers.fail!("expected a non-empty transcript, got #{inspect(text)}")

      not String.contains?(String.downcase(text), "fox") ->
        ExamplesHelpers.fail!("expected the transcript to mention \"fox\", got #{inspect(text)}")

      not match?(%ALLM.Usage{}, usage) ->
        ExamplesHelpers.fail!(
          "expected response.usage to be an %ALLM.Usage{}, got #{inspect(usage)}"
        )

      true ->
        IO.puts(
          "OK: transcribe audio — text=#{inspect(String.trim(text))} model=#{inspect(resp.model)} " <>
            "duration_seconds=#{inspect(resp.duration_seconds)} " <>
            "input_tokens=#{inspect(usage.input_tokens)} output_tokens=#{inspect(usage.output_tokens)}"
        )
    end

  {:ok, other} ->
    ExamplesHelpers.fail!("unexpected response shape #{inspect(other)}")

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.transcribe/3 returned error #{inspect(error)}")
end
