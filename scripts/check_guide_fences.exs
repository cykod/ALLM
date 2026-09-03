# Compiles every ```elixir fence in every registered guide.
#
# WHY THIS EXISTS
# ---------------
# `test/guides_doctest_test.exs` executes each guide's indented `iex>` blocks via
# `ExUnit.DocTest.doctest_file/1`, which ignores fenced blocks entirely. A
# ` ```elixir ` fence therefore ships to hexdocs with no execution and no
# reference checking whatsoever — the only thing standing between a broken fence
# and a user pasting it into their app is a human reading it. Phase 22.6 shipped
# `guides/moderation.md`'s flagship recipe with `verdict` referenced from a `with`
# block's `else` clause (a hard `CompileError`); it took four review agents to
# find it. This script turns that class into a suite failure.
#
# WHAT IT CATCHES — verified against `Code.compile_string/1` on Elixir 1.17.3:
#
#   * syntax errors
#   * unbound variables, including the `with`-clause-binding-in-`else` shape
#     that motivated this script (`error: undefined variable "verdict"`)
#   * struct literals naming a key the struct does not have
#     (`%ALLM.Response{content: "x"}` → `key :content not found`)
#   * bad arity / undefined local function calls within a fence
#
# WHAT IT DOES NOT CATCH — stated plainly, because a control that over-claims its
# coverage is the defect this script was commissioned to stop repeating:
#
#   * anything that only fails at RUNTIME. Notably `response.content` on a struct
#     with no `:content` field compiles clean and raises `KeyError` when run.
#     (`guides/fakes.md`'s `## Construction` block hit exactly this in 22.7; it
#     was caught by conversion to an `iex>` doctest, NOT by compilation, and this
#     script would not have caught it either. On Elixir 1.17 there is no
#     set-theoretic inference for dot access on a struct.)
#   * calls to modules that do not exist. `MyApp.Metrics.count/1` is a *warning*,
#     not an error, and this script deliberately does not escalate warnings —
#     illustrative fences naming application modules are legitimate and common.
#   * semantic wrongness of any kind: a fence that compiles and runs but
#     documents the wrong option name is invisible here.
#
# The gate is therefore a floor, not a ceiling. The stronger control remains
# CLAUDE.md's rule: prefer an `iex>` block for anything `ALLM.Providers.Fake` can
# run, and fall back to a fence only when the example genuinely can't.
#
# OPT-OUT
# -------
# A fence that legitimately cannot compile standalone — it uses a binding
# established in an earlier block, or a `~s` sigil of prose, or a file path that
# does not exist — is skipped with an HTML comment on the line immediately above
# its opening fence:
#
#     <!-- fence-check: skip — reason the fence cannot compile standalone -->
#     ```elixir
#
# The comment is invisible in rendered hexdocs, sits adjacent to the fence it
# governs (so it cannot drift the way a central line-numbered literal would), and
# every skip is enumerated in this script's output and in the `--list` report, so
# opt-out stays possible AND visible. A skip with no reason after the em dash is
# itself a failure.
#
# USAGE
#   mix run scripts/check_guide_fences.exs           # check; exit 1 on failure
#   mix run scripts/check_guide_fences.exs --list    # print the fence inventory
#
# `test/guides_test.exs` calls `Scripts.CheckGuideFences.run/0` so this is a red
# suite rather than a script nobody runs.

