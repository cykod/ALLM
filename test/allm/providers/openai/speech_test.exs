defmodule ALLM.Providers.OpenAI.SpeechTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.OpenAI.Speech`: body builder, response
  decoder, error classifier and the 4096-code-point gate. No HTTP, except the
  keyless gate tests, which install a plug that fails the test if a request is
  ever built.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.OpenAI.Speech

  doctest ALLM.Providers.OpenAI.Speech

  # A gate placed after key resolution would reach HTTP and hit this plug, so
  # the gate tests stay honest in a shell that exports OPENAI_API_KEY.
  @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
  def flunk_plug(_conn), do: flunk("gate let the request reach HTTP")

  defp req(opts), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))

  describe "to_json_body/2" do
    test "fills model and voice defaults when nil" do
      body = Speech.to_json_body(req([]), [])

      assert body == %{"model" => "gpt-4o-mini-tts", "input" => "Hello.", "voice" => "alloy"}
    end

    test "format :pcm becomes response_format pcm" do
      assert %{"response_format" => "pcm"} = Speech.to_json_body(req(format: :pcm), [])
    end

    test "nil format / instructions / speed are absent, not null" do
      body = Speech.to_json_body(req([]), [])

      refute Map.has_key?(body, "response_format")
      refute Map.has_key?(body, "instructions")
      refute Map.has_key?(body, "speed")
    end

    test "set fields are forwarded" do
      body =
        Speech.to_json_body(
          req(model: "tts-1", voice: "coral", instructions: "cheerful", speed: 1.5),
          []
        )

      assert %{
               "model" => "tts-1",
               "voice" => "coral",
               "instructions" => "cheerful",
               "speed" => 1.5
             } = body
    end

    test "options merge UNDER the structural fields" do
      body = Speech.to_json_body(req(options: %{"input" => "x", "extra" => 1}), [])

      assert body["input"] == "Hello."
      assert body["extra"] == 1
    end

    test "atom option keys are stringified" do
      assert %{"extra" => true} = Speech.to_json_body(req(options: %{extra: true}), [])
    end

    test "stream_format is reserved and dropped from options" do
      body =
        Speech.to_json_body(req(options: %{"stream_format" => "sse", stream_format: "sse"}), [])

      refute Map.has_key?(body, "stream_format")
    end
  end

  describe "decode_response/4" do
    test "bytes + audio/wav decode to format :wav with raw nil" do
      headers = %{"content-type" => ["audio/wav"], "x-request-id" => ["req_abc"]}

      assert {:ok, %SpeechResponse{} = resp} =
               Speech.decode_response("RIFFxxxx", headers, req(metadata: %{"k" => "v"}), [])

      assert resp.format == :wav
      assert resp.audio.mime_type == "audio/wav"
      assert Audio.to_binary(resp.audio) == {:ok, "RIFFxxxx"}
      assert resp.raw == nil
      assert resp.request_id == "req_abc"
      assert resp.usage == %Usage{}
      assert resp.provider == :openai
      assert resp.model == "gpt-4o-mini-tts"
      assert resp.metadata == %{"k" => "v"}
    end

    test "opts[:request_id] wins over x-request-id" do
      headers = %{"content-type" => ["audio/mpeg"], "x-request-id" => ["req_abc"]}

      assert {:ok, %SpeechResponse{request_id: "mine"}} =
               Speech.decode_response("ID3", headers, req([]), request_id: "mine")
    end

    test "a parameterized content type still maps, and the mime is the table's" do
      headers = %{"content-type" => ["audio/mpeg; charset=binary"]}

      assert {:ok, %SpeechResponse{format: :mp3, audio: %Audio{mime_type: "audio/mpeg"}}} =
               Speech.decode_response("ID3", headers, req([]), [])
    end

    test "an audio content type outside the table keeps its mime and format nil" do
      headers = %{"content-type" => ["audio/x-custom"]}

      assert {:ok, %SpeechResponse{format: nil, audio: %Audio{mime_type: "audio/x-custom"}}} =
               Speech.decode_response("bytes", headers, req([]), [])
    end

    test "a non-audio content type on a 200 is :malformed_response" do
      headers = %{"content-type" => ["text/event-stream"]}

      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("data: {}", headers, req([]), [])
    end

    test "a missing content type is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("ID3", %{}, req([]), [])
    end

    test "an empty body is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("", %{"content-type" => ["audio/mpeg"]}, req([]), [])
    end

    test "a decoded JSON map is :malformed_response" do
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response(
                 %{"error" => "x"},
                 %{"content-type" => ["audio/mpeg"]},
                 req([]),
                 []
               )
    end
  end

  describe "to_speech_adapter_error/4" do
    defp err(status, body, headers \\ %{}),
      do: Speech.to_speech_adapter_error(status, body, headers, [])

    test "401 with a text/plain JSON binary body is :authentication_failed with its message" do
      body = ~s({"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}})
      e = err(401, body)

      assert e.reason == :authentication_failed
      assert e.message == "Incorrect API key provided"
      assert e.metadata.openai_code == "invalid_api_key"
    end

    test "a binary body that is not JSON falls back to a generic message" do
      e = err(401, "<html>nope</html>")
      assert e.reason == :authentication_failed
      assert e.message == "OpenAI HTTP 401"
    end

    test "404 model_not_found is :invalid_request" do
      e = err(404, %{"error" => %{"code" => "model_not_found", "message" => "no such model"}})
      assert e.reason == :invalid_request
      assert e.status == 404
    end

    test "400 is :invalid_request" do
      assert err(400, %{"error" => %{"message" => "bad voice"}}).reason == :invalid_request
    end

    test "400 whose message carries string_too_long is :context_length_exceeded" do
      body = %{
        "error" => %{
          "message" => "[{'type': 'string_too_long', 'loc': ('body', 'input')}]",
          "code" => nil
        }
      }

      assert err(400, body).reason == :context_length_exceeded
    end

    test "429 honours Retry-After" do
      e = err(429, %{"error" => %{"message" => "slow"}}, %{"retry-after" => ["7"]})
      assert e.reason == :rate_limited
      assert e.retry_after_ms == 7_000
    end

    test "500 is :provider_unavailable, 418 is :unknown, 403 is :authentication_failed" do
      assert err(500, %{}).reason == :provider_unavailable
      assert err(418, %{}).reason == :unknown
      assert err(403, %{}).reason == :authentication_failed
    end

    test "a non-map \"error\" value does not raise" do
      e = err(500, %{"error" => "boom"})
      assert e.reason == :provider_unavailable
      assert e.message == "boom"
      assert err(500, %{"error" => 42}).message == "OpenAI HTTP 500"
    end

    test "every provider-authored string on the error is redacted, message and metadata" do
      planted = "sk-proj-PLANTED000111222333444"

      e =
        err(400, %{
          "error" => %{"message" => "bad #{planted}", "code" => planted, "type" => planted}
        })

      refute inspect(e) =~ planted
      refute Jason.encode!(e) =~ planted
      assert e.metadata.openai_code == "[REDACTED]"
      assert e.metadata.openai_type == "[REDACTED]"
    end

    test "opts[:request_id] lands on metadata" do
      e = Speech.to_speech_adapter_error(500, %{}, %{}, request_id: "r1")
      assert e.metadata.request_id == "r1"
    end
  end

  describe "gate_input_length/2 (code points, keyless)" do
    test "4096 code points pass" do
      assert :ok = Speech.gate_input_length(req(input: String.duplicate("a", 4096)), [])
    end

    test "4097 code points are :context_length_exceeded with count and max" do
      assert {:error, %SpeechAdapterError{reason: :context_length_exceeded, metadata: meta}} =
               Speech.gate_input_length(req(input: String.duplicate("a", 4097)), [])

      assert meta.count == 4097
      assert meta.max == 4096
    end

    # Falsifier for a grapheme count, which would see 2049 and pass it.
    test "2049 x e+U+0301 (4098 code points, 2049 graphemes) is rejected" do
      input = String.duplicate("é", 2049)
      assert String.length(input) == 2049

      assert {:error,
              %SpeechAdapterError{reason: :context_length_exceeded, metadata: %{count: 4098}}} =
               Speech.gate_input_length(req(input: input), [])
    end

    # Falsifier for a byte count, which would see 8192 and reject it.
    test "4096 x precomposed U+00E9 (8192 bytes) passes" do
      input = String.duplicate("é", 4096)
      assert byte_size(input) == 8192
      assert :ok = Speech.gate_input_length(req(input: input), [])
    end

    test "the gate runs through synthesize/2 before key resolution" do
      assert {:error, %SpeechAdapterError{reason: :context_length_exceeded}} =
               Speech.synthesize(req(input: String.duplicate("a", 4097)), @flunk_plug)
    end
  end

  describe "input gates through synthesize/2 (keyless)" do
    test "empty input is :invalid_request" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{field: :input}}} =
               Speech.synthesize(req(input: ""), @flunk_plug)
    end

    test "a non-binary input is :invalid_request rather than raising" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               Speech.synthesize(%SpeechRequest{input: nil}, @flunk_plug)
    end

    test "a non-UTF-8 input is :invalid_request rather than raising in Jason" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{field: :input}}} =
               Speech.synthesize(req(input: <<0xFF, 0xFE>>), @flunk_plug)
    end

    test "prepare_request/2 runs the same gates" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               Speech.prepare_request(req(input: ""), @flunk_plug)
    end
  end

  describe "prepare_request/2" do
    test "applies the 60 s default receive timeout when request_timeout is absent" do
      assert {:ok, http} = Speech.prepare_request(req([]), api_key: "sk-x")
      assert http.options[:receive_timeout] == 60_000
    end

    test "opts[:request_timeout] overrides the default" do
      assert {:ok, http} = Speech.prepare_request(req([]), api_key: "sk-x", request_timeout: 5)
      assert http.options[:receive_timeout] == 5
    end

    test "under a speech_script it returns a stub error instead of delegating" do
      assert {:error, %SpeechAdapterError{reason: :unknown}} =
               Speech.prepare_request(req([]), adapter_opts: [speech_script: [{:ok, "x"}]])
    end
  end

  describe "script hand-off" do
    test "a script reaches FakeSpeech before any of this adapter's gates" do
      # 4097 characters would trip this adapter's own length gate; FakeSpeech
      # has no length gate, so a success proves the hand-off came first.
      long = String.duplicate("a", 4097)

      assert {:ok, %SpeechResponse{} = resp} =
               Speech.synthesize(req(input: long), adapter_opts: [speech_script: [{:ok, "AUDIO"}]])

      assert Audio.to_binary(resp.audio) == {:ok, "AUDIO"}
    end
  end

  describe "defensive edges at the public seams" do
    test "list-shaped headers, a bare-string value, and an unparseable Retry-After" do
      headers = [{"Content-Type", "audio/mpeg"}, {:junk, "x"}, {"retry-after", "soon"}]
      assert {:ok, %{format: :mp3}} = Speech.decode_response("ID3", headers, req([]), [])
      assert Speech.to_speech_adapter_error(429, %{}, headers, []).retry_after_ms == nil

      assert {:ok, %{format: :mp3}} =
               Speech.decode_response("ID3", %{"content-type" => "audio/mpeg"}, req([]), [])

      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               Speech.decode_response("ID3", :not_headers, req([]), [])
    end

    test "a non-binary, non-map error body falls back to the generic message" do
      assert Speech.to_speech_adapter_error(500, [1], %{}, []).message == "OpenAI HTTP 500"
    end

    test "off-shape options are ignored" do
      assert %{"input" => "Hello."} = Speech.to_json_body(%{req([]) | options: :bad}, [])
    end
  end
end
