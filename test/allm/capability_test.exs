defmodule ALLM.CapabilityTest do
  # Not async — `Application.put_env(:allm, :force_capability_absent, _)`
  # mutates global state.
  use ExUnit.Case, async: false

  alias ALLM.{Capability, Message, ModelRef, Request, Tool, Usage}
  alias ALLM.Error.ValidationError

  doctest Capability

  setup do
    # Ensure each test starts with the override cleared so `LLMDB`
    # detection runs normally (the test fake is loaded — see
    # `test/support/llm_db.ex`).
    Application.delete_env(:allm, :force_capability_absent)
    on_exit(fn -> Application.delete_env(:allm, :force_capability_absent) end)
    :ok
  end

  describe "catalog_loaded?/0" do
    test "returns true when the LLMDB test fake is compiled and the override is unset" do
      assert Capability.catalog_loaded?() == true
    end

    test "returns false when force_capability_absent override is set" do
      Application.put_env(:allm, :force_capability_absent, true)
      assert Capability.catalog_loaded?() == false
    end
  end

  describe "preflight/2" do
    test "returns :ok when catalog is absent regardless of request shape" do
      Application.put_env(:allm, :force_capability_absent, true)
      ref = make_ref(:openai, "gpt-4.1-mini", %{tools: %{enabled: false}, json_native: false})
      tool = Tool.new(name: "echo", description: "x", schema: %{})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          tools: [tool],
          response_format: %{type: :json_schema, name: "x", schema: %{}, strict: true}
        )

      assert Capability.preflight(ref, req) == :ok
    end

    test "returns :ok for a bare model string regardless of request shape" do
      tool = Tool.new(name: "echo", description: "x", schema: %{})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          tools: [tool],
          response_format: %{type: :json_schema, name: "x", schema: %{}, strict: true}
        )

      assert Capability.preflight("openai:gpt-4.1-mini", req) == :ok
    end

    test "returns :ok for nil model" do
      req = Request.new([%Message{role: :user, content: "hi"}])
      assert Capability.preflight(nil, req) == :ok
    end

    test "rejects tools-against-disabled-tools with :tools_disabled" do
      ref = make_ref(:local, "no-tools", %{tools: %{enabled: false}, json_native: true})
      tool = Tool.new(name: "echo", description: "x", schema: %{})
      req = Request.new([%Message{role: :user, content: "hi"}], tools: [tool])

      assert {:error, %ValidationError{} = err} = Capability.preflight(ref, req)
      assert err.reason == :unsupported_capability
      assert err.errors == [{[:tools], :tools_disabled}]
    end

    test "returns :ok for a tools-disabled model when request has no tools" do
      ref = make_ref(:local, "no-tools", %{tools: %{enabled: false}, json_native: true})
      req = Request.new([%Message{role: :user, content: "hi"}], tools: [])

      assert Capability.preflight(ref, req) == :ok
    end

    test "rejects json_schema-against-non-json_native with :json_native_disabled" do
      ref = make_ref(:local, "no-json-native", %{tools: %{enabled: true}, json_native: false})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          response_format: %{type: :json_schema, name: "X", schema: %{}, strict: true}
        )

      assert {:error, %ValidationError{} = err} = Capability.preflight(ref, req)
      assert err.reason == :unsupported_capability
      assert err.errors == [{[:response_format], :json_native_disabled}]
    end

    test ":json_object is the soft carve-out — :ok against non-json_native model" do
      ref = make_ref(:local, "no-json-native", %{tools: %{enabled: true}, json_native: false})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          response_format: %{type: :json_object}
        )

      assert Capability.preflight(ref, req) == :ok
    end

    test "JSON-rehydrated %ModelRef{} (string-keyed capabilities) pre-flights identically" do
      # Review Finding #1 fix: Capability.preflight/2 must reject a
      # tools-disabled ref even when the ref came back from a JSON
      # round-trip (where opaque map fields keep STRING keys per the
      # Layer A nested-map asymmetry documented on ALLM.ModelRef).
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-tools-rehydrated",
          capabilities: %{"tools" => %{"enabled" => false}, "json_native" => false}
        )

      tool = Tool.new(name: "echo", description: "x", schema: %{})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          tools: [tool],
          response_format: %{type: :json_schema, name: "X", schema: %{}, strict: true}
        )

      assert {:error, %ValidationError{} = err} = Capability.preflight(ref, req)
      assert err.reason == :unsupported_capability
      assert {[:tools], :tools_disabled} in err.errors
      assert {[:response_format], :json_native_disabled} in err.errors
    end

    test "round-trips a %ModelRef{} via Jason and pre-flights through the rehydrated value" do
      # End-to-end: encode → decode → preflight. This is the asymmetry
      # masked by the original test fixtures. Without the tolerance fix
      # in check_tools/3 / check_json_native/3, this test silently passes
      # with `:ok` (no rejection) when it should reject.
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-tools-roundtrip",
          capabilities: %{tools: %{enabled: false}, json_native: true}
        )

      json = ALLM.Serializer.to_json!(ref)
      {:ok, rehydrated} = ALLM.Serializer.from_json(json)

      tool = Tool.new(name: "echo", description: "x", schema: %{})
      req = Request.new([%Message{role: :user, content: "hi"}], tools: [tool])

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errs}} =
               Capability.preflight(rehydrated, req)

      assert errs == [{[:tools], :tools_disabled}]
    end

    test "accumulates BOTH errors when both rejections fire" do
      ref =
        make_ref(:local, "no-anything", %{
          tools: %{enabled: false},
          json_native: false
        })

      tool = Tool.new(name: "echo", description: "x", schema: %{})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          tools: [tool],
          response_format: %{type: :json_schema, name: "X", schema: %{}, strict: true}
        )

      assert {:error, %ValidationError{} = err} = Capability.preflight(ref, req)
      assert err.reason == :unsupported_capability
      assert {[:tools], :tools_disabled} in err.errors
      assert {[:response_format], :json_native_disabled} in err.errors
      assert length(err.errors) == 2
    end
  end

  describe "populate_costs/2" do
    test "populates input_cost / output_cost / total_cost from per-million rates" do
      ref = ModelRef.new(provider: :openai, id: "x", pricing: %{input: 0.15, output: 0.6})
      usage = %Usage{input_tokens: 1_000, output_tokens: 500}
      populated = Capability.populate_costs(usage, ref)

      assert populated.input_cost == 1.5e-4
      assert populated.output_cost == 3.0e-4
      assert populated.total_cost == 4.5e-4
    end

    test "leaves :input_cost nil when input_tokens is nil; output still populates" do
      ref = ModelRef.new(provider: :openai, id: "x", pricing: %{input: 0.15, output: 0.6})
      usage = %Usage{input_tokens: nil, output_tokens: 500}
      populated = Capability.populate_costs(usage, ref)

      assert populated.input_cost == nil
      assert populated.output_cost == 3.0e-4
      # total_cost stays nil since one half is missing
      assert populated.total_cost == nil
    end

    test "returns usage unchanged when pricing is nil" do
      ref = ModelRef.new(provider: :local, id: "no-pricing", pricing: nil)
      usage = %Usage{input_tokens: 100, output_tokens: 50}

      assert Capability.populate_costs(usage, ref) == usage
    end

    test "returns usage unchanged when catalog is absent" do
      Application.put_env(:allm, :force_capability_absent, true)
      ref = ModelRef.new(provider: :openai, id: "x", pricing: %{input: 0.15, output: 0.6})
      usage = %Usage{input_tokens: 1_000, output_tokens: 500}

      assert Capability.populate_costs(usage, ref) == usage
    end

    test "never overwrites an already-populated cost field" do
      ref = ModelRef.new(provider: :openai, id: "x", pricing: %{input: 0.15, output: 0.6})

      usage = %Usage{
        input_tokens: 1_000,
        output_tokens: 500,
        input_cost: 99.0,
        output_cost: 88.0,
        total_cost: 77.0
      }

      populated = Capability.populate_costs(usage, ref)
      assert populated.input_cost == 99.0
      assert populated.output_cost == 88.0
      assert populated.total_cost == 77.0
    end

    test "returns usage unchanged when model is a bare string" do
      usage = %Usage{input_tokens: 1_000, output_tokens: 500}
      assert Capability.populate_costs(usage, "openai:gpt-4.1-mini") == usage
    end

    test "tolerates JSON-rehydrated %ModelRef{} with string-keyed pricing" do
      # Review Finding #1 fix: populate_costs/2 must compute costs from
      # a string-keyed pricing map (post-Jason round-trip). Without the
      # tolerance fix in apply_pricing/2, both costs would stay nil.
      ref =
        ModelRef.new(
          provider: :openai,
          id: "x",
          pricing: %{"input" => 0.15, "output" => 0.6}
        )

      usage = %Usage{input_tokens: 1_000, output_tokens: 500}
      populated = Capability.populate_costs(usage, ref)

      assert populated.input_cost == 1.5e-4
      assert populated.output_cost == 3.0e-4
      assert populated.total_cost == 4.5e-4
    end
  end

  describe "select/1" do
    test "returns {:ok, ref} from LLMDB.select/1 when loaded" do
      assert {:ok, ref} = Capability.select(require: [:tools])
      assert is_struct(ref, ModelRef)
    end

    test "returns {:error, :catalog_not_loaded} when catalog is absent" do
      Application.put_env(:allm, :force_capability_absent, true)
      assert Capability.select(require: [:tools]) == {:error, :catalog_not_loaded}
    end
  end

  defp make_ref(provider, id, capabilities) do
    ModelRef.new(provider: provider, id: id, capabilities: capabilities)
  end
end
