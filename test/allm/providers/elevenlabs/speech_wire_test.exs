defmodule ALLM.Providers.ElevenLabs.SpeechWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.ElevenLabs.Speech`, driven
  end-to-end through `synthesize/2` behind a `Req.Test` stub.

  **Provenance.** `recorded/` holds live responses written by
  `scripts/record_elevenlabs_audio_fixtures.exs` on 2026-09-26, including
  the assert-only `probe_*.json` outcomes (`tts_default.json` and
  `error_401_bad_key.json` on 2026-09-27, from the adapter's own request), and none carries a `_comment`
  marker. `synthesized/` files each carry one. Both halves are gated below
  by tests that read the raw file bytes, because the loaders strip the
  marker.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, SpeechRequest, SpeechResponse}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.ElevenLabs.Speech
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures
  alias ALLM.Providers.OpenAITestFixtures

  setup do
    {:ok, stub: String.to_atom("elevenlabs_speech_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))

  defp call(stub, request, opts \\ []) do
    Speech.synthesize(
      request,
      Keyword.merge(
        [api_key: "sk_wiretest", retry: false, adapter_opts: [plug: {Req.Test, stub}]],
        opts
      )
    )
  end

  defp stub_env(stub, env), do: Req.Test.stub(stub, &Fixtures.replay(&1, env))

  # {sample rate, Layer III bitrate in kbps} from the first MPEG audio frame
  # header, after an optional ID3v2 tag.
  @mp3_rates %{3 => [44_100, 48_000, 32_000], 2 => [22_050, 24_000, 16_000]}
  @mp3_l3_kbps %{
    3 => [nil, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    2 => [nil, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
  }

  defp mp3_frame(<<"ID3", _ver::16, _flags, s1, s2, s3, s4, rest::binary>>) do
    size = Bitwise.bsl(s1, 21) + Bitwise.bsl(s2, 14) + Bitwise.bsl(s3, 7) + s4
    <<_tag::binary-size(size), frames::binary>> = rest
    mp3_frame(frames)
  end

  defp mp3_frame(<<0b11111111111::11, version::2, 0b01::2, _crc::1, bitrate::4, rate::2, _::bits>>),
    do: {Enum.at(@mp3_rates[version], rate), Enum.at(@mp3_l3_kbps[version], bitrate)}

  # ---------------------------------------------------------------------------
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @recorded ~w(probe_control tts_default tts_mp3 tts_pcm tts_wav tts_opus
                 error_403_tier error_400_bad_key error_401_bad_key error_404_voice
                 error_422)
    @synthesized ~w(error_401 error_429 error_402 error_quota error_403_feature
                    error_403_other error_400_too_long error_409 error_503)

    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(Fixtures.raw("speech/recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`"
      end
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert Fixtures.raw("speech/synthesized", unquote(name))["_comment"] =~
                 "Synthesized (Phase 26.6)"
      end
    end

    test "@recorded enumerates every file under recorded/" do
      assert Fixtures.names_on_disk("speech/recorded") == Enum.sort(@recorded)
    end

    test "@synthesized enumerates every file under synthesized/" do
      assert Fixtures.names_on_disk("speech/synthesized") == Enum.sort(@synthesized)
    end

    test "audio envelopes check out against their byte_size and sha256" do
      for name <- [:tts_default, :tts_mp3, :tts_pcm, :tts_wav, :tts_opus] do
        env = Fixtures.speech_recorded(name)
        assert byte_size(OpenAITestFixtures.envelope_bytes(env)) == env["byte_size"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Request shape
  # ---------------------------------------------------------------------------

  describe "request shape" do
    test "POSTs JSON to /v1/text-to-speech/<voice> with the xi-api-key header", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path, conn.query_string,
           Plug.Conn.get_req_header(conn, "xi-api-key"),
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "content-type"), Jason.decode!(raw)}
        )

        Fixtures.replay(conn, Fixtures.speech_recorded(:tts_pcm))
      end)

      assert {:ok, _} = call(stub, req(format: :pcm, speed: 1.1))

      assert_received {:req, "POST", "api.elevenlabs.io", "/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
                       "output_format=pcm_24000", ["sk_wiretest"], [], [ct], body}

      assert ct =~ "application/json"

      assert body == %{
               "text" => "Hello.",
               "model_id" => "eleven_flash_v2_5",
               "voice_settings" => %{"speed" => 1.1}
             }
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/
  # ---------------------------------------------------------------------------

  describe "recorded audio bodies" do
    for {name, request_opts, format, mime, rate} <- [
          {:tts_default, [], :mp3, "audio/mpeg", 44_100},
          {:tts_mp3, [format: :mp3, sample_rate: 24_000], :mp3, "audio/mpeg", 24_000},
          {:tts_pcm, [format: :pcm], :pcm, "audio/pcm", 24_000},
          {:tts_wav, [format: :wav], :wav, "audio/wav", 24_000},
          {:tts_opus, [format: :opus], :opus, "audio/opus", 48_000}
        ] do
      test "recorded/#{name}.json decodes to #{inspect(format)} at #{rate} Hz", %{stub: stub} do
        env = Fixtures.speech_recorded(unquote(name))
        stub_env(stub, env)

        assert {:ok, %SpeechResponse{} = resp} = call(stub, req(unquote(request_opts)))
        assert resp.format == unquote(format)
        assert resp.audio.mime_type == unquote(mime)
        assert resp.sample_rate == unquote(rate)
        assert Audio.to_binary(resp.audio) == {:ok, OpenAITestFixtures.envelope_bytes(env)}
        assert resp.id == env["headers"]["request-id"]

        assert resp.raw == %{
                 "character_cost" => String.to_integer(env["headers"]["character-cost"])
               }

        assert resp.provider == :elevenlabs
      end
    end

    # `resp.sample_rate` is the REQUESTED rate, so the table above cannot fail
    # on provider behaviour. The mp3 bodies' own first frame header can: it
    # states the rate (and bitrate) ElevenLabs actually encoded. tts_default
    # was re-recorded 2026-09-27 with the adapter's own request
    # (`output_format=mp3_44100_128`).
    for {name, rate, kbps} <- [{:tts_default, 44_100, 128}, {:tts_mp3, 24_000, nil}] do
      test "recorded/#{name}.json's first mp3 frame is #{rate} Hz" do
        bytes = OpenAITestFixtures.envelope_bytes(Fixtures.speech_recorded(unquote(name)))
        assert {rate, kbps} = mp3_frame(bytes)
        assert rate == unquote(rate)
        if unquote(kbps), do: assert(kbps == unquote(kbps))
      end
    end

    test "a wav body starts with a RIFF header" do
      assert <<"RIFF", _::binary>> =
               OpenAITestFixtures.envelope_bytes(Fixtures.speech_recorded(:tts_wav))
    end

    test "the recorded default response names request-id and character-cost headers" do
      names = Fixtures.speech_recorded(:tts_default)["header_names"]
      assert "request-id" in names
      assert "character-cost" in names
    end
  end

  describe "recorded error bodies" do
    test "error_400_bad_key.json (a 400) is :authentication_failed", %{stub: stub} do
      env = Fixtures.speech_recorded(:error_400_bad_key)
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      assert err.status == 400
      assert err.message == env["body"]["detail"]["message"]
      assert err.metadata.code == "invalid_api_key"
    end

    test "error_401_bad_key.json (a non-hex key's 401) is :authentication_failed", %{
      stub: stub
    } do
      env = Fixtures.speech_recorded(:error_401_bad_key)
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      assert err.status == 401
      assert err.message == env["body"]["detail"]["message"]
      assert err.metadata.code == "unauthorized"
      assert err.metadata.type == "authentication_error"
    end

    test "error_403_tier.json (pcm_44100 on a lower tier) is :unsupported_feature", %{
      stub: stub
    } do
      stub_env(stub, Fixtures.speech_recorded(:error_403_tier))

      assert {:error, %SpeechAdapterError{reason: :unsupported_feature, status: 403} = err} =
               call(stub, req(format: :pcm, sample_rate: 44_100))

      assert err.message =~ "Pro tier"
    end

    test "error_404_voice.json is :invalid_request with the provider code", %{stub: stub} do
      stub_env(stub, Fixtures.speech_recorded(:error_404_voice))

      assert {:error, %SpeechAdapterError{reason: :invalid_request, status: 404} = err} =
               call(stub, req(voice: "notARealVoiceId000000"))

      assert err.metadata.code == "voice_not_found"
    end

    test "error_422.json (detail list) is :invalid_request with a field message", %{stub: stub} do
      stub_env(stub, Fixtures.speech_recorded(:error_422))

      assert {:error, %SpeechAdapterError{reason: :invalid_request, status: 422} = err} =
               call(stub, req())

      assert err.message == "body.text: Field required"
    end
  end

  describe "recorded probe outcomes" do
    test "the control arm was accepted (unknown fields are ignored)" do
      assert Fixtures.speech_recorded(:probe_control)["status"] == 200
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @planted "sk_FAKEKEY0123456789abcdef0123456789abcdef"

    test "the planted sk_ token in synthesized/error_401.json is redacted", %{stub: stub} do
      env = Fixtures.speech_synthesized(:error_401)
      assert env["body"]["detail"]["message"] =~ @planted, "fixture must carry a key-shaped token"
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      refute inspect(err) =~ @planted
      refute Jason.encode!(err) =~ @planted
      assert err.message =~ "[REDACTED]"
    end

    test "the OpenAI, Gemini and Voyage key patterns match nothing in the same fixture" do
      message = Fixtures.speech_synthesized(:error_401)["body"]["detail"]["message"]

      refute message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
      refute message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\bsk_[A-Za-z0-9]{16,}/
    end

    test "the recorded invalid-key error does not echo the key" do
      body = Jason.encode!(Fixtures.speech_recorded(:error_400_bad_key)["body"])
      refute body =~ ~r/\bsk_[A-Za-z0-9]{16,}/
    end
  end

  describe "synthesized error rows through synthesize/2" do
    test "error_429.json maps to :rate_limited with Retry-After honoured", %{stub: stub} do
      stub_env(stub, Fixtures.speech_synthesized(:error_429))

      assert {:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 7_000}} =
               call(stub, req())
    end

    test "error_quota.json (a 401 with quota_exceeded) is :invalid_request", %{stub: stub} do
      stub_env(stub, Fixtures.speech_synthesized(:error_quota))

      assert {:error, %SpeechAdapterError{reason: :invalid_request, status: 401}} =
               call(stub, req())
    end

    test "error_400_too_long.json is :context_length_exceeded", %{stub: stub} do
      stub_env(stub, Fixtures.speech_synthesized(:error_400_too_long))

      assert {:error, %SpeechAdapterError{reason: :context_length_exceeded}} = call(stub, req())
    end

    test "error_503.json is :provider_unavailable with Retry-After", %{stub: stub} do
      stub_env(stub, Fixtures.speech_synthesized(:error_503))

      assert {:error, %SpeechAdapterError{reason: :provider_unavailable, retry_after_ms: 2_000}} =
               call(stub, req())
    end
  end

  # ---------------------------------------------------------------------------
  # Transport
  # ---------------------------------------------------------------------------

  describe "transport failures" do
    test "a timeout converts to :timeout", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %SpeechAdapterError{reason: :timeout}} =
               call(stub, req(), request_timeout: 50)
    end

    test "a connection refusal converts to :network_error", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %SpeechAdapterError{reason: :network_error}} = call(stub, req())
    end

    test "a 200 JSON body instead of audio is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"not" => "audio"}))
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} = call(stub, req())
    end

    test "an undecodable JSON 200 is :malformed_response and does not leak the body", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not json at all")
      end)

      assert {:error, %SpeechAdapterError{reason: :malformed_response} = err} = call(stub, req())
      refute inspect(err) =~ "not json"
      assert is_binary(Exception.message(err.cause))
    end
  end
end
