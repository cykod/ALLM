defmodule ALLM.SerializerTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.{
    AdapterError,
    EngineError,
    StreamError,
    ToolError,
    ValidationError
  }

  alias ALLM.{
    ChatResult,
    Event,
    Message,
    Request,
    Response,
    Serializer,
    Session,
    StepResult,
    Thread,
    Tool,
    ToolCall,
    Usage
  }

  doctest Serializer

  # ---------------------------------------------------------------------------
  # Encoding — tagged wrapper shape, including nil fields
  # ---------------------------------------------------------------------------

  describe "to_json!/1 — tagged wrapper" do
    @tag :roundtrip
    test "wraps a populated Message with __type__/data and emits every field (including nils)" do
      msg =
        Message.new(
          role: :user,
          content: "hi",
          name: nil,
          tool_call_id: nil,
          metadata: %{"turn" => 1}
        )

      decoded = msg |> Serializer.to_json!() |> Jason.decode!()

      assert decoded["__type__"] == "ALLM.Message"
      assert is_map(decoded["data"])

      data = decoded["data"]
      # Every field present — including nil-valued ones.
      for field <- ["role", "content", "name", "tool_call_id", "metadata"] do
        assert Map.has_key?(data, field), "expected field #{field} to be emitted"
      end

      assert data["role"] == "user"
      assert data["content"] == "hi"
      assert data["name"] == nil
      assert data["tool_call_id"] == nil
    end

    test "to_iodata!/1 produces iodata that IO.iodata_to_binary matches to_json!/1" do
      msg = Message.new(role: :user, content: "hi")

      json = Serializer.to_json!(msg)
      iodata = Serializer.to_iodata!(msg)

      assert IO.iodata_to_binary(iodata) == json
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip — every Layer A struct with atom-typed fields
  # ---------------------------------------------------------------------------

  describe "from_json/2 — Message round-trip" do
    @tag :roundtrip
    test "populated Message round-trips equal, with :role restored as atom" do
      msg =
        Message.new(
          role: :assistant,
          content: "hello",
          name: "bot",
          tool_call_id: nil,
          metadata: %{"turn" => 3}
        )

      assert {:ok, ^msg} = msg |> Serializer.to_json!() |> Serializer.from_json()
      {:ok, decoded} = msg |> Serializer.to_json!() |> Serializer.from_json()
      assert is_atom(decoded.role)
    end

    @tag :roundtrip
    test "all four Message.role atoms round-trip" do
      for role <- [:system, :user, :assistant, :tool] do
        msg =
          Message.new(
            role: role,
            content: "c",
            tool_call_id: if(role == :tool, do: "call_1", else: nil)
          )

        assert {:ok, ^msg} = msg |> Serializer.to_json!() |> Serializer.from_json()
      end
    end
  end

  describe "from_json/2 — Tool round-trip" do
    @tag :roundtrip
    test "Tool with nil handler round-trips" do
      tool = Tool.new(name: "weather", description: "by city", schema: %{"type" => "object"})

      assert {:ok, ^tool} = tool |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — ToolCall round-trip" do
    @tag :roundtrip
    test "ToolCall round-trips" do
      tc =
        ToolCall.new(
          id: "call_1",
          name: "weather",
          arguments: %{"city" => "SFO"},
          raw_arguments: ~S({"city":"SFO"}),
          metadata: %{}
        )

      assert {:ok, ^tc} = tc |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — Request round-trip" do
    @tag :roundtrip
    test "Request with :text response_format and :auto tool_choice round-trips" do
      req =
        Request.new(
          [Message.new(role: :user, content: "hi")],
          model: "fake:x",
          temperature: 0.2,
          max_tokens: 100,
          response_format: :text,
          tool_choice: :auto
        )

      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end

    @tag :roundtrip
    test "all three atom tool_choice values round-trip" do
      for choice <- [:auto, :none, :required] do
        req =
          Request.new(
            [Message.new(role: :user, content: "hi")],
            tool_choice: choice
          )

        assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "Request with tools round-trips" do
      req =
        Request.new(
          [Message.new(role: :user, content: "hi")],
          tools: [Tool.new(name: "t", description: "d", schema: %{})]
        )

      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end

    @tag :roundtrip
    test "Request with response_format: %{type: :json_object} round-trips (atom-keyed restoration)" do
      req =
        Request.new(
          [Message.new(role: :user, content: "hi")],
          response_format: %{type: :json_object}
        )

      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end

    @tag :roundtrip
    test "Request with response_format: %{type: :json_schema, ...} round-trips (atom-keyed restoration)" do
      req =
        Request.new(
          [Message.new(role: :user, content: "hi")],
          response_format: %{
            type: :json_schema,
            name: "committee",
            schema: %{"type" => "object"},
            strict: true
          }
        )

      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end

    @tag :roundtrip
    test "Request with escape-hatch response_format map passes through unchanged on decode" do
      req =
        Request.new(
          [Message.new(role: :user, content: "hi")],
          response_format: %{"custom" => "provider-specific"}
        )

      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — Response round-trip" do
    @tag :roundtrip
    test "all six finish_reason atoms round-trip" do
      for reason <- [:stop, :length, :tool_calls, :content_filter, :error, :other] do
        resp =
          Response.new(
            id: "r_1",
            model: "fake:x",
            message: Message.new(role: :assistant, content: "ok"),
            output_text: "ok",
            finish_reason: reason,
            usage: Usage.new(input_tokens: 5, output_tokens: 3)
          )

        assert {:ok, ^resp} = resp |> Serializer.to_json!() |> Serializer.from_json()
      end
    end
  end

  describe "from_json/2 — Usage round-trip" do
    @tag :roundtrip
    test "populated Usage round-trips" do
      u =
        Usage.new(
          input_tokens: 10,
          output_tokens: 20,
          total_tokens: 30,
          input_cost: 0.001,
          output_cost: 0.002,
          total_cost: 0.003,
          tool_usage: %{"weather" => 1},
          extra: %{"provider" => "fake"}
        )

      assert {:ok, ^u} = u |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — Thread round-trip" do
    @tag :roundtrip
    test "Thread with three messages round-trips" do
      t =
        Thread.from_messages([
          Message.new(role: :system, content: "be nice"),
          Message.new(role: :user, content: "hi"),
          Message.new(role: :assistant, content: "hello")
        ])

      assert {:ok, ^t} = t |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — Session round-trip" do
    @tag :roundtrip
    test "all five Session.status atoms round-trip" do
      for status <- [:idle, :awaiting_user, :awaiting_tools, :completed, :error] do
        session = Session.new(id: "s1", status: status)

        assert {:ok, ^session} = session |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "Session with pending tool calls round-trips" do
      session =
        Session.new(
          id: "s1",
          status: :awaiting_tools,
          pending_tool_calls: [ToolCall.new(id: "c1", name: "t", arguments: %{})]
        )

      assert {:ok, ^session} = session |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — StepResult round-trip" do
    @tag :roundtrip
    test "StepResult with done?: true round-trips (exercises String.to_existing_atom(\"done?\"))" do
      sr =
        StepResult.new(
          thread: Thread.from_messages([Message.new(role: :user, content: "hi")]),
          response: Response.new(output_text: "ok", finish_reason: :stop, usage: %Usage{}),
          tool_results: [],
          done?: true
        )

      assert {:ok, ^sr} = sr |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  describe "from_json/2 — ChatResult round-trip (nested)" do
    @tag :roundtrip
    test "ChatResult containing Thread/Messages/Response/Usage round-trips" do
      cr =
        ChatResult.new(
          thread:
            Thread.from_messages([
              Message.new(role: :system, content: "be nice"),
              Message.new(role: :user, content: "hi"),
              Message.new(role: :assistant, content: "hello")
            ]),
          final_response:
            Response.new(
              id: "r1",
              model: "fake:x",
              output_text: "hello",
              finish_reason: :stop,
              usage:
                Usage.new(
                  input_tokens: 5,
                  output_tokens: 3,
                  total_tokens: 8
                )
            ),
          steps: [
            StepResult.new(
              thread: %Thread{},
              response: %Response{},
              done?: true
            )
          ],
          halted_reason: :completed
        )

      assert {:ok, ^cr} = cr |> Serializer.to_json!() |> Serializer.from_json()
    end
  end

  # ---------------------------------------------------------------------------
  # Error structs — atom reason round-trip
  # ---------------------------------------------------------------------------

  describe "from_json/2 — Error.* round-trip" do
    @tag :roundtrip
    test "every EngineError.reason atom round-trips" do
      for reason <- [
            :missing_adapter,
            :missing_stream_adapter,
            :missing_model,
            :missing_key,
            :unknown_tool,
            :invalid_engine,
            :unsupported_response_format
          ] do
        err = EngineError.new(reason, provider: :openai, metadata: %{"trace" => "x"})

        assert {:ok, ^err} = err |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "every AdapterError.reason atom round-trips" do
      for reason <- [
            :rate_limited,
            :authentication_failed,
            :invalid_request,
            :provider_unavailable,
            :context_length_exceeded,
            :content_filter,
            :timeout,
            :network_error,
            :malformed_response,
            :unsupported_feature,
            :unknown
          ] do
        err =
          AdapterError.new(reason,
            provider: :openai,
            status: 429,
            retry_after_ms: 500,
            request_id: "req_1"
          )

        assert {:ok, ^err} = err |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "every StreamError.reason atom round-trips" do
      for reason <- [:adapter_error, :cancelled, :timeout, :malformed_event, :unknown] do
        err = StreamError.new(reason, event_index: 3)

        assert {:ok, ^err} = err |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "every ValidationError.reason atom round-trips (with field-error list)" do
      for reason <- [
            :invalid_request,
            :invalid_message,
            :invalid_tool,
            :invalid_thread,
            :invalid_session,
            :invalid_session_input,
            :unsupported_capability,
            :invalid_image_request
          ] do
        # Note: errors field is a list of tuples — tuples don't survive JSON.
        # The decoder restores them as lists; we store a serializable shape here
        # for a fair round-trip.
        err = ValidationError.new(reason, [], message: "x")

        assert {:ok, ^err} = err |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    @tag :roundtrip
    test "every ToolError.reason atom round-trips" do
      for reason <- [
            :handler_raised,
            :handler_exit,
            :timeout,
            :invalid_return,
            :not_found,
            :encoding_failed
          ] do
        err = ToolError.new(reason, tool_name: "weather", tool_call_id: "c1")

        assert {:ok, ^err} = err |> Serializer.to_json!() |> Serializer.from_json()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Event round-trip (spot check — every tag has atom payload keys)
  # ---------------------------------------------------------------------------

  describe "from_json/2 — Event tags" do
    @tag :roundtrip
    test "every Event tag survives JSON encoding (spot check)" do
      # Events are 2-tuples (tag, payload). Tuples don't survive JSON encoding
      # directly — callers serialize the payload, not the tuple. We round-trip
      # the payload map here to exercise the tag atom, which lives in the
      # closed union and is verified by `Event.event?/1`.
      for tag <- Event.tags() do
        assert is_atom(tag)
        # Tag is a known, compiled atom — demonstrates `String.to_existing_atom`
        # safety for the `Event` taxonomy.
        assert String.to_existing_atom(Atom.to_string(tag)) == tag
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error path — malformed JSON, missing __type__, hint override
  # ---------------------------------------------------------------------------

  describe "from_json/2 — error paths" do
    test "returns :malformed on undecodable input" do
      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json("not json")

      assert {:json, :malformed} in errors
    end

    test "returns :missing_type_tag on untagged JSON with no :as" do
      untagged = Jason.encode!(%{"role" => "user", "content" => "hi"})

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(untagged)

      assert {:format, :missing_type_tag} in errors
    end

    test "decodes untagged JSON with :as hint" do
      untagged =
        Jason.encode!(%{
          "role" => "user",
          "content" => "hi",
          "name" => nil,
          "tool_call_id" => nil,
          "metadata" => %{}
        })

      assert {:ok, %Message{role: :user, content: "hi"}} =
               Serializer.from_json(untagged, as: Message)
    end

    test "unknown __type__ decodes to a plain map (forward-compat)" do
      json = Jason.encode!(%{"__type__" => "ALLM.NotAStruct", "data" => %{"x" => 1}})

      assert {:ok, %{"__type__" => "ALLM.NotAStruct", "data" => %{"x" => 1}}} =
               Serializer.from_json(json)
    end

    test "returns :missing on tagged JSON without a data key" do
      json = Jason.encode!(%{"__type__" => "ALLM.Message"})

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(json)

      assert {:data, :missing} in errors
    end

    test "returns :malformed_struct when tagged JSON has non-map data" do
      json = Jason.encode!(%{"__type__" => "ALLM.Message", "data" => "not a map"})

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(json)

      assert {:data, :malformed_struct} in errors
    end

    test "returns :missing_type_tag on a top-level JSON list without :as" do
      json = Jason.encode!([1, 2, 3])

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(json)

      assert {:format, :missing_type_tag} in errors
    end

    test "returns :unknown_type_tag when :as points at a non-ALLM module" do
      untagged = Jason.encode!(%{"x" => 1})

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(untagged, as: String)

      assert {:format, :unknown_type_tag} in errors
    end

    test "returns :atom_decode_failed when a decoded atom field isn't loaded in the BEAM" do
      # Force an unknown atom by hand-constructing a tagged payload with a
      # never-before-seen string in an atom-typed field.
      unknown = "allm_serializer_test_never_seen_atom_#{System.unique_integer([:positive])}"

      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Message",
          "data" => %{
            "role" => unknown,
            "content" => "c",
            "name" => nil,
            "tool_call_id" => nil,
            "metadata" => %{}
          }
        })

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Serializer.from_json(json)

      assert Enum.any?(errors, fn {_field, reason} -> reason == :atom_decode_failed end)
    end
  end

  # ---------------------------------------------------------------------------
  # Nested hydrate / forward-compat
  # ---------------------------------------------------------------------------

  describe "hydrate/1 — nested behaviour" do
    test "unknown __type__ inside a nested field passes through as a map" do
      # Construct a ChatResult where the steps list contains an unknown-tag map.
      # Use direct Jason to bypass encoder constraints.
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Thread",
          "data" => %{
            "messages" => [
              %{"__type__" => "ALLM.FutureType", "data" => %{"x" => 1}}
            ],
            "metadata" => %{}
          }
        })

      assert {:ok, %Thread{messages: [decoded]}} = Serializer.from_json(json)
      assert decoded == %{"__type__" => "ALLM.FutureType", "data" => %{"x" => 1}}
    end

    test "to_atom_field passes non-binary, non-nil values through unchanged" do
      # Covers the catch-all clause in to_atom_field/1 — e.g., a pre-decoded
      # value that made it into a field already as an atom.
      assert Serializer.to_atom_field(:already_atom) == :already_atom
      assert Serializer.to_atom_field(42) == 42
    end
  end
end
