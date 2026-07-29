defmodule ALLM.Providers.VoyageTestFixtures do
  @moduledoc """
  Loader for Voyage AI wire-test fixtures used by
  `test/allm/providers/voyage/embeddings_*_test.exs`.

  Mirrors `ALLM.Providers.OpenAITestFixtures`' embeddings half. Each fixture is
  loaded fresh per call (no caching) so a test that mutates the returned map
  does not contaminate later tests.

  The leading `_comment` provenance marker that synthesized fixtures carry is
  stripped on the way out via `ALLM.Providers.OpenAITestFixtures.drop_comment/1`
  — the single implementation in this repo, delegated to rather than copied
  (it reached three copies once already and was consolidated there).

  Because the marker is stripped unconditionally, **an assertion made through
  this loader cannot bind provenance**: a hand-written placeholder sitting in
  `recorded/` reads identically to a live recording. `embeddings_wire_test.exs`
  reads the raw file bytes for that.
  """

  alias ALLM.Providers.OpenAITestFixtures

  @fixtures_root "test/fixtures/voyage"

  @typedoc "Decoded JSON map of a fixture body."
  @type body :: map()

  @doc """
  Load a recorded embeddings fixture by name.

  Names map to files under
  `test/fixtures/voyage/embeddings/recorded/<name>.json`. These are genuine live
  Voyage responses and carry no `_comment` marker, which is what
  `scripts/record_voyage_embeddings_fixtures.exs` keys its refuse-to-overwrite
  check on.

  ## Examples

      iex> body = ALLM.Providers.VoyageTestFixtures.embeddings_recorded(:batch_input)
      iex> length(body["data"])
      3
  """
  @spec embeddings_recorded(atom()) :: body()
  def embeddings_recorded(name) when is_atom(name) do
    load(["embeddings", "recorded", "#{name}.json"])
  end

  @doc """
  Load a synthesized embeddings fixture by name.

  Names map to files under
  `test/fixtures/voyage/embeddings/synthesized/<name>.json`. The leading
  `_comment` marker every synthesized fixture carries is stripped.

  ## Examples

      iex> body = ALLM.Providers.VoyageTestFixtures.embeddings_synthesized(:error_429)
      iex> Map.keys(body)
      ["detail"]
  """
  @spec embeddings_synthesized(atom()) :: body()
  def embeddings_synthesized(name) when is_atom(name) do
    load(["embeddings", "synthesized", "#{name}.json"])
  end

  defp load(segments) do
    [@fixtures_root | segments]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> OpenAITestFixtures.drop_comment()
  end
end
