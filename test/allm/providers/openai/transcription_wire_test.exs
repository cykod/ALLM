defmodule ALLM.Providers.OpenAI.TranscriptionWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.OpenAI.Transcription`, driven
  end-to-end through `transcribe/2` behind a `Req.Test` stub.

  Fixtures are JSON envelopes (`status`, `headers`, `body`) written by
  `scripts/record_openai_audio_fixtures.exs` on 2026-09-24, plus the
  assert-only `probe_*.json` outcomes. `recorded/` files carry no `_comment`
  marker and `synthesized/` files each carry one; both are gated below from
  the raw file bytes, because the loaders call `drop_comment/1`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.OpenAI.Transcription
  alias ALLM.Providers.OpenAITestFixtures, as: Fixtures

  @fixtures_root "test/fixtures/openai/transcriptions"
  @clip "test/fixtures/audio/quick_brown_fox.mp3"

  setup do
    {:ok, stub: String.to_atom("openai_stt_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []) do
    TranscriptionRequest.new(Keyword.merge([audio: Audio.from_file(@clip)], opts))
  end

  defp call(stub, request, opts \\ []) do
    Transcription.transcribe(
      request,
      Keyword.merge([api_key: "sk-wire-test", adapter_opts: [plug: {Req.Test, stub}]], opts)
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
    @recorded ~w(gpt_transcribe mini_tokens error_400_format error_401_bad_key error_413
                 probe_control probe_audio_bin probe_size_ladder probe_duration)
    @synthesized ~w(error_401 error_429)

    defp raw(kind, name),
      do: [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()

    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )`"
      end
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 25.4)"
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

    test "the input clips the recorder wrote are all present" do
      for ext <- ~w(mp3 wav flac aac opus) do
        assert File.stat!("test/fixtures/audio/quick_brown_fox.#{ext}").size > 4096
      end

      assert File.read!("examples/fixtures/quick_brown_fox.mp3") == File.read!(@clip)
    end
  end

  # ---------------------------------------------------------------------------
  # Request shape
  # ---------------------------------------------------------------------------

  describe "request shape" do
    test "POSTs multipart/form-data to /v1/audio/transcriptions with a bearer key", %{
      stub: stub
    } do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "content-type"), raw}
        )

        replay(conn, Fixtures.transcription_recorded(:gpt_transcribe))
      end)

      assert {:ok, _} = call(stub, req(language: "en"))

      assert_received {:req, "POST", "api.openai.com", "/v1/audio/transcriptions",
                       ["Bearer sk-wire-test"], [ct], raw}

      assert ct =~ "multipart/form-data; boundary="
      assert raw =~ ~s(name="file"; filename="quick_brown_fox.mp3")
      assert raw =~ "content-type: audio/mpeg"
      assert raw =~ ~r/name="model"\r\n\r\ngpt-transcribe\r\n/
      assert raw =~ ~r/name="response_format"\r\n\r\njson\r\n/
      assert raw =~ ~r/name="language"\r\n\r\nen\r\n/
      assert :binary.match(raw, File.read!(@clip)) != :nomatch
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/
  # ---------------------------------------------------------------------------

  describe "recorded bodies" do
    test "gpt_transcribe.json: text, duration usage, language", %{stub: stub} do
      env = Fixtures.transcription_recorded(:gpt_transcribe)
      stub_env(stub, env)

      assert {:ok, %TranscriptionResponse{} = resp} = call(stub, req())
      assert resp.text == env["body"]["text"]
      assert resp.duration_seconds == env["body"]["usage"]["seconds"]
      assert resp.usage.input_tokens == nil
      assert resp.language == "en"
      assert resp.request_id == env["headers"]["x-request-id"]
      assert resp.raw == env["body"]
    end

    test "mini_tokens.json: token usage, no duration", %{stub: stub} do
      env = Fixtures.transcription_recorded(:mini_tokens)
      stub_env(stub, env)

      assert {:ok, resp} = call(stub, req(model: "gpt-4o-mini-transcribe"))
      usage = env["body"]["usage"]
      assert resp.usage.input_tokens == usage["input_tokens"]
      assert resp.usage.output_tokens == usage["output_tokens"]
      assert resp.usage.total_tokens == usage["total_tokens"]
      assert resp.duration_seconds == nil
      assert resp.model == "gpt-4o-mini-transcribe"
    end

    test "error_400_format.json is :invalid_request", %{stub: stub} do
      env = Fixtures.transcription_recorded(:error_400_format)
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               call(stub, req())

      assert err.message == env["body"]["error"]["message"]
    end

    test "error_413.json (the live size rejection) is :invalid_request", %{stub: stub} do
      stub_env(stub, Fixtures.transcription_recorded(:error_413))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, status: 413}} =
               call(stub, req())
    end

    test "error_401_bad_key.json arrives as text/plain and keeps its message", %{stub: stub} do
      env = Fixtures.transcription_recorded(:error_401_bad_key)
      assert env["headers"]["content-type"] =~ "text/plain"
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      assert err.message == env["body"]["error"]["message"]
    end
  end

  describe "recorded probe outcomes" do
    test "audio.bin was rejected: OpenAI trusts the filename extension" do
      env = Fixtures.transcription_recorded(:probe_audio_bin)
      assert env["status"] == 400
      assert env["error_body"]["error"]["message"] =~ "Unsupported file format bin"
    end

    test "the size ladder: two rungs accepted, 25 MiB + 1 rejected with 413" do
      ladder = Fixtures.transcription_recorded(:probe_size_ladder)
      assert Enum.map(ladder["rungs"], & &1["status"]) == [200, 200, 413]
    end

    test "control accepted; the 1800 s duration clip accepted" do
      assert Fixtures.transcription_recorded(:probe_control)["status"] == 200
      assert Fixtures.transcription_recorded(:probe_duration)["status"] == 200
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @planted "sk-proj-FAKEKEY000111222333444555"

    test "the planted sk- token in synthesized/error_401.json is redacted", %{stub: stub} do
      env = Fixtures.transcription_synthesized(:error_401)
      assert env["body"]["error"]["message"] =~ @planted, "fixture must carry a key-shaped token"
      stub_env(stub, env)

      assert {:error, %TranscriptionAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      refute inspect(err) =~ @planted
      refute Jason.encode!(err) =~ @planted
      assert err.message =~ "[REDACTED]"
      refute Map.has_key?(err.metadata, :body_preview)
    end

    test "the Gemini and Voyage key patterns match nothing in the same fixture" do
      message = Fixtures.transcription_synthesized(:error_401)["body"]["error"]["message"]

      refute message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
    end
  end

  describe "synthesized/error_429.json" do
    test "maps to :rate_limited with Retry-After, in one attempt", %{stub: stub} do
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

    test "a 200 without text is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"usage" => %{}}))
      assert {:error, %TranscriptionAdapterError{reason: :malformed_response}} = call(stub, req())
    end
  end
end
