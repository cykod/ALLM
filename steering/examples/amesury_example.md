# Amesbury → ALLM: replacing hand-built LLM code

A walkthrough of the LLM code in the Amesbury Elixir project (`~/Projects/amesbury`)
and concrete before/after snippets showing how ALLM (per `allm_engine_session_streaming_spec_v0_2.md`)
could replace it.

## What Amesbury built

| Area | File | ~Lines | Notes |
|---|---|---|---|
| OpenAI HTTP client | `apps/amesbury_scraper/lib/amesbury_scraper/transformers/llm_client.ex` | 708 | Single-provider (OpenAI). `complete/3`, `extract/4`, `complete_with_vision/4`, `complete_with_tools/6`. |
| Tool loop | `llm_client.ex` L280–L450 | ~170 | Custom multi-turn loop, "two-phase" workaround for tools + `response_format`, `max_tool_rounds`. |
| Request shaping | `llm_client.ex` L411–L506 | ~95 | Atom→string schema normalization, GPT-5 vs legacy param branching (`max_completion_tokens` / `reasoning_effort`). |
| Retry | `llm_client.ex` (execute_with_retry) | ~40 | Exponential backoff + jitter on 429. |
| Transformers (callers) | `transformers/{committee,ordinance,project,meeting_summary,image_classifier,narrative_generator}.ex` | 162–261 each | Build prompt + schema, call `LLMClient`, map response into domain struct. |
| JSON schemas | `transformers/schemas/{ordinance,committee,project}.ex` | 168+ each | Plain maps; enums duplicated in prompts. |
| Mock | `test/support/mocks/llm_mock.ex` | 175 | Hand-rolled recorder + script-style responses. |
| Streaming | — | 0 | Not implemented. |
| Session state | — | 0 | Each step is stateless. |
| Multi-provider | — | 0 | OpenAI only. |
| Telemetry | — | 0 | No LLM spans; `Logger` only. |

Total hand-maintained LLM surface: **~1,200–1,500 lines**.

## Distinctive things in Amesbury's code

1. **Two-phase structured output with tools** (`llm_client.ex:374-408`). OpenAI can't
   combine `tools` with `response_format: json_schema` in a single request, so after
   the tool loop ends they append `"Now provide your final structured response."` and
   re-request with the schema attached.
2. **GPT-5 vs legacy param branching** (`is_gpt5_model?/1`, `llm_client.ex:421-432`,
   `L468-L499`) — duplicated across `build_tool_request_body` and `build_request_body`.
3. **`Process.put(:documents_read, …)`** in `narrative_generator.ex:77-103` — process
   dictionary used to reach into the closure-bound tool handler from outside.
4. **No thread abstraction** — messages are inline `%{role: "user", content: …}` maps.

---

## Before / after

### 1. Simple structured-output completion

**Before** — `transformers/committee_transformer.ex` style:

```elixir
schema = AmesburyScraper.Transformers.Schemas.Committee.schema()

case LLMClient.complete(prompt, schema, model: "gpt-5-mini", max_tokens: 4096) do
  {:ok, %{response: data, tokens_used: tokens}} ->
    {:ok, to_output(data, tokens)}
  {:error, reason} ->
    {:error, {:llm_error, reason}}
end
```

…backed by ~150 lines in `llm_client.ex` for atom→string schema
normalization, `additionalProperties: false` rewriting, GPT-5 vs legacy parameter
choice, retry, and error extraction.

**After** — ALLM:

```elixir
# Built once at app start
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5-mini",
    params: %{max_tokens: 4096, temperature: 0.0}
  )

request =
  ALLM.request(
    [ALLM.user(prompt)],
    response_format: %{
      type: :json_schema,
      name: "committee",
      strict: true,
      schema: AmesburyScraper.Transformers.Schemas.Committee.schema()
    }
  )

case ALLM.generate(engine, request) do
  {:ok, %ALLM.Response{output_text: json, usage: usage}} ->
    {:ok, to_output(Jason.decode!(json), usage.total_tokens)}
  {:error, reason} ->
    {:error, {:llm_error, reason}}
end
```

