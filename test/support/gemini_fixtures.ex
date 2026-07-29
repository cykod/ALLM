defmodule ALLM.Providers.GeminiTestFixtures do
  @moduledoc """
  Loader for Gemini wire-test fixtures used by
  `test/allm/providers/gemini_*_test.exs`.

  Phase 16.1 ships hand-synthesized fixtures under
  `test/fixtures/gemini/` with leading `_comment` provenance.
  `scripts/record_gemini_chat_fixtures.exs` replaces files under
  `generate_content/` when run with `GEMINI_API_KEY`. Files under
  `synthesized/` are never overwritten.

  Each fixture is loaded fresh per call (no caching) so a test that
  mutates the returned map does not contaminate later tests.

  This loader is structured to extend cleanly across Phase 16.1–16.5:

    * `generate_content/1` — non-streaming `generateContent` JSON bodies
      (16.1 + 16.3 tools + 16.4 vision + 16.5 image-out).
    * `synthesized/1` — hand-synthesized error envelopes and edge bodies.
    * `stream_chunks/1` — recorded SSE chunk fixtures (Phase 16.2).
  """

  @fixtures_root "test/fixtures/gemini"

  @typedoc "Decoded JSON map of a fixture body."
  @type body :: map()

  @doc """
  Load a recorded `generateContent` fixture by name.

  Names map to files under
  `test/fixtures/gemini/generate_content/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.GeminiTestFixtures.generate_content(:happy_text)
      iex> body["candidates"] |> hd() |> get_in(["content", "parts"]) |> hd() |> Map.get("text")
      "hello"
  """
  @spec generate_content(atom()) :: body()
  def generate_content(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "generate_content", "#{name}.json"]))
  end

  @doc """
  Load a synthesized fixture by name.

  Names map to files under
  `test/fixtures/gemini/synthesized/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.GeminiTestFixtures.synthesized(:auth_failed)
      iex> body["error"]["status"]
      "UNAUTHENTICATED"
  """
  @spec synthesized(atom()) :: body()
  def synthesized(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "synthesized", "#{name}.json"]))
  end

  @doc """
  Load a recorded `batchEmbedContents` fixture by name.

  Names map to files under
  `test/fixtures/gemini/embeddings/recorded/<name>.json`. These are genuine
  live responses and carry no `_comment` marker; the `drop_comment/1` call
  inside `load_json/1` is therefore inert for them, which is exactly why a
  provenance assertion made through this loader cannot bind —
  `embeddings_wire_test.exs` reads the raw bytes instead.

  ## Examples

      iex> body = ALLM.Providers.GeminiTestFixtures.embeddings_recorded(:batch_embed_contents)
      iex> length(body["embeddings"])
      3
  """
  @spec embeddings_recorded(atom()) :: body()
  def embeddings_recorded(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "embeddings", "recorded", "#{name}.json"]))
  end

  @doc """
  Load a synthesized embeddings fixture by name.

  Names map to files under
  `test/fixtures/gemini/embeddings/synthesized/<name>.json`. The leading
  `_comment` provenance marker is stripped before the body is returned.

  ## Examples

      iex> body = ALLM.Providers.GeminiTestFixtures.embeddings_synthesized(:error_429)
      iex> body["error"]["status"]
      "RESOURCE_EXHAUSTED"
  """
  @spec embeddings_synthesized(atom()) :: body()
  def embeddings_synthesized(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "embeddings", "synthesized", "#{name}.json"]))
  end

  @doc """
  Load a recorded or synthesized SSE stream fixture by name (Phase 16.2).

  Names resolve as follows: first under
  `test/fixtures/gemini/generate_content/<name>.sse` (recorded fixtures),
  falling back to `test/fixtures/gemini/synthesized/<name>.sse`
  (hand-crafted fixtures). The raw file is split at SSE event boundaries
  (`"\\n\\n"`).
  """
  @spec stream_chunks(atom()) :: [binary()]
  def stream_chunks(name) when is_atom(name) do
    recorded_path = Path.join([@fixtures_root, "generate_content", "#{name}.sse"])
    synthesized_path = Path.join([@fixtures_root, "synthesized", "#{name}.sse"])

    path =
      cond do
        File.exists?(recorded_path) -> recorded_path
        File.exists?(synthesized_path) -> synthesized_path
        true -> raise "no Gemini SSE fixture named #{inspect(name)} under #{@fixtures_root}"
      end

    path
    |> File.read!()
    |> split_sse_chunks()
  end

  defp split_sse_chunks(binary) do
    parts = String.split(binary, "\n\n")

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, idx} ->
      cond do
        idx == length(parts) - 1 and part == "" -> []
        idx == length(parts) - 1 -> [part]
        true -> [part <> "\n\n"]
      end
    end)
  end

  defp load_json(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> drop_comment()
  end

  # Strip the leading `_comment` provenance marker that synthesized
  # fixtures carry per CLAUDE.md "Phases shipping synthesized wire
  # fixtures" rule. Without this, the marker leaks through
  # `Response.raw` into caller-visible state. Applied at the JSON-decode
  # seam so both `generate_content/1` and `synthesized/1` benefit.
  defp drop_comment(map) when is_map(map), do: Map.delete(map, "_comment")
  defp drop_comment(other), do: other
end
