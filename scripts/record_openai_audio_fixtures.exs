# scripts/record_openai_audio_fixtures.exs
#
# Fixture recorder AND live wire probe for the two OpenAI audio adapters:
#
#   * `ALLM.Providers.OpenAI.Speech`        — POST /v1/audio/speech
#   * `ALLM.Providers.OpenAI.Transcription` — POST /v1/audio/transcriptions
#
# Usage (the subshell keeps `.env` out of the parent shell, so a later
# `mix test` stays keyless and the keyless gate tests keep proving ordering):
#
#     ( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )
#
# Writes:
#
#   test/fixtures/openai/speech/recorded/*.json
#   test/fixtures/openai/transcriptions/recorded/*.json
#   test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus}   (STT input clips)
#   examples/fixtures/quick_brown_fox.mp3                         (copy for the example)
#
# It never touches a `synthesized/` directory.
#
# The four parts every probe in this repo carries
# -----------------------------------------------
#
# 1. **Control arm.** Both endpoints get an invented top-level field. On this
#    provider the control expects **200**: the design-time probe found both
#    audio endpoints IGNORE unknown fields (as `/v1/moderations` does). The arm
#    is kept so that the day OpenAI starts rejecting unknown fields, this script
#    halts. The consequence of the 200 is that no arm here treats acceptance as
#    proof that a field is in the schema. Only RESPONSE observables (a
#    content-type, a usage shape, an error code) settle a wire-map row.
#
# 2. **Assert, don't narrate.** Every arm carries an expected status plus a
#    body verdict. All pending arms run first, and any mismatch prints the
#    want/got table to stderr and `System.halt(1)`s BEFORE a single file is
#    written, clips included. The `Req.Test` wire tests assert what the ADAPTER
#    emits and stay green whatever OpenAI does, so this script is the only place
#    in the repo that can see the provider change.
#
# 3. **Record the body, not the status.** OpenAI TTS answers raw audio, and the
#    fixture convention is `.json`, so every recorded file is a JSON envelope:
#
#        {"status", "headers": {"content-type", "x-request-id"},
#         "body_base64", "byte_size", "sha256"}     # audio bodies
#        {"status", "headers": {...}, "body": {...}}  # JSON bodies (incl. errors)
#
#    Error envelopes are recorded too (400, 404, 401, the size rejection).
#    Assert-only arms write `probe_<arm>.json`: `{"status", "expected",
#    "error_body"?}` (a trimmed error body, never audio).
#
# 4. **Overwrite guard over EVERY arm.** Each arm owns one target path. An arm
#    runs only when its target is pending (missing, or a JSON file still carrying
#    a `_comment` marker). A fully recorded tree makes ZERO live calls and prints
#    `0 live calls`. Without this, every re-run would re-upload the ~25 MB size
#    ladder and re-bill the 4096-character TTS arms. Delete a file to re-run the
#    arm that owns it.
#
# Settled outcomes (first run 2026-09-24) are recorded in
# `steering/2026-09-24_SST_SUPPORT_RECORDS.md` §25.4 and in the design's
# wire-field map.
#
# Cost: OpenAI's pricing page (fetched 2026-09-24) lists tts-1 at
# $15.00 / 1M characters, gpt-4o-mini-tts audio output at $12.00 / 1M tokens,
# whisper-1 at $0.006 / minute, gpt-transcribe at $0.0045 / minute and
# gpt-4o-mini-transcribe at $0.003 / minute. One clean run is roughly $0.40,
# dominated by the two accepted ~13-minute ladder rungs and the ~30-minute
# duration clip. A fully recorded tree costs $0.00.
#
# The four streaming arms (Phase 26.5: `probe_stream_control`, `stream_pcm`,
# `stream_mp3_tts1`, `stream_error_401`) send about 820 characters in all:
# two ~405-character clips (one on gpt-4o-mini-tts, one on tts-1), plus
# "Hi." twice. At the prices above that is under $0.02 per run of those arms.
#
# Streamed bodies are recorded as the audio envelope plus
# `"chunks": [{"byte_size", "t_ms"}]`, one entry per `{:data, _}` message in
# arrival order, `t_ms` measured from the moment the request was sent.
#
# This script is NOT in the published Hex package (`scripts/` is excluded).

