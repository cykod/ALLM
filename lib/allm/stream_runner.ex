defmodule ALLM.StreamRunner do
  @moduledoc """
  Internal — use `ALLM.stream_generate/3` instead. See spec §17.

  Validates the request, resolves model/tools/params via `ALLM.Engine`,
  dispatches to the engine adapter's `stream/2`, and applies per-§19
  post-filters and the `:on_event` observer.

  ## Phase 7 opts are stripped

  Phase 7 orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are
  deny-listed here and NOT forwarded to the adapter — `stream_generate/3`
  is single-request, so they would be no-ops or (in the case of
  `:halt_when`) a `Protocol.UndefinedError` trap at the Jason-encode
  boundary of real providers. `Logger.debug/1` fires for each stripped
  key so power users can see the drop during development.

  ## No double-wrapped `Stream.resource/3`

  The adapter owns the streaming resource and its cleanup hook; this
  module only composes `Stream.each/2` (for `:on_event`) and
  `Stream.filter/2` (for the three emit/include filters) on top. Both
  operators propagate `{:halt, _}` upstream, which is what preserves the
  halt-safety contract from Phase 4.

  ## `:on_event` failure mode

  `:on_event` is invoked lazily by `Stream.each/2` inside the consumer's
  reducing process — an exception raised by the callback surfaces there,
  not at the `stream_generate/3` call site. This module does not wrap the
  callback in `try/rescue`; callers who need resilience wrap their own
  callback.
  """

  require Logger

  alias ALLM.{Engine, Request, Validate}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  # Phase 7 orchestration opts — stripped before reaching the adapter.
  @phase_7_opts [:mode, :max_turns, :halt_when]

  # Phase 5 streaming-layer opts — read directly from opts by this module,
  # not forwarded to the adapter as params.
  @phase_5_layer_opts [:emit_text_deltas, :emit_tool_deltas, :include_raw_chunks, :on_event]

  @doc """
  Dispatch a streaming request. Validates, resolves params, forwards to
  `engine.adapter.stream/2`, and wires the per-§19 post-processing
  pipeline.

  Returns `{:ok, stream}` on a successfully-opened stream (lazy — no
  event fires until the caller reduces) or `{:error, struct}` on a
  synchronous pre-flight failure.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
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
    with :ok <- check_adapter(engine),
         :ok <- check_stream_adapter(engine.adapter),
         :ok <- Validate.request(request) do
      dispatch(engine, request, opts)
    end
  end

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
    opts = strip_phase_7_opts(opts)
    final_request = resolve_request_model(engine, request, opts)
    dispatch_opts = build_dispatch_opts(engine, opts)

    engine.adapter.stream(final_request, dispatch_opts)
    |> post_process(opts)
  end

  # Strip the Phase 7 opts from the keyword list, logging each dropped key.
  defp strip_phase_7_opts(opts) do
    Enum.reduce(@phase_7_opts, opts, &maybe_strip_key/2)
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
    Logger.debug(fn -> "[ALLM.StreamRunner] stripped Phase 7 opt: #{inspect(key)}" end)
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

    adapter_opts =
      engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, [])

    Keyword.put(params_kw, :adapter_opts, adapter_opts)
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
