defmodule ALLM.GroupsForModulesAuditTest do
  @moduledoc """
  Phase 12.3 audit gate: every public module under `lib/` must appear in
  exactly one `mix.exs` `groups_for_modules:` entry, and every grouped
  module must exist as a public module under `lib/`.

  When this test fires, either:

    * a `lib/` module was added without grouping it in `mix.exs` (add it
      to a group, or mark it `@moduledoc false` if it's an internal-only
      module), or
    * a group references a removed/renamed module (delete the stale entry).

  Public-module discovery walks `lib/` for `.ex` files, parses out every
  `defmodule X do` header via regex, and excludes the file's modules if the
  source contains `@moduledoc false` anywhere.

  ## Known limitations (substring/regex heuristic, not AST traversal)

  This audit favors a 60-LOC heuristic over `Code.string_to_quoted!/2` +
  AST walk. The heuristic is sufficient for the current 43-module flat
  `lib/` tree, but has three latent failure modes that would silently
  miss public modules (no test failure, no warning):

    * **Multi-module files.** If one `.ex` file declares two `defmodule`s
      where one carries `@moduledoc false` and the other is public, the
      whole-file substring check excludes BOTH — the public module
      silently disappears from the audit's view.
    * **Macro-generated modules.** `defmodule` produced by `quote` /
      `unquote` macro expansion is not in the literal source, so the
      regex won't see it; the module is invisible to the audit.
    * **Single-line `defmodule X, do: ...` form.** The regex requires the
      `do` block style (`defmodule X do`); a single-line `do:` form is
      not matched.

  When any of these patterns appears in `lib/`, switch the discovery to
  AST-based traversal: `Code.string_to_quoted!(source)` then walk the
  quoted form for `{:defmodule, _, [{:__aliases__, _, parts}, ...]}`
  nodes, scoping the `@moduledoc false` check to each module's own
  attribute list rather than the whole file.
  """

  use ExUnit.Case, async: true

  @moduletag :audit

  test "every public lib/ module is grouped in mix.exs docs.groups_for_modules" do
    grouped = grouped_modules()
    public = public_lib_modules()

    missing_from_groups = MapSet.difference(public, grouped)
    extra_in_groups = MapSet.difference(grouped, public)

    assert MapSet.size(missing_from_groups) == 0,
           "Public lib/ modules missing from groups_for_modules: " <>
             inspect(MapSet.to_list(missing_from_groups))

    assert MapSet.size(extra_in_groups) == 0,
           "groups_for_modules entries that are not public lib/ modules: " <>
             inspect(MapSet.to_list(extra_in_groups))
  end

  defp grouped_modules do
    Mix.Project.config()[:docs][:groups_for_modules]
    |> Enum.flat_map(fn {_group, mods} -> mods end)
    |> MapSet.new()
  end

  defp public_lib_modules do
    Path.wildcard("lib/**/*.ex")
    |> Enum.flat_map(&parse_public_modules/1)
    |> MapSet.new()
  end

  defp parse_public_modules(path) do
    source = File.read!(path)

    if String.contains?(source, "@moduledoc false") do
      []
    else
      Regex.scan(~r/^defmodule\s+([A-Z][\w\.]*)\s+do/m, source, capture: :all_but_first)
      |> Enum.map(fn [name] -> Module.concat([name]) end)
    end
  end
end
