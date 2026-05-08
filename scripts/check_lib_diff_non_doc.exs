# scripts/check_lib_diff_non_doc.exs — classify lib/ diff lines as
# inside-docstring vs outside-docstring.
#
# Backs the documentation-rebuild "no behavioural change" claim with a
# mechanism rather than reviewer eyeballs. Walks `git diff <base>..HEAD --
# unified=0 -- lib/` (or `git diff <base> -- lib/` against the working
# tree when no commits have landed yet — see the `BASE_REF` notes below)
# and, for each `+`/`-` line, classifies whether the changed line sits
# inside a `@moduledoc` / `@doc` heredoc or outside.
#
# Outside-docstring change set must be empty for a documentation-only
# rebuild. The script exits 0 when that holds, 1 otherwise.
#
# Usage
# -----
#
#     # Default: diff working tree against HEAD (the rebuild's pre-state
#     # is HEAD itself when the rebuild is uncommitted).
#     mix run scripts/check_lib_diff_non_doc.exs
#
#     # Explicit base ref (env var or first positional arg):
#     BASE_REF=<sha-or-ref> mix run scripts/check_lib_diff_non_doc.exs
#     mix run scripts/check_lib_diff_non_doc.exs <sha-or-ref>
#
# Implementation
# --------------
#
# The heredoc state machine mirrors `scripts/audit_user_docs.exs` —
# tracks `:outside` vs `:inside` across each file, treats only
# `@moduledoc """` / `@doc """` as openers, and treats a lone `"""` as
# the closer. `@moduledoc false` / `@doc false` do not open. Lines that
# are themselves the opener or closer are counted as `:inside` for the
# purpose of this audit (they're docstring-shape lines, not function
# bodies).
#
# For each diff hunk header `@@ -a,b +c,d @@`, the script reads the
# corresponding file revision (HEAD-side for `-` lines, working-tree-side
# for `+` lines) via `git show` and classifies each line by re-running
# the state machine over the file's full text.

