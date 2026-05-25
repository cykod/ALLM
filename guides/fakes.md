# Testing with Fake

`ALLM.Providers.Fake` is the deterministic, scripted adapter that ships
with the library. It's the canonical test vehicle — fast (~50µs per
call), serializable, requires no network, and passes every conformance
suite that real provider adapters do.

This guide consolidates the script-entry vocabulary, the cursor model,
and the test-only `:usage` / `:record` opts. Reach for it whenever you
write a test against ALLM's orchestration layer.

## When to reach for it

Use `ALLM.Providers.Fake` for **every** orchestration test:

* `chat/3` / `step/3` flows including tool execution.
* Streaming tests (`stream/3`, `stream_step/3`).
* Session state transitions (`:idle` → `:awaiting_tools` → `:completed`).
* Error-path tests (rate limits, content filters, mid-stream failures).
* Multi-turn loop bound tests (`:max_turns`, `:halt_when`, ask-user).

Use real-provider wire tests (`@tag :wire`, `Bypass`/`Plug.Test`) ONLY
when you're testing request/response byte-shape. For everything else,
the Fake is faster, deterministic, and decoupled from provider quirks.

## Script-entry vocabulary

A script is a list of tagged tuples — each tuple describes one event
the Fake will produce. Two disjoint vocabularies exist; the leading tag
disambiguates.

### Spec entries (user-facing)

| Tag | Shape | Emits |
|-----|-------|-------|
| `{:text, s}` | binary | `:text_delta` (streaming) / accumulates text (non-streaming) |
| `{:tool_call, kw}` | keyword with `:id, :name, :arguments` | `:tool_call_completed` + sets `finish_reason: :tool_calls` |
| `{:tool_call_delta, kw}` | keyword with `:id, :arguments_delta` | `:tool_call_delta` |
| `{:usage, map}` | map of `%Usage{}` fields | sets `response.usage` (non-streaming) / `metadata.usage` on `:message_completed` (streaming) |
| `{:raw_chunk, term}` | opaque | `:raw_chunk` |
| `{:finish, reason}` | atom | terminal `:message_completed` |
| `{:error, term}` | atom (legal reason) or any term | `:error` event (mid-stream) |
| `{:delay, ms}` | non-neg int | `Process.sleep(ms)` — no event |
| `{:sleep, ms}` | non-neg int | deprecated alias of `:delay` |

### Conformance-harness entries

| Tag | Shape | Notes |
|-----|-------|-------|
| `{:ok, map}` | a `%Response{}`-shaped map | one entry per call |
| `{:error, reason, opts}` | 3-tuple | hands off to `AdapterError.new/2` |
| `{:text_delta, s}` | streaming-only | identical to `{:text, s}` |
| `{:preflight_error, reason, opts}` | streaming-only | synchronous `{:error, _}` from `stream/2` |
| `{:error_event, reason, opts}` | streaming-only | mid-stream `:error` event |
| `{:stream_error, reason, opts}` | streaming-only | `%StreamError{}` mid-stream |

The full grammar lives in `ALLM.Providers.Fake.Script`'s moduledoc.

## Construction

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.Fake,
  adapter_opts: [
    script: [{:text, "ok"}, {:finish, :stop}]
  ]
)
```

For multi-call tests, use `:scripts` (a list of per-call lists):

```elixir
adapter_opts: [
  scripts: [
    [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}}, {:finish, :tool_calls}],
    [{:text, "done"}, {:finish, :stop}]
  ]
]
```

Streaming uses `:stream_script` with the same shapes (it accepts either
a flat list for a single call or a list-of-lists for multi-call).

## Cursor patterns

Multi-call scripts advance a per-process cursor on every call. By default
the cursor lives in the process dictionary keyed by `:erlang.phash2(scripts)`
— isolated per ExUnit test process (`async: true`), GC'd on pid-down,
zero-setup for the common case.

### Footgun: content-equal scripts collide

Two engines built with byte-identical `:scripts` values in the same
process share the cursor. Workaround:

```elixir
cursor = ALLM.Providers.Fake.start_script_cursor()

