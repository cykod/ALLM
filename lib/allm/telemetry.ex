defmodule ALLM.Telemetry do
  @moduledoc """
  Internal — Layer B helper that wraps `:telemetry.span/3` with
  ALLM-specific metadata defaults.

  Phase 9.1 wires this around every public Layer-C entry point
  (`generate`, `stream_generate`, `step`, `stream_step`, `chat`, `stream`)
  so callers can attach `:telemetry.attach_many/4` handlers to
  `[:allm, :generate | :stream | :step | :chat | :tool, :start | :stop | :exception]`
  and observe every execution with `:duration` plus `:request_id`,
  `:engine`, `:model` metadata. See spec §29.

  ## Why request_id is metadata-only

  `:request_id` lives on telemetry span metadata and on
  `Response.request_id` post-collection — it does NOT extend the
  `ALLM.Event` closed tagged-tuple union. A consumer who folds events
  by hand (without `ALLM.StreamCollector`) reads `:request_id` from the
  surrounding span context, not from individual event payloads. See
  Phase 9 design Non-obvious Decision #1 for the full rationale.

  ## Span nesting

  Per-tool spans (`[:allm, :tool, ...]`) execute inside their parent
  step span (`[:allm, :step, ...]`); the parent step span itself nests
  inside its parent chat span when invoked from `chat/3` / `stream/3`.
  Inheritance: `request_id` is generated at the outermost call and
  threaded into inner calls via `opts[:request_id]`.

  ## Exception handling

  `span/3` delegates exception trapping to `:telemetry.span/3` (telemetry
  1.2+) which automatically catches raises in the closure, emits
  `[:allm, name, :exception]` with `%{kind, reason, stacktrace}` metadata,
  and re-raises the exception to the caller — preserving the existing
  bubble-up semantics of every wrapped function.
  """

  @event_prefix [:allm]

  @typedoc "Common metadata attached to every Layer-C span (spec §29)."
  @type common_metadata :: %{
          optional(:request_id) => String.t(),
          optional(:engine) => term(),
          optional(:model) => term(),
          optional(atom()) => term()
        }

  @typedoc "Span suffix per spec §29; the prefix [:allm] is fixed."
  @type span_name :: :generate | :stream | :step | :chat | :tool

  @valid_span_names [:generate, :stream, :step, :chat, :tool]

  @doc """
  Return the fixed event-name prefix for every ALLM telemetry event.

  ## Examples

      iex> ALLM.Telemetry.event_prefix()
      [:allm]
  """
  @spec event_prefix() :: [:allm]
  def event_prefix, do: @event_prefix

  @doc """
  Generate a fresh 22-character URL-safe Base64 request id.

  Sourced from 16 cryptographic random bytes. Used to correlate the
  start, stop, and any exception events of a single Layer-C call. The
  outermost public function generates the id; inner functions inherit
  via `opts[:request_id]` (see Phase 9 Non-obvious Decision #7).

  ## Examples

      iex> id = ALLM.Telemetry.request_id()
      iex> byte_size(id)
      22
      iex> id =~ ~r/^[A-Za-z0-9_-]{22}$/
      true
  """
  @spec request_id() :: String.t()
  def request_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  @doc """
  Wrap a closure in a `:telemetry.span/3` call under the `[:allm, name]`
  prefix.

  The closure must return `{result, stop_metadata_extras}` per
  `:telemetry.span/3`'s contract; `stop_metadata_extras` is shallow-merged
  on top of the start metadata at `:stop` emission time so per-span
  extras (`:response`, `:step_result`, `:chat_result`, `:result`) appear
  alongside the common keys.

  Caller-supplied `start_metadata` is forwarded to the `:start` event
  unchanged and used as the base for the `:stop` event's metadata.

  Raises `ArgumentError` for an unrecognised `name` (typo guard against
  `:chats` / `:steps`); valid names are
  `:generate | :stream | :step | :chat | :tool`.

  ## Carve-out: `:stream :stop` `:response` is `nil`

  Per `ALLM.StreamRunner.run/3`, the `:stream` span's `:stop` metadata
  carries `:response => nil` — materialising the wrapped enumerable to
  populate the `%Response{}` would defeat consumer-driven laziness.
  Consumers needing the canonical response should either fold the
  returned stream themselves (`ALLM.StreamCollector.to_response/1`) or
  call `ALLM.generate/3`, whose `:generate :stop` DOES carry the
  reduced `%Response{}`. See review Finding #2.

  ## Examples

      iex> :telemetry.attach(
      ...>   "doctest-handler",
      ...>   [:allm, :generate, :stop],
      ...>   fn _name, _measurements, %{result: r}, %{owner: pid} ->
      ...>     send(pid, {:doctest_event, r})
      ...>   end,
      ...>   %{owner: self()}
      ...> )
      iex> ALLM.Telemetry.span(:generate, %{request_id: "x"}, fn ->
      ...>   {:done, %{result: :ok}}
      ...> end)
      :done
      iex> :telemetry.detach("doctest-handler")
      iex> receive do
      ...>   {:doctest_event, payload} -> payload
      ...> after
      ...>   100 -> :no_event
      ...> end
      :ok
  """
  @spec span(span_name(), common_metadata(), (-> {result, map()})) :: result
        when result: var
  def span(name, start_metadata, fun)
      when is_atom(name) and is_map(start_metadata) and is_function(fun, 0) do
    unless name in @valid_span_names do
      raise ArgumentError,
            "ALLM.Telemetry.span/3: unknown span name #{inspect(name)}; " <>
              "expected one of #{inspect(@valid_span_names)}"
    end

    event = @event_prefix ++ [name]

    :telemetry.span(event, start_metadata, fn ->
      {result, stop_extras} = fun.()
      stop_metadata = Map.merge(start_metadata, stop_extras || %{})
      {result, stop_metadata}
    end)
  end

  @doc """
  Emit a single non-span event under the `[:allm | suffix_path]` event
  name. Used by `ALLM.Retry` for `[:allm, :adapter, :retry]`. No metadata
  merging or measurement injection — the caller supplies both maps in
  full.

  ## Examples

      iex> :telemetry.attach(
      ...>   "doctest-execute",
      ...>   [:allm, :doctest, :ping],
      ...>   fn _n, _m, _md, %{owner: pid} -> send(pid, :got_event) end,
      ...>   %{owner: self()}
      ...> )
      iex> ALLM.Telemetry.execute([:doctest, :ping], %{count: 1}, %{tag: :doc})
      :ok
      iex> :telemetry.detach("doctest-execute")
      iex> receive do
      ...>   :got_event -> :ok
      ...> after
      ...>   100 -> :no_event
      ...> end
      :ok
  """
  @spec execute([atom(), ...], map(), map()) :: :ok
  def execute(suffix_path, measurements, metadata)
      when is_list(suffix_path) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(@event_prefix ++ suffix_path, measurements, metadata)
  end
end
