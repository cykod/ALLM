defmodule ALLM.Providers.AnthropicTest do
  @moduledoc """
  Phase 11.1 unit tests for `ALLM.Providers.Anthropic` helpers.

  Covers:

    * `extract_system/1` — zero / one / many system messages, the `\\n\\n`
      join (Decision #1), and a property over arbitrary system-content lists.
    * `to_anthropic_messages/1` — role mapping; tool-result encoding into
      Anthropic's content-blocks `tool_result` shape.
    * `to_anthropic_tools/1` — `name`/`description`/`input_schema` rename.
    * `to_anthropic_tool_choice/1` — six canonical → wire shapes per
      Decision #3, including the `:required → "any"` rename and the
      `{:omit}` / `{:set, _}` sentinel contract; rejects unknown shapes
      with `ArgumentError`.
    * `to_anthropic_request_body/1` — system extraction round-trip;
      forced-choice + empty-tools defense-in-depth raise.
    * `inject_structured_output_tool/2` — Decision #4 tool-forcing
      injection: `:json_schema → tool + tool_choice` injected; `nil` and
      `:json_object` are no-ops; multi-turn (synthetic already called)
      suppresses re-injection.
    * `lift_structured_output/1` — Decision #4 lift: single synthetic
      tool call → `output_text = Jason.encode!(args)`,
      `finish_reason: :stop`, `tool_calls: []`, `metadata.structured_output_tool: true`;
      every other shape unchanged.
    * Synthetic / user-tool collision row: a request with a user-defined
      tool literally named `respond_with_json_<name>` co-exists with the
      synthetic tool in the wire body (both entries appear).
    * Stop-reason mapping — every documented Anthropic string + a property
      over arbitrary unknowns.
    * `requires_structured_finalize?/1` — always `false`.
    * `prepare_request/2` — `x-api-key` and `anthropic-version` headers
      threaded; `EngineError{:missing_key}` on missing key.
    * `translate_options/2` — identity (Decision #7).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  doctest ALLM.Providers.Anthropic

  alias ALLM.Error.AdapterError
  alias ALLM.Error.EngineError
  alias ALLM.Message
  alias ALLM.Providers.Anthropic
  alias ALLM.Providers.AnthropicTestFixtures, as: Fx
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.FinchStub
  alias ALLM.Tool
  alias ALLM.ToolCall

  setup do
    on_exit(fn -> ALLM.Keys.delete(:anthropic) end)
    :ok
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "claude-sonnet-4-6"], opts)
    )
  end

  # ---------------------------------------------------------------------------
  # extract_system/1 (Decision #1)
  # ---------------------------------------------------------------------------

  describe "extract_system/1" do
    test "no system messages → {nil, original_messages}" do
      msgs = [%Message{role: :user, content: "x"}, %Message{role: :assistant, content: "y"}]
      assert {nil, ^msgs} = Anthropic.extract_system(msgs)
    end

    test "one system message → {system_text, [non_system_messages]}" do
      msgs = [
        %Message{role: :system, content: "be brief"},
        %Message{role: :user, content: "hi"}
      ]

      assert {"be brief", [%Message{role: :user, content: "hi"}]} =
               Anthropic.extract_system(msgs)
    end

    test "three system messages → joined with \"\\n\\n\"" do
      msgs = [
        %Message{role: :system, content: "a"},
        %Message{role: :system, content: "b"},
        %Message{role: :system, content: "c"},
        %Message{role: :user, content: "hi"}
      ]

      assert {"a\n\nb\n\nc", [%Message{role: :user}]} = Anthropic.extract_system(msgs)
    end

    property "join is Enum.map_join(systems, \"\\n\\n\", & &1.content)" do
      check all(
              parts <-
                StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 50
            ) do
        msgs = Enum.map(parts, &%Message{role: :system, content: &1})
        msgs = msgs ++ [%Message{role: :user, content: "user"}]

        assert {sys, [%Message{role: :user}]} = Anthropic.extract_system(msgs)
        assert sys == Enum.join(parts, "\n\n")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # to_anthropic_messages/1
  # ---------------------------------------------------------------------------

  describe "to_anthropic_messages/1" do
    test "user message → %{role: \"user\", content: text}" do
      assert [%{"role" => "user", "content" => "hi"}] =
               Anthropic.to_anthropic_messages([%Message{role: :user, content: "hi"}])
    end

    test "assistant message (no tool_calls) → %{role: \"assistant\", content: text}" do
      assert [%{"role" => "assistant", "content" => "ok"}] =
               Anthropic.to_anthropic_messages([%Message{role: :assistant, content: "ok"}])
    end

    test "tool-result message → user-role with content-blocks tool_result entry" do
      msg = %Message{role: :tool, content: "weather is sunny", tool_call_id: "toolu_abc"}
      assert [m] = Anthropic.to_anthropic_messages([msg])
      assert m["role"] == "user"

      assert m["content"] == [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_abc",
                 "content" => "weather is sunny"
               }
             ]
    end

    test "assistant message with tool_calls metadata → assistant content-blocks" do
      tc = ToolCall.new(id: "toolu_x", name: "weather", arguments: %{"city" => "B"})
      msg = %Message{role: :assistant, content: "", metadata: %{tool_calls: [tc]}}
      assert [m] = Anthropic.to_anthropic_messages([msg])
      assert m["role"] == "assistant"

      assert [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_x",
                 "name" => "weather",
                 "input" => %{"city" => "B"}
               }
             ] = m["content"]
    end
  end

  # ---------------------------------------------------------------------------
  # to_anthropic_tools/1
  # ---------------------------------------------------------------------------

  describe "to_anthropic_tools/1" do
    test "renames :schema → \"input_schema\"" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Weather by city",
          schema: %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}
        )

      assert [w] = Anthropic.to_anthropic_tools([tool])
      assert w["name"] == "get_weather"
      assert w["description"] == "Weather by city"
      assert w["input_schema"]["type"] == "object"
    end
  end

  # ---------------------------------------------------------------------------
  # to_anthropic_tool_choice/1 (Decision #3)
  # ---------------------------------------------------------------------------

  describe "to_anthropic_tool_choice/1" do
    test "nil → {:omit}" do
      assert Anthropic.to_anthropic_tool_choice(nil) == {:omit}
    end

    test ":auto → {:omit}" do
      assert Anthropic.to_anthropic_tool_choice(:auto) == {:omit}
    end

    test ":none → {:set, %{type: \"none\"}}" do
      assert Anthropic.to_anthropic_tool_choice(:none) == {:set, %{"type" => "none"}}
    end

    test ":required → {:set, %{type: \"any\"}} (renamed)" do
      assert Anthropic.to_anthropic_tool_choice(:required) == {:set, %{"type" => "any"}}
    end

    test ~s(string "<name>" → {:set, %{type: "tool", name: ...}}) do
      assert Anthropic.to_anthropic_tool_choice("get_weather") ==
               {:set, %{"type" => "tool", "name" => "get_weather"}}
    end

    test ~s(passthrough %{type: "auto"|"any"|"none"|"tool"}) do
      for t <- ["auto", "any", "none"] do
        m = %{"type" => t}
        assert Anthropic.to_anthropic_tool_choice(m) == {:set, m}
      end

      m = %{"type" => "tool", "name" => "x"}
      assert Anthropic.to_anthropic_tool_choice(m) == {:set, m}
    end

    test "passthrough atom-keyed %{type: ...}" do
      for t <- ["auto", "any", "none"] do
        m = %{type: t}
        assert Anthropic.to_anthropic_tool_choice(m) == {:set, m}
      end
    end

    test "unknown shape raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Anthropic.to_anthropic_tool_choice(%{"type" => "unknown"})
      end

      assert_raise ArgumentError, fn -> Anthropic.to_anthropic_tool_choice(:bogus) end
      assert_raise ArgumentError, fn -> Anthropic.to_anthropic_tool_choice(123) end
    end
  end

  # ---------------------------------------------------------------------------
  # to_anthropic_request_body/1
  # ---------------------------------------------------------------------------

  describe "to_anthropic_request_body/1" do
    test "with tool_choice :auto, tools [] → no tool_choice field" do
      r = req(tool_choice: :auto, tools: [])
      body = Anthropic.to_anthropic_request_body(r)
      refute Map.has_key?(body, "tool_choice")
    end

    test "with tool_choice :required, tools [] → raises ArgumentError" do
      r = req(tool_choice: :required, tools: [])

      assert_raise ArgumentError, ~r/requires non-empty tools/, fn ->
        Anthropic.to_anthropic_request_body(r)
      end
    end

    test ~s(with tool_choice "<name>", tools [] → raises ArgumentError) do
      r = req(tool_choice: "weather", tools: [])

      assert_raise ArgumentError, ~r/requires non-empty tools/, fn ->
        Anthropic.to_anthropic_request_body(r)
      end
    end

    test "system extraction round-trip: system message → top-level system field" do
      r =
        Request.new(
          [
            %Message{role: :system, content: "be brief"},
            %Message{role: :user, content: "hi"}
          ],
          model: "claude-sonnet-4-6"
        )

      body = Anthropic.to_anthropic_request_body(r)
      assert body["system"] == "be brief"
      assert [%{"role" => "user", "content" => "hi"}] = body["messages"]
    end

    test "max_tokens defaults to 1024 when nil (Anthropic requires it)" do
      r = req(max_tokens: nil)
      body = Anthropic.to_anthropic_request_body(r)
      assert body["max_tokens"] == 1024
    end

    test "max_tokens passes through when set" do
      r = req(max_tokens: 256)
      body = Anthropic.to_anthropic_request_body(r)
      assert body["max_tokens"] == 256
    end

    test "tools list is mapped to Anthropic shape" do
      tool = Tool.new(name: "get_weather", description: "w", schema: %{"type" => "object"})
      r = req(tools: [tool])
      body = Anthropic.to_anthropic_request_body(r)
      assert [%{"name" => "get_weather", "input_schema" => _}] = body["tools"]
    end

    test "structured output keeps user tools and never forces tool_choice" do
      # Claude Opus 5.5 / Sonnet 5.5 / Fable 5.1 400 on a forced tool_choice,
      # so structured output must not add one (or a synthetic tool).
      user_tool = Tool.new(name: "weather", description: "w", schema: %{"type" => "object"})

      r =
        req(
          tools: [user_tool],
          response_format: %{
            type: :json_schema,
            name: "person",
            schema: %{"type" => "object"},
            strict: true
          }
        )

      body = Anthropic.to_anthropic_request_body(r)
      assert Enum.map(body["tools"], & &1["name"]) == ["weather"]
      refute Map.has_key?(body, "tool_choice")
      assert body["output_config"]["format"]["type"] == "json_schema"
    end

    test "response_format :json_schema → native output_config.format" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      r = req(response_format: %{type: :json_schema, name: "person", schema: schema, strict: true})
      body = Anthropic.to_anthropic_request_body(r)

      assert body["output_config"] == %{
               "format" => %{
                 "type" => "json_schema",
                 "schema" => Map.put(schema, "additionalProperties", false)
               }
             }

      refute Map.has_key?(body, "tools")
    end

    test "output_config.format merges into a caller-supplied output_config" do
      r =
        req(
          options: %{output_config: %{effort: "low"}},
          response_format: %{type: :json_schema, name: "p", schema: %{"type" => "object"}}
        )

      body = Anthropic.to_anthropic_request_body(r)
      assert body["output_config"][:effort] == "low"
      assert body["output_config"]["format"]["type"] == "json_schema"
    end

    test "response_format nil / :json_object → no output_config" do
      refute Map.has_key?(Anthropic.to_anthropic_request_body(req()), "output_config")

      body = Anthropic.to_anthropic_request_body(req(response_format: %{type: :json_object}))
      refute Map.has_key?(body, "output_config")
    end
  end

  # ---------------------------------------------------------------------------
  # to_anthropic_json_schema/1 — schemas the native format accepts
  # ---------------------------------------------------------------------------

  describe "to_anthropic_json_schema/1" do
    test "closes every nested object, stringifies atom keys" do
      schema = %{
        type: "object",
        properties: %{
          tags: %{type: "array", items: %{type: "object", properties: %{k: %{type: "string"}}}},
          maybe: %{anyOf: [%{type: "object", properties: %{}}, %{type: "null"}]},
          ref: %{"$ref" => "#/$defs/thing"}
        },
        "$defs": %{thing: %{type: ["object", "null"], properties: %{}}}
      }

      out = Anthropic.to_anthropic_json_schema(schema)

      assert out["additionalProperties"] == false
      assert out["properties"]["tags"]["items"]["additionalProperties"] == false
      assert out["properties"]["tags"]["items"]["properties"] == %{"k" => %{"type" => "string"}}

      assert [%{"additionalProperties" => false}, %{"type" => "null"}] =
               out["properties"]["maybe"]["anyOf"]

      assert out["$defs"]["thing"]["additionalProperties"] == false
      assert out["properties"]["ref"] == %{"$ref" => "#/$defs/thing"}
      refute Map.has_key?(out["properties"]["tags"], "additionalProperties")
    end

    test "additionalProperties: true is overridden (the API rejects it)" do
      out =
        Anthropic.to_anthropic_json_schema(%{"type" => "object", "additionalProperties" => true})

      assert out["additionalProperties"] == false
    end

    test "rejected constraints move into description; accepted ones stay" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
          "name" => %{"type" => "string", "description" => "Full name", "maxLength" => 40},
          "few" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1},
          "many" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 2,
            "maxItems" => 5,
            "uniqueItems" => true
          }
        },
        "maxProperties" => 9
      }

      out = Anthropic.to_anthropic_json_schema(schema)
      props = out["properties"]

      assert props["age"] == %{"type" => "integer", "description" => "{maximum: 150, minimum: 0}"}
      assert props["name"] == %{"type" => "string", "description" => "Full name", "maxLength" => 40}
      assert props["few"]["minItems"] == 1
      refute Map.has_key?(props["many"], "minItems")
      assert props["many"]["description"] == "{maxItems: 5, minItems: 2, uniqueItems: true}"
      assert out["description"] == "{maxProperties: 9}"
    end

    test "property names that collide with keywords are not stripped" do
      schema = %{
        "type" => "object",
        "properties" => %{"minimum" => %{"type" => "number"}, "items" => %{"type" => "string"}}
      }

      out = Anthropic.to_anthropic_json_schema(schema)

      assert out["properties"] == %{
               "minimum" => %{"type" => "number"},
               "items" => %{"type" => "string"}
             }
    end

    test "enum / const / default values pass through untouched" do
      s = %{"type" => "string", "enum" => ["minimum", "maximum"], "default" => "minimum"}
      assert Anthropic.to_anthropic_json_schema(s) == s
    end
  end

  # ---------------------------------------------------------------------------
  # Capability.preflight/2 — Anthropic returns :ok (Decision #13)
  # ---------------------------------------------------------------------------

  describe "Capability.preflight/2 — structured-output rewrite branch is skipped" do
    test "returns :ok (NOT {:ok, request} with structured_finalize: true)" do
      tool = Tool.new(name: "weather", description: "w", schema: %{"type" => "object"})

      r =
        req(
          tools: [tool],
          response_format: %{
            type: :json_schema,
            name: "person",
            schema: %{"type" => "object"},
            strict: true
          }
        )

      engine = ALLM.Engine.new(adapter: Anthropic, model: "claude-sonnet-4-6")

      # The Phase 10.4 widened contract: :ok | {:ok, Request.t()} | {:error, _}.
      # Anthropic's `requires_structured_finalize?/1 == false` so the rewrite
      # branch never fires; preflight returns plain :ok.
      assert ALLM.Capability.preflight(engine, r) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Stream-equivalence — chat/3 ≡ stream/3 |> StreamCollector.to_response/1
  # ---------------------------------------------------------------------------

  describe "structured output stream-equivalence" do
    test "streamed native JSON collapses to the same %Response{} as the non-streaming arm" do
      # Recorded from claude-sonnet-5-5 with output_config.format: the JSON
      # arrives as ordinary text_delta events.
      chunks = Fx.stream_chunks(:structured_output_stream)
      stub_ref = FinchStub.install(chunks, [])

      ALLM.Keys.put(:anthropic, "sk-ant-stream-equiv")

      r =
        req(
          response_format: %{
            type: :json_schema,
            name: "person",
            schema: %{"type" => "object"},
            strict: true
          }
        )

      {:ok, stream} = Anthropic.stream(r, finch_module: FinchStub, finch_stub_ref: stub_ref)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:text_delta, _}, &1))
      refute Enum.any?(events, &match?({:tool_call_started, _}, &1))

      state = Enum.reduce(events, StreamCollector.new(), &StreamCollector.apply_event(&2, &1))
      stream_response = StreamCollector.to_response(state)

      ns_response =
        Anthropic.from_anthropic_response(Fx.messages_response(:structured_output), [])

      for resp <- [stream_response, ns_response] do
        assert resp.finish_reason == :stop
        assert resp.tool_calls == []
        assert Jason.decode!(resp.output_text) == %{"name" => "Alice", "age" => 30}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Additional small-branch coverage (forced_choice, header_value, etc.)
  # ---------------------------------------------------------------------------

  describe "forced tool_choice on models that reject it" do
    setup do
      %{tool: Tool.new(name: "get_weather", description: "w", schema: %{"type" => "object"})}
    end

    test "forced choices are omitted for Opus 5.5 / Sonnet 5.5 / Fable 5.1 / Mythos 5.1", %{
      tool: tool
    } do
      for model <- ~w(claude-opus-5-5 claude-sonnet-5-5 claude-fable-5-1 claude-mythos-5-1),
          choice <- [
            :required,
            "get_weather",
            %{type: "tool", name: "get_weather"},
            %{"type" => "any"}
          ] do
        body =
          Anthropic.to_anthropic_request_body(req(model: model, tools: [tool], tool_choice: choice))

        refute Map.has_key?(body, "tool_choice"), "#{model} #{inspect(choice)}"
        assert [%{"name" => "get_weather"}] = body["tools"]
      end
    end

    test ":none is still sent on a rejecting model", %{tool: tool} do
      body =
        Anthropic.to_anthropic_request_body(
          req(model: "claude-opus-5-5", tools: [tool], tool_choice: :none)
        )

      assert body["tool_choice"] == %{"type" => "none"}
    end

    test "forced choices are still sent on models that accept them", %{tool: tool} do
      for model <-
            ~w(claude-sonnet-4-6 claude-opus-4-8 claude-opus-5 claude-sonnet-5 claude-fable-5) do
        body =
          Anthropic.to_anthropic_request_body(
            req(model: model, tools: [tool], tool_choice: :required)
          )

        assert body["tool_choice"] == %{"type" => "any"}, model
      end
    end

    test "the empty-tools guard still raises on a rejecting model" do
      assert_raise ArgumentError, ~r/requires non-empty tools/, fn ->
        Anthropic.to_anthropic_request_body(req(model: "claude-sonnet-5-5", tool_choice: :required))
      end
    end

    test "a raw tool_choice in options is passed through untouched", %{tool: tool} do
      r = req(model: "claude-opus-5-5", tools: [tool], options: %{tool_choice: %{type: "any"}})
      assert Anthropic.to_anthropic_request_body(r)["tool_choice"] == %{type: "any"}
    end

    test "the drop is logged at :debug", %{tool: tool} do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          Anthropic.to_anthropic_request_body(
            req(model: "claude-opus-5-5", tools: [tool], tool_choice: :required)
          )
        end)

      assert log =~ "dropping forced tool_choice :required for claude-opus-5-5"
    end
  end

  describe "additional branch coverage" do
    test "tool_choice atom-keyed %{type: \"tool\"} with non-empty tools is allowed" do
      tool = Tool.new(name: "x", description: "d", schema: %{})
      r = req(tool_choice: %{type: "tool", name: "x"}, tools: [tool])
      body = Anthropic.to_anthropic_request_body(r)
      assert body["tool_choice"] == %{type: "tool", name: "x"}
    end

    test "tool_choice atom-keyed %{type: \"any\"} with empty tools raises" do
      r = req(tool_choice: %{type: "any"}, tools: [])

      assert_raise ArgumentError, ~r/requires non-empty tools/, fn ->
        Anthropic.to_anthropic_request_body(r)
      end
    end

    test "to_anthropic_messages: assistant with empty tool_calls list → simple shape" do
      msg = %Message{role: :assistant, content: "ok", metadata: %{tool_calls: []}}
      assert [%{"role" => "assistant", "content" => "ok"}] = Anthropic.to_anthropic_messages([msg])
    end

    test "to_anthropic_messages: assistant with text + tool_calls → both content blocks" do
      tc = ToolCall.new(id: "toolu_y", name: "weather", arguments: %{})
      msg = %Message{role: :assistant, content: "Let me check.", metadata: %{tool_calls: [tc]}}
      assert [m] = Anthropic.to_anthropic_messages([msg])

      assert m["content"] == [
               %{"type" => "text", "text" => "Let me check."},
               %{"type" => "tool_use", "id" => "toolu_y", "name" => "weather", "input" => %{}}
             ]
    end

    test "to_anthropic_messages: nil content stringifies to \"\"" do
      msg = %Message{role: :user, content: nil}
      assert [%{"role" => "user", "content" => ""}] = Anthropic.to_anthropic_messages([msg])
    end

    test "to_anthropic_messages: [%TextPart{}] content materializes to its text (Phase 14.4)" do
      msg = %Message{role: :user, content: [%ALLM.TextPart{text: "hi"}]}
      assert [%{"role" => "user", "content" => "hi"}] = Anthropic.to_anthropic_messages([msg])
    end

    test "to_anthropic_messages: multi-TextPart content joins with newline (Phase 14.4)" do
      msg = %Message{
        role: :user,
        content: [%ALLM.TextPart{text: "a"}, %ALLM.TextPart{text: "b"}]
      }

      assert [%{"role" => "user", "content" => "a\nb"}] = Anthropic.to_anthropic_messages([msg])
    end

    test "to_anthropic_messages: defensive system-role coercion to user" do
      # extract_system/1 normally removes system messages; this exercises the
      # adapter's defense-in-depth fallback if a system message slips through.
      assert [%{"role" => "user", "content" => "hi"}] =
               Anthropic.to_anthropic_messages([%Message{role: :system, content: "hi"}])
    end

    test "to_anthropic_request_body emits temperature when set" do
      r = req(temperature: 0.7)
      body = Anthropic.to_anthropic_request_body(r)
      assert body["temperature"] == 0.7
    end

    test "to_anthropic_request_body merges request.options atom keys" do
      r = req(options: %{top_p: 0.95, atom_only: "x"})
      body = Anthropic.to_anthropic_request_body(r)
      assert body["top_p"] == 0.95
      assert body["atom_only"] == "x"
    end

    test "to_anthropic_request_body merges request.options string keys (passthrough)" do
      r = req(options: %{"already_string" => 1})
      body = Anthropic.to_anthropic_request_body(r)
      assert body["already_string"] == 1
    end

    test "header_value via list of headers ignores non-matching keys" do
      # Smoke: a 429 with a non-Retry-After header in the list still returns
      # nil retry_after_ms and parses correctly.
      err = Anthropic.from_anthropic_error(429, %{}, [{"content-type", "application/json"}])
      assert err.retry_after_ms == nil
    end

    test "header_value via list of headers with non-binary key entry ignores it" do
      # Defensive — exercise the catch-all in `header_value/2` for list shape.
      err = Anthropic.from_anthropic_error(429, %{}, [{:not_a_string, "x"}])
      assert err.retry_after_ms == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Stop-reason mapping (total)
  # ---------------------------------------------------------------------------

  describe "map_stop_reason/1 + from_anthropic_response/2 finish_reason mapping" do
    for {wire, expected, raw_keep} <- [
          {"end_turn", :stop, nil},
          {"max_tokens", :length, nil},
          {"tool_use", :tool_calls, nil},
          {"stop_sequence", :stop, "stop_sequence"},
          {"refusal", :content_filter, "refusal"},
          {"pause_turn", :other, "pause_turn"}
        ] do
      test "maps #{inspect(wire)} → #{inspect(expected)} (raw=#{inspect(raw_keep)})" do
        body = %{
          "id" => "msg_x",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => unquote(wire)
        }

        resp = Anthropic.from_anthropic_response(body, [])
        assert resp.finish_reason == unquote(expected)
        assert resp.raw_finish_reason == unquote(raw_keep)
      end
    end

    test "nil stop_reason → nil finish_reason (mid-stream)" do
      body = %{"content" => [%{"type" => "text", "text" => "x"}], "stop_reason" => nil}
      assert Anthropic.from_anthropic_response(body, []).finish_reason == nil
    end

    property "any unknown stop_reason maps to :other and preserves raw" do
      known = ~w(end_turn max_tokens tool_use stop_sequence refusal pause_turn)

      check all(
              s <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
              s not in known,
              max_runs: 100
            ) do
        body = %{"content" => [], "stop_reason" => s}
        resp = Anthropic.from_anthropic_response(body, [])
        assert resp.finish_reason == :other
        assert resp.raw_finish_reason == s
      end
    end
  end

  # ---------------------------------------------------------------------------
  # from_anthropic_response/2 — content-block decoding
  # ---------------------------------------------------------------------------

  describe "from_anthropic_response/2" do
    test "populates id, model, output_text, finish_reason, usage" do
      body = %{
        "id" => "msg_xyz",
        "model" => "claude-sonnet-4-6",
        "content" => [%{"type" => "text", "text" => "hello"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
      }

      resp = Anthropic.from_anthropic_response(body, [])
      assert resp.id == "msg_xyz"
      assert resp.model == "claude-sonnet-4-6"
      assert resp.output_text == "hello"
      assert resp.finish_reason == :stop
      assert resp.usage.input_tokens == 5
      assert resp.usage.output_tokens == 7
      assert resp.usage.total_tokens == 12
    end

    test "decodes single tool_use → %ToolCall{} per Decision #6" do
      body = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_abc",
            "name" => "get_weather",
            "input" => %{"city" => "Boston"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      resp = Anthropic.from_anthropic_response(body, [])
      assert resp.finish_reason == :tool_calls
      assert [tc] = resp.tool_calls
      assert tc.id == "toolu_abc"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Boston"}
      # Decision #6: raw_arguments computed from input map for OpenAI parity.
      assert is_binary(tc.raw_arguments)
      assert Jason.decode!(tc.raw_arguments) == %{"city" => "Boston"}
    end

    test "decodes parallel tool_use blocks" do
      body = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_a",
            "name" => "weather",
            "input" => %{"city" => "Boston"}
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_b",
            "name" => "weather",
            "input" => %{"city" => "Seattle"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      resp = Anthropic.from_anthropic_response(body, [])
      assert [a, b] = resp.tool_calls
      assert a.id == "toolu_a"
      assert b.id == "toolu_b"
    end

    test "interleaved text + tool_use blocks: text accumulates, tool_use surfaces" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "Let me check. "},
          %{"type" => "tool_use", "id" => "toolu_z", "name" => "weather", "input" => %{}}
        ],
        "stop_reason" => "tool_use"
      }

      resp = Anthropic.from_anthropic_response(body, [])
      assert resp.output_text == "Let me check. "
      assert [%ToolCall{id: "toolu_z"}] = resp.tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # from_anthropic_error/3 — error classification
  # ---------------------------------------------------------------------------

  describe "from_anthropic_error/3 (additional coverage)" do
    test "context_length_marker? matches 'context window' too" do
      body = %{
        "error" => %{"type" => "invalid_request_error", "message" => "context window exceeded"}
      }

      err = Anthropic.from_anthropic_error(400, body, [])
      assert err.reason == :context_length_exceeded
    end

    test "context_length_marker? matches 'context length' too" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "the context length is too big"
        }
      }

      err = Anthropic.from_anthropic_error(400, body, [])
      assert err.reason == :context_length_exceeded
    end

    test "context_length_marker? matches 'max_tokens' too" do
      body = %{"error" => %{"type" => "invalid_request_error", "message" => "max_tokens issue"}}
      err = Anthropic.from_anthropic_error(400, body, [])
      assert err.reason == :context_length_exceeded
    end

    test "400 with no error message map → :invalid_request" do
      err = Anthropic.from_anthropic_error(400, %{}, [])
      assert err.reason == :invalid_request
    end

    test "decode_error_body of non-map body collapses to %{}" do
      # Funnel through generate/2 to exercise classify_http_error's
      # `decode_error_body/1` non-map fallback.
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_decode_err_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(400, "plain text not json")
      end)

      assert {:error, %AdapterError{reason: :invalid_request, status: 400}} =
               Anthropic.generate(req(), retry: false, adapter_opts: [plug: {Req.Test, stub}])
    end

    test "200 with non-map body (Req returned non-decoded) → :malformed_response" do
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_nonmap_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        # Return a JSON-array body — Req will decode to a list, not a map.
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[]")
      end)

      assert {:error, %AdapterError{reason: :malformed_response}} =
               Anthropic.generate(req(), retry: false, adapter_opts: [plug: {Req.Test, stub}])
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 retry-policy widening (Decision #2)
  # ---------------------------------------------------------------------------

  describe "with_anthropic_retry_on (Decision #2 widening)" do
    test "retry: false passes through (no widening; runs single attempt)" do
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_no_retry_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          529,
          ~s({"type":"error","error":{"type":"overloaded_error","message":"o"}})
        )
      end)

      # retry: false → no widening, single attempt, classify_http_error
      # tries to set retry token but Retry.run/3 with :no_retry collapses
      # to {:error, _}. We accept the error tuple.
      assert {:error, %AdapterError{}} =
               Anthropic.generate(req(), retry: false, adapter_opts: [plug: {Req.Test, stub}])
    end

    test "explicit `retry: [retry_on: [...]]` opt is widened with 529" do
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_explicit_#{System.unique_integer([:positive])}")

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub, fn conn ->
        n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            529,
            ~s({"type":"error","error":{"type":"overloaded_error","message":"o"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"id":"x","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}})
          )
        end
      end)

      # Caller supplied a narrow retry_on set that does NOT include 529;
      # the closure widens it so 529 still retries successfully.
      assert {:ok, response} =
               Anthropic.generate(req(),
                 retry: [retry_on: [429, :timeout], base_delay_ms: 1, jitter_ms: 0],
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.output_text == "hi"
    end

    test "unrecognised retry shape (e.g. an atom) passes through unchanged" do
      # Direct unit-level call to the helper via generate; an unknown shape
      # would propagate to Retry.run/3 which only accepts :no_retry / :default
      # / engine_retry / policy. We can't easily exercise the catch-all
      # without crashing Retry; instead we verify the public guarantee that
      # `:default` retry policy still includes 529 widening.
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_default_widen_#{System.unique_integer([:positive])}")

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub, fn conn ->
        n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            529,
            ~s({"type":"error","error":{"type":"overloaded_error","message":"o"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"id":"x","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}})
          )
        end
      end)

      assert {:ok, _} =
               Anthropic.generate(req(),
                 retry: :default,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # from_anthropic_error/3 — original rows
  # ---------------------------------------------------------------------------

  describe "from_anthropic_error/3" do
    test "401 → :authentication_failed" do
      err =
        Anthropic.from_anthropic_error(401, %{"error" => %{"type" => "authentication_error"}}, [])

      assert err.reason == :authentication_failed
      assert err.status == 401
      assert err.provider == :anthropic
    end

    test "403 → :authentication_failed" do
      err = Anthropic.from_anthropic_error(403, %{"error" => %{"type" => "permission_error"}}, [])
      assert err.reason == :authentication_failed
    end

    test "429 → :rate_limited and Retry-After parsed" do
      err = Anthropic.from_anthropic_error(429, %{}, [{"retry-after", "5"}])
      assert err.reason == :rate_limited
      assert err.retry_after_ms == 5_000
    end

    test "413 → :invalid_request" do
      err = Anthropic.from_anthropic_error(413, %{"error" => %{"type" => "request_too_large"}}, [])
      assert err.reason == :invalid_request
      assert err.status == 413
    end

    test "400 with 'prompt is too long' marker → :context_length_exceeded" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "prompt is too long: 9000 tokens"
        }
      }

      err = Anthropic.from_anthropic_error(400, body, [])
      assert err.reason == :context_length_exceeded
    end

    test "400 generic → :invalid_request" do
      body = %{"error" => %{"type" => "invalid_request_error", "message" => "bad shape"}}
      err = Anthropic.from_anthropic_error(400, body, [])
      assert err.reason == :invalid_request
    end

    test "5xx + 529 → :provider_unavailable" do
      for status <- [500, 502, 503, 504, 529] do
        err = Anthropic.from_anthropic_error(status, %{}, [])
        assert err.reason == :provider_unavailable, "wrong reason for #{status}"
        assert err.status == status
      end
    end

    test "unknown status → :unknown" do
      err = Anthropic.from_anthropic_error(418, %{}, [])
      assert err.reason == :unknown
    end

    test "Retry-After in map-shaped headers parses too" do
      err = Anthropic.from_anthropic_error(429, %{}, %{"retry-after" => "3"})
      assert err.retry_after_ms == 3_000
    end

    test "unparseable Retry-After yields nil" do
      err = Anthropic.from_anthropic_error(429, %{}, [{"retry-after", "tomorrow"}])
      assert err.retry_after_ms == nil
    end
  end

  # ---------------------------------------------------------------------------
  # requires_structured_finalize?/1 (Decision #13)
  # ---------------------------------------------------------------------------

  describe "requires_structured_finalize?/1" do
    test "always returns false (Anthropic uses single-pass tool-forcing)" do
      refute Anthropic.requires_structured_finalize?(req())

      tool = Tool.new(name: "t", description: "d", schema: %{})

      r =
        req(
          tools: [tool],
          response_format: %{type: :json_schema, name: "p", schema: %{}, strict: true}
        )

      refute Anthropic.requires_structured_finalize?(r)

      refute Anthropic.requires_structured_finalize?(req(response_format: :text))
      refute Anthropic.requires_structured_finalize?(req(response_format: %{type: :json_object}))
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2 (Decision #9)
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "returns %Req.Request{} with x-api-key + anthropic-version headers" do
      ALLM.Keys.put(:anthropic, "sk-ant-prep-test")
      assert {:ok, %Req.Request{} = http} = Anthropic.prepare_request(req(), [])
      assert Req.Request.get_header(http, "x-api-key") == ["sk-ant-prep-test"]
      assert Req.Request.get_header(http, "anthropic-version") == ["2023-06-01"]
      assert http.url.path == "/v1/messages"
    end

    test "honors api_key opt over the env" do
      ALLM.Keys.put(:anthropic, "sk-env")
      assert {:ok, http} = Anthropic.prepare_request(req(), api_key: "sk-override")
      assert Req.Request.get_header(http, "x-api-key") == ["sk-override"]
    end

    test "raises EngineError{:missing_key} when no key resolvable" do
      ALLM.Keys.delete(:anthropic)
      System.delete_env("ANTHROPIC_API_KEY")

      assert_raise EngineError, fn ->
        Anthropic.prepare_request(req(), [])
      end
    end

    test "honors :request_timeout via Req.merge" do
      ALLM.Keys.put(:anthropic, "sk-x")
      assert {:ok, http} = Anthropic.prepare_request(req(), request_timeout: 5_000)
      assert http.options[:receive_timeout] == 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # translate_options/2 (Decision #7)
  # ---------------------------------------------------------------------------

  describe "translate_options/2" do
    test "is identity (Anthropic accepts max_tokens natively)" do
      r = req()
      assert Anthropic.translate_options([max_tokens: 100], r) == [max_tokens: 100]

      assert Anthropic.translate_options([max_tokens: 100, temperature: 0.7, top_p: 0.95], r) ==
               [max_tokens: 100, temperature: 0.7, top_p: 0.95]
    end

    test "is identity for empty opts" do
      assert Anthropic.translate_options([], req()) == []
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — direct paths (no HTTP)
  # ---------------------------------------------------------------------------

  describe "generate/2 (no HTTP)" do
    test "no-key → EngineError raised by prepare_request/2" do
      ALLM.Keys.delete(:anthropic)
      System.delete_env("ANTHROPIC_API_KEY")

      assert_raise EngineError, fn ->
        Anthropic.generate(req(), retry: false)
      end
    end

    test "transport_error returned as :network_error AdapterError" do
      ALLM.Keys.put(:anthropic, "sk-x")
      stub = String.to_atom("anthropic_test_stub_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %AdapterError{reason: :network_error}} =
               Anthropic.generate(req(), retry: false, adapter_opts: [plug: {Req.Test, stub}])
    end
  end
end
