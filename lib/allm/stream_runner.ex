defmodule ALLM.StreamRunner do
  @moduledoc """
  > #### Internal {: .warning}
  >
  > This module is internal — it's documented for transparency, but
  > call sites should use `ALLM.stream_generate/3` instead.

  Validates the request, resolves model/tools/params via `ALLM.Engine`,
  dispatches to the engine adapter's `stream/2`, and applies the
  documented post-filters plus the `:on_event` observer.

  ## Orchestration opts are stripped

  Orchestration opts — `:mode`, `:max_turns`, `:halt_when` — are
  deny-listed here and NOT forwarded to the adapter.
  `stream_generate/3` is single-request, so they would be no-ops or (in
  the case of `:halt_when`) a `Protocol.UndefinedError` trap at the
  Jason-encode boundary of real providers. `Logger.debug/1` fires for
  each stripped key so power users can see the drop during
  development.

  ## No double-wrapped `Stream.resource/3`

  The adapter owns the streaming resource and its cleanup hook; this
  module only composes `Stream.each/2` (for `:on_event`) and
  `Stream.filter/2` (for the three emit/include filters) on top. Both
  operators propagate `{:halt, _}` upstream, which preserves the
  halt-safety contract.

  ## `:on_event` failure mode

  `:on_event` is invoked lazily by `Stream.each/2` inside the consumer's
  reducing process — an exception raised by the callback surfaces there,
  not at the `stream_generate/3` call site. This module does not wrap the
  callback in `try/rescue`; callers who need resilience wrap their own
  callback.
  """

  require Logger

  alias ALLM.{Capability, Engine, Request, Telemetry, Validate}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  # Orchestration opts — stripped before reaching the adapter.
  # `ALLM.Chat` consumes `:mode` upstream; StreamRunner's deny-list is
  # the safety-net that catches any unstripped orchestration key before
  # adapter dispatch.
  @orchestration_opts [:mode, :max_turns, :halt_when]

  # Streaming-layer opts — read directly from opts by this module, not
  # forwarded to the adapter as params. `:resolved_model` is the
  # late-resolved model threaded downstream for
  # `Capability.populate_costs/2`; `:request_id` is the
  # telemetry-correlation id, threaded into adapter_opts via
  # `maybe_put_request_id/2`.
  @phase_5_layer_opts [
    :emit_text_deltas,
    :emit_tool_deltas,
    :include_raw_chunks,
    :on_event,
    :resolved_model,
    :request_id
  ]

  @doc """
  Dispatch a streaming request. Validates, resolves params, forwards to
  `engine.adapter.stream/2`, and wires the post-processing pipeline.

  Returns `{:ok, stream}` on a successfully-opened stream (lazy — no
  event fires until the caller reduces) or `{:error, struct}` on a
  synchronous pre-flight failure.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...>)
      iex> req = ALLM.request([ALLM.user("say hi")])
      iex> {:ok, stream} = ALLM.StreamRunner.run(engine, req)
      iex> events = Enum.to_list(stream)
      iex> Enum.any?(events, &match?({:message_completed, _}, &1))
      true
  """
  @spec run(Engine.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(%Engine{} = engine, %Request{} = request, opts \\ []) when is_list(opts) do
    request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()
    opts = Keyword.put(opts, :request_id, request_id)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: request.model || engine.model
    }

    Telemetry.span(:stream, start_metadata, fn ->
      result = do_run(engine, request, opts)
      # Phase 9 design carve-out (review Finding #2): `:stop` metadata's
      # `:response` is intentionally `nil` for streaming spans — design
      # DoD line 737 lists `:response` for both `:generate` and `:stream`
      # spans, but materialising the wrapped enumerable inside the closure
      # to populate it here would force consumption before any consumer
      # reduces, defeating consumer-driven laziness. Streaming consumers
      # that need the canonical `%Response{}` should fold the stream
      # themselves via `ALLM.StreamCollector.to_response/1` (or
      # `ALLM.generate/3`, which does exactly this — its `:generate :stop`
      # span DOES carry `:response`). The `:request_id` on the span
      # metadata correlates the streaming `:stop` with any post-collection
      # response the consumer builds.
      {result, %{response: nil}}
    end)
  end

  defp do_run(%Engine{} = engine, %Request{} = request, opts) do
    with :ok <- check_adapter(engine),
         :ok <- check_stream_adapter(engine.adapter),
         :ok <- Validate.request(request),
         resolved_request <- resolve_request_model(engine, request, opts),
         {:ok, request} <-
           normalize_preflight(
             Capability.preflight(resolved_request.model, request, engine.adapter),
             request
           ) do
      # Thread the resolved model into opts so downstream consumers (the
      # Runner's cost-population step, Chat's stream_collector finalize)
      # can call `Capability.populate_costs/2` without re-resolving.
      opts = Keyword.put(opts, :resolved_model, resolved_request.model)
      # Pre-flight may have rewritten the request (Phase 10.4 —
      # `structured_finalize: true` auto-set); merge the rewrite back into
      # the resolved-request so dispatch sees both the rewrite AND the
      # late-resolved model.
      resolved_request = %{resolved_request | structured_finalize: request.structured_finalize}
      dispatch(engine, resolved_request, opts)
    end
  end

  # Phase 10.4 — collapse the widened `Capability.preflight/3` return into
  # a single `{:ok, request}` shape the `with` chain can rebind on. The
  # original request flows through when pre-flight returns `:ok`; the
  # rewritten request flows through when pre-flight returns
  # `{:ok, %Request{}}`. Errors pass through unchanged.
  defp normalize_preflight(:ok, %Request{} = request), do: {:ok, request}
  defp normalize_preflight({:ok, %Request{} = request}, _orig), do: {:ok, request}
  defp normalize_preflight({:error, _} = err, _orig), do: err

  # ---------------------------------------------------------------------------
  # Validation chain
  # ---------------------------------------------------------------------------

  defp check_adapter(%Engine{adapter: nil}),
    do:
      {:error,
       EngineError.new(:missing_adapter,
         message: "engine.adapter is nil; pass an adapter module to ALLM.Engine.new/1"
       )}

  defp check_adapter(%Engine{}), do: :ok

  defp check_stream_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream, 2) do
      :ok
    else
      {:error,
       EngineError.new(:missing_stream_adapter,
         message:
           "engine.adapter #{inspect(adapter)} does not export stream/2; " <>
             "use an adapter that implements ALLM.StreamAdapter"
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch + post-process
  # ---------------------------------------------------------------------------

  defp dispatch(%Engine{} = engine, %Request{} = request, opts) do
    opts = strip_orchestration_opts(opts)
    dispatch_opts = build_dispatch_opts(engine, opts)

    # `request` is already resolved (model attached) by `do_run/3`'s
    # hoisted `resolve_request_model/3` call (Phase 9.4 Decision #17).
    engine.adapter.stream(request, dispatch_opts)
    |> post_process(opts)
  end

  # Strip the orchestration opts from the keyword list, logging each dropped key.
  defp strip_orchestration_opts(opts) do
    Enum.reduce(@orchestration_opts, opts, &maybe_strip_key/2)
  end

  defp maybe_strip_key(key, acc) do
    if Keyword.has_key?(acc, key) do
      log_stripped(key)
      Keyword.delete(acc, key)
    else
      acc
    end
  end

  defp log_stripped(key) do
    Logger.debug(fn -> "[ALLM.StreamRunner] stripped orchestration opt: #{inspect(key)}" end)
  end

  # Resolve the request's model via `Engine.resolve_model/2` and attach it
  # to the request. `resolve_model/2` returns a string/tuple/struct/nil —
  # we set `request.model` to whatever it returns so the adapter sees the
  # late-resolved value.
  defp resolve_request_model(%Engine{} = engine, %Request{} = request, opts) do
    model_opts = if request.model, do: Keyword.put(opts, :model, request.model), else: opts
    resolved = Engine.resolve_model(engine, model_opts)
    %{request | model: resolved}
  end

  # Build the keyword list of opts forwarded to `engine.adapter.stream/2`.
  # Phase 5 streaming-layer opts (`:emit_*`, `:include_raw_chunks`,
  # `:on_event`) are consumed here and NOT forwarded. Engine-resolved params
  # (which already exclude engine-field keys per `resolve_params/2`'s
  # deny-list) flow through. `:adapter_opts` from the engine and from opts
  # are concatenated.
  defp build_dispatch_opts(%Engine{} = engine, opts) do
    # Remove the Phase 5-layer opts before we hand the rest to resolve_params.
    adapter_facing_opts = Keyword.drop(opts, @phase_5_layer_opts)

    params_map = Engine.resolve_params(engine, adapter_facing_opts)

    params_kw = params_map |> Map.to_list()

    # Inject the engine's `:id` as `adapter_opts[:cursor_key]` (§31) so
    # content-equal Fake engines don't share the process-dict cursor at the
    # façade. `Engine.put_cursor_key/2` is `Keyword.put_new/3` (caller-supplied
    # `:cursor_key` wins) and a no-op for `nil`-id engines. For real adapters
    # the key is still injected but inert — they read only named `adapter_opts`
    # keys and never splat the list onto the wire (Decision #2).
    adapter_opts =
      (engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, []))
      |> Engine.put_cursor_key(engine)

    params_kw
    |> Keyword.put(:adapter_opts, adapter_opts)
    |> maybe_put_request_id(opts)
    |> maybe_put_api_key(opts)
    |> Keyword.put(:retry, engine.retry)
  end

  defp maybe_put_request_id(kw, opts) do
    case Keyword.get(opts, :request_id) do
      nil -> kw
      id -> Keyword.put(kw, :request_id, id)
    end
  end

  # Forward a per-call `:api_key` opt to the adapter so SaaS BYOK callers
  # can pass tenant-scoped keys via `ALLM.generate(engine, req, api_key: ...)`.
  # The engine-field deny-list in `Engine.resolve_params/2` strips
  # `:api_key` from params (defensively, to keep keys out of the params
  # map); we re-inject it here as a top-level dispatch_opts key so
  # `ALLM.Keys.fetch!/2`'s level-1 `opts[:api_key]` lookup resolves it
  # before falling back to env var / config / store. Mirrors
  # `Keys.wrap/1`'s nil/empty-string defensive shape.
  defp maybe_put_api_key(kw, opts) do
    case Keyword.get(opts, :api_key) do
      nil -> kw
      "" -> kw
      key when is_binary(key) -> Keyword.put(kw, :api_key, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Post-processing: Stream.each(on_event) → Stream.filter(keep?)
  # ---------------------------------------------------------------------------

  defp post_process({:error, %AdapterError{}} = err, _opts), do: err
  defp post_process({:error, %EngineError{}} = err, _opts), do: err
  defp post_process({:error, %ValidationError{}} = err, _opts), do: err

  defp post_process({:ok, stream}, opts) do
    on_event = Keyword.get(opts, :on_event)
    filter_opts = filter_options(opts)

    stream
    |> maybe_each(on_event)
    |> Stream.filter(&keep?(&1, filter_opts))
    |> then(&{:ok, &1})
  end

  defp maybe_each(stream, nil), do: stream
  defp maybe_each(stream, fun) when is_function(fun, 1), do: Stream.each(stream, fun)

  defp filter_options(opts) do
    %{
      emit_text_deltas: Keyword.get(opts, :emit_text_deltas, true),
      emit_tool_deltas: Keyword.get(opts, :emit_tool_deltas, true),
      include_raw_chunks: Keyword.get(opts, :include_raw_chunks, false)
    }
  end

  # Usage raw chunks always survive, regardless of include_raw_chunks.
  defp keep?({:raw_chunk, {:usage, _}}, _opts), do: true

  defp keep?({:raw_chunk, _}, %{include_raw_chunks: include}), do: include

  defp keep?({:text_delta, _}, %{emit_text_deltas: emit}), do: emit

  defp keep?({:tool_call_delta, _}, %{emit_tool_deltas: emit}), do: emit

  defp keep?(_event, _opts), do: true
end
