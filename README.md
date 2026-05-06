# ALLM (Agentic LLM Libray)

> **⚠ Alpha software.** ALLM is still taking shape — public APIs, wire
> translation, and on-disk session shapes can change without notice
> between releases. Do not use it in production. Bug reports, design
> feedback, and adapter PRs are very welcome while we iterate toward a
> stable surface.

Provider-neutral LLM execution and agentic loops for Elixir. One
engine surface — swap the adapter to retarget OpenAI, Anthropic, or
Gemini without touching call sites. Streaming is the primitive: every
synchronous call is a fold over a token-by-token event stream, so you
can drop into deltas whenever a UI needs them and pop back up when it
doesn't. Threads, tools, and sessions are plain serializable data —
persist them, ship them between nodes, resume them tomorrow. The same
composable surface scales from one-shot generation through multi-turn
chat to tool-using agents, and runs equally well with a single global
API key or per-call keys for multi-tenant SaaS.

ALLM splits an LLM call into four conceptual layers:

1. **Layer A — Serializable data.** `ALLM.Message`, `ALLM.Request`,
   `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.Event`, … plain
   structs that round-trip through `:erlang.term_to_binary/1` and JSON.
2. **Layer B — Runtime.** `ALLM.Engine` plus the `ALLM.Adapter`,
   `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, and `ALLM.ToolResultEncoder`
   behaviours. Holds the non-serializable deps (modules, funs, Finch
   names, keys resolved at call time).
3. **Layer C — Stateless execution.** `ALLM.generate/3`,
   `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`,
   `ALLM.chat/3`, `ALLM.stream/3`. Each call takes an engine explicitly.
4. **Layer D — Stateful continuation.** `ALLM.Session.start/3`,
   `ALLM.Session.reply/4`, `ALLM.Session.continue/3`, `ALLM.Session.step/3`,
   plus their streaming counterparts (`stream_start/3`, `stream_reply/4`,
   `stream_step/3`) over a persisted `%ALLM.Session{}`.

**Streaming is the primitive execution model.** Every non-streaming
function is implemented as a reducer over a stream of `ALLM.Event` values.
You can always drop down to the streaming variant to get token-by-token
visibility — and back up to the synchronous variant when you don't need
it.

The canonical spec is
[`steering/allm_engine_session_streaming_spec_v0_2.md`](steering/allm_engine_session_streaming_spec_v0_2.md)
(in the source tree).

## Installation

Add ALLM to your `mix.exs` deps:

```elixir
def deps do
  [
    {:allm, "~> 0.3"}
  ]
end
```

Run `mix deps.get`. Toolchain floor: Elixir `~> 1.17`, Erlang/OTP 27+.

## Hello, ALLM

Drive a one-shot generation against the deterministic
`ALLM.Providers.Fake` adapter — no API key, no network:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
  )

{:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
  ALLM.chat(engine, [ALLM.user("Hi.")])

text
# => "Hello, ALLM!"
```

To run against a real provider, swap the adapter and supply an API key
via env (see [Real providers](#real-providers) below):

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-4.1-mini"
  )

{:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("Say hi.")]))
IO.puts(response.output_text)
```

## Common patterns

A grand tour of what calling ALLM looks like in practice. Every snippet
below uses the same `engine` value — pick a provider once, and every
call site keeps working when you swap.

### 0. Pick a provider

```elixir
# OpenAI
engine =
  ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.4-nano")

# Anthropic — same engine surface, different adapter
engine =
  ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-sonnet-4-6")

# Gemini
engine =
  ALLM.Engine.new(adapter: ALLM.Providers.Gemini, model: "gemini-3-flash-preview")
```

API keys come from `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` /
`GEMINI_API_KEY` by default; override per-call with `api_key:` for
multi-tenant SaaS. Engines are serializable — they hold the adapter,
default model, declared tools, and retry policy, but never a key.

### 1. Generate — single round-trip

```elixir
# Synchronous — get the final response
{:ok, %ALLM.Response{output_text: text}} =
  ALLM.generate(engine, ALLM.request([ALLM.user("Name three primes.")]))

