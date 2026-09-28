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

    iex> engine =
    ...>   ALLM.Engine.new(
    ...>     adapter: ALLM.Providers.Fake,
    ...>     adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]]
    ...>   )
    iex> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
    iex> {response.output_text, response.finish_reason}
    {"ok", :stop}

For multi-call tests, use `:scripts` (a list of per-call lists):

<!-- fence-check: skip — a bare `adapter_opts:` keyword fragment, not a standalone expression -->
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

Multi-call scripts advance a per-process cursor on every call. The
cursor lives in the process dictionary — isolated per ExUnit test
process (`async: true`), GC'd on pid-down, zero-setup for the common
case. Its key is chosen in this order:

1. `adapter_opts[:script_cursor]` — an explicit Agent pid from
   `ALLM.Providers.Fake.start_script_cursor/0`.
2. `adapter_opts[:cursor_key]` — the engine's `:id`. Every call through
   the façade (`ALLM.generate/3`, `chat/3`, `stream/3`, `step/3`, the
   `ALLM.Session` functions, …) injects it for you.
3. `:erlang.phash2(scripts)` — a content hash, used only for direct
   adapter calls that carry no engine.

So at the façade the cursor follows engine identity: two engines built
with byte-identical `:scripts` each start at the first script, even in
the same process.

    iex> scripts = [[{:text, "first"}, {:finish, :stop}], [{:text, "second"}, {:finish, :stop}]]
    iex> e1 = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: scripts])
    iex> e2 = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: scripts])
    iex> req = ALLM.request([ALLM.user("hi")])
    iex> {:ok, r1} = ALLM.generate(e1, req)
    iex> {:ok, r2} = ALLM.generate(e2, req)
    iex> {r1.output_text, r2.output_text}
    {"first", "first"}

Because `:cursor_key` rides in `adapter_opts`, a façade call recorded
via `adapter_opts[:record]` (below) includes `{:cursor_key, engine.id}`
in the forwarded opts — account for it if you assert on the exact
keyword list.

### Direct adapter calls: content-equal scripts collide

`ALLM.Providers.Fake.generate(req, opts)` / `.stream(req, opts)` called
without an engine get no `:cursor_key` and fall back to the content
hash, so two direct calls with byte-identical scripts in the same
process share a cursor. Pass an explicit cursor instead:

```elixir
cursor = ALLM.Providers.Fake.start_script_cursor()

{:ok, response} =
  ALLM.Providers.Fake.generate(request, adapter_opts: [scripts: scripts, script_cursor: cursor])
```

`start_script_cursor/0` returns an Agent pid; `cursor_index/1` reads it
so a test can assert how many calls have been consumed.

### Cross-process cursor sharing

When a test dispatches the adapter call across processes
(`Task.async/1`), the explicit cursor is load-bearing — process-dict
isolation would otherwise reset the cursor for each Task.

## The `:usage` opt

`adapter_opts[:usage]` materializes a `%ALLM.Usage{}` on every response
without writing the usage entry per script:

<!-- fence-check: skip — a bare `adapter_opts:` keyword fragment, not a standalone expression -->
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

## The `:record` opt

`adapter_opts[:record]` accepts a pid that receives
`{:allm_fake_record, %Request{}, opts}` verbatim BEFORE the script
interpretation runs. The recording fires once per call — both
`generate/2` and `stream/2` send before opening the stream.

<!-- fence-check: skip — an ExUnit test body: `test/2`, `assert_receive/1` and `assert/1` need a `use ExUnit.Case` module around them -->
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

<!-- fence-check: skip — `script: [...]` is an elision for the reader, not a literal list -->
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

<!-- fence-check: skip — a bare `adapter_opts:` keyword fragment, not a standalone expression -->
```elixir
adapter_opts: [
  script: [{:text, "ok"}, {:finish, :stop}],
  retry_until_call: 3
]
```

`generate/2` retries automatically under the default policy. `stream/2`
emits the transient failure as a mid-stream `{:error, _}` event so the
consumer reduces to `%Response{finish_reason: :error}` — the mid-stream
error contract. Neither `ALLM.Runner` nor `chat/3` retries the streaming
arm; see `errors_and_retries.md`.

## Capability fakes

Every capability slot on the engine has its own scripted Fake, with the
same cursor model as the chat Fake (engine-id keyed at the façade,
`:script_cursor` for direct calls) and a `{:retry_until_call, n}` entry
for exercising retries:

| Fake | Engine slot | Script key | Guide |
|------|-------------|------------|-------|
| `ALLM.Providers.FakeImages` | `:image_adapter` | `:image_script` | `image_generation.md` |
| `ALLM.Providers.FakeEmbeddings` | `:embed_adapter` | `:embedding_script` | `embeddings.md` |
| `ALLM.Providers.FakeModeration` | `:moderation_adapter` | `:moderation_script` | `moderation.md` |
| `ALLM.Providers.FakeClassification` | `:classification_adapter` | `:classification_script` | `classification.md` |
| `ALLM.Providers.FakeSpeech` | `:speech_adapter` | `:speech_script` | `audio.md` |
| `ALLM.Providers.FakeTranscription` | `:transcription_adapter` | `:transcription_script` | `audio.md` |

The script key lives in the engine's `adapter_opts`. Some Fakes answer
with no script at all — FakeModeration returns a clean verdict,
FakeClassification answers every question with a deterministic default,
FakeSpeech returns `"FAKE-AUDIO:" <> input`, FakeTranscription returns
an empty transcript — but a non-empty script that runs out is an error,
never a silent fallback, so an off-by-one in your call count surfaces.

    iex> engine =
    ...>   ALLM.Engine.new(
    ...>     speech_adapter: ALLM.Providers.FakeSpeech,
    ...>     adapter_opts: [speech_script: [{:ok, "scripted-bytes"}]]
    ...>   )
    iex> {:ok, speech} = ALLM.synthesize(engine, "Hello there")
    iex> ALLM.Audio.to_binary(speech.audio)
    {:ok, "scripted-bytes"}

FakeSpeech and FakeTranscription also accept a stream-only
`{:events, events}` entry: the stream paths (`stream_synthesize/3`,
`stream_synthesize_input/3`, `stream_transcribe/3`) emit `events`
verbatim, which is how a mid-stream failure is scripted. The
non-streaming `synthesize/3` / `transcribe/3` answer that entry with an
`:unknown` error whose `metadata.cause` is `:stream_only_script_entry`.
Each Fake's moduledoc carries its full entry grammar.

## Cross-process engine injection

When a test fans work out across `Task.async/1` and you want the
workers to see the test's engine, use `ALLM.Sandbox.set_engine/1`:

<!-- fence-check: skip — an ExUnit test body: `test/2` and `assert/1` need a `use ExUnit.Case` module around them, and `fake_engine/0` is the reader's own helper -->
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
* `image_generation.md`, `embeddings.md`, `moderation.md`,
  `classification.md`, `audio.md` —
  the capability Fakes in context.
* `ALLM.Providers.Fake` and `ALLM.Providers.Fake.Script` moduledocs —
  reference-level documentation of every entry tag.
