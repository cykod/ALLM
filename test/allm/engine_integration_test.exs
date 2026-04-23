defmodule ALLM.EngineIntegrationTest do
  @moduledoc """
  Phase 2 end-to-end integration test (Sub-phase 2.4).

  Ties together the three prior sub-phases:

    * 2.1 — `ALLM.Engine.resolve_model/2`, `resolve_tools/2`, `resolve_params/2`
      (opts-win precedence per spec §10).
    * 2.2 — `ALLM.Keys` runtime store; keys are resolved at adapter-call time
      and never persisted on the engine (spec §6.4).
    * 2.3 — `:erlang.term_to_binary/1` round-trip on the engine struct
      (Non-obvious decision #7, closed contract).

  Four scenarios prove the surface composes:

    1. serialize → ship to a fresh process → deserialize → resolve — all
       three resolvers return the same value in the child process as in the
       parent.
    2. keys are not on the engine — a runtime key installed via
       `ALLM.Keys.put/2` does not leak into the serialized engine (verified
       by structurally walking the deserialized struct, not by substring
       search on the opaque binary).
    3. opts win end-to-end — per-call overrides win over engine defaults
       for each of the three resolvers, consistent with spec §10.
    4. MFA tool handlers round-trip through `:erlang.term_to_binary/1`
       (the module need not be loaded at decode time — the 2-tuple is
       opaque data to the VM).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ALLM.Engine
  alias ALLM.Keys
  alias ALLM.Tool

  setup do
    # Each scenario runs against a clean key store so runtime-key
    # assertions don't leak between tests or depend on execution order.
    Keys.Store.clear()
    on_exit(fn -> Keys.Store.clear() end)
    :ok
  end

  defp build_tool(name, opts \\ []) do
    Tool.new(
      Keyword.merge(
        [
          name: name,
          description: "tool #{name}",
          schema: %{"type" => "object"}
        ],
        opts
      )
    )
  end

  defp build_engine do
    tool_a = build_tool("a")
    tool_b = build_tool("b")

    Engine.new(
      # Harmless placeholder — this integration test never invokes the
      # adapter, it only exercises struct shape, serializability, and
      # the three opts-win resolvers. The canonical reference adapter
      # `ALLM.Providers.Fake` lands in Phase 4 per CLAUDE.md / spec §31;
      # until then any valid module atom satisfies `Engine.new/1`'s
      # `adapter` type. We use `ALLM.Engine` itself so no fake module is
      # referenced that doesn't exist yet.
      adapter: ALLM.Engine,
      adapter_opts: [timeout_ms: 5_000, base_url: "https://api.example.com"],
      model: "engine-default",
      tools: [tool_a, tool_b],
      params: %{temperature: 0.5},
      context: %{user_id: 42},
      metadata: %{trace_id: "abc-123"}
    )
  end

  # Recursively collect every string leaf reachable from `term`. Used to
  # prove Scenario 2 — the 2.4 design doc specifies this exact approach
  # (walk struct fields structurally) rather than `String.contains?/2` on
  # the ETF binary, because the binary's tag bytes can incidentally
  # include the same byte sequence as a short literal and produce a false
  # positive.
  defp string_leaves(%_{} = struct), do: struct |> Map.from_struct() |> string_leaves()

  defp string_leaves(map) when is_map(map) do
    Enum.flat_map(map, fn {_k, v} -> string_leaves(v) end)
  end

  defp string_leaves(list) when is_list(list), do: Enum.flat_map(list, &string_leaves/1)

  defp string_leaves(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> string_leaves()

  defp string_leaves(value) when is_binary(value), do: [value]
  defp string_leaves(_other), do: []

  test "Scenario 1: serialize, restore in a fresh process, resolve identically" do
    engine = build_engine()

    # Baseline in the parent process.
    original_model = Engine.resolve_model(engine, [])
    original_tools = Engine.resolve_tools(engine, [])
    original_params = Engine.resolve_params(engine, [])

    serialized = :erlang.term_to_binary(engine)

    # A `Task` runs in a fresh BEAM process — the deserialization happens
    # there and resolvers execute there too, proving the engine carries
    # no process-local state.
    task =
      Task.async(fn ->
        restored = :erlang.binary_to_term(serialized)

        %{
          restored: restored,
          model: Engine.resolve_model(restored, []),
          tools: Engine.resolve_tools(restored, []),
          params: Engine.resolve_params(restored, [])
        }
      end)

    %{restored: restored, model: model, tools: tools, params: params} =
      Task.await(task)

    assert restored == engine
    assert model == original_model
    assert tools == original_tools
    assert params == original_params
  end

  test "Scenario 2: runtime keys do not leak into the serialized engine" do
    # Install a runtime key with a deliberately short, unusual string so
    # the structural walk below can assert its absence unambiguously.
    secret = "rt-integration-secret-xyz"
    :ok = Keys.put(:fake, secret)

    # Sanity: the runtime store resolves the key (proves the setup is
    # valid — the later absence assertion means something).
    assert {:ok, ^secret, :runtime} = Keys.get(:fake)

    engine = build_engine()
    serialized = :erlang.term_to_binary(engine)
    restored = :erlang.binary_to_term(serialized)

    # Structural walk — not a substring search on the opaque binary. The
    # 2.4 design is explicit that `String.contains?/2` on the ETF binary
    # is too coarse. Instead, `Map.from_struct/1 |> Enum.flat_map(&string_leaves/1)`
    # visits every struct field recursively and collects string leaves.
    leaves = string_leaves(restored)

    refute secret in leaves,
           "runtime key #{inspect(secret)} leaked into engine fields: #{inspect(leaves)}"

    # The key is still resolvable via Keys.get/1 — it lives in the Agent
    # store, not on the engine (spec §6.4).
    assert {:ok, ^secret, :runtime} = Keys.get(:fake)
  end

  test "Scenario 3: opts win precedence end-to-end across all three resolvers" do
    engine = build_engine()

    override_tool = build_tool("b", description: "override")
    new_tool = build_tool("c")

    opts = [
      model: "override",
      # `:params` is an engine-field deny-list key per Non-obvious
      # decision #5 — it's consumed by `merge_opts/2`, not forwarded.
      # Passing `nil` asserts that resolve_params/2 drops it.
      params: nil,
      temperature: 0.9,
      tools: [override_tool, new_tool]
    ]

    assert Engine.resolve_model(engine, opts) == "override"

    # opts-win dedup: engine order preserved, engine tool "b" replaced in
    # place by override_tool, new_tool appended (Invariant 4).
    resolved_tools = Engine.resolve_tools(engine, opts)
    assert Enum.map(resolved_tools, & &1.name) == ["a", "b", "c"]
    assert Enum.at(resolved_tools, 1).description == "override"

    # resolve_params: `:model`, `:tools`, `:params` are engine-field keys
    # and never forwarded; `:temperature` is a shallow-merge winner over
    # `engine.params[:temperature]`.
    resolved_params = Engine.resolve_params(engine, opts)
    assert resolved_params == %{temperature: 0.9}
  end

  test "Scenario 4: MFA tool handler round-trips through term_to_binary" do
    # The module needn't be loaded at decode time — the tuple is opaque
    # data to the BEAM, and term_to_binary encodes it verbatim as a
    # 2-tuple of atoms. `MyApp.Tools` is a fresh atom created at this
    # source-read, which is sufficient.
    mfa_handler = {MyApp.Tools, :weather}

    tool =
      Tool.new(
        name: "weather",
        description: "weather by city",
        schema: %{"type" => "object"},
        handler: mfa_handler
      )

    # `adapter: ALLM.Engine` — harmless placeholder, same rationale as
    # `build_engine/0` above; the adapter is never invoked here.
    engine = Engine.new(adapter: ALLM.Engine, model: "m", tools: [tool])

    restored = engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert restored == engine
    [%Tool{handler: restored_handler}] = restored.tools
    assert restored_handler == mfa_handler
  end
end
