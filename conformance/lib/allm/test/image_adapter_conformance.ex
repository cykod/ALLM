defmodule ALLM.Test.ImageAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.ImageAdapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyImageAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.ImageAdapterConformance, image_adapter: MyImageAdapter
      end

  Injects a `describe "ALLM.ImageAdapter conformance (MyImageAdapter)"`
  block with 9 deterministic cases per the v0.3 Phase 14.1 design.

  ## Script contract

  Each injected case scripts the adapter through `adapter_opts[:image_script]`
  on the call's `opts` keyword list. See `ALLM.Providers.FakeImages`'s
  `script/1` `@doc` for the full grammar (the published reference
  implementation that the conformance suite targets).

  Adapters that read their script from a different key may override by
  populating the matching field themselves — the harness's requirement is
  only that the adapter respects the shape the script declares (one
  `{:ok, [%Image{}]}` or `{:ok, [%Image{}], opts}` or
  `{:error, %ImageAdapterError{}}` entry consumed per call).

  ## Unsupported-operation case

  Case 2 (unsupported operation) requires an adapter whose
  `supported_operations/0` does NOT include `:edit`. The harness uses the
  caller-supplied `:image_adapter` for cases 1, 3-9, and uses
  `ALLM.Test.Fixtures.GenerateOnlyImageStub` (defined in the conformance
  package's `test/support/`) for case 2 — the test branches on whether the
  caller-supplied adapter narrows or not.
  """

  use ExUnit.CaseTemplate

  @case_count 9

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  using opts do
    quote location: :keep do
      @__allm_image_conformance_adapter__ Keyword.fetch!(unquote(opts), :image_adapter)

      describe "ALLM.ImageAdapter conformance (#{inspect(@__allm_image_conformance_adapter__)})" do
        alias ALLM.Error.ImageAdapterError
        alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}

        test "1. supported_operations/0 returns a list of legal operation atoms" do
          ops = @__allm_image_conformance_adapter__.supported_operations()
          assert is_list(ops)
          assert ops != []
          legal = [:generate, :edit, :variation]
          for op <- ops, do: assert(op in legal)
        end

        test "2. rejects unsupported operation before any I/O with %ImageAdapterError{:unsupported_operation}" do
          # Use a sister adapter whose supported_operations excludes :edit, so
          # the case can run uniformly regardless of whether the
          # caller-supplied adapter narrows or not.
          gen_only = Module.concat(["ALLM", "Test", "Fixtures", "GenerateOnlyImageStub"])

          if Code.ensure_loaded?(gen_only) and :edit not in gen_only.supported_operations() do
            req = ImageRequest.new(operation: :edit, prompt: "x")

            assert {:error, %ImageAdapterError{reason: :unsupported_operation, metadata: meta}} =
                     gen_only.generate(req, [])

            assert meta.operation == :edit
          else
            # Fall through: ensure the contracted adapter at minimum honors
            # the supported_operations gate when narrowed inputs are given.
            ops = @__allm_image_conformance_adapter__.supported_operations()
            unsupported = Enum.find([:generate, :edit, :variation], &(&1 not in ops))

            if unsupported do
              req = ImageRequest.new(operation: unsupported, prompt: "x")

              assert {:error, %ImageAdapterError{reason: :unsupported_operation, metadata: meta}} =
                       @__allm_image_conformance_adapter__.generate(req, [])

              assert meta.operation == unsupported
            else
              :ok
            end
          end
        end

        test "3. preserves opts[:request_id] onto ImageResponse.request_id" do
          img = Image.from_binary(<<1>>, "image/png")
          req = ImageRequest.new(prompt: "x")

          opts = [
            adapter_opts: [image_script: [{:ok, [img]}]],
            request_id: "test-id-123"
          ]

          assert {:ok, %ImageResponse{request_id: "test-id-123"}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)
        end

        test "4. round-trips request.metadata onto response.metadata when adapter doesn't override" do
          img = Image.from_binary(<<1>>, "image/png")
          metadata = %{trace_id: "abc", user: "alice"}
          req = ImageRequest.new(prompt: "x", metadata: metadata)
          opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

          assert {:ok, %ImageResponse{metadata: ^metadata}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)
        end

        test "5. happy path: returns {:ok, %ImageResponse{}} with non-empty images for :generate" do
          img = Image.from_binary(<<2, 3>>, "image/png")
          req = ImageRequest.new(operation: :generate, prompt: "a kestrel")
          opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

          assert {:ok, %ImageResponse{images: [_ | _]}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)
        end

        test "6. edit happy path: returns {:ok, %ImageResponse{}} for :edit with a single input image" do
          base = Image.from_binary(<<1>>, "image/png")
          out = Image.from_binary(<<2>>, "image/png")
          req = ImageRequest.new(operation: :edit, prompt: "make it blue", input_images: [base])
          opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

          assert {:ok, %ImageResponse{images: [_ | _]}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)
        end

        test "7. variation happy path: returns {:ok, %ImageResponse{}} for :variation with prompt: nil" do
          base = Image.from_binary(<<1>>, "image/png")
          out = Image.from_binary(<<2>>, "image/png")
          req = ImageRequest.new(operation: :variation, prompt: nil, input_images: [base])
          opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

          assert {:ok, %ImageResponse{images: [_ | _]}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)
        end

        test "8. ImageUsage defaults: response.usage.images >= 1 when adapter doesn't supply usage" do
          img = Image.from_binary(<<1>>, "image/png")
          req = ImageRequest.new(prompt: "x")
          opts = [adapter_opts: [image_script: [{:ok, [img]}]]]

          assert {:ok, %ImageResponse{usage: %ImageUsage{images: n}}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)

          assert n >= 1
        end

        test "9. n: 4 batch returns response.images with length in 1..4 (open upper bound — providers may cap)" do
          imgs = for _ <- 1..4, do: Image.from_binary(<<1>>, "image/png")
          req = ImageRequest.new(prompt: "x", n: 4)
          opts = [adapter_opts: [image_script: [{:ok, imgs}]]]

          assert {:ok, %ImageResponse{images: out}} =
                   @__allm_image_conformance_adapter__.generate(req, opts)

          assert length(out) in 1..4
        end
      end
    end
  end
end
