defmodule ALLM.EnginePropertyTest do
  @moduledoc """
  Property tests for `ALLM.Engine` resolvers.

  Sub-phase 2.3 adds a property asserting that `resolve_model/2` is total and
  pass-through when `llm_db` is not loaded in the BEAM — the default v0.2
  configuration. Phase 2 ships with the optional `:llm_db` dep deliberately
  absent (see `mix.exs` comment), so `Code.ensure_loaded?/1` always returns
  false inside `resolve_model/2` and the branch collapses to "return the
  chosen value verbatim." This property is documentation-as-a-test for
  Phase 9 — when the real `llm_db` dep (or a test stub) lands, this test
  guards against regressions in the catalog-absent path.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.{Engine, Tool}
  alias ALLM.Test.Generators

  # The engine-field deny-list from Non-obvious decision #5; any opts key in
  # here is filtered out of `resolve_params/2`'s result. Must stay in sync
  # with `ALLM.Engine.@engine_field_keys`.
  @engine_field_keys [
    :adapter,
    :adapter_opts,
    :model,
    :tools,
    :tool_executor,
    :tool_result_encoder,
    :image_adapter,
    :params,
    :context,
    :retry,
    :middleware,
    :metadata,
    :api_key
  ]

  # Generators -----------------------------------------------------------------

  defp params_gen do
    StreamData.map_of(
      StreamData.atom(:alphanumeric),
      StreamData.one_of([
        StreamData.integer(),
        StreamData.float(),
        StreamData.string(:printable, max_length: 10),
        StreamData.boolean()
      ]),
      max_length: 4
    )
  end

  defp engine_gen do
    StreamData.bind(params_gen(), fn params ->
      StreamData.bind(StreamData.list_of(Generators.tool_gen(), max_length: 3), fn tools ->
        StreamData.constant(Engine.new(params: params, tools: Enum.uniq_by(tools, & &1.name)))
      end)
    end)
  end

  # A key that is NOT in the engine-field deny-list. We draw from a small fixed
  # pool of provider-/orchestration-style atom names.
  defp non_engine_key_gen do
    StreamData.member_of([
      :temperature,
      :top_p,
      :max_tokens,
      :max_turns,
      :halt_when,
      :reasoning_effort,
      :potato,
      :seed,
      :response_format,
      :stop
    ])
  end

  defp engine_field_key_gen do
    StreamData.member_of(@engine_field_keys)
  end

  defp value_gen do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.string(:printable, max_length: 10),
      StreamData.atom(:alphanumeric),
      StreamData.boolean()
    ])
  end

  defp binary_model_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  # Properties ----------------------------------------------------------------

  property "resolve_params/2: non-deny-list keys flow through with opts value" do
    check all(
            engine <- engine_gen(),
            key <- non_engine_key_gen(),
            value <- value_gen()
          ) do
      result = Engine.resolve_params(engine, [{key, value}])
      assert Map.get(result, key) == value
    end
  end

  property "resolve_params/2: engine-field keys never appear in the result" do
    check all(
            engine <- engine_gen(),
            key <- engine_field_key_gen(),
            value <- value_gen()
          ) do
      result = Engine.resolve_params(engine, [{key, value}])
      refute Map.has_key?(result, key)
    end
  end

  property "resolve_model/2: [model: m] with m binary returns m for any engine" do
    check all(
            engine <- engine_gen(),
            m <- binary_model_gen()
          ) do
      assert Engine.resolve_model(engine, model: m) == m
    end
  end

  property "resolve_model/2: llm_db-absent path is pass-through regardless of process state" do
    # Phase 2 has no `:llm_db` dep in the build, so `Code.ensure_loaded?/1`
    # returns `false` on every invocation. The property collapses to "return
    # the chosen value (opts[:model] || engine.model) verbatim" — but we
    # flip a process-dict flag between iterations to prove the resolver
    # doesn't accidentally depend on caller-local state (it shouldn't —
    # it's a pure function branching on `Code.ensure_loaded?/1`).
    check all(
            engine <- engine_gen(),
            m <- StreamData.one_of([StreamData.constant(nil), binary_model_gen()]),
            flag <- StreamData.boolean()
          ) do
      if flag do
        Process.put(:llm_db_loaded, true)
      else
        Process.delete(:llm_db_loaded)
      end

      opts = if is_nil(m), do: [], else: [model: m]
      expected = m || engine.model
      assert Engine.resolve_model(engine, opts) == expected
    end
  end

  property "resolve_tools/2: result length equals |ts1| + |ts2| - |name-intersection|" do
    check all(
            ts1 <- StreamData.list_of(Generators.tool_gen(), max_length: 5),
            ts2 <- StreamData.list_of(Generators.tool_gen(), max_length: 5)
          ) do
      ts1u = Enum.uniq_by(ts1, & &1.name)
      ts2u = Enum.uniq_by(ts2, & &1.name)

      names1 = MapSet.new(ts1u, & &1.name)
      names2 = MapSet.new(ts2u, & &1.name)
      intersect = MapSet.intersection(names1, names2) |> MapSet.size()

      engine = Engine.new(tools: ts1u)
      result = Engine.resolve_tools(engine, tools: ts2u)

      expected_len = length(ts1u) + length(ts2u) - intersect
      assert length(result) == expected_len

      # Sanity: every tool in the result is a %Tool{}.
      Enum.each(result, fn t -> assert %Tool{} = t end)

      # The result should be de-duplicated by name.
      result_names = Enum.map(result, & &1.name)
      assert result_names == Enum.uniq(result_names)
    end
  end
end
