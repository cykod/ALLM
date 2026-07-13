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

## Where to next

* `tools.md` — for the manual tool flow that drives
  `:awaiting_tools`.
* `streaming.md` — for the event union the stream reducer folds.
* `examples/08_session_round_trip.exs` — runnable round-trip smoke
  test.
* `examples/09_ask_user.exs` — runnable ask-user halt and resume.
* `examples/15_per_tool_manual_session.exs` — runnable per-tool manual
  flow over `Session.*`.