# Streaming — same engine, same request, token-by-token
{:ok, stream} =
  ALLM.stream_generate(engine, ALLM.request([ALLM.user("Name three primes.")]))

Enum.each(stream, fn
  {:text_delta, %{delta: t}} -> IO.write(t)
  _other                     -> :ok
end)
```

`generate/3` is implemented as a fold over `stream_generate/3` — every
non-streaming entry point has a streaming sibling. Streaming is the
primitive; sync is the convenience.

### 2. Structured output — same call, parsed shape

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "age"  => %{"type" => "integer"}
  },
  "required" => ["name", "age"]
}

req =
  ALLM.request(
    [ALLM.user("Pick a name and age for a fantasy character.")],
    response_format: ALLM.json_schema("person", schema)
  )

{:ok, response} = ALLM.generate(engine, req)
{:ok, %{"name" => _name, "age" => _age}} = Jason.decode(response.output_text)
```

OpenAI uses native JSON-schema mode; Anthropic implements the same
surface via tool-forcing; Gemini uses `responseSchema`. Caller code is
identical across all three.

### 3. Chat — multi-turn loop

```elixir
{:ok, result} =
  ALLM.chat(engine, [
    ALLM.system("You are a concise assistant."),
    ALLM.user("Hi! Who are you?")
  ])

result.final_response.output_text
# => "I'm a concise assistant. How can I help?"

# Continue the conversation by appending and re-issuing
followup =
  result.thread
  |> ALLM.Thread.add_message(ALLM.user("Tell me a joke."))

{:ok, result} = ALLM.chat(engine, followup)
```

`chat/3` runs the full model-tool loop until completion and returns a
`%ChatResult{}` with the final response, the accumulated thread, and
per-step records. The streaming sibling, `ALLM.stream/3`, emits the
same lifecycle as events.

### 4. Tools — declare, run, done

```elixir
weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return the current weather for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    },
    handler: fn %{"city" => city} ->
      {:ok, %{forecast: "sunny", city: city}}
    end
  )

engine = ALLM.Engine.put_tools(engine, [weather])

{:ok, result} =
  ALLM.chat(engine, [ALLM.user("What's the weather in Boston?")])

result.final_response.output_text
# => "It's sunny in Boston."

length(result.steps)
# => 2  — model called the tool, then summarized
```

The handler is a plain Elixir function. The engine runs it, encodes
the result for the next turn (`ToolResultEncoder.JSON` by default),
and feeds it back to the model. Need to inspect or transform a tool
call before it runs? `mode: :manual` halts the loop and hands control
back to you — see [Tools, manual mode](#tools-manual-mode-caller-driven)
below.

### 5. Sessions — pick up where you left off

```elixir
# Earlier — store the session after a turn:
#     binary = :erlang.term_to_binary(session)
#     MyApp.Repo.update!(conversation, session_blob: binary)

# Later, possibly on a different node, in a different request:
session = :erlang.binary_to_term(blob_from_db)

{:ok, session, result} =
  ALLM.Session.reply(engine, session, "What did I just ask?")

session.status
# => :completed
result.final_response.output_text
# => "You asked about the weather in Boston."
```

`%ALLM.Session{}` bundles the thread with a status (`:idle`,
`:awaiting_user`, `:awaiting_tools`, `:completed`, `:error`) and any
pending tool calls or ask-user prompt. Round-trip it through ETF or
JSON, hand it to a worker, store it in a database column — when
you're ready, hand it back to `ALLM.Session.reply/4` (or
`stream_reply/4`).

## The four layers, in order

### Layer A — Build messages and requests

Plain data constructors. No engine, no network.

```elixir
messages = [
  ALLM.system("You are a concise assistant."),
  ALLM.user("Name three primes.")
]

request =
  ALLM.request(messages,
    model: "gpt-4.1-mini",
    temperature: 0.2
  )

# Optional explicit validation (otherwise runs at the adapter boundary)
:ok = ALLM.Validate.request(request)

# Round-trip through JSON or ETF — safe to persist
json    = ALLM.Serializer.to_json!(request)
{:ok, ^request} = ALLM.Serializer.from_json(json)
binary  = :erlang.term_to_binary(request)
^request = :erlang.binary_to_term(binary)
```

