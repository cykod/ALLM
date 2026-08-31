defmodule ALLM.Telemetry do
  @moduledoc """
  Layer-B helper that wraps `:telemetry.span/3` with ALLM-specific
  metadata defaults.

  Every public Layer-C entry point (`ALLM.generate/3`,
  `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`,
  `ALLM.chat/3`, `ALLM.stream/3`, `ALLM.generate_image/3` &
  siblings) is wrapped in a span. Attach `:telemetry.attach_many/4`
  handlers to observe every execution.

  ## Emitted events

  | Event name | When | Measurements | Metadata |
  |------------|------|--------------|----------|
  | `[:allm, :generate, :start]` | non-streaming generate enters | `system_time`, `monotonic_time` | `request_id`, `engine`, `model` |
  | `[:allm, :generate, :stop]` | non-streaming generate exits | `duration`, `monotonic_time` | start metadata + `response` |
  | `[:allm, :generate, :exception]` | closure raised | `duration`, `monotonic_time` | start metadata + `kind`, `reason`, `stacktrace` |
  | `[:allm, :stream, :start \\| :stop \\| :exception]` | streaming generate | as above; `:stop` `response` is `nil` (lazy) | start metadata + `response: nil` |
  | `[:allm, :step, :start \\| :stop \\| :exception]` | single chat step | as above | start metadata + `step_result` |
  | `[:allm, :chat, :start \\| :stop \\| :exception]` | multi-turn chat loop | as above | start metadata + `chat_result` |
  | `[:allm, :tool, :start \\| :stop \\| :exception]` | per-tool execution | as above | start metadata + `tool_call_id`, `tool_name`, `result` |
  | `[:allm, :image, :start \\| :stop \\| :exception]` | image generation | `duration`, plus `image_count` on `:stop` | `request_id`, `engine`, `model`, `operation`, `n`, plus `usage`, `response`, `error` on `:stop` |
  | `[:allm, :embed, :start \\| :stop \\| :exception]` | text embedding | `duration`, plus `chunk_count` and `embedding_count` on `:stop` | `request_id`, `engine`, `model`, `input_count`, plus `usage`, `response`, `error` on `:stop` |
  | `[:allm, :moderate, :start \\| :stop \\| :exception]` | content moderation | `duration`, plus `result_count` and `flagged_count` on `:stop` | `request_id`, `engine`, `model`, `input_count`, `multimodal`, plus `usage`, `response`, `error` on `:stop` |
  | `[:allm, :adapter, :retry]` | per-attempt retry (non-streaming) | `system_time` | `attempt`, `delay_ms`, `reason`, `request_id` |

  `[:allm, :embed, :stop]` carries `embedding_count` and `chunk_count` on
  **both** paths — each is `0` on the error path rather than absent, so the
  measurement key set is stable. `chunk_count` is the only signal that one
  `ALLM.embed/3` call became N HTTP requests; see `ALLM.embed/3` for the
  batching contract.

  `[:allm, :moderate, :stop]` follows the same rule: `result_count` and
  `flagged_count` are present on both paths (`0` each on error). It also
  carries `usage: nil` unconditionally, even though `ALLM.ModerationResponse`
  has no `:usage` field — a stable key set across capability spans is what a
  metrics backend wants, and it is what keeps a handler written against
  `[:allm, :embed, :stop]` from `KeyError`ing when pointed at `:moderate`.
  There is no `chunk_count`: `ALLM.moderate/3` does not chunk (see its
  "Batching" section).

  `input_count` on the `:moderate` span is `length(request.input)` — the raw
  element count, **not** the provider's *item* count, which is `1` whenever
  `multimodal` is `true` (an `:input` list carrying an `ALLM.ImagePart` is one
  multimodal item, judged together). The two agree exactly for an all-strings
  input; `multimodal` rides alongside so a consumer can derive the item count
  without a second measurement. A 40-element input with one `ALLM.ImagePart`
  therefore reports `input_count: 40` and is still accepted by an adapter
  whose `c:ALLM.ModerationAdapter.max_batch_size/0` is `32`.

  ## Common metadata

  Every span carries `:request_id`, `:engine`, and `:model` on `:start`,
  and the same on `:stop` (plus the per-span `*_result` / `response` /
  `error` extras). `:request_id` is generated at the outermost public
  call and threaded into nested calls via `opts[:request_id]`, so
  per-tool spans inside a `chat/3` loop share the parent chat's id.

  ## Why request_id is metadata-only

  `:request_id` lives on telemetry span metadata and on
  `Response.request_id` post-collection — it does NOT extend the
  `ALLM.Event` closed tagged-tuple union. A consumer who folds events
  by hand (without `ALLM.StreamCollector`) reads `:request_id` from the
  surrounding span context, not from individual event payloads.

  ## Span nesting

  Per-tool spans (`[:allm, :tool, ...]`) execute inside their parent
  step span (`[:allm, :step, ...]`); the parent step span itself nests
  inside its parent chat span when invoked from `chat/3` / `stream/3`.

  ## Exception handling

  `span/3` delegates exception trapping to `:telemetry.span/3` which
  automatically catches raises in the closure, emits
  `[:allm, name, :exception]` with `%{kind, reason, stacktrace}`
  metadata, and re-raises the exception to the caller — preserving the
  existing bubble-up semantics of every wrapped function.
  """

  @event_prefix [:allm]

  @typedoc "Common metadata attached to every Layer-C span."
  @type common_metadata :: %{
          optional(:request_id) => String.t(),
          optional(:engine) => term(),
          optional(:model) => term(),
          optional(atom()) => term()
        }

  @typedoc "Span suffix; the prefix [:allm] is fixed."
  @type span_name :: :generate | :stream | :step | :chat | :tool | :image | :embed | :moderate

  @valid_span_names [:generate, :stream, :step, :chat, :tool, :image, :embed, :moderate]

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
  via `opts[:request_id]`.

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

  The closure must return either:

    * `{result, stop_metadata_extras}` — the 2-tuple form (default,
      used by `:generate | :stream | :step | :chat | :tool` spans).
      `stop_metadata_extras` is shallow-merged on top of the start
      metadata at `:stop` emission time so per-span extras
      (`:response`, `:step_result`, `:chat_result`, `:result`) appear
      alongside the common keys.
    * `{result, extra_measurements, stop_metadata_extras}` — the
      3-tuple form, for spans that inject custom `:stop` measurements
      beyond `:duration` and `:monotonic_time`. `:image`, `:embed` and
      `:moderate` spans use this form to carry `:image_count` /
      `:embedding_count` + `:chunk_count` / `:result_count` +
      `:flagged_count` as measurements (numeric metrics →
      measurements; structured context → metadata).

  Caller-supplied `start_metadata` is forwarded to the `:start` event
  unchanged and used as the base for the `:stop` event's metadata.

  Raises `ArgumentError` for an unrecognised `name` (typo guard against
  `:chats` / `:steps`); valid names are
  `:generate | :stream | :step | :chat | :tool | :image | :embed |
  :moderate`.

  ## Carve-out: `:stream :stop` `:response` is `nil`

  Per `ALLM.StreamRunner.run/3`, the `:stream` span's `:stop` metadata
  carries `:response => nil` — materialising the wrapped enumerable to
  populate the `%Response{}` would defeat consumer-driven laziness.
  Consumers needing the canonical response should either fold the
  returned stream themselves (`ALLM.StreamCollector.to_response/1`) or
  call `ALLM.generate/3`, whose `:generate :stop` DOES carry the
  reduced `%Response{}`.

  ## Examples

      iex> :telemetry.attach(
      ...> "doctest-handler",
      ...> [:allm, :generate, :stop],
      ...> fn _name, _measurements, %{result: r}, %{owner: pid} ->
      ...> send(pid, {:doctest_event, r})
      ...> end,
      ...> %{owner: self()}
      ...>)
      iex> ALLM.Telemetry.span(:generate, %{request_id: "x"}, fn ->
      ...> {:done, %{result: :ok}}
      ...> end)
      :done
      iex> :telemetry.detach("doctest-handler")
      iex> receive do
      ...> {:doctest_event, payload} -> payload
      ...> after
      ...> 100 -> :no_event
      ...> end
      :ok
  """
  @spec span(
          span_name(),
          common_metadata(),
          (-> {result, map()} | {result, map(), map()})
        ) :: result
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
      case fun.() do
        {result, stop_extras} ->
          stop_metadata = Map.merge(start_metadata, stop_extras || %{})
          {result, stop_metadata}

        {result, extra_measurements, stop_extras} ->
          stop_metadata = Map.merge(start_metadata, stop_extras || %{})
          {result, extra_measurements || %{}, stop_metadata}
      end
    end)
  end

  @doc """
  Emit a single non-span event under the `[:allm | suffix_path]` event
  name. Used by `ALLM.Retry` for `[:allm, :adapter, :retry]`. No metadata
  merging or measurement injection — the caller supplies both maps in
  full.

  ## Examples

      iex> :telemetry.attach(
      ...> "doctest-execute",
      ...> [:allm, :doctest, :ping],
      ...> fn _n, _m, _md, %{owner: pid} -> send(pid, :got_event) end,
      ...> %{owner: self()}
      ...>)
      iex> ALLM.Telemetry.execute([:doctest, :ping], %{count: 1}, %{tag: :doc})
      :ok
      iex> :telemetry.detach("doctest-execute")
      iex> receive do
      ...> :got_event -> :ok
      ...> after
      ...> 100 -> :no_event
      ...> end
      :ok
  """
  @spec execute([atom(), ...], map(), map()) :: :ok
  def execute(suffix_path, measurements, metadata)
      when is_list(suffix_path) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(@event_prefix ++ suffix_path, measurements, metadata)
  end
end
