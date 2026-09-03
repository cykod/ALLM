defmodule ExamplesHelpers do
  @moduledoc """
  Provider-neutral engine constructors for the runnable example scripts under
  `examples/`. Reads `ALLM_PROVIDER` env (default `"openai"`), looks up the
  adapter + default model + key env var name from the `@providers` table, and
  returns a configured `%ALLM.Engine{}` for use in any script.

  Four constructors are exposed:

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
    * `moderation_engine/1` — moderation-adapter engine (Phase 22.6); reads
      `:moderation_adapter` / `:moderation_default_model`. Raises
      `ArgumentError` for providers without a moderation adapter, which
      today is every provider except OpenAI.

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

  ## Why only the OpenAI row has a moderation adapter

  Moderation is a single-provider capability. Anthropic ships no moderation
  endpoint, and Google exposes safety ratings inline on `generateContent`
  rather than as a standalone classification call — neither can implement
  `c:ALLM.ModerationAdapter.moderate/2` without inventing a generation call
  to attach itself to. So the `"anthropic"` and `"gemini"` rows carry
  `moderation_adapter: nil`, `moderation_engine/1` raises for them, and the
  moderation scripts carry a `# Provider: openai` marker so `run_all.exs`
  SKIPS them on those arms instead of halting the run. This is the opposite
  of the embedding scripts, which carry no marker because every arm has an
  adapter.

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
      embedding_default_model: "text-embedding-3-small",
      moderation_adapter: ALLM.Providers.OpenAI.Moderation,
      moderation_default_model: "omni-moderation-latest"
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
      embedding_key_env: "VOYAGE_API_KEY",
      # Anthropic ships no moderation endpoint and names no partner for it —
      # see the moduledoc. `moderation_engine/1` raises here by design.
      moderation_adapter: nil,
      moderation_default_model: nil
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
      embedding_default_model: "gemini-embedding-001",
      # Gemini's safety ratings ride `generateContent` rather than a
      # standalone endpoint — see the moduledoc.
      moderation_adapter: nil,
      moderation_default_model: nil
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
    capability_engine(
      %{
        adapter_key: :image_adapter,
        model_key: :image_default_model,
        key_env_key: nil,
        model_env: "ALLM_MODEL",
        unavailable: "does not have an image_adapter; this script is OpenAI-only"
      },
      extra_opts
    )
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
    capability_engine(
      %{
        adapter_key: :embed_adapter,
        model_key: :embedding_default_model,
        key_env_key: :embedding_key_env,
        model_env: "ALLM_EMBEDDING_MODEL",
        unavailable: "does not have an embed_adapter; this script cannot run on that provider arm"
      },
      extra_opts
    )
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's moderation adapter
  (Phase 22.6).

  Reads `:moderation_adapter` / `:moderation_default_model` from the provider
  row. The key comes from the row's chat `:key_env`, because the only
  moderation adapter that exists is OpenAI's and it authenticates with the
  same `OPENAI_API_KEY` as the chat adapter.

  Raises `ArgumentError` naming the provider when the active row has no
  moderation adapter. Only the OpenAI row has one, so the moderation scripts
  carry a `# Provider: openai` marker and `run_all.exs` skips them on the
  other arms rather than reaching this raise; see the moduledoc.

  `extra_opts` is merged on top of the helper defaults (`moderation_adapter:`
  and `model:` are baked in from the provider row; `ALLM_MODERATION_MODEL`
  overrides the default model when set).
  """
  def moderation_engine(extra_opts \\ []) do
    capability_engine(
      %{
        adapter_key: :moderation_adapter,
        model_key: :moderation_default_model,
        key_env_key: nil,
        model_env: "ALLM_MODERATION_MODEL",
        unavailable: "does not have a moderation_adapter; this script is OpenAI-only"
      },
      extra_opts
    )
  end

  # `image_engine/1`, `embedding_engine/1` and `moderation_engine/1` are one
  # constructor differing only in five values, so they share one body
  # (`agent-spec/IMPLEMENTATION.md:68` — the second-caller trigger is two
  # implementations and is semantic, not byte-level; `:235` requires every
  # existing copy migrate in the same commit). A fourth capability is a spec
  # map, not a fourth copy.
  #
  #   * `:adapter_key`  — provider-row key AND the `%ALLM.Engine{}` slot; the
  #     two are the same atom for all three capabilities today.
  #   * `:model_key`    — provider-row key for the capability's default model,
  #     which always lands on the engine's single shared `:model` field.
  #   * `:key_env_key`  — optional provider-row key naming a capability-specific
  #     key env var, falling back to the row's chat `:key_env`. Only embeddings
  #     uses it (the Anthropic row's `VOYAGE_API_KEY`); `nil` for the others.
  #   * `:model_env`    — env var that overrides the row's default model. Note
  #     `image_engine/1` reads the generic `ALLM_MODEL` while its two siblings
  #     read a capability-specific variable; that divergence predates this
  #     extraction and is preserved here rather than silently normalized.
  #   * `:unavailable`  — the `ArgumentError` tail, appended to the provider
  #     name. Carries its own article ("an image_adapter" vs "a
  #     moderation_adapter"), so each message stays byte-identical to the one
  #     its script's `# Provider:` marker documents.
  @doc """
  Prints `FAIL: <msg>` to stderr and halts with exit status 1.

  Scripts 19 and 20 each defined this closure locally; `agent-spec/IMPLEMENTATION.md`
  puts the extraction trigger at two implementations. Scripts 01-18 still inline
  the two statements at every branch — migrating them is a separate `[CHORE]`, not
  a reason to leave the third copy here.
  """
  @spec fail!(String.t()) :: no_return()
  def fail!(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  defp capability_engine(spec, extra_opts) do
    provider = active_provider()
    row = lookup_provider_row()

    adapter = Map.get(row, spec.adapter_key)
    default_model = Map.get(row, spec.model_key)

    key_env =
      (spec.key_env_key && Map.get(row, spec.key_env_key)) || Map.fetch!(row, :key_env)

    if is_nil(adapter) or is_nil(default_model) do
      raise ArgumentError, "#{provider} #{spec.unavailable}"
    end

    ensure_adapter_loaded!(adapter)
    ensure_key_present!(key_env)

    model = System.get_env(spec.model_env, default_model)

    base = [{spec.adapter_key, adapter}, {:model, model}]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
  end

  defp active_provider do
    load_dotenv()
    System.get_env("ALLM_PROVIDER", "openai")
  end

  # Load .env from the project root if present — no-op when keys are already in env.
  #
  # `:env_loader` is `only: [:dev]` and `mix run examples/…` runs in `:dev`, so
  # the dep is available here. `test/allm/examples_helpers_test.exs` loads this
  # file via `Code.require_file/1` under `MIX_ENV=test`, where the module is
  # absent — hence `apply/3` rather than a direct `EnvLoader.load/1` call, which
  # the compiler flags as an undefined remote function regardless of the
  # `Code.ensure_loaded?/1` guard (that check is purely syntactic on the call
  # site). Mirrors the guard in `scripts/record_*_embeddings_fixtures.exs`.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if Code.ensure_loaded?(EnvLoader) and File.exists?(path) do
      apply(EnvLoader, :load, [path])
    end

    :ok
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
