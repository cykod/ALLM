defmodule ALLM.Providers.Support.ElevenLabsTest do
  @moduledoc """
  Tests for `ALLM.Providers.Support.ElevenLabs`: the format table, error
  classification (one test per HTTP row, driven from the recorded and
  synthesized fixtures), the error-field funnel and key redaction.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures
  alias ALLM.Providers.Support.ElevenLabs

  doctest ALLM.Providers.Support.ElevenLabs

  describe "output_format/2 (one test per Format-table row)" do
    test "nil format and nil rate -> the provider default mp3_44100_128" do
      assert {:ok,
              %{
                output_format: "mp3_44100_128",
                format: :mp3,
                mime_type: "audio/mpeg",
                sample_rate: 44_100
              }} = ElevenLabs.output_format(nil, nil)
    end

    for {rate, wire} <- [
          {22_050, "mp3_22050_32"},
          {24_000, "mp3_24000_48"},
          {44_100, "mp3_44100_128"}
        ] do
      test ":mp3 at #{rate} -> #{wire}" do
        assert {:ok, %{output_format: unquote(wire), mime_type: "audio/mpeg"}} =
                 ElevenLabs.output_format(:mp3, unquote(rate))
      end
    end

    test ":mp3 with nil rate defaults to 44100" do
      assert {:ok, %{output_format: "mp3_44100_128", sample_rate: 44_100}} =
               ElevenLabs.output_format(:mp3, nil)
    end

    test "nil format with a rate is mp3 at that rate" do
      assert {:ok, %{output_format: "mp3_24000_48", format: :mp3}} =
               ElevenLabs.output_format(nil, 24_000)
    end

    test ":opus defaults to 48000 and accepts only 48000" do
      assert {:ok, %{output_format: "opus_48000_64", mime_type: "audio/opus", sample_rate: 48_000}} =
               ElevenLabs.output_format(:opus, nil)

      assert {:error, {:sample_rate, [48_000]}} = ElevenLabs.output_format(:opus, 24_000)
    end

    for format <- [:pcm, :wav],
        rate <- [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000] do
      test "#{format} at #{rate} -> #{format}_#{rate}" do
        assert {:ok, %{output_format: wire, sample_rate: unquote(rate)}} =
                 ElevenLabs.output_format(unquote(format), unquote(rate))

        assert wire == "#{unquote(format)}_#{unquote(rate)}"
      end
    end

    test ":pcm and :wav default to 24000" do
      assert {:ok, %{output_format: "pcm_24000", mime_type: "audio/pcm"}} =
               ElevenLabs.output_format(:pcm, nil)

      assert {:ok, %{output_format: "wav_24000", mime_type: "audio/wav"}} =
               ElevenLabs.output_format(:wav, nil)
    end

    test "a rate outside the set is refused with the accepted list" do
      assert {:error, {:sample_rate, rates}} = ElevenLabs.output_format(:pcm, 11_025)
      assert 24_000 in rates
      assert {:error, {:sample_rate, _}} = ElevenLabs.output_format(:mp3, 48_000)
    end

    for {format, wire, mime} <- [
          {:ulaw, "ulaw_8000", "audio/basic"},
          {:alaw, "alaw_8000", "audio/alaw"}
        ] do
      test "#{format} defaults to and accepts only 8000 -> #{wire}" do
        assert {:ok,
                %{
                  output_format: unquote(wire),
                  format: unquote(format),
                  mime_type: unquote(mime),
                  sample_rate: 8_000
                }} = ElevenLabs.output_format(unquote(format), nil)

        assert {:ok, %{output_format: unquote(wire)}} =
                 ElevenLabs.output_format(unquote(format), 8_000)

        # The recorded `error_403_output_format.json` lists no other rate.
        assert {:error, {:sample_rate, [8_000]}} =
                 ElevenLabs.output_format(unquote(format), 16_000)
      end
    end

    test ":aac and :flac are refused" do
      assert {:error, {:format, :aac}} = ElevenLabs.output_format(:aac, nil)
      assert {:error, {:format, :flac}} = ElevenLabs.output_format(:flac, 24_000)
    end
  end

  describe "classify/2 (one test per HTTP row of the error classification)" do
    defp classify_fixture(env), do: ElevenLabs.classify(env["status"], env["body"])

    test "a quota code wins over the status (401 quota_exceeded -> :invalid_request)" do
      assert {:invalid_request, %{code: "quota_exceeded"}} =
               classify_fixture(Fixtures.speech_synthesized(:error_quota))
    end

    test "401 -> :authentication_failed" do
      assert {:authentication_failed, %{provider_status: "missing_permissions"}} =
               classify_fixture(Fixtures.speech_synthesized(:error_401))
    end

    test "the recorded invalid-key 400 (detail.type authentication_error) -> :authentication_failed" do
      env = Fixtures.speech_recorded(:error_400_bad_key)
      assert env["status"] == 400

      assert {:authentication_failed, %{code: "invalid_api_key", type: "authentication_error"}} =
               classify_fixture(env)
    end

    test "402 -> :invalid_request" do
      assert {:invalid_request, %{code: "payment_required"}} =
               classify_fixture(Fixtures.speech_synthesized(:error_402))
    end

    test "403 feature_not_available -> :unsupported_feature" do
      assert {:unsupported_feature, _} =
               classify_fixture(Fixtures.speech_synthesized(:error_403_feature))
    end

    test "the recorded invented-output_format 403 (invalid_output_format) -> :unsupported_feature" do
      env = Fixtures.speech_recorded(:error_403_output_format)
      assert env["status"] == 403

      assert {:unsupported_feature, %{code: "invalid_output_format", type: "validation_error"}} =
               classify_fixture(env)
    end

    test "the recorded tier-gate 403 (subscription_required) -> :unsupported_feature" do
      assert {:unsupported_feature, %{code: "subscription_required"}} =
               classify_fixture(Fixtures.speech_recorded(:error_403_tier))
    end

    test "other 403 -> :authentication_failed" do
      assert {:authentication_failed, _} =
               classify_fixture(Fixtures.speech_synthesized(:error_403_other))
    end

    test "400 text_too_long -> :context_length_exceeded" do
      assert {:context_length_exceeded, _} =
               classify_fixture(Fixtures.speech_synthesized(:error_400_too_long))
    end

    test "the recorded 404 voice_not_found -> :invalid_request" do
      assert {:invalid_request, %{code: "voice_not_found"}} =
               classify_fixture(Fixtures.speech_recorded(:error_404_voice))
    end

    test "409 -> :invalid_request" do
      assert {:invalid_request, _} = classify_fixture(Fixtures.speech_synthesized(:error_409))
    end

    test "the recorded 422 (detail is a list) -> :invalid_request with nil codes" do
      assert {:invalid_request, %{code: nil, type: nil, provider_status: nil}} =
               classify_fixture(Fixtures.speech_recorded(:error_422))
    end

    test "429 -> :rate_limited" do
      assert {:rate_limited, _} = classify_fixture(Fixtures.speech_synthesized(:error_429))
    end

    test "5xx -> :provider_unavailable" do
      assert {:provider_unavailable, _} = classify_fixture(Fixtures.speech_synthesized(:error_503))

      for status <- [500, 502, 504],
          do: assert({:provider_unavailable, _} = ElevenLabs.classify(status, %{}))
    end

    test "an unrecognised status -> :unknown" do
      assert {:unknown, _} = ElevenLabs.classify(418, %{})
    end

    test "a bare 400 with no detail -> :invalid_request" do
      assert {:invalid_request, %{code: nil}} = ElevenLabs.classify(400, "not json")
    end
  end

  describe "error_fields/4" do
    test "carries status, message and Retry-After for a 429" do
      env = Fixtures.speech_synthesized(:error_429)

      assert {:rate_limited, fields} =
               ElevenLabs.error_fields(429, env["body"], env["headers"], request_id: "r1")

      assert fields[:provider] == :elevenlabs
      assert fields[:status] == 429
      assert fields[:retry_after_ms] == 7_000
      assert fields[:message] == "Too many concurrent requests."
      assert fields[:metadata].status == 429
      assert fields[:metadata].code == "concurrent_limit_exceeded"
    end

    test "Retry-After is ignored for a non-retryable reason" do
      assert {:invalid_request, fields} =
               ElevenLabs.error_fields(400, %{}, %{"retry-after" => ["5"]}, [])

      assert fields[:retry_after_ms] == nil
      assert fields[:message] == "ElevenLabs HTTP 400"
    end

    test "a 422 detail list becomes a loc: msg message" do
      env = Fixtures.speech_recorded(:error_422)

      assert {:invalid_request, fields} =
               ElevenLabs.error_fields(422, env["body"], env["headers"], [])

      assert fields[:message] == "body.text: Field required"
    end

    test "a 422 entry without a string msg does not echo its other keys" do
      body = %{"detail" => [%{"input" => "secret text", "loc" => ["body", "text"]}]}
      assert {:invalid_request, fields} = ElevenLabs.error_fields(422, body, %{}, [])
      refute fields[:message] =~ "secret"
    end

    test "an undecoded JSON binary body is decoded before classification" do
      body = Jason.encode!(Fixtures.speech_recorded(:error_404_voice)["body"])
      assert {:invalid_request, fields} = ElevenLabs.error_fields(404, body, %{}, [])
      assert fields[:message] =~ "was not found"
    end
  end

  describe "redact_key_material/1" do
    @planted "sk_FAKEKEY0123456789abcdef0123456789abcdef"

    test "replaces an sk_ key and leaves ordinary text alone" do
      assert ElevenLabs.redact_key_material("key #{@planted} bad") == "key [REDACTED] bad"
      assert ElevenLabs.redact_key_material("sk_short stays") == "sk_short stays"
    end

    test "does not match the OpenAI key shape, and the OpenAI pattern does not match sk_" do
      openai = "sk-proj-FAKEKEY000111222333444555"
      assert ElevenLabs.redact_key_material(openai) == openai
      refute @planted =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
    end

    test "provider strings in the classification metadata are redacted" do
      body = %{"detail" => %{"code" => "x #{@planted}", "message" => "m"}}
      {_reason, meta} = ElevenLabs.classify(400, body)
      assert meta.code == "x [REDACTED]"
    end
  end

  describe "base_url/1 and headers/1" do
    test "defaults to the global host; opts and adapter_opts override it" do
      assert ElevenLabs.base_url([]) == "https://api.elevenlabs.io"
      assert ElevenLabs.base_url(base_url: "https://a") == "https://a"
      assert ElevenLabs.base_url(adapter_opts: [base_url: "https://b"]) == "https://b"

      assert ElevenLabs.base_url(base_url: "https://a", adapter_opts: [base_url: "https://b"]) ==
               "https://a"
    end

    test "auth is the xi-api-key header" do
      assert ElevenLabs.headers("sk_x") == [{"xi-api-key", "sk_x"}]
    end

    test "ws_base_url/1 swaps the scheme and keeps a ws:// or wss:// base" do
      assert ElevenLabs.ws_base_url([]) == "wss://api.elevenlabs.io"
      assert ElevenLabs.ws_base_url(base_url: "http://127.0.0.1:9") == "ws://127.0.0.1:9"
      assert ElevenLabs.ws_base_url(base_url: "wss://h") == "wss://h"
    end

    test "query_params/2 stringifies keys, drops nils and the reserved names" do
      assert ElevenLabs.query_params(%{:a => 1, "b" => nil, "c" => "x", "r" => 2}, ["r"]) ==
               %{"a" => 1, "c" => "x"}

      assert ElevenLabs.query_params("not a map", []) == %{}
    end
  end

  describe "ws_reason/2 (one row per WebSocket code of the error classification)" do
    for {code, reason} <- [
          {"invalid_api_key", :authentication_failed},
          {"authentication_required", :authentication_failed},
          {"auth_error", :authentication_failed},
          {"unaccepted_terms", :authentication_failed},
          {"quota_exceeded", :invalid_request},
          {"insufficient_credits", :invalid_request},
          {"rate_limited", :rate_limited},
          {"commit_throttled", :rate_limited},
          {"queue_overflow", :rate_limited},
          {"resource_exhausted", :rate_limited},
          {"session_time_limit_exceeded", :context_length_exceeded},
          {"input_error", :invalid_request},
          {"invalid_request", :invalid_request},
          {"chunk_size_exceeded", :invalid_request},
          {"insufficient_audio_activity", :invalid_request},
          {"voice_id_does_not_exist", :invalid_request},
          {"error", :provider_unavailable},
          {"transcriber_error", :provider_unavailable}
        ] do
      test "#{code} -> #{reason}, whatever the close code" do
        assert ElevenLabs.ws_reason(unquote(code), 1008) == unquote(reason)
        assert ElevenLabs.ws_reason(unquote(code), nil) == unquote(reason)
      end
    end

    test "an unknown code falls back on the close code: 1008 -> :invalid_request" do
      assert ElevenLabs.ws_reason("something_new", 1008) == :invalid_request
      assert ElevenLabs.ws_reason(nil, 1008) == :invalid_request
    end

    test "any other close code -> :network_error; no code at all -> :unknown" do
      assert ElevenLabs.ws_reason(nil, 1011) == :network_error
      assert ElevenLabs.ws_reason(nil, 1000) == :network_error
      assert ElevenLabs.ws_reason(nil, nil) == :unknown
    end
  end

  describe "ws_error?/1" do
    test "a string error, or a message_type ending in error, is an error frame" do
      assert ElevenLabs.ws_error?(%{"error" => "invalid_api_key"})
      assert ElevenLabs.ws_error?(%{"message_type" => "auth_error"})
      refute ElevenLabs.ws_error?(%{"message_type" => "partial_transcript"})
      refute ElevenLabs.ws_error?(%{"audio" => "AAAA", "isFinal" => nil, "error" => nil})
    end

    test "a classified message_type that does not end in error is an error frame too" do
      assert ElevenLabs.ws_error?(%{"message_type" => "commit_throttled"})
      assert ElevenLabs.ws_error?(%{"message_type" => "session_time_limit_exceeded"})
      refute ElevenLabs.ws_error?(%{"message_type" => "committed_transcript"})
      refute ElevenLabs.ws_error?(%{"message_type" => "warning"})
    end
  end

  describe "ws_error_fields/3" do
    test "the recorded bad-key frame -> :authentication_failed with code, close_code and message" do
      env = Fixtures.speech_stream_recorded(:ws_bad_key)
      [error_frame] = for %{"dir" => "out", "text" => t} <- env["frames"], do: Jason.decode!(t)

      assert {:authentication_failed, fields} =
               ElevenLabs.ws_error_fields(error_frame, nil, request_id: "rid")

      assert fields[:provider] == :elevenlabs
      assert fields[:message] == "Invalid API key"
      assert fields[:metadata] == %{code: "invalid_api_key", close_code: 1008, request_id: "rid"}
    end

    test "a message_type error (realtime STT shape) is classified by its message_type" do
      assert {:rate_limited, _} =
               ElevenLabs.ws_error_fields(%{"message_type" => "queue_overflow"}, nil, [])
    end

    test "the recorded realtime bad-key frame: the code is message_type, the text is error" do
      env = Fixtures.realtime_recorded(:rt_bad_key)

      [frame] =
        for %{"dir" => "out", "text" => t} <- env["frames"],
            %{"message_type" => "auth_error"} = p <- [Jason.decode!(t)],
            do: p

      assert %{"error" => text} = frame
      assert {:authentication_failed, fields} = ElevenLabs.ws_error_fields(frame, nil, [])
      assert fields[:message] == text
      assert fields[:metadata].code == "auth_error"
    end

    test "the recorded commit_throttled frame -> :rate_limited with the provider's text" do
      env = Fixtures.realtime_recorded(:rt_end)

      [frame] =
        for %{"dir" => "out", "text" => t} <- env["frames"],
            %{"message_type" => "commit_throttled"} = p <- [Jason.decode!(t)],
            do: p

      assert {:rate_limited, fields} = ElevenLabs.ws_error_fields(frame, nil, [])
      assert fields[:message] =~ "0.3s"
    end

    test "a planted key in a provider message is redacted" do
      {_reason, fields} =
        ElevenLabs.ws_error_fields(
          %{"error" => "invalid_api_key", "message" => "bad key sk_abcdefghijklmnop0123"},
          1008,
          []
        )

      assert fields[:message] == "bad key [REDACTED]"
    end

    test "a close without an error frame names the close code in the message" do
      assert {:network_error, fields} = ElevenLabs.ws_error_fields(%{}, 1011, [])
      assert fields[:message] =~ "1011"
      assert fields[:metadata].close_code == 1011
    end
  end
end
