defmodule ALLM.AllmImageVariationsTest do
  @moduledoc """
  Layer C facade tests for `ALLM.image_variations/3` (Phase 14.2, design
  §14.2.1).

  Asserts builder semantics, adapter-presence gate, opt forwarding, and
  the cross-function mirror property against `ALLM.image_request/2` per
  Decision #6.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ALLM.Engine
  alias ALLM.Error.EngineError
  alias ALLM.{Image, ImageRequest, ImageResponse}
  alias ALLM.Providers.FakeImages

  doctest ALLM, only: [image_variations: 3]

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp single_image, do: Image.from_binary(@png_bytes, "image/png")

  defp engine_with_script(script) do
    Engine.new(image_adapter: FakeImages, adapter_opts: [image_script: script])
  end

  defmodule CaptureAdapter do
    @moduledoc false
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate, :edit, :variation]

    def generate(req, opts) do
      pid = :erlang.whereis(:variation_capture)
      if is_pid(pid), do: send(pid, {:request, req, opts})
      {:ok, %ALLM.ImageResponse{images: [], usage: %ALLM.ImageUsage{}}}
    end
  end

  setup do
    name = :variation_capture

    case :erlang.whereis(name) do
      :undefined -> :ok
      _pid -> Process.unregister(name)
    end

    Process.register(self(), name)
    :ok
  end

  describe "builder shape" do
    test "image_variations(engine, img) builds %ImageRequest{operation: :variation, input_images: [img], prompt: nil}" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      img = single_image()

      assert {:ok, _} = ALLM.image_variations(engine, img)

      assert_received {:request, req, _opts}

      assert %ImageRequest{
               operation: :variation,
               input_images: [^img],
               prompt: nil
             } = req
    end

    test "image_variations(engine, img, n: 4) sets n: 4" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      img = single_image()

      assert {:ok, _} = ALLM.image_variations(engine, img, n: 4)
      assert_received {:request, %ImageRequest{n: 4, operation: :variation}, _opts}
    end
  end

  describe "adapter presence" do
    test "with engine.image_adapter == nil returns :no_image_adapter" do
      engine = Engine.new()
      img = single_image()

      assert {:error, %EngineError{reason: :no_image_adapter}} =
               ALLM.image_variations(engine, img)
    end
  end

  describe "happy path through FakeImages" do
    test "returns %ImageResponse{}" do
      engine = engine_with_script([{:ok, [single_image()]}])
      img = single_image()

      assert {:ok, %ImageResponse{images: [_]}} = ALLM.image_variations(engine, img)
    end
  end

  describe "cross-function mirror property (Decision #6)" do
    property "image_variations/3 builds the same struct as ALLM.image_request/2 with operation: :variation (modulo :request_id)" do
      check all(n <- StreamData.integer(1..4)) do
        img = single_image()

        engine = Engine.new(image_adapter: CaptureAdapter)
        {:ok, _} = ALLM.image_variations(engine, img, n: n)
        assert_received {:request, sugar_req, _opts}

        # Variations require empty/nil prompt; build the explicit form
        # without the prompt sugar (the facade `image_request/2` requires
        # a binary prompt, so use ImageRequest.new/1 directly).
        explicit =
          ImageRequest.new(
            operation: :variation,
            input_images: [img],
            n: n,
            prompt: nil
          )

        assert Map.from_struct(sugar_req) == Map.from_struct(explicit)
      end
    end
  end
end
