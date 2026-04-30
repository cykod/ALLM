# Live-recorder for OpenAI vision wire fixtures (Phase 17.1).
#
# Idempotent per run: re-running with the same `OPENAI_API_KEY` set
# overwrites all four source-shape fixtures × both endpoints. Cost per
# clean run is ~$0.005 (4 calls × 2 endpoints × ~$0.0006/call against
# `gpt-4o-mini` and `gpt-5.5`).
#
# Usage:
#
#     OPENAI_API_KEY=sk-... mix run scripts/record_openai_vision_fixtures.exs
#
# Output files (overwritten):
#
#   test/fixtures/openai/chat_completions/vision/single_image_url.json
#   test/fixtures/openai/chat_completions/vision/single_image_base64.json
#   test/fixtures/openai/chat_completions/vision/single_image_binary.json
#   test/fixtures/openai/chat_completions/vision/multi_image.json
#   test/fixtures/openai/responses/vision/single_image_url.json
#   test/fixtures/openai/responses/vision/single_image_base64.json
#   test/fixtures/openai/responses/vision/single_image_binary.json
#   test/fixtures/openai/responses/vision/multi_image.json
#
# IMPORTANT: this script intentionally captures the RAW JSON body the
# provider returned — do not edit the resulting files manually. If a
# response shape needs to change for a test, re-record.

require Logger

alias ALLM.{Image, ImagePart, Message, Request, TextPart}
alias ALLM.Providers.OpenAI

defmodule RecordVisionFixtures do
  @chat_dir "test/fixtures/openai/chat_completions/vision"
  @resp_dir "test/fixtures/openai/responses/vision"

  # 1x1 transparent PNG, 67 bytes — the smallest valid PNG. Same payload
  # used in the @tag :live_openai test in test/allm/providers/openai_vision_test.exs.
  @one_pixel_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0,
                   0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8,
                   153, 99, 248, 207, 192, 0, 0, 0, 3, 0, 1, 91, 169, 33, 76, 0, 0, 0, 0, 73,
                   69, 78, 68, 174, 66, 96, 130>>

  def run(api_key) do
    File.mkdir_p!(@chat_dir)
    File.mkdir_p!(@resp_dir)

    chat_model = "gpt-4o-mini"
    resp_model = "gpt-5.5"

    Logger.info("Recording Chat Completions vision fixtures against #{chat_model}…")
    record(:chat, "single_image_url", url_request(chat_model), api_key)
    record(:chat, "single_image_base64", base64_request(chat_model), api_key)
    record(:chat, "single_image_binary", binary_request(chat_model), api_key)
    record(:chat, "multi_image", multi_request(chat_model), api_key)

    Logger.info("Recording Responses-API vision fixtures against #{resp_model}…")
    record(:resp, "single_image_url", url_request(resp_model), api_key)
    record(:resp, "single_image_base64", base64_request(resp_model), api_key)
    record(:resp, "single_image_binary", binary_request(resp_model), api_key)
    record(:resp, "multi_image", multi_request(resp_model), api_key)

    Logger.info("Done. Re-run mix test test/allm/providers/openai_vision_test.exs to verify.")
  end

  defp record(kind, name, request, api_key) do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request_body, raw})
      conn
    end

    # We can't easily intercept the response with the production adapter
    # without a custom transport; instead make the live call and
    # re-issue with body capture. Simplest: call generate/2 and capture
    # response.raw which is the full decoded body.
    case OpenAI.generate(request, api_key: api_key, retry: false) do
      {:ok, response} ->
        body = response.raw
        path = path_for(kind, name)
        File.write!(path, Jason.encode_to_iodata!(body, pretty: true))
        Logger.info("  wrote #{path}")

      {:error, err} ->
        Logger.error("  failed for #{name}: #{inspect(err)}")
    end
  end

  defp path_for(:chat, name), do: Path.join(@chat_dir, "#{name}.json")
  defp path_for(:resp, name), do: Path.join(@resp_dir, "#{name}.json")

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

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img, detail: :low}])],
      model: model,
      max_tokens: 50
    )
  end

  defp base64_request(model) do
    encoded = Base.encode64(@one_pixel_png)
    img = Image.from_base64(encoded, "image/png")

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img, detail: :low}])],
      model: model,
      max_tokens: 50
    )
  end

  defp binary_request(model) do
    img = Image.from_binary(@one_pixel_png, "image/png")

    Request.new([user_msg("describe in 5 words", [%ImagePart{image: img, detail: :low}])],
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
          %ImagePart{image: img1, detail: :low},
          %ImagePart{image: img2, detail: :low}
        ])
      ],
      model: model,
      max_tokens: 60
    )
  end
end

case System.fetch_env("OPENAI_API_KEY") do
  {:ok, key} when is_binary(key) and key != "" ->
    RecordVisionFixtures.run(key)

  _ ->
    IO.puts(:stderr, """
    OPENAI_API_KEY is not set. Skipping live record.

    Synthesized fixtures already shipped under test/fixtures/openai/{chat_completions,responses}/vision/
    will be used by the test suite. Re-run with OPENAI_API_KEY=sk-... to capture real wire shapes.
    """)

    System.halt(1)
end
