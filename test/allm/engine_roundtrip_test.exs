defmodule ALLM.EngineRoundtripTest do
  @moduledoc """
  Engine serializability round-trip suite (Sub-phase 2.3, Non-obvious decision #7).

  Every bullet in the 2.3 Test Plan is a test here. The positive cases prove
  `:erlang.term_to_binary/1` and the `ALLM.Serializer.to_json!/1` +
  `ALLM.Serializer.from_json/1` round-trips return an equal struct. The
  negative cases prove the closed contract — tools with anonymous-function
  handlers, keyword-list-with-fn `adapter_opts`, etc. — break serialization
  by design. The `DateTime` test documents the ETF/JSON asymmetry: non-stdlib
  structs survive ETF but require user-supplied `Jason.Encoder` impls for the
  JSON path; the library does not ship encoders for them.
  """
  use ExUnit.Case, async: true

  @moduletag :roundtrip

  alias ALLM.Engine
  alias ALLM.Error.ValidationError

  # A deterministic module reference used to satisfy the "MFA handler"
  # contract — the module needn't actually exist at decode time, but it must
  # be an atom already loaded in the BEAM so `String.to_existing_atom/1`
  # succeeds. We use `ALLM.Engine` itself — it's guaranteed loaded.
  @stub_handler_module ALLM.Engine

  defp populated_engine(opts \\ []) do
    tool_a = ALLM.Tool.new(name: "a", description: "a", schema: %{}, metadata: %{"k" => "v"})
    tool_b = ALLM.Tool.new(name: "b", description: "b", schema: %{"type" => "object"})

    Engine.new(
      Keyword.merge(
        [
          adapter: ALLM.Engine,
          adapter_opts: [timeout_ms: 5_000, base_url: "https://api.example.com"],
          model: "fake:gpt-test",
          tools: [tool_a, tool_b],
          tool_executor: ALLM.Engine,
          tool_result_encoder: ALLM.Engine,
          image_adapter: ALLM.Engine,
          params: %{temperature: 0.2, top_p: 1.0, system: "be brief"},
          context: %{user_id: 42, mode: "chat"},
          retry: :default,
          middleware: [],
          metadata: %{trace_id: "abc-123", request_count: 3}
        ],
        opts
      )
    )
  end

  test "populated engine round-trips through :erlang.term_to_binary/1" do
    engine = populated_engine()
    round_tripped = engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert round_tripped == engine
  end

  test "populated engine round-trips through ALLM.Serializer JSON" do
    engine = populated_engine()
    json = ALLM.Serializer.to_json!(engine)
    assert {:ok, decoded} = ALLM.Serializer.from_json(json)
    assert decoded == engine
  end

  test "populated engine with image_adapter set decodes via String.to_existing_atom/1" do
    # Phase 13.3 belt-and-braces: the populated engine carries
    # `image_adapter: ALLM.Engine`. The decoder at `lib/allm/engine.ex:395`
    # routes through `restore_module/1`, which uses
    # `String.to_existing_atom/1` (per `lib/allm/engine.ex:416`). This test
    # asserts the field round-trips to a non-nil module value through the
    # JSON path — guarding against the silent-success failure mode where
    # `image_adapter:` decodes to `nil` because of a wiring bug.
    engine = populated_engine()
    assert engine.image_adapter == ALLM.Engine

    json = ALLM.Serializer.to_json!(engine)
    assert {:ok, decoded} = ALLM.Serializer.from_json(json)
    assert decoded.image_adapter == ALLM.Engine
    refute is_nil(decoded.image_adapter)
  end

  test "JSON decode with unloaded adapter module returns atom_decode_failed" do
    engine = populated_engine()
    json = ALLM.Serializer.to_json!(engine)

    # Patch the encoded JSON to reference a module that is guaranteed not
    # loaded in the BEAM. `String.to_existing_atom/1` must refuse it —
    # proving the decoder does not call `Module.concat/1` on input-derived
    # strings (which would silently create a phantom atom and pass).
    decoded = Jason.decode!(json)
    patched = put_in(decoded, ["data", "adapter"], "NonExistent.Module.DoesNotExist")
    patched_json = Jason.encode!(patched)

    assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
             ALLM.Serializer.from_json(patched_json)

    assert {:_unknown, :atom_decode_failed} in errors
  end

  test "engine with a {Module, :function} tool handler round-trips via term_to_binary" do
    tool =
      ALLM.Tool.new(
        name: "weather",
        description: "weather by city",
        schema: %{"type" => "object"},
        handler: {@stub_handler_module, :weather}
      )

    engine = Engine.new(adapter: ALLM.Engine, model: "m", tools: [tool])

    round_tripped = engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert round_tripped == engine

    [%{handler: handler}] = round_tripped.tools
    assert handler == {@stub_handler_module, :weather}
  end

  test "engine with an anonymous-function tool handler fails Jason encode" do
    # Contract per Non-obvious decision #7: a tool handler that is a fun
    # breaks JSON serialization. Jason has no encoder for functions, so
    # `Protocol.UndefinedError` is raised from the serializer.
    #
    # Note on ETF: `:erlang.term_to_binary/1` does NOT raise on a fun — it
    # encodes the fun into a BEAM-private representation that is unsafe to
    # persist (local anon funs depend on the module's compile-time MD5 and
    # `:badfun` on cross-node / cross-recompile decode). The design's closed
    # contract still forbids fn handlers on persisted engines; ETF simply
    # doesn't enforce it at encode time. The JSON path is where the
    # contract is mechanically checked. `[tactical]` — the 2.3 design
    # doc's claim that `term_to_binary` raises `ArgumentError` on funs is
    # incorrect; this test encodes the actual contract at the
    # implementation boundary (Jason refuses; ETF silently permits).
    tool =
      ALLM.Tool.new(
        name: "fn_tool",
        description: "fn",
        schema: %{},
        handler: fn _args -> {:ok, "no"} end
      )

    engine = Engine.new(adapter: ALLM.Engine, tools: [tool])

    assert_raise Protocol.UndefinedError, fn ->
      ALLM.Serializer.to_json!(engine)
    end
  end

  test "adapter_opts containing a fun fails Jason encode" do
    # Same pattern as the fn-handler test above: ETF silently permits funs,
    # Jason rejects them. The closed contract forbids fn values in
    # `adapter_opts`; this test enforces it at the JSON boundary.
    engine =
      Engine.new(
        adapter: ALLM.Engine,
        adapter_opts: [finch_callback: fn _ -> :ok end]
      )

    assert_raise Protocol.UndefinedError, fn ->
      ALLM.Serializer.to_json!(engine)
    end
  end

  test "metadata with DateTime survives term_to_binary but loses type on JSON" do
    # DateTime has a `Jason.Encoder` impl that emits an ISO-8601 string, so
    # `to_json!/1` succeeds. On decode, however, the library does not
    # attempt to re-parse ISO-8601 back into a `%DateTime{}` — values in
    # metadata pass through verbatim. The net effect: the JSON round-trip
    # is not equality-preserving for non-stdlib structs unless the user
    # supplies a custom decoder.
    engine =
      Engine.new(
        adapter: ALLM.Engine,
        model: "m",
        metadata: %{created_at: ~U[2026-01-01 00:00:00Z]}
      )

    # ETF is equality-preserving.
    round_tripped = engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert round_tripped == engine

    # JSON round-trip: `to_json!/1` succeeds (Jason encodes DateTime as a
    # string), but the decoded value's metadata carries a binary, not a
    # DateTime — equality does NOT hold. This asymmetry is documented in
    # `ALLM.Engine`'s moduledoc.
    assert {:ok, decoded} = engine |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    refute decoded == engine
    assert decoded.metadata[:created_at] == "2026-01-01T00:00:00Z"
  end

  test "engine with false retry round-trips via both ETF and JSON" do
    engine = Engine.new(adapter: ALLM.Engine, model: "m", retry: false)
    assert engine == engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, decoded} = engine |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    assert decoded == engine
  end

  test "engine with keyword-list retry round-trips via both ETF and JSON" do
    engine =
      Engine.new(
        adapter: ALLM.Engine,
        model: "m",
        retry: [max_attempts: 3, backoff_ms: 500]
      )

    assert engine == engine |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, decoded} = engine |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    assert decoded == engine
  end

  test "Phase 11.1: Anthropic engine round-trips with no key-shaped string in the binary" do
    # Per spec §6.4 + Phase 11 obligation: API keys never appear on the
    # engine. Construct an Anthropic-adapter engine with a plausible key in
    # the runtime store and assert the serialized binary contains no
    # key-shaped string.
    ALLM.Keys.put(:anthropic, "sk-ant-roundtrip-secret-DO-NOT-LEAK")
    on_exit(fn -> ALLM.Keys.delete(:anthropic) end)

    engine =
      Engine.new(
        adapter: ALLM.Providers.Anthropic,
        model: "claude-sonnet-4-6",
        adapter_opts: [organization: "org-roundtrip"]
      )

    binary = :erlang.term_to_binary(engine)
    refute binary =~ "sk-ant-roundtrip-secret-DO-NOT-LEAK"
    refute binary =~ "sk-ant-"

    # And the engine itself round-trips equality-preserving.
    assert engine == binary |> :erlang.binary_to_term()
  end
end
