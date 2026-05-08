defmodule PackageFilesExtrasConsistencyTest do
  @moduledoc """
  Asserts the long-standing invariant: `package[:files]` is a superset
  of `docs[:extras]`.

  ExDoc renders `:extras` files into hexdocs at publish time, but the
  Hex source tarball is gated on `package[:files]` only — a file in
  `:extras` but not in `:files` ships to hexdocs but NOT to the source
  download. This test catches that drift at test time, not release
  time.

  The equivalence between the two requires a small bit of glue: a
  `package[:files]` entry can be a directory (Hex recurses), so a
  literal-string-equality comparison would fail. Resolve each `:files`
  entry to its actual file set on disk and compare the union.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../", __DIR__)

  test "every docs[:extras] file is reachable through package[:files]" do
    config = Mix.Project.config()
    extras = config[:docs][:extras] || []
    files = config[:package][:files] || []

    reachable_set = expand_files(files)

    for extra <- extras do
      assert extra in reachable_set,
             """
             #{extra} is in docs[:extras] but is NOT reachable through
             package[:files]. The published source tarball would ship
             without this file even though hexdocs would render it.

             package[:files] entries: #{inspect(files)}
             """
    end
  end

  defp expand_files(files) do
    files
    |> Enum.flat_map(&expand_entry/1)
    |> MapSet.new()
  end

  defp expand_entry(entry) do
    abs = Path.join(@repo_root, entry)

    cond do
      File.dir?(abs) ->
        abs
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, @repo_root))

      File.regular?(abs) ->
        [entry]

      true ->
        []
    end
  end
end
