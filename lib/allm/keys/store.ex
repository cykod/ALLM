defmodule ALLM.Keys.Store do
  @moduledoc false

  # Agent-backed in-process key store for ALLM.Keys (spec §6.4, Non-obvious
  # decisions #1 and #10).
  #
  # State shape:
  #
  #     %{
  #       runtime: %{atom() => String.t()},
  #       dotenv:  :unloaded | %{String.t() => String.t()}
  #     }
  #
  # The `:runtime` slice holds keys installed via `ALLM.Keys.put/2`. The
  # `:dotenv` slice caches the one-time `.env` load — `:unloaded` until the
  # first `dotenv_lookup/1` call with `config :allm, load_dotenv: true`,
  # then the parsed map. `clear/0` resets BOTH slices so test suites can
  # isolate with a single call.

  use Agent

  alias ALLM.Keys.Dotenv

  @type state :: %{
          runtime: %{atom() => String.t()},
          dotenv: :unloaded | %{String.t() => String.t()}
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{runtime: %{}, dotenv: :unloaded} end, name: __MODULE__)
  end

  @spec put(atom(), String.t()) :: :ok
  def put(provider, key) when is_atom(provider) and is_binary(key) do
    Agent.update(__MODULE__, fn state ->
      %{state | runtime: Map.put(state.runtime, provider, key)}
    end)
  end

  @spec get(atom()) :: String.t() | nil
  def get(provider) when is_atom(provider) do
    Agent.get(__MODULE__, fn state -> Map.get(state.runtime, provider) end)
  end

  @spec delete(atom()) :: :ok
  def delete(provider) when is_atom(provider) do
    Agent.update(__MODULE__, fn state ->
      %{state | runtime: Map.delete(state.runtime, provider)}
    end)
  end

  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> %{runtime: %{}, dotenv: :unloaded} end)
  end

  @doc """
  Look up `env_var` in the cached `.env` map.

  Performs the lazy one-time load on first call when
  `config :allm, load_dotenv: true`. Returns `nil` when load_dotenv is
  disabled or when the env var is not in the file.
  """
  @spec dotenv_lookup(String.t()) :: String.t() | nil
  def dotenv_lookup(env_var) when is_binary(env_var) do
    if load_dotenv_enabled?() do
      map = ensure_dotenv_loaded()
      Map.get(map, env_var)
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_dotenv_enabled?() :: boolean()
  defp load_dotenv_enabled? do
    Application.get_env(:allm, :load_dotenv) == true
  end

  # Perform the lazy dotenv load under the Agent lock. First caller reads
  # the file via ALLM.Keys.Dotenv.load/1 and writes the result; subsequent
  # callers see the cached map.
  @spec ensure_dotenv_loaded() :: %{String.t() => String.t()}
  defp ensure_dotenv_loaded do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.dotenv do
        :unloaded ->
          map = Dotenv.load(dotenv_path())
          {map, %{state | dotenv: map}}

        map ->
          {map, state}
      end
    end)
  end

  @spec dotenv_path() :: Path.t()
  defp dotenv_path do
    Application.get_env(:allm, :dotenv_path) || Path.join(File.cwd!(), ".env")
  end
end
