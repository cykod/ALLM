# scripts/record_gemini_stream_fixtures.exs
#
# One-time fixture recorder for `test/fixtures/gemini/generate_content/`
# (recorded `.sse` SSE streams). Runs against the live Google Generative
# Language API; gated on `GEMINI_API_KEY`. Refuses to overwrite anything
# under `test/fixtures/gemini/synthesized/` (the synthesized baseline
# shipped in Phase 16.2 for stream tests).
#
# Usage:
#
#     GEMINI_API_KEY=... mix run scripts/record_gemini_stream_fixtures.exs
#
# Optional model override:
#
#     GEMINI_API_KEY=... ALLM_MODEL=gemini-2.5-pro mix run scripts/record_gemini_stream_fixtures.exs
#
# Per Phase 16 design Decision #11, the canonical model is
# `gemini-2.5-flash` for Phase 16.1/16.2 fixtures.
#
# Per CLAUDE.md "Phases shipping synthesized wire fixtures": the
# script is idempotent — files that already exist and lack the leading
# SSE-comment synthesized marker are NEVER overwritten. To re-record,
# delete the target file first OR ensure the file's first line starts
# with `: Synthesized for Phase`.
#
# Output: writes raw SSE bytes (the response body verbatim from the
# streaming endpoint). Tests load via
# `ALLM.Providers.GeminiTestFixtures.stream_chunks/1`.
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/`.

defmodule RecordGeminiStreamFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/gemini/generate_content"
  @synthesized_dir "test/fixtures/gemini/synthesized"
  @synthesized_marker ": Synthesized for Phase"
  @synthesized_marker_legacy ": Synthesized"
  @model_default "gemini-2.5-flash"
  @endpoint "https://generativelanguage.googleapis.com/v1beta"

  def run do
    unless System.get_env("GEMINI_API_KEY") do
      IO.puts(:stderr, "GEMINI_API_KEY not set — refusing to record.")
      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)
    model = System.get_env("ALLM_MODEL", @model_default)

    # Phase 16.2 stream fixtures — recorded variants of the synthesized
    # baseline (see test/fixtures/gemini/synthesized/*.sse for the
    # phase-16.2-shipped synthesized rows).

    record(:happy_text_stream, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Reply with: hello world"}]}
      ],
      "generationConfig" => %{"maxOutputTokens" => 64}
    })

    record(:intermediate_usage_stream, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Count to three; one word per response."}]}
      ],
      "generationConfig" => %{"maxOutputTokens" => 32}
    })

    IO.puts(
      "Done. Recorded SSE fixtures live under #{@recorded_dir}/. " <>
        "Synthesized baseline under #{@synthesized_dir}/ is untouched."
    )
  end

  defp record(name, model, body) do
    path_recorded = Path.join(@recorded_dir, "#{name}.sse")
    path_synth = Path.join(@synthesized_dir, "#{name}.sse")

    cond do
      File.exists?(path_recorded) and not synthesized_marker?(path_recorded) ->
        IO.puts(
          "- #{path_recorded} already recorded (no synth marker) — refusing to overwrite. " <>
            "Delete first to re-record."
        )

      true ->
        # The recorded path lives under `generate_content/`; loaders prefer
        # recorded over synthesized. We DO NOT remove the synth baseline.
        do_record(name, model, body, path_recorded, path_synth)
    end
  end

  defp synthesized_marker?(path) do
    case File.read(path) do
      {:ok, contents} ->
        first_line =
          contents
          |> String.split("\n", parts: 2)
          |> List.first()
          |> Kernel.||("")

        String.starts_with?(first_line, @synthesized_marker) or
          String.starts_with?(first_line, @synthesized_marker_legacy)

      _ ->
        false
    end
  end

  defp do_record(name, model, body, path_recorded, _path_synth) do
    key = System.get_env("GEMINI_API_KEY")
    url = @endpoint <> "/models/#{model}:streamGenerateContent?alt=sse"

    json_body = Jason.encode!(body)

    finch_request =
      Finch.build(
        :post,
        url,
        [
          {"x-goog-api-key", key},
          {"content-type", "application/json"}
        ],
        json_body
      )

    {:ok, _} = Finch.start_link(name: __MODULE__.Finch)

    {:ok, response} = Finch.request(finch_request, __MODULE__.Finch, receive_timeout: 60_000)

    case response.status do
      200 ->
        File.write!(path_recorded, response.body)
        IO.puts("✓ recorded #{path_recorded} (#{byte_size(response.body)} bytes)")

      other ->
        IO.puts(:stderr, "✗ #{name} failed: HTTP #{other} — #{inspect(response.body)}")
    end
  end
end

RecordGeminiStreamFixtures.run()
