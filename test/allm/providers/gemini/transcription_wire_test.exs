defmodule ALLM.Providers.Gemini.TranscriptionWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.Gemini.Transcription`, driven
  end-to-end through `transcribe/2` behind a `Req.Test` stub.

  Fixtures are JSON envelopes (`status`, `headers`, `body`) written by
  `scripts/record_gemini_audio_fixtures.exs` on 2026-09-24, plus the
  assert-only `probe_*.json` outcomes. `recorded/` files carry no `_comment`
  marker and `synthesized/` files each carry one; both are gated below from
  the raw file bytes, because the loaders call `drop_comment/1`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.Gemini.Transcription
  alias ALLM.Providers.GeminiTestFixtures, as: Fixtures

  @fixtures_root "test/fixtures/gemini/transcriptions"
  @clip "test/fixtures/audio/quick_brown_fox.mp3"
  @planted "AIzaSyFAKEKEY000111222333444555666"

  setup do
    {:ok, stub: String.to_atom("gemini_stt_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []) do
    TranscriptionRequest.new(Keyword.merge([audio: Audio.from_file(@clip)], opts))
  end

  defp call(stub, request, opts \\ []) do
    Transcription.transcribe(
      request,
      Keyword.merge([api_key: "AIza-wire-test", adapter_opts: [plug: {Req.Test, stub}]], opts)
    )
  end

  defp replay(conn, %{"status" => status, "body" => body} = env) do
    env
    |> Map.get("headers", %{})
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp stub_env(stub, env), do: Req.Test.stub(stub, &replay(&1, env))

  # ---------------------------------------------------------------------------
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @recorded ~w(mp3 wav flac aac error_400_unknown_field error_400_bad_key
                 probe_opus_as_ogg probe_opus_as_opus probe_boundary_at_cap
                 probe_boundary_over_cap)
    @synthesized ~w(error_400_key error_400_token_limit error_429 max_tokens thought_part
                    safety prompt_blocked)

    defp raw(kind, name),
      do: [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()

    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`( set -a; . ./.env; set +a; mix run scripts/record_gemini_audio_fixtures.exs )`"
      end
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 25.5)"
      end
    end

    defp on_disk(kind) do
      [@fixtures_root, kind, "*.json"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))
      |> Enum.sort()
    end

    test "@recorded enumerates every file under recorded/" do
      assert on_disk("recorded") == Enum.sort(@recorded)
    end

    test "@synthesized enumerates every file under synthesized/" do
      assert on_disk("synthesized") == Enum.sort(@synthesized)
    end
  end

  # ---------------------------------------------------------------------------
  # Request shape
  # ---------------------------------------------------------------------------

  describe "request shape" do
    test "POSTs JSON to models/<model>:generateContent with x-goog-api-key", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "x-goog-api-key"),
           Plug.Conn.get_req_header(conn, "content-type"), Jason.decode!(raw)}
        )

        replay(conn, Fixtures.transcription_recorded(:mp3))
      end)

      assert {:ok, _} = call(stub, req(language: "en"))

      assert_received {:req, "POST", "generativelanguage.googleapis.com",
                       "/v1beta/models/gemini-flash-latest:generateContent", ["AIza-wire-test"],
                       [ct], body}

      assert ct =~ "application/json"

      [%{"role" => "user", "parts" => [%{"text" => text}, %{"inlineData" => inline}]}] =
        body["contents"]

      assert text =~ "Generate a verbatim transcript"
      assert text =~ ~s(language "en")
      assert inline == %{"mimeType" => "audio/mpeg", "data" => Base.encode64(File.read!(@clip))}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/
  # ---------------------------------------------------------------------------

  describe "recorded bodies" do
    for name <- [:mp3, :wav, :flac, :aac] do
      test "#{name}.json decodes to the recorded transcript and usage", %{stub: stub} do
        env = Fixtures.transcription_recorded(unquote(name))
        stub_env(stub, env)

        assert {:ok, %TranscriptionResponse{} = resp} = call(stub, req(), request_id: "r1")
        assert resp.text =~ ~r/quick brown fox/i
        assert resp.id == env["body"]["responseId"]
        assert resp.request_id == "r1"
        assert resp.provider == :gemini
        assert resp.usage.input_tokens == env["body"]["usageMetadata"]["promptTokenCount"]
        assert resp.usage.reasoning_tokens == env["body"]["usageMetadata"]["thoughtsTokenCount"]
        assert resp.raw == env["body"]
      end
    end

    # The answer part carries a thoughtSignature; it is not a thought part.
    test "mp3.json: the answer part carries a thoughtSignature and is kept", %{stub: stub} do
      env = Fixtures.transcription_recorded(:mp3)
      [part] = hd(env["body"]["candidates"])["content"]["parts"]
      assert Map.has_key?(part, "thoughtSignature")
      stub_env(stub, env)

      assert {:ok, %{text: text}} = call(stub, req())
      assert text == part["text"]
    end

    # Binds only the two names the recorder's allowlist looks for; which
    # OTHER headers Google sent is not in this fixture. The recorder now also
    # writes `header_names` — a stronger assertion awaits a re-record.
    test "neither x-request-id nor x-goog-request-id came back; request_id is nil",
         %{stub: stub} do
      env = Fixtures.transcription_recorded(:mp3)
      refute Map.has_key?(env["headers"], "x-request-id")
      refute Map.has_key?(env["headers"], "x-goog-request-id")
      stub_env(stub, env)
      assert {:ok, %{request_id: nil}} = call(stub, req())
    end

    test "error_400_bad_key.json (API_KEY_INVALID) is :authentication_failed", %{stub: stub} do
      env = Fixtures.transcription_recorded(:error_400_bad_key)
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      assert err.status == 400
      assert err.message == env["body"]["error"]["message"]
      assert err.metadata.google_status == "INVALID_ARGUMENT"
    end

    test "error_400_unknown_field.json (the control) is :invalid_request", %{stub: stub} do
      env = Fixtures.transcription_recorded(:error_400_unknown_field)
      assert env["body"]["error"]["message"] =~ "Unknown name"
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} = call(stub, req())
    end
  end

  describe "recorded probe outcomes" do
    test "opus was accepted both as audio/ogg and as audio/opus" do
      for name <- [:probe_opus_as_ogg, :probe_opus_as_opus] do
        env = Fixtures.transcription_recorded(name)
        assert env["status"] == 200
        assert env["text"] =~ ~r/quick brown fox/i
      end

      assert :ok =
               Transcription.gate_audio(
                 req(audio: Audio.from_file("test/fixtures/audio/quick_brown_fox.opus")),
                 []
               )
    end

    test "a clip at max_audio_bytes() and one past it were both accepted (cap is conservative)" do
      assert Fixtures.transcription_recorded(:probe_boundary_at_cap)["status"] == 200
      assert Fixtures.transcription_recorded(:probe_boundary_over_cap)["status"] == 200
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/
  # ---------------------------------------------------------------------------

  describe "redaction" do
    test "the planted AIza token in synthesized/error_400_key.json is redacted", %{stub: stub} do
      env = Fixtures.transcription_synthesized(:error_400_key)
      assert env["body"]["error"]["message"] =~ @planted, "fixture must carry a key-shaped token"
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      refute inspect(err) =~ @planted
      refute Jason.encode!(err) =~ @planted
      assert err.message =~ "[REDACTED]"
      refute Map.has_key?(err.metadata, :body_preview)
    end

    test "the OpenAI and Voyage key patterns match nothing in the same fixture; Gemini's does" do
      message = Fixtures.transcription_synthesized(:error_400_key)["body"]["error"]["message"]

      refute message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
    end
  end

  describe "synthesized bodies" do
    test "error_400_token_limit.json is :context_length_exceeded", %{stub: stub} do
      stub_env(stub, Fixtures.transcription_synthesized(:error_400_token_limit))

      assert {:error, %TranscriptionAdapterError{reason: :context_length_exceeded}} =
               call(stub, req())
    end

    test "error_429.json maps to :rate_limited with Retry-After, in one attempt", %{stub: stub} do
      parent = self()
      env = Fixtures.transcription_synthesized(:error_429)

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        replay(conn, env)
      end)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 7_000}} =
               call(stub, req())

      assert_received :attempt
      refute_received :attempt
    end

    test "max_tokens.json returns the partial text with metadata.finish_reason :length", %{
      stub: stub
    } do
      env = Fixtures.transcription_synthesized(:max_tokens)
      stub_env(stub, env)

      assert {:ok, resp} = call(stub, req(metadata: %{"k" => "v"}))
      assert resp.text == "The quick brown fox jumps"
      assert resp.metadata == %{"k" => "v", finish_reason: :length}
      assert resp.raw == env["body"]
    end

    test "thought_part.json drops the thought part", %{stub: stub} do
      stub_env(stub, Fixtures.transcription_synthesized(:thought_part))

      assert {:ok, %{text: "The quick brown fox jumps over the lazy dog."}} = call(stub, req())
    end

    test "safety.json and prompt_blocked.json are :content_filter", %{stub: stub} do
      stub_env(stub, Fixtures.transcription_synthesized(:safety))

      assert {:error, %TranscriptionAdapterError{reason: :content_filter} = err} =
               call(stub, req())

      assert err.metadata.finish_reason == "SAFETY"

      stub_env(stub, Fixtures.transcription_synthesized(:prompt_blocked))

      assert {:error, %TranscriptionAdapterError{reason: :content_filter} = err} =
               call(stub, req())

      assert err.metadata.block_reason == "PROHIBITED_CONTENT"
    end
  end

  describe "transport failures" do
    test "a connection refusal converts to :network_error", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %TranscriptionAdapterError{reason: :network_error}} = call(stub, req())
    end

    test "an undecodable JSON 200 is :malformed_response and does not leak the body", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not json at all")
      end)

      assert {:error, %TranscriptionAdapterError{reason: :malformed_response} = err} =
               call(stub, req())

      refute inspect(err) =~ "not json"
      assert is_binary(Exception.message(err.cause))
    end

    test "a 200 without candidates is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"usageMetadata" => %{}}))
      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} = call(stub, req())
    end
  end
end