- GPT-5 vs legacy param translation moves into `ALLM.Providers.OpenAI.translate_options/2`
  (spec §7.1).
- Schema normalization, retry, and error shaping are adapter-side.
- Usage is typed (`%ALLM.Usage{}`), not a free-form map.

### 2. HTML extraction convenience

`LLMClient.extract/4` is just a system-prompt wrapper around `complete/3`. In ALLM it
collapses into one `request/2`:

```elixir
messages = [
  ALLM.system(extraction_system_prompt()),
  ALLM.user("""
  #{prompt}

  HTML Content:
  ```html
  #{html_content}
  ```
  """)
]

ALLM.generate(engine, ALLM.request(messages, response_format: json_schema(schema)))
```

The dedicated `extract/4` entry point (and its behaviour callback + mock implementation)
goes away.

### 3. Vision (image analysis)

**Before** — `llm_client.ex:251-278`: custom multipart content construction, base64 vs
URL branching, detail level handling.

**After** — ALLM messages already support list-of-parts content (`ALLM.Message` spec
§5.1 allows `content :: String.t() | list(map())`):

```elixir
messages = [
  %ALLM.Message{
    role: :user,
    content: [
      %{type: :text, text: prompt},
      %{type: :image_url, image_url: %{url: image_url, detail: "low"}}
    ]
  }
]

ALLM.generate(engine, ALLM.request(messages, response_format: json_schema(schema)))
```

Provider translation of the image-part shape happens in the OpenAI adapter.

### 4. Tool calling (NarrativeGenerator)

This is where the replacement is most striking. Amesbury's `complete_with_tools/6`
+ `run_tool_loop/8` is ~170 lines and has two awkward workarounds: the two-phase
schema trick and the process-dictionary tool tracking.

**Before** — `narrative_generator.ex:67-122`:

```elixir
tools = [get_full_document_tool()]            # a plain map
schema = narrative_output_schema()
full_text_lookup = build_full_text_lookup(input)

Process.put(:documents_read, [])

tool_handler = fn "get_full_document", %{"document_id" => doc_id} ->
  Process.put(:documents_read, [doc_id | Process.get(:documents_read, [])])

  case Map.get(full_text_lookup, doc_id) do
    nil -> {:ok, "Document not found…"}
    text -> {:ok, text}
  end
end

result =
  LLMClient.complete_with_tools(
    system_prompt, user_prompt, tools, tool_handler, schema,
    max_tool_rounds: 5
  )

docs_read = Process.get(:documents_read, [])
Process.delete(:documents_read)

case result do
  {:ok, %{response: data, tokens_used: tokens, tool_calls_made: calls}} ->
    {:ok, Output.new(…, documents_read_in_full: docs_read)}
  {:error, reason} ->
    {:error, reason}
end
```

**After** — ALLM session with a stateful agent that owns its own "docs read" list:

```elixir
defmodule NarrativeAgent do
  def run(input, engine) do
    lookup = build_full_text_lookup(input)

    tools = [
      ALLM.tool(
        name: "get_full_document",
        description: "Retrieve the full extracted text of a project document.",
        schema: %{
          type: "object",
          properties: %{document_id: %{type: "string"}},
          required: ["document_id"]
        },
        # Handler arity-2: opts carries per-call context including the session id
        handler: fn %{"document_id" => id}, opts ->
          Agent.update(opts[:docs_read_agent], &[id | &1])
          case Map.get(lookup, id) do
            nil  -> {:ok, "Document not found. Available: #{Map.keys(lookup) |> Enum.join(", ")}"}
            text -> {:ok, text}
          end
        end
      )
    ]

    {:ok, docs_agent} = Agent.start_link(fn -> [] end)
    engine = engine |> ALLM.Engine.put_tools(tools) |> ALLM.Engine.put_context(:docs_read_agent, docs_agent)

    messages = [
      ALLM.system(build_system_prompt(input)),
      ALLM.user(build_user_prompt(input))
    ]

    # Two-turn pattern, but explicit: first turn does tool calling, second turn
    # is schema-constrained. No in-library "two-phase" hack — we just call chat
    # twice with the same thread.
    with {:ok, %ALLM.ChatResult{thread: thread, final_response: resp1}} <-
           ALLM.chat(engine, messages, max_turns: 5),
         {:ok, %ALLM.ChatResult{final_response: resp2}} <-
           ALLM.chat(engine,
             ALLM.Thread.add_user(thread, "Now provide your final structured response."),
             response_format: %{type: :json_schema, name: "narrative",
                                strict: true, schema: narrative_output_schema()},
             tools: []   # disable tools for the structured pass
           ) do
      data = Jason.decode!(resp2.output_text)
      docs_read = Agent.get(docs_agent, & &1)
      Agent.stop(docs_agent)

      {:ok,
       Output.new(
         rich_description: data["rich_description"],
         ai_summary: data["summary"],
         ai_preview: data["preview"],
         key_facts: parse_key_facts(data["key_facts"]),
         tokens_used: resp1.usage.total_tokens + resp2.usage.total_tokens,
         tool_calls_made: length(docs_read),
         documents_read_in_full: docs_read
       )}
    end
  end
end
```

