# Live-recorder for Anthropic vision wire fixtures (Phase 17.2).
#
# Idempotent per run: re-running with the same `ANTHROPIC_API_KEY` set
# overwrites all four source-shape fixtures. Cost per clean run is
# ~$0.005 (4 calls × ~$0.001/call against `claude-haiku-4-5-20251001`).
#
# Usage:
#
#     ANTHROPIC_API_KEY=sk-ant-... mix run scripts/record_anthropic_vision_fixtures.exs
#
# Output files (overwritten):
#
#   test/fixtures/anthropic/messages/vision/single_image_url.json
#   test/fixtures/anthropic/messages/vision/single_image_base64.json
#   test/fixtures/anthropic/messages/vision/single_image_binary.json
#   test/fixtures/anthropic/messages/vision/multi_image.json
#
# IMPORTANT: this script intentionally captures the RAW JSON body the
# provider returned — do not edit the resulting files manually. If a
# response shape needs to change for a test, re-record.

require Logger

alias ALLM.{Image, ImagePart, Message, Request, TextPart}
alias ALLM.Providers.Anthropic

defmodule RecordAnthropicVisionFixtures do
  @vision_dir "test/fixtures/anthropic/messages/vision"

  # 1x1 transparent PNG, 67 bytes — same payload used in the
  # @tag :live_anthropic test in test/allm/providers/anthropic_vision_test.exs.
  @one_pixel_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0,
                   0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8,
                   153, 99, 248, 207, 192, 0, 0, 0, 3, 0, 1, 91, 169, 33, 76, 0, 0, 0, 0, 73,
                   69, 78, 68, 174, 66, 96, 130>>

  def run(api_key) do
    File.mkdir_p!(@vision_dir)
    model = "claude-haiku-4-5-20251001"

    Logger.info("Recording Anthropic Messages-API vision fixtures against #{model}…")
    record("single_image_url", url_request(model), api_key)
    record("single_image_base64", base64_request(model), api_key)
    record("single_image_binary", binary_request(model), api_key)
    record("multi_image", multi_request(model), api_key)

    Logger.info("Done. Re-run mix test test/allm/providers/anthropic_vision_test.exs to verify.")
  end

  defp record(name, request, api_key) do
    case Anthropic.generate(request, api_key: api_key, retry: false) do
      {:ok, response} ->
        body = response.raw
        path = Path.join(@vision_dir, "#{name}.json")
        File.write!(path, Jason.encode_to_iodata!(body, pretty: true))
        Logger.info("  wrote #{path}")

      {:error, err} ->
        Logger.error("  failed for #{name}: #{inspect(err)}")
    end
  end

  defp user_msg(text, parts) do
    %Message{
      role: :user,
      content: [%TextPart{text: text} | parts]
    }
  end

  defp url_request(model) do
    img =
      Image.from_url(
        "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/64px-Cat03.jpg"
      )

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img}])],
      model: model,
      max_tokens: 50
    )
  end

  defp base64_request(model) do
    encoded = Base.encode64(@one_pixel_png)
    img = Image.from_base64(encoded, "image/png")

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img}])],
      model: model,
      max_tokens: 50
    )
  end

  defp binary_request(model) do
    img = Image.from_binary(@one_pixel_png, "image/png")

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img}])],
      model: model,
      max_tokens: 50
    )
  end

  defp multi_request(model) do
    img1 =
      Image.from_url(
        "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/64px-Cat03.jpg"
      )

    img2 = Image.from_binary(@one_pixel_png, "image/png")

    Request.new(
      [
        user_msg("compare in one short sentence", [
          %ImagePart{image: img1},
          %ImagePart{image: img2}
        ])
      ],
      model: model,
      max_tokens: 60
    )
  end
end

case System.fetch_env("ANTHROPIC_API_KEY") do
  {:ok, key} when is_binary(key) and key != "" ->
    RecordAnthropicVisionFixtures.run(key)

  _ ->
    IO.puts(:stderr, """
    ANTHROPIC_API_KEY is not set. Skipping live record.

    Synthesized fixtures already shipped under test/fixtures/anthropic/messages/vision/
    will be used by the test suite. Re-run with ANTHROPIC_API_KEY=sk-ant-... to capture
    real wire shapes.
    """)

    System.halt(1)
end
