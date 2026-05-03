defmodule ALLM.ReadmeGettingStartedTest do
  @moduledoc """
  Phase 12.3 retro Finding #1: parallel-source drift detection for the
  README Hello, ALLM snippet.

  The README's `## Hello, ALLM` section at `README.md` carries a plain
  ` ```elixir ` fenced block intended for copy-paste into `iex -S mix`.
  A parallel `iex>`-prefixed doctest lives in `lib/allm.ex`'s `@moduledoc`
  and is exercised by `doctest ALLM` in `test/allm_test.exs`. The doctest
  validates the moduledoc copy; nothing validates the README copy.

  This test parses the first `elixir` fenced block under `## Hello, ALLM`
  out of `README.md`, evaluates it via `Code.eval_string/1`, and asserts
  the bound `text` variable equals `"Hello, ALLM!"`. Drift between the
  README and the live API surfaces here as a test failure rather than
  silent doc rot.
  """

  use ExUnit.Case, async: true

  test "README Hello, ALLM snippet evaluates to \"Hello, ALLM!\"" do
    snippet = extract_hello_allm_snippet!()
    {result, _bindings} = Code.eval_string(snippet)
    assert result == "Hello, ALLM!"
  end

  defp extract_hello_allm_snippet! do
    source = File.read!(Path.expand("../README.md", __DIR__))

    [_, after_heading] = String.split(source, "## Hello, ALLM", parts: 2)

    # Grab the first ```elixir block under the heading that exercises the
    # API (matches on `ALLM.Engine.new`).
    Regex.scan(~r/```elixir\n(.*?)\n```/s, after_heading, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.find(&String.contains?(&1, "ALLM.Engine.new"))
    |> case do
      nil ->
        flunk(
          "README.md ## Hello, ALLM section has no ```elixir block " <>
            "containing ALLM.Engine.new — snippet may have moved or renamed."
        )

      block ->
        block
    end
  end
end
