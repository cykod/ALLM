defmodule ALLM.EngineTest do
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Tool}

  doctest Engine

  # A small helper to make tool construction one-line.
  defp tool(name, opts \\ []) do
    Tool.new(
      Keyword.merge(
        [name: name, description: "desc-#{name}", schema: %{}],
        opts
      )
    )
  end

  # ---------------------------------------------------------------------------
  # new/1 — stable :id identity (§6, footgun design Phase 1)
  # ---------------------------------------------------------------------------

  describe "new/1 :id stamping" do
    test "stamps a positive-integer :id when none is supplied" do
      engine = Engine.new(adapter: ALLM.Providers.Fake)
      assert is_integer(engine.id)
      assert engine.id > 0
    end

    test "with explicit id: preserves it" do
      assert Engine.new(id: 42, adapter: ALLM.Providers.Fake).id == 42
    end

    test "two calls with identical opts produce distinct ids" do
      opts = [adapter: ALLM.Providers.Fake, model: "m"]
      assert Engine.new(opts).id != Engine.new(opts).id
    end

    test "with_model/2 preserves :id" do
      engine = Engine.new(model: "old")
      assert Engine.with_model(engine, "new").id == engine.id
    end

    test "merge_opts/2 preserves :id" do
      engine = Engine.new(model: "old")
      assert Engine.merge_opts(engine, model: "new").id == engine.id
    end

    test "put_tool/2 preserves :id" do
      engine = Engine.new()
      assert Engine.put_tool(engine, tool("a")).id == engine.id
    end

    test "a hand-built %Engine{} struct has id: nil" do
      assert %Engine{}.id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # put_cursor_key/2 — inject :id as adapter_opts[:cursor_key] (§31)
  # ---------------------------------------------------------------------------

  describe "put_cursor_key/2" do
    test "stamps the engine :id as :cursor_key on empty opts" do
      engine = Engine.new(adapter: ALLM.Providers.Fake)
      assert Engine.put_cursor_key([], engine) == [cursor_key: engine.id]
    end

    test "passes opts through untouched for a nil-id engine" do
      assert Engine.put_cursor_key([scripts: 1], %Engine{id: nil}) == [scripts: 1]
    end

    test "a caller-supplied :cursor_key wins (put_new precedence)" do
      engine = Engine.new(adapter: ALLM.Providers.Fake)
      assert Engine.put_cursor_key([cursor_key: 999], engine) == [cursor_key: 999]
    end
  end

  # ---------------------------------------------------------------------------
  # merge_opts/2
  # ---------------------------------------------------------------------------

  describe "merge_opts/2" do
    test "is a no-op when opts is []" do
      engine =
        Engine.new(adapter: ALLM.Providers.Fake, model: "m")
        |> Engine.put_tool(tool("a"))
        |> Engine.put_param(:temperature, 0.2)
        |> Engine.put_context(:user_id, 1)

      assert Engine.merge_opts(engine, []) == engine
    end

    test "[model: m] sets engine.model" do
      engine = Engine.new(model: "old")
      assert Engine.merge_opts(engine, model: "new").model == "new"
    end

    test "[tools: ts] merges tools with dedup-by-name (opts wins in-place)" do
      a = tool("a")
      b = tool("b")
      c = tool("c")
      b_prime = tool("b", description: "opts-override")
      d = tool("d")

      engine = Engine.new() |> Engine.put_tools([a, b, c])
      merged = Engine.merge_opts(engine, tools: [b_prime, d])

      assert merged.tools == [a, b_prime, c, d]
    end

    test "[params: %{...}] shallow-merges into engine.params" do
      engine = Engine.new(params: %{temperature: 0.5, top_p: 1.0})
      merged = Engine.merge_opts(engine, params: %{temperature: 0.9, max_tokens: 100})
      assert merged.params == %{temperature: 0.9, top_p: 1.0, max_tokens: 100}
    end

    test "[context: %{...}] shallow-merges into engine.context" do
      engine = Engine.new(context: %{user_id: 1, tenant: "t"})
      merged = Engine.merge_opts(engine, context: %{user_id: 2, locale: "en"})
      assert merged.context == %{user_id: 2, tenant: "t", locale: "en"}
    end

    test "unknown keys are silently dropped" do
      engine = Engine.new(model: "m")
      merged = Engine.merge_opts(engine, potato: :idaho, reasoning_effort: "high")
      # No new field shows up anywhere: unknown opts are ignored by merge_opts
      # (they're for execution functions, not the engine itself).
      assert merged == engine
    end

    test "composes multiple recognized opts in one call" do
      engine =
        Engine.new(model: "old", params: %{temperature: 0.1})
        |> Engine.put_tool(tool("a"))

      merged =
        Engine.merge_opts(engine,
          model: "new",
          tools: [tool("b")],
          params: %{temperature: 0.9}
        )

      assert merged.model == "new"
      assert Enum.map(merged.tools, & &1.name) == ["a", "b"]
      assert merged.params == %{temperature: 0.9}
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_model/2
  # ---------------------------------------------------------------------------

  describe "resolve_model/2" do
    test "with no opts returns engine.model" do
      engine = Engine.new(model: "gpt-x")
      assert Engine.resolve_model(engine, []) == "gpt-x"
    end

    test "with no opts returns nil when engine.model is nil" do
      engine = Engine.new()
      assert Engine.resolve_model(engine, []) == nil
    end

    test "[model: x] wins over engine.model" do
      engine = Engine.new(model: "engine-model")
      assert Engine.resolve_model(engine, model: "override") == "override"
    end

    test "tuple model passes through verbatim (llm_db absent)" do
      engine = Engine.new(model: {:openai, "gpt-x"})
      assert Engine.resolve_model(engine, []) == {:openai, "gpt-x"}
    end

    test "tuple model via opts passes through verbatim" do
      engine = Engine.new()
      assert Engine.resolve_model(engine, model: {:anthropic, "claude"}) == {:anthropic, "claude"}
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_tools/2
  # ---------------------------------------------------------------------------

  describe "resolve_tools/2" do
    test "with no opts returns engine.tools verbatim" do
      a = tool("a")
      b = tool("b")
      engine = Engine.new() |> Engine.put_tools([a, b])
      assert Engine.resolve_tools(engine, []) == [a, b]
    end

    test "with no opts and no engine tools returns []" do
      engine = Engine.new()
      assert Engine.resolve_tools(engine, []) == []
    end

    test "opts tool with matching name replaces engine tool in place" do
      a = tool("a")
      b = tool("b")
      c = tool("c")
      b_prime = tool("b", description: "override")

      engine = Engine.new() |> Engine.put_tools([a, b, c])
      assert Engine.resolve_tools(engine, tools: [b_prime]) == [a, b_prime, c]
    end

    test "opts tools with new names are appended in opts order" do
      a = tool("a")
      d = tool("d")
      e = tool("e")

      engine = Engine.new() |> Engine.put_tools([a])
      assert Engine.resolve_tools(engine, tools: [d, e]) == [a, d, e]
    end

    test "mixed collision + new (Decision #4 example)" do
      a = tool("a")
      b = tool("b")
      c = tool("c")
      b_prime = tool("b", description: "override")
      d = tool("d")

      engine = Engine.new() |> Engine.put_tools([a, b, c])
      assert Engine.resolve_tools(engine, tools: [b_prime, d]) == [a, b_prime, c, d]
    end

    test "empty opts tools yields engine tools unchanged" do
      a = tool("a")
      engine = Engine.new() |> Engine.put_tool(a)
      assert Engine.resolve_tools(engine, tools: []) == [a]
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_params/2
  # ---------------------------------------------------------------------------

  describe "resolve_params/2" do
    test "with no opts returns engine.params unchanged" do
      engine = Engine.new(params: %{temperature: 0.2, top_p: 1.0})
      assert Engine.resolve_params(engine, []) == %{temperature: 0.2, top_p: 1.0}
    end

    test "with empty engine.params and no opts returns empty map" do
      engine = Engine.new()
      assert Engine.resolve_params(engine, []) == %{}
    end

    test "[temperature: 0.7] merges into engine.params" do
      engine = Engine.new(params: %{temperature: 0.2, top_p: 1.0})
      assert Engine.resolve_params(engine, temperature: 0.7) == %{temperature: 0.7, top_p: 1.0}
    end

    test "opts value wins over engine.params for colliding keys" do
      engine = Engine.new(params: %{temperature: 0.2})
      assert Engine.resolve_params(engine, temperature: 0.9) == %{temperature: 0.9}
    end

    test "engine-field keys are filtered out (not forwarded into params)" do
      engine = Engine.new(params: %{temperature: 0.2})

      result =
        Engine.resolve_params(engine,
          adapter: ALLM.Providers.Fake,
          adapter_opts: [a: 1],
          model: "m",
          tools: [],
          tool_executor: Some.Mod,
          tool_result_encoder: Some.Mod,
          image_adapter: Some.Mod,
          params: %{should_not_leak: true},
          context: %{},
          retry: :default,
          middleware: [],
          metadata: %{},
          api_key: "secret"
        )

      # None of the engine-field keys should leak into the params map.
      refute Map.has_key?(result, :adapter)
      refute Map.has_key?(result, :adapter_opts)
      refute Map.has_key?(result, :model)
      refute Map.has_key?(result, :tools)
      refute Map.has_key?(result, :tool_executor)
      refute Map.has_key?(result, :tool_result_encoder)
      refute Map.has_key?(result, :image_adapter)
      refute Map.has_key?(result, :params)
      refute Map.has_key?(result, :context)
      refute Map.has_key?(result, :retry)
      refute Map.has_key?(result, :middleware)
      refute Map.has_key?(result, :metadata)
      refute Map.has_key?(result, :api_key)

      # engine.params still flows through; the opts[:params] value was
      # dropped by the deny-list filter, not merged in.
      assert result == %{temperature: 0.2}
    end

    test "provider-specific keys flow through (§10 forwarding)" do
      engine = Engine.new()

      result =
        Engine.resolve_params(engine,
          reasoning_effort: "high",
          potato: :idaho,
          response_format: :json
        )

      assert result == %{reasoning_effort: "high", potato: :idaho, response_format: :json}
    end

    test "orchestration keys flow through (max_turns, halt_when live in params per §22)" do
      engine = Engine.new(params: %{temperature: 0.1})

      result =
        Engine.resolve_params(engine, max_turns: 3, halt_when: :some_atom, on_event: {Mod, :fun})

      assert result == %{
               temperature: 0.1,
               max_turns: 3,
               halt_when: :some_atom,
               on_event: {Mod, :fun}
             }
    end

    test "returns a map (not a keyword list)" do
      engine = Engine.new()
      result = Engine.resolve_params(engine, temperature: 0.7)
      assert is_map(result)
      refute is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # :moderation_adapter — Phase 22.2 (§39)
  # ---------------------------------------------------------------------------

  describe ":moderation_adapter" do
    test "new/1 accepts moderation_adapter: SomeModule" do
      engine = Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
      assert engine.moderation_adapter == ALLM.Providers.FakeModeration
    end

    test "new/1 defaults :moderation_adapter to nil" do
      assert Engine.new().moderation_adapter == nil
    end

    test "new/1 with moderation_adapter: {Mod, []} raises ArgumentError" do
      assert_raise ArgumentError, ~r/moderation_adapter/, fn ->
        Engine.new(moderation_adapter: {ALLM.Providers.FakeModeration, []})
      end
    end

    test "an engine carrying :moderation_adapter round-trips through JSON" do
      engine = Engine.new(moderation_adapter: ALLM.Providers.FakeModeration, model: "omni")
      json = ALLM.Serializer.to_json!(engine)

      assert {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert decoded.moderation_adapter == ALLM.Providers.FakeModeration
      assert is_atom(decoded.moderation_adapter)
    end

    test "an engine carrying :moderation_adapter round-trips through term_to_binary" do
      engine = Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
      assert engine == engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "resolve_params/2 does not leak :moderation_adapter into params" do
      engine = Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)

      params =
        Engine.resolve_params(engine,
          moderation_adapter: ALLM.Providers.FakeModeration,
          temperature: 0.4
        )

      refute Map.has_key?(params, :moderation_adapter)
      assert params == %{temperature: 0.4}
    end
  end
end
