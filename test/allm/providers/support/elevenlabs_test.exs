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
  end
end
