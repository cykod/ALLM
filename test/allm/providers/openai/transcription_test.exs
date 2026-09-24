defmodule ALLM.Providers.OpenAI.TranscriptionTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.OpenAI.Transcription`: gates, multipart body
  builder, response decoder, error classifier, and the no-retry contract.

  Keyless gate tests install a plug that flunks if a request is ever built,
  so a gate placed after key resolution fails even with a key exported.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.OpenAI.Transcription
  alias ALLM.Providers.OpenAITestFixtures, as: Fixtures

  doctest ALLM.Providers.OpenAI.Transcription

  @clip "test/fixtures/audio/quick_brown_fox.mp3"

  @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
  def flunk_plug(_conn), do: flunk("gate let the request reach HTTP")

  defp req(audio, opts \\ []),
    do: TranscriptionRequest.new(Keyword.merge([audio: audio], opts))

  defp mp3(bytes \\ "ID3fake"), do: Audio.from_binary(bytes, "audio/mpeg")

  defp field(form, name), do: for({^name, v} <- form, do: v)

  describe "max_audio_bytes/0" do
    # Settled by the recorder's size ladder on 2026-09-24: 25 MiB - 64 KiB was
    # accepted, 25 MiB + 1 was a 413 on the whole multipart body.
    test "is the largest accepted ladder rung, 25 MiB - 64 KiB" do
      assert Transcription.max_audio_bytes() == 25 * 1024 * 1024 - 64 * 1024

      ladder = Fixtures.transcription_recorded(:probe_size_ladder)
      assert ladder["max_accepted_bytes"] == Transcription.max_audio_bytes()
    end
  end

  describe "to_multipart_body/2" do
    test "binary audio: file tuple, model default, response_format json" do
      assert {:ok, form} = Transcription.to_multipart_body(req(mp3()), [])

      assert field(form, "file") == [
               {"ID3fake", filename: "audio.mp3", content_type: "audio/mpeg"}
             ]

      assert field(form, "model") == ["gpt-transcribe"]
      assert field(form, "response_format") == ["json"]
      assert field(form, "language") == []
      assert field(form, "prompt") == []
    end

    test "a {:file, path} source is named by its basename and read from disk" do
      assert {:ok, form} = Transcription.to_multipart_body(req(Audio.from_file(@clip)), [])
      [{bytes, filename: name, content_type: ct}] = field(form, "file")

      assert name == "quick_brown_fox.mp3"
      assert ct == "audio/mpeg"
      assert bytes == File.read!(@clip)
    end

    test "a {:file, path} with an unknown extension is sent as application/octet-stream" do
      path = Path.join(System.tmp_dir!(), "allm_stt_#{System.unique_integer([:positive])}.xyz")
      File.write!(path, "abc")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, form} = Transcription.to_multipart_body(req(Audio.from_file(path)), [])

      assert [{"abc", filename: name, content_type: "application/octet-stream"}] =
               field(form, "file")

      assert name == Path.basename(path)
    end

    test "base64 and other mimes derive the extension from the mime" do
      audio = Audio.from_base64(Base.encode64("RIFF"), "audio/wav")
      assert {:ok, form} = Transcription.to_multipart_body(req(audio), [])
      assert [{"RIFF", filename: "audio.wav", content_type: "audio/wav"}] = field(form, "file")
    end

    test "model, language and prompt are sent when set" do
      assert {:ok, form} =
               Transcription.to_multipart_body(
                 req(mp3(), model: "whisper-1", language: "en", prompt: "names: Kestrel"),
                 []
               )

      assert field(form, "model") == ["whisper-1"]
      assert field(form, "language") == ["en"]
      assert field(form, "prompt") == ["names: Kestrel"]
    end

    test "options become extra form fields, stringified, lists repeated" do
      options = %{"temperature" => 0.2, :include => ["logprobs"], "chunking_strategy" => "auto"}
      assert {:ok, form} = Transcription.to_multipart_body(req(mp3(), options: options), [])

      assert field(form, "temperature") == ["0.2"]
      assert field(form, "include") == ["logprobs"]
      assert field(form, "chunking_strategy") == ["auto"]
    end

    test "options never override a structural field" do
      options = %{"model" => "x", "file" => "y", "language" => "fr"}
      assert {:ok, form} = Transcription.to_multipart_body(req(mp3(), options: options), [])

      assert field(form, "model") == ["gpt-transcribe"]
      assert length(field(form, "file")) == 1
      assert field(form, "language") == []
    end

    test "response_format in options is reserved and dropped; json is still sent" do
      assert {:ok, form} =
               Transcription.to_multipart_body(
                 req(mp3(), options: %{"response_format" => "srt"}),
                 []
               )

      assert field(form, "response_format") == ["json"]
    end

    test "a map option value is JSON-encoded" do
      assert {:ok, form} =
               Transcription.to_multipart_body(req(mp3(), options: %{"x" => %{"a" => 1}}), [])

      assert field(form, "x") == [~s({"a":1})]
    end

    test "unresolvable audio returns an error tuple rather than raising" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               Transcription.to_multipart_body(req(Audio.from_file("/nonexistent.mp3")), [])
    end

    # The seam shares the gate's filename helper, so it never builds the
    # `audio.bin` part the 2026-09-24 probe saw OpenAI reject.
    test "a non-file mime with no extension returns the filename gate's error" do
      for mime <- [nil, "audio/x-unknown"] do
        audio = %Audio{source: {:binary, "ID3"}, mime_type: mime}

        assert {:error, %TranscriptionAdapterError{metadata: %{mime_type: ^mime}}} =
                 Transcription.to_multipart_body(req(audio), [])
      end
    end

    test "a parameterised or mixed-case mime is named by its bare type, sent verbatim" do
      audio = Audio.from_binary("OggS", "Audio/WebM; codecs=opus")
      assert {:ok, form} = Transcription.to_multipart_body(req(audio), [])

      assert [{"OggS", filename: "audio.webm", content_type: "Audio/WebM; codecs=opus"}] =
               field(form, "file")
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

    test "size is checked before the filename gate" do
      max = Transcription.max_audio_bytes()
      audio = Audio.from_binary(:binary.copy(<<0>>, max + 1), "application/x-unknown")

      assert {:error, %TranscriptionAdapterError{metadata: %{count: count}}} =
               Transcription.gate_audio(req(audio), [])

      assert count == max + 1
    end

    # The 2026-09-24 probe sent valid mp3 bytes named `audio.bin` and got 400
    # "Unsupported file format bin": OpenAI trusts the filename extension, so
    # a filename the adapter cannot derive is rejected locally instead.
    test "a non-file source with a nil or unknown mime is :invalid_request, keyless" do
      for mime <- [nil, "audio/x-unknown"] do
        audio = %Audio{source: {:binary, "ID3"}, mime_type: mime}

        assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
                 Transcription.transcribe(req(audio), @flunk_plug)

        assert meta.field == :audio
        assert meta.mime_type == mime
      end
    end

    # `MediaRecorder` blobs report `audio/webm;codecs=opus`; an exact-match
    # gate refused them locally although OpenAI accepts the format.
    test "parameterised and mixed-case mimes pass the filename gate, keyless" do
      for mime <- ["audio/webm;codecs=opus", "audio/mpeg; charset=binary", "Audio/MPEG"] do
        audio = Audio.from_binary("ID3", mime)
        assert :ok = Transcription.gate_audio(req(audio), [])
      end
    end

    test "a valid clip passes every gate" do
      assert :ok = Transcription.gate_audio(req(Audio.from_file(@clip)), [])
    end
  end

  describe "decode_response/4" do
    test "duration usage fills duration_seconds and leaves Usage empty" do
      body = %{"text" => "hi", "usage" => %{"type" => "duration", "seconds" => 3}}

      assert {:ok, %TranscriptionResponse{} = resp} =
               Transcription.decode_response(body, %{}, req(mp3(), metadata: %{"k" => 1}), [])

      assert resp.duration_seconds == 3
      assert resp.usage == %Usage{}
      assert resp.usage.input_tokens == nil
      assert resp.text == "hi"
      assert resp.raw == body
      assert resp.provider == :openai
      assert resp.model == "gpt-transcribe"
      assert resp.metadata == %{"k" => 1}
    end

    test "token usage fills Usage and leaves duration_seconds nil" do
      body = %{
        "text" => "hi",
        "usage" => %{
          "type" => "tokens",
          "input_tokens" => 27,
          "output_tokens" => 12,
          "total_tokens" => 39
        }
      }

      assert {:ok, resp} = Transcription.decode_response(body, %{}, req(mp3()), [])
      assert resp.usage.input_tokens == 27
      assert resp.usage.output_tokens == 12
      assert resp.usage.total_tokens == 39
      assert resp.duration_seconds == nil
    end

    test "languages[0].code becomes :language" do
      body = %{"text" => "hi", "languages" => [%{"code" => "en"}]}
      assert {:ok, %{language: "en"}} = Transcription.decode_response(body, %{}, req(mp3()), [])
    end

    test "no usage and no languages decode to defaults" do
      assert {:ok, %{language: nil, usage: %Usage{}, duration_seconds: nil, text: ""}} =
               Transcription.decode_response(%{"text" => ""}, %{}, req(mp3()), [])
    end

    test "request_id: opts win, else x-request-id" do
      headers = %{"x-request-id" => ["req_1"]}
      body = %{"text" => "x"}

      assert {:ok, %{request_id: "req_1"}} =
               Transcription.decode_response(body, headers, req(mp3()), [])

      assert {:ok, %{request_id: "mine"}} =
               Transcription.decode_response(body, headers, req(mp3()), request_id: "mine")
    end

    test "a missing or non-binary text is :malformed_response" do
      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
               Transcription.decode_response(%{"usage" => %{}}, %{}, req(mp3()), [])

      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
               Transcription.decode_response(%{"text" => 5}, %{}, req(mp3()), [])

      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
               Transcription.decode_response("plain text", %{}, req(mp3()), [])
    end
  end

  describe "to_transcription_adapter_error/4" do
    defp err(status, body, headers \\ %{}),
      do: Transcription.to_transcription_adapter_error(status, body, headers, [])

    test "status mapping" do
      assert err(401, %{}).reason == :authentication_failed
      assert err(403, %{}).reason == :authentication_failed
      assert err(400, %{}).reason == :invalid_request
      assert err(404, %{}).reason == :invalid_request
      assert err(413, %{}).reason == :invalid_request
      assert err(500, %{}).reason == :provider_unavailable
      assert err(418, %{}).reason == :unknown
    end

    test "the recorded 413 (type server_error) maps by status to :invalid_request" do
      env = Fixtures.transcription_recorded(:error_413)
      e = err(env["status"], env["body"])

      assert e.reason == :invalid_request
      assert e.message =~ "Maximum content size limit"
    end

    test "429 honours Retry-After" do
      e = err(429, %{}, %{"retry-after" => ["3"]})
      assert {e.reason, e.retry_after_ms} == {:rate_limited, 3_000}
    end

    test "a text/plain binary 401 keeps its message" do
      e = err(401, ~s({"error":{"message":"Incorrect API key provided"}}))
      assert e.message == "Incorrect API key provided"
    end

    test "a non-map \"error\" value does not raise" do
      assert err(500, %{"error" => "boom"}).message == "boom"
      assert err(500, %{"error" => [1]}).message == "OpenAI HTTP 500"
    end

    test "provider-authored message, code and type are all redacted" do
      planted = "sk-proj-PLANTED000111222333444"
      e = err(400, %{"error" => %{"message" => planted, "code" => planted, "type" => planted}})

      refute Jason.encode!(e) =~ planted
      assert e.metadata.openai_code == "[REDACTED]"
      assert e.metadata.openai_type == "[REDACTED]"
    end
  end

  describe "no adapter-level retry" do
    setup do
      {:ok, stub: String.to_atom("openai_stt_retry_#{System.unique_integer([:positive])}")}
    end

    for {status, reason} <- [{429, :rate_limited}, {500, :provider_unavailable}] do
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
                   api_key: "sk-test",
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
                 api_key: "sk-test",
                 request_timeout: 50,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received :attempt
      refute_received :attempt
    end
  end

  describe "prepare_request/2" do
    test "applies the 120 s default receive timeout" do
      assert {:ok, http} = Transcription.prepare_request(req(mp3()), api_key: "sk-x")
      assert http.options[:receive_timeout] == 120_000
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

  describe "defensive edges at the public seams" do
    test "list-shaped headers, a bare-string value, and an unparseable Retry-After" do
      headers = [{"X-Request-Id", "req_list"}, {:junk, "x"}, {"retry-after", "soon"}]

      assert {:ok, %{request_id: "req_list"}} =
               Transcription.decode_response(%{"text" => "x"}, headers, req(mp3()), [])

      assert Transcription.to_transcription_adapter_error(429, %{}, headers, []).retry_after_ms ==
               nil

      assert {:ok, %{request_id: nil}} =
               Transcription.decode_response(%{"text" => "x"}, :not_headers, req(mp3()), [])

      assert {:ok, %{request_id: "bare"}} =
               Transcription.decode_response(
                 %{"text" => "x"},
                 %{"x-request-id" => "bare"},
                 req(mp3()),
                 []
               )
    end

    test "non-JSON, non-map and list error bodies fall back to the generic message" do
      assert Transcription.to_transcription_adapter_error(500, "<html>", %{}, []).message ==
               "OpenAI HTTP 500"

      assert Transcription.to_transcription_adapter_error(500, [1, 2], %{}, []).message ==
               "OpenAI HTTP 500"
    end

    test "opts[:request_id] lands on error metadata" do
      e = Transcription.to_transcription_adapter_error(500, %{}, %{}, request_id: "r1")
      assert e.metadata.request_id == "r1"
    end

    test "non-integer token counts decode to nil" do
      body = %{"text" => "x", "usage" => %{"type" => "tokens", "input_tokens" => "27"}}

      assert {:ok, %{usage: %Usage{input_tokens: nil}}} =
               Transcription.decode_response(body, %{}, req(mp3()), [])
    end

    test "nil option values are skipped and off-shape options are ignored" do
      assert {:ok, form} = Transcription.to_multipart_body(req(mp3(), options: %{"x" => nil}), [])
      assert field(form, "x") == []

      assert {:ok, form} = Transcription.to_multipart_body(%{req(mp3()) | options: :bad}, [])
      assert field(form, "model") == ["gpt-transcribe"]
    end

    test "to_multipart_body/2 on a non-Audio :audio returns :invalid_source" do
      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_source}}} =
               Transcription.to_multipart_body(req(nil), [])
    end
  end
end
