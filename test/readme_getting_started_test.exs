defmodule ALLM.ReadmeGettingStartedTest do
  @moduledoc """
  Phase 12.3 retro Finding #1: parallel-source drift detection for the
  README Getting Started snippet.

  The README's `## Getting Started` section at `README.md` carries a plain
  ` ```elixir ` fenced block intended for copy-paste into `iex -S mix`.
  A parallel `iex>`-prefixed doctest lives in `lib/allm.ex`'s `@moduledoc`
  and is exercised by `doctest ALLM` in `test/allm_test.exs`. The doctest
  validates the moduledoc copy; nothing validates the README copy.

  This test parses the first `elixir` fenced block under `## Getting
  Started` out of `README.md`, evaluates it via `Code.eval_string/1`, and
  asserts the bound `text` variable equals `"Hello, ALLM!"`. Drift between
  the README and the live API surfaces here as a test failure rather than
  silent doc rot.
  """

  use ExUnit.Case, async: true

  test "README Getting Started snippet evaluates to \"Hello, ALLM!\"" do
    snippet = extract_getting_started_snippet!()
    {result, _bindings} = Code.eval_string(snippet)
    assert result == "Hello, ALLM!"
  end

  defp extract_getting_started_snippet! do
    source = File.read!(Path.expand("../README.md", __DIR__))

    [_, after_heading] = String.split(source, "## Getting Started", parts: 2)

    # The Getting Started section has two ```elixir blocks (deps + chat
    # snippet); grab the one that exercises the API by matching on
    # `ALLM.Engine.new`.
    Regex.scan(~r/```elixir\n(.*?)\n```/s, after_heading, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.find(&String.contains?(&1, "ALLM.Engine.new"))
    |> case do
      nil ->
        flunk(
          "README.md ## Getting Started section has no ```elixir block " <>
            "containing ALLM.Engine.new — snippet may have moved or renamed."
        )

      block ->
        block
    end
  end
end
