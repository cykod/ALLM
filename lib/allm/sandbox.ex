defmodule ALLM.Sandbox do
  @moduledoc """
  Per-process engine resolution for tests — Layer B test-injection helper.

  Lives in `lib/` (NOT `test/support/`) so integrators can call it from
  their own test suites without depending on ALLM's internal test tree.
  The functions are pure process-dict and `$callers` reads — no
  GenServer, no ETS, no application state.

  ## When to reach for it

  When a test fans work out across `Task.async/1` / `Task.async_stream/3`
  workers — or any other process whose `$callers` chain includes the
  registering pid — `Sandbox.set_engine/1` makes the test's `%Engine{}`
  visible to those workers via `Sandbox.get_engine/0`. The pattern mirrors
  `Mox.allow/3` and `Ecto.Adapters.SQL.Sandbox.allow/3` so integrators
  don't have to learn a new mental model.

  ## Storage and isolation

    * Storage: `Process.put(:"$allm_test_engine", engine)` on the
      registering process.
    * Reads: walk `Process.get(:"$callers", [])` head → tail, returning
      the first ancestor's registration; fall back to the current
      process's own dict.
    * `async: true` isolation: every ExUnit test process owns its own
      process dict; registrations in test N never leak to test N+1.

  ## Example

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]])
      iex> :ok = ALLM.Sandbox.set_engine(engine)
      iex> ALLM.Sandbox.get_engine() == engine
      true
      iex> ALLM.Sandbox.unset_engine()
      :ok
      iex> ALLM.Sandbox.get_engine()
      nil
  """

  alias ALLM.Engine

  @key :"$allm_test_engine"

  @typedoc "An `%ALLM.Engine{}` registered for cross-process resolution."
  @type engine_value :: Engine.t()

  @doc """
  Register an engine for the current process.

  Visible to any process whose `$callers` chain includes the calling pid
  — `Task.async/1`, `Task.async_stream/3`, and any other process spawned
  via OTP's `proc_lib` machinery propagate `$callers` automatically.

  Returns `:ok`.

  ## Examples

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      iex> ALLM.Sandbox.set_engine(engine)
      :ok
  """
  @spec set_engine(engine_value()) :: :ok
  def set_engine(%Engine{} = engine) do
    Process.put(@key, engine)
    :ok
  end

  @doc """
  Resolve the registered engine for the current process.

  Walks `Process.get(:"$callers", [])` head → tail (most-recent ancestor
  first) and returns the first ancestor whose process dict carries a
  registration. Falls back to the current process's own dict, then to
  `nil` when no ancestor has registered.

  ## Examples

      iex> ALLM.Sandbox.get_engine()
      nil

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      iex> :ok = ALLM.Sandbox.set_engine(engine)
      iex> ALLM.Sandbox.get_engine() == engine
      true
  """
  @spec get_engine() :: engine_value() | nil
  def get_engine do
    # First check the current process's own dict — covers the common
    # same-process case without a `$callers` walk.
    case Process.get(@key) do
      %Engine{} = engine ->
        engine

      nil ->
        # Walk `$callers` head-to-tail (most-recent ancestor first). Mox
        # and Ecto.SQL.Sandbox use the same idiom. Reading another
        # process's dict requires `Process.info(pid, :dictionary)`.
        walk_callers(Process.get(:"$callers", []))
    end
  end

  @doc """
  Scope an engine registration to a callback's lifetime.

  Equivalent to `set_engine/1` immediately followed by `unset_engine/0`
  in `try/after`, but additionally restores a prior registration (if
  any) on callback exit.

  Returns the callback's return value.

  ## Examples

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      iex> ALLM.Sandbox.with_engine(engine, fn -> ALLM.Sandbox.get_engine() == engine end)
      true
      iex> ALLM.Sandbox.get_engine()
      nil
  """
  @spec with_engine(engine_value(), (-> result)) :: result when result: term()
  def with_engine(%Engine{} = engine, fun) when is_function(fun, 0) do
    prior = Process.get(@key)
    Process.put(@key, engine)

    try do
      fun.()
    after
      case prior do
        nil -> Process.delete(@key)
        %Engine{} = e -> Process.put(@key, e)
      end
    end
  end

  @doc """
  Clear the current process's registered engine. Idempotent — calling
  without a prior `set_engine/1` returns `:ok`.

  ## Examples

      iex> ALLM.Sandbox.unset_engine()
      :ok
  """
  @spec unset_engine() :: :ok
  def unset_engine do
    Process.delete(@key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Walk the `$callers` list head-to-tail. Reading another process's dict
  # uses `Process.info(pid, :dictionary)` — a documented BEAM idiom that
  # Mox and Ecto.SQL.Sandbox both rely on.
  defp walk_callers([]), do: nil

  defp walk_callers([pid | rest]) when is_pid(pid) do
    case caller_engine(pid) do
      %Engine{} = engine -> engine
      nil -> walk_callers(rest)
    end
  end

  defp walk_callers([_ | rest]), do: walk_callers(rest)

  defp caller_engine(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} when is_list(dict) ->
        case List.keyfind(dict, @key, 0) do
          {@key, %Engine{} = engine} -> engine
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
