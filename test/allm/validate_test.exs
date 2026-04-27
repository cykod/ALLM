defmodule ALLM.ValidateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.Error.ValidationError

  alias ALLM.{
    Image,
    ImagePart,
    Message,
    Request,
    Session,
    TextPart,
    Thread,
    Tool,
    ToolCall,
    Validate
  }

  alias ALLM.Test.Generators

  doctest ALLM.Validate

  # ---------------------------------------------------------------------------
  # Validate.request/1
  # ---------------------------------------------------------------------------

  describe "request/1" do
    test "happy path: single-message valid request returns :ok" do
      req = Request.new([%Message{role: :user, content: "hi"}])
      assert :ok = Validate.request(req)
    end

    test "fails on empty messages" do
      req = Request.new([])

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:messages, :empty} in errors
    end

    test "fails on duplicate tool names" do
      req =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          tools: [
            %Tool{name: "dup", description: "a", schema: %{}},
            %Tool{name: "dup", description: "b", schema: %{}}
          ]
        )

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:tools, :duplicate_name} in errors
    end

    test "fails on temperature out of range (high)" do
      req = Request.new([%Message{role: :user, content: "hi"}], temperature: 3.0)

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:temperature, :out_of_range} in errors
    end

    test "fails on temperature out of range (negative)" do
      req = Request.new([%Message{role: :user, content: "hi"}], temperature: -0.1)

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:temperature, :out_of_range} in errors
    end

    test "accepts temperature at range boundaries" do
      assert :ok =
               Validate.request(
                 Request.new([%Message{role: :user, content: "hi"}], temperature: 0.0)
               )

      assert :ok =
               Validate.request(
                 Request.new([%Message{role: :user, content: "hi"}], temperature: 2.0)
               )
    end

    test "fails on non-positive max_tokens" do
      req = Request.new([%Message{role: :user, content: "hi"}], max_tokens: 0)

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:max_tokens, :must_be_positive} in errors
    end

    test "fails on structured_finalize: true without json_schema response_format" do
      req =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          structured_finalize: true
        )

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:structured_finalize, :requires_json_schema} in errors
    end

    test "structured_finalize: true with json_schema response_format is OK" do
      req =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          structured_finalize: true,
          response_format: %{
            type: :json_schema,
            name: "out",
            schema: %{"type" => "object"},
            strict: true
          }
        )

      assert :ok = Validate.request(req)
    end

    test "accepts response_format :text and %{type: :json_object} and %{type: :json_schema}" do
      base = [%Message{role: :user, content: "hi"}]

      assert :ok = Validate.request(Request.new(base, response_format: nil))
      assert :ok = Validate.request(Request.new(base, response_format: :text))
      assert :ok = Validate.request(Request.new(base, response_format: %{type: :json_object}))

      assert :ok =
               Validate.request(
                 Request.new(base,
                   response_format: %{
                     type: :json_schema,
                     name: "x",
                     schema: %{"type" => "object"},
                     strict: false
                   }
                 )
               )
    end

    test "response_format escape-hatch (any other map) passes validation" do
      req =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          response_format: %{type: :exotic_vendor_format}
        )

      assert :ok = Validate.request(req)
    end

    test "response_format that is neither nil, atom, nor map is invalid" do
      req =
        Request.new(
          [%Message{role: :user, content: "hi"}],
          response_format: "json"
        )

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:response_format, :invalid_shape} in errors
    end

    test "propagates per-message errors with [:messages, idx, :field] path prefix" do
      req =
        Request.new([
          %Message{role: :user, content: "ok"},
          %Message{role: :bogus, content: "x"}
        ])

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {[:messages, 1, :role], :unknown} in errors
    end

    test "propagates per-tool errors with [:tools, idx, :field] path prefix" do
      req =
        Request.new(
          [%Message{role: :user, content: "ok"}],
          tools: [
            %Tool{name: "ok", description: "d", schema: %{}},
            %Tool{name: "has space", description: "d", schema: %{}}
          ]
        )

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {[:tools, 1, :name], :invalid_format} in errors
    end

    test "vision ImagePart in message content is accepted (v0.3 §35.6)" do
      img = Image.from_url("https://example.com/cat.png")

      req =
        Request.new([
          %Message{
            role: :user,
            content: [%TextPart{text: "describe"}, %ImagePart{image: img}]
          }
        ])

      assert :ok = Validate.request(req)
    end

    test "raw map content list element is rejected with :invalid_part_type" do
      req =
        Request.new([
          %Message{
            role: :user,
            content: [%{type: "image", url: "https://example.com/cat.png"}]
          }
        ])

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {[:messages, 0, :content], :invalid_part_type} in errors
    end

    # Defensive-branch coverage: `Request.new/2` would never produce a
    # non-numeric temperature, but a raw struct literal bypasses the
    # constructor. The fall-through clause in `validate_temperature/2`
    # catches this and reports `:out_of_range`. See retro
    # 2026-04-19-phase1-1.4-validate_applied.md Finding 7.
    test "fails on non-numeric temperature from a raw struct literal" do
      req = %Request{
        messages: [%Message{role: :user, content: "hi"}],
        temperature: "hot"
      }

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Validate.request(req)

      assert {:temperature, :out_of_range} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Validate.message/1
  # ---------------------------------------------------------------------------

  describe "message/1" do
    test "happy path returns :ok" do
      assert :ok = Validate.message(%Message{role: :user, content: "hi"})
    end

    test "accepts every legal role" do
      assert :ok = Validate.message(%Message{role: :system, content: "be nice"})
      assert :ok = Validate.message(%Message{role: :user, content: "hi"})
      assert :ok = Validate.message(%Message{role: :assistant, content: "hello"})

      assert :ok =
               Validate.message(%Message{role: :tool, content: "ok", tool_call_id: "call_1"})
    end

    test "fails on unknown role" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{role: :invalid, content: "hi"})

      assert {:role, :unknown} in errors
    end

    test "fails when role :tool lacks tool_call_id" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{role: :tool, content: "ok"})

      assert {:tool_call_id, :required} in errors
    end

    test "accepts string content" do
      assert :ok = Validate.message(%Message{role: :user, content: "plain string"})
    end

    test "accepts a list of TextPart structs" do
      assert :ok =
               Validate.message(%Message{
                 role: :user,
                 content: [%TextPart{text: "hello"}]
               })
    end

    test "accepts a mixed list of TextPart and ImagePart structs" do
      img = Image.from_url("https://example.com/cat.png")

      assert :ok =
               Validate.message(%Message{
                 role: :user,
                 content: [%TextPart{text: "describe"}, %ImagePart{image: img}]
               })
    end

    test "accepts a list of ImagePart structs alone" do
      img = Image.from_url("https://example.com/cat.png")

      assert :ok =
               Validate.message(%Message{
                 role: :user,
                 content: [%ImagePart{image: img, detail: :high}]
               })
    end

    test "rejects raw map content list element with [{:content, :invalid_part_type}]" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{
                 role: :user,
                 content: [%{type: "text", text: "x"}]
               })

      assert {:content, :invalid_part_type} in errors
    end

    test "rejects string-keyed image map (JSON-decoded shape) with :invalid_part_type" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{
                 role: :user,
                 content: [%{"type" => "image", "url" => "https://example.com/cat.png"}]
               })

      assert {:content, :invalid_part_type} in errors
    end

    test "rejects mixed list with one non-Part element with :invalid_part_type" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{
                 role: :user,
                 content: [%TextPart{text: "x"}, "raw string"]
               })

      assert {:content, :invalid_part_type} in errors
    end

    test "content that is neither string nor list is invalid" do
      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Validate.message(%Message{role: :user, content: 42})

      assert {:content, :invalid_type} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Validate.tool/1
  # ---------------------------------------------------------------------------

  describe "tool/1" do
    test "happy path returns :ok" do
      assert :ok =
               Validate.tool(%Tool{
                 name: "weather",
                 description: "lookup",
                 schema: %{"type" => "object"}
               })
    end

    test "fails on empty name" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "", description: "d", schema: %{}})

      assert {:name, :empty} in errors
    end

    test "fails on name with spaces" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "has spaces", description: "d", schema: %{}})

      assert {:name, :invalid_format} in errors
    end

    test "fails on name exceeding 64 characters" do
      long = String.duplicate("a", 65)

      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: long, description: "d", schema: %{}})

      assert {:name, :invalid_format} in errors
    end

    test "fails on description that is not a string" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "ok", description: 42, schema: %{}})

      assert {:description, :not_a_string} in errors
    end

    test "fails on schema that is not a map" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "ok", description: "d", schema: "not a map"})

      assert {:schema, :not_a_map} in errors
    end

    # Defensive-branch coverage: `Tool.new/1` with an atom name would raise
    # via `struct!/2`'s type handling, but a raw struct literal bypasses
    # that. The fall-through clause in `validate_tool_name/2` (non-binary)
    # catches this and reports `:invalid_format`. See retro
    # 2026-04-19-phase1-1.4-validate_applied.md Finding 7.
    test "fails on atom name from a raw struct literal" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: :atom_name, description: "d", schema: %{}})

      assert {:name, :invalid_format} in errors
    end

    # Reserved-name collision with `tool_choice` atom restoration: per sub-phase
    # 1.5 Finding 3, a tool named `"auto"` would round-trip to `:auto` on
    # decode. Rejecting these names at validation time makes the decoder
    # string-to-atom restoration safe by construction.
    test "fails on reserved tool name: auto" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "auto", description: "d", schema: %{}})

      assert {:name, :reserved_tool_name} in errors
    end

    test "fails on reserved tool name: none" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "none", description: "d", schema: %{}})

      assert {:name, :reserved_tool_name} in errors
    end

    test "fails on reserved tool name: required" do
      assert {:error, %ValidationError{reason: :invalid_tool, errors: errors}} =
               Validate.tool(%Tool{name: "required", description: "d", schema: %{}})

      assert {:name, :reserved_tool_name} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Validate.thread/1
  # ---------------------------------------------------------------------------

  describe "thread/1" do
    test "happy path returns :ok" do
      t =
        Thread.from_messages([
          %Message{role: :user, content: "hi"},
          %Message{role: :assistant, content: "hello"}
        ])

      assert :ok = Validate.thread(t)
    end

    test "propagates per-message errors with [:messages, idx, :field] path" do
      t =
        Thread.from_messages([
          %Message{role: :user, content: "ok"},
          %Message{role: :bogus, content: "x"},
          %Message{role: :tool, content: "missing id"}
        ])

      assert {:error, %ValidationError{reason: :invalid_thread, errors: errors}} =
               Validate.thread(t)

      assert {[:messages, 1, :role], :unknown} in errors
      assert {[:messages, 2, :tool_call_id], :required} in errors
    end

    test "ImagePart in thread message is accepted (v0.3 §35.6)" do
      img = Image.from_url("https://example.com/cat.png")

      t =
        Thread.from_messages([
          %Message{
            role: :user,
            content: [%TextPart{text: "describe"}, %ImagePart{image: img}]
          }
        ])

      assert :ok = Validate.thread(t)
    end

    test "raw map content in thread message is rejected with :invalid_part_type" do
      t =
        Thread.from_messages([
          %Message{
            role: :user,
            content: [%{type: "image", url: "x"}]
          }
        ])

      assert {:error, %ValidationError{reason: :invalid_thread, errors: errors}} =
               Validate.thread(t)

      assert {[:messages, 0, :content], :invalid_part_type} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Validate.session/1
  # ---------------------------------------------------------------------------

  describe "session/1" do
    test "happy path returns :ok for :idle with empty thread" do
      assert :ok = Validate.session(%Session{})
    end

    test "fails on unknown status" do
      s = %Session{status: :bogus}

      assert {:error, %ValidationError{reason: :invalid_session, errors: errors}} =
               Validate.session(s)

      assert {:status, :unknown} in errors
    end

    test "fails on :awaiting_user with nil pending_question" do
      s = %Session{status: :awaiting_user, pending_question: nil}

      assert {:error, %ValidationError{reason: :invalid_session, errors: errors}} =
               Validate.session(s)

      assert {:pending_question, :required_for_status} in errors
    end

    test "accepts :awaiting_user with pending_question set" do
      s = %Session{status: :awaiting_user, pending_question: "city?"}
      assert :ok = Validate.session(s)
    end

    test "fails on :awaiting_tools with empty pending_tool_calls" do
      s = %Session{status: :awaiting_tools, pending_tool_calls: []}

      assert {:error, %ValidationError{reason: :invalid_session, errors: errors}} =
               Validate.session(s)

      assert {:pending_tool_calls, :required_for_status} in errors
    end

    test "accepts :awaiting_tools with non-empty pending_tool_calls" do
      s = %Session{
        status: :awaiting_tools,
        pending_tool_calls: [
          %ToolCall{id: "c1", name: "weather", arguments: %{}}
        ]
      }

      assert :ok = Validate.session(s)
    end

    test "fails on :error with empty metadata (missing :error key)" do
      s = %Session{status: :error, metadata: %{}}

      assert {:error, %ValidationError{reason: :invalid_session, errors: errors}} =
               Validate.session(s)

      assert {:metadata, :error_required_for_status} in errors
    end

    test "accepts :error status with metadata[:error] populated" do
      s = %Session{
        status: :error,
        metadata: %{error: %ALLM.Error.AdapterError{reason: :unknown, message: "boom"}}
      }

      assert :ok = Validate.session(s)
    end

    test "propagates thread validation errors" do
      s = %Session{
        thread: Thread.from_messages([%Message{role: :bogus, content: "x"}])
      }

      assert {:error, %ValidationError{reason: :invalid_session, errors: errors}} =
               Validate.session(s)

      assert {[:thread, :messages, 0, :role], :unknown} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Property: random-field-valid Request -> Validate.request/1 == :ok
  # ---------------------------------------------------------------------------

  describe "property: valid-fields request" do
    property "random-field-valid Request validates to :ok" do
      check all(
              msgs <- StreamData.list_of(Generators.message_gen(), min_length: 1, max_length: 5),
              temp <-
                StreamData.one_of([StreamData.constant(nil), StreamData.float(min: 0.0, max: 2.0)]),
              max_t <-
                StreamData.one_of([
                  StreamData.constant(nil),
                  StreamData.integer(1..4096)
                ]),
              tools <- StreamData.list_of(Generators.tool_gen(), max_length: 3)
            ) do
        tools = Enum.uniq_by(tools, & &1.name)

        req =
          Request.new(msgs,
            temperature: temp,
            max_tokens: max_t,
            tools: tools
          )

        assert :ok = Validate.request(req)
      end
    end
  end
end
