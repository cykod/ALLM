# scripts/audit_user_docs.exs — banned-token audit for user-facing docs
#
# Walks the user-facing documentation surface (`lib/**/*.ex` docstrings,
# top-level `README.md`, `CHANGELOG.md`, `examples/README.md`, `guides/`,
# `mix.exs`) and reports every line matching the closed banned-token regex
# set — internal phase markers, spec-section pointers, internal design
# filenames, retro callouts. The script's exit code is 0 when zero hits,
# 1 otherwise; wire it into `/review` gates.
#
# Usage
# -----
#
#     mix run scripts/audit_user_docs.exs               # full surface
#     mix run scripts/audit_user_docs.exs lib/allm.ex   # just one file
#     mix run scripts/audit_user_docs.exs > tmp/docs_audit_baseline.txt
#
# What's banned
# -------------
#
#   - `Phase N` / `Phase N.M` (case-insensitive)
#   - `§N` / `§N.M` (spec-section markers)
#   - `spec §N`
#   - `allm_engine_session_streaming_spec` (the spec filename stem)
#   - `steering/` (path prefix)
#   - `PHASE_N(_DESIGN)?(_…)?.md` (internal design filenames)
#   - `Decision #N` / `Decision N` / `decision #N` (case-insensitive)
#   - `Non-obvious Decision`
#   - `retro F\d+`
#   - `retro/<file>.md`
#   - `RELEASE_PLAN` / `PROJECT_PHASING`
#
# Exclusions
# ----------
#
# `test/`, `steering/`, `retro/`, `reviews/`, `doc/`, `_build/`, `deps/`,
# `HISTORY.md`. Test code, internal design history, generated docs, and
# the per-commit rolling history are all out of scope by design — the
# audit targets what ships to Hex consumers via `package[:files]`.
#
# `.ex` heredoc targeting
# -----------------------
#
# Inside `lib/**/*.ex`, only `@moduledoc` and `@doc` heredoc bodies are
# scanned. A `# Phase 18.4 …` code comment inside a `def`/`defp` body
# is private implementation detail and stays. The line-based state
# machine tracks whether the current line sits inside a `"""`-delimited
# heredoc opened by `@moduledoc` / `@doc`. `@doc false` and
# `@moduledoc false` do NOT open a heredoc.

