# scripts/record_elevenlabs_audio_fixtures.exs
#
# Fixture recorder AND live wire probe for the two ElevenLabs audio adapters:
#
#   * `ALLM.Providers.ElevenLabs.Speech`        — POST /v1/text-to-speech/{voice_id}
#   * `ALLM.Providers.ElevenLabs.Transcription` — POST /v1/speech-to-text
#   * the two speech streams (Phase 26.7): POST …/stream and
#     wss://…/stream-input, through the adapter's own URL builders and
#     `ALLM.Providers.Support.WebSocket.Mint`
#
# Usage (the subshell keeps `.env` out of the parent shell, so a later
# `mix test` stays keyless and the keyless gate tests keep proving ordering):
#
#     ( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )
#
# Writes:
#
#   test/fixtures/elevenlabs/speech/recorded/*.json
#   test/fixtures/elevenlabs/transcriptions/recorded/*.json
#   test/fixtures/elevenlabs/speech_stream/recorded/*.json   (Phase 26.7)
#
# It never touches a `synthesized/` directory.
#
# The four parts every probe in this repo carries
# -----------------------------------------------
#
# 1. **Control arms.** Every endpoint gets an invented field (a JSON body field
#    on TTS, a multipart field on STT, an initial-message field on
#    `/stream-input`). Each control accepts 200 or 422 and
#    records which. Observed 2026-09-26: **200 on both**, so ElevenLabs
#    ignores unknown fields and no arm here treats acceptance as proof that a
#    field is in the schema. Only RESPONSE observables (a content-type, a
#    header, an error code, a transcript) settle a wire-map row.
#
# 2. **Assert, don't narrate.** Every arm carries an expected status plus a
#    body verdict. All pending arms run first, and any mismatch prints the
#    want/got table to stderr and `System.halt(1)`s BEFORE a single file is
#    written. The `Req.Test` wire tests assert what the ADAPTER emits and stay
#    green whatever ElevenLabs does, so this script is the only place in the
#    repo that can see the provider change.
#
# 3. **Record the body, not the status.** TTS answers raw audio, and the
#    fixture convention is `.json`, so every recorded file is a JSON envelope:
#
#        {"status", "headers": {...}, "header_names": [...],
#         "body_base64", "byte_size", "sha256"}           # audio bodies
#        {"status", "headers": {...}, "body": {...}}      # JSON bodies (incl. errors)
#
#    `header_names` lists EVERY response header name, not only the ones the
#    adapter reads, so a correlation header that is absent is visible as
#    absent. Error envelopes are recorded too. Assert-only arms write
#    `probe_<arm>.json`: `{"status", "expected", "error_body"?}`.
#
# 4. **Overwrite guard over EVERY arm.** Each arm owns one target path. An arm
#    runs only when its target is pending (missing, or a JSON file still
#    carrying a `_comment` marker). A fully recorded tree makes ZERO live
#    calls and prints `0 live calls`. Delete a file to re-run the arm that
#    owns it.
#
# Settled outcomes (first run 2026-09-26) are recorded in
# `steering/2026-09-25_ELEVENLABS_TTS_SST_RECORDS.md` §26.6 and as dated
# corrections under the design's wire-field map.
#
# Cost: ElevenLabs' pricing page (fetched 2026-09-25) lists Flash at $0.05 per
# 1K characters and Scribe v2 at $0.22 per hour. The billed arms send "Hello."
# six times (36 characters) and the 3.7 s fox clip three times. The error arms
# (`tier_gate`, bad key, bad voice, 422) are rejected before synthesis. The
# streaming arms send 44 characters on `/stream` and about 45 more across
# the `/stream-input` sessions (the WebSocket error arms are rejected before
# synthesis). One clean run is well under $0.01; a fully recorded tree costs
# $0.00.
#
# This script is NOT in the published Hex package (`scripts/` is excluded).

