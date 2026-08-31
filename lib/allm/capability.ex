defmodule ALLM.Capability do
  @moduledoc """
  Layer-B optional model-catalog integration via the `LLMDB` Hex package.

  Six helpers, all gated on `Code.ensure_loaded?(LLMDB)`:

    * `preflight/2` (and `/3`) — pre-flights tool / `response_format`
      capability against the catalog's `%ALLM.ModelRef{}` and surfaces a
      `%ALLM.Error.ValidationError{reason: :unsupported_capability}`
      before the adapter sees a request it can't satisfy.
    * `preflight_image/2` — sister of `preflight/3` for
      `ALLM.ImageRequest`: rejects requests against models with
      `images_enabled: false` or whose `supported_image_operations` does
      not include the requested op.
    * `preflight_embedding/2` — sister of `preflight/3` for
      `ALLM.EmbeddingRequest`: rejects requests against models with
      `embeddings_enabled: false` or whose `:dimensions` exceeds the
      catalog's `dimensions_max`.
    * `preflight_moderation/2` — sister of `preflight_embedding/2` for
      `ALLM.ModerationRequest`: rejects requests against models with
      `moderation_enabled: false`. One rule, not two — moderation has no
      numeric knob a catalog could cap.
    * `populate_costs/2` — fills `Usage.{input_cost, output_cost,
      total_cost}` from the catalog's per-million-token pricing after the
      adapter has reported token counts.
    * `select/1` — delegates to `LLMDB.select/1` for capability-based model
      selection (`require:` / `prefer:`).

  ## Why this is integration-by-detection, not a Hex dep

  `mix.exs` does NOT list `:llm_db` as a dep. ALLM detects the catalog
  at runtime via `Code.ensure_loaded?(Module.concat(["LLMDB"]))`.
  Application users who want capability pre-flight and cost population
  add `:llm_db` to their own `mix.exs`; ALLM picks it up automatically.
  Tests use a fake compiled only in `:test` that mimics the
  published-package surface verbatim.

  ## What pre-flight rejects

  Two rules in v0.2:

    * **Tools against a tools-disabled model** — `request.tools != []` AND
      `model_ref.capabilities.tools.enabled == false`.
    * **`response_format: %{type: :json_schema, ...}` against a
      non-`json_native` model** — `model_ref.capabilities.json_native ==
      false`.

  `:json_object` is the soft-capability carve-out — it does NOT require a
  structured-output schema enforcer; pre-flight does NOT reject
  `:json_object` requests against a non-`json_native` model (graceful
  degradation, not an error).

  Both rejections accumulate when both fire; the resulting
  `%ValidationError{}` carries two field-error tuples in `:errors`.

  ## JSON-rehydrated `%ModelRef{}` tolerance (Finding #1)

  `ALLM.ModelRef`'s opaque map fields (`:capabilities`, `:limits`,
  `:pricing`, `:metadata`) are documented as Layer-A-asymmetric: ETF
  round-trip is byte-identical, but JSON round-trip preserves only the
  outer struct shape — nested map keys come back as STRINGS (matching
  `ALLM.Engine`'s `:metadata` carve-out). Rather than restoring atoms
  in `ModelRef.__from_tagged__/1` (which would require a closed
  capability-key allowlist and tighten the surface), the consumer is
  made tolerant: `check_tools/3` and `check_json_native/3` pattern-match
  on **both** atom-keyed (`%{tools: %{enabled: false}}`) and
  string-keyed (`%{"tools" => %{"enabled" => false}}`) shapes so a
  rehydrated ref pre-flights identically to an in-process one.

  ## Where pre-flight runs

  Wired into `ALLM.StreamRunner.run/3`'s `with`-chain after
  `ALLM.Validate.request/1` and after `Engine.resolve_model/2` (the
  resolved model is passed to `preflight/2`). `Runner.run/3` delegates to
  `StreamRunner.run/3`, so the wire-up appears once. For multi-turn
  `ALLM.Chat` paths, pre-flight runs once at the first adapter call
  the model doesn't change mid-conversation.

  ## Cost units

  Pricing is per-million-tokens (the `llm_db` convention). Math:
  `input_cost = pricing.input * input_tokens /
  1_000_000`. `total_cost` is computed only when both `input_cost` and
  `output_cost` are populated. `populate_costs/2` NEVER overwrites a
  non-nil cost field; it only fills `nil`.
  """

  alias ALLM.EmbeddingRequest
  alias ALLM.Error.ValidationError
  alias ALLM.ImagePart
  alias ALLM.ImageRequest
  alias ALLM.Message
  alias ALLM.ModelRef
  alias ALLM.ModerationRequest
  alias ALLM.Request
  alias ALLM.Usage

  @typedoc """
  Result of a pre-flight capability check. Three shapes:

    * `:ok` — no rewrite needed, no rejection. The caller dispatches the
      original request unchanged.
    * `{:ok, %Request{}}` — pre-flight rewrote the request (e.g. set
      `structured_finalize: true`); the caller MUST dispatch the returned
      request, not the original.
    * `{:error, %ValidationError{}}` — pre-flight rejected the request;
      the caller MUST surface the error and not dispatch.
  """
  @type preflight_result :: :ok | {:ok, Request.t()} | {:error, ValidationError.t()}

  @typedoc "Either a resolved `%ModelRef{}` from the catalog, a raw model string/tuple, or `nil`."
  @type model_ref_or_string :: ModelRef.t() | String.t() | tuple() | nil

  @doc """
  Return `true` when the optional `LLMDB` catalog module is loaded into the
  BEAM AND the test override (`Application.put_env(:allm,
  :force_capability_absent, true)`) is NOT set.

  The override seam exists for the dep-free smoke test:
  `:code.delete/1` + `:code.purge/1` does NOT work because
  `test/support/llm_db.ex` re-loads from `_build` on the next
  `Code.ensure_loaded?/1`; the application-env override is the reliable
  simulator.

  Use the `Module.concat(["LLMDB"])` idiom to keep the dep optional
  the literal-string-list argument produces a single atom at runtime
  with no compile-time reference (the same pattern as
  `ALLM.Engine.resolve_model/2` at `lib/allm/engine.ex:301-304`).

  ## Examples

      iex> is_boolean(ALLM.Capability.catalog_loaded?())
      true
  """
  @spec catalog_loaded?() :: boolean()
  def catalog_loaded? do
    if Application.get_env(:allm, :force_capability_absent, false) == true do
      false
    else
      Code.ensure_loaded?(Module.concat(["LLMDB"]))
    end
  end

  @doc """
  Pre-flight a request against the catalog's view of a model.

  ## Three return shapes

    * `:ok` — no rewrite needed, no rejection. Caller dispatches the
      original request unchanged. Returned when the catalog is absent,
      when the model is a bare string/tuple/`nil` (no capability info),
      or when no rejection rule fires AND no rewrite predicate matches.
    * `{:ok, %Request{}}` — pre-flight rewrote the request. The current
      rewrite is `structured_finalize: true` (auto-set when the adapter's
      `requires_structured_finalize?/1` returns `true` for a request that
      combines tools and a `json_schema` response_format). Caller MUST
      dispatch the returned request.
    * `{:error, %ValidationError{reason: :unsupported_capability, errors: [...]}}`
      — pre-flight rejected the request. Both rejection rules accumulate
      in `:errors` when both fire.

  ## Adapter argument (optional)

  The third argument carries the adapter module so pre-flight can call
  `function_exported?(adapter, :requires_structured_finalize?, 1)` to
  decide the rewrite. Defaults to `nil` (no rewrite) so existing 2-arg
  callers continue to work — the rewrite branch only fires when the
  caller threads the adapter through. `requires_structured_finalize?/1`
  is a regular module function, NOT a `@callback`, so most adapters do
  not export it.

  ## Examples

      iex> ALLM.Capability.preflight("openai:gpt-4.1-mini", ALLM.request([ALLM.user("hi")]))
      :ok

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :local, id: "no-tools",
      ...> capabilities: %{tools: %{enabled: false}, json_native: true}
      ...>)
      iex> tool = ALLM.Tool.new(name: "echo", description: "x", schema: %{})
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], tools: [tool])
      iex> {:error, err} = ALLM.Capability.preflight(ref, req)
      iex> err.reason
      :unsupported_capability
      iex> err.errors
      [{[:tools], :tools_disabled}]
  """
  @spec preflight(model_ref_or_string(), Request.t(), module() | nil) :: preflight_result()
  def preflight(model_ref_or_string, %Request{} = request, adapter \\ nil) do
    cond do
      not catalog_loaded?() ->
        maybe_structured_finalize_rewrite(:ok, request, adapter)

      not is_struct(model_ref_or_string, ModelRef) ->
        maybe_structured_finalize_rewrite(:ok, request, adapter)

      true ->
        model_ref_or_string
        |> check_capabilities(request)
        |> maybe_structured_finalize_rewrite(request, adapter)
    end
  end

  # Phase 10.4 — auto-set `structured_finalize: true` when the adapter
  # exports `requires_structured_finalize?/1` AND it returns `true` for
  # this request. Idempotent: if the request already carries
  # `structured_finalize: true` we keep `:ok` (no-op rewrite). Errors
  # pass through unchanged. See spec §5.4 and design Decision #2.
  defp maybe_structured_finalize_rewrite({:error, _} = err, _request, _adapter), do: err

  defp maybe_structured_finalize_rewrite(:ok, %Request{structured_finalize: true}, _adapter),
    do: :ok

  defp maybe_structured_finalize_rewrite(:ok, %Request{} = request, adapter)
       when is_atom(adapter) and not is_nil(adapter) do
    if Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :requires_structured_finalize?, 1) and
         adapter.requires_structured_finalize?(request) == true do
      {:ok, %Request{request | structured_finalize: true}}
    else
      :ok
    end
  end

  defp maybe_structured_finalize_rewrite(:ok, _request, _adapter), do: :ok

  @typedoc "Two-shape result of `preflight_image/2` (no rewrite branch)."
  @type image_preflight_result :: :ok | {:error, ValidationError.t()}

  @doc """
  Pre-flight an `ALLM.ImageRequest` against the catalog's view of a
  model — sister of `preflight/3`, narrower contract.

  Returns `:ok | {:error, %ValidationError{reason: :unsupported_capability}}`
  only — there is no `{:ok, %ImageRequest{}}` rewrite branch. 2-arity by
  design — symmetric with `populate_costs/2`, NOT with `preflight/3`.

  ## Rejection rules (both accumulate when both fire)

    * `{[:images_enabled], :images_disabled}` — fires when
      `model_ref.capabilities.images_enabled == false`.
    * `{[:operation], :unsupported_image_operation}` — fires when
      `request.operation not in model_ref.capabilities.supported_image_operations`.

  Tolerates JSON-rehydrated `%ModelRef{}` with string-keyed
  capabilities (`%{"images_enabled" => false, "supported_image_operations" => ["generate"]}`)
  per the existing pattern in `check_tools/3` / `check_json_native/3`.

  Returns `:ok` early when the catalog is absent
  (`catalog_loaded?/0 == false`) or when `model_ref_or_string` is a bare
  string / tuple / `nil` (no capability info).

  ## Examples

      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel")
      iex> ALLM.Capability.preflight_image("openai:gpt-image-1", req)
      :ok

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :local, id: "no-images",
      ...> capabilities: %{images_enabled: false, supported_image_operations: []}
      ...>)
      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel")
      iex> {:error, err} = ALLM.Capability.preflight_image(ref, req)
      iex> err.reason
      :unsupported_capability
      iex> err.errors
      [{[:images_enabled], :images_disabled}, {[:operation], :unsupported_image_operation}]
  """
  @spec preflight_image(model_ref_or_string(), ImageRequest.t()) :: image_preflight_result()
  def preflight_image(model_ref_or_string, %ImageRequest{} = request) do
    cond do
      not catalog_loaded?() ->
        :ok

      not is_struct(model_ref_or_string, ModelRef) ->
        :ok

      true ->
        check_image_capabilities(model_ref_or_string, request)
    end
  end

  @typedoc "Two-shape result of `preflight_embedding/2` (no rewrite branch)."
  @type embedding_preflight_result :: :ok | {:error, ValidationError.t()}

  @doc """
  Pre-flight an `ALLM.EmbeddingRequest` against the catalog's view of a
  model — sister of `preflight_image/2`, same narrow contract.

  Returns `:ok | {:error, %ValidationError{reason: :unsupported_capability}}`
  only — there is no rewrite branch. 2-arity by design, symmetric with
  `preflight_image/2` and `populate_costs/2`, NOT with `preflight/3`.

  ## Rejection rules (both accumulate when both fire)

    * `{[:embeddings_enabled], :embeddings_disabled}` — fires when
      `model_ref.capabilities.embeddings_enabled == false`.
    * `{[:dimensions], :exceeds_max}` — fires when `request.dimensions` is
      set and exceeds `model_ref.capabilities.dimensions_max`.

  A missing key is never a rejection, per the module-wide
  graceful-degradation rule, and both rules tolerate JSON-rehydrated
  `%ModelRef{}` values with string-keyed capabilities.

  The per-model dimension cap lives here rather than in
  `ALLM.Validate.embedding_request/1` because it is model-specific catalog
  data the validator does not have. Without a catalog both rules are inert
  and an over-large `:dimensions` reaches the provider, earning a 400 that
  maps to `:invalid_request` — the intended degradation.

  Returns `:ok` early when the catalog is absent
  (`catalog_loaded?/0 == false`) or when `model_ref_or_string` is a bare
  string / tuple / `nil` (no capability info).

  ## Examples

      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> ALLM.Capability.preflight_embedding("openai:text-embedding-3-small", req)
      :ok

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :local, id: "no-embeddings",
      ...> capabilities: %{embeddings_enabled: false}
      ...>)
      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> {:error, err} = ALLM.Capability.preflight_embedding(ref, req)
      iex> err.reason
      :unsupported_capability
      iex> err.errors
      [{[:embeddings_enabled], :embeddings_disabled}]
  """
  @spec preflight_embedding(model_ref_or_string(), EmbeddingRequest.t()) ::
          embedding_preflight_result()
  def preflight_embedding(model_ref_or_string, %EmbeddingRequest{} = request) do
    cond do
      not catalog_loaded?() ->
        :ok

      not is_struct(model_ref_or_string, ModelRef) ->
        :ok

      true ->
        check_embedding_capabilities(model_ref_or_string, request)
    end
  end

  @typedoc "Two-shape result of `preflight_moderation/2` (no rewrite branch)."
  @type moderation_preflight_result :: :ok | {:error, ValidationError.t()}

  @doc """
  Pre-flight an `ALLM.ModerationRequest` against the catalog's view of a
  model — sister of `preflight_embedding/2`, same narrow contract.

  Returns `:ok | {:error, %ValidationError{reason: :unsupported_capability}}`
  only — there is no rewrite branch. 2-arity by design, symmetric with
  `preflight_image/2`, `preflight_embedding/2` and `populate_costs/2`, NOT
  with `preflight/3`.

  ## Rejection rule (there is exactly one)

    * `{[:moderation_enabled], :moderation_disabled}` — fires when
      `model_ref.capabilities.moderation_enabled == false`.

  The embeddings sibling's second rule (`dimensions_max`) has no moderation
  analogue: moderation has no numeric knob a catalog could cap, so nothing
  accumulates and the error list is always one element long. A missing key
  is never a rejection, per the module-wide graceful-degradation rule, and
  the rule tolerates JSON-rehydrated `%ModelRef{}` values with string-keyed
  capabilities.

  Nothing here reads the *request*: the request is taken for family symmetry
  (and so a future request-shaped rule needs no signature change), and a
  multimodal request is gated identically to an all-strings one.

  Returns `:ok` early when the catalog is absent
  (`catalog_loaded?/0 == false`) or when `model_ref_or_string` is a bare
  string / tuple / `nil` (no capability info).

  ## Examples

      iex> req = ALLM.ModerationRequest.new(input: ["is this ok?"])
      iex> ALLM.Capability.preflight_moderation("openai:omni-moderation-latest", req)
      :ok

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :local, id: "no-moderation",
      ...> capabilities: %{moderation_enabled: false}
      ...>)
      iex> req = ALLM.ModerationRequest.new(input: ["is this ok?"])
      iex> {:error, err} = ALLM.Capability.preflight_moderation(ref, req)
      iex> err.reason
      :unsupported_capability
      iex> err.errors
      [{[:moderation_enabled], :moderation_disabled}]
  """
  @spec preflight_moderation(model_ref_or_string(), ModerationRequest.t()) ::
          moderation_preflight_result()
  def preflight_moderation(model_ref_or_string, %ModerationRequest{} = request) do
    cond do
      not catalog_loaded?() ->
        :ok

      not is_struct(model_ref_or_string, ModelRef) ->
        :ok

      true ->
        check_moderation_capabilities(model_ref_or_string, request)
    end
  end

  @doc """
  Populate `Usage.{input_cost, output_cost, total_cost}` from
  `model_ref.pricing` (per-million-token rates).

  Returns the input usage unchanged when the catalog is absent, when the
  model is a bare string/tuple/`nil`, or when `model_ref.pricing == nil`.
  Partial population is allowed: when `:input_tokens` is `nil`,
  `:input_cost` stays `nil`; `:output_cost` can still populate from
  `:output_tokens`. `:total_cost` is populated only when both partial
  costs are present. NEVER overwrites a non-nil cost field — only fills
  `nil`.

  ## Examples

      iex> ref = ALLM.ModelRef.new(provider: :openai, id: "x", pricing: %{input: 0.15, output: 0.6})
      iex> usage = %ALLM.Usage{input_tokens: 1000, output_tokens: 500}
      iex> populated = ALLM.Capability.populate_costs(usage, ref)
      iex> populated.input_cost
      1.5e-4
      iex> populated.output_cost
      3.0e-4
      iex> populated.total_cost
      4.5e-4
  """
  @spec populate_costs(Usage.t(), model_ref_or_string()) :: Usage.t()
  def populate_costs(%Usage{} = usage, model_ref_or_string) do
    cond do
      not catalog_loaded?() -> usage
      not is_struct(model_ref_or_string, ModelRef) -> usage
      is_nil(model_ref_or_string.pricing) -> usage
      true -> apply_pricing(usage, model_ref_or_string.pricing)
    end
  end

  @doc """
  Delegate to `LLMDB.select/1` for capability-based model selection.

  Returns `LLMDB.select(criteria)` when the catalog is loaded; returns
  `{:error, :catalog_not_loaded}` (atom shape, not a struct — the only
  `:error` shape this module produces with an atom reason) otherwise.

  ## Examples

      iex> match?({:error, :catalog_not_loaded}, ALLM.Capability.select(require: [:tools])) or
      ...> match?({:ok, _}, ALLM.Capability.select(require: [:tools])) or
      ...> match?({:error, _}, ALLM.Capability.select(require: [:tools]))
      true
  """
  @spec select(keyword()) ::
          {:ok, ModelRef.t()} | {:error, :catalog_not_loaded | :no_match | term()}
  def select(criteria) when is_list(criteria) do
    if catalog_loaded?() do
      Module.concat(["LLMDB"]).select(criteria)
    else
      {:error, :catalog_not_loaded}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — shared capability-flag rule
  # ---------------------------------------------------------------------------

  # The single rejection rule behind all four boolean capability flags:
  # `:vision` (`check_vision/3`), `:images_enabled` (`check_images_enabled/2`),
  # `:embeddings_enabled` (`check_embeddings_enabled/2`) and
  # `:moderation_enabled` (`check_moderation_enabled/2`). The error atom is
  # mechanically derivable from the capability atom in all four, so the
  # capability key plus the error atom are the only axes.
  #
  # Extracted at the FOURTH copy (Phase 22.3 fix pass) per
  # `agent-spec/IMPLEMENTATION.md`'s promotion trigger, with every call site
  # migrated in the same commit per CLAUDE.md's migration-on-extraction rule.
  # Private, behaviour-preserving, no public name changed.
  #
  # Tolerates a JSON-rehydrated %ModelRef{} with string-keyed capabilities
  # (see @moduledoc "JSON-rehydrated %ModelRef{} tolerance"): atom-keyed
  # (in-process) and string-keyed (post-Jason round-trip) both reject, and a
  # missing key is "no info", never a rejection.
  #
  # `check_json_native/3` is deliberately NOT a call site: its error path is
  # `[:response_format]` while its capability key is `:json_native`, so the
  # `[key]` path this helper builds does not hold there. `check_tools/3` reads
  # a nested `%{enabled: false}` map and does not fit either.
  defp reject_when_flag_false(acc, caps, key, error_reason) when is_atom(key) do
    string_key = Atom.to_string(key)

    case caps do
      %{^key => false} -> [{[key], error_reason} | acc]
      %{^string_key => false} -> [{[key], error_reason} | acc]
      _ -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # Private — preflight checks
  # ---------------------------------------------------------------------------

  defp check_capabilities(%ModelRef{} = ref, %Request{} = request) do
    errors =
      []
      |> check_tools(ref, request)
      |> check_json_native(ref, request)
      |> check_vision(ref, request)
      |> Enum.reverse()

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:unsupported_capability, list,
           message: "model does not support requested capabilities"
         )}
    end
  end

  defp check_tools(acc, %ModelRef{capabilities: caps}, %Request{tools: tools})
       when is_list(tools) and tools != [] do
    # Tolerate JSON-rehydrated %ModelRef{} with string-keyed capabilities
    # (see @moduledoc "JSON-rehydrated %ModelRef{} tolerance"). Atom-keyed
    # nested map (in-process) and string-keyed (post-Jason round-trip) both
    # reject. Anything else passes.
    case caps do
      %{tools: %{enabled: false}} -> [{[:tools], :tools_disabled} | acc]
      %{"tools" => %{"enabled" => false}} -> [{[:tools], :tools_disabled} | acc]
      _ -> acc
    end
  end

  defp check_tools(acc, _ref, _req), do: acc

  defp check_json_native(acc, %ModelRef{capabilities: caps}, %Request{
         response_format: %{type: :json_schema}
       }) do
    # Tolerate JSON-rehydrated %ModelRef{} with string-keyed capabilities
    # (see @moduledoc "JSON-rehydrated %ModelRef{} tolerance").
    case caps do
      %{json_native: false} -> [{[:response_format], :json_native_disabled} | acc]
      %{"json_native" => false} -> [{[:response_format], :json_native_disabled} | acc]
      _ -> acc
    end
  end

  defp check_json_native(acc, _ref, _req), do: acc

  # Phase 17.1 — vision capability gate (§35.6, design Decision #5).
  # Fires when the request contains any %ImagePart{} AND the resolved
  # model's capabilities map says `vision: false` (atom-keyed) or
  # `"vision" => false` (string-keyed JSON-rehydrated). When the catalog
  # has no `:vision` key at all, no-op (graceful degradation matches the
  # `:tools_disabled` precedent).
  defp check_vision(acc, %ModelRef{capabilities: caps}, %Request{messages: messages}) do
    if request_has_image_part?(messages) do
      reject_when_flag_false(acc, caps, :vision, :vision_disabled)
    else
      acc
    end
  end

  defp request_has_image_part?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %Message{content: content} when is_list(content) ->
        Enum.any?(content, &match?(%ImagePart{}, &1))

      _ ->
        false
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — image preflight (Phase 14.3)
  # ---------------------------------------------------------------------------

  defp check_image_capabilities(%ModelRef{} = ref, %ImageRequest{} = request) do
    errors =
      []
      |> check_images_enabled(ref)
      |> check_supported_image_operation(ref, request)
      |> Enum.reverse()

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:unsupported_capability, list,
           message: "model does not support requested image capabilities"
         )}
    end
  end

  defp check_images_enabled(acc, %ModelRef{capabilities: caps}),
    do: reject_when_flag_false(acc, caps, :images_enabled, :images_disabled)

  defp check_supported_image_operation(acc, %ModelRef{capabilities: caps}, %ImageRequest{
         operation: op
       }) do
    # Tolerate string-keyed capabilities and string-encoded atoms (the
    # JSON encoder for capability lists emits `["generate"]` from
    # `[:generate]`).
    case caps do
      %{supported_image_operations: ops} when is_list(ops) ->
        if op in ops, do: acc, else: [{[:operation], :unsupported_image_operation} | acc]

      %{"supported_image_operations" => ops} when is_list(ops) ->
        if Atom.to_string(op) in ops or op in ops,
          do: acc,
          else: [{[:operation], :unsupported_image_operation} | acc]

      _ ->
        # No supported_image_operations key — don't reject (no info).
        acc
    end
  end

  # ---------------------------------------------------------------------------
  # Private — embedding preflight
  # ---------------------------------------------------------------------------

  defp check_embedding_capabilities(%ModelRef{} = ref, %EmbeddingRequest{} = request) do
    errors =
      []
      |> check_embeddings_enabled(ref)
      |> check_dimensions_max(ref, request)
      |> Enum.reverse()

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:unsupported_capability, list,
           message: "model does not support requested embedding capabilities"
         )}
    end
  end

  defp check_embeddings_enabled(acc, %ModelRef{capabilities: caps}),
    do: reject_when_flag_false(acc, caps, :embeddings_enabled, :embeddings_disabled)

  # A nil `:dimensions` requests the model's native dimensionality, which no
  # cap can exclude — short-circuit before reading the capability map.
  defp check_dimensions_max(acc, _ref, %EmbeddingRequest{dimensions: nil}), do: acc

  defp check_dimensions_max(acc, %ModelRef{capabilities: caps}, %EmbeddingRequest{dimensions: d}) do
    case caps do
      %{dimensions_max: m} when is_integer(m) and d > m -> [{[:dimensions], :exceeds_max} | acc]
      %{"dimensions_max" => m} when is_integer(m) and d > m -> [{[:dimensions], :exceeds_max} | acc]
      _ -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # Private — moderation preflight
  # ---------------------------------------------------------------------------

  # Accumulator shape kept even though exactly one rule exists today: a second
  # rule slots in as one more `|>` step, and `Enum.reverse/1` keeps the error
  # list in declaration order the moment there is more than one.
  defp check_moderation_capabilities(%ModelRef{} = ref, %ModerationRequest{}) do
    errors =
      []
      |> check_moderation_enabled(ref)
      |> Enum.reverse()

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:unsupported_capability, list,
           message: "model does not support requested moderation capabilities"
         )}
    end
  end

  defp check_moderation_enabled(acc, %ModelRef{capabilities: caps}),
    do: reject_when_flag_false(acc, caps, :moderation_enabled, :moderation_disabled)

  # ---------------------------------------------------------------------------
  # Private — cost math
  # ---------------------------------------------------------------------------

  defp apply_pricing(%Usage{} = usage, pricing) do
    # Tolerate JSON-rehydrated %ModelRef{} with string-keyed pricing
    # (see @moduledoc "JSON-rehydrated %ModelRef{} tolerance").
    input_rate = pricing[:input] || pricing["input"]
    output_rate = pricing[:output] || pricing["output"]
    input_cost = compute_cost(usage.input_cost, usage.input_tokens, input_rate)
    output_cost = compute_cost(usage.output_cost, usage.output_tokens, output_rate)

    total_cost =
      cond do
        not is_nil(usage.total_cost) -> usage.total_cost
        is_number(input_cost) and is_number(output_cost) -> input_cost + output_cost
        true -> nil
      end

    %{usage | input_cost: input_cost, output_cost: output_cost, total_cost: total_cost}
  end

  # Never overwrite an already-populated cost; only fill nil. When the
  # token count is nil OR the per-million rate is nil, leave at nil.
  defp compute_cost(existing, _tokens, _rate) when not is_nil(existing), do: existing

  defp compute_cost(_existing, tokens, rate) when is_integer(tokens) and is_number(rate),
    do: rate * tokens / 1_000_000

  defp compute_cost(_existing, _tokens, _rate), do: nil
end
