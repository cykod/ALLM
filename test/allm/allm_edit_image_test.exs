defmodule ALLM.AllmEditImageTest do
  @moduledoc """
  Layer C facade tests for `ALLM.edit_image/4` (Phase 14.2, design §14.2.1).

  Asserts the three call shapes per Decision #6: single image, 2-element
  list `[base, mask]` (treated as `input_images: [base, mask]`, mask: nil),
  and single image + explicit `mask:` keyword. Plus adapter-presence,
  opt forwarding, and the cross-function property test asserting the
  sugar produces a struct byte-equal (modulo `:request_id`) to the
  explicit `ALLM.image_request/2`-built equivalent.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ALLM.Engine
  alias ALLM.Error.EngineError
  alias ALLM.{Image, ImageRequest, ImageResponse}
  alias ALLM.Providers.FakeImages

  doctest ALLM, only: [edit_image: 4]

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
      pid = Process.get(:capture_adapter_pid) || :erlang.whereis(:edit_capture)
      if is_pid(pid), do: send(pid, {:request, req, opts})
      {:ok, %ALLM.ImageResponse{images: [], usage: %ALLM.ImageUsage{}}}
    end
  end

  setup do
    name = :edit_capture

    case :erlang.whereis(name) do
      :undefined -> :ok
      _pid -> Process.unregister(name)
    end

    Process.register(self(), name)
    :ok
  end

  describe "three call shapes (Decision #6)" do
    test "single base image: edit_image(engine, base, prompt) builds %ImageRequest{operation: :edit, input_images: [base], mask: nil}" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      base = single_image()

      assert {:ok, _} = ALLM.edit_image(engine, base, "make sky pink")

      assert_received {:request, req, _opts}

      assert %ImageRequest{
               operation: :edit,
               input_images: [^base],
               mask: nil,
               prompt: "make sky pink"
             } = req
    end

    test "list form [base, mask]: edit_image(engine, [base, mask], prompt) builds input_images: [base, mask], mask: nil" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      base = single_image()
      mask = single_image()

      assert {:ok, _} = ALLM.edit_image(engine, [base, mask], "make sky pink")

      assert_received {:request, req, _opts}

      assert %ImageRequest{
               operation: :edit,
               input_images: [^base, ^mask],
               mask: nil,
               prompt: "make sky pink"
             } = req
    end

    test "explicit mask kw: edit_image(engine, base, prompt, mask: mask) builds input_images: [base], mask: mask" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      base = single_image()
      mask = single_image()

      assert {:ok, _} = ALLM.edit_image(engine, base, "make sky pink", mask: mask)

      assert_received {:request, req, _opts}

      assert %ImageRequest{
               operation: :edit,
               input_images: [^base],
               mask: ^mask,
               prompt: "make sky pink"
             } = req
    end
  end

  describe "adapter presence" do
    test "with engine.image_adapter == nil returns :no_image_adapter" do
      engine = Engine.new()
      base = single_image()

      assert {:error, %EngineError{reason: :no_image_adapter}} =
               ALLM.edit_image(engine, base, "x")
    end
  end

  describe "opt forwarding" do
    test "forwards n, size, quality into the request" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      base = single_image()

      assert {:ok, _} =
               ALLM.edit_image(engine, base, "x", n: 3, size: {512, 512}, quality: :high)

      assert_received {:request, %ImageRequest{n: 3, size: {512, 512}, quality: :high}, _opts}
    end

    test "happy path through FakeImages returns %ImageResponse{}" do
      engine = engine_with_script([{:ok, [single_image()]}])
      base = single_image()

      assert {:ok, %ImageResponse{images: [_]}} =
               ALLM.edit_image(engine, base, "make sky pink")
    end
  end

  describe "cross-function mirror property (Decision #6)" do
    property "edit_image/4 with single base produces same struct as ALLM.image_request/2 (modulo :metadata.request_id)" do
      check all(
              prompt <- StreamData.string(:printable, min_length: 1, max_length: 20),
              n <- StreamData.integer(1..4)
            ) do
        base = single_image()

        engine = Engine.new(image_adapter: CaptureAdapter)
        {:ok, _} = ALLM.edit_image(engine, base, prompt, n: n)

        assert_received {:request, sugar_req, _opts}

        explicit =
          ALLM.image_request(prompt,
            operation: :edit,
            input_images: [base],
            n: n
          )

        assert Map.from_struct(sugar_req) == Map.from_struct(explicit)
      end
    end
  end
end
