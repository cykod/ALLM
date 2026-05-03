# examples/11_edit_image.exs
#
# Provider: openai, gemini
#
# Demonstrates: a non-streaming `ALLM.edit_image/4` call against
#               `gpt-image-1` with a real 256×256 base image. The
#               response carries a single edited image which is
#               materialized to bytes via `ALLM.Image.to_binary/1`,
#               written to a tmp file, and asserted to start with the
#               PNG magic-number signature.
# Spec section: §35.7 (OpenAI Images adapter — `:edit` operation),
#               §35.4/§35.5 (image-adapter facade).
# Steering strategy: tight — fixed prompt, fixed model (`gpt-image-1`),
#                    fixed 1024x1024 size; assertion is a byte-prefix
#                    check on the PNG magic number — independent of
#                    the actual pixel content. The base image is a
#                    checked-in real 256×256 PNG fixture
#                    (`fixtures/kestrel_256.png`, generated once via
#                    dall-e-2) — `gpt-image-1`'s safety system rejects
#                    synthetic 1×1 placeholders with `moderation_blocked`,
#                    so a realistic photographic-style fixture is
#                    required. No mask is supplied — `gpt-image-1`
#                    accepts no-mask edits which apply the prompt
#                    globally.
# Cost: roughly ~$0.04 USD per clean run (gpt-image-1 1024x1024 edit).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/11_edit_image.exs
#
# `run_all.exs` skips this script on `ALLM_PROVIDER=anthropic` (provider-
# arm gating per Phase 15.6 Decision #15 — Anthropic has no image
# adapter; Phase 17.3 Decision #9).

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine =
  case System.get_env("ALLM_PROVIDER", "openai") do
    "gemini" -> ExamplesHelpers.image_engine()
    _ -> ExamplesHelpers.image_engine(model: "gpt-image-1")
  end

base_png = File.read!(Path.join(__DIR__, "fixtures/kestrel_256.png"))
base = ALLM.Image.from_binary(base_png, "image/png")

case ALLM.edit_image(engine, base, "add a small red dot in the center",
       size: "1024x1024",
       request_timeout: 120_000
     ) do
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
            Path.join(System.tmp_dir!(), "11_edit_image_#{System.os_time(:millisecond)}.#{ext}")

          File.write!(path, bytes)

          IO.puts(
            "OK: edit_image — images=#{length(images)} usage.images=#{usage.images} " <>
              "bytes=#{byte_size(bytes)} path=#{path}"
          )
        else
          IO.puts(
            :stderr,
            "FAIL: edited image bytes did not start with PNG/JPEG signature; got prefix=" <>
              inspect(:binary.part(bytes, 0, min(8, byte_size(bytes))))
          )

          System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "FAIL: ALLM.Image.to_binary/1 returned error #{inspect(reason)}")
        System.halt(1)
    end

  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.edit_image/4 returned error #{inspect(error)}")
    System.halt(1)
end
