# examples/13_image_variations.exs
#
# Provider: openai
#
# Demonstrates: a non-streaming `ALLM.image_variations/3` call against
#               OpenAI's `dall-e-2` model. dall-e-2 is the only OpenAI
#               image model that supports the variation operation
#               (gpt-image-1 supports edit only; dall-e-3 supports
#               generate only). The response carries a single varied
#               image which is materialized to bytes via
#               `ALLM.Image.to_binary/1`, written to a tmp file, and
#               asserted to start with the PNG magic-number signature.
# Spec section: §35.7 (OpenAI Images adapter — `:variation` operation),
#               §35.4/§35.5 (image-adapter facade).
# Steering strategy: tight — fixed model (`dall-e-2`), fixed 256x256
#                    size; assertion is a byte-prefix check on the PNG
#                    magic number — independent of pixel content. The
#                    base image is a tiny synthesized 1×1 PNG so the
#                    script does not depend on third-party URL
#                    availability.
# Cost: roughly ~$0.018 USD per clean run (dall-e-2 256x256 variation).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/13_image_variations.exs
#
# `run_all.exs` skips this script on `ALLM_PROVIDER=anthropic` (provider-
# arm gating per Phase 15.6 Decision #15 — Anthropic has no image
# adapter; Phase 17.3 Decision #9).

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.image_engine()

# Checked-in real 256×256 PNG fixture (generated once via dall-e-2);
# `dall-e-2` variations expect a square PNG of a known size.
base_png = File.read!(Path.join(__DIR__, "fixtures/kestrel_256.png"))
base = ALLM.Image.from_binary(base_png, "image/png")

case ALLM.image_variations(engine, base, size: "256x256", request_timeout: 60_000) do
  {:ok, %ALLM.ImageResponse{images: [image | _] = images, usage: usage}} ->
    case ALLM.Image.to_binary(image) do
      {:ok, <<137, 80, 78, 71, _::binary>> = bytes} ->
        path =
          Path.join(
            System.tmp_dir!(),
            "13_image_variations_#{System.os_time(:millisecond)}.png"
          )

        File.write!(path, bytes)

        IO.puts(
          "OK: image_variations — images=#{length(images)} usage.images=#{usage.images} " <>
            "bytes=#{byte_size(bytes)} path=#{path}"
        )

      {:ok, other} ->
        IO.puts(
          :stderr,
          "FAIL: variation image bytes did not start with PNG signature; got prefix=" <>
            inspect(:binary.part(other, 0, min(8, byte_size(other))))
        )

        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "FAIL: ALLM.Image.to_binary/1 returned error #{inspect(reason)}")
        System.halt(1)
    end

  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.image_variations/3 returned error #{inspect(error)}")
    System.halt(1)
end
