defmodule ALLMTest do
  use ExUnit.Case, async: true

  doctest ALLM

  alias ALLM.{Message, Request, Tool}

  describe "message builders" do
    test "system/1 builds a system message" do
      assert %Message{role: :system, content: "be nice"} = ALLM.system("be nice")
    end

    test "system/1 returns an ALLM.Message struct" do
      assert is_struct(ALLM.system("hi"), Message)
    end

    test "user/1 builds a user message" do
      assert %Message{role: :user, content: "hi"} = ALLM.user("hi")
    end

    test "assistant/1 builds an assistant message" do
      assert %Message{role: :assistant, content: "hello"} = ALLM.assistant("hello")
    end

    test "tool_result/2 builds a tool message with the call id" do
      msg = ALLM.tool_result("call_abc", %{ok: true})
      assert %Message{role: :tool, tool_call_id: "call_abc", content: %{ok: true}} = msg
    end
  end

  describe "tool/1" do
    test "builds an ALLM.Tool struct" do
      tool =
        ALLM.tool(
          name: "get_weather",
          description: "weather by city",
          schema: %{type: "object"},
          handler: fn _ -> {:ok, "sunny"} end
        )

      assert %Tool{name: "get_weather", description: "weather by city"} = tool
      assert is_function(tool.handler, 1)
    end
  end

  describe "json_schema/3" do
    test "returns a canonical tagged map" do
      assert %{type: :json_schema, name: "foo", strict: true, schema: %{"type" => "object"}} =
               ALLM.json_schema("foo", %{"type" => "object"}, strict: true)
    end

    test "defaults strict to true" do
      assert %{strict: true} = ALLM.json_schema("foo", %{})
    end

    test "normalizes atom-keyed schema to string keys (mirrors ALLM.Tool.new/1)" do
      # Phase 21 (code-review F2): ALLM.json_schema/3 now applies the same
      # ALLM.JsonSchema.normalize/1 helper as ALLM.Tool.new/1's :schema
      # field, so a caller passing %{type: :object, ...} no longer leaks
      # atom keys/values into the adapter wire shape.
      result =
        ALLM.json_schema("person", %{type: :object, properties: %{name: %{type: :string}}})

      assert result.schema == %{
               "type" => "object",
               "properties" => %{"name" => %{"type" => "string"}}
             }
    end
  end

  describe "request/2" do
    test "wraps messages with defaults" do
      messages = [ALLM.user("hi")]
      req = ALLM.request(messages)

      assert %Request{messages: ^messages, stream: false, tools: []} = req
    end

    test "passes through request opts" do
      req = ALLM.request([ALLM.user("hi")], model: "gpt-4.1-mini", temperature: 0.2)
      assert req.model == "gpt-4.1-mini"
      assert req.temperature == 0.2
    end

    test "returns an ALLM.Request struct" do
      assert is_struct(ALLM.request([ALLM.user("hi")]), Request)
    end

    test "delegates to ALLM.Request.new/2 (same struct as calling new/2 directly)" do
      messages = [ALLM.user("hi")]
      opts = [model: "gpt-4.1-mini", temperature: 0.2]
      assert ALLM.request(messages, opts) == ALLM.Request.new(messages, opts)
    end
  end
end
