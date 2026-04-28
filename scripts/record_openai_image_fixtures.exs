# scripts/record_openai_image_fixtures.exs
#
# One-time fixture recorder for `test/fixtures/openai/images/recorded/`.
# Runs against the live OpenAI Images API; gated on `OPENAI_API_KEY`.
# Refuses to overwrite anything under `test/fixtures/openai/images/synthesized/`
# AND refuses to overwrite a `recorded/` file that's already been recorded
# (i.e., no longer carries a leading `_comment` field).
#
# Usage:
#
#     OPENAI_API_KEY=sk-... mix run scripts/record_openai_image_fixtures.exs
#
# Approximate cost (one-time):
#   - dall-e-2 256x256 generate (b64_json):   ~$0.016
#   - dall-e-2 256x256 generate (url):        ~$0.016
#   - dall-e-2 256x256 generate (n: 4 b64):   ~$0.064
#   - dall-e-3 1024x1024 generate (b64_json): ~$0.040
#   - gpt-image-1 1024x1024 generate (low quality): ~$0.011
#   - dall-e-2 256x256 edit (b64_json):       ~$0.018
#   - gpt-image-1 1024x1024 edit (low quality): ~$0.012
#   - dall-e-2 256x256 variation (b64_json):  ~$0.018
#   Total: ~$0.20
#
# Verify against current pricing at https://openai.com/api/pricing/.
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/` from the package files list.

defmodule RecordOpenAIImageFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/openai/images/recorded"

  # `:edit` cells use a small committed PNG as the input image so the
  # recorder is reproducible. Path is project-relative; the recorder runs
  # from the project root.
  @edit_input_path "test/fixtures/openai/images/inputs/sample_256.png"

  @specs [
    %{
      name: "generate_dall_e_2_happy",
      body: %{
        "model" => "dall-e-2",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => 1,
        "size" => "256x256",
        "response_format" => "b64_json"
      }
    },
    %{
      name: "generate_dall_e_2_url_happy",
      body: %{
        "model" => "dall-e-2",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => 1,
        "size" => "256x256",
        "response_format" => "url"
      }
    },
    %{
      name: "generate_dall_e_2_n4_happy",
      body: %{
        "model" => "dall-e-2",
        "prompt" => "a watercolor kestrel, four small variations",
        "n" => 4,
        "size" => "256x256",
        "response_format" => "b64_json"
      }
    },
    %{
      name: "generate_dall_e_3_happy",
      body: %{
        "model" => "dall-e-3",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => 1,
        "size" => "1024x1024",
        "response_format" => "b64_json",
        "quality" => "hd",
        "style" => "vivid"
      }
    },
    %{
      # gpt-image-1 ALWAYS returns base64 (Phase 15 Decision #5 — the
      # model rejects the `response_format` parameter at the wire), so the
      # body OMITS that field. `quality: "low"` keeps the recording cost
      # to ~$0.011. The recorded response carries `usage.input_tokens` /
      # `output_tokens` / `input_tokens_details` (Phase 15.3 wire-field map).
      name: "generate_gpt_image_1_happy",
      body: %{
        "model" => "gpt-image-1",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => 1,
        "size" => "1024x1024",
        "quality" => "low"
      }
    },
    %{
      # Phase 15.4 :edit deliverable. Uses the committed sample PNG as the
      # input image. dall-e-2 :edit costs ~$0.018 for one 256x256 output.
      name: "edit_dall_e_2_happy",
      endpoint: "edits",
      multipart: true,
      form: %{
        "model" => "dall-e-2",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => "1",
        "size" => "256x256",
        "response_format" => "b64_json"
      }
    },
    %{
      # Phase 15.4 :edit deliverable for gpt-image-1. ALWAYS returns
      # base64; recorded response carries token-usage shape.
      name: "edit_gpt_image_1_happy",
      endpoint: "edits",
      multipart: true,
      form: %{
        "model" => "gpt-image-1",
        "prompt" => "a watercolor kestrel in flight, soft natural light",
        "n" => "1",
        "size" => "1024x1024",
        "quality" => "low"
      }
    },
    %{
      # Phase 15.5 :variation deliverable. Variation is dall-e-2 ONLY (per
      # the model × operation matrix); drops `prompt` and `mask` from the
      # multipart body. Output costs match :edit at the same size
      # (~$0.018 for one 256x256 image).
      name: "variation_dall_e_2_happy",
      endpoint: "variations",
      multipart: true,
      form: %{
        "model" => "dall-e-2",
        "n" => "1",
        "size" => "256x256",
        "response_format" => "b64_json"
      }
    }
  ]

  def run do
    unless System.get_env("OPENAI_API_KEY") do
      IO.puts(:stderr, "OPENAI_API_KEY not set — refusing to record.")
      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)

    Enum.each(@specs, fn spec -> record(spec) end)

    IO.puts(
      "Done. Recorded fixtures live under #{@recorded_dir}/. Review the diff " <>
        "and update README.md's snapshot date."
    )
  end

  defp record(%{name: name} = spec) do
    path = Path.join(@recorded_dir, "#{name}.json")

    if synthesized_or_missing?(path) do
      do_record(path, spec, name)
    else
      IO.puts(
        "- #{path} already recorded (no _comment marker) — refusing to overwrite. " <>
          "Delete first to re-record."
      )
    end
  end

  # Treat a file as "okay to overwrite" when it doesn't exist OR it still
  # carries the leading `_comment` marker that synthesized fixtures use.
  # Real recorded responses don't have a `_comment` field.
  defp synthesized_or_missing?(path) do
    case File.read(path) do
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"_comment" => _}} -> true
          _ -> false
        end
    end
  end

  defp do_record(path, %{multipart: true, form: form, endpoint: endpoint}, name) do
    key = System.get_env("OPENAI_API_KEY")
    image_bytes = File.read!(@edit_input_path)

    multipart =
      [{"image", {image_bytes, filename: "image.png", content_type: "image/png"}}] ++
        Enum.map(form, fn {k, v} -> {k, v} end)

    response =
      Req.post!(
        "https://api.openai.com/v1/images/" <> endpoint,
        headers: [{"authorization", "Bearer " <> key}],
        form_multipart: multipart,
        receive_timeout: 120_000
      )

    write_or_log(path, name, response)
  end

  defp do_record(path, %{body: body}, name) do
    key = System.get_env("OPENAI_API_KEY")

    response =
      Req.post!(
        "https://api.openai.com/v1/images/generations",
        headers: [
          {"authorization", "Bearer " <> key},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 120_000
      )

    write_or_log(path, name, response)
  end

  defp write_or_log(path, name, response) do
    case response.status do
      200 ->
        File.write!(path, Jason.encode!(response.body, pretty: true) <> "\n")
        IO.puts("✓ recorded #{path}")

      other ->
        IO.puts(:stderr, "✗ #{name} failed: HTTP #{other} — #{inspect(response.body)}")
    end
  end
end

RecordOpenAIImageFixtures.run()
