defmodule ALLM.Providers.ElevenLabs.TranscriptionTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.ElevenLabs.Transcription`: the multipart
  body, the keyless gates, the decoder, and the single-attempt rule. The
  gate tests install a plug that fails the test if a request is ever sent.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.ElevenLabs.Transcription
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures

  doctest ALLM.Providers.ElevenLabs.Transcription

  @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
  def flunk_plug(_conn), do: flunk("gate let the request reach HTTP")

  defp mp3, do: Audio.from_binary("ID3-bytes", "audio/mpeg")
  defp req(opts \\ []), do: TranscriptionRequest.new(Keyword.merge([audio: mp3()], opts))

  # A file of `size` bytes whose data blocks are never written.
  defp sparse_file(path, size) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:write, :raw, :binary])
    :ok = :file.pwrite(fd, size - 1, <<0>>)
    :ok = :file.close(fd)
    path
  end

  describe "to_multipart_body/2" do
    test "carries file and model_id, and no language_code when unset" do
      assert {:ok, fields} = Transcription.to_multipart_body(req(), [])

      assert [{"file", {"ID3-bytes", file_opts}}, {"model_id", "scribe_v2"}] = fields
      assert file_opts[:filename] == "audio.mp3"
      assert file_opts[:content_type] == "audio/mpeg"
    end

    test "language_code is sent when set, and the model when given" do
      assert {:ok, fields} =
               Transcription.to_multipart_body(req(language: "en", model: "scribe_v1"), [])

      assert {"language_code", "en"} in fields
      assert {"model_id", "scribe_v1"} in fields
    end

    test "options become extra fields under the structural ones" do
      log =
        capture_log([level: :debug], fn ->
          assert {:ok, fields} =
                   Transcription.to_multipart_body(
                     req(options: %{"diarize" => true, "model_id" => "x", tag: ["a", "b"]}),
                     []
                   )

          assert {"diarize", "true"} in fields
          assert {"tag", "a"} in fields and {"tag", "b"} in fields
          assert Enum.count(fields, &match?({"model_id", _}, &1)) == 1
          assert {"model_id", "scribe_v2"} in fields
        end)

      assert log =~ "dropping option"
    end

    test "a file source is named by its basename" do
      path = Path.expand("test/fixtures/audio/quick_brown_fox.mp3")

      assert {:ok, [{"file", {_bytes, file_opts}} | _]} =
               Transcription.to_multipart_body(req(audio: Audio.from_file(path)), [])

      assert file_opts[:filename] == "quick_brown_fox.mp3"
    end

    test "an unknown mime is sent as audio.bin (ElevenLabs reads the content)" do
      audio = Audio.from_binary("bytes", "application/x-unknown")

      assert {:ok, [{"file", {_, file_opts}} | _]} =
               Transcription.to_multipart_body(req(audio: audio), [])

      assert file_opts[:filename] == "audio.bin"
    end

    test "a non-Audio source is :invalid_request" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               Transcription.to_multipart_body(%TranscriptionRequest{audio: "raw"}, [])
    end
  end

  describe "pre-flight gates (keyless, before Keys.fetch!/2)" do
    test "prompt -> :unsupported_feature" do
      assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature} = err} =
               Transcription.transcribe(req(prompt: "x"), @flunk_plug)

      assert err.metadata.field == :prompt
      assert err.provider == :elevenlabs
    end

    test "unresolvable audio -> :invalid_request" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               Transcription.transcribe(
                 req(audio: Audio.from_file("/nonexistent.mp3")),
                 @flunk_plug
               )

      assert err.metadata.cause == :enoent
    end

    # The conformance suite's case 4 is skipped for this adapter (owner
    # decision 2026-09-27: its clip would be 5 GB of memory), so the size
    # gate is bound here. A sparse file reports its full length to
    # `File.stat/1` without allocating it, and the gate never reads it.
    @tag :tmp_dir
    test "audio over max_audio_bytes/0 -> :invalid_request with count and max; at the cap passes",
         %{tmp_dir: dir} do
      max = Transcription.max_audio_bytes()
      over = sparse_file(Path.join(dir, "over.mp3"), max + 1)
      at_cap = sparse_file(Path.join(dir, "at_cap.mp3"), max)

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               Transcription.transcribe(req(audio: Audio.from_file(over)), @flunk_plug)

      assert err.metadata.field == :audio
      assert err.metadata.count == max + 1
      assert err.metadata.max == max

      assert :ok = Transcription.gate_audio(req(audio: Audio.from_file(at_cap)), [])
    end

    test "an unknown mime is NOT gated (no filename gate)" do
      audio = Audio.from_binary("bytes", "application/x-unknown")
      assert {:ok, _http} = Transcription.prepare_request(req(audio: audio), api_key: "sk_x")
    end

    test "prepare_request/2 runs the same gates and stubs under a script" do
      assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature}} =
               Transcription.prepare_request(req(prompt: "x"), [])

      assert {:error, %TranscriptionAdapterError{reason: :unknown}} =
               Transcription.prepare_request(req(),
                 adapter_opts: [transcription_script: [{:ok, "x"}]]
               )
    end

    test "prepare_request/2 sends xi-api-key and a 120 s timeout" do
      assert {:ok, http} = Transcription.prepare_request(req(), api_key: "sk_x")
      assert Req.Request.get_header(http, "xi-api-key") == ["sk_x"]
      assert http.options.receive_timeout == 120_000
    end
  end

  describe "decode_response/4" do
    test "maps text, language, duration and id; usage is all-nil" do
      body = %{
        "text" => "hi",
        "language_code" => "eng",
        "audio_duration_secs" => 3.72,
        "transcription_id" => "t1",
        "words" => []
      }

      assert {:ok, %TranscriptionResponse{} = resp} =
               Transcription.decode_response(body, %{}, req(metadata: %{k: 1}), request_id: "r1")

      assert resp.text == "hi"
      assert resp.language == "eng"
      assert resp.duration_seconds == 3.72
      assert resp.id == "t1"
      assert resp.request_id == "r1"
      assert resp.model == "scribe_v2"
      assert resp.provider == :elevenlabs
      assert resp.usage == %Usage{}
      assert resp.raw == body
      assert resp.metadata == %{k: 1}
    end

    test "absent optional fields decode to nil" do
      assert {:ok, %TranscriptionResponse{language: nil, duration_seconds: nil, id: nil}} =
               Transcription.decode_response(%{"text" => ""}, %{}, req(), [])
    end

    test "missing text is :malformed_response" do
      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} =
               Transcription.decode_response(%{"language_code" => "eng"}, %{}, req(), [])
    end
  end

  describe "one attempt, no retry" do
    setup do
      {:ok, stub: String.to_atom("elevenlabs_stt_once_#{System.unique_integer([:positive])}")}
    end

    test "a 429 is hit once and returned", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        Fixtures.replay(conn, Fixtures.transcription_synthesized(:error_429))
      end)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 3_000}} =
               Transcription.transcribe(req(),
                 api_key: "sk_test",
                 retry: [max_attempts: 3, base_delay_ms: 0, jitter_ms: 0, retry_on: [:rate_limited]],
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received :attempt
      refute_received :attempt
    end
  end
end
