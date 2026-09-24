defmodule ALLM.Providers.Gemini.TranscriptionTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.Gemini.Transcription`: gates, JSON body
  builder, response decoder, error classifier, and the no-retry contract.

  Keyless gate tests install a plug that flunks if a request is ever built,
  so a gate placed after key resolution fails even with a key exported.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.Gemini.Transcription

  doctest ALLM.Providers.Gemini.Transcription

  @clip "test/fixtures/audio/quick_brown_fox.mp3"
  @instruction "Generate a verbatim transcript of this audio. Output only the transcript."

  @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
  def flunk_plug(_conn), do: flunk("gate let the request reach HTTP")

  defp req(audio, opts \\ []),
    do: TranscriptionRequest.new(Keyword.merge([audio: audio], opts))

  defp mp3(bytes \\ "ID3fake"), do: Audio.from_binary(bytes, "audio/mpeg")

  defp parts(body), do: body |> Map.fetch!("contents") |> hd() |> Map.fetch!("parts")
  defp prompt_text(body), do: body |> parts() |> hd() |> Map.fetch!("text")
  defp inline(body), do: body |> parts() |> Enum.at(1) |> Map.fetch!("inlineData")

  defp candidate(parts, finish \\ "STOP") do
    %{
      "candidates" => [
        %{"content" => %{"role" => "model", "parts" => parts}, "finishReason" => finish}
      ]
    }
  end

  describe "max_audio_bytes/0" do
    test "is the raw size whose base64 plus 64 KiB of headroom fits a 20 MiB request" do
      assert Transcription.max_audio_bytes() == div((20 * 1024 * 1024 - 64 * 1024) * 3, 4)
      assert Transcription.max_audio_bytes() == 15_679_488
    end
  end

  describe "to_json_body/2" do
    test "instruction part first, then camelCase inlineData with mime and base64" do
      assert {:ok, body} = Transcription.to_json_body(req(mp3()), [])

      assert prompt_text(body) == @instruction
      assert inline(body) == %{"mimeType" => "audio/mpeg", "data" => Base.encode64("ID3fake")}
      assert [%{"role" => "user"}] = body["contents"]
      refute Map.has_key?(body, "generationConfig")
    end

    test "a {:file, path} source is read from disk and base64-encoded" do
      assert {:ok, body} = Transcription.to_json_body(req(Audio.from_file(@clip)), [])
      assert inline(body)["data"] == Base.encode64(File.read!(@clip))
    end

    test "language and prompt hints appear only when set, after the instruction" do
      assert {:ok, plain} = Transcription.to_json_body(req(mp3()), [])
      refute prompt_text(plain) =~ "language"
      refute prompt_text(plain) =~ "Kestrel"

      assert {:ok, body} =
               Transcription.to_json_body(req(mp3(), language: "fr", prompt: "Kestrel Ltd"), [])

      text = prompt_text(body)
      assert String.starts_with?(text, @instruction)
      assert text =~ ~s(language "fr")
      assert text =~ "Kestrel Ltd"
    end

    test "options are deep-merged into generationConfig, keys stringified" do
      options = %{:temperature => 0.1, "thinkingConfig" => %{"thinkingBudget" => 0}}
      assert {:ok, body} = Transcription.to_json_body(req(mp3(), options: options), [])

      assert body["generationConfig"] == %{
               "temperature" => 0.1,
               "thinkingConfig" => %{"thinkingBudget" => 0}
             }

      assert inline(body)["mimeType"] == "audio/mpeg"
    end

    test "an off-shape :options is ignored" do
      assert {:ok, body} = Transcription.to_json_body(%{req(mp3()) | options: :bad}, [])
      refute Map.has_key?(body, "generationConfig")
    end

    test "a parameterised or mixed-case mime is sent as its bare lowercase type" do
      audio = Audio.from_binary("RIFF", "Audio/WAV; codecs=1")
      assert {:ok, body} = Transcription.to_json_body(req(audio), [])
      assert inline(body)["mimeType"] == "audio/wav"
    end

    test "an .opus file is sent as audio/opus (no alias)" do
      audio = Audio.from_file("test/fixtures/audio/quick_brown_fox.opus")
      assert audio.mime_type == "audio/opus"
      assert {:ok, body} = Transcription.to_json_body(req(audio), [])
      assert inline(body)["mimeType"] == "audio/opus"
    end

    test "a nil mime returns the mime gate's error" do
      audio = %Audio{source: {:binary, "ID3"}, mime_type: nil}

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               Transcription.to_json_body(req(audio), [])

      assert meta.mime_type == nil
    end

    test "unresolvable audio returns an error tuple rather than raising" do
      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :enoent}}} =
               Transcription.to_json_body(req(Audio.from_file("/nonexistent.mp3")), [])

      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_source}}} =
               Transcription.to_json_body(req(nil), [])
    end
  end

  describe "gate_audio/2 and the gate order through transcribe/2 (keyless)" do
    test "a missing file is :invalid_request with metadata.cause" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               Transcription.transcribe(req(Audio.from_file("/nonexistent.mp3")), @flunk_plug)

      assert meta.cause == :enoent
      assert meta.field == :audio
    end

    test "a directory is :invalid_request with cause :eisdir" do
      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :eisdir}}} =
               Transcription.transcribe(req(Audio.from_file(System.tmp_dir!())), @flunk_plug)
    end

    test "invalid base64 is :invalid_request with cause :invalid_base64" do
      audio = Audio.from_base64("%%%", "audio/mpeg")

      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_base64}}} =
               Transcription.transcribe(req(audio), @flunk_plug)
    end

    test "an off-shape source or a non-Audio :audio is :invalid_source" do
      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_source}}} =
               Transcription.transcribe(req(%Audio{source: {:binary, 42}}), @flunk_plug)

      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_source}}} =
               Transcription.transcribe(req(nil), @flunk_plug)
    end

    test "oversized audio is :invalid_request with count and max, keyless" do
      max = Transcription.max_audio_bytes()
      audio = Audio.from_binary(:binary.copy(<<0>>, max + 1), "audio/mpeg")

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               Transcription.transcribe(req(audio), @flunk_plug)

      assert meta.count == max + 1
      assert meta.max == max
    end

    test "size is checked before the mime gate" do
      max = Transcription.max_audio_bytes()
      audio = Audio.from_binary(:binary.copy(<<0>>, max + 1), "audio/webm")

      assert {:error, %TranscriptionAdapterError{metadata: %{count: count}}} =
               Transcription.gate_audio(req(audio), [])

      assert count == max + 1
    end

    test "a nil mime is :invalid_request, keyless" do
      audio = %Audio{source: {:binary, "ID3"}, mime_type: nil}

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               Transcription.transcribe(req(audio), @flunk_plug)

      assert meta.field == :audio
      assert meta.mime_type == nil
    end

    # webm has no source clip, so the live probe never sent it; it stays
    # outside the accepted set.
    test "audio/webm is :invalid_request, keyless" do
      audio = Audio.from_binary("webm", "audio/webm")

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               Transcription.transcribe(req(audio), @flunk_plug)

      assert meta.mime_type == "audio/webm"
    end

    # A browser or ffmpeg-reported mime carries parameters; an exact-match
    # gate would refuse a format Gemini accepts.
    test "parameterised and mixed-case mimes pass the mime gate, keyless" do
      for mime <- ["audio/ogg; codecs=vorbis", "audio/mpeg; charset=binary", "Audio/FLAC"] do
        assert :ok = Transcription.gate_audio(req(Audio.from_binary("x", mime)), [])
      end
    end

    # Probed 2026-09-24: every clip below was transcribed correctly, the
    # Ogg-encapsulated opus clip under both `audio/opus` and `audio/ogg`.
    test "every clip format the recorder probed passes the gate" do
      for ext <- ~w(mp3 wav flac aac opus) do
        audio = Audio.from_file("test/fixtures/audio/quick_brown_fox.#{ext}")
        assert :ok = Transcription.gate_audio(req(audio), [])
      end
    end
  end

  describe "decode_response/4" do
    test "text parts are concatenated; usage maps thoughtsTokenCount to reasoning_tokens" do
      body =
        candidate([%{"text" => "The quick "}, %{"text" => "brown fox."}])
        |> Map.put("usageMetadata", %{
          "promptTokenCount" => 120,
          "candidatesTokenCount" => 9,
          "thoughtsTokenCount" => 40,
          "totalTokenCount" => 169
        })
        |> Map.put("responseId", "resp_1")

      assert {:ok, %TranscriptionResponse{} = resp} =
               Transcription.decode_response(body, %{}, req(mp3(), metadata: %{"k" => 1}), [])

      assert resp.text == "The quick brown fox."
      assert resp.usage.input_tokens == 120
      assert resp.usage.output_tokens == 9
      assert resp.usage.reasoning_tokens == 40
      assert resp.usage.total_tokens == 169
      assert resp.id == "resp_1"
      assert resp.provider == :gemini
      assert resp.model == "gemini-flash-latest"
      assert resp.raw == body
      assert resp.metadata == %{"k" => 1}
      assert resp.request_id == nil
    end

    test "a part marked thought: true is excluded; a thoughtSignature part is kept" do
      body =
        candidate([
          %{"text" => "Let me think about the audio.", "thought" => true},
          %{"text" => "hello", "thoughtSignature" => "c2ln"}
        ])

      assert {:ok, %{text: "hello"}} = Transcription.decode_response(body, %{}, req(mp3()), [])
    end

    test "MAX_TOKENS returns the partial text with metadata.finish_reason :length" do
      body = candidate([%{"text" => "The quick"}], "MAX_TOKENS")

      assert {:ok, resp} =
               Transcription.decode_response(body, %{}, req(mp3(), metadata: %{"k" => 1}), [])

      assert resp.text == "The quick"
      assert resp.metadata == %{"k" => 1, finish_reason: :length}
      assert resp.raw == body
    end

    test "SAFETY and RECITATION are :content_filter" do
      for finish <- ["SAFETY", "RECITATION"] do
        body = %{"candidates" => [%{"finishReason" => finish}]}

        assert {:error, %TranscriptionAdapterError{reason: :content_filter} = err} =
                 Transcription.decode_response(body, %{}, req(mp3()), [])

        assert err.metadata.finish_reason == finish
      end
    end

    test "an empty candidate list with promptFeedback.blockReason is :content_filter" do
      body = %{"candidates" => [], "promptFeedback" => %{"blockReason" => "OTHER"}}

      assert {:error, %TranscriptionAdapterError{reason: :content_filter} = err} =
               Transcription.decode_response(body, %{}, req(mp3()), [])

      assert err.metadata.block_reason == "OTHER"

      assert {:error, %TranscriptionAdapterError{reason: :content_filter}} =
               Transcription.decode_response(
                 Map.delete(body, "candidates"),
                 %{},
                 req(mp3()),
                 []
               )
    end

    test "a candidate with no parts decodes to empty text (silence)" do
      body = %{"candidates" => [%{"content" => %{"role" => "model"}, "finishReason" => "STOP"}]}
      assert {:ok, %{text: ""}} = Transcription.decode_response(body, %{}, req(mp3()), [])
    end

    test "request_id comes only from opts; the request model wins over the default" do
      body = candidate([%{"text" => "x"}])

      assert {:ok, %{request_id: "mine", model: "gemini-2.5-flash"}} =
               Transcription.decode_response(
                 body,
                 %{},
                 req(mp3(), model: "gemini-2.5-flash"),
                 request_id: "mine"
               )
    end

    test "no candidates and no block reason, or a non-map body, is :malformed_response" do
      for body <- [%{"candidates" => []}, %{}, %{"candidates" => ["x"]}, "plain text"] do
        assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
                 Transcription.decode_response(body, %{}, req(mp3()), [])
      end
    end

    test "missing usageMetadata and non-integer counts decode to an empty Usage" do
      assert {:ok, %{usage: %Usage{input_tokens: nil}}} =
               Transcription.decode_response(candidate([%{"text" => "x"}]), %{}, req(mp3()), [])

      body = Map.put(candidate([%{"text" => "x"}]), "usageMetadata", %{"promptTokenCount" => "7"})

      assert {:ok, %{usage: %Usage{input_tokens: nil}}} =
               Transcription.decode_response(body, %{}, req(mp3()), [])
    end
  end

  describe "to_transcription_adapter_error/4" do
    defp err(status, body, headers \\ %{}),
      do: Transcription.to_transcription_adapter_error(status, body, headers, [])

    defp google(status_text, message, details \\ []) do
      %{"error" => %{"status" => status_text, "message" => message, "details" => details}}
    end

    test "status mapping" do
      assert err(401, %{}).reason == :authentication_failed
      assert err(403, %{}).reason == :authentication_failed
      assert err(400, %{}).reason == :invalid_request
      assert err(404, %{}).reason == :invalid_request
      assert err(500, %{}).reason == :provider_unavailable
      assert err(503, %{}).reason == :provider_unavailable
      assert err(418, %{}).reason == :unknown
    end

    test "a 400 whose details carry reason API_KEY_INVALID is :authentication_failed" do
      body =
        google("INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.", [
          %{"@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => "API_KEY_INVALID"}
        ])

      e = err(400, body)
      assert e.reason == :authentication_failed
      assert e.status == 400
    end

    test "a 400 exceeding the token window is :context_length_exceeded" do
      body =
        google(
          "INVALID_ARGUMENT",
          "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."
        )

      assert err(400, body).reason == :context_length_exceeded
    end

    test "429 honours Retry-After" do
      e = err(429, %{}, %{"retry-after" => ["3"]})
      assert {e.reason, e.retry_after_ms} == {:rate_limited, 3_000}
    end

    test "a binary JSON body is decoded; a non-map error value does not raise" do
      assert err(400, ~s({"error":{"message":"bad audio"}})).message == "bad audio"
      assert err(500, %{"error" => "boom"}).message == "boom"
      assert err(500, %{"error" => [1]}).message == "Gemini HTTP 500"
      assert err(500, "<html>").message == "Gemini HTTP 500"
      assert err(500, [1, 2]).message == "Gemini HTTP 500"
    end

    test "provider-authored message and status are both redacted" do
      planted = "AIzaPLANTED000111222333444555"
      e = err(400, google(planted, "key " <> planted <> " rejected"))

      refute inspect(e) =~ planted
      refute Jason.encode!(e) =~ planted
      assert e.message =~ "[REDACTED]"
      assert e.metadata.google_status == "[REDACTED]"
    end

    test "opts[:request_id] lands on error metadata" do
      e = Transcription.to_transcription_adapter_error(500, %{}, %{}, request_id: "r1")
      assert e.metadata.request_id == "r1"
      assert e.metadata.status == 500
    end
  end

  describe "no adapter-level retry" do
    setup do
      {:ok, stub: String.to_atom("gemini_stt_retry_#{System.unique_integer([:positive])}")}
    end

    for {status, reason} <- [{429, :rate_limited}, {503, :provider_unavailable}] do
      test "a #{status} is attempted exactly once, even under a permissive policy", %{stub: stub} do
        parent = self()

        Req.Test.stub(stub, fn conn ->
          send(parent, :attempt)
          Req.Test.json(Plug.Conn.put_status(conn, unquote(status)), %{"error" => %{}})
        end)

        # Falsifier: an adapter wrapping its attempt in Retry.run/3 would make
        # 3 calls under this policy.
        assert {:error, %TranscriptionAdapterError{reason: unquote(reason)}} =
                 Transcription.transcribe(req(mp3()),
                   api_key: "AIza-test",
                   retry: [
                     max_attempts: 3,
                     base_delay_ms: 0,
                     jitter_ms: 0,
                     retry_on: [unquote(reason)]
                   ],
                   adapter_opts: [plug: {Req.Test, stub}]
                 )

        assert_received :attempt
        refute_received :attempt
      end
    end

    test "a transport timeout is returned once as :timeout", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %TranscriptionAdapterError{reason: :timeout}} =
               Transcription.transcribe(req(mp3()),
                 api_key: "AIza-test",
                 request_timeout: 50,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received :attempt
      refute_received :attempt
    end
  end

  describe "prepare_request/2" do
    test "targets models/<model>:generateContent with the x-goog-api-key header" do
      assert {:ok, http} =
               Transcription.prepare_request(req(mp3(), model: "models/gemini-2.5-flash"),
                 api_key: "AIza-x"
               )

      assert URI.to_string(http.url) ==
               "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

      assert http.headers["x-goog-api-key"] == ["AIza-x"]
    end

    test "applies the 120 s default receive timeout, or opts[:request_timeout]" do
      assert {:ok, http} = Transcription.prepare_request(req(mp3()), api_key: "AIza-x")
      assert http.options[:receive_timeout] == 120_000

      assert {:ok, http} =
               Transcription.prepare_request(req(mp3()), api_key: "AIza-x", request_timeout: 5)

      assert http.options[:receive_timeout] == 5
    end

    test "honours adapter_opts[:endpoint]" do
      assert {:ok, http} =
               Transcription.prepare_request(req(mp3()),
                 api_key: "AIza-x",
                 adapter_opts: [endpoint: "http://proxy.local/v1beta"]
               )

      assert URI.to_string(http.url) ==
               "http://proxy.local/v1beta/models/gemini-flash-latest:generateContent"
    end

    test "runs the gates first, keyless" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               Transcription.prepare_request(req(Audio.from_file("/nope.mp3")), @flunk_plug)
    end

    test "under a transcription_script it returns a stub error" do
      assert {:error, %TranscriptionAdapterError{reason: :unknown}} =
               Transcription.prepare_request(req(mp3()),
                 adapter_opts: [transcription_script: [{:ok, "x"}]]
               )
    end
  end

  describe "script hand-off" do
    # Falsifier: without the real cap passed as adapter_opts[:max_audio_bytes],
    # FakeTranscription's 1024-byte default rejects this multi-KB clip.
    test "a scripted call with the real quick_brown_fox.mp3 clip returns the script" do
      assert File.stat!(@clip).size > 4096

      assert {:ok, %TranscriptionResponse{text: "scripted"}} =
               Transcription.transcribe(req(Audio.from_file(@clip)),
                 adapter_opts: [transcription_script: [{:ok, "scripted"}]]
               )
    end

    test "the hand-off passes this adapter's own cap as adapter_opts[:max_audio_bytes]" do
      assert {:ok, _} =
               Transcription.transcribe(req(mp3()),
                 adapter_opts: [transcription_script: [{:ok, "x"}], capture_pid: self()]
               )

      assert_received {ALLM.Providers.FakeTranscription, :call, %{opts: opts}}
      assert opts[:adapter_opts][:max_audio_bytes] == Transcription.max_audio_bytes()
    end
  end
end