Layer A is what you put in your database, send over the wire between
nodes, or hand to a worker process. It carries **no** PIDs, refs, funs,
or API keys.

### Layer B — Configure an engine

An `%ALLM.Engine{}` is the one place that holds your provider adapter,
default model, declared tools, and per-call retry policy. Engines are
themselves serializable (no keys live on them).

```elixir
weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return a weather forecast for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    },
    handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
  )

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-4.1-mini",
    tools: [weather],
    params: %{temperature: 0}
  )
```

Per-call options always win over engine defaults — the engine sets the
floor.

### Layer C — Stateless execution

You hand the engine, a request (or message list), and per-call opts.
There's no hidden state.

#### Non-streaming: `ALLM.generate/3`

One adapter round-trip; no tool loop, no continuation.

```elixir
{:ok, %ALLM.Response{} = response} =
  ALLM.generate(engine, ALLM.request([ALLM.user("Hello!")]))

response.output_text     # => "Hi! How can I help?"
response.finish_reason   # => :stop
response.usage           # => %ALLM.Usage{input_tokens: …, output_tokens: …}
```

#### Streaming: `ALLM.stream_generate/3`

Returns a lazy `Enumerable` of `ALLM.Event` tagged tuples. No event
fires until you reduce.

```elixir
{:ok, stream} =
  ALLM.stream_generate(engine, ALLM.request([ALLM.user("Stream me a haiku.")]))

Enum.each(stream, fn
  {:text_delta, %{delta: t}}                  -> IO.write(t)
  {:message_completed, %{finish_reason: fr}}  -> IO.puts("\n[done] #{fr}")
  _other                                      -> :ok
end)
```

`generate/3` is implemented as a reducer over `stream_generate/3` —
when you want the final `%Response{}` and don't care about deltas, use
`generate/3`; when you want progressive UI updates, use
`stream_generate/3`. Same engine, same request, same result on
completion.

#### Tools, the synchronous loop: `ALLM.chat/3`

Multi-turn loop that runs declared tool handlers automatically and
returns a `%ALLM.ChatResult{}` when the loop halts.

```elixir
{:ok, result} =
  ALLM.chat(engine, [ALLM.user("What's the weather in Boston?")])

result.halted_reason       # => :completed
length(result.steps)       # => 2  (model called the tool, then summarised)
result.final_response.output_text
# => "It's sunny in Boston."
```

`chat/3` honours `:max_turns`, a `:halt_when` callback, and
`:on_tool_error` (`:continue` / `:halt` / a fun); see `ALLM.chat/3` for
the full halt-reason table.

#### Tools, streaming: `ALLM.stream/3`

A lazy event stream that includes adapter events, tool-execution
events, one `:step_completed` per turn, and exactly one trailing
`:chat_completed` carrying the final `%ChatResult{}`.

```elixir
{:ok, stream} = ALLM.stream(engine, [ALLM.user("Weather in Boston?")])

stream
|> Enum.each(fn
  {:text_delta, %{delta: t}}              -> IO.write(t)
  {:tool_execution_started, %{name: n}}   -> IO.puts("\n[tool] #{n}")
  {:step_completed, %{response: r}}       -> IO.puts("\n[step] #{r.finish_reason}")
  {:chat_completed, %{result: r}}         -> IO.puts("\n[done] #{r.halted_reason}")
  _                                       -> :ok
end)
```

#### Tools, manual mode (caller-driven)

When you want to inspect or transform tool calls before executing them,
pass `mode: :manual`. The loop halts on the first `:tool_calls`
response; you submit the tool result yourself and re-issue `chat/3`.

```elixir
{:ok, r1} = ALLM.chat(engine, messages, mode: :manual, tool_choice: :auto)
r1.halted_reason
# => :manual_tool_calls

[%ALLM.ToolCall{id: id, arguments: args}] = r1.final_response.tool_calls

# Compute the result yourself (e.g. call your own service):
result = my_weather_service(args["city"])

augmented =
  ALLM.Thread.add_message(r1.thread, %ALLM.Message{
    role: :tool,
    tool_call_id: id,
    content: Jason.encode!(result)
  })

{:ok, r2} = ALLM.chat(engine, augmented, mode: :manual)
r2.final_response.output_text
```

