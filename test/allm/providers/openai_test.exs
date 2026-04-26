defmodule ALLM.Providers.OpenAITest do
  @moduledoc """
  Phase 10.2 unit tests for `ALLM.Providers.OpenAI` helpers.

  Covers translate_options rename matrix (with property), finish-reason
  mapping (table + property over unknowns), `requires_structured_finalize?/1`,
  `prepare_request/2` key resolution + o-series rejection, and
  `dispatch_endpoint/2` matrix per Phase 10 design Decision #1.
  """
  # `async: false` because several `prepare_request/2` tests mutate the
  # global `ALLM.Keys.Store` for `:openai`, which collides with the async
  # wire tests if they run concurrently.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ALLM.Error.EngineError
  alias ALLM.Message
  alias ALLM.Providers.OpenAI
  alias ALLM.Request
  alias ALLM.Tool

  setup do
    # Each test gets a clean Keys.Store so cross-test state doesn't leak.
    on_exit(fn -> ALLM.Keys.delete(:openai) end)
    :ok
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "gpt-4o-mini"], opts)
    )
  end

  # ---------------------------------------------------------------------------
  # translate_options/2
  # ---------------------------------------------------------------------------

  describe "translate_options/2 — :max_tokens rename" do
    test "renames to :max_completion_tokens for gpt-4o-mini" do
      assert OpenAI.translate_options([max_tokens: 100], req(model: "gpt-4o-mini")) ==
               [max_completion_tokens: 100]
    end

    test "renames to :max_completion_tokens for gpt-4.1-mini" do
      assert OpenAI.translate_options([max_tokens: 100], req(model: "gpt-4.1-mini")) ==
               [max_completion_tokens: 100]
    end

    test "passes through :max_tokens for gpt-3.5-turbo" do
      assert OpenAI.translate_options([max_tokens: 100], req(model: "gpt-3.5-turbo")) ==
               [max_tokens: 100]
    end

    test "leaves non-:max_tokens keys untouched on gpt-4o" do
      assert OpenAI.translate_options([temperature: 0.7], req(model: "gpt-4o")) ==
               [temperature: 0.7]
    end

    property "endpoint-aware rename: gpt-4o/gpt-4.1/gpt-5 chat models rename, others passthrough" do
      check all(
              prefix <-
                StreamData.member_of([
                  "gpt-3.5-turbo",
                  "gpt-4-turbo",
                  "gpt-4",
                  "gpt-4o",
                  "gpt-4o-mini",
                  "gpt-4.1",
                  "gpt-4.1-mini"
                ]),
              n <- StreamData.integer(1..4096),
              max_runs: 100
            ) do
        result = OpenAI.translate_options([max_tokens: n], req(model: prefix))

        if prefix in ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini"] do
          assert result == [max_completion_tokens: n]
        else
          assert result == [max_tokens: n]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # finish-reason mapping (via from_openai_response on synthetic bodies)
  # ---------------------------------------------------------------------------

  describe "finish_reason mapping (Chat Completions)" do
    for {wire, expected, raw_keep} <- [
          {"stop", :stop, nil},
          {"length", :length, nil},
          {"tool_calls", :tool_calls, nil},
          {"content_filter", :content_filter, nil},
          {"function_call", :tool_calls, "function_call"}
        ] do
      test "maps #{inspect(wire)} → #{inspect(expected)} (raw_finish_reason=#{inspect(raw_keep)})" do
        body = %{
          "id" => "x",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => unquote(wire)
            }
          ]
        }

        resp = OpenAI.from_openai_response(body, :chat_completions)
        assert resp.finish_reason == unquote(expected)
        assert resp.raw_finish_reason == unquote(raw_keep)
      end
    end

    test "nil finish_reason maps to nil (mid-stream chunk)" do
      body = %{"choices" => [%{"message" => %{"content" => "x"}, "finish_reason" => nil}]}
      assert OpenAI.from_openai_response(body, :chat_completions).finish_reason == nil
    end

    property "any unknown string maps to :other and preserves raw_finish_reason" do
      known = ~w(stop length tool_calls content_filter function_call)

      check all(
              s <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
              s not in known,
              max_runs: 100
            ) do
        body = %{"choices" => [%{"message" => %{"content" => "x"}, "finish_reason" => s}]}
        resp = OpenAI.from_openai_response(body, :chat_completions)
        assert resp.finish_reason == :other
        assert resp.raw_finish_reason == s
      end
    end
  end

  # ---------------------------------------------------------------------------
  # requires_structured_finalize?/1
  # ---------------------------------------------------------------------------

  describe "requires_structured_finalize?/1" do
    test "true when tools present AND response_format is json_schema" do
      tool = Tool.new(name: "t", description: "d", schema: %{})

      r =
        req(
          tools: [tool],
          response_format: %{type: :json_schema, name: "p", schema: %{}, strict: true}
        )

      assert OpenAI.requires_structured_finalize?(r)
    end

    test "false when tools present but response_format is :text" do
      tool = Tool.new(name: "t", description: "d", schema: %{})
      r = req(tools: [tool], response_format: :text)
      refute OpenAI.requires_structured_finalize?(r)
    end

    test "false when response_format is json_schema but no tools" do
      r = req(response_format: %{type: :json_schema, name: "p", schema: %{}, strict: true})
      refute OpenAI.requires_structured_finalize?(r)
    end

    test "false when response_format is json_object (no schema)" do
      tool = Tool.new(name: "t", description: "d", schema: %{})
      r = req(tools: [tool], response_format: %{type: :json_object})
      refute OpenAI.requires_structured_finalize?(r)
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch_endpoint/2
  # ---------------------------------------------------------------------------

  describe "dispatch_endpoint/2" do
    test "gpt-4* → :chat_completions" do
      assert OpenAI.dispatch_endpoint("gpt-4o", []) == :chat_completions
      assert OpenAI.dispatch_endpoint("gpt-4.1-mini", []) == :chat_completions
      assert OpenAI.dispatch_endpoint("gpt-4-turbo", []) == :chat_completions
    end

    test "gpt-3.5* → :chat_completions" do
      assert OpenAI.dispatch_endpoint("gpt-3.5-turbo", []) == :chat_completions
    end

    test "gpt-5* → :responses" do
      assert OpenAI.dispatch_endpoint("gpt-5", []) == :responses
      assert OpenAI.dispatch_endpoint("gpt-5.5", []) == :responses
    end

    test "o[1-9]* → :responses" do
      assert OpenAI.dispatch_endpoint("o1", []) == :responses
      assert OpenAI.dispatch_endpoint("o3", []) == :responses
      assert OpenAI.dispatch_endpoint("o9-preview", []) == :responses
    end

    test "unknown model → :chat_completions (default)" do
      assert OpenAI.dispatch_endpoint("claude-3-opus", []) == :chat_completions
      assert OpenAI.dispatch_endpoint("nonsense", []) == :chat_completions
    end

    test "nil model → :chat_completions (default)" do
      assert OpenAI.dispatch_endpoint(nil, []) == :chat_completions
    end

    test "explicit opts[:endpoint] wins" do
      assert OpenAI.dispatch_endpoint("gpt-4o", endpoint: :responses) == :responses
      assert OpenAI.dispatch_endpoint("gpt-5.5", endpoint: :chat_completions) == :chat_completions
    end

    test "explicit adapter_opts[:endpoint] wins (when opts[:endpoint] absent)" do
      assert OpenAI.dispatch_endpoint("gpt-4o", adapter_opts: [endpoint: :responses]) ==
               :responses

      assert OpenAI.dispatch_endpoint("gpt-5.5", adapter_opts: [endpoint: :chat_completions]) ==
               :chat_completions
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "returns %Req.Request{} with Bearer header when key is present" do
      ALLM.Keys.put(:openai, "sk-prep-test")
      assert {:ok, %Req.Request{} = http} = OpenAI.prepare_request(req(), [])
      assert Req.Request.get_header(http, "authorization") == ["Bearer sk-prep-test"]
      assert http.url.path == "/v1/chat/completions"
    end

    test "honors api_key opt over the env" do
      ALLM.Keys.put(:openai, "sk-env")
      assert {:ok, http} = OpenAI.prepare_request(req(), api_key: "sk-override")
      assert Req.Request.get_header(http, "authorization") == ["Bearer sk-override"]
    end

    test "raises EngineError{:missing_key} when no key is resolvable" do
      ALLM.Keys.delete(:openai)
      System.delete_env("OPENAI_API_KEY")

      assert_raise EngineError, fn ->
        OpenAI.prepare_request(req(), [])
      end
    end

    test "Phase 10.6: o-series models prepare a Responses-API request (no longer rejected)" do
      ALLM.Keys.put(:openai, "sk-x")
      assert {:ok, %Req.Request{} = http} = OpenAI.prepare_request(req(model: "o3"), [])
      assert http.url.path == "/v1/responses"
    end

    test "Phase 10.6: gpt-5* models prepare a Responses-API request" do
      ALLM.Keys.put(:openai, "sk-x")
      assert {:ok, %Req.Request{} = http} = OpenAI.prepare_request(req(model: "gpt-5.5"), [])
      assert http.url.path == "/v1/responses"
    end

    test "passes openai-organization header when adapter_opts[:organization] set" do
      ALLM.Keys.put(:openai, "sk-x")
      assert {:ok, http} = OpenAI.prepare_request(req(), adapter_opts: [organization: "org-42"])
      assert Req.Request.get_header(http, "openai-organization") == ["org-42"]
    end
  end

  # ---------------------------------------------------------------------------
  # to_openai_request_body / message + tool encoding (unit-level coverage)
  # ---------------------------------------------------------------------------

  describe "to_openai_request_body/3 (chat_completions)" do
    test "encodes a tool-role message with tool_call_id" do
      msg = %Message{role: :tool, content: "ok", tool_call_id: "call_x"}
      r = Request.new([msg], model: "gpt-4o")
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert [m] = body["messages"]
      assert m == %{"role" => "tool", "content" => "ok", "tool_call_id" => "call_x"}
    end

    test "encodes assistant message with tool_calls metadata" do
      tc = ALLM.ToolCall.new(id: "c1", name: "weather", arguments: %{"city" => "B"})

      msg = %Message{
        role: :assistant,
        content: "",
        metadata: %{tool_calls: [tc]}
      }

      r = Request.new([msg], model: "gpt-4o")
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert [m] = body["messages"]
      assert [tc_wire] = m["tool_calls"]
      assert tc_wire["id"] == "c1"
      assert tc_wire["function"]["name"] == "weather"
      assert tc_wire["function"]["arguments"] =~ "city"
    end

    test "encodes tools list from request.tools" do
      tool = Tool.new(name: "weather", description: "Weather", schema: %{"type" => "object"})
      r = req(model: "gpt-4o", tools: [tool])
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert [t] = body["tools"]
      assert t["type"] == "function"
      assert t["function"]["name"] == "weather"
    end

    test "encodes tool_choice variants" do
      r_auto = req(tool_choice: :auto)
      r_none = req(tool_choice: :none)
      r_required = req(tool_choice: :required)
      r_named = req(tool_choice: "weather")

      assert OpenAI.to_openai_request_body(r_auto, :chat_completions, [])["tool_choice"] == "auto"
      assert OpenAI.to_openai_request_body(r_none, :chat_completions, [])["tool_choice"] == "none"

      assert OpenAI.to_openai_request_body(r_required, :chat_completions, [])["tool_choice"] ==
               "required"

      named = OpenAI.to_openai_request_body(r_named, :chat_completions, [])["tool_choice"]
      assert named == %{"type" => "function", "function" => %{"name" => "weather"}}
    end

    test "explicit map tool_choice passes through" do
      explicit = %{"type" => "function", "function" => %{"name" => "x"}}
      body = OpenAI.to_openai_request_body(req(tool_choice: explicit), :chat_completions, [])
      assert body["tool_choice"] == explicit
    end

    test "max_tokens is renamed and emitted in body" do
      r = req(model: "gpt-4o", max_tokens: 256)
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert body["max_completion_tokens"] == 256
      refute Map.has_key?(body, "max_tokens")
    end

    test "stringifies request.options atom keys" do
      r = req(options: %{temperature_extra: 0.1})
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert body["temperature_extra"] == 0.1
    end
  end

  # ---------------------------------------------------------------------------
  # to_openai_response_format/2 — Phase 10.2 only handles nil/text
  # ---------------------------------------------------------------------------

  describe "to_openai_response_format/2 (Phase 10.4 — endpoint-aware translation)" do
    test "nil returns nil for both endpoints (omit on the wire)" do
      assert OpenAI.to_openai_response_format(:chat_completions, nil) == nil
      assert OpenAI.to_openai_response_format(:responses, nil) == nil
    end

    test ":text omits on chat_completions, emits text/format on responses" do
      assert OpenAI.to_openai_response_format(:chat_completions, :text) == nil

      assert OpenAI.to_openai_response_format(:responses, :text) ==
               {:text, %{format: %{type: "text"}}}
    end

    test "json_object encodes to response_format on chat_completions, text on responses" do
      assert OpenAI.to_openai_response_format(:chat_completions, %{type: :json_object}) ==
               {:response_format, %{type: "json_object"}}

      assert OpenAI.to_openai_response_format(:responses, %{type: :json_object}) ==
               {:text, %{format: %{type: "json_object"}}}
    end

    test "json_schema encodes with json_schema sub-map on chat_completions" do
      rf = %{type: :json_schema, name: "greeting", schema: %{type: "object"}, strict: true}

      assert OpenAI.to_openai_response_format(:chat_completions, rf) ==
               {:response_format,
                %{
                  type: "json_schema",
                  json_schema: %{name: "greeting", schema: %{type: "object"}, strict: true}
                }}
    end

    test "json_schema encodes with flat fields on responses" do
      rf = %{type: :json_schema, name: "greeting", schema: %{type: "object"}, strict: true}

      assert OpenAI.to_openai_response_format(:responses, rf) ==
               {:text,
                %{
                  format: %{
                    type: "json_schema",
                    name: "greeting",
                    schema: %{type: "object"},
                    strict: true
                  }
                }}
    end

    test "unknown canonical shape raises FunctionClauseError (defense in depth)" do
      assert_raise FunctionClauseError, fn ->
        OpenAI.to_openai_response_format(:chat_completions, %{type: :unknown})
      end
    end

    test "every canonical shape JSON-encodes for both endpoints" do
      schema = %{type: "object", properties: %{a: %{type: "string"}}}

      shapes = [
        nil,
        :text,
        %{type: :json_object},
        %{type: :json_schema, name: "x", schema: schema, strict: true}
      ]

      for endpoint <- [:chat_completions, :responses], shape <- shapes do
        case OpenAI.to_openai_response_format(endpoint, shape) do
          nil ->
            :ok

          {key, value} ->
            assert is_atom(key)
            assert is_binary(Jason.encode!(%{key => value}))
        end
      end
    end

    test "body composition merges the wire key into the request body" do
      rf = %{type: :json_schema, name: "g", schema: %{type: "object"}, strict: true}

      req =
        ALLM.Request.new(
          [%ALLM.Message{role: :user, content: "x"}],
          model: "gpt-4o-mini",
          response_format: rf
        )

      body = OpenAI.to_openai_request_body(req, :chat_completions, [])

      assert body["response_format"] == %{
               type: "json_schema",
               json_schema: %{name: "g", schema: %{type: "object"}, strict: true}
             }
    end

    test "body composition omits the field when canonical shape returns nil" do
      req =
        ALLM.Request.new(
          [%ALLM.Message{role: :user, content: "x"}],
          model: "gpt-4o-mini",
          response_format: nil
        )

      body = OpenAI.to_openai_request_body(req, :chat_completions, [])

      refute Map.has_key?(body, "response_format")
    end
  end

  # ---------------------------------------------------------------------------
  # from_openai_error/3 — error classification
  # ---------------------------------------------------------------------------

  describe "from_openai_error/3" do
    test "401 → :authentication_failed regardless of body" do
      err = OpenAI.from_openai_error(401, %{}, [])
      assert err.reason == :authentication_failed
      assert err.status == 401
    end

    test "403 → :authentication_failed" do
      err = OpenAI.from_openai_error(403, %{"error" => %{"message" => "forbidden"}}, [])
      assert err.reason == :authentication_failed
    end

    test "429 → :rate_limited and Retry-After parsed from headers" do
      err = OpenAI.from_openai_error(429, %{}, [{"retry-after", "5"}])
      assert err.reason == :rate_limited
      assert err.retry_after_ms == 5_000
    end

    test "400 with code: context_length_exceeded → :context_length_exceeded" do
      body = %{"error" => %{"code" => "context_length_exceeded", "message" => "too long"}}
      err = OpenAI.from_openai_error(400, body, [])
      assert err.reason == :context_length_exceeded
    end

    test "400 with type: content_filter → :content_filter" do
      body = %{"error" => %{"type" => "content_filter", "message" => "policy"}}
      err = OpenAI.from_openai_error(400, body, [])
      assert err.reason == :content_filter
    end

    test "400 with type containing 'content_filter' → :content_filter" do
      body = %{"error" => %{"type" => "openai/content_filter_block", "message" => "p"}}
      err = OpenAI.from_openai_error(400, body, [])
      assert err.reason == :content_filter
    end

    test "400 generic → :invalid_request" do
      err = OpenAI.from_openai_error(400, %{"error" => %{"message" => "bad"}}, [])
      assert err.reason == :invalid_request
    end

    test "5xx statuses → :provider_unavailable" do
      for status <- [500, 502, 503, 504] do
        err = OpenAI.from_openai_error(status, %{}, [])
        assert err.reason == :provider_unavailable, "wrong reason for #{status}"
      end
    end

    test "unrecognized status → :unknown" do
      err = OpenAI.from_openai_error(418, %{}, [])
      assert err.reason == :unknown
    end

    test "Retry-After in map-shaped headers parses too" do
      err = OpenAI.from_openai_error(429, %{}, %{"retry-after" => "3"})
      assert err.retry_after_ms == 3_000
    end

    test "unparseable Retry-After yields nil retry_after_ms" do
      err = OpenAI.from_openai_error(429, %{}, [{"retry-after", "tomorrow-please"}])
      assert err.retry_after_ms == nil
    end
  end

  # ---------------------------------------------------------------------------
  # from_openai_response/2 — Chat Completions decoder
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # generate/2 — direct paths that don't need a wire stub
  # ---------------------------------------------------------------------------

  describe "generate/2 (no HTTP)" do
    test "passes :request_timeout through to Req.merge" do
      # Smoke-test that the `request_timeout:` opt threads through
      # `prepare_request/2` without raising. Actual timeout enforcement is
      # exercised by the wire test suite via stubs.
      ALLM.Keys.put(:openai, "sk-x")
      assert {:ok, http} = OpenAI.prepare_request(req(), request_timeout: 5_000)
      assert http.options[:receive_timeout] == 5_000
    end
  end

  describe "from_openai_response/2 (chat_completions)" do
    test "populates id, model, output_text, finish_reason, usage" do
      body = %{
        "id" => "chatcmpl-xyz",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "hello"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
      }

      resp = OpenAI.from_openai_response(body, :chat_completions)
      assert resp.id == "chatcmpl-xyz"
      assert resp.model == "gpt-4o"
      assert resp.output_text == "hello"
      assert resp.finish_reason == :stop
      assert resp.usage.input_tokens == 5
      assert resp.usage.output_tokens == 7
      assert resp.usage.total_tokens == 12
    end

    test "decodes single tool_call" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{
                    "name" => "weather",
                    "arguments" => ~s({"city":"B"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      resp = OpenAI.from_openai_response(body, :chat_completions)
      assert [tc] = resp.tool_calls
      assert tc.id == "c1"
      assert tc.name == "weather"
      assert tc.arguments == %{"city" => "B"}
      assert tc.raw_arguments == ~s({"city":"B"})
    end

    test "decode_usage handles empty/missing usage map" do
      body = %{"choices" => [%{"message" => %{"content" => "x"}, "finish_reason" => "stop"}]}
      resp = OpenAI.from_openai_response(body, :chat_completions)
      assert resp.usage.input_tokens == nil
      assert resp.usage.output_tokens == nil
    end

    test "tool_calls metadata absent for assistant with no tool_calls" do
      body = %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "x"}, "finish_reason" => "stop"}
        ]
      }

      resp = OpenAI.from_openai_response(body, :chat_completions)
      assert resp.message.metadata == %{}
    end

    test "Phase 10.6: populates Usage.reasoning_tokens from completion_tokens_details" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15,
          "completion_tokens_details" => %{"reasoning_tokens" => 30}
        }
      }

      resp = OpenAI.from_openai_response(body, :chat_completions)
      assert resp.usage.reasoning_tokens == 30
    end

    test "tool_call with malformed JSON arguments → arguments: %{}" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "function" => %{"name" => "x", "arguments" => "not json{{{"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      resp = OpenAI.from_openai_response(body, :chat_completions)
      [tc] = resp.tool_calls
      assert tc.arguments == %{}
      assert tc.raw_arguments == "not json{{{"
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.6 — reasoning controls in translate_options/2
  # ---------------------------------------------------------------------------

  describe "translate_options/2 — reasoning controls (Phase 10.6)" do
    test ":reasoning_effort on :responses → reasoning: %{effort: ...}" do
      assert OpenAI.translate_options([reasoning_effort: :medium], req(model: "gpt-5.5")) ==
               [reasoning: %{effort: "medium"}]
    end

    test ":reasoning_effort + :reasoning_summary on :responses share one reasoning sub-map" do
      assert OpenAI.translate_options(
               [reasoning_effort: :medium, reasoning_summary: :concise],
               req(model: "gpt-5.5")
             ) == [reasoning: %{effort: "medium", summary: "concise"}]
    end

    test ":verbosity on :responses → bare verbosity wire key" do
      assert OpenAI.translate_options([verbosity: :low], req(model: "gpt-5.5")) ==
               [verbosity: "low"]
    end

    test ":reasoning_effort on :chat_completions for gpt-5* → bare reasoning_effort key" do
      result =
        OpenAI.translate_options(
          [reasoning_effort: :medium, endpoint: :chat_completions],
          req(model: "gpt-5")
        )

      # `:endpoint` itself is a non-translated opt that survives passthrough.
      assert {:reasoning_effort, "medium"} in result
    end

    test ":verbosity on :chat_completions for gpt-5* → bare verbosity wire key" do
      result =
        OpenAI.translate_options(
          [verbosity: :high, endpoint: :chat_completions],
          req(model: "gpt-5")
        )

      assert {:verbosity, "high"} in result
    end

    test ":reasoning_effort on non-reasoning chat-completions model → silently stripped" do
      import ExUnit.CaptureLog

      log =
        capture_log([level: :debug], fn ->
          assert OpenAI.translate_options(
                   [reasoning_effort: :medium],
                   req(model: "gpt-4.1-mini")
                 ) == []
        end)

      assert log =~ "reasoning controls ignored"
    end

    test "illegal reasoning_effort raises ArgumentError" do
      assert_raise ArgumentError, ~r/reasoning_effort/, fn ->
        OpenAI.translate_options([reasoning_effort: :illegal], req(model: "gpt-5.5"))
      end
    end

    test "illegal reasoning_summary raises ArgumentError" do
      assert_raise ArgumentError, ~r/reasoning_summary/, fn ->
        OpenAI.translate_options([reasoning_summary: :illegal], req(model: "gpt-5.5"))
      end
    end

    test "illegal verbosity raises ArgumentError" do
      assert_raise ArgumentError, ~r/verbosity/, fn ->
        OpenAI.translate_options([verbosity: :illegal], req(model: "gpt-5.5"))
      end
    end

    test ":max_tokens on :responses → :max_output_tokens" do
      assert OpenAI.translate_options([max_tokens: 200], req(model: "gpt-5.5")) ==
               [max_output_tokens: 200]
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.6 — Responses-API decoder
  # ---------------------------------------------------------------------------

  describe "from_responses_response/2" do
    test "status: completed → finish_reason :stop, output_text passthrough" do
      body = %{
        "id" => "resp_x",
        "model" => "gpt-5.5",
        "status" => "completed",
        "output_text" => "hi",
        "usage" => %{
          "input_tokens" => 5,
          "output_tokens" => 1,
          "output_tokens_details" => %{"reasoning_tokens" => 42},
          "total_tokens" => 6
        }
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp.id == "resp_x"
      assert resp.output_text == "hi"
      assert resp.finish_reason == :stop
      assert resp.usage.reasoning_tokens == 42
      assert resp.usage.input_tokens == 5
      assert resp.usage.output_tokens == 1
    end

    test "status: incomplete + max_output_tokens → :length + metadata.incomplete_details" do
      body = %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "output_text" => "",
        "usage" => %{
          "input_tokens" => 5,
          "output_tokens" => 1024,
          "output_tokens_details" => %{"reasoning_tokens" => 1024},
          "total_tokens" => 1029
        }
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp.finish_reason == :length
      assert resp.metadata.incomplete_details.reason == "max_output_tokens"
      assert resp.usage.reasoning_tokens == 1024
    end

    test "status: incomplete + content_filter → :content_filter" do
      body = %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "content_filter"},
        "output_text" => ""
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp.finish_reason == :content_filter
      assert resp.metadata.incomplete_details.reason == "content_filter"
    end

    test "status: incomplete + unknown reason → :other (raw preserved)" do
      body = %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "stranger_things"},
        "output_text" => ""
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp.finish_reason == :other
      assert resp.raw_finish_reason == "stranger_things"
      assert resp.metadata.incomplete_details.reason == "stranger_things"
    end

    test "reasoning block populates metadata.reasoning" do
      body = %{
        "status" => "completed",
        "output_text" => "ok",
        "reasoning" => %{"effort" => "medium", "summary" => "thought hard"}
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp.metadata.reasoning == %{effort: "medium", summary: "thought hard"}
    end

    test "Response.metadata.reasoning round-trips through term_to_binary" do
      body = %{
        "status" => "completed",
        "output_text" => "ok",
        "reasoning" => %{"effort" => "high", "summary" => "x"}
      }

      resp = OpenAI.from_responses_response(body, [])
      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    # Bug #5 (Phase 10 retro): the Responses-API decoder previously
    # hard-coded `tool_calls: []` and never inspected `output[]` for
    # `function_call` items. These three rows lock the fix in.
    test "single function_call in output[] → tool_calls populated, finish_reason :tool_calls" do
      body = ALLM.Providers.OpenAITestFixtures.responses(:single_tool_call)
      resp = OpenAI.from_responses_response(body, [])

      assert [tc] = resp.tool_calls
      assert tc.id == "call_yyy"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Boston"}
      assert tc.raw_arguments == ~s({"city":"Boston"})

      assert resp.finish_reason == :tool_calls
      assert resp.message.metadata.tool_calls == [tc]
    end

    test "parallel function_calls in output[] → both surface with IDs preserved" do
      body = ALLM.Providers.OpenAITestFixtures.responses(:parallel_tool_calls)
      resp = OpenAI.from_responses_response(body, [])

      ids = resp.tool_calls |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["call_a", "call_b"]

      by_id = Map.new(resp.tool_calls, &{&1.id, &1})
      assert by_id["call_a"].name == "get_weather"
      assert by_id["call_a"].arguments == %{"city" => "Boston"}
      assert by_id["call_b"].name == "get_time"
      assert by_id["call_b"].arguments == %{"tz" => "UTC"}

      assert resp.finish_reason == :tool_calls
    end

    test "mixed function_call + message item → tool_calls populated AND output_text intact" do
      body = ALLM.Providers.OpenAITestFixtures.responses(:mixed_tool_and_message)
      resp = OpenAI.from_responses_response(body, [])

      assert resp.output_text == "calling weather"
      assert [tc] = resp.tool_calls
      assert tc.id == "call_mix"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Boston"}
      assert resp.finish_reason == :tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.6 — Responses request body shape
  # ---------------------------------------------------------------------------

  describe "to_openai_request_body/3 (:responses)" do
    test "uses :input array (not :messages)" do
      r = req(model: "gpt-5.5")
      body = OpenAI.to_openai_request_body(r, :responses, [])
      assert is_list(body["input"])
      refute Map.has_key?(body, "messages")
    end

    test "system message encodes as {role: system, content}" do
      msgs = [
        %Message{role: :system, content: "be brief"},
        %Message{role: :user, content: "hi"}
      ]

      r = Request.new(msgs, model: "gpt-5.5")
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert [sys, usr] = body["input"]
      assert sys == %{"role" => "system", "content" => "be brief"}
      assert usr == %{"role" => "user", "content" => "hi"}
    end

    test "max_tokens renames to max_output_tokens" do
      r = req(model: "gpt-5.5", max_tokens: 200)
      body = OpenAI.to_openai_request_body(r, :responses, [])
      assert body["max_output_tokens"] == 200
      refute Map.has_key?(body, "max_tokens")
    end

    test "reasoning controls from opts merge into body" do
      r = req(model: "gpt-5.5")

      body =
        OpenAI.to_openai_request_body(r, :responses, reasoning_effort: :medium, verbosity: :low)

      assert body["reasoning"] == %{effort: "medium"}
      assert body["verbosity"] == "low"
    end

    test "tools encode with flat top-level name (not nested function:)" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Return weather for a city.",
          schema: %{"type" => "object"}
        )

      r = req(model: "gpt-5.5", tools: [tool])
      body = OpenAI.to_openai_request_body(r, :responses, [])
      assert [t] = body["tools"]
      assert t["type"] == "function"
      assert t["name"] == "get_weather"
      assert t["description"] == "Return weather for a city."
      assert t["parameters"] == %{"type" => "object"}
      refute Map.has_key?(t, "function")
    end

    test "named tool_choice (binary) uses flat shape on responses" do
      r = req(model: "gpt-5.5", tool_choice: "weather")
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert body["tool_choice"] == %{
               "type" => "function",
               "name" => "weather"
             }
    end

    test "tool-role message encodes as function_call_output input item (Bug #5 round-trip)" do
      msg = %Message{role: :tool, content: ~s({"forecast":"sunny"}), tool_call_id: "call_xyz"}
      r = Request.new([msg], model: "gpt-5.4-nano")
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert [item] = body["input"]

      assert item == %{
               "type" => "function_call_output",
               "call_id" => "call_xyz",
               "output" => ~s({"forecast":"sunny"})
             }
    end

    test "assistant message with tool_calls metadata encodes as function_call input items (Bug #5 round-trip)" do
      tc = ALLM.ToolCall.new(id: "call_w", name: "get_weather", arguments: %{"city" => "Boston"})

      msg = %Message{
        role: :assistant,
        content: "",
        metadata: %{tool_calls: [tc]}
      }

      r = Request.new([msg], model: "gpt-5.4-nano")
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert [item] = body["input"]
      assert item["type"] == "function_call"
      assert item["call_id"] == "call_w"
      assert item["name"] == "get_weather"
      assert item["arguments"] =~ "Boston"
    end

    test "assistant text + tool_calls splits into a message item AND function_call items" do
      tc = ALLM.ToolCall.new(id: "call_w", name: "get_weather", arguments: %{"city" => "Boston"})

      msg = %Message{
        role: :assistant,
        content: "calling weather",
        metadata: %{tool_calls: [tc]}
      }

      r = Request.new([msg], model: "gpt-5.4-nano")
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert [text_item, call_item] = body["input"]
      assert text_item == %{"role" => "assistant", "content" => "calling weather"}
      assert call_item["type"] == "function_call"
      assert call_item["call_id"] == "call_w"
    end

    test "{:tool, name} tool_choice uses flat shape on responses" do
      r = req(model: "gpt-5.5", tool_choice: {:tool, "weather"})
      body = OpenAI.to_openai_request_body(r, :responses, [])

      assert body["tool_choice"] == %{
               "type" => "function",
               "name" => "weather"
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.5 retro — Bug fixes for endpoint-aware translation
  # ---------------------------------------------------------------------------

  describe "tool envelope endpoint dispatch (Bug #2)" do
    test "tools nest under function: on chat_completions (legacy wire)" do
      tool =
        Tool.new(
          name: "weather",
          description: "Get weather",
          schema: %{"type" => "object"}
        )

      r = req(model: "gpt-4o", tools: [tool])
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])
      assert [t] = body["tools"]
      assert t["type"] == "function"
      assert t["function"]["name"] == "weather"
      assert t["function"]["parameters"] == %{"type" => "object"}
      refute Map.has_key?(t, "name")
    end
  end

  describe "merge_reasoning_opts threads endpoint override (Bug #3)" do
    test "explicit chat_completions on gpt-5.5 emits bare reasoning_effort (not nested map)" do
      r = req(model: "gpt-5.5")

      # Caller forced :chat_completions via adapter_opts (Engine threads
      # adapter_opts into the opts kwlist as `:adapter_opts` AND the
      # endpoint resolver picks it up). The body builder receives the
      # already-resolved `:chat_completions` endpoint, so reasoning opts
      # must use the bare `reasoning_effort:` key (not the Responses
      # `reasoning: %{effort: ...}` sub-map).
      body =
        OpenAI.to_openai_request_body(
          r,
          :chat_completions,
          reasoning_effort: :low,
          adapter_opts: [endpoint: :chat_completions]
        )

      assert body["reasoning_effort"] == "low"
      refute Map.has_key?(body, "reasoning")
    end

    test "responses endpoint on gpt-5.5 still emits the reasoning sub-map" do
      r = req(model: "gpt-5.5")

      body =
        OpenAI.to_openai_request_body(r, :responses, reasoning_effort: :low)

      assert body["reasoning"] == %{effort: "low"}
      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  describe "tool_choice {:tool, name} tuple form (Bug #4)" do
    test "{:tool, name} encodes nested function: on chat_completions" do
      r = req(tool_choice: {:tool, "get_weather"})
      body = OpenAI.to_openai_request_body(r, :chat_completions, [])

      assert body["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "get_weather"}
             }
    end
  end

  describe "@effort_atoms (Bug #1) — :minimal removed" do
    test ":minimal raises ArgumentError on translate_options" do
      assert_raise ArgumentError, ~r/reasoning_effort/, fn ->
        OpenAI.translate_options([reasoning_effort: :minimal], req(model: "gpt-5.5"))
      end
    end

    test ":none, :low, :medium, :high, :xhigh all accepted" do
      for effort <- [:none, :low, :medium, :high, :xhigh] do
        result = OpenAI.translate_options([reasoning_effort: effort], req(model: "gpt-5.5"))
        assert result == [reasoning: %{effort: Atom.to_string(effort)}]
      end
    end
  end
end
