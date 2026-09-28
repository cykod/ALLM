defmodule ALLM.Providers.TypeSafeTestFixtures do
  @moduledoc """
  Loader for TypeSafe classification wire-test fixtures used by
  `test/allm/providers/typesafe/*_test.exs`.

  Every fixture is a JSON envelope, `{"status", "headers", "body"}` (recorded
  ones also carry `"header_names"`), except the question-ladder summary
  `recorded/probe_question_ladder.json`. Recorded files are written by
  `scripts/record_typesafe_classification_fixtures.exs`; synthesized files
  are hand-written and carry a leading `_comment` marker.

  The marker is stripped on the way out via
  `ALLM.Providers.OpenAITestFixtures.drop_comment/1`, so **an assertion made
  through `recorded/1` or `synthesized/1` cannot bind provenance**. Use
  `raw/2`, which reads the file bytes and strips nothing.
  """

  alias ALLM.Providers.OpenAITestFixtures

  @fixtures_root "test/fixtures/typesafe/classification"

  @doc """
  Load a recorded envelope by name.

  ## Examples

      iex> env = ALLM.Providers.TypeSafeTestFixtures.recorded(:mixed_questions)
      iex> env["status"]
      200
  """
  @spec recorded(atom()) :: map()
  def recorded(name) when is_atom(name), do: load("recorded", name)

  @doc """
  Load a synthesized envelope by name, `_comment` stripped.

  ## Examples

      iex> env = ALLM.Providers.TypeSafeTestFixtures.synthesized(:error_529)
      iex> env["status"]
      529
  """
  @spec synthesized(atom()) :: map()
  def synthesized(name) when is_atom(name), do: load("synthesized", name)

  @doc "The decoded file under `<dir>/<name>.json`, with nothing stripped."
  @spec raw(String.t(), String.t()) :: map()
  def raw(dir, name) do
    [@fixtures_root, dir, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  @doc "The base names of every `.json` file under `<dir>`, sorted."
  @spec names_on_disk(String.t()) :: [String.t()]
  def names_on_disk(dir) do
    [@fixtures_root, dir, "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  @doc """
  A `Req.Test` plug body that replays an envelope: its status, its recorded
  headers and its JSON body.
  """
  @spec replay(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replay(conn, env) do
    env
    |> Map.get("headers", %{})
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(env["status"], Jason.encode!(env["body"]))
  end

  defp load(dir, name) do
    [@fixtures_root, dir, "#{name}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> OpenAITestFixtures.drop_comment()
  end
end