defmodule Scripts.AuditUserDocs do
  @moduledoc false

  # Each pattern is a `{label, regex}` pair; the label flows into the
  # per-hit record so reviewers can see which rule fired without
  # re-reading the line.
  @patterns [
    {"phase_n", ~r/\bphase\s+\d+(\.\d+)?\b/i},
    {"section_marker", ~r/§\d+(\.\d+)?/},
    {"spec_section", ~r/\bspec\s+§\d/i},
    {"spec_filename", ~r/allm_engine_session_streaming_spec/},
    {"steering_path", ~r/\bsteering\//},
    {"phase_design_md", ~r/PHASE_\d+(_DESIGN)?(_[A-Za-z0-9_]+)?\.md/},
    {"decision_n", ~r/\bdecision\s*#?\s*\d+/i},
    {"non_obvious_decision", ~r/Non-obvious\s+Decision/i},
    {"retro_finding", ~r/\bretro\s+F\d+/i},
    {"retro_path", ~r{\bretro/[a-z0-9_\-/]+\.md}i},
    {"release_or_phasing_doc", ~r/\b(RELEASE_PLAN|PROJECT_PHASING)\b/}
  ]

  @excluded_dir_prefixes [
    "test/",
    "steering/",
    "retro/",
    "reviews/",
    "doc/",
    "_build/",
    "deps/",
    "tmp/",
    "cover/",
    ".elixir_ls/",
    ".git/",
    "conformance/"
  ]

  @excluded_files ["HISTORY.md"]

  # Top-level files explicitly in scope (when present).
  @top_level_md ["README.md", "CHANGELOG.md", "mix.exs"]

  @doc """
  Returns the list of `{label, pattern}` tuples the auditor enforces.

  Exposed so the test suite can iterate every pattern with a positive
  fixture.
  """
  def patterns, do: @patterns

  @doc """
  Scans a single line of text and returns the list of pattern labels
  that match.

  Returns an empty list when the line is clean.
  """
  @spec scan_line(String.t()) :: [String.t()]
  def scan_line(line) when is_binary(line) do
    for {label, regex} <- @patterns, Regex.match?(regex, line), do: label
  end

  @doc """
  Walks the configured surface set rooted at `repo_root` and returns
  the absolute paths of every file that should be audited.
  """
  @spec surface_paths(Path.t()) :: [Path.t()]
  def surface_paths(repo_root) do
    repo_root = Path.expand(repo_root)

    lib_files = list_files(Path.join(repo_root, "lib"), [".ex"])
    guides_files = list_files(Path.join(repo_root, "guides"), [".md"])
    examples_readme = Path.join([repo_root, "examples", "README.md"])

    candidates =
      lib_files ++
        guides_files ++
        Enum.map(@top_level_md, &Path.join(repo_root, &1)) ++
        [examples_readme]

    candidates
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded?(&1, repo_root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_files(dir, extensions) do
    case File.ls(dir) do
      {:ok, _} ->
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(fn p -> File.regular?(p) and Path.extname(p) in extensions end)

      {:error, _} ->
        []
    end
  end

  defp excluded?(absolute_path, repo_root) do
    relative = Path.relative_to(absolute_path, repo_root)

    Enum.any?(@excluded_dir_prefixes, &String.starts_with?(relative, &1)) or
      relative in @excluded_files
  end

  @doc """
  Scans a single file and returns the list of hit records.

  Each hit is a map with `:path`, `:line`, `:pattern`, and `:text`. For
  `.ex` files only `@moduledoc` / `@doc` heredoc bodies are scanned; for
  every other file the whole content is scanned line-by-line.
  """
  @spec scan_file(Path.t()) :: [map()]
  def scan_file(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        case Path.extname(path) do
          ".ex" -> scan_ex_lines(path, lines)
          _ -> scan_md_lines(path, lines)
        end

      {:error, _} ->
        []
    end
  end

  # Heredoc-aware scan. `state` is `:outside` or `:inside` (in a `@doc` /
  # `@moduledoc` heredoc body). Lines containing the opening `"""` and
  # the closing `"""` are NOT scanned themselves — they are pure
  # delimiters. The line-based heuristic here is intentionally not a
  # full Elixir parser; the surface it audits (curated docstrings) does
  # not exercise the corner cases (nested heredocs in metaprogramming,
  # `~S"""` sigils used as docs).
  defp scan_ex_lines(path, lines) do
    {hits, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], :outside}, fn {line, lineno}, {acc, state} ->
        {new_state, line_hits} = step_ex(line, lineno, state, path)
        {acc ++ line_hits, new_state}
      end)

    hits
  end

  defp step_ex(line, lineno, :outside, path) do
    cond do
      # Opening of a docstring heredoc: `@moduledoc """` or `@doc """`
      # (with optional whitespace and an optional trailing-only comment
      # on the same line — defensive). The opening line itself is the
      # delimiter; we don't scan it.
      Regex.match?(~r/^\s*@(moduledoc|doc)\s+"""\s*$/, line) ->
        {:inside, []}

      # @doc false / @moduledoc false — does NOT open a heredoc.
      Regex.match?(~r/^\s*@(moduledoc|doc)\s+false\s*$/, line) ->
        {:outside, []}

      # Single-line `@doc "..."` form: the value is on the same line.
      # Treat the trailing portion as a docstring body for matching.
      single = single_line_docstring(line) ->
        {:outside, hits_for(path, lineno, single)}

      true ->
        {:outside, []}
    end
  end

  defp step_ex(line, lineno, :inside, path) do
    if Regex.match?(~r/^\s*"""\s*$/, line) do
      {:outside, []}
    else
      {:inside, hits_for(path, lineno, line)}
    end
  end

  # Best-effort extraction of the contents of a single-line `@doc "..."`
  # form. Returns the inner string when the line matches, else `nil`.
  defp single_line_docstring(line) do
    case Regex.run(~r/^\s*@(?:moduledoc|doc)\s+"((?:[^"\\]|\\.)*)"\s*$/, line) do
      [_, body] -> body
      _ -> nil
    end
  end

  defp scan_md_lines(path, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} -> hits_for(path, lineno, line) end)
  end

  defp hits_for(path, lineno, text) do
    case scan_line(text) do
      [] ->
        []

      labels ->
        Enum.map(labels, fn label ->
          %{path: path, line: lineno, pattern: label, text: String.trim_trailing(text)}
        end)
    end
  end

  @doc """
  Runs the audit over the supplied paths (or the full surface when
  `paths` is empty) and returns `{:ok, hits, summary}` where `summary`
  carries totals.
  """
  @spec run_audit([Path.t()]) :: {:ok, [map()], map()}
  def run_audit(paths) when is_list(paths) do
    files =
      case paths do
        [] -> surface_paths(File.cwd!())
        _ -> paths
      end

    hits = Enum.flat_map(files, &scan_file/1)

    summary = %{
      total_hits: length(hits),
      files_scanned: length(files),
      files_with_hits: hits |> Enum.map(& &1.path) |> Enum.uniq() |> length()
    }

    {:ok, hits, summary}
  end

  @doc """
  Maps a hit list to a process exit code: 0 if empty, 1 otherwise.
  """
  @spec exit_code_for([map()]) :: 0 | 1
  def exit_code_for([]), do: 0
  def exit_code_for([_ | _]), do: 1

  @doc """
  Renders a human-readable report to `device` from a hit list and
  summary. Two sections: per-file hit counts, then a flat
  `path:line:pattern:text` listing.
  """
  @spec render_report([map()], map(), IO.device()) :: :ok
  def render_report(hits, summary, device \\ :stdio) do
    IO.puts(device, "ALLM user-facing docs audit")
    IO.puts(device, "===========================")
    IO.puts(device, "")

    IO.puts(device, "Files scanned:    #{summary.files_scanned}")
    IO.puts(device, "Files with hits:  #{summary.files_with_hits}")
    IO.puts(device, "Total hits:       #{summary.total_hits}")
    IO.puts(device, "")

    if hits == [] do
      IO.puts(device, "No banned-token matches. The surface is clean.")
    else
      IO.puts(device, "Per-file summary")
      IO.puts(device, "----------------")

      hits
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.each(fn {path, file_hits} ->
        IO.puts(device, "  #{path}: #{length(file_hits)}")
      end)

      IO.puts(device, "")
      IO.puts(device, "Hits")
      IO.puts(device, "----")

      Enum.each(hits, fn hit ->
        IO.puts(device, "#{hit.path}:#{hit.line}:#{hit.pattern}:#{hit.text}")
      end)
    end

    :ok
  end
end

# CLI entry — only fires when this file is executed under `mix run`.
# When the test suite `Code.require_file/1`s this script, `System.argv/0`
# still reflects the test-runner invocation, but `Mix.env() == :test` and
# we skip the side effects.
if Mix.env() != :test do
  {:ok, hits, summary} = Scripts.AuditUserDocs.run_audit(System.argv())
  Scripts.AuditUserDocs.render_report(hits, summary, :stdio)
  System.halt(Scripts.AuditUserDocs.exit_code_for(hits))
end
