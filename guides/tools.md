# Tools

A "tool" is a function the model can call — a weather lookup, a database
query, an action in your app. ALLM ships a synchronous tool loop that
handles the round-trip: the model emits a tool call, your code runs the
tool, the result feeds back to the model, the model produces a final
reply. This guide covers the auto-loop, manual mode, per-tool manual
control, the `{:ask_user, _}` suspension protocol, and compact tools for
large tool catalogs.

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
asks, give the tool a `handler`.

## Handlers live on the tool

A tool runs its own handler. Pass a `handler:` function to `ALLM.tool/1`
and the default executor (`ALLM.ToolExecutor.Default`, wired
automatically) invokes it when the model calls the tool:

```elixir
weather = ALLM.tool(
  name: "get_weather",
  description: "Returns the current weather for a city.",
  schema: %{
    "type" => "object",
    "properties" => %{"city" => %{"type" => "string"}},
    "required" => ["city"]
  },
  handler: fn %{"city" => city} ->
    {:ok, %{temperature: 62, conditions: "sunny", city: city}}
  end
)

engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4.1-mini")
```

The engine's `:tool_executor` is a bare `module()` override for the
default executor — you never pass a `{module, tools: %{}}` tuple to it
(that raises `ArgumentError` at `Engine.new/1`; handlers belong on the
tool, not the engine).

The function receives the parsed argument map and must return one of:

* `{:ok, term}` — JSON-encodable result. Default encoder is
  `ALLM.ToolResultEncoder.JSON`.
* `{:error, reason}` — tool raised a domain error. The chat loop
  continues by feeding the error back to the model (it can recover or
  abandon).
* `{:ask_user, prompt, metadata}` — suspend the loop and ask the user.

## The auto-loop

Pass the messages to `chat/3` — the tools ride on the engine. The loop
handles the round-trip:

    iex> weather = ALLM.tool(
    ...>   name: "get_weather",
    ...>   description: "weather",
    ...>   schema: %{"type" => "object"},
    ...>   handler: fn _args -> {:ok, %{temperature: 62}} end
    ...> )
    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [stream_script: [
    ...>     [
    ...>       {:tool_call, id: "call_1", name: "get_weather", arguments: %{"city" => "Boston"}},
    ...>       {:finish, :tool_calls}
    ...>     ],
    ...>     [
    ...>       {:text, "It's 62F and sunny in Boston."},
    ...>       {:finish, :stop}
    ...>     ]
    ...>   ]],
    ...>   tools: [weather]
    ...> )
    iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
    ...>   ALLM.chat(engine, [ALLM.user("Weather?")])
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
them, or run them in a different process. `:mode` is a **per-call opt**
(not an engine field — passing `mode:` to `Engine.new/1` raises
`KeyError`). Pass `mode: :manual` at the call site:

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4.1-mini")

ALLM.chat(engine, req, mode: :manual)
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

<!-- fence-check: skip — the `%{...}` schema bodies are elisions for the reader, not literal maps -->
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
`Session.submit_tool_result/3` then `Session.continue(engine, session, nil)`).

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
`:tool_call_started` then `:tool_call_delta` events (the argument blob
accumulates) followed by a `:tool_call_completed` event when the call is
complete. The auto-loop dispatches the tool, emitting
`:tool_execution_started` → `:tool_execution_completed` →
`:tool_result_encoded`, and continues the loop.

See `streaming.md` for the full event-shape table.

## Handler context (arity-2)

A tool handler may be 1-arity (`fn args -> ... end`) or 2-arity
(`fn args, context -> ... end`). ALLM detects the arity at dispatch
time and routes accordingly.

The arity-2 keyword list carries call context. Standard keys provided by
`ALLM.ToolExecutor.Default`:

| Key | Type | Notes |
|-----|------|-------|
| `:context` | `term()` | The opaque value passed via `ALLM.chat(engine, thread, context: ...)` or `Session.reply(engine, session, msg, context: ...)`. Caller-defined shape. |
| `:session_id` | `String.t() \| nil` | The `%Session{}.id` when invoked through the Session API; `nil` for stateless `chat/3` / `step/3`. |
| `:tool_call` | `%ALLM.ToolCall{}` | The exact tool call the assistant emitted (`:id`, `:name`, `:arguments`). |
| `:engine` | `%ALLM.Engine{}` | The engine driving the call — handlers needing to issue downstream LLM calls reuse it via `ALLM.generate/3`. |
| `:request_id` | `String.t() \| nil` | Telemetry-correlation id from the parent span. |

<!-- fence-check: skip — `lookup_for_user/2` stands in for an application function the reader supplies -->
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

## Compact tools

Every tool you give the model costs prompt tokens on every step: its
full description and its whole JSON Schema are sent each time. With a
large tool catalog most of that is spent on tools the model never calls.
Mark those tools `compact: true` and the model sees a one-line usage
summary instead, and can ask for the full definition when it needs it.

A compact tool is sent to the model as a **stub**. The stub has:

* the tool's real name, so the model can call it directly;
* a one-line description: the first sentence of `:description` (or
  your `:summary`), then an `Args:` hint listing the argument names
  declared in the schema's `"properties"`, required ones first and
  optional ones in brackets, then `[compact]`;
* the bare schema `{"type": "object"}`.

