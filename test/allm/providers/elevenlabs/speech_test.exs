defmodule ALLM.Providers.ElevenLabs.SpeechTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.ElevenLabs.Speech`: URL and body builders,
  the keyless pre-flight gates, the response decoder, and the adapter's own
  retry loop. The gate tests install a plug that fails the test if a request
  is ever sent, so they stay honest in a shell that exports
  `ELEVENLABS_API_KEY`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.{Audio, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.ElevenLabs.Speech
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures

  doctest ALLM.Providers.ElevenLabs.Speech

  @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
  def flunk_plug(_conn), do: flunk("gate let the request reach HTTP")

  defp req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))

  describe "to_json_body/2" do
    test "fills model_id from the default and sends text" do
      assert Speech.to_json_body(req(), []) == %{
               "text" => "Hello.",
               "model_id" => "eleven_flash_v2_5"
             }
    end

    test "an explicit model is sent" do
      assert %{"model_id" => "eleven_multilingual_v2"} =
               Speech.to_json_body(req(model: "eleven_multilingual_v2"), [])
    end

    test "speed becomes voice_settings.speed" do
      assert %{"voice_settings" => %{"speed" => 1.1}} = Speech.to_json_body(req(speed: 1.1), [])
    end

    test "an options voice_settings map coexists with speed" do
      body =
        Speech.to_json_body(
          req(speed: 1.1, options: %{"voice_settings" => %{"stability" => 0.3}}),
          []
        )

      assert body["voice_settings"] == %{"stability" => 0.3, "speed" => 1.1}
    end

    test "speed wins over an options voice_settings speed; atom keys are stringified" do
      body = Speech.to_json_body(req(speed: 1.1, options: %{voice_settings: %{speed: 0.8}}), [])
      assert body["voice_settings"] == %{"speed" => 1.1}
    end

    test "options text does not replace the input" do
      log =
        capture_log([level: :debug], fn ->
          assert %{"text" => "Hello."} = Speech.to_json_body(req(options: %{"text" => "x"}), [])
        end)

      assert log =~ "dropping reserved option"
    end

    test "options output_format and model_id are dropped" do
      body =
        Speech.to_json_body(
          req(options: %{"output_format" => "pcm_8000", "model_id" => "other"}),
          []
        )

      refute Map.has_key?(body, "output_format")
      assert body["model_id"] == "eleven_flash_v2_5"
    end

    test "options query stays out of the body; other options merge under the fields" do
      body =
        Speech.to_json_body(
          req(options: %{"query" => %{"optimize" => 1}, "seed" => 7, language_code: "en"}),
          []
        )

      refute Map.has_key?(body, "query")
      assert body["seed"] == 7
      assert body["language_code"] == "en"
    end

    test "nil fields are absent, not null" do
      body = Speech.to_json_body(req(), [])
      refute Map.has_key?(body, "voice_settings")
      refute Enum.any?(body, fn {_k, v} -> is_nil(v) end)
    end
  end

  describe "url/2" do
    test "the default voice goes in the path with the default output_format" do
      assert Speech.url(req(), []) ==
               "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=mp3_44100_128"
    end

    test "an explicit voice and format" do
      assert Speech.url(req(voice: "abc123", format: :pcm, sample_rate: 16_000), []) ==
               "https://api.elevenlabs.io/v1/text-to-speech/abc123?output_format=pcm_16000"
    end

    for {format, wire} <- [ulaw: "ulaw_8000", alaw: "alaw_8000"] do
      test "format #{inspect(format)} sends output_format=#{wire}" do
        assert Speech.url(req(format: unquote(format)), []) =~ "?output_format=#{unquote(wire)}"

        assert Speech.url(req(format: unquote(format), sample_rate: 8_000), []) =~
                 "?output_format=#{unquote(wire)}"
      end
    end

    test "options query merges under output_format" do
      url =
        Speech.url(
          req(
            format: :wav,
            options: %{"query" => %{"enable_logging" => false, "output_format" => "pcm_8000"}}
          ),
          []
        )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query == %{"enable_logging" => "false", "output_format" => "wav_24000"}
    end

    test "base_url: overrides the host" do
      assert Speech.url(req(), base_url: "https://api.eu.residency.elevenlabs.io") =~
               ~r{^https://api\.eu\.residency\.elevenlabs\.io/v1/text-to-speech/}
    end

    test "a voice is path-encoded" do
      assert Speech.url(req(voice: "a b/c"), []) =~ "/v1/text-to-speech/a%20b%2Fc?"
    end
  end

  describe "pre-flight gates (keyless, before Keys.fetch!/2)" do
    test "instructions -> :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature} = err} =
               Speech.synthesize(req(instructions: "x"), @flunk_plug)

      assert err.metadata.field == :instructions
      assert err.provider == :elevenlabs
    end

    test "format :aac -> :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature} = err} =
               Speech.synthesize(req(format: :aac), @flunk_plug)

      assert err.metadata.field == :format
    end

    test "format :opus at 24000 -> :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature} = err} =
               Speech.synthesize(req(format: :opus, sample_rate: 24_000), @flunk_plug)

      assert err.metadata.field == :sample_rate
      assert err.metadata.sample_rate == 24_000
    end

    for format <- [:ulaw, :alaw] do
      test "format #{inspect(format)} at 16000 -> :unsupported_feature naming the rate" do
        assert {:error, %SpeechAdapterError{reason: :unsupported_feature} = err} =
                 Speech.synthesize(req(format: unquote(format), sample_rate: 16_000), @flunk_plug)

        assert err.metadata.field == :sample_rate
        assert err.message =~ "[8000]"
      end
    end

    test "empty input -> :invalid_request" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request} = err} =
               Speech.synthesize(req(input: ""), @flunk_plug)

      assert err.metadata.field == :input
    end

    test "non-binary and non-UTF-8 input -> :invalid_request" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               Speech.synthesize(%SpeechRequest{input: nil}, @flunk_plug)

      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               Speech.synthesize(req(input: <<0xFF>>), @flunk_plug)
    end

    test "prepare_request/2 runs the same gates" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature}} =
               Speech.prepare_request(req(format: :flac), [])
    end

    test "prepare_request/2 under a speech_script returns a stub error" do
      assert {:error, %SpeechAdapterError{reason: :unknown}} =
               Speech.prepare_request(req(), adapter_opts: [speech_script: [{:ok, "x"}]])
    end
  end

  describe "prepare_request/2" do
    test "sends the xi-api-key header and the JSON body" do
      {:ok, http} = Speech.prepare_request(req(), api_key: "sk_test")
      assert Req.Request.get_header(http, "xi-api-key") == ["sk_test"]
      assert http.options.json == %{"text" => "Hello.", "model_id" => "eleven_flash_v2_5"}
      assert http.options.receive_timeout == 60_000
    end
  end

  describe "decode_response/4" do
    test "maps content-type, request-id and character-cost; sample rate from the request" do
      headers = %{
        "content-type" => ["audio/pcm"],
        "request-id" => ["req_1"],
        "character-cost" => ["3"]
      }

      assert {:ok, %SpeechResponse{} = resp} =
               Speech.decode_response(
                 "PCM",
                 headers,
                 req(format: :pcm, metadata: %{k: 1}),
                 request_id: "facade-1"
               )

      assert resp.format == :pcm
      assert resp.audio.mime_type == "audio/pcm"
      assert resp.sample_rate == 24_000
      assert resp.id == "req_1"
      assert resp.request_id == "facade-1"
      assert resp.raw == %{"character_cost" => 3}
      assert resp.model == "eleven_flash_v2_5"
      assert resp.provider == :elevenlabs
      assert resp.usage == %Usage{}
      assert resp.metadata == %{k: 1}
      assert Audio.to_binary(resp.audio) == {:ok, "PCM"}
    end

    test "the nil-format default reports mp3 at 44100" do
      assert {:ok, %SpeechResponse{format: :mp3, sample_rate: 44_100, raw: nil}} =
               Speech.decode_response("ID3", %{"content-type" => ["audio/mpeg"]}, req(), [])
    end

    test "a non-audio content type is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("{}", %{"content-type" => ["application/json"]}, req(), [])
    end

    test "an empty or non-binary body is :malformed_response" do
      headers = %{"content-type" => ["audio/mpeg"]}

      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("", headers, req(), [])

      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response(%{"x" => 1}, headers, req(), [])
    end

    test "an unparsable character-cost leaves raw nil" do
      headers = %{"content-type" => ["audio/mpeg"], "character-cost" => ["n/a"]}
      assert {:ok, %SpeechResponse{raw: nil}} = Speech.decode_response("ID3", headers, req(), [])
    end
  end

  describe "retry (the adapter's own ALLM.Retry.run/3 loop)" do
    setup do
      {:ok, stub: String.to_atom("elevenlabs_speech_retry_#{System.unique_integer([:positive])}")}
    end

    defp rate_limited_then_ok(stub) do
      parent = self()
      counter = :counters.new(1, [])

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, ~s({"detail":{"status":"concurrent_limit_exceeded"}}))
        else
          Fixtures.replay(conn, Fixtures.speech_recorded(:tts_mp3))
        end
      end)
    end

    defp call(stub, retry) do
      Speech.synthesize(req(),
        api_key: "sk_test",
        retry: retry,
        adapter_opts: [plug: {Req.Test, stub}]
      )
    end

    test "a policy listing :rate_limited retries a 429 once and succeeds", %{stub: stub} do
      rate_limited_then_ok(stub)

      assert {:ok, %SpeechResponse{format: :mp3}} =
               call(stub,
                 max_attempts: 3,
                 base_delay_ms: 0,
                 jitter_ms: 0,
                 retry_on: [:rate_limited]
               )

      assert_received :attempt
      assert_received :attempt
      refute_received :attempt
    end

    test "the default policy does not retry a 429", %{stub: stub} do
      rate_limited_then_ok(stub)

      assert {:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               call(stub, :default)

      assert_received :attempt
      refute_received :attempt
    end
  end
end
