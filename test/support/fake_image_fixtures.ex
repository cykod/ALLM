defmodule ALLM.Test.FakeImageFixtures do
  @moduledoc """
  Named scripted fixtures for `ALLM.Providers.FakeImages`. Every fixture
  returns a keyword `adapter_opts` ready to pass to `ALLM.Engine.new/1`
  under the `adapter_opts:` key (Phase 14.2 will wire `image_adapter:`).

  Layer B (test support) — lives under `test/support/` and is not part of
  the published Hex package. The Fake adapter itself ships in `lib/`
  (Decision #1) but its named test fixtures stay test-only.
  """

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageUsage}

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc """
  Single-image scripted response for a `:generate` request.
  """
  @spec single_generate() :: keyword()
  def single_generate do
    img = Image.from_binary(@png_bytes, "image/png")
    [image_script: [{:ok, [img]}]]
  end

  @doc """
  Batch of `n` images scripted for a single `:generate` call.
  """
  @spec multi_generate(pos_integer()) :: keyword()
  def multi_generate(n) when is_integer(n) and n >= 1 do
    img = Image.from_binary(@png_bytes, "image/png")
    [image_script: [{:ok, List.duplicate(img, n)}]]
  end

  @doc """
  Edit fixture — single output image for an `:edit` request.
  """
  @spec edit_with_mask() :: keyword()
  def edit_with_mask do
    img = Image.from_binary(@png_bytes, "image/png")
    [image_script: [{:ok, [img]}]]
  end

  @doc """
  Variation fixture — single output image for a `:variation` request.
  """
  @spec variation() :: keyword()
  def variation do
    img = Image.from_binary(@png_bytes, "image/png")
    [image_script: [{:ok, [img]}]]
  end

  @doc """
  Empty script — used to exercise the cursor-exhaustion path.
  """
  @spec exhausted_script() :: keyword()
  def exhausted_script do
    [image_script: []]
  end

  @doc """
  Script driving a scripted `:rate_limited` rejection — sister fixture for
  asserting error pass-through.
  """
  @spec unsupported_op() :: keyword()
  def unsupported_op do
    err =
      ImageAdapterError.new(:unsupported_operation,
        message: "scripted unsupported operation",
        metadata: %{operation: :edit}
      )

    [image_script: [{:error, err}]]
  end

  @doc """
  Fixture returning a single image with a populated `%ImageUsage{}` typical
  of a gpt-image-1-style token-priced call.
  """
  @spec gpt_image_1_usage() :: keyword()
  def gpt_image_1_usage do
    img = Image.from_binary(@png_bytes, "image/png")
    usage = %ImageUsage{images: 1, input_tokens: 100, output_tokens: 0}
    [image_script: [{:ok, [img], usage: usage}]]
  end
end
