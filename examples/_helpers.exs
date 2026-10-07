defmodule ExamplesHelpers do
  @moduledoc """
  Provider-neutral engine constructors for the runnable example scripts under
  `examples/`. Reads `ALLM_PROVIDER` env (default `"openai"`), looks up the
  adapter + default model + key env var name from the `@providers` table, and
  returns a configured `%ALLM.Engine{}` for use in any script.

  Seven constructors are exposed:

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
    * `speech_engine/1` — text-to-speech engine; reads `:speech_adapter` /
      `:speech_model` and sets the engine's `:speech_model` field, not
      `:model`. Raises `ArgumentError` for providers without a speech
      adapter, which today is every provider except OpenAI and ElevenLabs.
    * `transcription_engine/1` — speech-to-text engine; reads
      `:transcription_adapter` / `:transcription_model` and sets the
      engine's `:transcription_model` field. Raises `ArgumentError` for
      Anthropic, which has no transcription adapter.
    * `classification_engine/1` — typed-classification engine; reads
      `:classification_adapter` / `:classification_default_model` and sets
      the engine's `:classification_model` field, not `:model`. Raises
      `ArgumentError` for every provider except TypeSafe.

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

  ## Why the audio rows differ

  OpenAI has both a text-to-speech and a speech-to-text endpoint, so its row
  carries both audio adapters. Gemini's row carries only a transcription
  adapter: Gemini text-to-speech works but is not bundled yet. Anthropic ships
  no audio endpoint in either direction, so both of its audio adapters are
  `nil`. The ElevenLabs row carries both audio adapters and nothing else.
  Each audio script's `# Provider:` marker names the arms it can run on, and
  `run_all.exs` skips it on the others.

  The OpenAI and ElevenLabs rows also carry `:speech_voice`, read with
  `speech_voice/0`, because voices are provider strings: OpenAI's are names
  (`"alloy"`), ElevenLabs' are ids.

  ## The capability-only arms

  Two rows have `adapter: nil`, because the provider has no chat adapter: a
  capability-only arm (audio: `elevenlabs`; classification: `typesafe`).
  `chat_provider?/1` is `false` for both, and `run_all.exs` runs a script
  without a `# Provider:` marker (the chat, vision, embedding and tool
  scripts) only on a chat arm, so each of these arms runs only the scripts
  whose marker names it — the audio scripts on `elevenlabs`, the classify
  script on `typesafe`.

  The audio and classification engines set the slot's own model field
  (`:speech_model`, `:transcription_model`, `:classification_model`) rather
  than `:model`, because `ALLM.synthesize/3`, `ALLM.transcribe/3` and
  `ALLM.classify/3` never read the chat model.

  ## Why only the TypeSafe row has a classification adapter

  Typed classification is a single-provider capability: no chat provider
  offers it through a dedicated endpoint, and faking it with a chat model's
  structured output would invent probabilities rather than report calibrated
  ones. So every other row carries `classification_adapter: nil`, and the
  classify script carries `# Provider: typesafe`.

  Auto-loads a project-root `.env` via `:env_loader` (dev-only dep) so reviewers
  who keep both `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` in `.env` don't have to
  export them per script.
  """

  # Per-provider rows. The optional `:default_temperature` field (Phase 16.6 /
  # Decision #20) lets a provider opt out of the OpenAI/Anthropic-friendly
  # `temperature: 0` baseline; Google explicitly recommends `1.0` for Gemini 3.
  # Rows that omit the key inherit the `0` default in `engine/1` — caller
  # `temperature:` overrides still win.
  #
  # The optional `:zero_temperature_models` field lists model-name prefixes
  # that accept `temperature: 0`. When a row carries it, any other model gets
  # NO `temperature` param (the provider default applies). Claude Opus 4.7+
  # and every Claude 5.x model 400 on `temperature: 0` ("`temperature` is
  # deprecated for this model") while accepting the default `1` — live-probed
  # 2026-10-06. An allowlist, not a denylist, so a newer model defaults to
  # omitting the param rather than to a 400.
  @providers %{
    "openai" => %{
      adapter: ALLM.Providers.OpenAI,
      default_model: "gpt-5.4-nano",
      vision_default_model: "gpt-4o-mini",
      key_env: "OPENAI_API_KEY",
      image_adapter: ALLM.Providers.OpenAI.Images,
      image_default_model: "gpt-image-1",
      embed_adapter: ALLM.Providers.OpenAI.Embeddings,
      embedding_default_model: "text-embedding-3-small",
      moderation_adapter: ALLM.Providers.OpenAI.Moderation,
      moderation_default_model: "omni-moderation-latest",
      speech_adapter: ALLM.Providers.OpenAI.Speech,
      speech_model: "gpt-4o-mini-tts",
      speech_voice: "alloy",
      transcription_adapter: ALLM.Providers.OpenAI.Transcription,
      transcription_model: "gpt-transcribe",
      # Typed classification is TypeSafe-only — see the moduledoc.
      classification_adapter: nil,
      classification_default_model: nil
    },
    "anthropic" => %{
      adapter: ALLM.Providers.Anthropic,
      default_model: "claude-sonnet-4-6",
      vision_default_model: "claude-haiku-4-5-20251001",
      key_env: "ANTHROPIC_API_KEY",
      zero_temperature_models:
        ~w(claude-opus-4-6 claude-sonnet-4-6 claude-sonnet-4-5 claude-haiku-4-5),
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
      moderation_default_model: nil,
      # Anthropic ships no audio endpoint in either direction — see the
      # moduledoc. `speech_engine/1` and `transcription_engine/1` raise here.
      speech_adapter: nil,
      speech_model: nil,
      transcription_adapter: nil,
      transcription_model: nil,
      classification_adapter: nil,
      classification_default_model: nil
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
      moderation_default_model: nil,
      # Gemini transcription is bundled; Gemini text-to-speech is not (yet) —
      # see the moduledoc. `speech_engine/1` raises here.
      speech_adapter: nil,
      speech_model: nil,
      transcription_adapter: ALLM.Providers.Gemini.Transcription,
      transcription_model: "gemini-flash-latest",
      classification_adapter: nil,
      classification_default_model: nil
    },
    # ElevenLabs is an audio-only arm: there is no chat, image, embedding or
    # moderation adapter, so `adapter: nil` and `chat_provider?/1` is false.
    # `run_all.exs` runs only the scripts whose `# Provider:` marker names
    # elevenlabs. `key_env` is still required: `capability_engine/2` reads it.
    "elevenlabs" => %{
      adapter: nil,
      default_model: nil,
      vision_default_model: nil,
      key_env: "ELEVENLABS_API_KEY",
      image_adapter: nil,
      image_default_model: nil,
      embed_adapter: nil,
      embedding_default_model: nil,
      moderation_adapter: nil,
      moderation_default_model: nil,
      speech_adapter: ALLM.Providers.ElevenLabs.Speech,
      speech_model: "eleven_flash_v2_5",
      # ElevenLabs voices are ids, not names. This is the adapter's own
      # default voice, confirmed live.
      speech_voice: "JBFqnCBsd6RMkjVDRZzb",
      transcription_adapter: ALLM.Providers.ElevenLabs.Transcription,
      transcription_model: "scribe_v2",
      classification_adapter: nil,
      classification_default_model: nil
    },
    # TypeSafe is a classification-only arm: Jev is a classification model,
    # not a chat model, so `adapter: nil` and `chat_provider?/1` is false.
    # `run_all.exs` runs only the scripts whose `# Provider:` marker names
    # typesafe. `key_env` is still required: `capability_engine/2` reads it.
    "typesafe" => %{
      adapter: nil,
      default_model: nil,
      vision_default_model: nil,
      key_env: "TYPESAFE_API_KEY",
      image_adapter: nil,
      image_default_model: nil,
      embed_adapter: nil,
      embedding_default_model: nil,
      moderation_adapter: nil,
      moderation_default_model: nil,
      speech_adapter: nil,
      speech_model: nil,
      transcription_adapter: nil,
      transcription_model: nil,
      classification_adapter: ALLM.Providers.TypeSafe.Classification,
      # An alias that moves; set ALLM_CLASSIFICATION_MODEL to pin a version.
      classification_default_model: "jev-latest"
    }
  }

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's chat adapter.

  `extra_opts` is a keyword list merged on top of the helper defaults; pass
  `tools:`, `tool_executor:`, `tool_result_encoder:`, `params:`, etc. for
  per-script customization. The defaults set `tool_executor:`,
  `tool_result_encoder:`, and `params:` from `default_params/2` (normally
  `%{temperature: 0}`).
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
    base = [
      adapter: adapter,
      model: model,
      tool_executor: ALLM.ToolExecutor.Default,
      tool_result_encoder: ALLM.ToolResultEncoder.JSON,
      params: default_params(row, model)
    ]

    ALLM.Engine.new(merge_with_params(base, extra_opts))
  end

  # The row's baseline `params:` for `model`: `%{temperature: t}` with the
  # row's `:default_temperature` (absent → `0`), or `%{}` when the row has a
  # `:zero_temperature_models` allowlist that `model` is not on. Public test
  # seam — `engine/1` needs a live key.
  @doc false
  def default_params(row, model) do
    case Map.get(row, :zero_temperature_models) do
      nil ->
        %{temperature: Map.get(row, :default_temperature, 0)}

      prefixes ->
        if Enum.any?(prefixes, &String.starts_with?(model, &1)),
          do: %{temperature: Map.get(row, :default_temperature, 0)},
          else: %{}
    end
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
        engine_model_field: :model,
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
        engine_model_field: :model,
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
        engine_model_field: :model,
        key_env_key: nil,
        model_env: "ALLM_MODERATION_MODEL",
        unavailable: "does not have a moderation_adapter; this script is OpenAI-only"
      },
      extra_opts
    )
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's speech (text-to-speech)
  adapter.

  Reads `:speech_adapter` / `:speech_model` from the provider row and puts the
  model on the engine's `:speech_model` field, never on `:model` —
  `ALLM.synthesize/3` does not read the chat model. The key comes from the
  row's chat `:key_env`.

  Raises `ArgumentError` naming the provider when the active row has no speech
  adapter. Only the OpenAI and ElevenLabs rows have one, so the speech
  scripts carry a `# Provider:` marker naming those arms and `run_all.exs`
  skips them on the others.

  `extra_opts` is merged on top of the helper defaults; `ALLM_SPEECH_MODEL`
  overrides the default model when set.
  """
  def speech_engine(extra_opts \\ []) do
    capability_engine(
      %{
        adapter_key: :speech_adapter,
        model_key: :speech_model,
        engine_model_field: :speech_model,
        key_env_key: nil,
        model_env: "ALLM_SPEECH_MODEL",
        unavailable: "does not have a speech_adapter; this script runs on openai and elevenlabs"
      },
      extra_opts
    )
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's transcription
  (speech-to-text) adapter.

  Reads `:transcription_adapter` / `:transcription_model` from the provider row
  and puts the model on the engine's `:transcription_model` field, never on
  `:model`. The key comes from the row's chat `:key_env`.

  Raises `ArgumentError` naming the provider when the active row has no
  transcription adapter (Anthropic). The transcription scripts carry a
  `# Provider:` marker that leaves Anthropic out, so `run_all.exs` skips them
  there.

  `extra_opts` is merged on top of the helper defaults;
  `ALLM_TRANSCRIPTION_MODEL` overrides the default model when set.
  """
  def transcription_engine(extra_opts \\ []) do
    capability_engine(
      %{
        adapter_key: :transcription_adapter,
        model_key: :transcription_model,
        engine_model_field: :transcription_model,
        key_env_key: nil,
        model_env: "ALLM_TRANSCRIPTION_MODEL",
        unavailable: "does not have a transcription_adapter; this script cannot run on that arm"
      },
      extra_opts
    )
  end

  @doc """
  Build a `%ALLM.Engine{}` for the active provider's typed-classification
  adapter.

  Reads `:classification_adapter` / `:classification_default_model` from the
  provider row and puts the model on the engine's `:classification_model`
  field, never on `:model` — `ALLM.classify/3` does not read the chat model.
  The key comes from the row's `:key_env`.

  Raises `ArgumentError` naming the provider when the active row has no
  classification adapter, which today is every provider except TypeSafe. The
  classify script carries `# Provider: typesafe`, so `run_all.exs` skips it on
  the other arms rather than reaching this raise.

  `extra_opts` is merged on top of the helper defaults;
  `ALLM_CLASSIFICATION_MODEL` overrides the default model when set.
  """
  def classification_engine(extra_opts \\ []) do
    capability_engine(
      %{
        adapter_key: :classification_adapter,
        model_key: :classification_default_model,
        engine_model_field: :classification_model,
        key_env_key: nil,
        model_env: "ALLM_CLASSIFICATION_MODEL",
        unavailable: "does not have a classification_adapter; this script is TypeSafe-only"
      },
      extra_opts
    )
  end

  @doc """
  Whether `provider` (default: the active `ALLM_PROVIDER`) has a chat
  adapter. `run_all.exs` runs a script without a `# Provider:` marker only
  when this is `true`. Raises `ArgumentError` for an unknown provider.
  """
  @spec chat_provider?(String.t()) :: boolean()
  def chat_provider?(provider \\ active_provider()) do
    case Map.fetch(@providers, provider) do
      {:ok, row} ->
        not is_nil(row.adapter)

      :error ->
        raise ArgumentError,
              "Unknown ALLM_PROVIDER #{inspect(provider)}; legal: " <>
                inspect(Map.keys(@providers))
    end
  end

  @doc """
  The active provider row's default speech voice (`:speech_voice`), or `nil`
  when the row has none.
  """
  @spec speech_voice() :: String.t() | nil
  def speech_voice, do: Map.get(lookup_provider_row(), :speech_voice)

  # Test seam: the provider table, for `test/allm/examples_helpers_test.exs`.
  @doc false
  def provider_rows, do: @providers

  # `image_engine/1`, `embedding_engine/1`, `moderation_engine/1`,
  # `speech_engine/1`, `transcription_engine/1` and `classification_engine/1`
  # are one constructor
  # differing only in a handful of values, so they share one body
  # (`agent-spec/IMPLEMENTATION.md:68` — the second-caller trigger is two
  # implementations and is semantic, not byte-level; `:235` requires every
  # existing copy migrate in the same commit). A new capability is a spec
  # map, not a new copy.
  #
  #   * `:adapter_key`  — provider-row key AND the `%ALLM.Engine{}` slot; the
  #     two are the same atom for every capability today.
  #   * `:model_key`    — provider-row key for the capability's default model.
  #   * `:engine_model_field` — the `%ALLM.Engine{}` field the model lands on.
  #     Images, embeddings and moderation pass the shared `:model`, which is
  #     what their façades read. The audio and classification capabilities
  #     pass `:speech_model` / `:transcription_model` / `:classification_model`,
  #     because their façades never read `:model` (a chat model name is never
  #     an audio or classification model name).
  #   * `:key_env_key`  — provider-row key naming a capability-specific
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

  # Exit status a script uses to report that it skipped itself. `run_all.exs`
  # maps it to a `[SKIP]` summary line, so a self-skip is never reported as
  # `[OK]` and never counts as a failure.
  @skip_exit_status 3

  @doc """
  The exit status `skip!/1` halts with; `run_all.exs` reads it to tell a
  self-skip from a pass.
  """
  @spec skip_exit_status() :: pos_integer()
  def skip_exit_status, do: @skip_exit_status

  @doc """
  Prints `SKIP: <msg>` and halts with `skip_exit_status/0`. For a script
  that cannot run on this arm for a reason its `# Provider:` marker cannot
  express (a second provider's key is absent). `run_all.exs` reports it as
  `[SKIP] <script> (self-skipped)` rather than `[OK]`.
  """
  @spec skip!(String.t()) :: no_return()
  def skip!(msg) do
    IO.puts("SKIP: " <> msg)
    System.halt(@skip_exit_status)
  end

  @doc """
  Reads a mono 16-bit PCM WAV and returns `{sample_rate, pcm_bytes}`.

  A `data` chunk size of `0xFFFFFFFF` ("unknown length", as in a
  *streaming* WAV such as `fixtures/quick_brown_fox.wav`) means the data
  runs to the end of the file. Any other format raises `MatchError`.
  """
  @spec read_pcm_wav!(Path.t()) :: {pos_integer(), binary()}
  def read_pcm_wav!(path) do
    <<"RIFF", _riff_size::little-32, "WAVE", chunks::binary>> = File.read!(path)
    walk_wav(chunks, nil)
  end

  defp walk_wav(<<"fmt ", size::little-32, fmt::binary-size(size), rest::binary>>, _rate) do
    <<1::little-16, 1::little-16, rate::little-32, _::binary>> = fmt
    walk_wav(rest, rate)
  end

  defp walk_wav(<<"data", 0xFFFFFFFF::little-32, pcm::binary>>, rate) when is_integer(rate),
    do: {rate, pcm}

  defp walk_wav(<<"data", size::little-32, pcm::binary-size(size), _::binary>>, rate)
       when is_integer(rate),
       do: {rate, pcm}

  defp walk_wav(<<_id::binary-4, size::little-32, rest::binary>>, rate) do
    <<_skipped::binary-size(size + rem(size, 2)), rest::binary>> = rest
    walk_wav(rest, rate)
  end

  @doc """
  Splits mono 16-bit `pcm` at `rate` Hz into chunks of `ms` milliseconds.
  A trailing partial chunk is dropped.
  """
  @spec pcm_chunks(binary(), pos_integer(), pos_integer()) :: [binary()]
  def pcm_chunks(pcm, rate, ms) do
    size = div(rate * 2 * ms, 1000)
    for <<chunk::binary-size(size) <- pcm>>, do: chunk
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

    base = [{spec.adapter_key, adapter}, {spec.engine_model_field, model}]

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
