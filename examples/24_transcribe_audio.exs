# examples/24_transcribe_audio.exs
#
# Provider: openai, gemini, elevenlabs
#
# The marker is deliberate. Speech-to-text is bundled for OpenAI
# (`/v1/audio/transcriptions`), Gemini (prompted `generateContent`) and
# ElevenLabs (`/v1/speech-to-text`, Scribe); Anthropic ships no audio
# endpoint, so `run_all.exs` SKIPS this script on the Anthropic arm instead
# of halting on `transcription_engine/1`'s ArgumentError.
#
# Demonstrates: `ALLM.transcribe/3` over an `ALLM.Audio.from_file/1` clip —
#               `examples/fixtures/quick_brown_fox.mp3`, one spoken sentence
#               ("The quick brown fox jumps over the lazy dog."). The engine
#               carries the transcription model on its own
#               `:transcription_model` field. Asserts the transcript is a
#               non-empty string containing "fox" and that `response.usage`
#               is an `%ALLM.Usage{}` (never nil, even when the provider bills
#               by the second and reports `duration_seconds` instead).
#
#               On the ElevenLabs arm a second call opts in to word spans
#               (`timestamps: true, logprobs: true`) and asserts
#               `response.spans` is a non-empty list of `%ALLM.TranscriptSpan{}`
#               whose `:word` entries each carry a start/end time and a
#               log-probability, then prints the words and
#               `ALLM.TranscriptionResponse.mean_logprob/1`.
#
#               On the OpenAI arm a second call opts in to token
#               log-probabilities (`logprobs: true`) and asserts
#               `response.spans` is a non-empty list of `:token` spans, each
#               with a numeric log-probability and no times. On the Gemini arm
#               the same call is the documented refusal: the adapter answers
#               `{:error, %{reason: :unsupported_feature, metadata: %{field:
#               :logprobs}}}` before any request is sent (one live probe on
#               gemini-flash-latest found log-probabilities not enabled).
# Spec section: §37 (audio), §37.5 (public API), §37.7 (provider adapters).
# Steering strategy: loose on wording — Gemini's transcript is a language
#                    model's answer and may differ in punctuation or case, so
#                    the one content assertion is a case-insensitive "fox".
# Cost: well under $0.001 USD per clean run on any arm (a ~3-second clip;
#       two clips on the ElevenLabs and OpenAI arms; the Gemini refusal is
#       local and free).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/24_transcribe_audio.exs
#         OR:  GEMINI_API_KEY=...   ALLM_PROVIDER=gemini mix run examples/24_transcribe_audio.exs
#         OR:  ELEVENLABS_API_KEY=sk_... ALLM_PROVIDER=elevenlabs mix run examples/24_transcribe_audio.exs

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

# Word timings and confidence: ElevenLabs honours both span flags.
if System.get_env("ALLM_PROVIDER", "openai") == "elevenlabs" do
  case ALLM.transcribe(engine, audio, timestamps: true, logprobs: true) do
    {:ok, %ALLM.TranscriptionResponse{spans: [_ | _] = spans} = resp} ->
      words = Enum.filter(spans, &(&1.kind == :word))

      timed? =
        words != [] and
          Enum.all?(
            words,
            &(is_number(&1.start_seconds) and is_number(&1.end_seconds) and is_number(&1.logprob))
          )

      if timed? do
        shown =
          words
          |> Enum.take(4)
          |> Enum.map_join(" ", fn w ->
            "#{w.text}@#{w.start_seconds}s(#{Float.round(w.logprob * 1.0, 3)})"
          end)

        IO.puts(
          "OK: transcribe audio with spans — spans=#{length(spans)} words=#{length(words)} " <>
            "first=#{shown} mean_logprob=#{inspect(ALLM.TranscriptionResponse.mean_logprob(resp))}"
        )
      else
        ExamplesHelpers.fail!(
          "expected every :word span to carry times and a logprob, got #{inspect(words)}"
        )
      end

    {:ok, other} ->
      ExamplesHelpers.fail!("expected a non-empty spans list, got #{inspect(other.spans)}")

    {:error, error} ->
      ExamplesHelpers.fail!("flagged ALLM.transcribe/3 returned error #{inspect(error)}")
  end
end

# Token log-probabilities: OpenAI honours `logprobs: true`; Gemini refuses it
# locally with :unsupported_feature, before any request is sent.
case System.get_env("ALLM_PROVIDER", "openai") do
  "openai" ->
    case ALLM.transcribe(engine, audio, logprobs: true) do
      {:ok, %ALLM.TranscriptionResponse{spans: [_ | _] = spans} = resp} ->
        scored? =
          Enum.all?(
            spans,
            &(&1.kind == :token and is_number(&1.logprob) and is_nil(&1.start_seconds))
          )

        if scored? do
          IO.puts(
            "OK: transcribe audio with logprobs — tokens=#{length(spans)} " <>
              "first=#{inspect(Enum.map(Enum.take(spans, 4), & &1.text))} " <>
              "mean_logprob=#{inspect(ALLM.TranscriptionResponse.mean_logprob(resp))}"
          )
        else
          ExamplesHelpers.fail!(
            "expected :token spans with a logprob and no times, got #{inspect(spans)}"
          )
        end

      {:ok, other} ->
        ExamplesHelpers.fail!("expected a non-empty spans list, got #{inspect(other.spans)}")

      {:error, error} ->
        ExamplesHelpers.fail!("logprobs ALLM.transcribe/3 returned error #{inspect(error)}")
    end

  "gemini" ->
    case ALLM.transcribe(engine, audio, logprobs: true) do
      {:error, %{reason: :unsupported_feature, metadata: %{field: :logprobs}}} ->
        IO.puts("OK: transcribe audio with logprobs — refused locally on Gemini, as documented")

      other ->
        ExamplesHelpers.fail!(
          "expected Gemini to refuse logprobs: true with :unsupported_feature, got #{inspect(other)}"
        )
    end

  _other ->
    :ok
end