#### One-step variants: `ALLM.step/3` and `ALLM.stream_step/3`

When you want exactly one adapter round-trip (plus auto-executed tool
calls) but **not** the multi-turn loop, use `step/3`:

```elixir
{:ok, %ALLM.StepResult{} = sr} =
  ALLM.step(engine, [ALLM.user("Weather in NYC?")])

sr.done?           # false — model called a tool; you can keep going
sr.tool_results    # [%ALLM.Message{role: :tool, ...}]
sr.thread          # the augmented thread, ready for another `step/3`
```

The streaming counterpart `ALLM.stream_step/3` emits the same adapter
events plus the tool-execution events, terminating in one
`:step_completed`.

#### Structured output

Pass a JSON-Schema response format via `ALLM.json_schema/3`:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{"name" => %{"type" => "string"}, "age" => %{"type" => "integer"}},
  "required" => ["name", "age"]
}

req =
  ALLM.request(
    [ALLM.user("Pick a name and age.")],
    response_format: ALLM.json_schema("person", schema)
  )

{:ok, r} = ALLM.generate(engine, req)
{:ok, %{"name" => _, "age" => _}} = Jason.decode(r.output_text)
```

OpenAI uses native `:json_schema` with `strict: true`; Anthropic
implements the same surface via the tool-forcing pattern (a synthetic
tool is forced and its arguments are lifted to `output_text`). Same
caller code, identical semantic shape.

### Layer D — Stateful continuation (`ALLM.Session`)

`%ALLM.Session{}` is a serializable struct that bundles a `Thread` with
a status (`:idle`, `:awaiting_user`, `:awaiting_tools`, `:completed`,
`:error`) and any pending tool calls / question. Every Layer C
operation has a session-aware sibling that takes and returns a
`%Session{}`.

```elixir
{:ok, session, _result} =
  ALLM.Session.start(engine, [
    ALLM.system("You are a friendly assistant."),
    ALLM.user("Hi!")
  ])

# Persist however you like — JSON, ETF binary, your DB column of choice.
binary = :erlang.term_to_binary(session)

# … later, possibly on a different node …
session = :erlang.binary_to_term(binary)

{:ok, session, result} = ALLM.Session.reply(engine, session, "Tell me a joke.")
session.status                                # => :completed
result.final_response.output_text             # => "Why did …"
```

Streaming sessions return a stream you fold through
`ALLM.Session.StreamReducer` to recover the post-call `%Session{}`:

```elixir
{:ok, stream} = ALLM.Session.stream_reply(engine, session, "Another?")

{updated_session, %ALLM.ChatResult{} = result} =
  stream
  |> Enum.reduce(ALLM.Session.StreamReducer.new(session), fn event, acc ->
    case event do
      {:text_delta, %{delta: t}} -> IO.write(t)
      _                          -> :ok
    end

    ALLM.Session.StreamReducer.apply_event(acc, event)
  end)
  |> ALLM.Session.StreamReducer.finalize()
```

#### Manual tool cycle on a session

When the model calls a tool and you want to provide the result yourself
(rather than letting the engine's declared handler run), pass
`mode: :manual`:

```elixir
{:ok, session, _result} =
  ALLM.Session.start(engine, [ALLM.user("Weather in Boston?")], mode: :manual)

session.status            # => :awaiting_tools
session.pending_tool_calls
# => [%ALLM.ToolCall{id: "c0", name: "get_weather", arguments: %{"city" => "Boston"}}]

session = ALLM.Session.submit_tool_result(session, "c0", %{forecast: "sunny"})
session.status            # => :idle

{:ok, session, _result} = ALLM.Session.continue(engine, session, nil)
session.status            # => :completed
```

#### Ask-user suspension

A tool handler can return `{:ask_user, question}` to halt the loop and
prompt the caller. The session captures the question and resumes when
you call `reply/4`:

```elixir
{:ok, session, _result} = ALLM.Session.start(engine, messages)