Replacements and gains:

- **Tool loop** replaced by `ALLM.chat/3` with `max_turns` (§10.5 / §19).
- **Two-phase trick** becomes two explicit `ALLM.chat/3` calls over the same
  `ALLM.Thread`. The workaround is visible in caller code instead of hidden in a
  library function, and the `Thread` struct is the explicit carrier of history.
- **Process dictionary** replaced by `ALLM.Engine.put_context/3` — `context` is
  plumbed through to tool handlers via `opts` (§6.1, §7.3), so per-call state has
  a durable home that doesn't leak via process state.
- **Tool definitions** are `%ALLM.Tool{}` structs (`ALLM.tool/1`) instead of naked
  maps. Validation via `ALLM.Tool.validate/1` (§15).

### 5. Manual tool orchestration (new capability)

The Amesbury design assumes the caller is the same process that executes tools.
If they ever want to checkpoint after an LLM requests a tool (e.g. a human-approval
step, or a tool that requires an external job), they'd have to re-engineer the loop.

ALLM gives this for free via `mode: :manual` + `ALLM.Session` (§11, §12, §25):

```elixir
{:ok, session, _result} =
  ALLM.Session.reply(engine, session, "Read the staff report.", mode: :manual)

# session.status == :awaiting_tools; serialize the session to DB and come back later.
{:ok, saved} = Repo.insert(%ChatSession{id: session.id, state: :erlang.term_to_binary(session)})

# …later, possibly in a different process / after human approval
session = saved |> Map.get(:state) |> :erlang.binary_to_term()

session = ALLM.Session.submit_tool_result(session, "call_123", %{…})
{:ok, session, step} = ALLM.Session.step(engine, session)
```

For Amesbury today this is latent — they don't have a chat UI — but the same
primitive is what would let the scraper pipeline checkpoint a long-running
tool-calling step to the PipelineRun store instead of holding it in one process.

### 6. Streaming (new capability)

`llm_client.ex` is entirely request/response. Any UI surface (a future dashboard
that watches a transformer run, or a chat interface for asking questions about
meeting minutes) would need streaming added from scratch.

ALLM's `stream/3` (§10.6) returns an `Enumerable` of `ALLM.Event` values that
cover text deltas, tool-call deltas, tool execution, and completion:

```elixir
{:ok, stream} = ALLM.stream(engine, thread)

Enum.each(stream, fn
  {:text_delta, %{delta: d}}              -> Phoenix.PubSub.broadcast(…, {:token, d})
  {:tool_execution_started, %{name: n}}   -> Phoenix.PubSub.broadcast(…, {:status, "Running #{n}"})
  {:chat_completed, %{result: r}}         -> finalize(r)
  _                                       -> :ok
end)
```

No custom SSE parsing (Amesbury would otherwise need to add `Finch` streaming and
the usual HTTP/1 vs HTTP/2 pitfall around request bodies >64KB, per spec §7.2
notes). The non-streaming `ALLM.chat/3` is itself implemented as a reducer over
this stream (spec §3), so there's one code path to maintain.

