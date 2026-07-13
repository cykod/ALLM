# Streaming

Streaming is the primitive in ALLM. The non-streaming entry points
(`generate/3`, `step/3`, `chat/3`) are reducers over a stream — every
provider adapter implements both shapes, but the streaming path is the
canonical one. This guide covers when to stream, what events to expect,
and how to control the firehose.

## When to stream

Reach for `stream_generate/3` or `stream/3` when you want incremental
output — typing-effect UIs, progressive tool-call dispatch, latency
hiding for long completions. The non-streaming variants give you a
single `%Response{}` (or `%ChatResult{}`) at the end; the streaming
variants give you a lazy `Enumerable` of `t:ALLM.Event.t/0` values you fold
over yourself.

## The simplest stream

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [
    ...>     stream_script: [[
    ...>       {:text_delta, "Hello"},
    ...>       {:text_delta, ", "},
    ...>       {:text_delta, "world"},
    ...>       {:finish, :stop}
    ...>     ]]
    ...>   ]
    ...> )
    iex> req = ALLM.request([ALLM.user("hi")])
    iex> {:ok, stream} = ALLM.stream_generate(engine, req)
    iex> Enum.any?(Enum.to_list(stream), &match?({:message_completed, _}, &1))
    true

`stream_generate/3` returns `{:ok, stream}`. The stream is lazy; it
doesn't dispatch to the provider until you start consuming. Common
consumption patterns:

```elixir
# Print every text delta as it arrives.
{:ok, stream} = ALLM.stream_generate(engine, req)

stream
|> Stream.each(fn
  {:text_delta, %{delta: chunk}} -> IO.write(chunk)
  _ -> :ok
end)
|> Stream.run()
```

```elixir
# Collect the full response synchronously (equivalent to generate/3).
{:ok, stream} = ALLM.stream_generate(engine, req)
{:ok, response} = ALLM.StreamCollector.collect(stream)
```

## The event union

Every event is a tagged tuple with a payload map. The closed set:

| Tag | When it fires | Payload keys |
|---|---|---|
| `{:message_started, _}` | The assistant message begins | `:message` |
| `{:text_delta, _}` | Each chunk of assistant text | `:id`, `:delta` |
| `{:text_completed, _}` | The assistant text finished | `:id`, `:text` |
| `{:tool_call_started, _}` | A tool call begins assembling | `:id`, `:name` |
| `{:tool_call_delta, _}` | Each chunk of a tool-call argument blob | `:id`, `:arguments_delta` |
| `{:tool_call_completed, _}` | A complete tool call has assembled | `:id`, `:name`, `:arguments`, `:raw_arguments` |
| `{:tool_execution_started, _}` | A tool handler is about to run | `:id`, `:name`, `:arguments` |
| `{:tool_execution_completed, _}` | A tool handler returned a result | `:id`, `:name`, `:result` |
| `{:tool_result_encoded, _}` | The result was encoded for the model | `:id`, `:content` |
| `{:ask_user_requested, _}` | A tool returned `{:ask_user, _, _}` | `:tool_call_id`, `:tool_name`, `:question`, `:opts` |
| `{:tool_halt, _}` | A tool halted the loop | `:tool_call_id`, `:reason`, `:result` |
| `{:message_completed, _}` | The assistant message finished | `:message`, `:finish_reason` |
| `{:step_completed, _}` | One round-trip completed (chat/3 emits this each loop iteration) | `:response`, `:thread`, `:mode`, `:manual_tool_calls` |
| `{:chat_completed, _}` | The chat loop finished (terminal) | `:result` |
| `{:raw_chunk, _}` | Provider-native chunk passthrough (when `:include_raw_chunks` is on) | opaque |
| `{:error, _}` | Mid-stream error from the provider | opaque |

Pattern-matching on a payload key is **not exhaustive** — adding new
keys to a payload map is non-breaking. Match on the leading tag.

## Filter opts

Most consumers don't need every event. `stream_generate/3` and
`stream/3` accept filter options:

* `:emit_text_deltas` (default `true`) — set to `false` to drop
  `:text_delta` events.
* `:emit_tool_deltas` (default `true`) — set to `false` to drop
  `:tool_call_delta` events; you'll still receive the assembled
  `:tool_call_completed` event.
* `:include_raw_chunks` (default `false`) — set to `true` to receive
  `:raw_chunk` events with provider-native chunks (useful for
  passthrough proxies).
* `:on_event` — a 1-arity function called on every event before the
  consumer sees it. Useful for telemetry instrumentation that doesn't
  need to mutate the stream.

```elixir
{:ok, stream} = ALLM.stream_generate(engine, req,
  emit_tool_deltas: false,
  on_event: fn event -> :telemetry.execute([:my_app, :llm, :event], %{}, %{event: event}) end
)
```

## stream/3 — the multi-turn streaming loop

`ALLM.stream/3` is `chat/3` plus streaming. It runs the auto-loop —
calling tools as they're requested, feeding results back in, looping
until the model stops asking — and emits events the entire way. You'll
see a `:step_completed` event per loop iteration, and a final terminal
`:chat_completed` event when the loop exits.

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [
    ...>     stream_script: [[
    ...>       {:text_delta, "done"},
    ...>       {:finish, :stop}
    ...>     ]]
    ...>   ]
    ...> )
    iex> {:ok, stream} = ALLM.stream(engine, [ALLM.user("hi")])
    iex> events = Enum.to_list(stream)
    iex> Enum.any?(events, &match?({:message_completed, _}, &1))
    true

## Cancellation and cleanup

The stream returned by `stream_generate/3` / `stream/3` is built on
`Stream.resource/3`. When the consumer halts early — `Enum.take/2`,
breaking out of `Enum.reduce_while/3`, the consumer process crashing —
the resource's `after_fun` runs and tears down the underlying HTTP
connection. You don't need to call any explicit cancel function.

If you want to halt the stream after a fixed number of text deltas:

```elixir
{:ok, stream} = ALLM.stream_generate(engine, req)

stream
|> Stream.filter(&match?({:text_delta, _}, &1))
|> Enum.take(10)
```

Taking 10 elements halts the stream; the underlying HTTP connection is
closed automatically.

## Mid-stream errors

A mid-stream `{:error, struct}` event surfaces as
`{:ok, %Response{finish_reason: :error, metadata: %{error: struct}}}`
from the non-streaming variants — the call-site tuple stays `{:ok, _}`.

For streaming consumers, you see the `{:error, _}` event in the stream
itself. The error is folded mid-stream and does **not** terminate the
enumeration — scan collected events for `{:error, _}` before folding
deltas.

```elixir
{:ok, stream} = ALLM.stream_generate(engine, req)

Enum.each(stream, fn
  {:error, %ALLM.Error.AdapterError{reason: :rate_limited}} ->
    IO.puts("backing off")

  {:text_delta, %{delta: chunk}} ->
    IO.write(chunk)

  _ ->
    :ok
end)
```

If you're using `StreamCollector.collect/1`, the collector folds the
mid-stream error into the response struct's `:metadata.error` field and
returns `{:ok, response}` with `finish_reason: :error`. Pre-flight
errors (validation failures, missing adapter) surface as `{:error, _}`
at the `stream_generate/3` call site, before the stream is built.

## Where to next

* `tools.md` — streaming + tool calls.
* `errors_and_retries.md` — retry policy for transient errors.
* `examples/02_streaming_text.exs` — runnable smoke test against any
  provider.
