defmodule ALLM.Providers.GeminiToolsTest do
  @moduledoc """
  Phase 16.3 — Tool-calling round-trip for `ALLM.Providers.Gemini`.

  Covers Test Plan §16.3.1:

    * Request build — tool declarations + toolConfig modes (AUTO / ANY /
      NONE / ANY+allowedFunctionNames / multi-tool).
    * Non-streaming response decode — single, parallel, mixed text+call,
      arguments↔raw_arguments round-trip, id preservation + synthesis.
    * Tool-result round-trip — :tool message translation to user-role
      `functionResponse` parts (binary + map content).
    * Multi-turn user→model functionCall→user functionResponse→model text.
    * Streaming parity — :tool_call_started + :tool_call_completed (no
      deltas); stream-equivalence parity for tool-call responses (cross-
      ref `gemini_stream_test.exs`'s functionCall fixtures).
    * Finish-reason override — STOP+functionCall → :tool_calls;
      MALFORMED_FUNCTION_CALL → :error raw preserved.

  Per the design's "Cross-function invariants" section, stream-equivalence
  for tool-call fixtures relaxes `raw_finish_reason` until Phase 16.7
  closes the StreamCollector round-trip gap. The streaming side already
  promotes finish_reason to :tool_calls (Phase 16.2); 16.3 lands the
  non-streaming side so the projection's
  `{content, tool_calls, finish_reason, usage}` rejoins.
  """
  use ExUnit.Case, async: false

  alias ALLM.Message
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.GeminiTestFixtures, as: Fx
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.FinchStub
  alias ALLM.Tool
  alias ALLM.ToolCall

  setup do
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    :ok
  end

  defp tool(name, description \\ "test tool", schema \\ %{"type" => "object"}) do
    Tool.new(name: name, description: description, schema: schema)
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

  defp stub_capture(name_prefix, body_fn) do
    test_pid = self()
    ref = make_ref()
    stub = String.to_atom("#{name_prefix}_#{System.unique_integer([:positive])}")

    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {ref, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body_fn.()))
    end)

    {stub, ref}
  end

  # ---------------------------------------------------------------------------
  # Request build — tool declarations + toolConfig
  # ---------------------------------------------------------------------------

  describe "to_gemini_request_body/2 — tool declarations" do
    test "single tool produces tools: [{functionDeclarations: [{name, description, parameters}]}]" do
      schema = %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }

      r =
        Request.new([%Message{role: :user, content: "weather?"}],
          model: "gemini-2.5-flash",
          tools: [
            Tool.new(name: "get_weather", description: "fetch weather", schema: schema)
          ]
        )

      body = Gemini.to_gemini_request_body(r, [])

      assert body["tools"] == [
               %{
                 "functionDeclarations" => [
                   %{
                     "name" => "get_weather",
                     "description" => "fetch weather",
                     "parameters" => schema
                   }
                 ]
               }
             ]
    end

    test "multiple tools collapse into one functionDeclarations array" do
      r =
        Request.new([%Message{role: :user, content: "x"}],
          model: "gemini-2.5-flash",
          tools: [tool("a"), tool("b"), tool("c")]
        )

      body = Gemini.to_gemini_request_body(r, [])

      assert [%{"functionDeclarations" => decls}] = body["tools"]
      assert Enum.map(decls, & &1["name"]) == ["a", "b", "c"]
    end

    test "empty tools list omits tools / toolConfig keys" do
      r = Request.new([%Message{role: :user, content: "x"}], model: "gemini-2.5-flash", tools: [])

      body = Gemini.to_gemini_request_body(r, [])

      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "toolConfig")
    end
  end

  describe "to_gemini_request_body/2 — toolConfig.functionCallingConfig" do
    test ":auto → AUTO" do
      r = req(tools: [tool("x")], tool_choice: :auto)
      body = Gemini.to_gemini_request_body(r, [])

      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "AUTO"}}
    end

    test ":required → ANY" do
      r = req(tools: [tool("x")], tool_choice: :required)
      body = Gemini.to_gemini_request_body(r, [])

      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "ANY"}}
    end

    test ":none → NONE" do
      r = req(tools: [tool("x")], tool_choice: :none)
      body = Gemini.to_gemini_request_body(r, [])

      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "NONE"}}
    end

    test ~s({:tool, "name"} → ANY + allowedFunctionNames) do
      r = req(tools: [tool("set_color")], tool_choice: {:tool, "set_color"})
      body = Gemini.to_gemini_request_body(r, [])

      assert body["toolConfig"] == %{
               "functionCallingConfig" => %{
                 "mode" => "ANY",
                 "allowedFunctionNames" => ["set_color"]
               }
             }
    end

    test "string tool_choice is shorthand for {:tool, name}" do
      r = req(tools: [tool("set_color")], tool_choice: "set_color")
      body = Gemini.to_gemini_request_body(r, [])

      assert body["toolConfig"] == %{
               "functionCallingConfig" => %{
                 "mode" => "ANY",
                 "allowedFunctionNames" => ["set_color"]
               }
             }
    end

    test "nil tool_choice (with tools) defaults to AUTO mode (Gemini default)" do
      # nil is the canonical "let provider decide" — Gemini's documented
      # default when tools are present is AUTO, so we omit toolConfig
      # entirely and the wire defaults apply.
      r = req(tools: [tool("x")], tool_choice: nil)
      body = Gemini.to_gemini_request_body(r, [])

      refute Map.has_key?(body, "toolConfig")
    end
  end

  # ---------------------------------------------------------------------------
  # Response decode (non-streaming)
  # ---------------------------------------------------------------------------

  describe "decode response — single functionCall part" do
    test "decodes to %Response{tool_calls: [%ToolCall{}], finish_reason: :tool_calls}" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_one", 200, Fx.synthesized(:tool_call_one))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      # output_text is nil when no text parts emitted (Anthropic
      # precedent at lib/allm/providers/anthropic.ex's decode);
      # message.content stays "" for assistant-side tool-only turns.
      assert response.output_text == nil
      assert response.message.content == ""
      assert response.finish_reason == :tool_calls

      # Decision #14 override: STOP + functionCall → :tool_calls; raw still STOP.
      assert response.raw_finish_reason == nil

      assert [%ToolCall{} = tc] = response.tool_calls
      assert tc.id == "fc_one"
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Boston"}
      # Decision #4 — raw_arguments is canonical-JSON of arguments
      assert tc.raw_arguments == ~s({"city":"Boston"})
      assert tc.arguments == Jason.decode!(tc.raw_arguments)
    end

    test "tool_calls also surfaced in message.metadata.tool_calls (collector parity)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_one_md", 200, Fx.synthesized(:tool_call_one))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      # Mirrors Anthropic's tool_calls_metadata/1 at lib/allm/providers/anthropic.ex:1196
      assert response.message.metadata[:tool_calls] == response.tool_calls
    end
  end

  describe "decode response — parallel functionCalls" do
    test "two parallel functionCall parts decode in source order" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_par", 200, Fx.synthesized(:tool_call_parallel))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :tool_calls
      assert [a, b] = response.tool_calls
      assert a.id == "fc_a" and a.name == "get_weather" and a.arguments == %{"city" => "Boston"}
      assert b.id == "fc_b" and b.name == "set_color" and b.arguments == %{"color" => "red"}
    end
  end

  describe "decode response — mixed text + functionCall" do
    test "text content preserved; finish_reason promotes to :tool_calls" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_mix", 200, Fx.synthesized(:tool_call_mixed))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.output_text == "checking weather"
      assert response.message.content == "checking weather"
      assert response.finish_reason == :tool_calls
      assert [%ToolCall{name: "get_weather"}] = response.tool_calls
    end
  end

  describe "decode response — id preservation / synthesis" do
    test "functionCall with id present preserves it on ToolCall.id" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_idp", 200, Fx.synthesized(:tool_call_one))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert [%ToolCall{id: "fc_one"}] = response.tool_calls
    end

    test "functionCall without id synthesizes a deterministic id (Anthropic precedent)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_idgen", 200, Fx.synthesized(:tool_call_no_id))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert [%ToolCall{id: id, name: "set_color"}] = response.tool_calls
      assert is_binary(id) and byte_size(id) > 0
      assert String.starts_with?(id, "fc_")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool-result round-trip — :tool messages → user-role functionResponse parts
  # ---------------------------------------------------------------------------

  describe "to_gemini_contents/1 — :tool message translation (Decision #5)" do
    test ":tool message with binary content is wrapped as response: %{\"output\" => content}" do
      messages = [
        %Message{
          role: :tool,
          content: "72°F sunny",
          tool_call_id: "fc_one",
          name: "get_weather"
        }
      ]

      [encoded] = Gemini.to_gemini_contents(messages)

      assert encoded == %{
               "role" => "user",
               "parts" => [
                 %{
                   "functionResponse" => %{
                     "id" => "fc_one",
                     "name" => "get_weather",
                     "response" => %{"output" => "72°F sunny"}
                   }
                 }
               ]
             }
    end

    test ":tool message with map content passes the map through verbatim" do
      payload = %{"temperature" => 72, "condition" => "sunny"}

      messages = [
        %Message{
          role: :tool,
          content: payload,
          tool_call_id: "fc_two",
          name: "get_weather"
        }
      ]

      [encoded] = Gemini.to_gemini_contents(messages)

      assert encoded["parts"] == [
               %{
                 "functionResponse" => %{
                   "id" => "fc_two",
                   "name" => "get_weather",
                   "response" => payload
                 }
               }
             ]
    end

    test ":tool message without tool_call_id omits the id field" do
      messages = [
        %Message{role: :tool, content: "ok", name: "get_weather"}
      ]

      [encoded] = Gemini.to_gemini_contents(messages)

      [%{"functionResponse" => fr}] = encoded["parts"]
      refute Map.has_key?(fr, "id")
      assert fr["name"] == "get_weather"
      assert fr["response"] == %{"output" => "ok"}
    end

    test "multi-turn user → model functionCall → user functionResponse → model text" do
      # Mirror the conversation a chat loop produces: caller wants the
      # adapter to translate the :tool turn back into a user-role
      # functionResponse part adjacent to the prior model turn's
      # functionCall.
      assistant_with_call = %Message{
        role: :assistant,
        content: "",
        metadata: %{
          tool_calls: [
            ToolCall.new(
              id: "fc_z",
              name: "get_weather",
              arguments: %{"city" => "Boston"}
            )
          ]
        }
      }

      messages = [
        %Message{role: :user, content: "weather in Boston?"},
        assistant_with_call,
        %Message{
          role: :tool,
          content: "72°F",
          tool_call_id: "fc_z",
          name: "get_weather"
        }
      ]

      contents = Gemini.to_gemini_contents(messages)

      assert length(contents) == 3
      assert Enum.at(contents, 0)["role"] == "user"
      assert Enum.at(contents, 1)["role"] == "model"
      assert Enum.at(contents, 2)["role"] == "user"

      # Final user turn carries the functionResponse part
      assert [%{"functionResponse" => %{"name" => "get_weather", "id" => "fc_z"}}] =
               Enum.at(contents, 2)["parts"]
    end

    test "assistant turn with metadata.tool_calls renders functionCall parts (Decision #5 round-trip)" do
      # The model's prior turn re-fed back through the request; its
      # tool_calls metadata must serialize as functionCall parts so
      # Gemini sees the same wire shape it produced.
      assistant_with_call = %Message{
        role: :assistant,
        content: "",
        metadata: %{
          tool_calls: [
            ToolCall.new(id: "fc_z", name: "get_weather", arguments: %{"city" => "Boston"})
          ]
        }
      }

      [encoded] = Gemini.to_gemini_contents([assistant_with_call])

      assert encoded == %{
               "role" => "model",
               "parts" => [
                 %{
                   "functionCall" => %{
                     "id" => "fc_z",
                     "name" => "get_weather",
                     "args" => %{"city" => "Boston"}
                   }
                 }
               ]
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Wire-shape capture — full request body integration
  # ---------------------------------------------------------------------------

  describe "generate/2 wire shape with tools" do
    test "tools list + tool_choice :auto produces tools + toolConfig in body" do
      ALLM.Keys.put(:gemini, "AIza-test")
      {stub, ref} = stub_capture("gemini_tools_wire", fn -> Fx.synthesized(:tool_call_one) end)

      r =
        Request.new([%Message{role: :user, content: "weather?"}],
          model: "gemini-2.5-flash",
          tools: [tool("get_weather", "weather", %{"type" => "object"})],
          tool_choice: :auto
        )

      assert {:ok, _} = Gemini.generate(r, retry: false, adapter_opts: [plug: {Req.Test, stub}])

      assert_received {^ref, body}
      assert [%{"functionDeclarations" => [%{"name" => "get_weather"}]}] = body["tools"]
      assert body["toolConfig"]["functionCallingConfig"]["mode"] == "AUTO"
    end
  end

  # ---------------------------------------------------------------------------
  # Finish-reason override — STOP + functionCall → :tool_calls;
  # MALFORMED_FUNCTION_CALL → :error raw preserved
  # ---------------------------------------------------------------------------

  describe "finish-reason override (Decision #14)" do
    test "STOP + functionCall parts → :tool_calls, raw collapses to nil (STOP canonical row)" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_stopfc", 200, Fx.synthesized(:tool_call_one))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :tool_calls
      # STOP collapses to nil per Decision #14 row 1; the override does
      # not introduce a non-canonical raw value.
      assert response.raw_finish_reason == nil
    end

    test "MALFORMED_FUNCTION_CALL → :error, raw preserved" do
      ALLM.Keys.put(:gemini, "AIza-test")
      stub = stub_json("gemini_tc_mfc", 200, Fx.synthesized(:malformed_function_call))

      assert {:ok, response} =
               Gemini.generate(req(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert response.finish_reason == :error
      assert response.raw_finish_reason == "MALFORMED_FUNCTION_CALL"
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming parity — :tool_call_started + :tool_call_completed + zero deltas
  # for the parallel-tool-call SSE fixture (extends Phase 16.2's single-call
  # test at gemini_stream_test.exs:132-156).
  # ---------------------------------------------------------------------------

  describe "stream/2 — tool-call parity (extends Phase 16.2)" do
    test "two parallel functionCall parts → two starts + two completeds, zero deltas" do
      ALLM.Keys.put(:gemini, "AIza-test")
      chunks = Fx.stream_chunks(:tool_call_parallel_stream)
      stub = install_stream_stub(chunks)

      {:ok, stream} =
        Gemini.stream(req(),
          finch_module: ALLM.Test.FinchStub,
          finch_stub_ref: stub
        )

      events = Enum.to_list(stream)

      # Two starts + two completeds, in source order
      starts = Enum.filter(events, &match?({:tool_call_started, _}, &1))
      assert length(starts) == 2

      assert [
               {:tool_call_started, %{id: "fc_a", name: "get_weather"}},
               {:tool_call_started, %{id: "fc_b", name: "set_color"}}
             ] = starts

      assert [] = Enum.filter(events, &match?({:tool_call_delta, _}, &1))

      completed = Enum.filter(events, &match?({:tool_call_completed, _}, &1))
      assert length(completed) == 2

      response = collect(events)
      assert response.finish_reason == :tool_calls
      assert [a, b] = response.tool_calls
      assert a.name == "get_weather"
      assert b.name == "set_color"
    end
  end

  # ---------------------------------------------------------------------------
  # Stream-equivalence — extends Phase 16.2's functionCall sub-projection now
  # that 16.3's non-streaming decoder catches up. Per the design's relaxation
  # note: `raw_finish_reason` stays out of the projection until 16.7.
  # ---------------------------------------------------------------------------

  describe "stream-equivalence — functionCall fixtures (Phase 16.3 close)" do
    @fixtures [:equiv_function_call, :equiv_text_then_function_call]

    for fixture <- @fixtures do
      @fixture fixture
      test "equiv: #{fixture} content + tool_calls + finish_reason + usage" do
        ALLM.Keys.put(:gemini, "AIza-test")
        json_body = Fx.synthesized(@fixture)

        # Non-streaming arm
        stub = stub_json("equiv_ns_#{@fixture}", 200, json_body)
        {:ok, ns} = Gemini.generate(req(), retry: false, adapter_opts: [plug: {Req.Test, stub}])

        # Streaming arm — `:gemini` key already set above.
        chunks = Fx.stream_chunks(@fixture)
        stream_stub = install_stream_stub(chunks)

        {:ok, stream} =
          Gemini.stream(req(),
            finch_module: ALLM.Test.FinchStub,
            finch_stub_ref: stream_stub
          )

        st = collect(Enum.to_list(stream))

        # raw_finish_reason relaxed (Phase 16.7 closes); content/tool_calls/
        # finish_reason/usage join the projection now that 16.3 lands.
        assert st.output_text == ns.output_text or st.message.content == ns.message.content
        assert tool_call_projection(st.tool_calls) == tool_call_projection(ns.tool_calls)
        assert st.finish_reason == ns.finish_reason
        assert st.usage == ns.usage
      end
    end
  end

  defp tool_call_projection(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      {tc.id, tc.name, tc.arguments, tc.raw_arguments}
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp install_stream_stub(chunks), do: FinchStub.install(chunks, [])

  defp collect(events) when is_list(events) do
    state = Enum.reduce(events, StreamCollector.new(), &StreamCollector.apply_event(&2, &1))
    StreamCollector.to_response(state)
  end
end
