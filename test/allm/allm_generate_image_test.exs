defmodule ALLM.AllmGenerateImageTest do
  @moduledoc """
  Layer C facade tests for `ALLM.generate_image/3` (Phase 14.2, design
  §14.2.1).

  Asserts the bare-`with`-chain dispatch shape against
  `ALLM.Providers.FakeImages`: adapter-presence gate, string-prompt sugar,
  struct-form pass-through, `request_id` propagation, and adapter-error
  pass-through. NO telemetry, NO preflight, NO retry yet (Phase 14.3
  scope).
  """
  use ExUnit.Case, async: false

  alias ALLM.Engine
  alias ALLM.Error.{EngineError, ImageAdapterError}
  alias ALLM.{Image, ImageRequest, ImageResponse}
  alias ALLM.Providers.FakeImages

  doctest ALLM, only: [generate_image: 3]

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule CaptureAdapter do
    @moduledoc false
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate, :edit, :variation]

    def generate(req, opts) do
      pid = :erlang.whereis(:gen_image_capture)
      if is_pid(pid), do: send(pid, {:request, req, opts})
      {:ok, %ALLM.ImageResponse{images: [], usage: %ALLM.ImageUsage{}}}
    end
  end

  defmodule NilReqIdAdapter do
    @moduledoc false
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate, :edit, :variation]

    def generate(_req, _opts) do
      {:ok, %ALLM.ImageResponse{images: [], usage: %ALLM.ImageUsage{}, request_id: nil}}
    end
  end

  defmodule SetReqIdAdapter do
    @moduledoc false
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate, :edit, :variation]

    def generate(_req, _opts) do
      {:ok,
       %ALLM.ImageResponse{
         images: [],
         usage: %ALLM.ImageUsage{},
         request_id: "from-provider-header"
       }}
    end
  end

  defmodule GenerateOnlyAdapter do
    @moduledoc false
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate]

    def generate(%ALLM.ImageRequest{operation: :edit}, _opts) do
      {:error,
       ALLM.Error.ImageAdapterError.new(:unsupported_operation,
         metadata: %{operation: :edit}
       )}
    end

    def generate(_req, _opts) do
      {:ok, %ALLM.ImageResponse{images: [], usage: %ALLM.ImageUsage{}}}
    end
  end

  setup do
    name = :gen_image_capture

    case :erlang.whereis(name) do
      :undefined -> :ok
      _pid -> Process.unregister(name)
    end

    Process.register(self(), name)
    :ok
  end

  defp engine_with_script(script) do
    Engine.new(image_adapter: FakeImages, adapter_opts: [image_script: script])
  end

  defp single_image, do: Image.from_binary(@png_bytes, "image/png")

  describe "adapter presence" do
    test "with engine.image_adapter == nil returns {:error, %EngineError{reason: :no_image_adapter}}" do
      engine = Engine.new(adapter: ALLM.Providers.Fake)
      assert engine.image_adapter == nil

      assert {:error, %EngineError{reason: :no_image_adapter}} =
               ALLM.generate_image(engine, "a kestrel")
    end

    test "with engine.image_adapter set dispatches and returns {:ok, %ImageResponse{}}" do
      engine = engine_with_script([{:ok, [single_image()]}])

      assert {:ok, %ImageResponse{} = resp} = ALLM.generate_image(engine, "a kestrel")
      assert length(resp.images) == 1
    end
  end

  describe "string-prompt sugar" do
    test "generate_image(engine, \"a kestrel\") builds a generate-shaped request and dispatches" do
      engine = Engine.new(image_adapter: CaptureAdapter)

      assert {:ok, _} = ALLM.generate_image(engine, "a kestrel")
      assert_received {:request, %ImageRequest{operation: :generate, prompt: "a kestrel"}, _opts}
    end

    test "merges opts into the request (n, size)" do
      engine = Engine.new(image_adapter: CaptureAdapter)

      assert {:ok, _} =
               ALLM.generate_image(engine, "a kestrel", n: 2, size: {1024, 1024})

      assert_received {:request, %ImageRequest{n: 2, size: {1024, 1024}, prompt: "a kestrel"},
                       _opts}
    end
  end

  describe "struct form" do
    test "with %ImageRequest{} dispatches the struct verbatim (does NOT re-wrap)" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      img = single_image()
      input = %ImageRequest{operation: :variation, input_images: [img], prompt: nil}

      assert {:ok, _} = ALLM.generate_image(engine, input)
      assert_received {:request, ^input, _opts}
    end

    test "manually-built %ImageRequest{prompt: \"\"} dispatches without validating (Decision #13)" do
      engine = engine_with_script([{:ok, [single_image()]}])
      req = %ImageRequest{operation: :generate, prompt: ""}
      assert {:ok, %ImageResponse{}} = ALLM.generate_image(engine, req)
    end
  end

  describe "request_id propagation" do
    test "generates a request_id when opts has none and forwards to the adapter via opts[:request_id]" do
      engine = Engine.new(image_adapter: CaptureAdapter)
      assert {:ok, _} = ALLM.generate_image(engine, "x")

      assert_received {:request, _req, opts}
      id = Keyword.get(opts, :request_id)
      assert is_binary(id)
      assert byte_size(id) > 0
    end

    test "forwards opts[:request_id] verbatim" do
      engine = Engine.new(image_adapter: CaptureAdapter)

      assert {:ok, _} = ALLM.generate_image(engine, "x", request_id: "caller-supplied")
      assert_received {:request, _req, opts}
      assert Keyword.get(opts, :request_id) == "caller-supplied"
    end

    test "Response.request_id is filled from opts[:request_id] when adapter returns nil" do
      engine = Engine.new(image_adapter: NilReqIdAdapter)

      assert {:ok, %ImageResponse{request_id: "facade-fills"}} =
               ALLM.generate_image(engine, "x", request_id: "facade-fills")
    end

    test "preserves response.request_id when adapter sets it (does NOT overwrite)" do
      engine = Engine.new(image_adapter: SetReqIdAdapter)

      assert {:ok, %ImageResponse{request_id: "from-provider-header"}} =
               ALLM.generate_image(engine, "x", request_id: "facade-supplied")
    end
  end

  describe "adapter-error pass-through" do
    test "FakeImages cursor-exhaustion :unknown surfaces verbatim" do
      engine = engine_with_script([])

      assert {:error, %ImageAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_image}}} =
               ALLM.generate_image(engine, "x")
    end

    test "adapter :unsupported_operation rejection surfaces verbatim" do
      engine = Engine.new(image_adapter: GenerateOnlyAdapter)
      req = %ImageRequest{operation: :edit, prompt: "x", input_images: [single_image()]}

      assert {:error,
              %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :edit}}} =
               ALLM.generate_image(engine, req)
    end
  end

  describe ":stream opt is silently dropped (line 294)" do
    test "generate_image with stream: true does NOT error" do
      engine = engine_with_script([{:ok, [single_image()]}])
      assert {:ok, %ImageResponse{}} = ALLM.generate_image(engine, "x", stream: true)
    end

    test "adapter does NOT receive :stream in dispatch opts (Phase 14.2 fix)" do
      engine = Engine.new(image_adapter: CaptureAdapter)

      assert {:ok, _} = ALLM.generate_image(engine, "x", stream: true)
      assert_received {:request, _req, opts}
      refute Keyword.has_key?(opts, :stream)
    end
  end

  describe "adapter_opts merge precedence (Phase 14.2 fix — Finding 1)" do
    test "engine.adapter_opts wins on collision with call-site adapter_opts (mirrors chat-side `++`)" do
      # Engine carries adapter_opts: [foo: :engine]; call-site supplies
      # adapter_opts: [foo: :call]. With `++` precedent (Keyword.get returns
      # first occurrence), engine wins. With Keyword.merge/2 (the pre-fix
      # bug), call would have won.
      engine =
        Engine.new(
          image_adapter: CaptureAdapter,
          adapter_opts: [foo: :engine]
        )

      assert {:ok, _} =
               ALLM.generate_image(engine, "x", adapter_opts: [foo: :call])

      assert_received {:request, _req, opts}
      merged = Keyword.get(opts, :adapter_opts)
      assert Keyword.get(merged, :foo) == :engine
    end
  end
end