case session.status do
  :awaiting_user ->
    answer = MyApp.UI.prompt(session.pending_question)
    {:ok, session, _} = ALLM.Session.reply(engine, session, answer)
    session

  :completed ->
    session
end
```

## Real providers

ALLM ships three production adapters:

- **`ALLM.Providers.OpenAI`** — Chat Completions and Responses
  endpoints; auto-routes by model. Image generation via
  `ALLM.Providers.OpenAI.Images` (`dall-e-2`, `dall-e-3`,
  `gpt-image-1`).
- **`ALLM.Providers.Anthropic`** — Messages API; chat-vision input
  only (no image generation).
- **`ALLM.Providers.Gemini`** — Google Generative Language API
  (`generateContent` / `streamGenerateContent`); chat-vision input.
  Image generation via `ALLM.Providers.Gemini.Images`
  (`gemini-3.1-flash-image-preview`).

Configure via env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`) or per-call:

```elixir
{:ok, response} = ALLM.generate(engine, request, api_key: tenant_key)
```

The per-call `:api_key` opt has the highest precedence in `ALLM.Keys`'s
five-level resolution chain — it overrides env vars, app config, and
the runtime store. The engine itself is safe to cache and share across
tenants.

See [`examples/README.md`](examples/README.md) for the full runnable
smoke set:

```bash
OPENAI_API_KEY=sk-...     mix run examples/run_all.exs
ANTHROPIC_API_KEY=sk-...  ALLM_PROVIDER=anthropic mix run examples/run_all.exs
GEMINI_API_KEY=...        ALLM_PROVIDER=gemini    mix run examples/run_all.exs
```

## Vision input

`ALLM.Message.content` accepts a list of content parts —
`[%ALLM.TextPart{}, %ALLM.ImagePart{}]` — for vision-capable models.
OpenAI (Chat Completions and Responses), Anthropic (Messages API),
and Gemini (`generateContent`) all translate the part list to their
respective wire shapes:

```elixir
img = ALLM.Image.from_file("arch.png")

msg = %ALLM.Message{
  role: :user,
  content: [
    %ALLM.TextPart{text: "What's the failure mode in this diagram?"},
    %ALLM.ImagePart{image: img, detail: :high}
  ]
}

{:ok, %ALLM.Response{output_text: text}} =
  ALLM.generate(engine, ALLM.request([msg]))
```

The same engine + message shape works across all three providers. See
[`examples/12_vision_input.exs`](examples/12_vision_input.exs) for a
runnable multi-provider smoke test.

## Image generation

ALLM ships an image-generation surface parallel to the chat surface.
Generation, editing (inpaint), and variations are all served via
`ALLM.generate_image/3`, `ALLM.edit_image/4`, and
`ALLM.image_variations/3` against an engine carrying an
`:image_adapter`. Two production image adapters ship today:
`ALLM.Providers.OpenAI.Images` (`dall-e-2`, `dall-e-3`, `gpt-image-1`;
generate / edit / variations) and `ALLM.Providers.Gemini.Images`
(`gemini-3.1-flash-image-preview`; generate / edit). Anthropic has no
image-generation surface.

```elixir
engine =
  ALLM.Engine.new(
    image_adapter: ALLM.Providers.OpenAI.Images,
    model: "dall-e-2"
  )

{:ok, %ALLM.ImageResponse{images: [image | _]}} =
  ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256")

{:ok, png_bytes} = ALLM.Image.to_binary(image)
File.write!("kestrel.png", png_bytes)
```

For deterministic tests, use `ALLM.Providers.FakeImages`:

```elixir
img = ALLM.Image.from_binary(<<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")

engine =
  ALLM.Engine.new(
    image_adapter: ALLM.Providers.FakeImages,
    adapter_opts: [image_script: [{:ok, [img]}]]
  )

{:ok, _response} = ALLM.generate_image(engine, "anything")
```

