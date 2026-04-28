defmodule ALLM.Providers.OpenAI.ImagesLiveTest do
  @moduledoc """
  Live OpenAI Images provider smoke tests (`@moduletag :live_openai_images`).

  Excluded by default in `test/test_helper.exs`. Opt-in via:

      OPENAI_API_KEY=sk-... mix test --include live_openai_images \\
        test/allm/providers/openai/images_live_test.exs

  ## Cost (per clean run)

  ~$0.034 total per pass (~$0.03–0.04):

    * `dall-e-2` `:generate` at 256x256 — ~$0.016
    * `dall-e-2` `:edit` at 256x256 — ~$0.018

  Per Decision #16 in `steering/PHASE_15_image_layer_6.md`, the live
  smoke test runs both `:generate` and `:edit` cells; `:variation` is a
  strict subset of `:edit`'s multipart shape (drops `prompt` / `mask`)
  and is NOT live-tested to keep costs bounded. Both `images_live_test`
  cells together verify the request-shape contract end-to-end against
  real OpenAI — neither wire-stub fixtures nor synthesized fixtures
  catch per-model rejection or request-side wire-shape divergences
  (per AGENT_DESIGN_SPEC.md rule 16).

  ## Skip path

  When `OPENAI_API_KEY` is unset or empty, the entire module is tagged
  `:skip` so opportunistic local runs do not fail noisily — same idiom
  as `test/allm/providers/openai_live_test.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :live_openai_images

  if System.get_env("OPENAI_API_KEY") in [nil, ""] do
    @moduletag :skip
  end

  alias ALLM.{Image, ImageRequest, ImageResponse}
  alias ALLM.Providers.OpenAI.Images

  @sample_png_path "test/fixtures/openai/images/inputs/sample_256.png"

  test "live: dall-e-2 generate at 256x256 returns one image with PNG-decoded bytes" do
    req =
      ImageRequest.new(
        operation: :generate,
        prompt: "a small watercolor kestrel in flight, soft natural light",
        model: "dall-e-2",
        n: 1,
        size: {256, 256},
        response_format: :binary
      )

    assert {:ok, %ImageResponse{} = resp} =
             Images.generate(req, retry: false, request_timeout: 120_000)

    assert length(resp.images) == 1
    assert resp.usage.images == 1
    assert [%Image{source: {:binary, bytes}}] = resp.images
    # Decoded PNG signature: 89 50 4E 47 (\x89PNG)
    assert <<137, 80, 78, 71, _::binary>> = bytes
  end

  test "live: dall-e-2 edit at 256x256 returns one image (multipart wire path validated)" do
    base_bytes = File.read!(@sample_png_path)
    base = Image.from_binary(base_bytes, "image/png")

    req =
      ImageRequest.new(
        operation: :edit,
        prompt: "transform into a vibrant impressionist painting",
        model: "dall-e-2",
        n: 1,
        size: {256, 256},
        input_images: [base],
        response_format: :binary
      )

    assert {:ok, %ImageResponse{} = resp} =
             Images.generate(req, retry: false, request_timeout: 120_000)

    assert length(resp.images) == 1
    assert resp.usage.images == 1
    assert [%Image{source: {:binary, bytes}}] = resp.images
    assert <<137, 80, 78, 71, _::binary>> = bytes
  end
end
