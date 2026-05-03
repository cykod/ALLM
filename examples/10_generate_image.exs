# examples/10_generate_image.exs
#
# Provider: openai, gemini
#
# Demonstrates: a non-streaming `ALLM.generate_image/3` call against
#               `dall-e-2` (256x256). The response carries a single image
#               which is materialized to bytes via `ALLM.Image.to_binary/1`
#               and written to a tmp file; the script asserts the PNG
#               magic-number signature on the on-disk bytes.
# Spec section: §35.7 (OpenAI Images adapter), §35.1 (image data structs).
# Steering strategy: tight — fixed `size: "256x256"`, fixed prompt, fixed
#                    model (`dall-e-2`); the assertion is a byte-prefix
#                    check on the PNG magic number — independent of the
#                    actual pixel content.
# Source policy: this script does NOT use `:url` source images. Per the
#                Phase 15.4 retro / 15.6 design hint, future image-input
#                examples (`:edit` / `:variation`) should also prefer
#                `:binary` or `:file` sources so the BLOCKING `/review`
#                examples gate does not depend on third-party URL
#                availability. The default response format on `dall-e-2`
#                is `:base64` per the OpenAI Images adapter.
# Cost: roughly ~$0.016 USD per clean run (dall-e-2 256x256 generate).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/10_generate_image.exs
#
# `run_all.exs` skips this script on `ALLM_PROVIDER=anthropic` (provider-arm
# gating per Phase 15.6 Decision #15 — Anthropic has no image adapter).

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.image_engine()

case ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256") do
  {:ok, %ALLM.ImageResponse{images: [image | _] = images, usage: usage}} ->
    case ALLM.Image.to_binary(image) do
      {:ok, bytes} when is_binary(bytes) ->
        ext =
          case bytes do
            <<137, 80, 78, 71, _::binary>> -> "png"
            <<255, 216, 255, _::binary>> -> "jpg"
            _ -> nil
          end

        if ext do
          path =
            Path.join(System.tmp_dir!(), "10_generate_image_#{System.os_time(:millisecond)}.#{ext}")

          File.write!(path, bytes)

          IO.puts(
            "OK: generate_image — images=#{length(images)} usage.images=#{usage.images} " <>
              "bytes=#{byte_size(bytes)} path=#{path}"
          )
        else
          IO.puts(
            :stderr,
            "FAIL: generated image bytes did not start with PNG/JPEG signature; got prefix=" <>
              inspect(:binary.part(bytes, 0, min(8, byte_size(bytes))))
          )

          System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "FAIL: ALLM.Image.to_binary/1 returned error #{inspect(reason)}")
        System.halt(1)
    end

  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.generate_image/3 returned error #{inspect(error)}")
    System.halt(1)
end
