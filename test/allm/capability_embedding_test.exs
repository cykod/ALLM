defmodule ALLM.CapabilityEmbeddingTest do
  @moduledoc """
  `ALLM.Capability.preflight_embedding/2` matrix tests. Mirrors the structure
  of `ALLM.CapabilityImageTest`. `async: false` because the
  `force_capability_absent` env var mutates global state.
  """

  use ExUnit.Case, async: false

  alias ALLM.{Capability, EmbeddingRequest, ModelRef}
  alias ALLM.Error.ValidationError

  setup do
    Application.delete_env(:allm, :force_capability_absent)
    on_exit(fn -> Application.delete_env(:allm, :force_capability_absent) end)
    :ok
  end

  defp ref(provider, id, capabilities) do
    ModelRef.new(provider: provider, id: id, capabilities: capabilities)
  end

  defp request(opts \\ []) do
    EmbeddingRequest.new(Keyword.put_new(opts, :input, ["a chunk"]))
  end

  describe "preflight_embedding/2 — catalog absent" do
    test "returns :ok regardless of model shape when force_capability_absent is set" do
      Application.put_env(:allm, :force_capability_absent, true)

      disabled = ref(:local, "no-embeddings", %{embeddings_enabled: false})

      assert Capability.preflight_embedding(disabled, request()) == :ok
      assert Capability.preflight_embedding("openai:text-embedding-3-small", request()) == :ok
      assert Capability.preflight_embedding(nil, request()) == :ok
    end
  end

  describe "preflight_embedding/2 — bare model identifier" do
    test "returns :ok for a bare string (no capability info)" do
      assert Capability.preflight_embedding("openai:text-embedding-3-small", request()) == :ok
    end

    test "returns :ok for a bare tuple" do
      assert Capability.preflight_embedding({:openai, "text-embedding-3-small"}, request()) == :ok
    end

    test "returns :ok for nil" do
      assert Capability.preflight_embedding(nil, request()) == :ok
    end
  end

  describe "preflight_embedding/2 — embeddings_enabled gate" do
    test "returns :ok when capabilities lack an embeddings_enabled key" do
      r = ref(:openai, "text-embedding-3-small", %{tools: %{enabled: false}})

      assert Capability.preflight_embedding(r, request()) == :ok
    end

    test "returns :ok when embeddings_enabled is true" do
      r = ref(:openai, "text-embedding-3-small", %{embeddings_enabled: true})

      assert Capability.preflight_embedding(r, request()) == :ok
    end

    test "rejects atom-keyed embeddings_enabled: false" do
      r = ref(:local, "no-embeddings", %{embeddings_enabled: false})

      assert {:error, %ValidationError{} = err} = Capability.preflight_embedding(r, request())
      assert err.reason == :unsupported_capability
      assert err.errors == [{[:embeddings_enabled], :embeddings_disabled}]
    end

    test "rejects string-keyed \"embeddings_enabled\" => false (JSON-rehydrated ref)" do
      r = ref(:local, "no-embeddings", %{"embeddings_enabled" => false})

      assert {:error, %ValidationError{} = err} = Capability.preflight_embedding(r, request())
      assert err.errors == [{[:embeddings_enabled], :embeddings_disabled}]
    end
  end

  describe "preflight_embedding/2 — dimensions_max gate" do
    test "returns :ok when :dimensions is nil, whatever the cap says" do
      r = ref(:openai, "text-embedding-3-small", %{dimensions_max: 1536})

      assert Capability.preflight_embedding(r, request()) == :ok
    end

    test "returns :ok when :dimensions is within the cap" do
      r = ref(:openai, "text-embedding-3-small", %{dimensions_max: 1536})

      assert Capability.preflight_embedding(r, request(dimensions: 512)) == :ok
      assert Capability.preflight_embedding(r, request(dimensions: 1536)) == :ok
    end

    test "returns :ok when capabilities lack a dimensions_max key" do
      r = ref(:openai, "text-embedding-3-small", %{embeddings_enabled: true})

      assert Capability.preflight_embedding(r, request(dimensions: 99_999)) == :ok
    end

    test "rejects atom-keyed dimensions_max overflow" do
      r = ref(:openai, "text-embedding-3-small", %{dimensions_max: 1536})

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_embedding(r, request(dimensions: 4096))

      assert err.reason == :unsupported_capability
      assert err.errors == [{[:dimensions], :exceeds_max}]
    end

    test "rejects string-keyed \"dimensions_max\" overflow (JSON-rehydrated ref)" do
      r = ref(:openai, "text-embedding-3-small", %{"dimensions_max" => 1536})

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_embedding(r, request(dimensions: 4096))

      assert err.errors == [{[:dimensions], :exceeds_max}]
    end
  end

  describe "preflight_embedding/2 — accumulation" do
    test "both gates accumulate into one ValidationError, in declaration order" do
      r = ref(:local, "no-embeddings", %{embeddings_enabled: false, dimensions_max: 256})

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_embedding(r, request(dimensions: 4096))

      assert err.errors == [
               {[:embeddings_enabled], :embeddings_disabled},
               {[:dimensions], :exceeds_max}
             ]
    end
  end
end
