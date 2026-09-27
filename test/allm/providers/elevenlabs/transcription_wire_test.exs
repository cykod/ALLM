defmodule ALLM.Providers.ElevenLabs.TranscriptionWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.ElevenLabs.Transcription`, driven
  end-to-end through `transcribe/2` behind a `Req.Test` stub.

  **Provenance.** `recorded/` holds live responses written by
  `scripts/record_elevenlabs_audio_fixtures.exs` on 2026-09-26 and none
  carries a `_comment` marker; `synthesized/` files each carry one. Both
  halves are gated below by raw-byte reads.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.ElevenLabs.Transcription
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures

  @fox Path.expand("test/fixtures/audio/quick_brown_fox.mp3")

  setup do
    {:ok, stub: String.to_atom("elevenlabs_stt_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []),
    do: TranscriptionRequest.new(Keyword.merge([audio: Audio.from_file(@fox)], opts))

  defp call(stub, request, opts \\ []) do
    Transcription.transcribe(
      request,
      Keyword.merge([api_key: "sk_wiretest", adapter_opts: [plug: {Req.Test, stub}]], opts)
    )
  end

  defp stub_env(stub, env), do: Req.Test.stub(stub, &Fixtures.replay(&1, env))

  describe "fixture provenance" do
    @recorded ~w(probe_control scribe_v2 probe_audio_bin error_400_bad_key)
    @synthesized ~w(error_401 error_429)

    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(Fixtures.raw("transcriptions/recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`"
      end
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert Fixtures.raw("transcriptions/synthesized", unquote(name))["_comment"] =~
                 "Synthesized (Phase 26.6)"
      end
    end

    test "@recorded enumerates every file under recorded/" do
      assert Fixtures.names_on_disk("transcriptions/recorded") == Enum.sort(@recorded)
    end

    test "@synthesized enumerates every file under synthesized/" do
      assert Fixtures.names_on_disk("transcriptions/synthesized") == Enum.sort(@synthesized)
    end
  end

  describe "request shape" do
    test "POSTs multipart to /v1/speech-to-text with the xi-api-key header", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "xi-api-key"),
           Plug.Conn.get_req_header(conn, "content-type"), raw}
        )

        Fixtures.replay(conn, Fixtures.transcription_recorded(:scribe_v2))
      end)

      assert {:ok, _} = call(stub, req(language: "en"))

      assert_received {:req, "POST", "api.elevenlabs.io", "/v1/speech-to-text", ["sk_wiretest"],
                       [ct], raw}

      assert ct =~ "multipart/form-data"
      assert raw =~ ~s(name="file"; filename="quick_brown_fox.mp3")
      assert raw =~ ~s(name="model_id") <> "\r\n\r\nscribe_v2"
      assert raw =~ ~s(name="language_code") <> "\r\n\r\nen"
      refute raw =~ ~s(name="prompt")
    end
  end

  describe "recorded bodies" do
    test "scribe_v2.json decodes the fox transcript", %{stub: stub} do
      env = Fixtures.transcription_recorded(:scribe_v2)
      stub_env(stub, env)

      assert {:ok, %TranscriptionResponse{} = resp} = call(stub, req(), request_id: "r1")
      assert resp.text == "The quick brown fox jumps over the lazy dog."
      assert resp.language == "eng"
      assert resp.duration_seconds == env["body"]["audio_duration_secs"]
      assert resp.id == env["body"]["transcription_id"]
      assert resp.request_id == "r1"
      assert resp.raw == env["body"]
    end

    test "the recorded response carries no request-id header" do
      refute "request-id" in Fixtures.transcription_recorded(:scribe_v2)["header_names"]
    end

    test "error_400_bad_key.json (a 400) is :authentication_failed", %{stub: stub} do
      stub_env(stub, Fixtures.transcription_recorded(:error_400_bad_key))

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed, status: 400}} =
               call(stub, req())
    end

    test "the probes: unknown fields ignored, a mp3 named audio.bin accepted" do
      assert Fixtures.transcription_recorded(:probe_control)["status"] == 200
      # Re-recorded 2026-09-27 as a body envelope: the adapter's no-filename-
      # gate choice rests on this upload being transcribed, not merely accepted.
      audio_bin = Fixtures.transcription_recorded(:probe_audio_bin)
      assert audio_bin["status"] == 200
      assert audio_bin["body"]["text"] =~ ~r/fox/i
    end
  end

  describe "redaction" do
    @planted "sk_FAKEKEY0123456789abcdef0123456789abcdef"

    test "the planted sk_ token in synthesized/error_401.json is redacted", %{stub: stub} do
      env = Fixtures.transcription_synthesized(:error_401)
      assert env["body"]["detail"]["message"] =~ @planted, "fixture must carry a key-shaped token"
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      refute inspect(err) =~ @planted
      refute Jason.encode!(err) =~ @planted
      assert err.message =~ "[REDACTED]"
    end

    test "the OpenAI, Gemini and Voyage key patterns match nothing in the same fixture" do
      message = Fixtures.transcription_synthesized(:error_401)["body"]["detail"]["message"]

      refute message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
      refute message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\bsk_[A-Za-z0-9]{16,}/
    end
  end

  describe "transport failures" do
    test "a timeout converts to :timeout", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %TranscriptionAdapterError{reason: :timeout}} =
               call(stub, req(), request_timeout: 50)
    end

    test "a connection refusal converts to :network_error", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %TranscriptionAdapterError{reason: :network_error}} = call(stub, req())
    end

    test "an undecodable JSON 200 is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not json")
      end)

      assert {:error, %TranscriptionAdapterError{reason: :malformed_response} = err} =
               call(stub, req())

      assert err.message =~ "ElevenLabs transcription"
    end
  end
end