### 7. Provider portability

Amesbury pins itself to OpenAI by construction: the client module is named for it,
and request shapes are OpenAI-specific. Switching a transformer to Claude would
mean writing a second parallel client.

With ALLM, the same transformer code runs against Anthropic by swapping the
adapter:

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-sonnet-4-6")
```

Pre-flight capability checks (spec §6.3) will refuse a request that uses
`response_format: :json_schema` against a model whose `capabilities.json_native`
is false, before any network call — surfacing as `{:error, {:unsupported_capability, :json_native}}`.

### 8. Testing

Amesbury's `test/support/mocks/llm_mock.ex` (175 lines) is a hand-rolled recorder
with script-style responses. ALLM's `ALLM.Providers.Fake` (§31) covers the same
ground:

```elixir
test "narrative generator reads the staff report" do
  engine =
    ALLM.Engine.new(
      adapter: ALLM.Providers.Fake,
      adapter_opts: [
        scripts: [
          [
            {:tool_call, id: "c1", name: "get_full_document",
                         arguments: %{"document_id" => "doc-staff-report"}},
            {:finish, :tool_calls}
          ],
          [
            {:text, ~s|{"rich_description":"…","summary":"…","preview":"…","key_facts":[]}|},
            {:finish, :stop}
          ]
        ]
      ]
    )

  assert {:ok, output} = NarrativeAgent.run(input, engine)
  assert "doc-staff-report" in output.documents_read_in_full
end
```

- No bespoke `Process`-based recorder.
- `ALLM.Test.collect/1`, `text/1`, `tool_calls/1` cover the common assertions.

---

## Summary of what would be deleted or shrunk

| Amesbury file / section | Lines | Post-ALLM |
|---|---:|---|
| `llm_client.ex` (whole file) | 708 | deleted; a thin `Amesbury.LLM` module exposing a configured `ALLM.Engine` remains (~30 lines) |
| `complete_with_tools` + `run_tool_loop` | ~170 | replaced by `ALLM.chat/3` + explicit two-call pattern in `NarrativeGenerator` |
| GPT-5/legacy request body branching | ~60 | moves into `ALLM.Providers.OpenAI.translate_options/2` (one adapter, reusable) |
| Retry/backoff | ~40 | adapter-level, telemetry-driven |
| Process-dict tracking in `NarrativeGenerator` | ~10 | replaced by `Engine.put_context/3` + `Agent` |
| `llm_mock.ex` | 175 | deleted; `ALLM.Providers.Fake` covers scripted responses |
| Per-transformer error/usage plumbing | ~15 × 6 files | simplified to `{:ok, %ALLM.Response{usage: …}}` pattern |

Net reduction: **~1,100 lines of LLM plumbing** removed, with streaming, sessions,
capability pre-flight, typed usage/costs, and multi-provider support gained.

## What would stay

- Prompt construction (`build_system_prompt/1`, `build_user_prompt/1`) — domain
  logic that should not live in a library.
- JSON schemas (`schemas/ordinance.ex`, etc.) — domain data shape.
- Pipeline infra (`Pipeline.Step`, `Pipeline.Runner`, `PipelineRun`, `StepLog`,
  `ArtifactStore`) — not LLM-specific.
- Transformer input/output structs — domain data.

## Migration order suggestion

1. Introduce `ALLM.Engine` construction in app config; leave `LLMClient` in place.
2. Rewrite `complete/3` callers (Committee, Ordinance, Project, MeetingSummary,
   ImageClassifier) — one PR each. These are straight `ALLM.generate/2` swaps.
3. Rewrite `NarrativeGenerator` (tool calling). This is the riskiest one because
   of the two-phase schema trick; keep both paths behind a config flag during
   cutover and A/B the outputs on a sample of projects.
4. Swap `LLMClient.Mock` for `ALLM.Providers.Fake` in tests. Delete
   `llm_client.ex` and `llm_mock.ex`.
5. Add telemetry handlers on `[:llm, :chat, :stop]` to populate the existing
   pipeline step log with token/cost data from `%ALLM.Usage{}`.
