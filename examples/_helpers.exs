defmodule ExamplesHelpers do
  @moduledoc """
  Provider-neutral engine constructors for the runnable example scripts under
  `examples/`. Reads `ALLM_PROVIDER` env (default `"openai"`), looks up the
  adapter + default model + key env var name from the `@providers` table, and
  returns a configured `%ALLM.Engine{}` for use in any script.

  Three constructors are exposed:

    * `engine/1` — chat-adapter engine; reads `:adapter` / `:default_model`
      / `:key_env` from the provider row. Pass `vision: true` to route to
      the row's `:vision_default_model` instead of `:default_model` (Phase
      17.3 / §35.6) — used by `12_vision_input.exs` to pick a vision-capable
      model on each provider arm.
    * `image_engine/1` — image-adapter engine (Phase 15.6); reads
      `:image_adapter` / `:image_default_model`. Raises `ArgumentError` for
      providers without an image adapter (e.g. Anthropic).
    * `embedding_engine/1` — embed-adapter engine (Phase 20.7); reads
      `:embed_adapter` / `:embedding_default_model` / `:embedding_key_env`.
      Raises `ArgumentError` for providers without an embedding adapter.

  ## Why the Anthropic row's embedding adapter is `Voyage`

  Anthropic ships no embeddings endpoint and never has; it names Voyage AI as
  its recommended embeddings partner. So the `"anthropic"` row points
  `:embed_adapter` at `ALLM.Providers.Voyage.Embeddings` and overrides
  `:embedding_key_env` to `"VOYAGE_API_KEY"` — the embedding scripts on the
  Anthropic arm authenticate against Voyage, NOT against Anthropic. That makes
  `VOYAGE_API_KEY` a hard requirement for `ALLM_PROVIDER=anthropic`, because
  `ensure_key_present!/1` halts on a missing key. Naming a Voyage client after
  Anthropic would assert a wire that does not exist, which is why there is no
  `ALLM.Providers.Anthropic.Embeddings` module to point at instead.

  `:embedding_key_env` defaults to the row's chat `:key_env` when absent, so
  OpenAI and Gemini need no extra key.

  Auto-loads a project-root `.env` via `:env_loader` (dev-only dep) so reviewers
  who keep both `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` in `.env` don't have to
  export them per script.
  """

  # Per-provider rows. The optional `:default_temperature` field (Phase 16.6 /
  # Decision #20) lets a provider opt out of the OpenAI/Anthropic-friendly
  # `temperature: 0` baseline; Google explicitly recommends `1.0` for Gemini 3.
  # Rows that omit the key inherit the `0` default in `engine/1` — caller
  # `temperature:` overrides still win.
  @providers %{
    "openai" => %{
      adapter: ALLM.Providers.OpenAI,
      default_model: "gpt-5.4-nano",
      vision_default_model: "gpt-4o-mini",
      key_env: "OPENAI_API_KEY",
      image_adapter: ALLM.Providers.OpenAI.Images,
      image_default_model: "dall-e-2",
      embed_adapter: ALLM.Providers.OpenAI.Embeddings,
      embedding_default_model: "text-embedding-3-small"
    },
    "anthropic" => %{
      adapter: ALLM.Providers.Anthropic,
      default_model: "claude-sonnet-4-6",
      vision_default_model: "claude-haiku-4-5-20251001",
      key_env: "ANTHROPIC_API_KEY",
      image_adapter: nil,
      image_default_model: nil,
      # Anthropic has no embeddings endpoint — Voyage is its recommended
      # partner, and the key comes from VOYAGE_API_KEY. See the moduledoc.
      embed_adapter: ALLM.Providers.Voyage.Embeddings,
      embedding_default_model: "voyage-3.5-lite",
      embedding_key_env: "VOYAGE_API_KEY"
    },
    "gemini" => %{
      adapter: ALLM.Providers.Gemini,
      default_model: "gemini-3-flash-preview",
      vision_default_model: "gemini-3-flash-preview",
      key_env: "GEMINI_API_KEY",
      image_adapter: ALLM.Providers.Gemini.Images,
      image_default_model: "gemini-3.1-flash-image-preview",
      default_temperature: 1.0,
      embed_adapter: ALLM.Providers.Gemini.Embeddings,
      embedding_default_model: "gemini-embedding-001"
    }
  }

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's chat adapter.

  `extra_opts` is a keyword list merged on top of the helper defaults; pass
  `tools:`, `tool_executor:`, `tool_result_encoder:`, `params:`, etc. for
  per-script customization. The defaults set `tool_executor:`,
  `tool_result_encoder:`, and `params: %{temperature: 0}`.
  """
  def engine(extra_opts \\ []) do
    {vision?, extra_opts} = Keyword.pop(extra_opts, :vision, false)

    %{adapter: adapter, default_model: default_model, key_env: key_env} =
      row = lookup_provider_row()

    ensure_adapter_loaded!(adapter)
    ensure_key_present!(key_env)

    base_model =
      if vision?, do: Map.get(row, :vision_default_model) || default_model, else: default_model

    model = System.get_env("ALLM_MODEL", base_model)

    # Phase 16.6 / Decision #20 — provider row may declare a `:default_temperature`
    # (Gemini sets `1.0` per Google's recommendation). Absent → `0` (the historic
    # OpenAI/Anthropic-friendly baseline). Caller-supplied `params:` still wins,
    # but `Keyword.merge` SHALLOW-replaces the whole `:params` map; we deep-merge
    # the `:params` map below so a caller passing `params: %{max_tokens: 100}`
    # (without a `temperature` key) preserves the row's `default_temperature`
    # rather than silently losing it. Phase 16.6 retro Finding 3.
    default_temperature = Map.get(row, :default_temperature, 0)

    base = [
      adapter: adapter,
      model: model,
      tool_executor: ALLM.ToolExecutor.Default,
      tool_result_encoder: ALLM.ToolResultEncoder.JSON,
      params: %{temperature: default_temperature}
    ]

    ALLM.Engine.new(merge_with_params(base, extra_opts))
  end

  # Deep-merge for the `:params` map only — every other keyword key is
  # shallow-replaced as `Keyword.merge` would. Public test seam for the
  # Decision #20 invariant (Phase 16.6 retro Finding 3).
  @doc false
  def merge_with_params(base, extra_opts) do
    base_params = Keyword.get(base, :params, %{})
    extra_params = Keyword.get(extra_opts, :params, %{})

    merged_params = Map.merge(base_params, extra_params)

    base
    |> Keyword.merge(extra_opts)
    |> Keyword.put(:params, merged_params)
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's image adapter (Phase
  15.6 / Decision #14).

  Raises `ArgumentError` when the active provider has no `:image_adapter`
  (e.g. `ALLM_PROVIDER=anthropic`) — image-only example scripts should
  guard with `# Provider: openai` so `run_all.exs` skips them on the
  Anthropic arm.

  `extra_opts` is a keyword list merged on top of the helper defaults
  (`adapter:` and `model:` are baked in from the provider row;
  `ALLM_MODEL` overrides the default model when set).
  """
  def image_engine(extra_opts \\ []) do
    provider = active_provider()
    row = lookup_provider_row()

    %{key_env: key_env, image_adapter: image_adapter, image_default_model: image_default_model} =
      row

    if is_nil(image_adapter) or is_nil(image_default_model) do
      raise ArgumentError,
            "#{provider} does not have an image_adapter; this script is OpenAI-only"
    end

    ensure_adapter_loaded!(image_adapter)
    ensure_key_present!(key_env)

    model = System.get_env("ALLM_MODEL", image_default_model)

    base = [
      image_adapter: image_adapter,
      model: model
    ]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's embedding adapter (Phase
  20.7).

  Reads `:embed_adapter` / `:embedding_default_model` from the provider row,
  and `:embedding_key_env` — which falls back to the row's chat `:key_env`
  when absent. The Anthropic row sets it to `"VOYAGE_API_KEY"` because
  Anthropic ships no embeddings endpoint and Voyage is its recommended
  partner; see the moduledoc.

  Raises `ArgumentError` when the active provider row has no embedding
  adapter. Every bundled provider arm has one, so the embedding scripts carry
  no `# Provider:` marker and `run_all.exs` runs them everywhere.

  `extra_opts` is merged on top of the helper defaults (`embed_adapter:` and
  `model:` are baked in from the provider row; `ALLM_EMBEDDING_MODEL`
  overrides the default model when set).
  """
  def embedding_engine(extra_opts \\ []) do
    provider = active_provider()
    row = lookup_provider_row()

    embed_adapter = Map.get(row, :embed_adapter)
    embedding_default_model = Map.get(row, :embedding_default_model)
    key_env = Map.get(row, :embedding_key_env) || Map.fetch!(row, :key_env)

    if is_nil(embed_adapter) or is_nil(embedding_default_model) do
      raise ArgumentError,
            "#{provider} does not have an embed_adapter; " <>
              "this script cannot run on that provider arm"
    end

    ensure_adapter_loaded!(embed_adapter)
    ensure_key_present!(key_env)

    model = System.get_env("ALLM_EMBEDDING_MODEL", embedding_default_model)

    base = [
      embed_adapter: embed_adapter,
      model: model
    ]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
  end

  defp active_provider do
    # Load .env from project root if present — no-op when keys are already in env.
    EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "..")))
    System.get_env("ALLM_PROVIDER", "openai")
  end

  defp lookup_provider_row do
    provider = active_provider()

    case Map.fetch(@providers, provider) do
      {:ok, row} ->
        row

      :error ->
        raise ArgumentError,
              "Unknown ALLM_PROVIDER #{inspect(provider)}; legal: " <>
                inspect(Map.keys(@providers))
    end
  end

  defp ensure_adapter_loaded!(adapter) do
    unless Code.ensure_loaded?(adapter) do
      IO.puts(
        :stderr,
        "FAIL: #{inspect(adapter)} not compiled — is the provider's phase included in this build?"
      )

      System.halt(1)
    end
  end

  defp ensure_key_present!(key_env) do
    if System.get_env(key_env) in [nil, ""] do
      IO.puts(
        :stderr,
        "FAIL: #{key_env} not set (required for ALLM_PROVIDER=#{System.get_env("ALLM_PROVIDER", "openai")}); " <>
          "set it in env or add to .env at the project root"
      )

      System.halt(1)
    end
  end
end
