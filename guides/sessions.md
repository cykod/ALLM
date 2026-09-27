# Sessions

The `ALLM.Session` API wraps the chat loop with persistent state. A
`%Session{}` carries the thread, the status (`:idle`, `:awaiting_tools`,
`:awaiting_user`, `:completed`, `:error`), pending tool calls, and any
caller metadata you want to ride along. Sessions round-trip safely
through `:erlang.term_to_binary/1` and `ALLM.Serializer.to_json!/1`, so
you can persist them to a database column, an ETS table, or a queue
between turns.

This guide covers when to reach for sessions, the status union, the
streaming reducer pattern, and the canonical persistence shapes.

## When to use Session vs chat

Use `chat/3` when the conversation lives in one process for one request
— a CLI tool, a one-off script, a test. The thread is yours to manage.

Use `Session` when the conversation needs to outlive a request. Web app
where each user message is a new HTTP request? Background worker
resuming after a crash? Job queue with durable state between turns?
Reach for `Session`.

## Building a session

`Session.start/3` runs the first turn:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "Hello!"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, session, _chat_result} = ALLM.Session.start(engine, [ALLM.user("Hi.")])
    iex> session.status
    :completed

A `:completed` session has finished its turn normally and is ready for
the next one (`reply/4` and `continue/4` treat `:completed` like
`:idle`). The `session.thread` field carries the full conversation;
serialize the
session and stash it.

## Replying

`Session.reply/4` appends a user message and runs the next turn:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [scripts: [
    ...>     [{:text, "Hello!"}, {:finish, :stop}],
    ...>     [{:text, "Goodbye!"}, {:finish, :stop}]
    ...>   ]]
    ...> )
    iex> {:ok, session, _} = ALLM.Session.start(engine, [ALLM.user("Hi.")])
    iex> {:ok, session, _} = ALLM.Session.reply(engine, session, "Bye.")
    iex> session.status
    :completed

`reply/4` takes the engine as its **first** argument again — engines
aren't persisted on the session (they hold non-serializable bits like
Finch names and key resolvers). The session and engine pair to make a
turn.

## The status union

| Status | Meaning | Caller action |
|---|---|---|
| `:idle` | Last turn completed; ready for next reply | Call `reply/4` or `continue/4` |
| `:awaiting_tools` | Loop halted on manual tool calls | Run the manual tools, call `submit_tool_result/3`, then `continue/4` |
| `:awaiting_user` | Loop halted on `{:ask_user, _, _}` | Append user reply via `reply/4` |
| `:completed` | Session ended (e.g., max iterations) | New session if you want to continue |
| `:error` | Fatal error during the turn; `ChatResult.halted_reason: :error` | Inspect the result, start a new session |

Pattern-match on `session.status` to drive your application's UI.

## Manual tool flow

When `session.status == :awaiting_tools`, the pending calls live on
`session.pending_tool_calls`. After you run them externally, submit
each result and continue:

```elixir
session = ALLM.Session.submit_tool_result(session, "call_1", %{ok: true})
{:ok, session, _chat_result} = ALLM.Session.continue(engine, session, nil)
```

`submit_tool_result/3` returns the updated session directly (a bare
`%Session{}`, or `{:error, %ALLM.Error.SessionError{}}` on a bad call
id); `continue/4` takes the engine first and re-enters the chat loop,
returning the same `{:ok, session, chat_result}` 3-tuple as `reply/4`.

## Persistence patterns

### Serialize to ETF (BEAM-to-BEAM)

Best for a process-restart-safe queue or an ETS table:

```elixir
binary = :erlang.term_to_binary(session)
# ... store, fetch, restart ...
session = :erlang.binary_to_term(binary)
```

### Serialize to JSON (cross-language, DB column)

`ALLM.Serializer.to_json!/1` and `from_json/1` round-trip functionally
(the restored session drives the same turns), but the result is **not**
`==` the original — map-typed `metadata`/`context` come back
string-keyed. Assert a stable scalar field, never a pin match:

```elixir
json = ALLM.Serializer.to_json!(session)
{:ok, restored} = ALLM.Serializer.from_json(json)
true = restored.status == session.status
```

Useful for storing the session in a `text` or `jsonb` column in
Postgres alongside the user/conversation row.

### Database column shape

```elixir
defmodule MyApp.Conversation do
  use Ecto.Schema

  schema "conversations" do
    field :session_json, :string
    timestamps()
  end
end

# Persist after each turn:
Ecto.Changeset.change(conv, session_json: ALLM.Serializer.to_json!(session))
```

Restoring before the next turn:

```elixir
{:ok, session} = ALLM.Serializer.from_json(conv.session_json)
{:ok, session, _} = ALLM.Session.reply(engine, session, user_input)
```

## The streaming reducer

`Session.stream_start/3` and `Session.stream_reply/4` return `{:ok,
stream}` (engine-first). Fold the stream with `ALLM.Session.StreamReducer`
— `new/2` builds a reducer from the session, `apply_event/2` folds one
event at a time (do your side effects in the same fold), and `finalize/1`
returns the `{session, result}` pair once the stream is fully consumed.
There is no `run/2`.

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [scripts: [
    ...>     [{:text, "Hi."}, {:finish, :stop}],
    ...>     [{:text, "Hello!"}, {:finish, :stop}]
    ...>   ]]
    ...> )
    iex> {:ok, session, _} = ALLM.Session.start(engine, [ALLM.user("Hi.")])
    iex> {:ok, stream} = ALLM.Session.stream_reply(engine, session, "Hello?")
    iex> reducer = ALLM.Session.StreamReducer.new(session)
    iex> reducer =
    ...>   Enum.reduce(stream, reducer, fn event, acc ->
    ...>     ALLM.Session.StreamReducer.apply_event(acc, event)
    ...>   end)
    iex> {session, _result} = ALLM.Session.StreamReducer.finalize(reducer)
    iex> session.status
    :completed

