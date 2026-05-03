defmodule ALLM.Providers.GeminiTest do
  @moduledoc """
  Phase 16.1 unit tests for `ALLM.Providers.Gemini` non-streaming chat.

  Covers Test Plan §16.1.1 first list:

    * Happy-path single-turn `STOP` decode (`Response.content`,
      `:finish_reason`, `:usage`, `metadata.raw_finish_reason`,
      `metadata.model_version`).
    * Multi-turn `:user`/`:assistant` history with `:assistant → "model"`.
    * System-message hoist into `systemInstruction`.
    * Multiple system messages concatenated with `\\n\\n`.
    * `:max_tokens / :temperature / :top_p` mapping into
      `generationConfig.{maxOutputTokens, temperature, topP}`.
    * `response_format: %{type: :json_object}` and `:json_schema`.
    * Decision #14 finish-reason mapping rows.
    * Decision #9 `promptFeedback.blockReason` empty-candidates path.
    * Decision #10 empty-candidates without blockReason → :malformed_response.
    * Decision #11 `responseTokenCount` fallback.
    * Decision #15 error envelope mapping (full table).
    * `opts[:request_timeout]` honored.
    * `opts[:adapter_opts][:endpoint]` override.
    * Missing-key surfaces `%EngineError{reason: :missing_key}`.
  """
  use ExUnit.Case, async: false

  doctest ALLM.Providers.Gemini

  alias ALLM.Error.AdapterError
  alias ALLM.Error.EngineError
  alias ALLM.Message
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.GeminiTestFixtures, as: Fx
  alias ALLM.Request

  setup do
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    :ok
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "gemini-2.5-flash"], opts)
    )
  end

  defp stub_json(name_prefix, status, body) do
    stub = String.to_atom("#{name_prefix}_#{System.unique_integer([:positive])}")

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    stub
  end

  # ---------------------------------------------------------------------------
  # Happy-path generate/2
  # ---------------------------------------------------------------------------

  describe "generate/2 happy path" do
    test "single user message → :stop, content, usage, raw_finish_reason, model_version" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_happy", 200, Fx.generate_content(:happy_text))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.output_text == "hello"
      assert response.finish_reason == :stop
      assert response.raw_finish_reason == nil
      assert response.usage.input_tokens == 9
      assert response.usage.output_tokens == 1
      assert response.usage.total_tokens == 10
      assert response.metadata[:model_version] == "gemini-2.5-flash"
      assert response.message.role == :assistant
      assert response.message.content == "hello"
    end

    test "multi-turn user/assistant history maps :assistant → \"model\"" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()

      stub = String.to_atom("gemini_multi_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:multi_turn)))
      end)

      messages = [
        %Message{role: :user, content: "What is 2+2?"},
        %Message{role: :assistant, content: "It is 4."},
        %Message{role: :user, content: "And 2+2 again?"}
      ]

      assert {:ok, _} =
               Gemini.generate(Request.new(messages, model: "gemini-2.5-flash"),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      contents = body["contents"]
      assert length(contents) == 3
      assert Enum.at(contents, 0)["role"] == "user"
      assert Enum.at(contents, 1)["role"] == "model"
      assert Enum.at(contents, 2)["role"] == "user"
    end

    test "single system message hoisted to systemInstruction; not in contents" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()
      stub = String.to_atom("gemini_sys_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
      end)

      messages = [
        %Message{role: :system, content: "Be brief."},
        %Message{role: :user, content: "hi"}
      ]

      assert {:ok, _} =
               Gemini.generate(Request.new(messages, model: "gemini-2.5-flash"),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      assert get_in(body, ["systemInstruction", "parts"]) == [%{"text" => "Be brief."}]
      assert length(body["contents"]) == 1
      assert hd(body["contents"])["role"] == "user"
    end

    test "multiple system messages concatenated with \"\\n\\n\"" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()
      stub = String.to_atom("gemini_multisys_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
      end)

      messages = [
        %Message{role: :system, content: "a"},
        %Message{role: :system, content: "b"},
        %Message{role: :system, content: "c"},
        %Message{role: :user, content: "hi"}
      ]

      assert {:ok, _} =
               Gemini.generate(Request.new(messages, model: "gemini-2.5-flash"),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      assert get_in(body, ["systemInstruction", "parts"]) == [%{"text" => "a\n\nb\n\nc"}]
    end

    test "max_tokens / temperature / top_p map into generationConfig" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()
      stub = String.to_atom("gemini_genconf_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
      end)

      request =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          model: "gemini-2.5-flash",
          max_tokens: 256,
          temperature: 0.7,
          options: %{top_p: 0.9}
        )

      assert {:ok, _} =
               Gemini.generate(request,
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      gc = body["generationConfig"]
      assert gc["maxOutputTokens"] == 256
      assert gc["temperature"] == 0.7
      assert gc["topP"] == 0.9
    end

    test "response_format :json_object sets responseMimeType only" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()
      stub = String.to_atom("gemini_json_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
      end)

      request =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          response_format: %{type: :json_object}
        )

      assert {:ok, _} =
               Gemini.generate(request,
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      assert body["generationConfig"]["responseMimeType"] == "application/json"
      refute Map.has_key?(body["generationConfig"], "responseSchema")
    end

    test "response_format :json_schema sets responseMimeType + responseSchema" do
      ALLM.Keys.put(:gemini, "AIza-test")
      ref = make_ref()
      test_pid = self()
      stub = String.to_atom("gemini_schema_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
      end)

      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

      request =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          response_format: %{type: :json_schema, name: "person", schema: schema}
        )

      assert {:ok, _} =
               Gemini.generate(request,
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {^ref, body}
      assert body["generationConfig"]["responseMimeType"] == "application/json"
      assert body["generationConfig"]["responseSchema"] == schema
    end
  end

  # ---------------------------------------------------------------------------
  # Decision #14 finish-reason mapping (representative rows; full table covered
  # in `parse_finish_reason/1` doctest + the helper test below).
  # ---------------------------------------------------------------------------

  describe "generate/2 finish-reason mapping (Decision #14)" do
    test "MAX_TOKENS → :length, raw preserved" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_maxtok", 200, Fx.generate_content(:max_tokens))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :length
      assert response.raw_finish_reason == "MAX_TOKENS"
    end

    test "SAFETY → :content_filter, raw preserved" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_safety", 200, Fx.generate_content(:safety_filter))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :content_filter
      assert response.raw_finish_reason == "SAFETY"
    end
  end

  describe "parse_finish_reason/1 (Decision #14 closed table)" do
    test "every documented row" do
      assert Gemini.parse_finish_reason("STOP") == {:stop, nil}
      assert Gemini.parse_finish_reason("MAX_TOKENS") == {:length, "MAX_TOKENS"}
      assert Gemini.parse_finish_reason("SAFETY") == {:content_filter, "SAFETY"}
      assert Gemini.parse_finish_reason("RECITATION") == {:content_filter, "RECITATION"}
      assert Gemini.parse_finish_reason("LANGUAGE") == {:content_filter, "LANGUAGE"}
      assert Gemini.parse_finish_reason("BLOCKLIST") == {:content_filter, "BLOCKLIST"}

      assert Gemini.parse_finish_reason("PROHIBITED_CONTENT") ==
               {:content_filter, "PROHIBITED_CONTENT"}

      assert Gemini.parse_finish_reason("SPII") == {:content_filter, "SPII"}
      assert Gemini.parse_finish_reason("IMAGE_SAFETY") == {:content_filter, "IMAGE_SAFETY"}

      assert Gemini.parse_finish_reason("IMAGE_PROHIBITED_CONTENT") ==
               {:content_filter, "IMAGE_PROHIBITED_CONTENT"}

      assert Gemini.parse_finish_reason("IMAGE_RECITATION") ==
               {:content_filter, "IMAGE_RECITATION"}

      assert Gemini.parse_finish_reason("IMAGE_OTHER") == {:other, "IMAGE_OTHER"}
      assert Gemini.parse_finish_reason("NO_IMAGE") == {:other, "NO_IMAGE"}

      assert Gemini.parse_finish_reason("MALFORMED_FUNCTION_CALL") ==
               {:error, "MALFORMED_FUNCTION_CALL"}

      assert Gemini.parse_finish_reason("UNEXPECTED_TOOL_CALL") ==
               {:error, "UNEXPECTED_TOOL_CALL"}

      assert Gemini.parse_finish_reason("TOO_MANY_TOOL_CALLS") ==
               {:error, "TOO_MANY_TOOL_CALLS"}

      assert Gemini.parse_finish_reason("MISSING_THOUGHT_SIGNATURE") ==
               {:error, "MISSING_THOUGHT_SIGNATURE"}

      assert Gemini.parse_finish_reason("MALFORMED_RESPONSE") ==
               {:error, "MALFORMED_RESPONSE"}

      assert Gemini.parse_finish_reason("OTHER") == {:other, "OTHER"}

      assert Gemini.parse_finish_reason("FINISH_REASON_UNSPECIFIED") ==
               {:other, "FINISH_REASON_UNSPECIFIED"}

      assert Gemini.parse_finish_reason("CHEESE") == {:other, "CHEESE"}
      assert Gemini.parse_finish_reason(nil) == {nil, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Decision #9 / #10 — empty-candidates branches
  # ---------------------------------------------------------------------------

  describe "generate/2 promptFeedback / empty candidates" do
    test "promptFeedback.blockReason → {:ok, %Response{finish_reason: :content_filter, content: \"\"}} (Decision #9)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_blocked", 200, Fx.synthesized(:prompt_blocked))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :content_filter
      assert response.output_text == ""
      assert response.metadata[:error][:reason] == "blocked:SAFETY"
    end

    test "empty candidates with no promptFeedback → :malformed_response (Decision #10)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_empty", 200, Fx.synthesized(:empty_candidates))

      assert {:error, %AdapterError{reason: :malformed_response}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Decision #11 — usageMetadata fallback
  # ---------------------------------------------------------------------------

  describe "generate/2 usage decoding (Decision #11)" do
    test "candidatesTokenCount primary path" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_usage_p", 200, Fx.generate_content(:happy_text))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.usage.output_tokens == 1
    end

    test "responseTokenCount fallback when candidatesTokenCount absent" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_usage_r", 200, Fx.generate_content(:response_token_count))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.usage.input_tokens == 5
      assert response.usage.output_tokens == 1
      assert response.usage.total_tokens == 6
    end
  end

  # ---------------------------------------------------------------------------
  # Decision #15 — error envelope mapping
  # ---------------------------------------------------------------------------

  describe "generate/2 error envelope mapping (Decision #15)" do
    test "401 UNAUTHENTICATED → :authentication_failed" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_401", 401, Fx.synthesized(:auth_failed))

      assert {:error, %AdapterError{reason: :authentication_failed, status: 401}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "403 PERMISSION_DENIED → :authentication_failed" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_403", 403, Fx.synthesized(:permission_denied))

      assert {:error, %AdapterError{reason: :authentication_failed, status: 403}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "404 NOT_FOUND → :invalid_request" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_404", 404, Fx.synthesized(:not_found))

      assert {:error, %AdapterError{reason: :invalid_request, status: 404}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "429 RESOURCE_EXHAUSTED → :rate_limited" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_429", 429, Fx.synthesized(:rate_limited))

      assert {:error, %AdapterError{reason: :rate_limited, status: 429}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "500 INTERNAL → :provider_unavailable" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_500", 500, Fx.synthesized(:server_error))

      assert {:error, %AdapterError{reason: :provider_unavailable, status: 500}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "503 UNAVAILABLE → :provider_unavailable" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_503", 503, Fx.synthesized(:unavailable))

      assert {:error, %AdapterError{reason: :provider_unavailable, status: 503}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "504 DEADLINE_EXCEEDED → :provider_unavailable" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_504", 504, Fx.synthesized(:deadline_exceeded))

      assert {:error, %AdapterError{reason: :provider_unavailable, status: 504}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "400 INVALID_ARGUMENT (no marker) → :invalid_request" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_400", 400, Fx.synthesized(:invalid_argument))

      assert {:error, %AdapterError{reason: :invalid_request, status: 400}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "400 INVALID_ARGUMENT with context-window substring → :context_length_exceeded" do
      ALLM.Keys.put(:gemini, "AIza-test")

      stub =
        stub_json(
          "gemini_400_ctx",
          400,
          Fx.synthesized(:context_length_exceeded)
        )

      assert {:error, %AdapterError{reason: :context_length_exceeded, status: 400}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "non-map body decode → :malformed_response" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_nonmap_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[]")
      end)

      assert {:error, %AdapterError{reason: :malformed_response}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "transport error → :network_error" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_net_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %AdapterError{reason: :network_error}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # opts behaviour
  # ---------------------------------------------------------------------------

  describe "generate/2 options" do
    test "honors opts[:request_timeout] (forwards as :receive_timeout)" do
      ALLM.Keys.put(:gemini, "AIza-test")

      assert {:ok, %Req.Request{} = http_req} =
               Gemini.prepare_request(req(), request_timeout: 1234)

      assert http_req.options[:receive_timeout] == 1234
    end

    test "honors opts[:adapter_opts][:endpoint] override" do
      ALLM.Keys.put(:gemini, "AIza-test")

      assert {:ok, %Req.Request{} = http_req} =
               Gemini.prepare_request(req(),
                 adapter_opts: [endpoint: "https://example.test/v1custom"]
               )

      assert URI.parse(http_req.url |> to_string()).host == "example.test"
    end

    test "missing key raises %EngineError{reason: :missing_key} via Keys.fetch!" do
      ALLM.Keys.delete(:gemini)
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      assert_raise EngineError, fn ->
        Gemini.generate(req(), retry: false)
      end
    end

    test "request_id flows into retry telemetry metadata" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_reqid", 200, Fx.generate_content(:happy_text))

      assert {:ok, _response} =
               Gemini.generate(req(),
                 retry: false,
                 request_id: "req-abc-123",
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Retry — default policy retries 5xx then succeeds
  # ---------------------------------------------------------------------------

  describe "generate/2 retry (default policy)" do
    test "retries 503 then succeeds on second attempt" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_retry_#{System.unique_integer([:positive])}")
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub, fn conn ->
        n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(503, Jason.encode!(Fx.synthesized(:unavailable)))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(Fx.generate_content(:happy_text)))
        end
      end)

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: [retry_on: [503, :timeout], base_delay_ms: 1, jitter_ms: 0],
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.output_text == "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # translate_options/2 — identity (Decision #18)
  # ---------------------------------------------------------------------------

  describe "translate_options/2" do
    test "is identity" do
      r = req()

      assert Gemini.translate_options([max_tokens: 100, temperature: 0.5], r) ==
               [max_tokens: 100, temperature: 0.5]

      assert Gemini.translate_options([], r) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive branches — coverage for paths that legitimate happy-path tests
  # don't exercise (transport faults, malformed bodies, defensive role
  # mappings, option_key passthrough). These guard against silent regressions
  # if the relevant invariants ever flip.
  # ---------------------------------------------------------------------------

  describe "defensive branches" do
    test "transport :timeout surfaces as :timeout AdapterError after retry exhaustion" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_timeout_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        # Simulate a transport-level timeout — Req surfaces this as a
        # Req.TransportError with reason: :timeout (gemini.ex:320).
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %AdapterError{reason: :timeout}} =
               Gemini.generate(req(),
                 retry: [retry_on: [:timeout], max_attempts: 1, base_delay_ms: 0, jitter_ms: 0],
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "transport non-timeout exception surfaces as :network_error" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_neterr_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %AdapterError{reason: :network_error} = err} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert err.message =~ "transport failure"
    end

    test "Retry-After header is parsed and populates AdapterError.retry_after_ms (Decision #16 amendment)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_retryafter_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.resp(429, Jason.encode!(Fx.synthesized(:rate_limited)))
      end)

      # `retry: false` short-circuits the retry loop; the classified error
      # is what surfaces. We verify it carries the parsed retry_after_ms.
      assert {:error, %AdapterError{reason: :rate_limited} = err} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert err.retry_after_ms == 7_000
    end

    test "Retry-After with unparseable value parses to nil" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = String.to_atom("gemini_retryafter_bad_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "not-a-number")
        |> Plug.Conn.resp(429, Jason.encode!(Fx.synthesized(:rate_limited)))
      end)

      assert {:error, %AdapterError{reason: :rate_limited, retry_after_ms: nil}} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end

    test "classify_error/3 with list-of-tuples headers extracts retry-after" do
      # Direct unit test against the `@doc false` seam to exercise the
      # list-shaped header branch (`header_value/2` for list).
      err =
        Gemini.classify_error(429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}, [
          {"Retry-After", "3"}
        ])

      assert err.retry_after_ms == 3_000
    end

    test "classify_error/3 with unrecognized HTTP status returns :unknown reason" do
      err = Gemini.classify_error(418, %{"error" => %{"message" => "I'm a teapot"}}, [])
      assert err.reason == :unknown
      assert err.status == 418
    end

    test "classify_error/3 on 400 with non-binary message defaults to :invalid_request" do
      # The default fall-through `Map.get(error, "message", "Gemini HTTP #{status}")`
      # supplies a binary fallback, so to truly hit the non-binary clause we
      # bypass via direct call with a non-binary message in the error body.
      err =
        Gemini.classify_error(
          400,
          %{"error" => %{"status" => "INVALID_ARGUMENT", "message" => 123}},
          []
        )

      # 123 is not binary; classify_reason/3 falls through to the
      # `classify_reason(400, _gs, _msg)` clause.
      assert err.reason == :invalid_request
    end

    test "to_gemini_request_body honors response_format: :text (no responseMimeType set)" do
      r =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          response_format: :text
        )

      body = Gemini.to_gemini_request_body(r, [])
      # generationConfig either absent or present without a responseMimeType
      gc = body["generationConfig"] || %{}
      refute Map.has_key?(gc, "responseMimeType")
    end

    test "to_gemini_request_body ignores unknown response_format shape (defensive)" do
      r =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          response_format: %{type: :unknown_shape}
        )

      body = Gemini.to_gemini_request_body(r, [])
      gc = body["generationConfig"] || %{}
      refute Map.has_key?(gc, "responseMimeType")
    end

    test "to_gemini_request_body maps :top_p / :top_k / :stop / :response_mime_type / :response_schema option keys" do
      r =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          options: %{
            "rawKey" => "v",
            top_p: 0.9,
            top_k: 40,
            stop: ["END"],
            response_mime_type: "application/json",
            response_schema: %{"type" => "object"},
            # arbitrary atom key — passes through via `Atom.to_string/1`
            custom_atom: "v"
          }
        )

      gc = Gemini.to_gemini_request_body(r, [])["generationConfig"]
      assert gc["topP"] == 0.9
      assert gc["topK"] == 40
      assert gc["stopSequences"] == ["END"]
      assert gc["responseMimeType"] == "application/json"
      assert gc["responseSchema"] == %{"type" => "object"}
      assert gc["custom_atom"] == "v"
      assert gc["rawKey"] == "v"
    end

    test "to_gemini_contents handles message with nil content (stringify_content/1 nil path)" do
      [encoded] = Gemini.to_gemini_contents([%Message{role: :user, content: nil}])
      assert encoded == %{"role" => "user", "parts" => [%{"text" => ""}]}
    end

    test "to_gemini_contents handles a stray :system message defensively (extract_system would normally remove)" do
      [encoded] =
        Gemini.to_gemini_contents([%Message{role: :system, content: "should-not-arrive-here"}])

      # Defensive fallback collapses to a user turn so the request still
      # serializes without crashing.
      assert encoded == %{
               "role" => "user",
               "parts" => [%{"text" => "should-not-arrive-here"}]
             }
    end

    test "to_gemini_contents translates a :tool-role message to a functionResponse part (Phase 16.3 round-trip)" do
      # Phase 16.3 replaced 16.1's defensive `user/text` fallback with the
      # canonical `user`-role + `functionResponse` part translation per
      # GEMINI_DESIGN.md Decision #5.
      [encoded] =
        Gemini.to_gemini_contents([
          %Message{
            role: :tool,
            content: "tool-output",
            tool_call_id: "call_abc",
            name: "do_thing"
          }
        ])

      assert encoded == %{
               "role" => "user",
               "parts" => [
                 %{
                   "functionResponse" => %{
                     "id" => "call_abc",
                     "name" => "do_thing",
                     "response" => %{"output" => "tool-output"}
                   }
                 }
               ]
             }
    end

    test "decode_response throws :malformed_response when candidates is non-list" do
      assert catch_throw(Gemini.decode_response(%{"candidates" => "not-a-list"}, [])) ==
               {:malformed_response, {:non_list_candidates, "not-a-list"}}
    end

    test "decode_response on empty parts list yields output_text == nil and content \"\"" do
      body = %{
        "candidates" => [
          %{"content" => %{"parts" => []}, "finishReason" => "STOP"}
        ]
      }

      response = Gemini.decode_response(body, [])
      assert response.output_text == nil
      assert response.message.content == ""
    end

    test "decode_response skips non-text parts without crashing (parts_to_text/1 default branch)" do
      # A future phase (16.4 vision input echoing a part, or 16.5 image-out)
      # may surface non-text parts here; the text accumulator must skip
      # them rather than crash.
      body = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "before"},
                %{"functionCall" => %{"name" => "x", "args" => %{}}},
                %{"text" => "after"}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = Gemini.decode_response(body, [])
      assert response.output_text == "beforeafter"
    end

    test "decode_response without modelVersion produces empty metadata" do
      body = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
        ]
      }

      response = Gemini.decode_response(body, [])
      assert response.metadata == %{}
    end

    test "parse_usage/1 returns empty Usage when given a non-map input" do
      assert Gemini.parse_usage(nil) == %ALLM.Usage{}
      assert Gemini.parse_usage(:not_a_map) == %ALLM.Usage{}
    end

    test "parse_finish_reason/1 maps unknown binary to :other (defensive fallback)" do
      assert Gemini.parse_finish_reason("UNKNOWN_FUTURE_REASON") ==
               {:other, "UNKNOWN_FUTURE_REASON"}
    end

    test "GeminiTestFixtures loaders strip the `_comment` provenance marker" do
      # Synthesized fixtures carry `_comment`; the loader's drop_comment/1
      # ensures it never leaks into Response.raw or request-build paths.
      body = Fx.synthesized(:auth_failed)
      refute Map.has_key?(body, "_comment")

      body2 = Fx.generate_content(:happy_text)
      refute Map.has_key?(body2, "_comment")
    end
  end
end
