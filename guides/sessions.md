# Sessions

The `ALLM.Session` API wraps the chat loop with persistent state. A
`%Session{}` carries the engine, the thread, the status (idle, halted
for tools, halted for user, terminated), pending tool calls, and any
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
    iex> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("Hi.")])
    iex> session.status
    :idle

A `:idle` session has completed its turn and is ready for the next one.
The `session.thread` field carries the full conversation; serialize the
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
    iex> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("Hi.")])
    iex> {:ok, session} = ALLM.Session.reply(session, engine, "Bye.")
    iex> session.status
    :idle

Note `Session.reply/4` takes the engine again — engines are not
persisted on the session (they hold non-serializable bits like Finch
names and key resolvers). The session and engine pair to make a turn.

## The status union

| Status | Meaning | Caller action |
|---|---|---|
| `:idle` | Last turn completed; ready for next reply | Call `reply/4` or `continue/3` |
| `:halted_for_tools` | Loop halted on manual tool calls | Run the manual tools, call `submit_tool_result/3`, then `continue/3` |
| `:halted_for_user` | Loop halted on `{:ask_user, _, _}` | Append user reply via `reply/4` |
| `:terminated` | Session ended (e.g., max iterations, fatal error) | New session if you want to continue |

Pattern-match on `session.status` to drive your application's UI.

## Manual tool flow

When `session.status == :halted_for_tools`, the pending calls live on
`session.pending_tool_calls`. After you run them externally, submit
each result and continue:

```elixir
{:ok, session} = ALLM.Session.submit_tool_result(session, "call_1", %{ok: true})
{:ok, session} = ALLM.Session.continue(session, engine)
```

`submit_tool_result/3` mutates the session in-memory; `continue/3`
re-enters the chat loop.

## Persistence patterns

### Serialize to ETF (BEAM-to-BEAM)

Best for a process-restart-safe queue or an ETS table:

```elixir
binary = :erlang.term_to_binary(session)
# ... store, fetch, restart ...
session = :erlang.binary_to_term(binary)
```

### Serialize to JSON (cross-language, DB column)

`ALLM.Serializer.to_json!/1` and `from_json/1` round-trip without loss:

```elixir
json = ALLM.Serializer.to_json!(session)
{:ok, ^session} = ALLM.Serializer.from_json(json)
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
{:ok, session} = ALLM.Session.reply(session, engine, user_input)
```

## The streaming reducer

`Session.stream_start/3` and `Session.stream_reply/4` return a stream of
events plus a final updated session. The `ALLM.Session.StreamReducer`
helper folds the event stream into both — useful when you want to push
events to a Phoenix LiveView or websocket while still ending up with a
persisted session.

```elixir
{:ok, stream} = ALLM.Session.stream_reply(session, engine, "Hello?")

{:ok, session, events} =
  ALLM.Session.StreamReducer.run(stream, fn event ->
    Phoenix.PubSub.broadcast(MyApp.PubSub, "chat:#{session.id}", event)
  end)
```

The reducer hands each event to your callback (for side effects),
returns the final updated session, AND collects every event into a list
for replay or testing.

## Round-trip safety

A session is round-trip safe iff it never carries a non-serializable
value. ALLM enforces this on construction — engines (which DO carry
non-serializable bits) are passed at call time, not stored on the
session. Verify in your tests:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("hi")])
    iex> binary = :erlang.term_to_binary(session)
    iex> ^session = :erlang.binary_to_term(binary)
    iex> session.status
    :idle

## Where to next

* `tools.md` — for the manual tool flow that drives
  `:halted_for_tools`.
* `streaming.md` — for the event union the stream reducer folds.
* `examples/08_session_round_trip.exs` — runnable round-trip smoke
  test.
* `examples/09_ask_user.exs` — runnable ask-user halt and resume.
* `examples/15_per_tool_manual_session.exs` — runnable per-tool manual
  flow over `Session.*`.
