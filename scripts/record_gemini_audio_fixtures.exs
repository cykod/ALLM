# scripts/record_gemini_audio_fixtures.exs
#
# Fixture recorder AND live wire probe for `ALLM.Providers.Gemini.Transcription`
# (`POST .../models/<model>:generateContent` with inline audio).
#
# Usage (the subshell keeps `.env` out of the parent shell, so a later
# `mix test` stays keyless and the keyless gate tests keep proving ordering):
#
#     ( set -a; . ./.env; set +a; mix run scripts/record_gemini_audio_fixtures.exs )
#
# Writes `test/fixtures/gemini/transcriptions/recorded/*.json` only. It never
# touches `synthesized/`, and it reads (never writes) the input clips
# `test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus}` that
# `scripts/record_openai_audio_fixtures.exs` produced.
#
# The four parts every probe in this repo carries
# -----------------------------------------------
#
# 1. **Control arm.** The adapter's own body plus an invented top-level field.
#    On Gemini the control expects **400 `Unknown name`**: the API rejects
#    unknown fields, so on this provider an arm's 200 IS evidence that what it
#    sent is in the schema. If the control ever starts returning 200, every
#    acceptance arm below stops meaning anything, and the script halts.
#
# 2. **Assert, don't narrate.** Every arm carries an expected status plus a
#    body verdict. All pending arms run first; any mismatch prints the
#    want/got table to stderr and `System.halt(1)`s BEFORE a single file is
#    written. The `Req.Test` wire tests assert what the ADAPTER emits and stay
#    green whatever Google does, so this script is the only place in the repo
#    that can see the provider change.
#
# 3. **Record the body, not the status.** Recorded files are JSON envelopes
#    `{"status", "headers": {"content-type", "x-request-id"?,
#    "x-goog-request-id"?}, "header_names", "body"}`, error envelopes
#    included (the control's 400 and the bad-key 400). `header_names` is the
#    sorted list of EVERY response header name (names only, never values), so
#    a claim about which headers Google sends can be checked against what came
#    back rather than against this script's allowlist. Assert-only arms write
#    `probe_<arm>.json`: `{"status", "expected", "text"?, "model_version"?,
#    "usage"?, "error_body"?}`, never audio.
#
# 4. **Overwrite guard over EVERY arm.** Each arm owns one target path and runs
#    only when that target is pending (missing, or a JSON file still carrying a
#    `_comment` marker). A fully recorded tree makes ZERO live calls and prints
#    `0 live calls`. Without this, every re-run would re-send the two ~15 MB
#    boundary clips. Delete a file to re-run the arm that owns it.
#
# Request bodies come from the adapter's own `to_json_body/2`, so an accepted
# arm certifies the exact shape the adapter sends (camelCase `inlineData`,
# the fixed instruction part). On the first run the adapter did not yet accept
# `audio/opus`, so that arm rewrote `mimeType` on an `audio/ogg` body; it now
# goes through the adapter like every other arm.
#
# Settled outcomes (first run 2026-09-24) are recorded in
# `steering/2026-09-24_SST_SUPPORT_RECORDS.md` §25.5 and in the design's
# Gemini wire-field map.
#
# Cost: Google's pricing page (https://ai.google.dev/gemini-api/docs/pricing,
# fetched 2026-09-24) lists Gemini 3.8 Flash audio input at "$3.00 or
# $0.005/min (audio)" per 1M tokens and output at "$12.00" per 1M tokens
# (thinking included). The two boundary clips are ~8 minutes of 16 kHz 16-bit
# mono silence each. Their audio input is only ~$0.04 each, but on silence the
# model thinks at length and invents a transcript, so the observed cost per
# boundary rung was ~$0.09-0.13, mostly output + thinking tokens (2026-09-24:
# 1,363 output + 6,179 thinking tokens on one rung). The five 4-second clips
# are negligible. The first clean run cost ~$0.22 (RECORDS §25.5, summed from
# the recorded `usageMetadata`). A fully recorded tree costs $0.00.
#
# This script is NOT in the published Hex package (`scripts/` is excluded).

