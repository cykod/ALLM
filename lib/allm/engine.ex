defmodule ALLM.Engine do
  @moduledoc """
  Layer-B runtime engine — the composition point for an adapter, declared
  tools, and default request params/context.

  An engine is a plain struct carrying only modules, atoms, and serializable
  plain data (no PIDs, refs, funs, or API keys). Call sites merge per-call
  overrides via the `resolve_*` functions: **call opts win over engine
  defaults**.

  ## Building an engine

  The deterministic `ALLM.Providers.Fake` adapter requires no API key:

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "Hi"}, {:finish, :stop}]]
      ...>)
      iex> engine.adapter
      ALLM.Providers.Fake

  Swap `ALLM.Providers.Fake` for `ALLM.Providers.OpenAI`,
  `ALLM.Providers.Anthropic`, or `ALLM.Providers.Gemini` and pass `:model`
  to use a real provider. API keys resolve through `ALLM.Keys`.

  ## Serializability

  Engines are safe to round-trip through `:erlang.term_to_binary/1` and JSON
  **iff** every field carries only modules, atoms, or plain serializable data:

    * `:id` — `integer() | nil`. A plain positive integer
      (`System.unique_integer([:positive])`) auto-stamped by `new/1`, or
      `nil` for a hand-built `%Engine{}`. Round-trips natively through both
      ETF and JSON. `__from_tagged__/1` restores it verbatim (no
      re-stamping); a pre-fix serialized engine lacking `"id"` decodes to
      `nil`. Used as the per-engine cursor key for the deterministic
      `ALLM.Providers.Fake` / `ALLM.Providers.FakeImages` adapters (§31).
    * `:adapter`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter`
      `module | nil`. Modules are restored on JSON decode via
      `String.to_existing_atom/1`; an adapter module not loaded in the BEAM
      at decode time surfaces as `{:_unknown, :atom_decode_failed}` via the
      `ALLM.Serializer.from_json/1` error path (`[:adapter] :module_not_loaded`
      in the field-error vocabulary).
    * `:adapter_opts` — keyword list of serializable values only. A keyword
      list containing a fun (e.g. a Finch retry callback) is rejected by
      the JSON encoder (`Protocol.UndefinedError` from Jason). Atom **values**
      in the kwlist (e.g. `adapter_opts: [mode: :strict]`) survive ETF but
      lose type on JSON round-trip (become binaries) — the decoder restores
      kwlist *keys* via `String.to_existing_atom/1` but passes *values*
      through verbatim. This is the same caller-value asymmetry as
      `:params`/`:context`/`:metadata` below; callers whose adapter opts
      rely on atom values for provider behaviour (e.g. `verify: :peer`)
      should convert at the adapter boundary rather than expect round-trip
      equality through JSON. The same rule applies to kwlist-shaped `:retry`.
    * `:model` — `String.t | nil`.
    * `:tools` — `[ALLM.Tool.t]` where each tool's `:handler` is `nil` or
      `{Module, :function}`. A tool with an anonymous-function handler is not
      JSON-serializable (see `ALLM.Tool` moduledoc). Each tool's `:manual`
      flag (boolean, default `false`) controls per-tool opt-out of
      auto-execution: when `manual: true`, `ALLM.chat/3` under `mode:
      :auto` halts with `:manual_tool_calls` instead of running the
      handler.
    * `:params`, `:context`, `:metadata` — maps of serializable values whose
      keys are restored as atoms via `String.to_existing_atom/1` on JSON
      decode. Values pass through verbatim — the library does not deep-type
      caller-supplied data. Non-stdlib struct values (e.g. `DateTime`,
      `Decimal`) survive ETF round-trip but lose type on JSON decode unless
      the caller supplies a custom decoder; this asymmetry is by design.
    * `:retry` — `:default | false | keyword`.
    * `:middleware` — `[]` today; reserved for a later version.

  Unknown opts keys that are not in the engine-field deny-list are
  forwarded to the adapter unchanged via `resolve_params/2` — this is
  how provider-specific knobs like `:reasoning_effort` reach the adapter
  without the resolver having to know about them.
  """

  alias ALLM.Tool

  @type retry :: :default | false | keyword()

  @typedoc """
  Late-resolved model value returned by `resolve_model/2`. A bare string,
  a provider-tagged tuple, a struct (typically `%ALLM.ModelRef{}` when
  the optional `LLMDB` catalog is loaded — spec §6.3), or `nil` when the
  engine has no model and no override was passed.
  """
  @type resolved_model :: String.t() | tuple() | struct() | nil

  @type t :: %__MODULE__{
          id: integer() | nil,
          adapter: module() | nil,
          adapter_opts: keyword(),
          model: String.t() | nil,
          tools: [Tool.t()],
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          image_adapter: module() | nil,
          params: map(),
          context: map(),
          retry: retry(),
          middleware: [module()],
          metadata: map()
        }

  defstruct [
    :id,
    :adapter,
    :model,
    :tool_executor,
    :tool_result_encoder,
    :image_adapter,
    adapter_opts: [],
    tools: [],
    params: %{},
    context: %{},
    retry: :default,
    middleware: [],
    metadata: %{}
  ]

  # Engine struct field keys — any key in this list is excluded from the
  # opts merged by `resolve_params/2` (Non-obvious decision #5). Provider-
  # specific and orchestration opts (not in this list) flow through
  # unchanged per spec §10. `:params` is in the list because it is itself
  # the map that `resolve_params/2` merges *into* — it's consumed by
  # `merge_opts/2`, never forwarded — and the 2.4 integration test
  # (Scenario 3) surfaced its prior omission as a correctness gap.
  @engine_field_keys [
    :adapter,
    :adapter_opts,
    :model,
    :tools,
    :tool_executor,
    :tool_result_encoder,
    :image_adapter,
    :params,
    :context,
    :retry,
    :middleware,
    :metadata,
    :api_key
  ]

  @doc """
  Build an `%ALLM.Engine{}` from keyword opts.

  Accepts any subset of the documented struct fields; unknown keys raise
  `KeyError` via `struct!/2`. `:adapter` may be `nil` at construction — the
  missing-adapter check fires at adapter-call time (surfaces as
  `%EngineError{reason: :missing_adapter}`), not here.

  A stable, serializable `:id` is auto-stamped via
  `System.unique_integer([:positive])` when none is supplied — this is the
  per-engine identity used as the `Fake`/`FakeImages` multi-call cursor key
  (see §31). Because every constructed engine gets a distinct id,
  `Engine.new(opts) != Engine.new(opts)` by `:id` — each constructed engine
  *is* a distinct instance. An explicitly-passed `id:` opt is preserved
  (supports deterministic reconstruction). Derived engines built via
  struct-update (`with_model/2`, `merge_opts/2`, `put_tool/2`, …) keep the
  same `:id` — correct for "same engine, reconfigured"; use `new/1` when you
  need two independent multi-call engines.

  ## Examples

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake, model: "fake:m")
      iex> engine.adapter
      ALLM.Providers.Fake
      iex> engine.model
      "fake:m"
      iex> engine.tools
      []
      iex> is_integer(engine.id) and engine.id > 0
      true
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    engine = struct!(__MODULE__, opts)
    %{engine | id: engine.id || System.unique_integer([:positive])}
  end

  @doc false
  # Inject the engine's `:id` as `adapter_opts[:cursor_key]` so content-equal
  # engines don't share the `Fake`/`FakeImages` process-dict cursor (§31).
  # `Keyword.put_new/3` — an explicit caller-supplied `:cursor_key` wins;
  # a `nil`-id (hand-built) engine passes through untouched and falls back to
  # the `:erlang.phash2(scripts)` default. Provider-neutral: real adapters
  # read only named `adapter_opts` keys, so `:cursor_key` is an inert no-op.
  @spec put_cursor_key(keyword(), t()) :: keyword()
  def put_cursor_key(adapter_opts, %__MODULE__{id: nil}) when is_list(adapter_opts),
    do: adapter_opts

  def put_cursor_key(adapter_opts, %__MODULE__{id: id}) when is_list(adapter_opts),
    do: Keyword.put_new(adapter_opts, :cursor_key, id)

  @doc """
  Append a single tool to the engine's `:tools` list.

  Naive append — does **not** dedup by `:name`. Use `merge_opts/2` or
  `resolve_tools/2` when you need opts-win dedup semantics for per-call
  overrides.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "echo", description: "echo", schema: %{})
      iex> engine = ALLM.Engine.new() |> ALLM.Engine.put_tool(tool)
      iex> Enum.map(engine.tools, & &1.name)
      ["echo"]
  """
  @spec put_tool(t(), Tool.t()) :: t()
  def put_tool(%__MODULE__{tools: tools} = e, %Tool{} = tool),
    do: %{e | tools: tools ++ [tool]}

  @doc """
  Append multiple tools to the engine's `:tools` list.

  Naive append (`engine.tools ++ more`) — does **not** dedup by `:name`. Use
  `merge_opts/2` for per-call override semantics that replace an engine tool
  in place when names collide.

  ## Examples

      iex> a = ALLM.Tool.new(name: "a", description: "a", schema: %{})
      iex> b = ALLM.Tool.new(name: "b", description: "b", schema: %{})
      iex> engine = ALLM.Engine.new() |> ALLM.Engine.put_tools([a, b])
      iex> Enum.map(engine.tools, & &1.name)
      ["a", "b"]
  """
  @spec put_tools(t(), [Tool.t()]) :: t()
  def put_tools(%__MODULE__{tools: existing} = e, more),
    do: %{e | tools: existing ++ more}

  @doc """
  Set a single entry in the engine's `:params` map.

  Keys may be atoms or strings — adapters decide which form they accept at
  wire time.

  ## Examples

      iex> engine = ALLM.Engine.new() |> ALLM.Engine.put_param(:temperature, 0.7)
      iex> engine.params
      %{temperature: 0.7}
  """
  @spec put_param(t(), atom() | String.t(), term()) :: t()
  def put_param(%__MODULE__{params: p} = e, key, value),
    do: %{e | params: Map.put(p, key, value)}

  @doc """
  Set a single entry in the engine's `:context` map.

  `:context` is opaque to the library; tool handlers receive it as the second
  argument when declared with arity 2.

  ## Examples

      iex> engine = ALLM.Engine.new() |> ALLM.Engine.put_context(:user_id, 42)
      iex> engine.context
      %{user_id: 42}
  """
  @spec put_context(t(), atom() | String.t(), term()) :: t()
  def put_context(%__MODULE__{context: c} = e, key, value),
    do: %{e | context: Map.put(c, key, value)}

  @doc """
  Replace the engine's `:model` string.

  ## Examples

      iex> engine = ALLM.Engine.new(model: "old") |> ALLM.Engine.with_model("new")
      iex> engine.model
      "new"
  """
  @spec with_model(t(), String.t()) :: t()
  def with_model(%__MODULE__{} = e, model), do: %{e | model: model}

  @doc """
  Compose per-call overrides into the engine struct, returning a new engine.

  Convenience helper — `merge_opts/2` is **not** a primitive of the resolver
  chain; execution functions typically use `resolve_model/2`,
  `resolve_tools/2`, and `resolve_params/2` directly rather than rebuilding
  an engine. `merge_opts/2` is useful when you want a single engine value
  reflecting per-call overrides (e.g. for telemetry or for passing into a
  pre-built helper).

  Recognized opt keys:

    * `:model` — replaces `engine.model` via `with_model/2`.
    * `:tools` — dedup-by-name merge via `resolve_tools/2` (this does
      **not** call `put_tools/2`, which is naive append).
    * `:params` — shallow-merge into `engine.params`. The value **must be
      a map**; a non-map value (e.g., a keyword list) is silently dropped,
      because `engine.params` is itself a map and the merge target is not
      defined for other shapes.
    * `:context` — shallow-merge into `engine.context`. Same map-only
      rule as `:params`.

  Any other opts key is silently dropped — unknown keys are for execution
  functions, not the engine itself.

  Total on valid input: given any `%ALLM.Engine{}` and any keyword list,
  `merge_opts/2` returns an `%ALLM.Engine{}` and does not raise.

  ## Examples

      iex> a = ALLM.Tool.new(name: "a", description: "a", schema: %{})
      iex> b = ALLM.Tool.new(name: "b", description: "b", schema: %{})
      iex> engine = ALLM.Engine.new(model: "old") |> ALLM.Engine.put_tool(a)
      iex> merged = ALLM.Engine.merge_opts(engine, model: "new", tools: [b], params: %{temperature: 0.9})
      iex> merged.model
      "new"
      iex> Enum.map(merged.tools, & &1.name)
      ["a", "b"]
      iex> merged.params
      %{temperature: 0.9}
  """
  @spec merge_opts(t(), keyword()) :: t()
  def merge_opts(%__MODULE__{} = engine, opts) when is_list(opts) do
    engine
    |> maybe_put_model(opts)
    |> maybe_put_tools(opts)
    |> maybe_merge_params(opts)
    |> maybe_merge_context(opts)
  end

  @doc """
  Resolve the effective model for an adapter call.

  Reads `opts[:model]` if present, otherwise falls back to `engine.model`.
  When the optional `LLMDB` model-catalog module is loaded in the BEAM,
  delegates to `LLMDB.model/1` on the chosen value so the caller can
  receive a catalog-backed model ref; when absent (the default), returns
  the value verbatim. Core ALLM functions without the catalog.

  ## Examples

      iex> engine = ALLM.Engine.new(model: "fake:m")
      iex> ALLM.Engine.resolve_model(engine, [])
      "fake:m"
      iex> ALLM.Engine.resolve_model(engine, model: "override")
      "override"
      iex> ALLM.Engine.resolve_model(ALLM.Engine.new(model: {:openai, "gpt-x"}), [])
      {:openai, "gpt-x"}
  """
  @spec resolve_model(t(), keyword()) :: resolved_model()
  def resolve_model(%__MODULE__{} = engine, opts) when is_list(opts) do
    chosen = Keyword.get(opts, :model) || engine.model

    # `Module.concat(["LLMDB"])` produces the `LLMDB` atom at runtime
    # without the compiler tracing it as a hard reference — required because
    # :llm_db is an optional dep. When absent, `Code.ensure_loaded?/1`
    # returns false and we pass the chosen value through verbatim.
    #
    # Note: the `Module.concat/1` ban inside the Serializer's JSON decoder
    # (where the argument is caller-controlled JSON input and unbounded
    # atom creation is an atom-table exhaustion vector) does not apply
    # here — the argument is a compile-time literal string list, so only
    # the single `LLMDB` atom is ever produced.
    catalog = Module.concat(["LLMDB"])

    if Code.ensure_loaded?(catalog) do
      catalog.model(chosen)
    else
      chosen
    end
  end

  @doc """
  Resolve the effective tool list for an adapter call using dedup-by-name
  semantics.

  The result preserves `engine.tools` order; each engine tool whose `:name`
  matches a tool in `opts[:tools]` is replaced **in place** by the matching
  opts tool. Opts tools whose `:name` doesn't match any engine tool are
  appended in `opts[:tools]` order. Example: `engine.tools = [a, b, c]`,
  `opts[:tools] = [b', d]` → `[a, b', c, d]`.

  When `opts` has no `:tools` key, returns `engine.tools` unchanged.

  ## Examples

      iex> a = ALLM.Tool.new(name: "a", description: "a", schema: %{})
      iex> b = ALLM.Tool.new(name: "b", description: "b", schema: %{})
      iex> c = ALLM.Tool.new(name: "c", description: "c", schema: %{})
      iex> b_prime = ALLM.Tool.new(name: "b", description: "override", schema: %{})
      iex> d = ALLM.Tool.new(name: "d", description: "d", schema: %{})
      iex> engine = ALLM.Engine.new() |> ALLM.Engine.put_tools([a, b, c])
      iex> ALLM.Engine.resolve_tools(engine, tools: [b_prime, d]) |> Enum.map(& &1.name)
      ["a", "b", "c", "d"]
  """
  @spec resolve_tools(t(), keyword()) :: [Tool.t()]
  def resolve_tools(%__MODULE__{tools: engine_tools}, opts) when is_list(opts) do
    case Keyword.fetch(opts, :tools) do
      :error ->
        engine_tools

      {:ok, opts_tools} ->
        dedup_tools(engine_tools, opts_tools)
    end
  end

  @doc """
  Resolve the effective params map for an adapter call via a shallow merge
  of `engine.params` with `opts` filtered by the engine-field deny-list.

  Returned as a **map** (not a keyword list). Engine-field keys
  (`:adapter`, `:adapter_opts`, `:model`, `:tools`, `:tool_executor`,
  `:tool_result_encoder`, `:image_adapter`, `:params`, `:context`,
  `:retry`, `:middleware`, `:metadata`, `:api_key`) are never forwarded
  they are consumed by the engine layer or by other resolvers. Every
  other opts key flows through unchanged, so provider-specific knobs
  (`:reasoning_effort`) and orchestration knobs (`:max_turns`,
  `:halt_when`) naturally reach the adapter — unknown options in `opts`
  are forwarded to the adapter unchanged.

  ## Examples

      iex> engine = ALLM.Engine.new(params: %{temperature: 0.2, top_p: 1.0})
      iex> ALLM.Engine.resolve_params(engine, temperature: 0.7)
      %{temperature: 0.7, top_p: 1.0}
      iex> ALLM.Engine.resolve_params(engine, model: "x", reasoning_effort: "high")
      %{temperature: 0.2, top_p: 1.0, reasoning_effort: "high"}
  """
  @spec resolve_params(t(), keyword()) :: map()
  def resolve_params(%__MODULE__{params: engine_params}, opts) when is_list(opts) do
    opts_map =
      opts
      |> Enum.reject(fn {k, _v} -> k in @engine_field_keys end)
      |> Map.new()

    Map.merge(engine_params, opts_map)
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      # Plain pass-through — NO re-stamping on decode, or round-trip equality
      # breaks. A pre-fix engine map lacking "id" decodes to id: nil
      # (backward compatible; falls back to the phash2 cursor default).
      id: data["id"],
      adapter: restore_module(data["adapter"]),
      adapter_opts: restore_keyword(data["adapter_opts"] || []),
      model: data["model"],
      tools: restore_tools(data["tools"] || []),
      tool_executor: restore_module(data["tool_executor"]),
      tool_result_encoder: restore_module(data["tool_result_encoder"]),
      image_adapter: restore_module(data["image_adapter"]),
      params: restore_atom_keyed_map(data["params"] || %{}),
      context: restore_atom_keyed_map(data["context"] || %{}),
      retry: restore_retry(data["retry"]),
      middleware: data["middleware"] || [],
      metadata: restore_atom_keyed_map(data["metadata"] || %{})
    }
  end

  # --- private helpers -------------------------------------------------------

  # Restore a module-typed field. `nil` stays `nil`; a binary is converted
  # via `String.to_existing_atom/1`, which raises `ArgumentError` on an
  # unloaded module. `ALLM.Serializer.hydrate_with/2` rescues that raise
  # and converts it to `{:_unknown, :atom_decode_failed}` per the field-
  # error vocabulary (§Error Contract). `Module.concat/1` is deliberately
  # NOT used here — it would silently create a phantom atom from caller-
  # controlled JSON input, which is the atom-table exhaustion vector the
  # 2.3 design explicitly bans.
  @spec restore_module(binary() | nil) :: module() | nil
  defp restore_module(nil), do: nil
  defp restore_module(value) when is_binary(value), do: String.to_existing_atom(value)

  # Restore a keyword list. The JSON encoder in this module emits keyword
  # lists as JSON arrays of 2-element `[key, value]` arrays; each key is
  # restored via `String.to_existing_atom/1`. An empty list (the struct
  # default) is returned as-is.
  @spec restore_keyword(list()) :: keyword()
  defp restore_keyword(list) when is_list(list) do
    Enum.map(list, fn [k, v] when is_binary(k) -> {String.to_existing_atom(k), v} end)
  end

  # Restore each tool via `ALLM.Tool.__from_tagged__/1`. The JSON encoder
  # emits tagged wrappers (`%{"__type__" => ..., "data" => ...}`) per
  # `ALLM.Serializer.encode_tagged/2`; unwrap before delegating.
  @spec restore_tools(list()) :: [Tool.t()]
  defp restore_tools(tools) when is_list(tools) do
    Enum.map(tools, fn %{"__type__" => _, "data" => data} when is_map(data) ->
      Tool.__from_tagged__(data)
    end)
  end

  # Restore an atom-keyed map from a JSON-decoded string-keyed map. Keys go
  # through `String.to_existing_atom/1`; values pass through verbatim.
  @spec restore_atom_keyed_map(map()) :: map()
  defp restore_atom_keyed_map(map) when is_map(map) do
    Map.new(map, fn {k, v} when is_binary(k) -> {String.to_existing_atom(k), v} end)
  end

  # `:retry` is one of `:default | false | keyword()`. JSON encodes
  # `:default` as the string `"default"`, `false` as a JSON boolean, and
  # a keyword list as a JSON array of [key, value] pairs.
  @spec restore_retry(term()) :: retry()
  defp restore_retry(false), do: false
  defp restore_retry("default"), do: :default
  defp restore_retry(list) when is_list(list), do: restore_keyword(list)

  @spec maybe_put_model(t(), keyword()) :: t()
  defp maybe_put_model(engine, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, m} -> with_model(engine, m)
      :error -> engine
    end
  end

  @spec maybe_put_tools(t(), keyword()) :: t()
  defp maybe_put_tools(engine, opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, _} -> %{engine | tools: resolve_tools(engine, opts)}
      :error -> engine
    end
  end

  @spec maybe_merge_params(t(), keyword()) :: t()
  defp maybe_merge_params(engine, opts) do
    case Keyword.fetch(opts, :params) do
      {:ok, params} when is_map(params) ->
        %{engine | params: Map.merge(engine.params, params)}

      _ ->
        engine
    end
  end

  @spec maybe_merge_context(t(), keyword()) :: t()
  defp maybe_merge_context(engine, opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, ctx} when is_map(ctx) ->
        %{engine | context: Map.merge(engine.context, ctx)}

      _ ->
        engine
    end
  end

  # Dedup-by-name merge: preserve engine order, replace colliding engine
  # tools in place with opts versions, append opts-only tools in order.
  @spec dedup_tools([Tool.t()], [Tool.t()]) :: [Tool.t()]
  defp dedup_tools(engine_tools, opts_tools) do
    opts_by_name = Map.new(opts_tools, fn %Tool{name: n} = t -> {n, t} end)

    replaced =
      Enum.map(engine_tools, fn %Tool{name: n} = t ->
        Map.get(opts_by_name, n, t)
      end)

    engine_names = MapSet.new(engine_tools, & &1.name)
    appended = Enum.reject(opts_tools, fn %Tool{name: n} -> MapSet.member?(engine_names, n) end)

    replaced ++ appended
  end
end

defimpl Jason.Encoder, for: ALLM.Engine do
  # `:adapter_opts` and keyword-list-shaped `:retry` carry raw tuples that
  # Jason can't encode directly. Transform them to list-of-pairs
  # (`[[k, v], [k, v]]`) before delegating; the decoder
  # (`ALLM.Engine.__from_tagged__/1`) rebuilds keyword lists from either
  # shape. Every other engine field is plain map/binary/atom/number data
  # that `encode_tagged/2` handles natively.
  def encode(%ALLM.Engine{} = value, opts) do
    transformed = %{
      value
      | adapter_opts: keyword_to_pairs(value.adapter_opts),
        retry: transform_retry(value.retry)
    }

    ALLM.Serializer.encode_tagged(transformed, opts)
  end

  defp keyword_to_pairs(kw) when is_list(kw) do
    Enum.map(kw, fn {k, v} -> [k, v] end)
  end

  defp transform_retry(kw) when is_list(kw), do: keyword_to_pairs(kw)
  defp transform_retry(other), do: other
end
