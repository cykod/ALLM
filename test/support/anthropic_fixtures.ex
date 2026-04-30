defmodule ALLM.Providers.AnthropicTestFixtures do
  @moduledoc """
  Loader for Anthropic wire-test fixtures used by
  `test/allm/providers/anthropic_*_test.exs`.

  Phase 11.1 ships hand-synthesized fixtures under `test/fixtures/anthropic/`
  with leading `_comment` provenance. `scripts/record_anthropic_fixtures.exs`
  replaces files under `messages/` when run with `ANTHROPIC_API_KEY`. Files
  under `synthesized/` are never overwritten.

  Each fixture is loaded fresh per call (no caching) so a test that mutates
  the returned map does not contaminate later tests.
  """

  @fixtures_root "test/fixtures/anthropic"

  @typedoc "Decoded JSON map of a fixture body."
  @type body :: map()

  @doc """
  Load a recorded Messages-API fixture by name.

  Names map to files under `test/fixtures/anthropic/messages/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.AnthropicTestFixtures.messages_response(:happy_text)
      iex> body["content"] |> hd() |> Map.get("text")
      "hello"
  """
  @spec messages_response(atom()) :: body()
  def messages_response(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "messages", "#{name}.json"]))
  end

  @doc """
  Load a recorded Messages-API vision fixture by name.

  Names map to files under `test/fixtures/anthropic/messages/vision/<name>.json`.
  """
  @spec messages_vision(atom()) :: body()
  def messages_vision(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "messages/vision", "#{name}.json"]))
  end

  @doc """
  Load a synthesized fixture by name.

  Names map to files under `test/fixtures/anthropic/synthesized/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.AnthropicTestFixtures.synthesized(:auth_failed)
      iex> body["error"]["type"]
      "authentication_error"
  """
  @spec synthesized(atom()) :: body()
  def synthesized(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "synthesized", "#{name}.json"]))
  end

  @doc """
  Load a synthesized fixture's raw body bytes (no JSON decode).

  Used for the malformed-body fixture where decoding would defeat the test.
  """
  @spec synthesized_raw(atom()) :: binary()
  def synthesized_raw(name) when is_atom(name) do
    File.read!(Path.join([@fixtures_root, "synthesized", "#{name}.json"]))
  end

  @doc """
  Load a synthesized fixture's response-header sidecar (`<name>.headers.json`).

  Returns a map of header-name → string value. The leading `_comment` field is
  stripped before return so the map is safe to thread into `Req.Response`.
  """
  @spec synthesized_headers(atom()) :: %{optional(String.t()) => String.t()}
  def synthesized_headers(name) when is_atom(name) do
    @fixtures_root
    |> Path.join(["synthesized/", "#{name}.headers.json"])
    |> load_json()
    |> Map.delete("_comment")
  end

  @doc """
  Load a recorded or synthesized SSE stream fixture by name.

  Names resolve as follows: first under `test/fixtures/anthropic/messages/<name>.sse`
  (recorded fixtures), falling back to `test/fixtures/anthropic/synthesized/<name>.sse`
  (hand-crafted fixtures). The raw file is split at SSE event boundaries
  (`"\\n\\n"`) so each returned binary models the bytes a real network frame
  would carry; trailing separators are preserved on each chunk to keep the
  byte sequence reassembly-faithful when concatenated.

  Per Phase 11 Decision #11 + Phase 10 Decision #11, hand-crafted fixtures
  start with leading SSE-comment lines (`": ..."`) carrying provenance —
  the SSE decoder drops them per the spec, so they don't affect parsing.
  """
  @spec stream_chunks(atom()) :: [binary()]
  def stream_chunks(name) when is_atom(name) do
    messages_path = Path.join([@fixtures_root, "messages", "#{name}.sse"])
    synthesized_path = Path.join([@fixtures_root, "synthesized", "#{name}.sse"])

    path =
      cond do
        File.exists?(messages_path) -> messages_path
        File.exists?(synthesized_path) -> synthesized_path
        true -> raise "no Anthropic SSE fixture named #{inspect(name)} under #{@fixtures_root}"
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
  end
end
