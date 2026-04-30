defmodule ExamplesHelpers do
  @moduledoc """
  Provider-neutral engine constructors for the runnable example scripts under
  `examples/`. Reads `ALLM_PROVIDER` env (default `"openai"`), looks up the
  adapter + default model + key env var name from the `@providers` table, and
  returns a configured `%ALLM.Engine{}` for use in any script.

  Two constructors are exposed:

    * `engine/1` — chat-adapter engine; reads `:adapter` / `:default_model`
      / `:key_env` from the provider row. Pass `vision: true` to route to
      the row's `:vision_default_model` instead of `:default_model` (Phase
      17.3 / §35.6) — used by `12_vision_input.exs` to pick a vision-capable
      model on each provider arm.
    * `image_engine/1` — image-adapter engine (Phase 15.6); reads
      `:image_adapter` / `:image_default_model`. Raises `ArgumentError` for
      providers without an image adapter (e.g. Anthropic).

  Auto-loads a project-root `.env` via `:env_loader` (dev-only dep) so reviewers
  who keep both `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` in `.env` don't have to
  export them per script.
  """

  @providers %{
    "openai" => %{
      adapter: ALLM.Providers.OpenAI,
      default_model: "gpt-5.4-nano",
      vision_default_model: "gpt-4o-mini",
      key_env: "OPENAI_API_KEY",
      image_adapter: ALLM.Providers.OpenAI.Images,
      image_default_model: "dall-e-2"
    },
    "anthropic" => %{
      adapter: ALLM.Providers.Anthropic,
      default_model: "claude-sonnet-4-6",
      vision_default_model: "claude-haiku-4-5-20251001",
      key_env: "ANTHROPIC_API_KEY",
      image_adapter: nil,
      image_default_model: nil
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

    base = [
      adapter: adapter,
      model: model,
      tool_executor: ALLM.ToolExecutor.Default,
      tool_result_encoder: ALLM.ToolResultEncoder.JSON,
      params: %{temperature: 0}
    ]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
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
