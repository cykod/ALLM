# scripts/record_openai_embeddings_fixtures.exs
#
# Fixture recorder for `test/fixtures/openai/embeddings/recorded/`.
# Runs against the live OpenAI Embeddings API; gated on `OPENAI_API_KEY`.
#
# Idempotent by construction: it NEVER touches
# `test/fixtures/openai/embeddings/synthesized/`, and it refuses to overwrite
# a `recorded/` file that has already been recorded — i.e. one that no longer
# carries a leading `_comment` provenance marker. A second run against an
# already-recorded tree is therefore a no-op.
#
# Usage:
#
#     mix run scripts/record_openai_embeddings_fixtures.exs
#
# The key is read from the environment, but a project-root `.env` is loaded
# first — that gitignored file is this repo's documented key mechanism
# (`examples/README.md`), and `examples/_helpers.exs` already loads it via the
# `:env_loader` dev dep. Recorder scripts historically read `System.get_env/1`
# bare, which reports "OPENAI_API_KEY not set" in a fully-provisioned checkout
# and makes the script's own diagnostic confirm a false premise. "No key"
# means absent AFTER that load. `.env` is consulted only when the variable is
# not already set, so an explicit assignment still wins:
#
#     OPENAI_API_KEY=sk-... mix run scripts/record_openai_embeddings_fixtures.exs
#
# To deliberately re-record a fixture, delete the file first (or restore its
# `_comment` marker) and re-run.
#
# Approximate cost (one-time), `text-embedding-3-small` at $0.02 / 1M tokens:
#
#   - single_input        (1 short input):        ~5 tokens
#   - batch_input         (3 short inputs):       ~12 tokens
#   - reduced_dimensions  (1 short input, d=512): ~5 tokens
#   Total: ~22 tokens, well under $0.0001.
#
# Verify against current pricing at https://openai.com/api/pricing/.
#
# Load-bearing details for the wire tests
# ---------------------------------------
#
#   * `batch_input` MUST record exactly THREE inputs —
#     `test/allm/providers/openai/embeddings_wire_test.exs` drives it with a
#     three-element `:input` and asserts
#     `length(embeddings) == length(input)` (the assertion that binds
#     `ALLM.EmbeddingAdapter` invariant 8 for this adapter, which the
#     conformance suite cannot).
#   * `reduced_dimensions` MUST request fewer dimensions than the model's
#     native width, because the wire test asserts
#     `dimension_of(reduced) < dimension_of(single_input)`.
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/` from the package files list.

defmodule RecordOpenAIEmbeddingsFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/openai/embeddings/recorded"
  @url "https://api.openai.com/v1/embeddings"
  @model "text-embedding-3-small"

  @specs [
    %{
      name: "single_input",
      body: %{"model" => @model, "input" => ["a kestrel"]}
    },
    %{
      # Exactly three inputs — see the header note.
      name: "batch_input",
      body: %{"model" => @model, "input" => ["chunk one", "chunk two", "chunk three"]}
    },
    %{
      # `dimensions` is supported on text-embedding-3 and later only; 512 is
      # comfortably below the model's native 1536.
      name: "reduced_dimensions",
      body: %{"model" => @model, "input" => ["a kestrel"], "dimensions" => 512}
    }
  ]

  def run do
    load_dotenv()

    unless System.get_env("OPENAI_API_KEY") do
      IO.puts(
        :stderr,
        "OPENAI_API_KEY not set (checked the environment and project-root .env) — " <>
          "refusing to record."
      )

      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)

    Enum.each(@specs, &record/1)

    IO.puts(
      "Done. Recorded fixtures live under #{@recorded_dir}/. Review the diff, then " <>
        "re-run `mix test test/allm/providers/openai/embeddings_wire_test.exs`."
    )
  end

  # Mirrors `examples/_helpers.exs`'s `active_provider/0`. `:env_loader` is
  # `only: [:dev]` and `mix run scripts/…` runs in `:dev`, so the dep is
  # available here; the `Code.ensure_loaded?/1` guard keeps the script usable
  # under other MIX_ENVs.
  #
  # Loaded ONLY when the key is not already in the environment: `EnvLoader.load/1`
  # calls `System.put_env/2` unconditionally, so an unguarded load would let a
  # stale `.env` silently override an explicit
  # `OPENAI_API_KEY=… mix run scripts/…`. This ordering keeps explicit env winning.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("OPENAI_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end

  defp record(%{name: name} = spec) do
    path = Path.join(@recorded_dir, "#{name}.json")

    if overwritable?(path) do
      do_record(path, spec, name)
    else
      IO.puts(
        "- #{path} already recorded (no _comment marker) — refusing to overwrite. " <>
          "Delete it first to re-record."
      )
    end
  end

  # A file is safe to overwrite when it does not exist, or when it still
  # carries the leading `_comment` marker that synthesized placeholders use.
  # A real recorded response has no such field.
  defp overwritable?(path) do
    case File.read(path) do
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"_comment" => _}} -> true
          _ -> false
        end

      # Fail loudly with a readable reason rather than a CaseClauseError that
      # reads as a script bug when it is a permissions problem.
      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp do_record(path, %{body: body}, name) do
    key = System.get_env("OPENAI_API_KEY")

    response =
      Req.post!(@url,
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

RecordOpenAIEmbeddingsFixtures.run()