defmodule Scripts.CheckGuideFences do
  @moduledoc false

  @repo_root Path.expand("..", __DIR__)

  @skip_pragma ~r/^\s*<!--\s*fence-check:\s*skip\s*(?:—|--)?\s*(?<reason>.*?)\s*-->\s*$/u

  @type fence :: %{
          guide: String.t(),
          line: pos_integer(),
          body: String.t(),
          skip: nil | String.t()
        }

  @doc """
  Returns the guides ExDoc actually publishes, read off `docs[:extras]`.

  Read off the project config rather than a literal in this file for the reason
  `test/guides_test.exs`'s parity block states: a hand-maintained subject list
  produces silence for an unregistered subject, not a failure.
  """
  @spec guides() :: [String.t()]
  def guides do
    (Mix.Project.config()[:docs][:extras] || [])
    |> Enum.filter(&String.starts_with?(&1, "guides/"))
  end

  @doc """
  Extracts every ` ```elixir ` fence from `path`, with its 1-based opening-fence
  line and any `fence-check: skip` pragma on the preceding line.
  """
  @spec fences(String.t()) :: [fence()]
  def fences(path) do
    path
    |> Path.expand(@repo_root)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> collect_fences(path, [], nil)
    |> Enum.reverse()
  end

  defp collect_fences([], _guide, acc, _open), do: acc

  defp collect_fences([{line, lineno} | rest], guide, acc, nil) do
    if Regex.match?(~r/^```elixir\s*$/, line) do
      collect_fences(rest, guide, acc, {lineno, []})
    else
      collect_fences(rest, guide, acc, nil)
    end
  end

  defp collect_fences([{line, _lineno} | rest], guide, acc, {start, body}) do
    if Regex.match?(~r/^```\s*$/, line) do
      fence = %{
        guide: guide,
        line: start,
        body: body |> Enum.reverse() |> Enum.join("\n"),
        skip: nil
      }

      collect_fences(rest, guide, [fence | acc], nil)
    else
      collect_fences(rest, guide, acc, {start, [line | body]})
    end
  end

  @doc """
  Attaches the `fence-check: skip` pragma (if any) sitting on the line directly
  above each fence's opening delimiter.
  """
  @spec attach_skips([fence()], String.t()) :: [fence()]
  def attach_skips(fences, path) do
    lines =
      path
      |> Path.expand(@repo_root)
      |> File.read!()
      |> String.split("\n")

    Enum.map(fences, fn fence ->
      preceding = Enum.at(lines, fence.line - 2, "")

      case Regex.named_captures(@skip_pragma, preceding) do
        %{"reason" => reason} -> %{fence | skip: reason}
        nil -> fence
      end
    end)
  end

  @doc """
  Walks `ast` in evaluation order, returning `{:read, name}` / `{:bind, name}`
  events for every variable occurrence.

  Evaluation order is what makes the walk useful rather than a plain census:
  in `session = f(session)` the right-hand side is READ before the left-hand
  side BINDS, so `session` is correctly seen as arriving from an earlier block;
  in `with {:ok, verdict} <- f(x)` the pattern BINDS before anything reads
  `verdict`, so a later reference to it is a use of a name the fence owns.

  Binding positions recognised: the left of `=`, the left of `<-` (so `with`
  and `for` clause heads), every `->` clause head (so `case`, `cond`, `fn`,
  `rescue`, `catch`), and `def`/`defp`/`defmacro`/`defmacrop` parameter lists.
  A pin (`^x`) is a read, not a binding.

  Scope is deliberately NOT modelled — a name bound inside an inner `fn` counts
  as bound for the whole fence. That is the safe direction of the two: an
  unmodelled scope makes the walk treat a name as owned, which at worst declines
  to auto-bind it, never the reverse.
  """
  @spec scan(Macro.t()) :: [{:read | :bind, atom()}]
  def scan({:=, _, [lhs, rhs]}), do: scan(rhs) ++ binds(lhs)
  def scan({:<-, _, [lhs, rhs]}), do: scan(rhs) ++ binds(lhs)
  def scan({:->, _, [args, body]}), do: binds(args) ++ scan(body)
  def scan({:^, _, [var]}), do: scan(var)

  def scan({op, _, [head, body]}) when op in [:def, :defp, :defmacro, :defmacrop],
    do: binds(def_params(head)) ++ scan(body)

  def scan({name, _, context}) when is_atom(name) and is_atom(context) do
    if reserved?(name), do: [], else: [{:read, name}]
  end

  def scan({callee, _, args}) when is_list(args), do: scan(callee) ++ scan(args)
  def scan({left, right}), do: scan(left) ++ scan(right)
  def scan(list) when is_list(list), do: Enum.flat_map(list, &scan/1)
  def scan(_leaf), do: []

  defp binds({:^, _, [var]}), do: scan(var)
  defp binds({:when, _, [pattern | _]}), do: binds(pattern)
  defp binds({:=, _, [lhs, rhs]}), do: binds(lhs) ++ binds(rhs)

  defp binds({name, _, context}) when is_atom(name) and is_atom(context) do
    if reserved?(name), do: [], else: [{:bind, name}]
  end

  defp binds({callee, _, args}) when is_list(args), do: binds(callee) ++ binds(args)
  defp binds({left, right}), do: binds(left) ++ binds(right)
  defp binds(list) when is_list(list), do: Enum.flat_map(list, &binds/1)
  defp binds(_leaf), do: []

  defp def_params({:when, _, [head | _]}), do: def_params(head)
  defp def_params({_name, _, params}) when is_list(params), do: params
  defp def_params(_), do: []

  # `__MODULE__` and friends are special forms, not variables; a leading
  # underscore is a discard and never needs binding.
  defp reserved?(name) do
    name in [:__MODULE__, :__DIR__, :__ENV__, :__CALLER__, :__STACKTRACE__, :__aliases__] or
      String.starts_with?(Atom.to_string(name), "_")
  end

  @doc """
  Names the fence READS before it ever BINDS them — the "carried in from an
  earlier block or from the prose" class, which is legitimate in a narrative
  guide. These are bound to `nil` in a preamble rather than reported.

  This is what separates the two kinds of `undefined variable`. `engine` in
  `guides/streaming.md` is read and never bound: carried in, fine. The `verdict`
  that motivated this script is bound by its own `with` clause and only then
  read from `else`, where Elixir does not expose it — so it is not free, gets no
  preamble binding, and the fence stays red.
  """
  @spec free_vars(Macro.t()) :: [atom()]
  def free_vars(ast) do
    ast
    |> scan()
    |> Enum.reduce({MapSet.new(), []}, fn {kind, name}, {seen, free} ->
      cond do
        MapSet.member?(seen, name) -> {seen, free}
        kind == :read -> {MapSet.put(seen, name), [name | free]}
        true -> {MapSet.put(seen, name), free}
      end
    end)
    |> elem(1)
    |> Enum.sort()
  end

  @doc """
  Compiles one fence WITHOUT RUNNING IT. Returns `:ok` or `{:error, message}`.

  Two wrappings are attempted and the fence passes if either compiles:

    * `defmodule X do def __fence__ do <preamble> <body> end end` — an
      expression-shaped fence (`engine = ALLM.Engine.new(...)`, a pipeline);
    * `defmodule X do <body> end` — a fence that is itself `def`/`defmodule`/
      module-attribute shaped.

  **Both wrappings put the fence inside a function or a module body, so the
  fence's own code never executes.** That is load-bearing, not tidy: compiling
  these fences at top level RUNS them, and the guides' fences resolve API keys,
  read `/path/to/photo.png`, and call `System.fetch_env!/1`. A gate that made
  live provider calls on every `mix test` would be worse than no gate.
  """
  @spec compile_fence(fence()) :: :ok | {:error, String.t()}
  def compile_fence(%{body: body, guide: guide, line: line}) do
    module = "GuideFence_#{:erlang.phash2({guide, line})}"

    case Code.string_to_quoted(body) do
      {:ok, ast} -> compile_shapes(module, body, ast)
      {:error, {meta, message, token}} -> {:error, syntax_error(meta, message, token)}
    end
  end

  defp compile_shapes(module, body, ast) do
    preamble = preamble(ast)
    in_function = "defmodule #{module} do\ndef __fence__ do\n#{preamble}#{body}\nend\nend\n"
    in_module = "defmodule #{module} do\n#{body}\nend\n"

    # Attempt the shape the fence actually looks like FIRST, so that when it
    # fails the reported diagnostic is the compiler's real complaint rather than
    # the other shape's generic "cannot invoke def/2 inside function/macro".
    {preferred, fallback} =
      if module_shaped?(ast), do: {in_module, in_function}, else: {in_function, in_module}

    case attempt(preferred) do
      :ok -> :ok
      {:error, first} -> fallback_attempt(fallback, first)
    end
  end

  defp fallback_attempt(source, first) do
    case attempt(source) do
      :ok -> :ok
      {:error, _second} -> {:error, first}
    end
  end

  @module_forms [:def, :defp, :defmacro, :defmacrop, :defmodule, :defstruct, :defdelegate, :@]

  # True when any top-level form of the fence only makes sense in a module body.
  defp module_shaped?({:__block__, _, forms}), do: Enum.any?(forms, &module_form?/1)
  defp module_shaped?(form), do: module_form?(form)

  defp module_form?({op, _, _}) when op in @module_forms, do: true
  defp module_form?(_), do: false

  defp preamble(ast) do
    ast
    |> free_vars()
    |> Enum.map_join("", fn name -> "#{name} = nil\n" end)
  end

  defp syntax_error(meta, message, token) do
    line = Keyword.get(meta, :line, 0)
    "syntax error on fence line #{line}: #{to_string(message)}#{to_string(token)}"
  end

  # `Code.with_diagnostics/1` collects the compiler's warnings and errors rather
  # than printing them, which keeps a failing fence from dumping a wall of
  # compiler output into an ExUnit run — and is also the only way to recover the
  # real message, since `CompileError` itself says only "errors have been
  # logged". Undefined-remote-module warnings are collected and discarded; see
  # the "does not catch" note at the top of this file.
  defp attempt(source) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          purge(Code.compile_string(source))
          :ok
        rescue
          e -> {:error, first_line(Exception.message(e))}
        catch
          kind, payload -> {:error, first_line(Exception.format(kind, payload))}
        end
      end)

    case result do
      :ok -> :ok
      {:error, message} -> {:error, explain(message, diagnostics)}
    end
  end

  # Prefer the compiler's own error diagnostic over the opaque
  # "cannot compile file (errors have been logged)" wrapper.
  defp explain(message, diagnostics) do
    diagnostics
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.map_join("; ", &first_line(&1.message))
    |> case do
      "" -> message
      detail -> detail
    end
  end

  # Fences are compiled inside a live VM that already holds the real `ALLM.*`
  # modules, so every module a fence defines is unloaded again immediately. A
  # guide illustrating (say) a `defmodule ALLM.Providers.Fake` would otherwise
  # clobber the module the rest of the suite runs against.
  defp purge(compiled) do
    for {module, _binary} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    :ok
  end

  defp first_line(message) do
    message |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.first() || message
  end

  @doc """
  Checks every fence in every registered guide.

  Returns `{failures, skipped, checked}` where `failures` is a list of
  `{fence, message}` and `skipped` a list of fences carrying a pragma.
  """
  @spec check() :: {[{fence(), String.t()}], [fence()], non_neg_integer()}
  def check do
    all =
      guides()
      |> Enum.flat_map(fn guide -> guide |> fences() |> attach_skips(guide) end)

    {skipped, live} = Enum.split_with(all, &(&1.skip != nil))

    failures =
      live
      |> Enum.map(fn fence -> {fence, compile_fence(fence)} end)
      |> Enum.filter(&match?({_, {:error, _}}, &1))
      |> Enum.map(fn {fence, {:error, message}} -> {fence, message} end)

    {failures, skipped, length(live)}
  end

  @doc """
  Runs the check and prints a report. Returns `:ok` or `{:error, report}`.
  """
  @spec run() :: :ok | {:error, String.t()}
  def run do
    {failures, skipped, checked} = check()

    unreasoned = Enum.filter(skipped, &(String.trim(&1.skip) == ""))

    cond do
      failures != [] -> {:error, failure_report(failures)}
      unreasoned != [] -> {:error, unreasoned_report(unreasoned)}
      true -> print_ok(checked, skipped)
    end
  end

  defp print_ok(checked, skipped) do
    IO.puts("#{checked} fences compiled, #{length(skipped)} skipped.")

    for fence <- skipped do
      IO.puts("  skip #{fence.guide}:#{fence.line} — #{fence.skip}")
    end

    :ok
  end

  defp failure_report(failures) do
    body =
      Enum.map_join(failures, "\n", fn {fence, message} ->
        "  #{fence.guide}:#{fence.line} — #{message}"
      end)

    """
    #{length(failures)} ```elixir fence(s) do not compile:

    #{body}

    Fix the fence, or — preferred, per CLAUDE.md — convert it to an `iex>` block
    if ALLM.Providers.Fake can run it, which also gives it doctest coverage.
    If it genuinely cannot compile standalone, add the line

        <!-- fence-check: skip — why it cannot compile standalone -->

    directly above the opening ```elixir delimiter. Re-check with:

        mix run scripts/check_guide_fences.exs
    """
  end

  defp unreasoned_report(unreasoned) do
    body =
      Enum.map_join(unreasoned, "\n", fn fence -> "  #{fence.guide}:#{fence.line}" end)

    """
    #{length(unreasoned)} fence-check skip pragma(s) carry no reason:

    #{body}

    Write the reason after the em dash so the opt-out stays auditable:

        <!-- fence-check: skip — why it cannot compile standalone -->
    """
  end

  @doc "Prints the full fence inventory, skipped and checked alike."
  @spec list() :: :ok
  def list do
    for guide <- guides() do
      all = guide |> fences() |> attach_skips(guide)
      IO.puts("#{guide} — #{length(all)} fences")

      for fence <- all do
        marker = if fence.skip, do: "SKIP", else: "check"
        suffix = if fence.skip, do: " — #{fence.skip}", else: ""
        IO.puts("  #{marker} :#{fence.line}#{suffix}")
      end
    end

    :ok
  end
end

# CLI entry — only fires when this file is executed under `mix run`. When the
# test suite `Code.require_file/1`s this script, `Mix.env() == :test` and we skip
# the side effects. Same idiom as `scripts/audit_user_docs.exs`.
if Mix.env() != :test do
  case System.argv() do
    ["--list"] ->
      Scripts.CheckGuideFences.list()

    _ ->
      case Scripts.CheckGuideFences.run() do
        :ok ->
          :ok

        {:error, report} ->
          IO.puts(:stderr, report)
          System.halt(1)
      end
  end
end
