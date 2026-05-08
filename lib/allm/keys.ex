defmodule ALLM.Keys do
  @moduledoc """
  API key resolution. Keys never appear on the engine — they resolve at
  adapter-call time, so a serialized engine is safe to persist.

  ## Resolution chain

  Five levels — the first level that yields a non-empty string wins:

    1. `opts[:api_key]` — explicit per-call override
    2. The runtime store — an in-process Agent set via `put/2`
    3. `Application.get_env(:allm, :keys, %{})[provider]`
    4. `System.get_env(env_var_for(provider))`
    5. `.env` file at `config :allm, :dotenv_path` (default:
       `File.cwd! <> "/.env"`) — **only** consulted when
       `config :allm, load_dotenv: true`.

  Empty-string values at every level are treated as missing (defensive
  an unset-looking env var like `OPENAI_API_KEY=` must not satisfy
  resolution).

  ## Return shapes

  `get/1` and `get/2` return `{:ok, key, source}` on hit or
  `{:error, :missing}` on miss. `fetch!/2` raises
  `%ALLM.Error.EngineError{reason: :missing_key}` on miss — it's the only
  function in the library that raises rather than returning an
  `{:error, _}` tuple, justified because adapters look up keys at call
  time deep inside their implementation and bubbling `{:error, _}`
  through every `with` chain is untenable.

  ## `.env` parser limitations

  ALLM ships a built-in `.env` parser to avoid pulling in a `dotenvy`
  dependency for a level-5 fallback most users won't even enable. The
  supported subset is strict: `KEY=VALUE` lines, `# comment` lines,
  blank lines, `export KEY=VALUE` (the leading `export` is stripped),
  and surrounding double-quote stripping. **No variable interpolation,
  no multi-line values, no escape sequences, no single-quote
  stripping.** Users with complex `.env` files should either
  `System.put_env/2` at boot or depend on `dotenvy` themselves.

  See also `guides/multi_tenant_keys.md`.
  """

  alias ALLM.Error.EngineError
  alias ALLM.Keys.Dotenv
  alias ALLM.Keys.Store

  @type provider :: atom()
  @type source :: :opts | :runtime | :app_config | :env | :dotenv

  # Known-provider env-var mapping (spec §6.4 table). Unknown providers fall
  # back to String.upcase("#{atom}") <> "_API_KEY".
  @env_var_table %{
    openai: "OPENAI_API_KEY",
    anthropic: "ANTHROPIC_API_KEY",
    google: "GOOGLE_API_KEY",
    cohere: "COHERE_API_KEY",
    mistral: "MISTRAL_API_KEY",
    fake: "FAKE_API_KEY"
  }

  @doc """
  Install `key` for `provider` in the in-process runtime store.

  Cleared by `ALLM.Keys.delete/1` or by clearing the runtime store
  directly. Persists for the lifetime of the in-process Agent.

  ## Examples

      iex> ALLM.Keys.Store.clear()
      iex> ALLM.Keys.put(:my_test_provider, "sk-doctest")
      :ok
      iex> ALLM.Keys.get(:my_test_provider)
      {:ok, "sk-doctest", :runtime}
      iex> ALLM.Keys.Store.clear()
      :ok
  """
  @spec put(provider(), String.t()) :: :ok
  def put(provider, key) when is_atom(provider) and is_binary(key),
    do: Store.put(provider, key)

  @doc """
  Remove `provider`'s key from the in-process runtime store.

  Does not touch Application env, system env, or the `.env` cache.
  """
  @spec delete(provider()) :: :ok
  def delete(provider) when is_atom(provider), do: Store.delete(provider)

  @doc """
  Resolve the API key for `provider` via the five-level chain.

  Returns `{:ok, key, source}` on hit (where `source` identifies which
  level of the chain provided the key) or `{:error, :missing}` on miss.
  Shorthand for `get(provider, [])`.

  ## Examples

      iex> ALLM.Keys.Store.clear()
      iex> ALLM.Keys.put(:my_test_provider, "sk-doctest")
      iex> ALLM.Keys.get(:my_test_provider)
      {:ok, "sk-doctest", :runtime}
      iex> ALLM.Keys.Store.clear()
      :ok
  """
  @spec get(provider()) :: {:ok, String.t(), source()} | {:error, :missing}
  def get(provider), do: get(provider, [])

  @doc """
  Resolve the API key for `provider`, honoring `opts[:api_key]` as the
  highest-precedence source.

  See the module docs for the full chain.
  """
  @spec get(provider(), keyword()) :: {:ok, String.t(), source()} | {:error, :missing}
  def get(provider, opts) when is_atom(provider) and is_list(opts) do
    sources = checked_sources()
    walk(sources, provider, opts)
  end

  @doc """
  Like `get/2`, but raises `%ALLM.Error.EngineError{reason: :missing_key}`
  when no source yields a non-empty key.

  This is the ONLY function in the library that raises
  `ALLM.Error.EngineError` rather than returning it in an `{:error, _}`
  tuple. Justified because adapters look up keys at call time deep
  inside their implementation, and bubbling `{:error, _}` through every
  `with` chain is untenable.

  The raised error's `:metadata` carries `:checked_sources` — a list of
  the source atoms that were actually consulted (`:dotenv` is included
  only when `config :allm, load_dotenv: true`).

  Note: `:checked_sources` records which levels were **configured/enabled**
  for this call (i.e., which chain links were walked), not which levels
  actually had a value supplied. An `:opts` entry appearing in the list
  means the opts keyword was inspected — it does not distinguish
  "`api_key:` omitted" from "`api_key:` present but empty/nil".

  ## Examples

      iex> ALLM.Keys.Store.clear()
      iex> ALLM.Keys.put(:my_test_provider, "sk-doctest")
      iex> ALLM.Keys.fetch!(:my_test_provider)
      "sk-doctest"
      iex> ALLM.Keys.Store.clear()
      iex> try do
      ...> ALLM.Keys.fetch!(:my_test_provider)
      ...> rescue
      ...> e in ALLM.Error.EngineError -> e.reason
      ...> end
      :missing_key
  """
  @spec fetch!(provider(), keyword()) :: String.t()
  def fetch!(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    case get(provider, opts) do
      {:ok, key, _source} ->
        key

      {:error, :missing} ->
        raise EngineError.new(:missing_key,
                provider: provider,
                message:
                  "no API key found for provider #{inspect(provider)} " <>
                    "(checked: #{inspect(checked_sources())})",
                metadata: %{checked_sources: checked_sources()}
              )
    end
  end

  @doc """
  Translate a provider atom to its env-var name.

  Known providers use a fixed table (`:openai → "OPENAI_API_KEY"`,
  `:anthropic → "ANTHROPIC_API_KEY"`, `:google → "GOOGLE_API_KEY"`,
  `:cohere → "COHERE_API_KEY"`, `:mistral → "MISTRAL_API_KEY"`,
  `:fake → "FAKE_API_KEY"`). Unknown providers fall back to
  `String.upcase("\#{provider}") <> "_API_KEY"`.

  Public because the dotenv-loader delegates through it for
  consistent provider→env-var translation: the `.env` source looks up the
  same env-var name the `System.get_env` source does, so configuring one
  (`OPENAI_API_KEY=…` in the shell) and the other (`OPENAI_API_KEY=…` in
  `.env`) uses an identical key name. This module is the single source
  of truth for that mapping.

  ## Examples

      iex> ALLM.Keys.env_var_for(:openai)
      "OPENAI_API_KEY"
      iex> ALLM.Keys.env_var_for(:anthropic)
      "ANTHROPIC_API_KEY"
      iex> ALLM.Keys.env_var_for(:some_new_provider)
      "SOME_NEW_PROVIDER_API_KEY"
  """
  @spec env_var_for(provider()) :: String.t()
  def env_var_for(provider) when is_atom(provider) do
    case Map.fetch(@env_var_table, provider) do
      {:ok, env_var} -> env_var
      :error -> String.upcase("#{provider}") <> "_API_KEY"
    end
  end

  # ---------------------------------------------------------------------------
  # Private — resolver chain
  # ---------------------------------------------------------------------------

  @spec checked_sources() :: [source()]
  defp checked_sources do
    base = [:opts, :runtime, :app_config, :env]
    if load_dotenv_enabled?(), do: base ++ [:dotenv], else: base
  end

  @spec load_dotenv_enabled?() :: boolean()
  defp load_dotenv_enabled? do
    Application.get_env(:allm, :load_dotenv) == true
  end

  @spec walk([source()], provider(), keyword()) ::
          {:ok, String.t(), source()} | {:error, :missing}
  defp walk([], _provider, _opts), do: {:error, :missing}

  defp walk([source | rest], provider, opts) do
    case try_source(source, provider, opts) do
      {:ok, key} -> {:ok, key, source}
      :miss -> walk(rest, provider, opts)
    end
  end

  @spec try_source(source(), provider(), keyword()) :: {:ok, String.t()} | :miss
  defp try_source(:opts, _provider, opts) do
    wrap(Keyword.get(opts, :api_key))
  end

  defp try_source(:runtime, provider, _opts) do
    wrap(Store.get(provider))
  end

  defp try_source(:app_config, provider, _opts) do
    wrap(Application.get_env(:allm, :keys, %{})[provider])
  end

  defp try_source(:env, provider, _opts) do
    wrap(System.get_env(env_var_for(provider)))
  end

  defp try_source(:dotenv, provider, _opts) do
    wrap(Dotenv.lookup(provider))
  end

  # Treat nil AND empty-string as missing.
  @spec wrap(nil | String.t()) :: {:ok, String.t()} | :miss
  defp wrap(nil), do: :miss
  defp wrap(""), do: :miss
  defp wrap(value) when is_binary(value), do: {:ok, value}
  defp wrap(_), do: :miss
end