defmodule Scripts.CheckLibDiffNonDoc do
  @moduledoc false

  @type classification :: :inside | :outside | :delimiter

  @doc """
  Classifies every line in `content` (a full file as a single binary)
  by walking the heredoc state machine and returning a map of
  `line_number => classification`.

  Line numbers start at 1.
  """
  @spec classify_file(String.t()) :: %{pos_integer() => classification()}
  def classify_file(content) when is_binary(content) do
    lines = String.split(content, "\n")

    {map, _state} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, :outside}, fn {line, lineno}, {acc, state} ->
        {new_state, classification} = step(line, state)
        {Map.put(acc, lineno, classification), new_state}
      end)

    map
  end

  # State transitions mirror scripts/audit_user_docs.exs exactly so the
  # two scripts agree on what counts as a docstring line.
  defp step(line, :outside) do
    cond do
      Regex.match?(~r/^\s*@(moduledoc|doc|typedoc|shortdoc)\s+"""\s*$/, line) ->
        # The opener line itself is a docstring delimiter; classify as
        # :inside so a diff that adds/removes a `@doc """` line still
        # counts as docstring scaffolding. `@typedoc` and `@shortdoc`
        # are user-facing documentation attributes too — ExDoc renders
        # them on the type/module page.
        {:inside, :inside}

      Regex.match?(~r/^\s*@(moduledoc|doc|typedoc|shortdoc)\s+false\s*$/, line) ->
        {:outside, :outside}

      Regex.match?(~r/^\s*@(?:moduledoc|doc|typedoc|shortdoc)\s+"((?:[^"\\]|\\.)*)"\s*$/, line) ->
        # Single-line `@doc "..."` form — entirely a docstring line.
        {:outside, :inside}

      true ->
        {:outside, :outside}
    end
  end

  defp step(line, :inside) do
    if Regex.match?(~r/^\s*"""\s*$/, line) do
      {:outside, :inside}
    else
      {:inside, :inside}
    end
  end

  @doc """
  Resolves the base ref. CLI arg wins, then `BASE_REF` env var, then
  defaults to `HEAD` (working-tree diff).
  """
  @spec resolve_base_ref([String.t()]) :: String.t()
  def resolve_base_ref(argv) do
    case argv do
      [ref | _] when is_binary(ref) and ref != "" -> ref
      _ -> System.get_env("BASE_REF") || "HEAD"
    end
  end

  @doc """
  Runs `git diff <base> --unified=0 -- lib/` and returns the raw diff
  text. When the base equals `HEAD` and there are no commits beyond
  HEAD, this surfaces the working-tree diff against HEAD.
  """
  @spec git_diff(String.t()) :: String.t()
  def git_diff(base) do
    {output, _exit} =
      System.cmd("git", ["diff", "--unified=0", base, "--", "lib/"],
        stderr_to_stdout: true
      )

    output
  end

  @doc """
  Reads file content at `ref` for `path`. When `ref` is the empty
  string (sentinel for the working tree), reads the file directly.
  """
  @spec read_file_at(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file_at("", path) do
    File.read(path)
  end

  def read_file_at(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {content, 0} -> {:ok, content}
      {err, _} -> {:error, err}
    end
  end

  @doc """
  Parses unified-zero diff output into a list of changes. Each change
  is `{path, side, lineno, text}` where `side` is `:minus` or `:plus`.
  """
  @spec parse_diff(String.t()) :: [{String.t(), :minus | :plus, pos_integer(), String.t()}]
  def parse_diff(diff_text) do
    lines = String.split(diff_text, "\n")
    {changes, _state} = Enum.reduce(lines, {[], %{path: nil, minus: 0, plus: 0, side: nil}}, &parse_diff_line/2)
    Enum.reverse(changes)
  end

  defp parse_diff_line(line, {acc, state}) do
    cond do
      String.starts_with?(line, "diff --git ") ->
        {acc, %{state | path: nil, minus: 0, plus: 0, side: nil}}

      # `+++ b/lib/foo.ex` is the canonical "current file" marker.
      String.starts_with?(line, "+++ b/") ->
        path = String.replace_prefix(line, "+++ b/", "")
        {acc, %{state | path: path}}

      # `+++ /dev/null` for deletions — keep the path from the `--- a/...` header instead.
      String.starts_with?(line, "+++ /dev/null") ->
        {acc, state}

      String.starts_with?(line, "--- a/") and is_nil(state.path) ->
        path = String.replace_prefix(line, "--- a/", "")
        {acc, %{state | path: path}}

      String.starts_with?(line, "@@") ->
        case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
          [_, minus, plus] ->
            {acc, %{state | minus: String.to_integer(minus), plus: String.to_integer(plus)}}

          _ ->
            {acc, state}
        end

      String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
        {acc, state}

      String.starts_with?(line, "+") and state.path != nil ->
        change = {state.path, :plus, state.plus, String.slice(line, 1..-1//1) || ""}
        {[change | acc], %{state | plus: state.plus + 1}}

      String.starts_with?(line, "-") and state.path != nil ->
        change = {state.path, :minus, state.minus, String.slice(line, 1..-1//1) || ""}
        {[change | acc], %{state | minus: state.minus + 1}}

      true ->
        {acc, state}
    end
  end

  @doc """
  Runs the audit and returns `{inside_changes, outside_changes}`.
  """
  @spec run(String.t()) :: {[map()], [map()]}
  def run(base_ref) do
    diff = git_diff(base_ref)
    changes = parse_diff(diff)

    # Cache classifications per-(ref, path) — minus side reads from
    # `base_ref`, plus side reads from working tree (sentinel "").
    cache = %{}

    {inside, outside, _cache} =
      Enum.reduce(changes, {[], [], cache}, fn {path, side, lineno, text}, {ins, outs, cache} ->
        ref = if side == :minus, do: base_ref, else: ""
        key = {ref, path}

        {classifications, cache} =
          case Map.fetch(cache, key) do
            {:ok, c} ->
              {c, cache}

            :error ->
              classifications =
                case read_file_at(ref, path) do
                  {:ok, content} -> classify_file(content)
                  {:error, _} -> %{}
                end

              {classifications, Map.put(cache, key, classifications)}
          end

        classification = Map.get(classifications, lineno, :outside)
        record = %{path: path, side: side, line: lineno, text: text, class: classification}

        case classification do
          :inside -> {[record | ins], outs, cache}
          _ -> {ins, [record | outs], cache}
        end
      end)

    {Enum.reverse(inside), Enum.reverse(outside)}
  end

  @doc """
  Renders the report and returns the exit code.
  """
  @spec report({[map()], [map()]}, IO.device()) :: 0 | 1
  def report({inside, outside}, device \\ :stdio) do
    IO.puts(device, "ALLM lib/ diff classification")
    IO.puts(device, "=============================")
    IO.puts(device, "")
    IO.puts(device, "Inside-docstring changes:  #{length(inside)}")
    IO.puts(device, "Outside-docstring changes: #{length(outside)}")
    IO.puts(device, "")

    if outside == [] do
      IO.puts(device, "No outside-docstring changes. The lib/ diff is documentation-only.")
      0
    else
      IO.puts(device, "Outside-docstring changes (these break the doc-only invariant):")
      IO.puts(device, "----------------------------------------------------------------")

      Enum.each(outside, fn r ->
        sigil = if r.side == :plus, do: "+", else: "-"
        IO.puts(device, "  #{r.path}:#{r.line} #{sigil} #{String.slice(r.text, 0, 200)}")
      end)

      1
    end
  end
end

if Mix.env() != :test do
  base_ref = Scripts.CheckLibDiffNonDoc.resolve_base_ref(System.argv())
  IO.puts(:stderr, "Comparing against base ref: #{base_ref}")

  result = Scripts.CheckLibDiffNonDoc.run(base_ref)
  exit_code = Scripts.CheckLibDiffNonDoc.report(result, :stdio)
  System.halt(exit_code)
end