defmodule RecordElevenLabsAudioFixtures do
  @moduledoc false

  alias ALLM.Providers.ElevenLabs.Speech
  alias ALLM.Providers.Support.WebSocket.Mint, as: WS
  alias ALLM.SpeechRequest

  @base "https://api.elevenlabs.io"
  @stt_url @base <> "/v1/speech-to-text"

  @speech_dir "test/fixtures/elevenlabs/speech/recorded"
  @stream_dir "test/fixtures/elevenlabs/speech_stream/recorded"
  @stt_dir "test/fixtures/elevenlabs/transcriptions/recorded"
  @fox_mp3 "test/fixtures/audio/quick_brown_fox.mp3"

  # Every TTS request is built by the adapter itself
  # (`ALLM.Providers.ElevenLabs.Speech.url/2` and `to_json_body/2`), so an
  # accepted arm is evidence about the request the adapter really sends,
  # injected defaults included: `tts_default` sends `output_format=mp3_44100_128`,
  # the voice and the model exactly as a default `ALLM.synthesize/3` call does
  # (corrected 2026-09-27; the first run hand-built its requests and sent no
  # `output_format`). The STT arms still build their multipart form here.
  @stt_model "scribe_v2"

  # There is no input-length arm. The design's `too_long` arm (eleven_v3,
  # 5,001 characters, expecting 400 `text_too_long`) was run once on
  # 2026-09-26 and got **200**: eleven_v3 synthesized the whole input, which
  # was billed. A longer input risks a far larger bill if it is accepted too,
  # so the `text_too_long` classification stays documented, not observed.

  def run do
    load_dotenv()

    unless System.get_env("ELEVENLABS_API_KEY") do
      IO.puts(
        :stderr,
        "ELEVENLABS_API_KEY not set (checked the environment and project-root .env) — refusing to record."
      )

      System.halt(1)
    end

    Enum.each([@speech_dir, @stt_dir, @stream_dir], &File.mkdir_p!/1)

    pending = Enum.filter(arms(), fn arm -> Enum.any?(arm.targets, &pending?/1) end)

    if pending == [] do
      IO.puts("0 live calls: every target is already recorded. Delete a file to re-run its arm.")
    else
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
    speech_arms() ++ stt_arms() ++ speech_stream_arms()
  end

  defp speech_arms do
    [
      %{
        id: :control,
        label: "CONTROL tts: not_a_real_field -> 200 (ignored) or 422 (rejected), recorded",
        targets: [speech_path("probe_control")],
        run: fn -> tts(speech_request(options: %{"not_a_real_field" => true})) end,
        expect: [200, 422],
        verify: &verify_control/1,
        write: :probe
      },
      %{
        id: :tts_default,
        label:
          "tts adapter defaults (voice, model, output_format=mp3_44100_128) -> audio/mpeg, " <>
            "request-id, character-cost",
        targets: [speech_path("tts_default")],
        run: fn -> tts(speech_request([])) end,
        expect: [200],
        verify: &verify_tts(&1, "audio/mpeg"),
        write: :audio_envelope
      },
      tts_format_arm(:tts_mp3, [format: :mp3, sample_rate: 24_000], "audio/mpeg"),
      tts_format_arm(:tts_pcm, [format: :pcm], "audio/pcm"),
      tts_format_arm(:tts_wav, [format: :wav], "audio/wav"),
      tts_format_arm(:tts_opus, [format: :opus], "audio/opus"),
      %{
        id: :tier_gate,
        label: "tts output_format=pcm_44100 -> 403 subscription_required (Pro tier)",
        targets: [speech_path("error_403_tier")],
        run: fn -> tts(speech_request(format: :pcm, sample_rate: 44_100)) end,
        expect: [403],
        verify: &verify_detail(&1, "code", "subscription_required"),
        write: :json_envelope
      },
      %{
        id: :bad_key,
        label: "tts BAD hex-shaped sk_ KEY -> 400 invalid_api_key (does the body echo the key?)",
        targets: [speech_path("error_400_bad_key")],
        run: fn -> tts(speech_request([]), :bad) end,
        expect: [400],
        verify: &verify_bad_key(&1, :bad, "invalid_api_key"),
        write: :json_envelope
      },
      %{
        # Added 2026-09-27: a key that is not hex-shaped gets a 401, not the
        # 400 above (functional review, 2026-09-26). Invalid-key calls are
        # not billed.
        id: :bad_key_401,
        label: "tts BAD mixed-case sk_ KEY -> 401 unauthorized (does the body echo the key?)",
        targets: [speech_path("error_401_bad_key")],
        run: fn -> tts(speech_request([]), :bad_mixed) end,
        expect: [401],
        verify: &verify_bad_key(&1, :bad_mixed, "unauthorized"),
        write: :json_envelope
      },
      %{
        id: :bad_voice,
        label: "tts unknown voice_id -> 404 voice_not_found",
        targets: [speech_path("error_404_voice")],
        run: fn -> tts(speech_request(voice: "notARealVoiceId000000")) end,
        expect: [404],
        verify: &verify_detail(&1, "code", "voice_not_found"),
        write: :json_envelope
      },
      %{
        id: :error_422,
        label: "tts body without text -> 422 with detail as an ARRAY",
        targets: [speech_path("error_422")],
        run: fn -> tts(speech_request([]), :live, &Map.delete(&1, "text")) end,
        expect: [422],
        verify: &verify_detail_list/1,
        write: :json_envelope
      }
    ]
  end

  defp stt_arms do
    [
      %{
        id: :stt_control,
        label: "CONTROL stt: not_a_real_field -> 200 (ignored) or 422 (rejected), recorded",
        targets: [stt_path("probe_control")],
        run: fn -> stt("fox.mp3", "audio/mpeg", [{"not_a_real_field", "x"}]) end,
        expect: [200, 422],
        verify: &verify_control/1,
        write: :probe
      },
      %{
        id: :stt_default,
        label: "stt #{@stt_model} fox mp3 -> 200, text mentions fox; all header names recorded",
        targets: [stt_path("scribe_v2")],
        run: fn -> stt("fox.mp3", "audio/mpeg") end,
        expect: [200],
        verify: &verify_stt/1,
        write: :json_envelope
      },
      %{
        id: :stt_audio_bin,
        # Narrowed 2026-09-27 from [200, 400] to [200]: the adapter uploads
        # unknown-mime audio as `audio.bin` because this arm got a 200, so a
        # 400 here would make the adapter wrong.
        label: "stt valid mp3 named audio.bin (application/octet-stream) -> 200, text mentions fox",
        targets: [stt_path("probe_audio_bin")],
        run: fn -> stt("audio.bin", "application/octet-stream") end,
        expect: [200],
        verify: &verify_stt/1,
        write: :json_envelope
      },
      %{
        id: :stt_bad_key,
        label: "stt BAD sk_ KEY -> 400 invalid_api_key",
        targets: [stt_path("error_400_bad_key")],
        run: fn -> stt("fox.mp3", "audio/mpeg", [], :bad) end,
        expect: [400],
        verify: &verify_bad_key(&1, :bad, "invalid_api_key"),
        write: :json_envelope
      }
    ]
  end

  defp tts_format_arm(id, fields, mime) do
    request = speech_request(fields)
    {:ok, %{output_format: output_format}} = output_format(request)

    %{
      id: id,
      label: "tts output_format=#{output_format} -> #{mime}",
      targets: [speech_path(Atom.to_string(id))],
      run: fn -> tts(request) end,
      expect: [200],
      verify: &verify_tts(&1, mime),
      write: :audio_envelope
    }
  end

  # ---------------------------------------------------------------------------
  # Streaming arms (Phase 26.7)
  #
  # `stream_chunked` reads `POST /v1/text-to-speech/{voice}/stream` through
  # `Finch.stream/5` on the adapter's own pool and times every data message.
  # The `ws_*` arms drive `wss://…/stream-input` through the adapter's own
  # transport (`ALLM.Providers.Support.WebSocket.Mint`) with the adapter's
  # own URL and initial-message builders (`ws_url/2`, `init_message/2`), and
  # record every frame in both directions. Texts stay short (50 characters
  # at most): TTS is billed per character.
  # ---------------------------------------------------------------------------

  # 44 characters: long enough for a pcm_24000 body of several chunks.
  @stream_text "The quick brown fox jumps over the lazy dog."
  @ws_tokens ["Hel", "lo", " world", "."]

  defp speech_stream_arms do
    [
      %{
        id: :stream_chunked,
        label:
          "http /stream pcm_24000 (#{String.length(@stream_text)} chars) -> audio/pcm in >= 2 timed chunks",
        targets: [stream_path("stream_chunked")],
        run: fn -> tts_stream(speech_request(input: @stream_text, format: :pcm)) end,
        expect: [200],
        verify: &verify_stream/1,
        write: :stream_envelope
      },
      %{
        id: :ws_tokens,
        label:
          "ws tokens #{inspect(@ws_tokens)} under the default chunk_length_schedule -> audio + isFinal",
        targets: [stream_path("ws_tokens")],
        run: fn -> ws_session(ws_request([]), :live, token_sends()) end,
        expect: [101],
        verify: &verify_ws_audio/1,
        write: :ws_frames
      },
      %{
        id: :ws_tokens_auto_mode,
        label: "ws tokens #{inspect(@ws_tokens)} with auto_mode=true -> audio + isFinal",
        targets: [stream_path("ws_tokens_auto_mode")],
        run: fn ->
          ws_session(
            ws_request(options: %{"query" => %{"auto_mode" => "true"}}),
            :live,
            token_sends()
          )
        end,
        expect: [101],
        verify: &verify_ws_audio/1,
        write: :ws_frames
      },
      %{
        id: :ws_end,
        label:
          "ws flush-then-close with one {\"text\":\" \"} keep-alive mid-input (inactivity_timeout=1) " <>
            "-> isFinal within 10 s of the flush",
        targets: [stream_path("ws_end")],
        run: fn ->
          sends = [
            {:json, %{"text" => "Hi"}},
            {:sleep, 500},
            {:json, %{"text" => " "}},
            {:sleep, 200},
            {:json, %{"text" => " there."}}
            | end_sends()
          ]

          ws_session(ws_request([]), :live, sends, stream_timeout: 1_000)
        end,
        expect: [101],
        verify: &verify_ws_end/1,
        write: :ws_frames
      },
      %{
        id: :ws_control,
        label:
          "CONTROL ws: not_a_real_field in the initial message -> accepted or rejected, recorded",
        targets: [stream_path("ws_control")],
        run: fn ->
          ws_session(ws_request(options: %{"not_a_real_field" => true}), :live, hi_sends())
        end,
        expect: [101],
        verify: &verify_ws_control/1,
        write: :ws_frames
      },
      %{
        id: :ws_v3,
        label:
          "ws model_id=eleven_v3 on /stream-input -> audio, an error frame or an upgrade error, recorded",
        targets: [stream_path("ws_v3")],
        run: fn -> ws_session(ws_request(model: "eleven_v3"), :live, hi_sends()) end,
        # First run 2026-09-27: the upgrade itself answered 400.
        expect: [101, 400],
        verify: &verify_ws_v3/1,
        write: :ws_frames
      },
      %{
        id: :ws_bad_voice,
        label: "ws unknown voice_id -> error frame voice_id_does_not_exist, then close 1008",
        targets: [stream_path("ws_bad_voice")],
        run: fn -> ws_session(ws_request(voice: "notARealVoiceId000000"), :live, hi_sends()) end,
        expect: [101],
        verify: &verify_ws_error(&1, "voice_id_does_not_exist"),
        write: :ws_frames
      },
      %{
        id: :ws_bad_key,
        label: "ws BAD mixed-case sk_ KEY -> error frame invalid_api_key, then close 1008",
        targets: [stream_path("ws_bad_key")],
        run: fn -> ws_session(ws_request([]), :bad_mixed, hi_sends()) end,
        expect: [101],
        verify: &verify_ws_error(&1, "invalid_api_key"),
        write: :ws_frames
      }
    ]
  end

  defp stream_path(name), do: Path.join(@stream_dir, name <> ".json")

  defp ws_request(fields),
    do: speech_request(Keyword.merge([input: "", format: :pcm], fields))

  # An LLM-like cadence: one token every 80 ms, then the end of input.
  defp token_sends do
    Enum.flat_map(@ws_tokens, fn t -> [{:json, %{"text" => t}}, {:sleep, 80}] end) ++ end_sends()
  end

  defp hi_sends, do: [{:json, %{"text" => "Hi."}} | end_sends()]

  defp end_sends, do: [{:json, %{"text" => "", "flush" => true}}, {:json, %{"text" => ""}}]

  defp speech_path(name), do: Path.join(@speech_dir, name <> ".json")
  defp stt_path(name), do: Path.join(@stt_dir, name <> ".json")

  # ---------------------------------------------------------------------------
  # Running and reporting
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
  defp status_of({:ws, %{status: s}}), do: s
  defp status_of({:error, e}), do: "ERR #{inspect(e)}"

  defp print_result(r) do
    flag = if r.ok?, do: "ok  ", else: "FAIL"

    IO.puts(
      "  #{flag} got #{inspect(r.got)} want #{inspect(r.expect, charlists: :as_lists)}  " <>
        "#{r.label}#{r.verdict.note}"
    )
  end

  defp halt_unless_all_ok(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(
        :stderr,
        "\nElevenLabs' audio wire no longer matches the recorded truth — refusing to record.\n"
      )

      Enum.each(results, fn r ->
        IO.puts(
          :stderr,
          "  want #{inspect(r.expect, charlists: :as_lists)}  got #{inspect(r.got)}  " <>
            "#{r.label}#{r.verdict.note}"
        )
      end)

      IO.puts(
        :stderr,
        "\nNothing was written. Re-read the ElevenLabs wire-field map in\n" <>
          "steering/2026-09-25_ELEVENLABS_TTS_SST.md before changing an expectation.\n" <>
          "The Req.Test wire tests assert what the ADAPTER emits and stay green regardless."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Verdicts
  # ---------------------------------------------------------------------------

  defp verify_control({:ok, %Req.Response{status: 200}}),
    do: %{ok?: true, note: "  (200: unknown fields are IGNORED; acceptance proves nothing)"}

  defp verify_control({:ok, %Req.Response{status: 422} = resp}),
    do: %{ok?: true, note: "  (422: unknown fields are REJECTED) #{snippet(resp.body)}"}

  defp verify_tts({:ok, %Req.Response{body: body} = resp}, mime_prefix) do
    ct = header(resp, "content-type") || ""

    verdict(
      [
        {String.starts_with?(ct, mime_prefix),
         "content-type #{inspect(ct)} is not #{mime_prefix}*"},
        {is_binary(body) and byte_size(body) > 0, "empty or non-binary body"},
        {is_binary(header(resp, "request-id")), "request-id header absent"},
        {is_binary(header(resp, "character-cost")), "character-cost header absent"}
      ],
      "  (#{ct}, #{if is_binary(body), do: byte_size(body), else: 0} bytes, " <>
        "character-cost #{inspect(header(resp, "character-cost"))})"
    )
  end

  defp verify_tts(_resp, _prefix), do: %{ok?: false, note: "  <- transport error"}

  defp verify_stt({:ok, resp}) do
    body = decode(resp.body)
    text = if is_map(body), do: body["text"], else: nil

    verdict(
      [
        {is_binary(text) and text =~ ~r/fox/i, "text absent or without \"fox\": #{inspect(text)}"},
        {is_map(body) and is_binary(body["transcription_id"]), "no transcription_id"},
        {is_map(body) and is_number(body["audio_duration_secs"]), "no audio_duration_secs"},
        {is_map(body) and is_binary(body["language_code"]), "no language_code"}
      ],
      "  (text #{inspect(text)}; language_code #{inspect(is_map(body) && body["language_code"])}; " <>
        "request-id header #{inspect(header(resp, "request-id"))})"
    )
  end

  defp verify_detail({:ok, resp}, key, want) do
    detail = resp.body |> decode() |> detail_of()
    got = if is_map(detail), do: detail[key], else: nil

    verdict(
      [
        {is_map(detail) and is_binary(detail["message"]), "no detail.message"},
        {got == want, "detail.#{key} is #{inspect(got)}, want #{inspect(want)}"}
      ],
      "  (#{snippet(resp.body)})"
    )
  end

  defp verify_detail_list({:ok, resp}) do
    detail = resp.body |> decode() |> detail_of()

    verdict(
      [{is_list(detail) and detail != [], "detail is not a non-empty list"}],
      "  (#{snippet(resp.body)})"
    )
  end

  defp verify_bad_key({:ok, resp}, key_kind, want_code) do
    detail = resp.body |> decode() |> detail_of()
    text = resp.body |> decode() |> Jason.encode!()
    sent = key(key_kind)

    echo =
      cond do
        String.contains?(text, sent) -> "ECHOES THE FULL KEY"
        String.contains?(text, String.slice(sent, -4, 4)) -> "echoes a MASKED key"
        true -> "no key echo"
      end

    verdict(
      [
        {is_map(detail) and detail["code"] == want_code,
         "detail.code is #{inspect(is_map(detail) && detail["code"])}, want #{inspect(want_code)}"},
        {is_map(detail) and detail["type"] == "authentication_error",
         "detail.type is #{inspect(is_map(detail) && detail["type"])}"}
      ],
      "  [#{echo}] (#{snippet(resp.body)})"
    )
  end

  # `/stream` framing, as for OpenAI (Alternative E): many data messages,
  # the first arriving before the last.
  defp verify_stream({:ok, resp} = r) do
    base = verify_tts(r, "audio/pcm")
    chunks = Req.Response.get_private(resp, :chunks, [])
    first = chunks |> List.first(%{}) |> Map.get("t_ms")
    last = chunks |> List.last(%{}) |> Map.get("t_ms")

    verdict(
      [
        {base.ok?, String.trim_leading(base.note, "  <- ")},
        {length(chunks) >= 2, "only #{length(chunks)} data message(s): the body did not stream"},
        {is_integer(first) and is_integer(last) and first < last,
         "first-chunk t_ms #{inspect(first)} is not before last-chunk t_ms #{inspect(last)}"}
      ],
      base.note <>
        "  [#{length(chunks)} data messages; first byte #{inspect(first)} ms, last #{inspect(last)} ms; " <>
        "transfer-encoding #{inspect(header(resp, "transfer-encoding"))}]"
    )
  end

  defp verify_stream(_resp), do: %{ok?: false, note: "  <- transport error"}

  defp verify_ws_audio({:ws, session}) do
    verdict(
      [
        {session.audio_frames >= 1, "no audio frame"},
        {session.final?, "no isFinal frame"},
        {session.error == nil, "error frame #{inspect(session.error)}"}
      ],
      "  [#{session.audio_frames} audio frames, #{session.audio_bytes} bytes; first audio " <>
        "#{inspect(session.first_audio_ms)} ms after the first text; close #{inspect(session.close)}]"
    )
  end

  defp verify_ws_end({:ws, session} = r) do
    base = verify_ws_audio(r)

    verdict(
      [
        {base.ok?, String.trim_leading(base.note, "  <- ")},
        {is_integer(session.final_after_flush_ms) and session.final_after_flush_ms <= 10_000,
         "isFinal #{inspect(session.final_after_flush_ms)} ms after the flush (want <= 10000)"}
      ],
      base.note <> "  [isFinal #{inspect(session.final_after_flush_ms)} ms after the flush]"
    )
  end

  defp verify_ws_control({:ws, session}) do
    outcome =
      cond do
        session.error -> "REJECTED #{inspect(session.error)}"
        session.final? -> "ACCEPTED (audio + isFinal): unknown init fields are ignored"
        true -> "neither audio nor an error"
      end

    %{ok?: session.error != nil or session.final?, note: "  (#{outcome})"}
  end

  defp verify_ws_v3({:ws, %{status: 101} = session}) do
    outcome =
      if session.final?,
        do: "eleven_v3 SPEAKS on /stream-input (#{session.audio_bytes} bytes)",
        else: "eleven_v3 REJECTED: #{inspect(session.error)}, close #{inspect(session.close)}"

    %{ok?: session.final? or session.error != nil, note: "  (#{outcome})"}
  end

  defp verify_ws_v3({:ws, session}) do
    body = session.frames |> List.first(%{}) |> Map.get("upgrade_body")

    %{
      ok?: body != nil,
      note: "  (eleven_v3 REJECTED at the upgrade, HTTP #{session.status}: #{inspect(body)})"
    }
  end

  defp verify_ws_error({:ws, session}, want) do
    code = session.error && session.error["error"]

    verdict(
      [
        {code == want, "error frame code #{inspect(code)}, want #{inspect(want)}"},
        {match?([1008 | _], session.close), "close #{inspect(session.close)}, want 1008"},
        {session.audio_frames == 0, "audio arrived"}
      ],
      "  (#{inspect(session.error)}; close #{inspect(session.close)}; key echo: " <>
        "#{if session.echo?, do: "ECHOES THE KEY", else: "none"})"
    )
  end

  defp verdict(checks, extra) do
    case for({false, why} <- checks, do: why) do
      [] -> %{ok?: true, note: extra}
      failures -> %{ok?: false, note: "  <- " <> Enum.join(failures, "; ") <> extra}
    end
  end

  defp detail_of(%{"detail" => d}), do: d
  defp detail_of(_), do: nil

  defp snippet(body), do: body |> decode() |> Jason.encode!() |> String.slice(0, 200)

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_result(%{arm: %{write: :probe, targets: [path]}, expect: expect, response: {:ok, resp}}) do
    base = %{"status" => resp.status, "expected" => expect}

    body =
      if resp.status in 200..299,
        do: base,
        else: Map.put(base, "error_body", decode(resp.body))

    write_json(path, body)
  end

  defp write_result(%{arm: %{write: :audio_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp),
      "header_names" => header_names(resp),
      "body_base64" => Base.encode64(resp.body),
      "byte_size" => byte_size(resp.body),
      "sha256" => :crypto.hash(:sha256, resp.body) |> Base.encode16(case: :lower)
    })
  end

  defp write_result(%{arm: %{write: :json_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp),
      "header_names" => header_names(resp),
      "body" => decode(resp.body)
    })
  end

  # The audio envelope plus `"chunks": [{"byte_size", "t_ms"}]`, the arrival
  # time of each data message since the request was sent.
  defp write_result(%{arm: %{write: :stream_envelope, targets: [path]}, response: {:ok, resp}}) do
    write_json(path, %{
      "status" => resp.status,
      "headers" => picked_headers(resp) |> Map.merge(pick(resp, ["transfer-encoding"])),
      "header_names" => header_names(resp),
      "body_base64" => Base.encode64(resp.body),
      "byte_size" => byte_size(resp.body),
      "sha256" => :crypto.hash(:sha256, resp.body) |> Base.encode16(case: :lower),
      "chunks" => Req.Response.get_private(resp, :chunks, [])
    })
  end

  # A WebSocket session: the upgrade status, the URL (which never carries
  # the key), and every frame in arrival order. `dir` is from the server's
  # side: `"in"` is a client frame, `"out"` a server frame.
  defp write_result(%{arm: %{write: :ws_frames, targets: [path]}, response: {:ws, session}}) do
    write_json(path, %{
      "status" => session.status,
      "url" => session.url,
      "frames" => session.frames,
      "summary" => %{
        "audio_frames" => session.audio_frames,
        "audio_bytes" => session.audio_bytes,
        "first_audio_ms" => session.first_audio_ms,
        "final_after_flush_ms" => session.final_after_flush_ms,
        "close" => session.close
      }
    })
  end

  defp pick(resp, names) do
    for name <- names, v = header(resp, name), into: %{}, do: {name, v}
  end

  defp picked_headers(resp) do
    for name <- ["content-type", "request-id", "character-cost", "retry-after"],
        v = header(resp, name),
        into: %{},
        do: {name, v}
  end

  defp header_names(resp), do: resp.headers |> Map.keys() |> Enum.sort()

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
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        match?({:ok, %{"_comment" => _}}, Jason.decode(contents))

      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  # Text kept short (6 characters) because TTS is billed per character.
  defp speech_request(fields), do: SpeechRequest.new(Keyword.merge([input: "Hello."], fields))

  defp output_format(%SpeechRequest{format: format, sample_rate: rate}),
    do: ALLM.Providers.Support.ElevenLabs.output_format(format, rate)

  # The URL and JSON body come from the adapter's own builders; `edit_body`
  # breaks the body on purpose for an error arm.
  defp tts(%SpeechRequest{} = request, key_kind \\ :live, edit_body \\ & &1) do
    bump()

    Req.post(Speech.url(request, []),
      headers: [{"xi-api-key", key(key_kind)}],
      json: edit_body.(Speech.to_json_body(request, [])),
      receive_timeout: 120_000,
      retry: false,
      decode_body: false
    )
  end

  defp stt(filename, content_type, extra \\ [], key_kind \\ :live) do
    bump()

    form =
      [
        {"file", {File.read!(@fox_mp3), filename: filename, content_type: content_type}},
        {"model_id", @stt_model}
      ] ++ extra

    Req.post(@stt_url,
      headers: [{"xi-api-key", key(key_kind)}],
      form_multipart: form,
      receive_timeout: 120_000,
      retry: false,
      decode_body: false
    )
  end

  # The `/stream` transport: `Finch.stream/5` on the adapter's own pool,
  # with the adapter's own URL and body. Returns a `%Req.Response{}` so the
  # verdicts and writers apply unchanged; the timings ride in
  # `private.chunks`.
  defp tts_stream(%SpeechRequest{} = request) do
    bump()

    finch_request =
      Finch.build(
        :post,
        Speech.stream_url(request, []),
        [{"xi-api-key", key(:live)}, {"content-type", "application/json"}],
        Jason.encode!(Speech.to_json_body(request, []))
      )

    t0 = System.monotonic_time(:millisecond)

    result =
      Finch.stream(
        finch_request,
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
        receive_timeout: 120_000
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

  # One `/stream-input` session through the adapter's own transport. Sends
  # the adapter's initial message, then `sends` (`{:json, map}` or
  # `{:sleep, ms}`, reading server frames while it sleeps), then reads until
  # the server closes (or 15 s pass). `t_ms` is measured from the upgrade
  # request.
  defp ws_session(%SpeechRequest{} = request, key_kind, sends, opts \\ []) do
    bump()
    url = Speech.ws_url(request, opts)
    t0 = System.monotonic_time(:millisecond)
    sent_key = key(key_kind)

    case WS.connect(url, [{"xi-api-key", sent_key}], connect_timeout: 15_000) do
      {:error, {:upgrade_status, status, body}} ->
        {:ws, session(url, status, [{:upgrade_body, body}], t0, sent_key)}

      {:error, {:transport, reason}} ->
        {:error, reason}

      {:ok, conn} ->
        s = %{conn: conn, t0: t0, log: []}
        s = ws_send(s, Speech.init_message(request, []))

        s =
          Enum.reduce(sends, s, fn
            {:json, map}, s -> s |> ws_read(0) |> ws_send(map)
            {:sleep, ms}, s -> ws_read(s, ms)
          end)

        s = ws_read_until_close(s, System.monotonic_time(:millisecond) + 15_000)
        WS.close(s.conn)
        WS.flush_messages(s.conn)
        {:ws, session(url, 101, Enum.reverse(s.log), t0, sent_key)}
    end
  end

  defp ws_send(s, map) do
    {:ok, conn} = WS.send_frame(s.conn, {:text, Jason.encode!(map)})
    %{s | conn: conn, log: [{:in, ms_since(s.t0), map} | s.log]}
  end

  # Reads server frames for `ms` milliseconds.
  defp ws_read(s, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_read(s, deadline, false)
  end

  defp ws_read_until_close(s, deadline), do: do_read(s, deadline, true)

  defp do_read(s, deadline, until_close?) do
    tag = WS.message_tag(s.conn)
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      m when is_tuple(m) and tuple_size(m) in [2, 3] and elem(m, 1) == tag ->
        {:ok, conn, frames} = WS.handle_message(s.conn, m)
        log = Enum.reduce(frames, s.log, fn f, log -> [{:out, ms_since(s.t0), f} | log] end)
        s = %{s | conn: conn, log: log}

        if until_close? and Enum.any?(frames, &(match?({:close, _, _}, &1) or &1 == :closed)),
          do: s,
          else: do_read(s, deadline, until_close?)
    after
      wait -> s
    end
  end

  defp ms_since(t0), do: System.monotonic_time(:millisecond) - t0

  # Summarises a session log and renders its frames for the fixture: server
  # audio is replaced by "<N bytes>" except in the first audio frame, which
  # is kept whole so a decode test has real base64.
  defp session(url, status, log, t0, sent_key) do
    _ = t0

    first_text =
      Enum.find_value(log, fn
        {:in, t, %{"text" => txt}} when txt not in [" ", ""] -> t
        _ -> nil
      end)

    flush_at =
      Enum.find_value(log, fn
        {:in, t, %{"flush" => true}} -> t
        _ -> nil
      end)

    {frames, acc} =
      Enum.map_reduce(
        log,
        %{audio_frames: 0, audio_bytes: 0, first_audio: nil, final: nil, error: nil, close: nil},
        &render/2
      )

    text = Jason.encode!(frames)

    %{
      url: url,
      status: status,
      frames: frames,
      audio_frames: acc.audio_frames,
      audio_bytes: acc.audio_bytes,
      first_audio_ms: acc.first_audio && first_text && acc.first_audio - first_text,
      final?: acc.final != nil,
      final_after_flush_ms: acc.final && flush_at && acc.final - flush_at,
      error: acc.error,
      close: acc.close,
      echo?: String.contains?(text, sent_key)
    }
  end

  defp render({:in, t, map}, acc),
    do: {%{"dir" => "in", "t_ms" => t, "text" => Jason.encode!(map)}, acc}

  defp render({:out, t, {:text, json}}, acc) do
    payload = Jason.decode!(json)

    {payload, acc} =
      case payload do
        %{"audio" => audio} when is_binary(audio) and audio != "" ->
          bytes = byte_size(Base.decode64!(audio))
          first? = acc.audio_frames == 0

          acc = %{
            acc
            | audio_frames: acc.audio_frames + 1,
              audio_bytes: acc.audio_bytes + bytes,
              first_audio: acc.first_audio || t
          }

          {if(first?, do: payload, else: Map.put(payload, "audio", "<#{bytes} bytes>")), acc}

        _ ->
          {payload, acc}
      end

    acc = if payload["isFinal"] == true, do: %{acc | final: acc.final || t}, else: acc
    acc = if is_binary(payload["error"]), do: %{acc | error: acc.error || payload}, else: acc
    {%{"dir" => "out", "t_ms" => t, "text" => Jason.encode!(payload)}, acc}
  end

  defp render({:out, t, {:close, code, reason}}, acc),
    do: {%{"dir" => "out", "t_ms" => t, "close" => [code, reason]}, %{acc | close: [code, reason]}}

  defp render({:out, t, :closed}, acc),
    do:
      {%{"dir" => "out", "t_ms" => t, "closed" => true},
       %{acc | close: acc.close || [nil, "closed"]}}

  defp render({:out, t, other}, acc),
    do: {%{"dir" => "out", "t_ms" => t, "other" => inspect(other)}, acc}

  defp render({:upgrade_body, body}, acc), do: {%{"dir" => "out", "upgrade_body" => body}, acc}

  defp bump, do: Process.put(:live_calls, (Process.get(:live_calls) || 0) + 1)

  defp key(:live), do: System.get_env("ELEVENLABS_API_KEY")
  defp key(:bad), do: "sk_" <> String.duplicate("0a1b", 12)
  defp key(:bad_mixed), do: "sk_" <> String.duplicate("a1B2c3D4", 6)

  # Deliberately invalid keys with ElevenLabs' real `sk_` prefix, so the
  # bad-key arms exercise the provider's own rejection. Recording their
  # bodies commits no key material: the only key a body can echo is one of
  # these. ElevenLabs answers the hex-shaped `:bad` key with a 400
  # `invalid_api_key` and the mixed-case `:bad_mixed` key with a 401
  # `unauthorized` (observed 2026-09-26); both carry
  # `detail.type: "authentication_error"`.

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

  # Loaded ONLY when the key is absent: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("ELEVENLABS_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end
end

RecordElevenLabsAudioFixtures.run()