Whenever at least one compact tool is present, one extra tool named
`tool_help` is added. The model calls it with a list of tool names and
gets back each tool's full description and JSON Schema as text.
`ALLM.ToolHelp.project/2` shows exactly what the model receives:

    iex> issue = ALLM.tool(
    ...>   name: "create_issue",
    ...>   description: "Create a new issue in a repository. The issue number and URL are returned.",
    ...>   schema: %{
    ...>     "type" => "object",
    ...>     "properties" => %{
    ...>       "repo" => %{"type" => "string", "description" => "owner/name"},
    ...>       "title" => %{"type" => "string"},
    ...>       "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
    ...>     },
    ...>     "required" => ["repo", "title"]
    ...>   },
    ...>   compact: true
    ...> )
    iex> [stub, help] = ALLM.ToolHelp.project([issue], nil)
    iex> stub.description
    "Create a new issue in a repository. Args: repo, title [labels] [compact]"
    iex> stub.schema
    %{"type" => "object"}
    iex> help.name
    "tool_help"

Only the list sent to the model is compacted. When the model calls a
compact tool, your handler runs with the arguments exactly as it would
for a full tool.

### A round trip

The chat loop answers `tool_help` itself; you write no handler for it.
In this scripted run the model first asks for help, then calls
`create_issue` without its required `repo`, gets a usage error back,
and corrects itself:

    iex> issue = ALLM.tool(
    ...>   name: "create_issue",
    ...>   description: "Create a new issue in a repository. The issue number and URL are returned.",
    ...>   schema: %{
    ...>     "type" => "object",
    ...>     "properties" => %{"repo" => %{"type" => "string"}, "title" => %{"type" => "string"}},
    ...>     "required" => ["repo", "title"]
    ...>   },
    ...>   handler: fn args -> {:ok, %{number: 7, repo: args["repo"]}} end,
    ...>   compact: true
    ...> )
    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [stream_script: [
    ...>     [{:tool_call, id: "c1", name: "tool_help", arguments: %{"names" => ["create_issue"]}}, {:finish, :tool_calls}],
    ...>     [{:tool_call, id: "c2", name: "create_issue", arguments: %{"title" => "Login broken"}}, {:finish, :tool_calls}],
    ...>     [{:tool_call, id: "c3", name: "create_issue", arguments: %{"repo" => "acme/web", "title" => "Login broken"}}, {:finish, :tool_calls}],
    ...>     [{:text, "Filed issue #7."}, {:finish, :stop}]
    ...>   ]],
    ...>   tools: [issue]
    ...> )
    iex> {:ok, result} = ALLM.chat(engine, [ALLM.user("File a bug: login is broken in acme/web.")])
    iex> [help, usage, created] = for m <- result.thread.messages, m.role == :tool, do: m.content
    iex> help |> String.split("\n") |> Enum.take(2)
    ["## create_issue", "Create a new issue in a repository. The issue number and URL are returned."]
    iex> usage |> Jason.decode!() |> Map.fetch!("error") |> String.split("\n") |> hd()
    "missing required argument(s): repo"
    iex> created
    ~s({"number":7,"repo":"acme/web"})
    iex> result.final_response.output_text
    "Filed issue #7."

Things to know:

* **The usage error replaces the handler call.** A compact tool called
  without one of its top-level `"required"` arguments does not run its
  handler; the model gets back an error carrying the tool's full help.
  It goes through your `:on_tool_error` policy like any other tool
  error, so `on_tool_error: :halt` stops the loop there. Only the
  presence of required keys is checked, not their types. Full
  (non-compact) tools are never checked.
* **Each `tool_help` call is a round trip.** It uses a turn of
  `max_turns`, and its result counts as a tool result for `halt_when`.
  The model can skip it whenever the `Args:` hint is enough.
* **The tool list sent to the model never changes during a run**, so
  provider prompt caches keep working. Learning about a tool adds a
  message to the conversation, not a tool definition.
* **Forcing a compact tool sends it in full.** When `:tool_choice`
  names one compact tool, that tool goes out with its whole description
  and schema, so the model does not have to guess its arguments.
* **The summary is used verbatim.** Without a non-empty `:summary`,
  the stub uses the first sentence of the description (`summary: ""`
  falls back too). An explicit non-empty `:summary` is copied as-is, so
  keep it to one line: a line break in it becomes a line break in the
  stub.
* **Don't name your own tool `tool_help`** alongside a compact tool.
  The request is rejected before it is sent, with
  `{:tools, :duplicate_name}`.
* **Under `mode: :manual` you run `tool_help` too.** Its call comes
  back to you like any other. Submit `ALLM.ToolHelp.answer/2` as its
  result. With per-tool `manual: true`, `tool_help` still runs
  automatically.

Compact tools suit the long tail of a catalog. Keep the few tools the
model calls most often in full, so their argument types reach the
provider, and compact the rest. `examples/21_compact_tools.exs` runs
the same task with and without compact tools against a real provider
and prints the input-token counts of both.

## Where to next

* `sessions.md` — multi-turn tool flows with persistence.
* `streaming.md` — tool calls in the event stream.
* `examples/03_single_tool_call.exs` — runnable single-tool smoke test.
* `examples/04_parallel_tool_calls.exs` — two tools in one round.
* `examples/07_manual_tool_round_trip.exs` — engine-wide manual mode.
* `examples/21_compact_tools.exs` — compact tools against a real
  provider, with and without compaction.
