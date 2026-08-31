defmodule ALLM.CapabilityModerationTest do
  @moduledoc """
  `ALLM.Capability.preflight_moderation/2` matrix tests. Mirrors the structure
  of `ALLM.CapabilityEmbeddingTest`. `async: false` because the
  `force_capability_absent` env var mutates global state.

  Moderation has **one** rejection rule, not two: there is no numeric knob a
  catalog could cap, so the embeddings sibling's `dimensions_max` arm has no
  analogue here and there is nothing to accumulate.
  """

  use ExUnit.Case, async: false

  alias ALLM.{Capability, ModelRef, ModerationRequest}
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
    ModerationRequest.new(Keyword.put_new(opts, :input, ["is this ok?"]))
  end

  describe "preflight_moderation/2 — catalog absent" do
    test "returns :ok regardless of model shape when force_capability_absent is set" do
      Application.put_env(:allm, :force_capability_absent, true)

      disabled = ref(:local, "no-moderation", %{moderation_enabled: false})

      assert Capability.preflight_moderation(disabled, request()) == :ok
      assert Capability.preflight_moderation("openai:omni-moderation-latest", request()) == :ok
      assert Capability.preflight_moderation(nil, request()) == :ok
    end
  end

  describe "preflight_moderation/2 — bare model identifier" do
    test "returns :ok for a bare string (no capability info)" do
      assert Capability.preflight_moderation("openai:omni-moderation-latest", request()) == :ok
    end

    test "returns :ok for a bare tuple" do
      assert Capability.preflight_moderation({:openai, "omni-moderation-latest"}, request()) == :ok
    end

    test "returns :ok for nil" do
      assert Capability.preflight_moderation(nil, request()) == :ok
    end
  end

  describe "preflight_moderation/2 — moderation_enabled gate" do
    test "returns :ok when capabilities lack a moderation_enabled key" do
      r = ref(:openai, "omni-moderation-latest", %{tools: %{enabled: false}})

      assert Capability.preflight_moderation(r, request()) == :ok
    end

    test "returns :ok when moderation_enabled is true" do
      r = ref(:openai, "omni-moderation-latest", %{moderation_enabled: true})

      assert Capability.preflight_moderation(r, request()) == :ok
    end

    test "rejects atom-keyed moderation_enabled: false" do
      r = ref(:local, "no-moderation", %{moderation_enabled: false})

      assert {:error, %ValidationError{} = err} = Capability.preflight_moderation(r, request())
      assert err.reason == :unsupported_capability
      assert err.errors == [{[:moderation_enabled], :moderation_disabled}]
    end

    test "rejects string-keyed \"moderation_enabled\" => false (JSON-rehydrated ref)" do
      r = ref(:local, "no-moderation", %{"moderation_enabled" => false})

      assert {:error, %ValidationError{} = err} = Capability.preflight_moderation(r, request())
      assert err.errors == [{[:moderation_enabled], :moderation_disabled}]
    end

    test "a multimodal request is gated identically — the rule reads the ref, not the request" do
      part = ALLM.ImagePart.new(ALLM.Image.from_url("https://example.com/cat.png"))
      r = ref(:local, "no-moderation", %{moderation_enabled: false})

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_moderation(r, request(input: ["look", part]))

      assert err.errors == [{[:moderation_enabled], :moderation_disabled}]
    end
  end
end
