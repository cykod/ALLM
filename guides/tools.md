# Tools

A "tool" is a function the model can call — a weather lookup, a database
query, an action in your app. ALLM ships a synchronous tool loop that
handles the round-trip: the model emits a tool call, your code runs the
tool, the result feeds back to the model, the model produces a final
reply. This guide covers the auto-loop, manual mode, per-tool manual
control, and the `{:ask_user, _}` suspension protocol.

## Declaring a tool

A tool has a name, a description, a JSON Schema for its arguments, and
an executor function:

```elixir
weather = ALLM.tool(
  name: "get_weather",
  description: "Returns the current weather for a city.",
  schema: %{
    "type" => "object",
    "properties" => %{
      "city" => %{"type" => "string"}
    },
    "required" => ["city"]
  }
)
```

`ALLM.tool/1` returns a `%ALLM.Tool{}` struct. Pass it to
`ALLM.request/2` (or `ALLM.chat/3` directly) via the `:tools` opt:

```elixir
req = ALLM.request([ALLM.user("Weather in Boston?")], tools: [weather])
```

The model now knows the tool exists. To actually run it when the model
asks, configure a tool executor on the engine.

## The default tool executor

`ALLM.ToolExecutor.Default` ships with the library. It takes a map of
tool-name → 1-arity function:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  tool_executor: {ALLM.ToolExecutor.Default, tools: %{
    "get_weather" => fn %{"city" => city} ->
      {:ok, %{temperature: 62, conditions: "sunny", city: city}}
    end
  }}
)
```

The function receives the parsed argument map and must return one of:

* `{:ok, term}` — JSON-encodable result. Default encoder is
  `ALLM.ToolResultEncoder.JSON`.
* `{:error, reason}` — tool raised a domain error. The chat loop
  continues by feeding the error back to the model (it can recover or
  abandon).
* `{:ask_user, prompt, metadata}` — suspend the loop and ask the user.

## The auto-loop

Pass the request to `chat/3`. The loop handles the round-trip:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [scripts: [
    ...>     [
    ...>       {:tool_call, %{id: "call_1", name: "get_weather", args: %{"city" => "Boston"}}},
    ...>       {:finish, :tool_calls}
    ...>     ],
    ...>     [
    ...>       {:text, "It's 62F and sunny in Boston."},
    ...>       {:finish, :stop}
    ...>     ]
    ...>   ]],
    ...>   tool_executor: {ALLM.ToolExecutor.Default, tools: %{
    ...>     "get_weather" => fn _args -> {:ok, %{temperature: 62}} end
    ...>   }}
    ...> )
    iex> weather = ALLM.tool(name: "get_weather", description: "weather", schema: %{"type" => "object"})
    iex> req = ALLM.request([ALLM.user("Weather?")], tools: [weather])
    iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
    ...>   ALLM.chat(engine, req)
    iex> text
    "It's 62F and sunny in Boston."

The loop ran two round-trips: the first produced a tool call, the
executor ran the tool, the result fed back in, and the second round-trip
produced the final assistant text.

`step/3` is the same minus the loop — one round-trip, one
`%StepResult{}` returned. Use it when you want explicit control over
each iteration.

## Manual mode (engine-wide)

Sometimes you don't want the loop to run tools at all — you want the
model's tool calls returned to your code so you can audit them, queue
them, or run them in a different process. Pass `mode: :manual` on the
engine:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  mode: :manual
)
```

Now `chat/3` halts after one round-trip whenever the model emits tool
calls. The `%ChatResult{}` carries `halted_reason: :tool_calls` and the
calls live on the final response's `tool_calls` field. You're
responsible for executing them and constructing a `:tool` message
containing each result, then re-issuing `chat/3` with the augmented
thread.

## Per-tool manual control

Mix-and-match: most tools auto, one tool manual. Set `manual: true` on
the tool definition:

```elixir
auto_tool = ALLM.tool(name: "get_weather", description: "...", schema: %{...})

manual_tool = ALLM.tool(
  name: "confirm_action",
  description: "Asks the user to confirm an irreversible action.",
  schema: %{...},
  manual: true
)

req = ALLM.request([ALLM.user("...")], tools: [auto_tool, manual_tool])
```

Under `mode: :auto` (the default), the chat orchestrator runs the auto
bucket eagerly. If the model ALSO calls a manual tool in the same
round, the loop halts with `halted_reason: :manual_tool_calls` and the
manual subset surfaces in `metadata.manual_tool_calls` (for
`chat/3`/`stream/3`) or `Session.pending_tool_calls` (for
`Session.start/3`).

After you've handled the manual tool, append a `:tool` message
containing the result and re-issue `chat/3` (or call
`Session.submit_tool_result/3` then `Session.continue/3`).

`examples/14_per_tool_manual.exs` and
`examples/15_per_tool_manual_session.exs` are runnable smoke tests of
this flow.

## `:on_tool_error` policy

