defmodule ALLM.Providers.OpenAITestFixtures do
  @moduledoc """
  Loader for OpenAI wire-test fixtures used by `test/allm/providers/openai_*_test.exs`.

  Phase 10.2 ships hand-synthesized fixtures under `test/fixtures/openai/`
  (per Phase 10 design Decision #11). The recorder script lands in Phase
  10.5; until then `chat_completion/1` returns the synthesized seed bodies
  and `synthesized/1` returns the hand-crafted error bodies.

  Each fixture is loaded fresh per call (no caching) so a test that mutates
  the returned map does not contaminate later tests.
  """

  @fixtures_root "test/fixtures/openai"

  @typedoc "Decoded JSON map of a fixture body."
  @type body :: map()

  @doc """
  Load a Chat Completions fixture by name.

  Names map to files under `test/fixtures/openai/chat_completions/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.chat_completion(:happy_text)
      iex> body["choices"] |> hd() |> get_in(["message", "content"])
      "hello"
  """
  @spec chat_completion(atom()) :: body()
  def chat_completion(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "chat_completions", "#{name}.json"]))
  end

  @doc """
  Load a Chat Completions vision fixture by name (Phase 17.1).

  Names map to files under `test/fixtures/openai/chat_completions/vision/<name>.json`.
  """
  @spec chat_vision(atom()) :: body()
  def chat_vision(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "chat_completions/vision", "#{name}.json"]))
  end

  @doc """
  Load a Responses-API vision fixture by name (Phase 17.1).

  Names map to files under `test/fixtures/openai/responses/vision/<name>.json`.
  """
  @spec responses_vision(atom()) :: body()
  def responses_vision(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "responses/vision", "#{name}.json"]))
  end

  @doc """
  Load a synthesized fixture by name.

  Names map to files under `test/fixtures/openai/synthesized/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.synthesized(:auth_failed)
      iex> body["error"]["code"]
      "invalid_api_key"
  """
  @spec synthesized(atom()) :: body()
  def synthesized(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "synthesized", "#{name}.json"]))
  end

  @doc """
  Load a Responses-API fixture by name (Phase 10.6).

  Names map to files under `test/fixtures/openai/responses/<name>.json`.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.responses(:happy_text)
      iex> body["status"]
      "completed"
  """
  @spec responses(atom()) :: body()
  def responses(name) when is_atom(name) do
    load_json(Path.join([@fixtures_root, "responses", "#{name}.json"]))
  end

  @doc """
  Load a Responses-API SSE stream fixture by name (Phase 10.6).

  Names map to files under `test/fixtures/openai/responses/<name>.sse`.
  See `stream_chunks/1` for chunk-splitting semantics.
  """
  @spec responses_stream_chunks(atom()) :: [binary()]
  def responses_stream_chunks(name) when is_atom(name) do
    path = Path.join([@fixtures_root, "responses", "#{name}.sse"])

    path
    |> File.read!()
    |> split_sse_chunks()
  end

  @doc """
  Load a recorded embeddings fixture by name.

  Names map to files under `test/fixtures/openai/embeddings/recorded/<name>.json`.
  These are genuine live OpenAI responses and therefore carry NO `_comment`
  marker; the `drop_comment/1` call is defensive, so the loader keeps working
  if a fixture is ever temporarily replaced by a placeholder awaiting a
  re-record. Because it strips unconditionally, an assertion made through this
  loader cannot bind provenance — `embeddings_wire_test.exs` reads the raw
  file bytes for that.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.embeddings_recorded(:single_input)
      iex> length(body["data"])
      1
  """
  @spec embeddings_recorded(atom()) :: body()
  def embeddings_recorded(name) when is_atom(name) do
    @fixtures_root
    |> Path.join(["embeddings/recorded/", "#{name}.json"])
    |> load_json()
    |> drop_comment()
  end

  @doc """
  Load a synthesized embeddings fixture by name.

  Names map to files under
  `test/fixtures/openai/embeddings/synthesized/<name>.json`. The leading
  `_comment` marker every synthesized fixture carries is stripped.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.embeddings_synthesized(:error_401)
      iex> body["error"]["code"]
      "invalid_api_key"
  """
  @spec embeddings_synthesized(atom()) :: body()
  def embeddings_synthesized(name) when is_atom(name) do
    @fixtures_root
    |> Path.join(["embeddings/synthesized/", "#{name}.json"])
    |> load_json()
    |> drop_comment()
  end

  @doc """
  Load a recorded moderations fixture by name (Phase 22.4).

  Names map to files under `test/fixtures/openai/moderations/recorded/<name>.json`.
  These are genuine live OpenAI `/v1/moderations` responses recorded on
  2026-08-31 and therefore carry NO `_comment` marker; the `drop_comment/1` call
  is defensive, so the loader keeps working if a fixture is ever temporarily
  replaced by a placeholder awaiting a re-record. Because it strips
  unconditionally, an assertion made through this loader cannot bind provenance —
  `moderation_wire_test.exs` reads the raw file bytes for that.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.moderation_recorded(:single_clean)
      iex> length(body["results"])
      1
  """
  @spec moderation_recorded(atom()) :: body()
  def moderation_recorded(name) when is_atom(name) do
    @fixtures_root
    |> Path.join(["moderations/recorded/", "#{name}.json"])
    |> load_json()
    |> drop_comment()
  end

  @doc """
  Load a synthesized moderations fixture by name (Phase 22.4).

  Names map to files under
  `test/fixtures/openai/moderations/synthesized/<name>.json`. The leading
  `_comment` marker every synthesized fixture carries is stripped.

  ## Examples

      iex> body = ALLM.Providers.OpenAITestFixtures.moderation_synthesized(:error_401)
      iex> body["error"]["code"]
      "invalid_api_key"
  """
  @spec moderation_synthesized(atom()) :: body()
  def moderation_synthesized(name) when is_atom(name) do
    @fixtures_root
    |> Path.join(["moderations/synthesized/", "#{name}.json"])
    |> load_json()
    |> drop_comment()
  end

  @doc """
  Strip the leading `_comment` provenance marker from a decoded fixture map.

  Every synthesized fixture carries one; recorded fixtures do not (which is
  also what the recorder scripts key their refuse-to-overwrite check on, and
  what the per-file raw-read provenance tests in
  `test/allm/providers/openai/embeddings_wire_test.exs` enforce).

  This is the single implementation for the OpenAI test-support family —
  `ALLM.Providers.OpenAI.ImagesTestHelpers.drop_comment/1` delegates here.

  ## Examples

      iex> ALLM.Providers.OpenAITestFixtures.drop_comment(%{"_comment" => "x", "a" => 1})
      %{"a" => 1}
  """
  @spec drop_comment(map()) :: map()
  def drop_comment(map) when is_map(map), do: Map.delete(map, "_comment")

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
    |> drop_comment()
  end

  @doc """
  Load a synthesized SSE stream fixture by name and return its chunks.

  Names map to files under `test/fixtures/openai/synthesized/<name>.sse`. The
  raw file is split at SSE event boundaries (`"\\n\\n"`) so each returned
  binary models the bytes a real network frame would carry; trailing
  separators are preserved on each chunk to keep the byte sequence
  reassembly-faithful when concatenated.

  Leading SSE-comment lines (`": ..."`) are kept verbatim — the SSE decoder
  drops them per the spec and tests can use them to verify provenance.
  """
  @spec stream_chunks(atom()) :: [binary()]
  def stream_chunks(name) when is_atom(name) do
    path = Path.join([@fixtures_root, "synthesized", "#{name}.sse"])

    path
    |> File.read!()
    |> split_sse_chunks()
  end

  # Split on event boundaries (`\n\n`) but re-attach the separator so the
  # concatenated chunks are byte-identical to the original file. An empty
  # trailing element (file ends in `\n\n`) is dropped.
  defp split_sse_chunks(binary) do
    parts = String.split(binary, "\n\n")

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, idx} ->
      cond do
        # last element, empty: drop
        idx == length(parts) - 1 and part == "" -> []
        # last element, non-empty: keep as-is (file didn't end with \n\n)
        idx == length(parts) - 1 -> [part]
        # any other element: re-attach the boundary
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
