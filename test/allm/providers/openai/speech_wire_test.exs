defmodule ALLM.Providers.OpenAI.SpeechWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.OpenAI.Speech`, driven end-to-end
  through `synthesize/2` behind a `Req.Test` stub.

  **Fixtures are JSON envelopes** (`status`, `headers`, and either
  `body_base64`/`byte_size`/`sha256` for audio or `body` for JSON), because
  the endpoint answers raw audio and the fixture convention is `.json`. The
  stub replays the recorded status, `content-type` and body bytes.

  **Provenance.** `recorded/` holds genuine live responses written by
  `scripts/record_openai_audio_fixtures.exs` on 2026-09-24, including the
  assert-only `probe_*.json` outcomes, and none carries a `_comment` marker.
  `synthesized/` files each carry one. Both halves are gated below by tests
  that read the raw file bytes, because the loaders call `drop_comment/1`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, SpeechRequest, SpeechResponse}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.OpenAI.Speech
  alias ALLM.Providers.OpenAITestFixtures, as: Fixtures

  @fixtures_root "test/fixtures/openai/speech"

  setup do
    {:ok, stub: String.to_atom("openai_speech_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))

  defp call(stub, request, opts \\ []) do
    Speech.synthesize(
      request,
      Keyword.merge(
        [api_key: "sk-wire-test", retry: false, adapter_opts: [plug: {Req.Test, stub}]],
        opts
      )
    )
  end

  # Replays an envelope: status, every recorded header, and the body bytes
  # (audio decoded from base64, JSON re-encoded).
  defp replay(conn, env) do
    body =
      case env do
        %{"body_base64" => _} -> Fixtures.envelope_bytes(env)
        %{"body" => b} -> Jason.encode!(b)
      end

    env
    |> Map.get("headers", %{})
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.send_resp(env["status"], body)
  end

  defp stub_env(stub, env), do: Req.Test.stub(stub, &replay(&1, env))

  # ---------------------------------------------------------------------------
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @recorded ~w(mp3_default wav pcm error_400_too_long error_404_model error_401_bad_key
                 probe_control probe_unit_graphemes probe_unit_bytes)
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

    test "audio envelopes carry no raw audio outside body_base64 and check out" do
      for name <- [:mp3_default, :wav, :pcm] do
        env = Fixtures.speech_recorded(name)
        assert byte_size(Fixtures.envelope_bytes(env)) == env["byte_size"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Request shape
  # ---------------------------------------------------------------------------

  describe "request shape" do
    test "POSTs JSON to /v1/audio/speech with a bearer key", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "content-type"), Jason.decode!(raw)}
        )

        replay(conn, Fixtures.speech_recorded(:mp3_default))
      end)

      assert {:ok, _} = call(stub, req(format: :wav))

      assert_received {:req, "POST", "api.openai.com", "/v1/audio/speech", ["Bearer sk-wire-test"],
                       [ct], body}

      assert ct =~ "application/json"

      assert body == %{
               "model" => "gpt-4o-mini-tts",
               "input" => "Hello.",
               "voice" => "alloy",
               "response_format" => "wav"
             }
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/
  # ---------------------------------------------------------------------------

  describe "recorded audio bodies" do
    for {name, format, mime} <- [
          {:mp3_default, :mp3, "audio/mpeg"},
          {:wav, :wav, "audio/wav"},
          {:pcm, :pcm, "audio/pcm"}
        ] do
      test "recorded/#{name}.json decodes to format #{inspect(format)}", %{stub: stub} do
        env = Fixtures.speech_recorded(unquote(name))
        stub_env(stub, env)

        assert {:ok, %SpeechResponse{} = resp} = call(stub, req())
        assert resp.format == unquote(format)
        assert resp.audio.mime_type == unquote(mime)
        assert Audio.to_binary(resp.audio) == {:ok, Fixtures.envelope_bytes(env)}
        assert resp.raw == nil
        assert resp.request_id == env["headers"]["x-request-id"]
        assert resp.provider == :openai
      end
    end
  end

  describe "recorded error bodies" do
    test "error_400_too_long.json (live string_too_long) is :context_length_exceeded", %{
      stub: stub
    } do
      stub_env(stub, Fixtures.speech_recorded(:error_400_too_long))

      # The gate would stop a 4097-character input before HTTP; a caller whose
      # model had a different limit would meet the provider's 400 instead.
      assert {:error, %SpeechAdapterError{reason: :context_length_exceeded, status: 400}} =
               call(stub, req())
    end

    test "error_404_model.json is :invalid_request with the provider code", %{stub: stub} do
      env = Fixtures.speech_recorded(:error_404_model)
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :invalid_request} = err} = call(stub, req())
      assert err.status == 404
      assert err.metadata.openai_code == "model_not_found"
      assert err.message == env["body"]["error"]["message"]
    end

    test "error_401_bad_key.json arrives as text/plain and keeps its message", %{stub: stub} do
      env = Fixtures.speech_recorded(:error_401_bad_key)
      assert env["headers"]["content-type"] =~ "text/plain"
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      # Falsifier: a decode_error_body/1 that drops binaries leaves the
      # generic "OpenAI HTTP 401" here.
      assert err.message == env["body"]["error"]["message"]
      assert err.message =~ "sk-proj-****"
    end
  end

  describe "recorded probe outcomes" do
    test "the unit probes settle code points: graphemes 400, precomposed bytes 200" do
      assert Fixtures.speech_recorded(:probe_unit_graphemes)["status"] == 400
      assert Fixtures.speech_recorded(:probe_unit_bytes)["status"] == 200

      assert Jason.encode!(Fixtures.speech_recorded(:probe_unit_graphemes)["error_body"]) =~
               "string_too_long"
    end

    test "the control arm was accepted (unknown fields are ignored)" do
      assert Fixtures.speech_recorded(:probe_control)["status"] == 200
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/ — redaction and 429
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @planted "sk-proj-FAKEKEY000111222333444555"

    test "the planted sk- token in synthesized/error_401.json is redacted", %{stub: stub} do
      env = Fixtures.speech_synthesized(:error_401)
      assert env["body"]["error"]["message"] =~ @planted, "fixture must carry a key-shaped token"
      stub_env(stub, env)

      assert {:error, %SpeechAdapterError{reason: :authentication_failed} = err} =
               call(stub, req())

      refute inspect(err) =~ @planted
      refute Jason.encode!(err) =~ @planted
      assert err.message =~ "[REDACTED]"
      refute Map.has_key?(err.metadata, :body_preview)
    end

    test "the Gemini and Voyage key patterns match nothing in the same fixture" do
      message = Fixtures.speech_synthesized(:error_401)["body"]["error"]["message"]

      refute message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
    end
  end

  describe "synthesized/error_429.json" do
    test "maps to :rate_limited with Retry-After honoured", %{stub: stub} do
      stub_env(stub, Fixtures.speech_synthesized(:error_429))

      assert {:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 7_000}} =
               call(stub, req())
    end
  end

  # ---------------------------------------------------------------------------
  # Transport and retry
  # ---------------------------------------------------------------------------

  describe "transport failures" do
    test "a timeout converts to :timeout", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %SpeechAdapterError{reason: :timeout}} =
               call(stub, req(), request_timeout: 50)
    end

    test "a connection refusal converts to :network_error", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %SpeechAdapterError{reason: :network_error}} = call(stub, req())
    end

    test "a 200 JSON body instead of audio is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"not" => "audio"}))
      assert {:error, %SpeechAdapterError{reason: :malformed_response}} = call(stub, req())
    end

    test "an undecodable JSON 200 is :malformed_response and does not leak the body", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not json at all")
      end)

      assert {:error, %SpeechAdapterError{reason: :malformed_response} = err} = call(stub, req())
      refute inspect(err) =~ "not json"
      # The sanitized cause must still render: blanking only `:data` makes
      # `Jason.DecodeError.message/1` raise on the stale offset.
      assert is_binary(Exception.message(err.cause))
    end
  end

  describe "retry integration (the adapter's own loop)" do
    defp counting_stub(stub, status, body) do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        Req.Test.json(Plug.Conn.put_status(conn, status), body)
      end)
    end

    test "under the DEFAULT policy a 500 is not retried by the adapter", %{stub: stub} do
      counting_stub(stub, 500, %{"error" => %{"message" => "boom"}})

      assert {:error, %SpeechAdapterError{reason: :provider_unavailable}} =
               call(stub, req(), retry: :default)

      assert_received :attempt
      refute_received :attempt
    end

    test "a policy listing :rate_limited retries a 429", %{stub: stub} do
      counting_stub(stub, 429, %{"error" => %{"message" => "slow"}})

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               call(stub, req(),
                 retry: [max_attempts: 2, base_delay_ms: 0, jitter_ms: 0, retry_on: [:rate_limited]]
               )

      assert_received :attempt
      assert_received :attempt
      refute_received :attempt
    end

    test "a 400 is never retried", %{stub: stub} do
      counting_stub(stub, 400, %{"error" => %{"message" => "bad voice"}})

      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               call(stub, req(),
                 retry: [
                   max_attempts: 3,
                   base_delay_ms: 0,
                   jitter_ms: 0,
                   retry_on: [:invalid_request]
                 ]
               )

      # Even a policy naming :invalid_request cannot retry it: the attempt
      # returns {:error, _}, never {:retry, _, _}, for a 400.
      assert_received :attempt
      refute_received :attempt
    end
  end
end
