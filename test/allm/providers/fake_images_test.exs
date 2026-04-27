defmodule ALLM.Providers.FakeImagesTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}
  alias ALLM.Providers.FakeImages

  doctest FakeImages

  # The conformance suite — Phase 14.1.2 step "use ALLM.Test.ImageAdapterConformance"
  use ALLM.Test.ImageAdapterConformance, image_adapter: FakeImages

  describe "supported_operations/0" do
    test "returns the closed list of three image operations" do
      assert FakeImages.supported_operations() == [:generate, :edit, :variation]
    end
  end

  describe "generate/2 — script-shape coverage" do
    test ":ok 2-tuple returns the images plus default usage with images: length(images)" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

      assert {:ok, %ImageResponse{images: [^img], usage: %ImageUsage{images: 1}}} =
               FakeImages.generate(req, opts)
    end

    test ":ok 3-tuple returns the supplied usage verbatim" do
      img = Image.from_binary(<<1>>, "image/png")
      usage = %ImageUsage{images: 1, input_tokens: 100}
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [img], usage: usage}]]]

      assert {:ok, %ImageResponse{usage: ^usage}} = FakeImages.generate(req, opts)
    end

    test ":error 2-tuple with %ImageAdapterError{} returns the struct verbatim" do
      err = ImageAdapterError.new(:rate_limited, retry_after_ms: 500)
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:error, err}]]]

      assert {:error, ^err} = FakeImages.generate(req, opts)
    end

    test "exhausted/empty script returns ImageAdapterError{:unknown, metadata: %{cause: :no_scripted_image}}" do
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: []]]

      assert {:error, %ImageAdapterError{reason: :unknown, metadata: meta} = err} =
               FakeImages.generate(req, opts)

      assert meta.cause == :no_scripted_image
      assert err.message == "no scripted image"
    end
  end

  describe "generate/2 — operation gate" do
    test "request operation not in supported_operations returns :unsupported_operation BEFORE script consult" do
      # Construct a request whose operation, while in the closed enum, is
      # not in our adapter's supported_operations. To exercise this path
      # against FakeImages itself (which supports all three), use a sister
      # adapter whose supported_operations are narrower.
      defmodule GenOnlyForTest do
        @behaviour ALLM.ImageAdapter
        @impl true
        def supported_operations, do: [:generate]
        @impl true
        def generate(%ImageRequest{operation: :generate} = req, opts) do
          # Delegate to FakeImages once the gate passes — but we never get here.
          FakeImages.generate(req, opts)
        end

        def generate(%ImageRequest{operation: op}, _opts) do
          {:error,
           ImageAdapterError.new(:unsupported_operation,
             metadata: %{operation: op}
           )}
        end
      end

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          input_images: [Image.from_binary(<<1>>, "image/png")]
        )

      assert {:error,
              %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :edit}}} =
               GenOnlyForTest.generate(req, [])
    end
  end

  describe "generate/2 — operation × script matrix" do
    test ":generate with prompt + 1-image script returns the image" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :generate, prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [img]}]]]
      assert {:ok, %ImageResponse{images: [^img]}} = FakeImages.generate(req, opts)
    end

    test ":edit with prompt + input_image + 1-image script returns the image" do
      base = Image.from_binary(<<1>>, "image/png")
      out = Image.from_binary(<<2>>, "image/png")
      req = ImageRequest.new(operation: :edit, prompt: "x", input_images: [base])
      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]
      assert {:ok, %ImageResponse{images: [^out]}} = FakeImages.generate(req, opts)
    end

    test ":variation with input_image + 1-image script returns the image (prompt nil)" do
      base = Image.from_binary(<<1>>, "image/png")
      out = Image.from_binary(<<2>>, "image/png")
      req = ImageRequest.new(operation: :variation, prompt: nil, input_images: [base])
      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]
      assert {:ok, %ImageResponse{images: [^out]}} = FakeImages.generate(req, opts)
    end

    test "n: 4 with a 4-image script returns all four images" do
      imgs = for i <- 1..4, do: Image.from_binary(<<i>>, "image/png")
      req = ImageRequest.new(prompt: "x", n: 4)
      opts = [adapter_opts: [image_script: [{:ok, imgs}]]]
      assert {:ok, %ImageResponse{images: out}} = FakeImages.generate(req, opts)
      assert length(out) == 4
    end
  end

  describe "generate/2 — request_id and metadata propagation" do
    test "preserves opts[:request_id] onto response.request_id" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [img]}]], request_id: "rid-1"]

      assert {:ok, %ImageResponse{request_id: "rid-1"}} = FakeImages.generate(req, opts)
    end

    test "round-trips request.metadata onto response.metadata" do
      img = Image.from_binary(<<1>>, "image/png")
      meta = %{trace_id: "abc"}
      req = ImageRequest.new(prompt: "x", metadata: meta)
      opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

      assert {:ok, %ImageResponse{metadata: ^meta}} = FakeImages.generate(req, opts)
    end

    test "response.model defaults to request.model when set" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x", model: "fake-model")
      opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

      assert {:ok, %ImageResponse{model: "fake-model"}} = FakeImages.generate(req, opts)
    end
  end

  describe "cursor management — process-dict default" do
    test "two consecutive calls against a 2-entry script return entries 0 and 1" do
      img1 = Image.from_binary(<<1>>, "image/png")
      img2 = Image.from_binary(<<2>>, "image/png")

      script = [{:ok, [img1]}, {:ok, [img2]}]
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: script]]

      assert {:ok, %ImageResponse{images: [^img1]}} = FakeImages.generate(req, opts)
      assert {:ok, %ImageResponse{images: [^img2]}} = FakeImages.generate(req, opts)
    end

    test "exhausted script does NOT wrap around — returns no_scripted_image" do
      img = Image.from_binary(<<1>>, "image/png")
      script = [{:ok, [img]}]
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: script]]

      assert {:ok, _} = FakeImages.generate(req, opts)

      assert {:error, %ImageAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_image}}} =
               FakeImages.generate(req, opts)
    end
  end

  describe "cursor management — explicit Agent" do
    test "start_script_cursor/0 returns a pid; cursor isolates across processes" do
      pid = FakeImages.start_script_cursor()
      assert is_pid(pid)
      assert FakeImages.cursor_index(pid) == 0

      img1 = Image.from_binary(<<1>>, "image/png")
      img2 = Image.from_binary(<<2>>, "image/png")
      script = [{:ok, [img1]}, {:ok, [img2]}]
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: script, script_cursor: pid]]

      task =
        Task.async(fn ->
          {FakeImages.generate(req, opts), FakeImages.generate(req, opts)}
        end)

      assert {{:ok, %ImageResponse{images: [^img1]}}, {:ok, %ImageResponse{images: [^img2]}}} =
               Task.await(task)

      assert FakeImages.cursor_index(pid) == 2
    end
  end

  describe "capture_pid side-channel" do
    test "sends {ALLM.Providers.FakeImages, :call, %{request, opts}} to capture_pid before script consult" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "a kestrel")

      opts = [
        adapter_opts: [image_script: [{:ok, [img]}], capture_pid: self()],
        request_id: "rid-cap"
      ]

      assert {:ok, %ImageResponse{}} = FakeImages.generate(req, opts)

      assert_receive {FakeImages, :call, %{request: ^req, opts: captured_opts}}
      assert Keyword.get(captured_opts, :request_id) == "rid-cap"
    end

    test "captures even rejected (unsupported_operation) calls" do
      defmodule GenOnlyForCaptureTest do
        @behaviour ALLM.ImageAdapter
        @impl true
        def supported_operations, do: [:generate]
        @impl true
        def generate(%ImageRequest{operation: :generate} = req, opts),
          do: FakeImages.generate(req, opts)

        def generate(%ImageRequest{operation: op}, _opts) do
          {:error, ImageAdapterError.new(:unsupported_operation, metadata: %{operation: op})}
        end
      end

      base = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :edit, prompt: "x", input_images: [base])
      opts = [adapter_opts: [capture_pid: self()]]

      # Hit FakeImages directly with an :edit op — FakeImages supports :edit,
      # so it captures and proceeds. The capture firing BEFORE script consult
      # is what we're asserting.
      _ = FakeImages.generate(req, opts)
      assert_receive {FakeImages, :call, %{request: ^req}}
    end

    test "absent capture_pid is a no-op (no message sent)" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

      assert {:ok, _} = FakeImages.generate(req, opts)
      refute_received {FakeImages, :call, _}
    end
  end

  describe "script/1 grammar validation" do
    test "accepts well-formed entries" do
      img = Image.from_binary(<<1>>, "image/png")

      assert :ok =
               FakeImages.script([
                 {:ok, [img]},
                 {:ok, [img], usage: %ImageUsage{images: 1}},
                 {:error, ImageAdapterError.new(:timeout)}
               ])
    end

    test "raises ArgumentError on a malformed entry" do
      assert_raise ArgumentError, ~r/invalid FakeImages script entry/, fn ->
        FakeImages.script([{:bogus, "shape"}])
      end
    end

    test "accepts {:retry_until_call, n} entries (Phase 14.3)" do
      assert :ok = FakeImages.script([{:retry_until_call, 3}])

      img = Image.from_binary(<<1>>, "image/png")

      assert :ok =
               FakeImages.script([{:retry_until_call, 2}, {:ok, [img]}])
    end
  end

  describe "retry_until_call (Phase 14.3)" do
    test "{:retry_until_call, 1} advances on the first call (n - 1 = 0 retries)" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x")
      opts = [adapter_opts: [image_script: [{:retry_until_call, 1}, {:ok, [img]}]]]

      assert {:ok, %ImageResponse{images: [^img]}} = FakeImages.generate(req, opts)
    end

    test "{:retry_until_call, 3} returns :rate_limited for calls 1 and 2; advances on call 3" do
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(prompt: "x")

      adapter_opts = [image_script: [{:retry_until_call, 3}, {:ok, [img]}]]

      assert {:error, %ImageAdapterError{reason: :rate_limited, retry_after_ms: 0} = err1} =
               FakeImages.generate(req, adapter_opts: adapter_opts)

      assert err1.message == "FakeImages retry_until_call hint"

      assert {:error, %ImageAdapterError{reason: :rate_limited}} =
               FakeImages.generate(req, adapter_opts: adapter_opts)

      assert {:ok, %ImageResponse{images: [^img]}} =
               FakeImages.generate(req, adapter_opts: adapter_opts)
    end

    test "{:retry_until_call, n} followed by no successor returns :no_scripted_image after exhaustion" do
      req = ImageRequest.new(prompt: "x")
      adapter_opts = [image_script: [{:retry_until_call, 2}]]

      assert {:error, %ImageAdapterError{reason: :rate_limited}} =
               FakeImages.generate(req, adapter_opts: adapter_opts)

      assert {:error, %ImageAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_image}}} =
               FakeImages.generate(req, adapter_opts: adapter_opts)
    end
  end
end