When a tool returns `{:error, reason}`, the loop's default behaviour is
to feed the error back to the model and continue. Override with
`:on_tool_error`:

```elixir
ALLM.chat(engine, req, on_tool_error: :halt)
```

Legal values:

* `:continue` (default) — feed the error back to the model.
* `:halt` — halt the loop with `halted_reason: :tool_error`.
* A 2-arity function `fn tool_call, error -> :continue | :halt end` —
  decide per-call.

## Ask-user suspension

A tool can return `{:ask_user, prompt, metadata}` to halt the loop and
wait for human input. The chat loop returns with
`halted_reason: :ask_user`; the prompt and metadata live on the result.

```elixir
ask_tool = fn _args ->
  {:ask_user, "Confirm deleting the production database?", %{action: :delete_db}}
end
```

Resume by appending the user's reply as a `:user` message and re-issuing
`chat/3`, or by calling `Session.reply/4` if you're using sessions.

`examples/09_ask_user.exs` is a runnable smoke test.

## Streaming tool calls

`stream/3` is the streaming version of `chat/3`. Tool calls arrive as
`:tool_call_delta` events (the argument blob accumulates) followed by a
`:tool_call` event when the call is complete. The auto-loop dispatches
the tool, emits a `:tool_result` event, and continues the loop.

See `streaming.md` for the full event-shape table.

## Handler context (arity-2)

A tool handler may be 1-arity (`fn args -> ... end`) or 2-arity
(`fn args, context -> ... end`). ALLM detects the arity at dispatch
time and routes accordingly.

The arity-2 keyword list carries call context. Standard keys provided by
`ALLM.ToolExecutor.Default`:

| Key | Type | Notes |
|-----|------|-------|
| `:context` | `term()` | The opaque value passed via `ALLM.chat(engine, thread, context: ...)` or `Session.reply(session, msg, context: ...)`. Caller-defined shape. |
| `:session_id` | `String.t() \| nil` | The `%Session{}.id` when invoked through the Session API; `nil` for stateless `chat/3` / `step/3`. |
| `:tool_call` | `%ALLM.ToolCall{}` | The exact tool call the assistant emitted (`:id`, `:name`, `:arguments`). |
| `:engine` | `%ALLM.Engine{}` | The engine driving the call — handlers needing to issue downstream LLM calls reuse it via `ALLM.generate/3`. |
| `:request_id` | `String.t() \| nil` | Telemetry-correlation id from the parent span. |

```elixir
handler = fn args, ctx ->
  case Keyword.get(ctx, :context) do
    %{user_id: id} -> {:ok, lookup_for_user(id, args)}
    _ -> {:ok, args}
  end
end
```

Reach for the 1-arity form when handlers don't need context — it keeps
the call site simple. Custom keys in `:context` are passed through
unchanged so tests can inject arbitrary correlation data.

## Adapter-call cadence

Each turn of the tool loop consumes **two adapter calls**: one for the
assistant's tool-call request, and one for the post-tool-result
assistant turn. Token bills scale with `turn_count × 2`. Multi-tool
turns (parallel tool calls) still count as one assistant call each
direction — only the turn count drives the call multiplier.

A loop running three tool-call turns issues six adapter requests. With
`max_turns: 8` (the library default), the upper bound is sixteen calls
per `ALLM.chat/3` invocation.

## Structured response after tool loop

When you need the post-tool-loop assistant turn to return JSON matching
a schema (rather than free-form text), pass both `:response_format` and
`structured_finalize: true`:

```elixir
schema = ALLM.json_schema("answer", %{
  "type" => "object",
  "properties" => %{"answer" => %{"type" => "string"}},
  "required" => ["answer"]
})

{:ok, result} =
  ALLM.chat(engine, [ALLM.user("what is 6×7?")],
    response_format: schema,
    structured_finalize: true
  )

{:ok, %{"answer" => "42"}} = Jason.decode(result.final_response.output_text)
```

`structured_finalize: true` runs a two-pass orchestration: pass 1 runs
the tool loop freely (the model may emit any text or tool calls); pass 2
re-prompts the model with `response_format` constrained to the schema so
the *final* turn is guaranteed to match.

The result's metadata carries observability for the two passes:

* `result.metadata.structured_finalize.pass_1_halted` — the halt reason
  pass 1 reached (typically `:completed`).
* `result.metadata.structured_finalize.pass_1_response` — pass 1's
  raw `%Response{}` for inspection.

`result.steps` contains the merged step list from both passes so step
indexes remain stable across the two-pass boundary.

## Where to next

* `sessions.md` — multi-turn tool flows with persistence.
* `streaming.md` — tool calls in the event stream.
* `examples/03_single_tool_call.exs` — runnable single-tool smoke test.
* `examples/04_parallel_tool_calls.exs` — two tools in one round.
* `examples/07_manual_tool_round_trip.exs` — engine-wide manual mode.