defmodule RecordOpenAIAudioFixtures do
  @moduledoc false

  @speech_url "https://api.openai.com/v1/audio/speech"
  @stt_url "https://api.openai.com/v1/audio/transcriptions"

  @speech_dir "test/fixtures/openai/speech/recorded"
  @stt_dir "test/fixtures/openai/transcriptions/recorded"
  @clip_dir "test/fixtures/audio"
  @example_clip "examples/fixtures/quick_brown_fox.mp3"

  @tts_model "gpt-4o-mini-tts"
  @clip_text "The quick brown fox jumps over the lazy dog."
  @clip_formats ~w(mp3 wav flac aac opus)

  # ~400 characters for the streaming arms: long enough that synthesis takes
  # seconds, so a body that really streams arrives spread over that time.
  @stream_text String.duplicate("The quick brown fox jumps over the lazy dog. ", 9)

  # The OpenAI TTS input limit is 4096 "characters". These two arms settle the
  # unit. 2049 x (e + U+0301 COMBINING ACUTE) is 4098 code points but 2049
  # graphemes: a 400 means code points (or bytes), a 200 means graphemes.
  # 4096 x precomposed U+00E9 is 4096 code points but 8192 UTF-8 bytes: a 200
  # means code points, a 400 means bytes.
  @graphemes_input String.duplicate("é", 2049)
  @bytes_input String.duplicate("é", 4096)

  # Size ladder (file-part bytes, 16 kHz mono 16-bit silence WAV, whisper-1).
  # Rung 1 must be accepted and rung 3 rejected; either violation halts.
  # Rung 2 settled decimal-vs-binary MB. Observed 2026-09-24: rungs 1 and 2
  # 200, rung 3 **413** with "Maximum content size limit (26214400) exceeded
  # (26214850 bytes read)" -- the cap is 25 MiB on the WHOLE multipart body,
  # and rung 3's file part plus ~449 bytes of field/header overhead crossed it.
  # `ALLM.Providers.OpenAI.Transcription.max_audio_bytes/0` is rung 2, which
  # leaves 64 KiB for the other form fields. Every expectation below now
  # asserts the observed status, so a change fails loudly.
  @ladder [
    {25_000_000 - 64 * 1024, [200]},
    {25 * 1024 * 1024 - 64 * 1024, [200]},
    {25 * 1024 * 1024 + 1, [413]}
  ]

  # Duration arm: > 1500 s of audio under the byte cap. No ffmpeg in this
  # container, so this is 8 kHz 8-bit mono PCM silence in a WAV (1800 s,
  # ~14.4 MB) rather than a low-bitrate mp3. The design allowed 200 or 400;
  # observed 2026-09-24: **200**, so no duration cap was found at 1800 s on
  # gpt-transcribe, and the arm now asserts it.
  @duration_seconds 1800

  def run do
    load_dotenv()

    unless System.get_env("OPENAI_API_KEY") do
      IO.puts(
        :stderr,
        "OPENAI_API_KEY not set (checked the environment and project-root .env) — refusing to record."
      )

      System.halt(1)
    end

    Enum.each([@speech_dir, @stt_dir, @clip_dir, Path.dirname(@example_clip)], &File.mkdir_p!/1)

    pending = Enum.filter(arms(), fn arm -> Enum.any?(arm.targets, &pending?/1) end)
    clips_pending? = Enum.any?(clip_paths(), &pending?/1)

    if pending == [] and not clips_pending? do
      IO.puts("0 live calls: every target is already recorded. Delete a file to re-run its arm.")
    else
      Process.put(:live_calls, 0)
      clips = load_or_synthesize_clips()
      results = Enum.map(pending, fn arm -> run_arm(arm, clips) end)

      Enum.each(results, &print_result/1)
      halt_unless_all_ok(results ++ clips.results)

      write_clips(clips)
      Enum.each(results, &write_result/1)

      IO.puts("\n#{Process.get(:live_calls)} live calls. Every asserted arm matched.")
    end
  end

  # ---------------------------------------------------------------------------
  # Arms
  # ---------------------------------------------------------------------------

  defp arms do
    [
      %{
        id: :speech_control,
        label: "CONTROL speech: not_a_real_field is IGNORED (200)",
        targets: [speech_path("probe_control")],
        run: fn _ ->
          tts(%{
            "model" => "tts-1",
            "input" => "Hi.",
            "voice" => "alloy",
            "not_a_real_field" => true
          })
        end,
        expect: [200],
        verify: &verify_audio(&1, "audio/mpeg"),
        write: :probe
      },
      %{
        id: :mp3_default,
        label: "tts default format (no response_format) -> audio/mpeg + x-request-id",
        targets: [speech_path("mp3_default")],
        run: fn _ -> tts(%{"model" => @tts_model, "input" => "Hello.", "voice" => "alloy"}) end,
        expect: [200],
        verify: &verify_audio(&1, "audio/mpeg"),
        write: :audio_envelope
      },
      %{
        id: :wav,
        label: "tts response_format=wav -> audio/wav",
        targets: [speech_path("wav")],
        run: fn _ ->
          tts(%{
            "model" => @tts_model,
            "input" => "Hello.",
            "voice" => "alloy",
            "response_format" => "wav"
          })
        end,
        expect: [200],
        verify: &verify_audio(&1, "audio/wav"),
        write: :audio_envelope
      },
      %{
        id: :pcm,
        label: "tts response_format=pcm -> audio/pcm",
        targets: [speech_path("pcm")],
        run: fn _ ->
          tts(%{
            "model" => @tts_model,
            "input" => "Hello.",
            "voice" => "alloy",
            "response_format" => "pcm"
          })
        end,
        expect: [200],
        verify: &verify_audio(&1, "audio/pcm"),
        write: :audio_envelope
      },
      %{
        id: :unit_graphemes,
        label: "tts 2049 x e+U+0301 (4098 code points, 2049 graphemes) -> 400 string_too_long",
        targets: [speech_path("probe_unit_graphemes")],
        run: fn _ -> tts(%{"model" => "tts-1", "input" => @graphemes_input, "voice" => "alloy"}) end,
        expect: [400],
        verify: &verify_error_mentions(&1, "string_too_long"),
        write: :probe
      },
      %{
        id: :unit_bytes,
        label: "tts 4096 x U+00E9 (4096 code points, 8192 bytes) -> 200",
        targets: [speech_path("probe_unit_bytes")],
        run: fn _ -> tts(%{"model" => "tts-1", "input" => @bytes_input, "voice" => "alloy"}) end,
        expect: [200],
        verify: &verify_audio(&1, "audio/mpeg"),
        write: :probe
      },
      %{
        id: :too_long,
        label: "tts 4097 ASCII -> 400 string_too_long",
        targets: [speech_path("error_400_too_long")],
        run: fn _ ->
          tts(%{"model" => "tts-1", "input" => String.duplicate("a", 4097), "voice" => "alloy"})
        end,
        expect: [400],
        verify: &verify_error_mentions(&1, "string_too_long"),
        write: :json_envelope
      },
      %{
        id: :bad_model,
        label: "tts bad model -> 404 model_not_found",
        targets: [speech_path("error_404_model")],
        run: fn _ ->
          tts(%{"model" => "not-a-real-tts-model", "input" => "Hi.", "voice" => "alloy"})
        end,
        expect: [404],
        verify: &verify_error_code(&1, "model_not_found"),
        write: :json_envelope
      },
      %{
        id: :speech_bad_key,
        label: "tts BAD KEY -> 401 (text/plain JSON body; does it echo the key?)",
        targets: [speech_path("error_401_bad_key")],
        run: fn _ -> tts(%{"model" => "tts-1", "input" => "Hi.", "voice" => "alloy"}, :bad) end,
        expect: [401],
        verify: &verify_bad_key/1,
        write: :json_envelope
      },
      # Streaming arms (Phase 26.5). The body is read through `Finch.stream/5`
      # on `ALLM.Finch`, the adapter's own transport, so each `{:data, _}`
      # message is timed as it arrives.
      %{
        id: :stream_control,
        label: "CONTROL stream: not_a_real_field is IGNORED on the streaming path (200)",
        targets: [speech_path("probe_stream_control")],
        run: fn _ ->
          tts_stream(%{
            "model" => "tts-1",
            "input" => "Hi.",
            "voice" => "alloy",
            "not_a_real_field" => true
          })
        end,
        expect: [200],
        verify: &verify_audio(&1, "audio/mpeg"),
        write: :probe
      },
      %{
        id: :stream_chunked,
        label:
          "stream #{@tts_model} pcm, ~400 chars -> chunked audio/pcm, >= 2 timed data messages",
        targets: [speech_path("stream_pcm")],
        run: fn _ ->
          tts_stream(%{
            "model" => @tts_model,
            "input" => @stream_text,
            "voice" => "alloy",
            "response_format" => "pcm"
          })
        end,
        expect: [200],
        verify: &verify_stream(&1, "audio/pcm"),
        write: :stream_envelope
      },
      %{
        id: :stream_mp3_tts1,
        label:
          "stream tts-1 (legacy) mp3, ~400 chars -> chunked audio/mpeg, >= 2 timed data messages",
        targets: [speech_path("stream_mp3_tts1")],
        run: fn _ ->
          tts_stream(%{"model" => "tts-1", "input" => @stream_text, "voice" => "alloy"})
        end,
        expect: [200],
        verify: &verify_stream(&1, "audio/mpeg"),
        write: :stream_envelope
      },
      %{
        id: :stream_401,
        label: "stream BAD KEY -> 401 with a text/plain JSON body on the streaming path",
        targets: [speech_path("stream_error_401")],
        run: fn _ ->
          tts_stream(%{"model" => "tts-1", "input" => "Hi.", "voice" => "alloy"}, :bad)
        end,
        expect: [401],
        verify: &verify_stream_bad_key/1,
        write: :stream_json_envelope
      },
      %{
        id: :stt_control,
        label: "CONTROL stt: not_a_real_field is IGNORED (200)",
        targets: [stt_path("probe_control")],
        run: fn clips ->
          stt(clips.mp3, "quick_brown_fox.mp3", "audio/mpeg", "whisper-1", [
            {"not_a_real_field", "1"}
          ])
        end,
        expect: [200],
        verify: &verify_text/1,
        write: :probe
      },
      %{
        id: :gpt_transcribe,
        label: "stt gpt-transcribe -> text + duration usage",
        targets: [stt_path("gpt_transcribe")],
        run: fn clips -> stt(clips.mp3, "quick_brown_fox.mp3", "audio/mpeg", "gpt-transcribe") end,
        expect: [200],
        verify: &verify_usage(&1, "duration"),
        write: :json_envelope
      },
      %{
        id: :mini_tokens,
        label: "stt gpt-4o-mini-transcribe -> text + token usage",
        targets: [stt_path("mini_tokens")],
        run: fn clips ->
          stt(clips.mp3, "quick_brown_fox.mp3", "audio/mpeg", "gpt-4o-mini-transcribe")
        end,
        expect: [200],
        verify: &verify_usage(&1, "tokens"),
        write: :json_envelope
      },
      %{
        id: :junk,
        label: "stt junk bytes -> 400",
        targets: [stt_path("error_400_format")],
        run: fn _ ->
          stt(String.duplicate("not audio at all ", 64), "junk.mp3", "audio/mpeg", "gpt-transcribe")
        end,
        expect: [400],
        verify: &verify_error_envelope/1,
        write: :json_envelope
      },
      %{
        id: :audio_bin,
        label: "stt valid mp3 bytes named audio.bin (content sniffing vs filename trust)",
        targets: [stt_path("probe_audio_bin")],
        run: fn clips ->
          stt(clips.mp3, "audio.bin", "application/octet-stream", "gpt-transcribe")
        end,
        # The design allowed either outcome. Observed 2026-09-24: 400
        # "Unsupported file format bin" (code unsupported_value) -- OpenAI
        # trusts the filename extension, so the adapter gates a filename it
        # cannot derive (nil or unknown mime) as :invalid_request instead.
        expect: [400],
        verify: &verify_error_code(&1, "unsupported_value"),
        write: :probe
      },
      %{
        id: :size_ladder,
        label: "stt size ladder (whisper-1, 16 kHz silence WAV)",
        targets: [stt_path("probe_size_ladder")],
        run: :ladder,
        expect: [:ladder],
        verify: nil,
        write: :ladder
      },
      %{
        id: :duration,
        label: "stt gpt-transcribe > 1500 s clip (8 kHz 8-bit WAV, #{@duration_seconds} s)",
        targets: [stt_path("probe_duration")],
        run: fn _ ->
          pcm = :binary.copy(<<128>>, 8000 * @duration_seconds)
          stt(wav(pcm, 8000, 8), "long_silence.wav", "audio/wav", "gpt-transcribe")
        end,
        expect: [200],
        verify: &verify_text/1,
        write: :probe
      },
      %{
        id: :stt_bad_key,
        label: "stt BAD KEY -> 401",
        targets: [stt_path("error_401_bad_key")],
        run: fn clips ->
          stt(clips.mp3, "quick_brown_fox.mp3", "audio/mpeg", "whisper-1", [], :bad)
        end,
        expect: [401],
        verify: &verify_bad_key/1,
        write: :json_envelope
      }
    ]
  end

  defp speech_path(name), do: Path.join(@speech_dir, name <> ".json")
  defp stt_path(name), do: Path.join(@stt_dir, name <> ".json")

  # ---------------------------------------------------------------------------
  # Input clips — five tts calls, each overwrite-guarded. Held in memory until
  # every arm has passed, so a halt writes nothing.
  # ---------------------------------------------------------------------------

  defp clip_paths do
    Enum.map(@clip_formats, &Path.join(@clip_dir, "quick_brown_fox.#{&1}")) ++ [@example_clip]
  end

  defp load_or_synthesize_clips do
    {bytes_by_format, results} =
      Enum.map_reduce(@clip_formats, [], fn format, acc ->
        path = Path.join(@clip_dir, "quick_brown_fox.#{format}")

        if File.exists?(path) do
          {{format, {:existing, File.read!(path)}}, acc}
        else
          resp =
            tts(%{
              "model" => @tts_model,
              "input" => @clip_text,
              "voice" => "alloy",
              "response_format" => format
            })

          result = %{
            label: "clip quick_brown_fox.#{format}",
            expect: [200],
            got: status_of(resp),
            verdict: verify_audio(resp, "audio/"),
            response: resp
          }

          bytes = if match?({:ok, %{status: 200}}, resp), do: elem(resp, 1).body, else: nil
          {{format, {:new, bytes}}, [finish(result) | acc]}
        end
      end)

    by_format = Map.new(bytes_by_format)
    Enum.each(Enum.reverse(results), &print_result/1)

    %{
      by_format: by_format,
      mp3: elem(Map.fetch!(by_format, "mp3"), 1),
      results: Enum.reverse(results)
    }
  end

  defp write_clips(%{by_format: by_format}) do
    Enum.each(by_format, fn
      {format, {:new, bytes}} when is_binary(bytes) ->
        path = Path.join(@clip_dir, "quick_brown_fox.#{format}")
        File.write!(path, bytes)
        IO.puts("  wrote #{path} (#{byte_size(bytes)} bytes)")

      _ ->
        :ok
    end)

    if not File.exists?(@example_clip) do
      File.cp!(Path.join(@clip_dir, "quick_brown_fox.mp3"), @example_clip)
      IO.puts("  wrote #{@example_clip}")
    end
  end

  # ---------------------------------------------------------------------------
  # Running arms
  # ---------------------------------------------------------------------------

  defp run_arm(%{run: :ladder} = arm, _clips) do
    rungs =
      Enum.map(@ladder, fn {bytes, expect} ->
        pcm = :binary.copy(<<0>>, bytes - 44)
        resp = stt(wav(pcm, 16_000, 16), "silence.wav", "audio/wav", "whisper-1")
        status = status_of(resp)
        IO.puts("  ladder #{bytes} bytes -> #{status} (want one of #{inspect(expect)})")
        %{bytes: bytes, expect: expect, status: status, response: resp}
      end)

    ok? = Enum.all?(rungs, fn r -> r.status in r.expect end)
    accepted = for r <- rungs, r.status == 200, do: r.bytes

    %{
      arm: arm,
      label: arm.label,
      expect: Enum.map(rungs, & &1.expect),
      got: Enum.map(rungs, & &1.status),
      verdict: %{ok?: ok?, note: "  (largest accepted: #{inspect(List.last(accepted))})"},
      rungs: rungs,
      ok?: ok?
    }
  end

  defp run_arm(arm, clips) do
    resp = arm.run.(clips)

    finish(%{
      arm: arm,
      label: arm.label,
      expect: arm.expect,
      got: status_of(resp),
      verdict:
        if(status_of(resp) in arm.expect, do: arm.verify.(resp), else: %{ok?: false, note: ""}),
      response: resp
    })
  end

  defp finish(result), do: Map.put(result, :ok?, result.got in result.expect and result.verdict.ok?)

  defp status_of({:ok, %Req.Response{status: s}}), do: s
  defp status_of({:error, e}), do: "ERR #{inspect(e)}"

  defp print_result(r) do
    flag = if r.ok?, do: "ok  ", else: "FAIL"

    IO.puts(
      "  #{flag} got #{inspect(r.got)} want #{inspect(r.expect)}  #{r.label}#{r.verdict.note}"
    )
  end

  defp halt_unless_all_ok(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(
        :stderr,
        "\nOpenAI's audio wire no longer matches the recorded truth — refusing to record.\n"
      )

      Enum.each(results, fn r ->
        IO.puts(
          :stderr,
          "  want #{inspect(r.expect)}  got #{inspect(r.got)}  #{r.label}#{r.verdict.note}"
        )
      end)

      IO.puts(
        :stderr,
        "\nNothing was written. Re-read the wire-field map in steering/2026-09-24_SST_SUPPORT.md\n" <>
          "and the outcome rules in its Phase 25.4 live-probe table before changing an expectation.\n" <>
          "The Req.Test wire tests assert what the ADAPTER emits and stay green regardless."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Verdicts
  # ---------------------------------------------------------------------------

  defp verify_audio({:ok, %Req.Response{body: body} = resp}, mime_prefix) do
    ct = header(resp, "content-type") || ""

    verdict(
      [
        {String.starts_with?(ct, mime_prefix),
         "content-type #{inspect(ct)} is not #{mime_prefix}*"},
        {is_binary(body) and byte_size(body) > 0, "empty or non-binary body"},
        {is_binary(header(resp, "x-request-id")), "x-request-id header absent"}
      ],
      "  (#{ct}, #{if is_binary(body), do: byte_size(body), else: 0} bytes)"
    )
  end

  defp verify_audio(_resp, _prefix), do: %{ok?: false, note: "  <- transport error"}

  defp verify_text({:ok, resp}) do
    body = decode(resp.body)
    verdict([{is_map(body) and is_binary(body["text"]), "no text field"}])
  end

  defp verify_usage({:ok, resp}, type) do
    body = decode(resp.body)
    usage = if is_map(body), do: body["usage"], else: nil

    verdict(
      [
        {is_map(body) and is_binary(body["text"]) and body["text"] != "", "text absent or empty"},
        {is_map(usage) and usage["type"] == type,
         "usage.type is not #{inspect(type)}: #{inspect(usage)}"},
        {is_binary(header(resp, "x-request-id")), "x-request-id header absent"}
      ],
      "  (usage #{inspect(usage)}; languages #{inspect(is_map(body) && body["languages"])})"
    )
  end

  defp verify_error_envelope({:ok, resp}) do
    error = resp.body |> decode() |> error_of()

    verdict(
      [{is_map(error) and is_binary(error["message"]), "no error.message"}],
      "  (#{inspect(error && error["message"]) |> String.slice(0, 160)})"
    )
  end

  defp verify_error_mentions({:ok, resp} = r, needle) do
    base = verify_error_envelope(r)
    text = resp.body |> decode() |> Jason.encode!()

    if base.ok? and String.contains?(text, needle),
      do: base,
      else: %{ok?: false, note: "  <- #{needle} absent: #{String.slice(text, 0, 200)}"}
  end

  defp verify_error_code({:ok, resp} = r, code) do
    base = verify_error_envelope(r)
    error = resp.body |> decode() |> error_of()

    if base.ok? and error["code"] == code,
      do: base,
      else: %{ok?: false, note: "  <- code #{inspect(error && error["code"])}"}
  end

  defp verify_bad_key({:ok, resp} = r) do
    base = verify_error_envelope(r)
    ct = header(resp, "content-type")
    message = (resp.body |> decode() |> error_of() || %{})["message"] || ""

    echo =
      cond do
        String.contains?(message, bad_key()) -> "ECHOES THE FULL KEY"
        String.contains?(message, String.slice(bad_key_tail(), -4, 4)) -> "echoes a MASKED key"
        true -> "no key echo"
      end

    %{base | note: base.note <> "  [content-type #{inspect(ct)}; #{echo}]"}
  end

  # Streaming framing (Alternative E of the Phase 26 design). A single-chunk
  # body, or one whose first byte arrives no earlier than its last, means the
  # endpoint buffered the whole clip: the recorder halts, and the design falls
  # back to `stream_format: "sse"`. `transfer-encoding: chunked` is asserted
  # too. The chunk COUNT alone is weak evidence (TCP splits any large body
  # into many reads), so the note prints the first-byte and last-byte times.
  defp verify_stream({:ok, resp} = r, mime_prefix) do
    base = verify_audio(r, mime_prefix)
    chunks = Req.Response.get_private(resp, :chunks, [])
    te = header(resp, "transfer-encoding")
    first = chunks |> List.first(%{}) |> Map.get("t_ms")
    last = chunks |> List.last(%{}) |> Map.get("t_ms")

    checks = [
      {base.ok?, String.trim_leading(base.note, "  <- ")},
      {length(chunks) >= 2, "only #{length(chunks)} data message(s): the body did not stream"},
      {is_integer(first) and is_integer(last) and first < last,
       "first-chunk t_ms #{inspect(first)} is not before last-chunk t_ms #{inspect(last)}"},
      {te == "chunked", "transfer-encoding is #{inspect(te)}, not chunked"}
    ]

    verdict(
      checks,
      base.note <>
        "  [#{length(chunks)} data messages; first byte #{inspect(first)} ms, last #{inspect(last)} ms]"
    )
  end

  defp verify_stream(_resp, _prefix), do: %{ok?: false, note: "  <- transport error"}

  defp verify_stream_bad_key({:ok, resp} = r) do
    base = verify_bad_key(r)
    ct = header(resp, "content-type") || ""

    if base.ok? and String.starts_with?(ct, "text/plain"),
      do: base,
      else: %{ok?: false, note: base.note <> "  <- content-type #{inspect(ct)} is not text/plain"}
  end

  defp verdict(checks, extra \\ "") do
    case for({false, why} <- checks, do: why) do
      [] -> %{ok?: true, note: extra}
      failures -> %{ok?: false, note: "  <- " <> Enum.join(failures, "; ")}
    end
  end

  defp error_of(%{"error" => e}) when is_map(e), do: e
  defp error_of(_), do: nil

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_result(%{arm: %{write: :ladder, targets: [path]}, rungs: rungs}) do
    accepted = for r <- rungs, r.status == 200, do: r.bytes

    write_json(path, %{
      "rungs" =>
        Enum.map(rungs, fn r ->
          %{"file_part_bytes" => r.bytes, "status" => r.status, "expected" => r.expect}
        end),
      "max_accepted_bytes" => List.last(accepted)
    })

    case Enum.find(rungs, &(&1.status in [400, 413])) do
      %{status: 413, response: {:ok, resp}} ->
        write_json(stt_path("error_413"), json_envelope(resp))

      %{status: 400, response: {:ok, resp}} ->
        write_json(stt_path("error_400_size"), json_envelope(resp))

      _ ->
        :ok
    end
  end

  defp write_result(%{arm: %{write: :probe, targets: [path]}, expect: expect, response: {:ok, resp}}) do
    base = %{"status" => resp.status, "expected" => expect}

    body =
      if resp.status in 200..299, do: base, else: Map.put(base, "error_body", trimmed(resp.body))

    write_json(path, body)
  end

  defp write_result(%{arm: %{write: :audio_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp),
      "body_base64" => Base.encode64(resp.body),
      "byte_size" => byte_size(resp.body),
      "sha256" => :crypto.hash(:sha256, resp.body) |> Base.encode16(case: :lower)
    })
  end

  # The Phase 25 audio envelope plus `"chunks": [{"byte_size", "t_ms"}]`, the
  # arrival time of each `{:data, _}` message since the request was sent.
  # The chunk sizes sum to `byte_size`, so a test can replay the body in the
  # recorded framing.
  defp write_result(%{arm: %{write: :stream_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp, ["transfer-encoding"]),
      "body_base64" => Base.encode64(resp.body),
      "byte_size" => byte_size(resp.body),
      "sha256" => :crypto.hash(:sha256, resp.body) |> Base.encode16(case: :lower),
      "chunks" => Req.Response.get_private(resp, :chunks, [])
    })
  end

  defp write_result(%{
         arm: %{write: :stream_json_envelope, targets: [path]},
         response: {:ok, resp}
       }) do
    write_json(
      path,
      resp
      |> json_envelope()
      |> Map.put("headers", picked_headers(resp, ["transfer-encoding"]))
      |> Map.put("chunks", Req.Response.get_private(resp, :chunks, []))
    )
  end

  defp write_result(%{arm: %{write: :json_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, json_envelope(resp))
  end

  defp json_envelope(resp) do
    %{"status" => resp.status, "headers" => picked_headers(resp), "body" => decode(resp.body)}
  end

  defp picked_headers(resp, extra \\ []) do
    for name <- ["content-type", "x-request-id" | extra],
        v = header(resp, name),
        into: %{},
        do: {name, v}
  end

  defp trimmed(body) do
    case decode(body) do
      map when is_map(map) -> map
      bin when is_binary(bin) -> String.slice(bin, 0, 500)
      other -> inspect(other)
    end
  end

  defp write_json(path, map) do
    if pending?(path) do
      File.write!(path, Jason.encode!(map, pretty: true) <> "\n")
      IO.puts("  wrote #{path}")
    else
      IO.puts("  - #{path} already recorded; refusing to overwrite")
    end
  end

  # Pending = missing, or a JSON file still carrying a `_comment` placeholder
  # marker. A binary clip is pending only when missing.
  defp pending?(path) do
    case File.read(path) do
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        Path.extname(path) == ".json" and match?({:ok, %{"_comment" => _}}, Jason.decode(contents))

      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp tts(body, key_kind \\ :live) do
    bump()

    Req.post(@speech_url,
      headers: [{"authorization", "Bearer " <> key(key_kind)}],
      json: body,
      receive_timeout: 180_000,
      retry: false,
      decode_body: false
    )
  end

  # The streaming transport: `Finch.stream/5` on the adapter's own pool
  # (`ALLM.Finch`, HTTP/1), timing every `{:data, _}` message from the moment
  # the request is sent. Returns a `%Req.Response{}` so the verdicts and
  # writers above apply unchanged; the timings ride in `private.chunks`.
  defp tts_stream(body, key_kind \\ :live) do
    bump()

    request =
      Finch.build(
        :post,
        @speech_url,
        [{"authorization", "Bearer " <> key(key_kind)}, {"content-type", "application/json"}],
        Jason.encode!(body)
      )

    t0 = System.monotonic_time(:millisecond)

    result =
      Finch.stream(
        request,
        ALLM.Finch,
        %{status: nil, headers: [], data: [], chunks: []},
        fn
          {:status, status}, acc ->
            %{acc | status: status}

          {:headers, headers}, acc ->
            %{acc | headers: acc.headers ++ headers}

          {:data, data}, acc ->
            chunk = %{
              "byte_size" => byte_size(data),
              "t_ms" => System.monotonic_time(:millisecond) - t0
            }

            %{acc | data: [acc.data | data], chunks: [chunk | acc.chunks]}
        end,
        receive_timeout: 180_000
      )

    case result do
      {:ok, acc} ->
        resp =
          Enum.reduce(
            acc.headers,
            Req.Response.new(status: acc.status, body: IO.iodata_to_binary(acc.data)),
            fn {k, v}, r -> Req.Response.put_header(r, k, v) end
          )

        {:ok, Req.Response.put_private(resp, :chunks, Enum.reverse(acc.chunks))}

      {:error, error, _acc} ->
        {:error, error}
    end
  end

  defp stt(bytes, filename, content_type, model, extra \\ [], key_kind \\ :live) do
    bump()

    form =
      [
        {"file", {bytes, filename: filename, content_type: content_type}},
        {"model", model},
        {"response_format", "json"}
      ] ++ extra

    Req.post(@stt_url,
      headers: [{"authorization", "Bearer " <> key(key_kind)}],
      form_multipart: form,
      receive_timeout: 600_000,
      retry: false,
      decode_body: false
    )
  end

  defp bump, do: Process.put(:live_calls, (Process.get(:live_calls) || 0) + 1)

  defp key(:live), do: System.get_env("OPENAI_API_KEY")
  defp key(:bad), do: bad_key()

  # A deliberately invalid key with a real OpenAI prefix, so the 401 arms
  # exercise the provider's own auth rejection. Recording its 401 body commits
  # no key material: the only key the body can echo is this fake one.
  defp bad_key, do: "sk-proj-" <> bad_key_tail()
  defp bad_key_tail, do: "NOTAREALKEY0011223344556677889900"

  defp header(%Req.Response{} = resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> v
      _ -> nil
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode(body), do: body

  defp wav(pcm, rate, bits) do
    block_align = div(bits, 8)
    size = byte_size(pcm)

    <<"RIFF", 36 + size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * block_align::little-32, block_align::little-16, bits::little-16,
      "data", size::little-32>> <> pcm
  end

  # Copied from the sibling recorders (a `[CHORE]` to extract it is open).
  # Loaded ONLY when the key is absent: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("OPENAI_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end
end

RecordOpenAIAudioFixtures.run()
