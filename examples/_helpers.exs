defmodule ExamplesHelpers do
  @moduledoc """
  Provider-neutral engine constructor for the runnable example scripts under
  `examples/`. Reads `ALLM_PROVIDER` env (default `"openai"`), looks up the
  adapter + default model + key env var name from the `@providers` table, and
  returns a configured `%ALLM.Engine{}` for use in any script.

  Auto-loads a project-root `.env` via `:env_loader` (dev-only dep) so reviewers
  who keep both `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` in `.env` don't have to
  export them per script.
  """

  @providers %{
    "openai" => {ALLM.Providers.OpenAI, "gpt-5.4-nano", "OPENAI_API_KEY"},
    "anthropic" => {ALLM.Providers.Anthropic, "claude-sonnet-4-6", "ANTHROPIC_API_KEY"}
  }

  @doc """
  Build a `%ALLM.Engine{}` for the active provider.

  `extra_opts` is a keyword list merged on top of the helper defaults; pass
  `tools:`, `tool_executor:`, `tool_result_encoder:`, `params:`, etc. for
  per-script customization. The defaults set `tool_executor:`,
  `tool_result_encoder:`, and `params: %{temperature: 0}`.
  """
  def engine(extra_opts \\ []) do
    # Load .env from project root if present — no-op when keys are already in env.
    EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "..")))

    provider = System.get_env("ALLM_PROVIDER", "openai")

    {adapter, default_model, key_env} =
      case Map.fetch(@providers, provider) do
        {:ok, row} ->
          row

        :error ->
          raise ArgumentError,
                "Unknown ALLM_PROVIDER #{inspect(provider)}; legal: " <>
                  inspect(Map.keys(@providers))
      end

    unless Code.ensure_loaded?(adapter) do
      IO.puts(
        :stderr,
        "FAIL: #{inspect(adapter)} not compiled — is the provider's phase included in this build?"
      )

      System.halt(1)
    end

    if System.get_env(key_env) in [nil, ""] do
      IO.puts(
        :stderr,
        "FAIL: #{key_env} not set (required for ALLM_PROVIDER=#{provider}); " <>
          "set it in env or add to .env at the project root"
      )

      System.halt(1)
    end

    model = System.get_env("ALLM_MODEL", default_model)

    base = [
      adapter: adapter,
      model: model,
      tool_executor: ALLM.ToolExecutor.Default,
      tool_result_encoder: ALLM.ToolResultEncoder.JSON,
      params: %{temperature: 0}
    ]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
  end
end