Consume the stream **in full** before `finalize/1` — a fully-folded chat
stream normalizes `status` to `:completed` with `halted_reason:
:completed`; a partially-consumed fold reports `halted_reason:
:cancelled`. Do your side effects (a Phoenix broadcast, a LiveView push)
inside the fold:

```elixir
{:ok, stream} = ALLM.Session.stream_reply(engine, session, "Hello?")

reducer =
  Enum.reduce(stream, ALLM.Session.StreamReducer.new(session), fn event, acc ->
    Phoenix.PubSub.broadcast(MyApp.PubSub, "chat:#{session.id}", event)
    ALLM.Session.StreamReducer.apply_event(acc, event)
  end)

{session, _result} = ALLM.Session.StreamReducer.finalize(reducer)
```

The reduce fn's arg order is a footgun: `Enum.reduce`'s callback is
`(event, acc)`, but `apply_event/2` is `(reducer, event)` — so the call
inside is `apply_event(acc, event)`.

## Round-trip safety

A session is round-trip safe iff it never carries a non-serializable
value. ALLM enforces this on construction — engines (which DO carry
non-serializable bits) are passed at call time, not stored on the
session. Verify in your tests:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, session, _} = ALLM.Session.start(engine, [ALLM.user("hi")])
    iex> binary = :erlang.term_to_binary(session)
    iex> ^session = :erlang.binary_to_term(binary)
    iex> session.status
    :completed

## Prompt caching

A long-lived session re-sends the same prefix every turn: the system
prompt, the tools, and every earlier message. Providers can serve that
prefix from a prompt cache, which lowers both the latency to the first
token and the input cost. Turn it on with `prompt_cache:`, as a call
option or in the engine's `params` (below, `recipe_text` stands for your
long, stable system prompt):

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5.6",
    params: %{prompt_cache: %{retention: :long}}
  )

session = ALLM.Session.new(id: "recipe-42") |> ALLM.Session.append(ALLM.system(recipe_text))
{:ok, session, result} = ALLM.Session.start(engine, session)
{:ok, _session, result} = ALLM.Session.reply(engine, session, "How long does step 12 take?")
result.final_response.usage.cached_input_tokens
```

`retention: :short` keeps the provider's default cache lifetime;
`:long` asks for the longest lifetime the provider offers per request.
When you give no `:key`, the session's id is used as the cache key, so a
session whose id carries personal data should pass an explicit
`prompt_cache: %{key: ..., retention: ...}`. Caching stays off unless you
ask for it.

The option lands on the request as a typed field that
`ALLM.Validate.request/1` checks, and usage reports what the cache did:

    iex> req = ALLM.Request.new([ALLM.user("hi")], prompt_cache: %{key: "recipe-42", retention: :long})
    iex> ALLM.Validate.request(req)
    :ok
    iex> bad = ALLM.Request.new([ALLM.user("hi")], prompt_cache: %{retention: :forever})
    iex> {:error, %ALLM.Error.ValidationError{errors: errors}} = ALLM.Validate.request(bad)
    iex> {:prompt_cache, :invalid_shape} in errors
    true
    iex> usage = %ALLM.Usage{input_tokens: 6263, cached_input_tokens: 6260, cache_write_input_tokens: 0}
    iex> usage.cached_input_tokens / usage.input_tokens > 0.99
    true

`input_tokens` counts every prompt token, cached reads and cache writes
included, on every provider, so `cached_input_tokens / input_tokens` is
the share of the prompt served from the cache. A counter the provider did
not report is `nil`, never `0`.

What each provider does with the option:

* **OpenAI** (both endpoints) sends the key as `prompt_cache_key` and
  `retention: :long` as `prompt_cache_retention: "24h"`. The key steers
  routing; it does not guarantee a hit. Usage reports cache reads on
  both endpoints. The Responses endpoint also sends a cache-write
  counter, but it has been observed reading `0` on turns that created a
  cache entry, so treat it as advisory; Chat Completions may omit it, and
  it then stays `nil`. A cacheable prefix needs at least 1,024 tokens.
* **Anthropic** turns on automatic caching with a top-level
  `cache_control`, which moves the cache point forward as the
  conversation grows; `:long` asks for a one-hour lifetime. The key is
  never sent. Usage reports cache reads and cache writes. Changing the
  tools invalidates the whole cache, and a cache entry becomes readable
  only once the first response has begun, so parallel first requests all
  miss.
* **Gemini** caches implicitly on its own and takes no cache option, so
  `prompt_cache` is ignored without error. Usage reports cache reads when
  a hit happens; a miss leaves `cached_input_tokens` `nil`.

Caching is best-effort on every provider: a hit is likely, never
promised. Keep the prefix stable (append messages, don't rewrite earlier
ones) and above the provider's minimum length, which ranges from 512 to
4,096 tokens depending on the model.

## Where to next

* `tools.md` — for the manual tool flow that drives
  `:awaiting_tools`.
* `streaming.md` — for the event union the stream reducer folds.
* `examples/08_session_round_trip.exs` — runnable round-trip smoke
  test.
* `examples/09_ask_user.exs` — runnable ask-user halt and resume.
* `examples/15_per_tool_manual_session.exs` — runnable per-tool manual
  flow over `Session.*`.
* `examples/28_prompt_cache.exs` — runnable prompt caching over a
  three-turn session, printing each turn's cache reads and writes.