engine1 = ALLM.Engine.new(
  adapter: ALLM.Providers.Fake,
  adapter_opts: [scripts: scripts, script_cursor: cursor]
)
```

`start_script_cursor/0` returns an Agent pid; `cursor_index/1` reads it
so a test can assert how many calls have been consumed.

### Cross-process cursor sharing

When a test dispatches the adapter call across processes
(`Task.async/1`), the explicit cursor is load-bearing — process-dict
isolation would otherwise reset the cursor for each Task.

## The `:usage` opt (Phase 21.2)

`adapter_opts[:usage]` materializes a `%ALLM.Usage{}` on every response
without writing the usage entry per script:

```elixir
adapter_opts: [
  script: [{:text, "ok"}, {:finish, :stop}],
  usage: [input_tokens: 12, output_tokens: 4]
]
```

Accepts a pre-built `%Usage{}` or a keyword list (normalized via
`Usage.new/1`). The opt wins over any per-script `{:usage, _}` entry
for the same call.

On streaming, the Usage rides on the `:message_completed` payload's
`metadata.usage` key (additive payload-key extension — no new event
variant). `ALLM.StreamCollector.apply_event/2` copies it onto
`state.usage` so non-streaming collection produces a
`%Response{usage: _}`.

A per-script `{:usage, _}` entry behaves the same on streaming: it
accumulates into `metadata.usage` rather than emitting a `:raw_chunk`.
Real adapters emitting `{:raw_chunk, {:usage, _}}` keep their existing
path; the change is scoped to Fake's `{:usage, _}` entry.

## The `:record` opt (Phase 21.2)

`adapter_opts[:record]` accepts a pid that receives
`{:allm_fake_record, %Request{}, opts}` verbatim BEFORE the script
interpretation runs. The recording fires once per call — both
`generate/2` and `stream/2` send before opening the stream.

```elixir
test "tool call sends the right schema" do
  me = self()

  engine = ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      script: [{:text, "ok"}, {:finish, :stop}],
      record: me
    ],
    tools: [my_tool]
  )

  {:ok, _} = ALLM.chat(engine, [ALLM.user("trigger")])

  assert_receive {:allm_fake_record, %ALLM.Request{tools: [tool]}, _opts}
  assert tool.schema["properties"]["city"]["type"] == "string"
end
```

`opts` are forwarded verbatim — no key scrubbing. The caller owns the
opts they passed in; redact via `Keyword.delete/2` before asserting if
needed. A dead recording pid raises `ArgumentError` — a dead pid is a
test bug.

## Cleanup observation

For streaming tests asserting that `Stream.resource/3`'s `after_fun`
runs:

```elixir
ref = :counters.new(1, [:atomics])

{:ok, stream} = ALLM.Providers.Fake.stream(req,
  adapter_opts: [script: [...], cleanup_observer: ref])

_ = Enum.take(stream, 2)
assert :counters.get(ref, 1) == 1
```

The counter increments at most once per stream (on consumer halt,
reducer throws, or `Stream.run/1` scope exit). Brutal `Process.exit(pid,
:kill)` skips cleanup per OTP design — don't simulate `:kill` in tests.

## Retry simulation

`adapter_opts[:retry_until_call]` makes the first `n - 1` calls fail
transiently (with `:timeout`) and the `n`-th call succeed:

```elixir
adapter_opts: [
  script: [{:text, "ok"}, {:finish, :stop}],
  retry_until_call: 3
]
```

`generate/2` retries automatically under the default policy. `stream/2`
emits the transient failure as a mid-stream `{:error, _}` event so the
consumer reduces to `%Response{finish_reason: :error}` per the
mid-stream error contract (`ALLM.Runner` / `chat/3` do not retry the
streaming arm — spec §6.1).

## Cross-process engine injection

When a test fans work out across `Task.async/1` and you want the
workers to see the test's engine, use `ALLM.Sandbox.set_engine/1`:

```elixir
test "fan-out workers use the test engine" do
  ALLM.Sandbox.set_engine(fake_engine())

  results =
    ["a", "b", "c"]
    |> Task.async_stream(fn input ->
      ALLM.generate(ALLM.Sandbox.get_engine(), ALLM.request([ALLM.user(input)]))
    end)
    |> Enum.map(fn {:ok, r} -> r end)

  assert length(results) == 3
end
```

`Sandbox.get_engine/0` walks `$callers` so worker processes inherit the
registering ancestor's engine — same idiom as `Mox.allow/3` and
`Ecto.Adapters.SQL.Sandbox.allow/3`.

## Where to next

* `streaming.md` — the event-shape vocabulary the scripts emit.
* `tools.md` — tool-loop tests against scripted tool calls.
* `sessions.md` — multi-turn persistence tests.
* `ALLM.Providers.Fake` and `ALLM.Providers.Fake.Script` moduledocs —
  reference-level documentation of every entry tag.