See [`examples/10_generate_image.exs`](examples/10_generate_image.exs),
[`examples/11_edit_image.exs`](examples/11_edit_image.exs), and
[`examples/13_image_variations.exs`](examples/13_image_variations.exs)
for live-call worked examples.

## Events

`ALLM.Event` is a closed tagged-tuple union; every streaming function
emits values from this set:

| Event                          | When                                          |
|--------------------------------|-----------------------------------------------|
| `{:text_delta, payload}`       | Token / text fragment                         |
| `{:tool_call_delta, payload}`  | Streaming tool-call argument fragment         |
| `{:message_started, payload}`  | One per assistant message                     |
| `{:message_completed, payload}`| One per assistant message (carries `:message`, `:finish_reason`) |
| `{:tool_execution_started, _}` | Per tool, before the handler runs (chat-layer) |
| `{:tool_execution_completed,_}`| Per tool, after the handler returns (chat-layer) |
| `{:tool_result_encoded, _}`    | After the result is encoded for the next turn |
| `{:ask_user_requested, _}`     | Handler returned `{:ask_user, _}`             |
| `{:step_completed, _}`         | One per chat step (carries `:response`, `:thread`) |
| `{:chat_completed, _}`         | Exactly one terminal event (carries `:result`) |
| `{:raw_chunk, payload}`        | Raw provider chunk (off by default, except `{:usage, _}`) |
| `{:error, struct}`             | Mid-stream adapter error (folds into `response.finish_reason`) |

Stream filters: `:emit_text_deltas`, `:emit_tool_deltas`,
`:include_raw_chunks`, and `:on_event` (an observer callback) are
accepted by every streaming entry point.

## Examples directory

The [`examples/`](examples/) directory ships 15 runnable scripts that
double as integration tests. Each is self-asserting (`unless ok?, do:
System.halt(1)`) and runs against a real provider. The **Layer**
column maps each script onto the four-layer API so you can find a
worked example at the level you're working at; the **Providers**
column shows which provider arms the script runs on (per the
`# Provider:` header marker; otherwise all three).

| Script | Layer | Providers | Demonstrates |
|--------|-------|-----------|--------------|
| `01_plain_text.exs` | C | all | `ALLM.generate/3` non-streaming |
| `02_streaming_text.exs` | C | all | `ALLM.stream_generate/3` SSE consumption |
| `03_single_tool_call.exs` | C | all | `ALLM.chat/3` with one tool |
| `04_parallel_tool_calls.exs` | C | all | Two tools called in one turn |
| `05_multi_turn_chat.exs` | C | all | Thread accumulation across `chat/3` calls |
| `06_structured_output.exs` | C | all | `response_format: ALLM.json_schema(…)` |
| `07_manual_tool_round_trip.exs` | C | all | `mode: :manual` halt + caller-supplied result |
| `08_session_round_trip.exs` | D | all | `Session` survives ETF round-trip |
| `09_ask_user.exs` | D | all | `{:ask_user, _, _}` halt and follow-up turn |
| `10_generate_image.exs` | C | openai, gemini | `ALLM.generate_image/3` |
| `11_edit_image.exs` | C | openai, gemini | `ALLM.edit_image/4` with mask |
| `12_vision_input.exs` | C | all | Multimodal `[TextPart, ImagePart]` content |
| `13_image_variations.exs` | C | openai | `ALLM.image_variations/3` |
| `14_per_tool_manual.exs` | C | openai, anthropic | Per-tool `manual: true` via `chat/3` |
| `15_per_tool_manual_session.exs` | D | openai, anthropic | Per-tool manual via `Session.start → submit_tool_result → continue` |

Layer A (data structs) and Layer B (engine config) don't get
dedicated scripts — every script above starts with a few lines of
Layer-A `ALLM.user/1` / `ALLM.request/2` calls and a Layer-B
`ExamplesHelpers.engine/1` call, so each Layer-C/D script is itself
an end-to-end demo of the layers it sits on top of.

## Development

```bash
mix deps.get
mix compile
mix test                  # full suite (80% coverage threshold)
mix format
mix credo --strict
mix dialyzer
iex -S mix
```

The included dev container installs a compatible toolchain
automatically.

## License

MIT.
