defmodule ALLM.CapabilityImageTest do
  @moduledoc """
  Phase 14.3 — `ALLM.Capability.preflight_image/2` matrix tests.
  Mirrors the structure of `ALLM.CapabilityTest`. async: false because
  the `force_capability_absent` env var mutates global state.
  """

  use ExUnit.Case, async: false

  alias ALLM.{Capability, Engine, Image, ImageRequest, ModelRef}
  alias ALLM.Error.{EngineError, ValidationError}
  alias ALLM.Providers.FakeImages

  setup do
    Application.delete_env(:allm, :force_capability_absent)
    on_exit(fn -> Application.delete_env(:allm, :force_capability_absent) end)
    :ok
  end

  defp ref(provider, id, capabilities) do
    ModelRef.new(provider: provider, id: id, capabilities: capabilities)
  end

  defp generate_request, do: ImageRequest.new(prompt: "a kestrel")

  defp edit_request do
    img = Image.from_binary(<<1>>, "image/png")
    ImageRequest.new(operation: :edit, prompt: "x", input_images: [img])
  end

  describe "preflight_image/2 — catalog absent" do
    test "returns :ok regardless of model shape when force_capability_absent is set" do
      Application.put_env(:allm, :force_capability_absent, true)

      no_image_ref =
        ref(:local, "no-images", %{images_enabled: false, supported_image_operations: []})

      assert Capability.preflight_image(no_image_ref, generate_request()) == :ok
      assert Capability.preflight_image("openai:gpt-image-1", generate_request()) == :ok
      assert Capability.preflight_image(nil, generate_request()) == :ok
    end
  end

  describe "preflight_image/2 — bare model identifier" do
    test "returns :ok for a bare string (no capability info)" do
      assert Capability.preflight_image("openai:gpt-image-1", generate_request()) == :ok
    end

    test "returns :ok for a bare tuple" do
      assert Capability.preflight_image({:openai, "gpt-image-1"}, generate_request()) == :ok
    end

    test "returns :ok for nil" do
      assert Capability.preflight_image(nil, generate_request()) == :ok
    end
  end

  describe "preflight_image/2 — happy path with capabilities" do
    test "returns :ok when images_enabled and operation is supported" do
      r =
        ref(:openai, "gpt-image-1", %{
          images_enabled: true,
          supported_image_operations: [:generate, :edit]
        })

      assert Capability.preflight_image(r, generate_request()) == :ok
      assert Capability.preflight_image(r, edit_request()) == :ok
    end
  end

  describe "preflight_image/2 — :images_disabled rejection" do
    test "fires when capabilities.images_enabled == false" do
      r = ref(:local, "no-images", %{images_enabled: false, supported_image_operations: []})

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_image(r, generate_request())

      assert err.reason == :unsupported_capability
      assert {[:images_enabled], :images_disabled} in err.errors
      # operation is also rejected since [] doesn't include :generate
      assert {[:operation], :unsupported_image_operation} in err.errors
    end
  end

  describe "preflight_image/2 — :unsupported_image_operation rejection" do
    test "fires when operation not in supported_image_operations" do
      r =
        ref(:openai, "dall-e-3", %{
          images_enabled: true,
          supported_image_operations: [:generate]
        })

      assert {:error, %ValidationError{} = err} =
               Capability.preflight_image(r, edit_request())

      assert err.reason == :unsupported_capability
      assert err.errors == [{[:operation], :unsupported_image_operation}]
    end

    test "does NOT fire when operation IS in supported_image_operations" do
      r =
        ref(:openai, "dall-e-3", %{
          images_enabled: true,
          supported_image_operations: [:generate]
        })

      assert Capability.preflight_image(r, generate_request()) == :ok
    end
  end

  describe "preflight_image/2 — both rules accumulate" do
    test "errors list contains both atoms when images_enabled: false AND op missing" do
      r = ref(:local, "no-images", %{images_enabled: false, supported_image_operations: []})

      assert {:error, %ValidationError{errors: errors}} =
               Capability.preflight_image(r, generate_request())

      assert {[:images_enabled], :images_disabled} in errors
      assert {[:operation], :unsupported_image_operation} in errors
      assert length(errors) == 2
    end
  end

  describe "preflight_image/2 — JSON-rehydrated string-keyed capabilities" do
    test "string-keyed images_enabled: false rejects identically to atom-keyed" do
      r =
        ref(:local, "no-images", %{
          "images_enabled" => false,
          "supported_image_operations" => []
        })

      assert {:error, %ValidationError{errors: errors}} =
               Capability.preflight_image(r, generate_request())

      assert {[:images_enabled], :images_disabled} in errors
    end

    test "string-keyed supported_image_operations with string atoms" do
      r =
        ref(:openai, "dall-e-3", %{
          "images_enabled" => true,
          "supported_image_operations" => ["generate"]
        })

      # :generate IS in the list (string atoms tolerated).
      assert Capability.preflight_image(r, generate_request()) == :ok

      assert {:error, %ValidationError{errors: [{[:operation], :unsupported_image_operation}]}} =
               Capability.preflight_image(r, edit_request())
    end
  end

  describe "preflight_image/2 — wired into the façade" do
    test "generate_image/3 against a model with images_enabled: false returns the ValidationError synchronously" do
      img = Image.from_binary(<<1>>, "image/png")

      engine =
        Engine.new(
          image_adapter: FakeImages,
          model: "local:no-images",
          adapter_opts: [image_script: [{:ok, [img]}]]
        )

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               ALLM.generate_image(engine, "x")

      assert {[:images_enabled], :images_disabled} in errors
    end

    test "generate_image/3 against an unsupported operation returns ValidationError synchronously" do
      img = Image.from_binary(<<1>>, "image/png")

      engine =
        Engine.new(
          image_adapter: FakeImages,
          model: "openai:dall-e-3",
          adapter_opts: [image_script: [{:ok, [img]}]]
        )

      base = Image.from_binary(<<2>>, "image/png")

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               ALLM.edit_image(engine, base, "make sky pink")

      assert {[:operation], :unsupported_image_operation} in errors
    end

    test "generate_image/3 with images_enabled: true and supported op succeeds" do
      img = Image.from_binary(<<1>>, "image/png")

      engine =
        Engine.new(
          image_adapter: FakeImages,
          model: "openai:gpt-image-1",
          adapter_opts: [image_script: [{:ok, [img]}]]
        )

      assert {:ok, _response} = ALLM.generate_image(engine, "x")
    end
  end

  describe "preflight_image/2 — adapter-presence gate fires FIRST" do
    test "missing adapter + tools-disabled-style model returns :no_image_adapter, NOT :unsupported_capability" do
      engine = Engine.new(model: "local:no-images")

      assert {:error, %EngineError{reason: :no_image_adapter}} =
               ALLM.generate_image(engine, "x")
    end
  end

  describe "preflight_image/2 — dep-free smoke test" do
    test "with force_capability_absent: true the façade does NOT consult the catalog" do
      Application.put_env(:allm, :force_capability_absent, true)

      img = Image.from_binary(<<1>>, "image/png")

      engine =
        Engine.new(
          image_adapter: FakeImages,
          # would normally reject if catalog were consulted
          model: "local:no-images",
          adapter_opts: [image_script: [{:ok, [img]}]]
        )

      assert {:ok, _response} = ALLM.generate_image(engine, "x")
    end
  end
end