defmodule RecordGeminiAudioFixtures do
  @moduledoc false

  alias ALLM.{Audio, TranscriptionRequest}
  alias ALLM.Providers.Gemini.Transcription

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @model "gemini-flash-latest"
  @dir "test/fixtures/gemini/transcriptions/recorded"
  @clip_dir "test/fixtures/audio"

  # Boundary rungs, raw WAV bytes (16 kHz 16-bit mono silence). The first is
  # the adapter's own cap and must be accepted (a 400 means the cap is too
  # high). The second is ~15.1 MiB raw, ~20.1 MiB once base64-encoded: the
  # design allowed a 400 (confirms the 20 MB request limit) or a 200 (the cap
  # is conservative, a [CARRY] rather than a halt). Observed 2026-09-24:
  # **200**, so the cap is conservative; the arm now asserts 200.
  #
  # Every other discovery arm was likewise tightened to its observed outcome
  # after the first run, so a later provider change halts this script:
  # opus as `audio/ogg` AND as `audio/opus` both 200 with the right text
  # (`audio/opus` joined the adapter's accepted set; no alias table).
  @at_cap Transcription.max_audio_bytes()
  @over_cap 15 * 1024 * 1024 + 100 * 1024

  def run do
    load_dotenv()

    unless System.get_env("GEMINI_API_KEY") do
      IO.puts(
        :stderr,
        "GEMINI_API_KEY not set (checked the environment and project-root .env) — refusing to record."
      )

      System.halt(1)
    end

    File.mkdir_p!(@dir)

    case Enum.filter(arms(), fn arm -> pending?(arm.target) end) do
      [] ->
        IO.puts("0 live calls: every target is already recorded. Delete a file to re-run its arm.")

      pending ->
        Process.put(:live_calls, 0)
        results = Enum.map(pending, &run_arm/1)
        Enum.each(results, &print_result/1)
        halt_unless_all_ok(results)
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
        label: "CONTROL: notARealField is REJECTED (400 Unknown name)",
        target: path("error_400_unknown_field"),
        run: fn -> post(clip_body("mp3") |> Map.put("notARealField", true)) end,
        expect: [400],
        verify: &verify_error_mentions(&1, "Unknown name"),
        write: :envelope
      },
      %{
        label: "mp3 clip as audio/mpeg -> 200, 'quick brown fox'",
        target: path("mp3"),
        run: fn -> post(clip_body("mp3")) end,
        expect: [200],
        verify: &verify_text(&1, "quick brown fox"),
        write: :envelope
      },
      %{
        label: "wav clip as audio/wav -> 200, 'fox'",
        target: path("wav"),
        run: fn -> post(clip_body("wav")) end,
        expect: [200],
        verify: &verify_text(&1, "fox"),
        write: :envelope
      },
      %{
        label: "flac clip as audio/flac -> 200, 'fox'",
        target: path("flac"),
        run: fn -> post(clip_body("flac")) end,
        expect: [200],
        verify: &verify_text(&1, "fox"),
        write: :envelope
      },
      %{
        label: "aac clip as audio/aac -> 200, 'fox'",
        target: path("aac"),
        run: fn -> post(clip_body("aac")) end,
        expect: [200],
        verify: &verify_text(&1, "fox"),
        write: :envelope
      },
      %{
        label: "opus clip as audio/ogg -> 200, 'fox'",
        target: path("probe_opus_as_ogg"),
        run: fn -> post(clip_body("opus", "audio/ogg")) end,
        expect: [200],
        verify: &verify_text(&1, "fox"),
        write: :probe
      },
      %{
        label: "opus clip as audio/opus -> 200, 'fox'",
        target: path("probe_opus_as_opus"),
        # `ALLM.Audio.from_file/1` names an `.opus` file `audio/opus`.
        run: fn -> post(clip_body("opus")) end,
        expect: [200],
        verify: &verify_text(&1, "fox"),
        write: :probe
      },
      %{
        label: "boundary: max_audio_bytes() (#{@at_cap}) raw WAV -> 200",
        target: path("probe_boundary_at_cap"),
        run: fn -> post(silence_body(@at_cap)) end,
        expect: [200],
        verify: &verify_candidates/1,
        write: :probe
      },
      %{
        label: "boundary: #{@over_cap} raw WAV (~20.1 MiB base64) -> 200 (cap is conservative)",
        target: path("probe_boundary_over_cap"),
        run: fn -> post(silence_body(@over_cap)) end,
        expect: [200],
        verify: &verify_candidates/1,
        write: :probe
      },
      %{
        label: "BAD KEY -> 400 API_KEY_INVALID",
        target: path("error_400_bad_key"),
        run: fn -> post(clip_body("mp3"), :bad) end,
        expect: [400],
        verify: &verify_bad_key/1,
        write: :envelope
      }
    ]
  end

  defp path(name), do: Path.join(@dir, name <> ".json")

  # ---------------------------------------------------------------------------
  # Bodies — the adapter's own builder
  # ---------------------------------------------------------------------------

  defp clip_body(ext, mime \\ nil) do
    audio = Audio.from_file(Path.join(@clip_dir, "quick_brown_fox.#{ext}"))
    audio = if mime, do: %{audio | mime_type: mime}, else: audio
    build!(audio)
  end

  defp silence_body(raw_bytes) do
    build!(Audio.from_binary(wav(:binary.copy(<<0>>, raw_bytes - 44)), "audio/wav"))
  end

  defp build!(audio) do
    {:ok, body} = Transcription.to_json_body(TranscriptionRequest.new(audio: audio), [])
    body
  end

  defp wav(pcm) do
    size = byte_size(pcm)

    <<"RIFF", 36 + size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data",
      size::little-32>> <> pcm
  end

  # ---------------------------------------------------------------------------
  # Running
  # ---------------------------------------------------------------------------

  defp run_arm(arm) do
    resp = arm.run.()
    got = status_of(resp)
    verdict = if got in arm.expect, do: arm.verify.(resp), else: %{ok?: false, note: ""}

    %{
      arm: arm,
      label: arm.label,
      expect: arm.expect,
      got: got,
      verdict: verdict,
      response: resp,
      ok?: got in arm.expect and verdict.ok?
    }
  end

  defp status_of({:ok, %Req.Response{status: s}}), do: s
  defp status_of({:error, e}), do: "ERR #{inspect(e)}"

  defp print_result(r) do
    flag = if r.ok?, do: "ok  ", else: "FAIL"

    IO.puts(
      "  #{flag} got #{inspect(r.got)} want #{inspect(r.expect)}  #{r.label}#{r.verdict.note}"
    )
  end

  defp halt_unless_all_ok(results) do
    unless Enum.all?(results, & &1.ok?) do
      IO.puts(
        :stderr,
        "\nGemini's audio wire no longer matches the recorded truth — refusing to record.\n"
      )

      Enum.each(results, fn r ->
        IO.puts(
          :stderr,
          "  want #{inspect(r.expect)}  got #{inspect(r.got)}  #{r.label}#{r.verdict.note}"
        )
      end)

      IO.puts(
        :stderr,
        "\nNothing was written. Re-read the Gemini wire-field map in steering/2026-09-24_SST_SUPPORT.md\n" <>
          "and the outcome rules in its Phase 25.5 live-probe table before changing an expectation."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Verdicts
  # ---------------------------------------------------------------------------

  defp verify_text({:ok, resp}, needle) do
    text = text_of(resp.body)

    verdict(
      [
        {String.contains?(String.downcase(text), needle),
         "text lacks #{inspect(needle)}: #{inspect(text)}"}
      ],
      "  (#{inspect(text)}; #{resp.body["modelVersion"]})"
    )
  end

  defp verify_candidates({:ok, resp}) do
    verdict(
      [{match?(%{"candidates" => [_ | _]}, resp.body), "no candidates"}],
      "  (text #{inspect(String.slice(text_of(resp.body), 0, 80))}; usage #{inspect(resp.body["usageMetadata"])})"
    )
  end

  defp verify_error_mentions({:ok, resp}, needle) do
    message = error_message(resp)

    verdict(
      [{String.contains?(message, needle), "message lacks #{inspect(needle)}"}],
      "  (#{message})"
    )
  end

  defp verify_bad_key({:ok, resp}) do
    details = get_in(resp.body, ["error", "details"]) || []
    reasons = for %{"reason" => r} <- details, do: r

    echo =
      if String.contains?(inspect(resp.body), bad_key()), do: "ECHOES THE KEY", else: "no key echo"

    verdict(
      [
        {"API_KEY_INVALID" in reasons,
         "details[].reason lacks API_KEY_INVALID: #{inspect(reasons)}"}
      ],
      "  (#{error_message(resp)}; #{echo})"
    )
  end

  defp verdict(checks, extra) do
    case for({false, why} <- checks, do: why) do
      [] -> %{ok?: true, note: extra}
      failures -> %{ok?: false, note: "  <- " <> Enum.join(failures, "; ")}
    end
  end

  defp text_of(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) when is_list(parts) do
    for %{"text" => t} = p <- parts, p["thought"] != true, into: "", do: t
  end

  defp text_of(_body), do: ""

  defp error_message(resp) do
    case resp.body do
      %{"error" => %{"message" => m}} -> String.slice(m, 0, 200)
      other -> String.slice(inspect(other), 0, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_result(%{arm: %{write: :envelope, target: path}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp),
      "header_names" => resp.headers |> Map.keys() |> Enum.sort(),
      "body" => resp.body
    })
  end

  defp write_result(%{arm: %{write: :probe, target: path}, expect: expect, response: {:ok, resp}}) do
    base = %{"status" => resp.status, "expected" => expect}

    body =
      if resp.status in 200..299 do
        base
        |> Map.put("text", String.slice(text_of(resp.body), 0, 500))
        |> Map.put("model_version", resp.body["modelVersion"])
        |> Map.put("usage", resp.body["usageMetadata"])
      else
        Map.put(base, "error_body", resp.body)
      end

    write_json(path, body)
  end

  defp picked_headers(resp) do
    for name <- ["content-type", "x-request-id", "x-goog-request-id"],
        v = header(resp, name),
        into: %{},
        do: {name, v}
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
  # marker.
  defp pending?(path) do
    case File.read(path) do
      {:error, :enoent} -> true
      {:ok, contents} -> match?({:ok, %{"_comment" => _}}, Jason.decode(contents))
      {:error, reason} -> raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp post(body, key_kind \\ :live) do
    Process.put(:live_calls, (Process.get(:live_calls) || 0) + 1)

    Req.post("#{@base_url}/models/#{@model}:generateContent",
      headers: [{"x-goog-api-key", key(key_kind)}],
      json: body,
      receive_timeout: 600_000,
      retry: false
    )
  end

  defp key(:live), do: System.get_env("GEMINI_API_KEY")
  defp key(:bad), do: bad_key()

  # A deliberately invalid key with Google's real prefix, so the bad-key arm
  # exercises the provider's own rejection. Recording its body commits no key
  # material: the only key it can echo is this fake one.
  defp bad_key, do: "AIzaNOTAREALKEY00112233445566778899"

  defp header(%Req.Response{} = resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> v
      _ -> nil
    end
  end

  # Copied from the sibling recorders (a `[CHORE]` to extract it is open).
  # Loaded ONLY when the key is absent: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("GEMINI_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end
end

RecordGeminiAudioFixtures.run()
