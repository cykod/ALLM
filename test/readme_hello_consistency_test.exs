defmodule ALLM.ReadmeHelloConsistencyTest do
  @moduledoc """
  Single-source-of-truth check: the README's `## Hello, ALLM` snippet
  is byte-identical (modulo `iex>` / `...>` doctest prefixes) to the
  Hello block in `lib/allm.ex`'s `@moduledoc`.

  `lib/allm.ex` is the canonical source — it carries the runnable
  `iex>` doctest that `doctest ALLM` exercises under `mix test`. The
  README has the same code as a plain ` ```elixir ` fenced block so a
  reader can copy-paste it into `iex -S mix`. This test guarantees the
  two stay in lock-step: stripping `iex> ` / `...> ` prefixes from
  `lib/allm.ex`'s Hello block produces the README's Hello block.
  """

  use ExUnit.Case, async: true

  @readme_path Path.expand("../README.md", __DIR__)
  @lib_path Path.expand("../lib/allm.ex", __DIR__)

  test "README Hello block is byte-identical to lib/allm.ex moduledoc Hello block (modulo iex> prefixes)" do
    readme_block = extract_readme_hello_block!()
    lib_block = extract_lib_hello_block!()

    stripped =
      lib_block
      |> String.split("\n")
      |> Enum.map(&strip_iex_prefix/1)
      |> Enum.reject(&(&1 == :result_line))
      |> Enum.join("\n")
      |> String.trim_trailing("\n")

    assert stripped == String.trim_trailing(readme_block, "\n"),
           """
           README Hello block and lib/allm.ex Hello doctest have drifted.

           README block:
           #{inspect(String.trim_trailing(readme_block, "\n"))}

           lib/allm.ex (prefixes stripped):
           #{inspect(stripped)}
           """
  end

  defp extract_readme_hello_block! do
    source = File.read!(@readme_path)
    [_, after_heading] = String.split(source, "## Hello, ALLM", parts: 2)

    Regex.scan(~r/```elixir\n(.*?)\n```/s, after_heading, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.find(&String.contains?(&1, "ALLM.Engine.new"))
    |> case do
      nil ->
        flunk("README.md ## Hello, ALLM section has no ```elixir block with ALLM.Engine.new")

      block ->
        # Drop the trailing `# => "..."` comment line — it's a docs
        # convenience in the README copy and does not appear in the
        # lib/allm.ex doctest body (the doctest uses an iex> result
        # assertion line, which we strip on the lib side).
        block
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "# =>"))
        |> Enum.join("\n")
        |> String.trim_trailing("\n")
    end
  end

  defp extract_lib_hello_block! do
    # Walk the file line-by-line. After we see `## Hello, ALLM`, gather
    # the contiguous run of doctest lines (those starting — after any
    # leading whitespace — with `iex>`, `...>`, or the expected-output
    # literal `"Hello, ALLM!"`). Stop on the first non-matching line
    # AFTER we've started collecting.
    {block, _state} =
      @lib_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({[], :before}, &lib_hello_step/2)

    case block do
      [] -> flunk("lib/allm.ex moduledoc has no ## Hello, ALLM iex> doctest block")
      lines -> Enum.join(lines, "\n")
    end
  end

  defp lib_hello_step(line, {acc, :before}) do
    if String.contains?(line, "## Hello, ALLM"), do: {acc, :seeking}, else: {acc, :before}
  end

  defp lib_hello_step(line, {acc, :seeking}) do
    trimmed = String.trim_leading(line)

    if doctest_line?(trimmed),
      do: {acc ++ [trimmed], :collecting},
      else: {acc, :seeking}
  end

  defp lib_hello_step(line, {acc, :collecting}) do
    trimmed = String.trim_leading(line)

    if doctest_line?(trimmed),
      do: {acc ++ [trimmed], :collecting},
      else: {acc, :done}
  end

  defp lib_hello_step(_line, {acc, :done}), do: {acc, :done}

  defp doctest_line?("iex>" <> _), do: true
  defp doctest_line?("...>" <> _), do: true
  defp doctest_line?("\"Hello, ALLM!\"" <> _), do: true
  defp doctest_line?(_), do: false

  defp strip_iex_prefix("iex> " <> rest), do: rest
  defp strip_iex_prefix("...> " <> rest), do: rest
  defp strip_iex_prefix("...>" <> rest), do: rest

  # The trailing `"Hello, ALLM!"` line is the doctest's expected-output
  # assertion, NOT executable code. Drop it from the comparison — the
  # README's equivalent is the dropped `# => "..."` comment on the
  # README side (also dropped above).
  defp strip_iex_prefix("\"Hello, ALLM!\"" <> _), do: :result_line

  defp strip_iex_prefix(other), do: other
end
