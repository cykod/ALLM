# Case Study: Replacing `unllmtd`'s hand-built LLM code with ALLM

This doc walks through the LLM-facing code in [`~/Projects/unllmtd`](../../unllmtd) and shows how each piece would be expressed using the ALLM library defined in [`allm_engine_session_streaming_spec_v0_2.md`](../allm_engine_session_streaming_spec_v0_2.md).

Unlike the `meal` example — a single-turn, single-provider, no-tools case — `unllmtd` is a **multi-provider, multi-turn, multi-subagent platform with tools**. It hand-rolls everything ALLM is designed to provide.

## What `unllmtd` uses LLMs for

unllmtd is an AI-native agent platform. The control plane (Elixir umbrella, `services/control-plane/apps/core/`) uses LLMs in two layers:

1. **`Unllmtd.LLM.*`** — low-level HTTP clients and an execution wrapper for user-deployed LLM nodes inside a running agent.
2. **`Unllmtd.AI.*`** — an internal "agent generator" pipeline that spawns multiple LLM-driven subagents to plan, generate, and fix TypeScript/LLM nodes from a natural-language description.

### The low-level layer (`Unllmtd.LLM.*`)

| File | Lines | Purpose |
|---|---|---|
| `llm/anthropic_client.ex` | 289 | Hand-written Messages API client. Builds payloads, formats messages (tool_use / tool_result blocks), adds the `web-search-2025-03-05` beta header, parses `content[]` blocks into `{:ok, %{type: :text \| :tool_calls, …}}`. Pulls the API key out of a credential list. |
| `llm/openai_client.ex` | 259 | Hand-written Chat Completions client. Same shape, different provider. JSON-encodes tool-call arguments, remaps `prompt_tokens`/`completion_tokens` into a local `usage` map. |
| `llm/message_formatter.ex` | 154 | Converts internal `"tool_result"` messages into provider-specific shapes (Anthropic wraps in a user content array, OpenAI remaps to role `"tool"`). Also converts Anthropic tool_use blocks to OpenAI tool_calls format when switching providers mid-thread. |
| `llm/models.ex` | 47 | Hard-coded map of provider → default model string, plus `valid_provider?/1`. |
| `llm/executor.ex` | 167 | Tool-calling loop for user-deployed LLM nodes. Calls the provider, dispatches tool calls to `Unllmtd.Orchestrator.execute_node/3`, re-calls the provider with results, caps at 10 turns. |
| `ai/llm_adapter.ex` | 259 | The façade every higher layer actually calls. Handles provider selection, model tier (`:orchestrator` vs `:execution`), retries with exponential backoff on 429/500/503, debug logging. `stream/3` is a stub (`{:error, "Streaming not yet implemented"}`). |

### The agent-generation layer (`Unllmtd.AI.*`)

The agent generator runs a 9-step pipeline. Four of those steps are **LLM-driven tool-calling loops**, each a separate copy of roughly the same orchestration code:

| File | Lines | Loop? | What it does |
|---|---|---|---|
| `ai/agent_generator.ex` | 1318 | `run_llm_loop/5` at **line 1112** | Top-level planning loop — research + plan the agent DAG. |
| `ai/node_generation_subagent.ex` | 917 | `run_loop/4` at **line 339** | Per-node subagent — writes code, validates, revises. |
| `ai/fix_subagent.ex` | 447 | `run_fix_loop/4` at **line 172** | Fixes a single failing node after validation errors. |
| `ai/connection_fix_subagent.ex` | 717 | `run_loop/4` at **line ~220** | Fixes schema mismatches between connected nodes. |
| `ai/credential_detector.ex` | 168 | single-shot `LLMAdapter.complete` | One-off JSON extraction. |
| `ai/agentic_tools.ex` | 1234 | — | The tool registry + dispatcher the planning loop uses. |
| `ai/agentic_prompt_builder.ex` | 883 | — | Prompt templates + a hand-rolled message compressor (`compress_messages/1`) + a state-context refresher. |
| `ai/generation_state.ex` | 1356 | — | Serializable pipeline state, including a frozen copy of the planning messages. |

Total LLM / AI code: **~10,300 lines**. The orchestration shape is the same every time:

```elixir
def run_loop(system_prompt, messages, state, config) do
  if state.turn >= @max_turns, do: {:error, :max_turns}, else:
    case LLMAdapter.complete(system_prompt, messages, provider: …, tools: …) do
      {:ok, %{type: :tool_calls, tool_calls: tcs}} -> process_tool_calls(tcs, …)
      {:ok, %{type: :text,       content: c}}      -> re_ask_to_use_tools(c, …)
      {:error, reason}                              -> {:error, reason}
    end
end
```

…duplicated across four files with slightly different termination conditions.

## Mapping `unllmtd` concepts to ALLM concepts

| `unllmtd` construct | ALLM replacement | Spec section |
|---|---|---|
| `Unllmtd.LLM.AnthropicClient` (~289 LoC) | `ALLM.Providers.Anthropic` adapter (ships with ALLM) | §32.1 |
| `Unllmtd.LLM.OpenAIClient` (~259 LoC) | `ALLM.Providers.OpenAI` adapter (ships with ALLM) | §32.1 |
| `Unllmtd.LLM.MessageFormatter` (~154 LoC) | **Gone.** Each adapter translates `ALLM.Message` → provider shape internally. | §7.1, §5.1 |
| `Unllmtd.LLM.Models` hard-coded map | `ALLM.Engine.new(model: …)` + optional `llm_db` for capability/pricing | §6.2, §6.3 |
| `LLMAdapter.complete/3` | `ALLM.generate/3` for single round-trip, `ALLM.chat/3` for multi-turn | §10.1, §10.5 |
| `LLMAdapter.stream/3` (stub) | `ALLM.stream/3` (first-class, not a stub) | §10.6, §13 |
| `LLMAdapter.summarize/3` | `ALLM.generate/3` with a system-prompt override; same shape, no special helper needed | §10.1 |
| `LLMAdapter.with_retries/2` (429/500/503 backoff) | Not in v0.2 core — wire in via adapter wrapping or `Req` retry middleware handed back by `prepare_request/2` | §7.1, §29 |
| `model_tier: :orchestrator \| :execution` + `execution_models/0` lookup | Two engines (e.g. `orchestrator_engine`, `execution_engine`), or one engine with `ALLM.Engine.with_model/2` per call | §6.2 |
| API key lookup inside each provider client (`find_credential/2`) | `ALLM.Keys` with explicit precedence; keys never enter `ALLM.Session` | §6.4 |
| `@max_turns 10` / `@max_turns 5` / `@planning_max_turns 15` constants | `max_turns:` option on `ALLM.chat/3` / `ALLM.stream/3` | §19 |
| `run_llm_loop/5` in `agent_generator.ex` | `ALLM.Session.stream_reply/4` + `mode: :auto` | §11, §12 |
| `run_loop/4` in `node_generation_subagent.ex` | Same — a subagent is an `ALLM.Session` with a different engine (different tools, different system prompt) | §11 |
| `run_fix_loop/4` in `fix_subagent.ex` | Same | §11 |
| `run_loop/4` in `connection_fix_subagent.ex` | Same | §11 |
| "LLM replied with text when we expected tools, re-ask" branch in every loop | `halt_when:` callback on `ALLM.chat/3`, or leave as-is inside a manual-mode caller | §19 |
| `AgenticPromptBuilder.compress_messages/1` (tool-result compaction) | Not in v0.2 core (out-of-scope per §33). Stays in unllmtd as a pre-processor over `session.thread.messages`. | §33 |
| `AgenticPromptBuilder.refresh_state_context/2` (strips old STATE_CONTEXT blocks, appends current) | Same — application-specific, stays put. Operates on the serializable `ALLM.Thread`. | §5.6 |
| `Unllmtd.LLM.Executor` (user-LLM-node tool loop) | `ALLM.chat/3` with tools built from the node's `available_tool_node_ids` | §10.5, §15 |
| `build_tools/2` returning custom tool definition maps | `ALLM.Tool.new/1` | §15 |
| `AgenticToolRegistry` (plan_agent / web_fetch / ask_user / generate_node / …) as a map of name → function | `ALLM.Engine.put_tools/2` — each tool is an `ALLM.Tool` with a `handler:` | §5.2, §15 |
| `GenerationState.messages` + `GenerationState.serialize/1` | Store `ALLM.Session` directly (it's already serializable per §5.7); keep `GenerationState` for the *non-LLM* pipeline fields (nodes, edges, validation results, phase) | §5.7, §11 |
| `{:suspended, result, messages}` three-tuple + `resume/3` | `ALLM.Session` with `status: :awaiting_user` — same contract, standard shape | §5.7, §12 |
| `broadcast_llm_response/4` + every `on_progress.(%{event: "llm_request", …})` | `:telemetry` handler on `[:llm, :chat, :*]` and `[:llm, :tool, :*]`; event stream from `ALLM.stream/3` for UI | §29, §8 |
| `%{type: :text \| :tool_calls, content, tool_calls, usage}` response map | `ALLM.Response` (typed struct with normalized `finish_reason` + typed `usage`) | §5.5, §5.9a |
| Hand-rolled web-search headers (Anthropic `anthropic-beta: web-search-2025-03-05`, OpenAI `{type: "web_search"}`) | Provider adapter owns this. Surfaced as a per-request option on the engine (`put_param(engine, :enable_web_search, true)`) or an adapter-level translate. | §7.1 |

What ALLM does **not** replace: `AgenticPromptBuilder` prompt templates, `AgenticTools` business-logic tool handlers, `GenerationState` pipeline fields (nodes/edges/validation), `SchemaCompatibility`, `BoundaryNodeGenerator`, the validation pipeline, and `WebFetchAdapter`. Those stay put. ALLM replaces the *plumbing around* the LLM call.

---

## Side-by-side 1: The low-level `LLMAdapter.complete/3`

### Before — `apps/core/lib/core/ai/llm_adapter.ex:74-117` + `anthropic_client.ex` + `openai_client.ex`

```elixir
# 1. Caller (agent_generator.ex:1148)
llm_result = LLMAdapter.complete(
  system_prompt,
  compressed_messages,
  provider: config.provider,
  credentials: config.credentials,
  tools: config.tools
)

# 2. LLMAdapter.complete/3 dispatches on provider:
def complete(system_prompt, messages, opts \\ []) do
  provider = Keyword.get(opts, :provider, @default_provider)
  model = resolve_model(opts, provider)
  …
  with_retries(fn ->
    case provider do
      :anthropic -> AnthropicClient.create_message(model, system_prompt, messages, tools, credentials, …)
      :openai    -> OpenAIClient.create_completion(model, system_prompt, messages, tools, credentials, …)
    end
  end)
end

# 3. AnthropicClient.create_message/6 — 289 lines of:
#    - find_credential/2 to locate the Anthropic key inside `credentials`
#    - build_payload/5   (tool formatting, system-prompt placement)
#    - build_headers/2   (x-api-key, anthropic-version, optional beta)
#    - HTTPClient.post/4
#    - parse_response/1  → parse_content/2 walks `content[]` blocks,
#                          filters tool_use / text / web_search_tool_result
#    - returns {:ok, %{type: :text | :tool_calls, …}}
#
# 4. OpenAIClient.create_completion/6 — 259 lines of:
#    - find_credential/2 (OpenAI variant — auth_type "openai_api_key" or name match)
#    - build_payload/5 (max_completion_tokens, messages with JSON-encoded tool args)
#    - parse_choice/2 (JSON-decodes tool-call arguments back into a map)
#    - returns the same {:ok, %{type: :text | :tool_calls, …}} shape
#
# 5. MessageFormatter (separate 154-LoC module) handles `"tool_result"` → provider
#    format, plus a second pass for converting Anthropic tool_use blocks to
#    OpenAI tool_calls when switching providers mid-thread.
```

Total: **~960 LoC** of hand-maintained provider plumbing, plus the `ai/llm_adapter.ex` façade on top.

### After — with ALLM

```elixir
# One-time engine setup, e.g. in an application supervisor or a context module
defmodule Unllmtd.AI.Engines do
  def orchestrator(provider, credentials) do
    adapter = case provider do
      :openai    -> ALLM.Providers.OpenAI
      :anthropic -> ALLM.Providers.Anthropic
    end

    model = case provider do
      :openai    -> "gpt-5.2-2025-12-11"
      :anthropic -> "claude-sonnet-4-5-20250929"
    end

    ALLM.Engine.new(
      adapter: adapter,
      model: model,
      adapter_opts: [api_key: find_key(credentials, provider)],
      params: %{temperature: 0.2, max_turns: 15}
    )
  end

  def execution(provider, credentials) do
    orchestrator(provider, credentials)
    |> ALLM.Engine.with_model(execution_model_for(provider))
  end
end
```

```elixir
# Caller — single-turn, no tools (replaces LLMAdapter.complete/3 for that case)
request = ALLM.request(messages, metadata: %{caller: :credential_detector})
{:ok, response} = ALLM.generate(engine, request)

response.output_text        # => "…"        (was: result.content)
response.tool_calls         # => [...]      (was: result.tool_calls, typed now)
response.usage.input_tokens # => 1234       (was: result.usage.input_tokens)
response.finish_reason      # => :stop | :tool_calls | :length  (new: normalized enum)
```

Gone with the old code:
- `find_credential/2` in both clients → `ALLM.Keys.fetch!/2` (§6.4)
- `build_payload/build_headers/format_messages/format_tools` → inside `ALLM.Providers.*` (§7.1)
- `parse_response/parse_content/parse_choice` → adapter returns `ALLM.Response` directly (§5.5)
- `MessageFormatter` cross-provider conversion → each adapter owns its own shape; callers pass `ALLM.Message` and it Just Works (§5.1)
- `with_retries/2` manual 429/500/503 backoff → wire via `prepare_request/2` handing back a `Req.Request` the app can add retry middleware to (§7.1)
- The `%{type: :text | :tool_calls, …}` duck-typed map → `ALLM.Response` with `finish_reason :: :stop | :tool_calls | :length | …` (§5.5)
- Streaming stub → real `ALLM.stream_generate/3` (§10.2)

---

## Side-by-side 2: The `run_llm_loop/5` orchestration in `agent_generator.ex`

This is the heart of unllmtd's planning loop. It's ~150 lines (agent_generator.ex:1112-1263), and it's duplicated in three more subagents.

### Before — `agent_generator.ex:1112-1196`

```elixir
defp run_llm_loop(system_prompt, messages, state, config, opts) do
  terminate_when = Keyword.get(opts, :terminate_when, fn _ -> false end)
  max_turns = Keyword.get(opts, :max_turns, @max_turns)

  if state.turn >= max_turns do
    Logger.warning("Max turns (#{max_turns}) exceeded in LLM loop")
    config.on_progress.(%{event: "max_turns_exceeded", turns: state.turn})
    {:error, "Maximum turns (#{max_turns}) exceeded"}
  else
    state = GenerationState.increment_turn(state)
    # …broadcast event…
    compressed_messages = AgenticPromptBuilder.compress_messages(messages)
    compressed_messages = AgenticPromptBuilder.refresh_state_context(compressed_messages, state)

    llm_result = LLMAdapter.complete(system_prompt, compressed_messages,
      provider: config.provider, credentials: config.credentials, tools: config.tools)

    broadcast_llm_response(llm_result, state.turn, llm_duration, config.on_progress)

    case llm_result do
      {:ok, %{type: :tool_calls, tool_calls: tool_calls}} ->
        process_loop_tool_calls(tool_calls, system_prompt, messages, state, config, …)

      {:ok, %{type: :text, content: content}} ->
        # LLM ignored the tools — append the text, re-ask with a nudge
        new_messages = messages ++ [
          %{role: "assistant", content: content},
          %{role: "user", content: "Please use the available tools to continue…"}
        ]
        run_llm_loop(system_prompt, new_messages, state, updated_config, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defp process_loop_tool_calls(tool_calls, system_prompt, messages, state, config, opts) do
  assistant_message = %{role: "assistant", content: nil,
                        tool_calls: Enum.map(tool_calls, fn tc -> %{id: tc.id, name: tc.name, arguments: tc.arguments} end)}

  {tool_messages, final_state, suspended?} =
    Enum.reduce_while(tool_calls, {[], state, false}, fn tool_call, {msgs, current_state, _} ->
      {result, updated_state} = AgenticTools.execute(tool_call.name, tool_call.arguments, current_state, …)

      if updated_state.phase == :awaiting_user do
        {:halt, {msgs, updated_state, true}}      # manual-mode suspension
      else
        tool_message = AgenticPromptBuilder.build_tool_result_message(…)
        {:cont, {msgs ++ [tool_message], …, false}}
      end
    end)

  cond do
    suspended? -> {:suspended, GenerationState.to_result(final_state), messages}
    terminate_when.(final_state) -> {:ok, final_state}
    final_state.phase == :failed -> {:ok, final_state}
    true -> run_llm_loop(system_prompt, new_messages, final_state, updated_config, …)
  end
end
```

### After — with ALLM

```elixir
# Tools become ALLM.Tool values with handlers. Each handler is a pure function
# that receives the arguments and returns {:ok, term} | {:error, term}.
plan_agent_tool = ALLM.tool(
  name: "plan_agent",
  description: "Submit a complete agent plan…",
  schema: AgenticTools.planning_schemas()[:plan_agent],
  handler: fn args, opts ->
    state = Keyword.fetch!(opts, :state)
    AgenticTools.Planning.plan_agent(args, state)
  end
)

web_fetch_tool = ALLM.tool(
  name: "web_fetch",
  description: "Fetch a URL and return its text content.",
  schema: %{type: "object",
            properties: %{url: %{type: "string"}},
            required: ["url"]},
  handler: fn %{"url" => url}, _opts -> Unllmtd.AI.WebFetchAdapter.fetch(url) end
)

ask_user_tool = ALLM.tool(
  name: "ask_user",
  description: "Pause generation and ask the user a clarifying question.",
  schema: %{type: "object",
            properties: %{question: %{type: "string"}},
            required: ["question"]},
  handler: fn %{"question" => q}, _ -> {:halt, {:awaiting_user, q}} end
  # handler returning :halt triggers manual-mode suspension — see below
)

engine =
  Engines.orchestrator(provider, credentials)
  |> ALLM.Engine.put_tools([plan_agent_tool, web_fetch_tool, ask_user_tool, …])
  |> ALLM.Engine.put_context(:generation_state, state)   # handed to tool handlers
```

The loop itself collapses into one call:

```elixir
# Automatic orchestration — ALLM loops internally, executes tools, halts on
# `halt_when` (e.g., when a plan has been submitted).
{:ok, stream} =
  ALLM.stream(engine, thread,
    mode: :auto,
    max_turns: 15,
    halt_when: fn %ALLM.StepResult{thread: t} ->
      GenerationState.plan_submitted?(unllmtd_state_from(t))
    end
  )

# Drive the stream, fanning events out to on_progress / telemetry.
collector = ALLM.StreamCollector.new(thread)

collector =
  Enum.reduce(stream, collector, fn event, acc ->
    case event do
      {:text_delta, %{delta: d}}             -> on_progress.(%{event: "llm_text_delta", delta: d})
      {:tool_call_started, %{name: name}}    -> on_progress.(%{event: "tool_started", name: name})
      {:tool_execution_completed, payload}   -> on_progress.(%{event: "tool_done", name: payload.name})
      {:step_completed, %{response: r}}      -> on_progress.(%{event: "llm_response", usage: r.usage})
      _                                      -> :ok
    end
    ALLM.StreamCollector.apply_event(acc, event)
  end)

chat_result = ALLM.StreamCollector.to_chat_result(collector)
```

The "LLM replied with text when we expected tools" nudge is gone. Either:
- keep the existing nudge by post-processing when `chat_result.halted_reason == :max_turns` *and* `chat_result.final_response.finish_reason == :stop` — but in practice ALLM's `halt_when` + proper prompt engineering handles this case; or
- pass `tool_choice: "plan_agent"` (or `:required`) on the first turn to force a tool call. This is a feature of both OpenAI and Anthropic that the hand-rolled loop wasn't exploiting.

The `{:suspended, result, messages}` return is replaced by ALLM's first-class suspension model:

```elixir
# If ask_user's handler returns {:halt, {:awaiting_user, q}}, ALLM transitions
# the session to status: :awaiting_tools (or :awaiting_user with a custom status
# extension) and stops the loop. Serialize the session, persist it.
case ALLM.Session.start(engine, initial_messages, id: generation_id) do
  {:ok, %ALLM.Session{status: :awaiting_user} = session, partial_result} ->
    Unllmtd.AI.GenerationStateStore.save!(session)
    {:suspended, partial_result, session.thread.messages}

  {:ok, %ALLM.Session{status: :completed} = session, result} ->
    Unllmtd.AI.GenerationStateStore.save!(session)
    {:ok, result}
end

# Resume:
session = Unllmtd.AI.GenerationStateStore.load!(generation_id)
{:ok, updated_session, result} = ALLM.Session.reply(engine, session, user_answer)
```

Savings: **one loop, one copy** — replaces `run_llm_loop/5` in `agent_generator.ex`, `run_loop/4` in `node_generation_subagent.ex`, `run_fix_loop/4` in `fix_subagent.ex`, and `run_loop/4` in `connection_fix_subagent.ex`. Each subagent is now just "build an engine with the right tools, call `ALLM.chat/3`".

---

## Side-by-side 3: The user-LLM-node `Unllmtd.LLM.Executor`

This is the runtime path for an LLM node *inside a user's running agent* (distinct from the agent-generator). It's 167 lines and implements yet another multi-turn tool loop.

### Before — `apps/core/lib/core/llm/executor.ex:55-113`

```elixir
defp execute_with_tools(provider, model, system, messages, tools, credentials, turn) do
  result = case provider do
    "anthropic" -> AnthropicClient.create_message(model, system, messages, tools, credentials)
    "openai"    -> OpenAIClient.create_completion(model, system, messages, tools, credentials)
  end

  case result do
    {:ok, %{type: :text, content: text, usage: usage}} ->
      {:ok, %{"text" => text, "messages" => messages ++ [%{role: "assistant", content: text}], "usage" => usage}}

    {:ok, %{type: :tool_calls, tool_calls: tool_calls, usage: _}} ->
      tool_results = Enum.map(tool_calls, fn tc -> execute_tool_call(tc, tools) end)
      assistant_message = %{role: "assistant", content: "", tool_calls: tool_calls}
      tool_result_messages = build_tool_result_messages(tool_calls, tool_results)
      execute_with_tools(provider, model, system, messages ++ [assistant_message] ++ tool_result_messages,
                          tools, credentials, turn + 1)

    {:error, reason} -> {:error, reason}
  end
end

defp execute_tool_call(%{name: name, arguments: arguments}, tools) do
  case Enum.find(tools, fn t -> t.name == name end) do
    nil  -> %{"error" => "Tool not found: #{name}"}
    tool ->
      node = Unllmtd.Repo.get!(Agents.Node, tool.node_id)
      case Orchestrator.execute_node(node, arguments, []) do
        {:ok, output}    -> output
        {:error, reason} -> %{"error" => "Tool execution failed: #{inspect(reason)}"}
      end
  end
end
```

### After — with ALLM

```elixir
def execute(%Agents.Node{node_type: t} = node, input, credentials, opts) when t in ["llm_structured", "llm_streaming"] do
  provider = String.to_atom(node.config["provider"] || "openai")
  engine =
    Engines.orchestrator(provider, credentials)
    |> ALLM.Engine.with_model(node.config["model"] || default_model(provider))
    |> ALLM.Engine.put_tools(tools_from_node_ids(node.available_tool_node_ids, opts))

  thread = ALLM.Thread.new()
           |> ALLM.Thread.add_system(node.system_prompt)
           |> ALLM.Thread.add_user(render_template(node.user_prompt_template || "{{input}}", input))

  case ALLM.chat(engine, thread, max_turns: 10) do
    {:ok, %ALLM.ChatResult{final_response: r, thread: final_thread}} ->
      {:ok, %{"text" => r.output_text,
              "messages" => final_thread.messages,
              "usage" => Map.from_struct(r.usage)}}

    {:error, reason} -> {:error, reason}
  end
end

defp tools_from_node_ids(node_ids, opts) do
  Enum.map(node_ids, fn node_id ->
    node = Unllmtd.Repo.get!(Agents.Node, node_id)
    ALLM.tool(
      name: "tool_#{node_id}",
      description: node.description || "Execute node #{node_id}",
      schema: SchemaCompatibility.input_type_to_json_schema(node.input_type),
      handler: fn args, _ ->
        case Unllmtd.Orchestrator.execute_node(node, args, Keyword.get(opts, :parent_inputs, [])) do
          {:ok, output} -> {:ok, output}
          {:error, reason} -> {:error, "Tool execution failed: #{inspect(reason)}"}
        end
      end
    )
  end)
end
```

The recursion, the turn counter, the assistant-message construction, the tool-result-message construction, the provider dispatch — all gone. `ALLM.chat/3` owns the loop. What unllmtd keeps is the two domain-specific bits: rendering the user prompt template, and wrapping `Orchestrator.execute_node/3` as an `ALLM.Tool` handler.

Added for free by ALLM: streaming (`ALLM.stream/3` for `llm_streaming` node types, currently unimplemented), typed `usage` (cost fields populated if `llm_db` is present — §6.3), normalized `finish_reason`, telemetry spans (`[:llm, :chat, :stop]` for latency/cost dashboards), and `halt_when` (e.g., stop if total tokens exceed a budget).

---

## Side-by-side 4: Streaming

### Before — `ai/llm_adapter.ex:248-258`

```elixir
defp stream_anthropic(_model, _system, _messages, _credentials) do
  # TODO: Implement streaming for Anthropic
  # This would use Server-Sent Events from the Anthropic API
  {:error, "Streaming not yet implemented for Anthropic"}
end

defp stream_openai(_model, _system, _messages, _credentials) do
  # TODO: Implement streaming for OpenAI
  # This would use Server-Sent Events from the OpenAI API
  {:error, "Streaming not yet implemented for OpenAI"}
end
```

### After — with ALLM

```elixir
{:ok, stream} = ALLM.stream(engine, thread, mode: :auto, max_turns: 10)

Enum.each(stream, fn
  {:text_delta, %{delta: d}}                   -> Phoenix.PubSub.broadcast(PubSub, "gen:#{id}", {:delta, d})
  {:tool_call_started, %{name: name}}          -> on_progress.(%{event: "tool_started", name: name})
  {:tool_call_delta, %{arguments_delta: d}}    -> on_progress.(%{event: "tool_args_delta", delta: d})
  {:tool_execution_started, %{name: name}}     -> on_progress.(%{event: "tool_running", name: name})
  {:tool_execution_completed, %{result: r}}    -> on_progress.(%{event: "tool_done", result: r})
  {:step_completed, %{response: r}}            -> on_progress.(%{event: "step_done", usage: r.usage})
  {:chat_completed, %{result: r}}              -> on_progress.(%{event: "generation_complete", result: r})
  _                                            -> :ok
end)
```

This replaces both the stubbed `stream/3` *and* the existing `broadcast_llm_response/4` progress-broadcast code in `agent_generator.ex`. Streamed tool-call argument deltas (which the current code can't observe) are a significant UX win for the agent-generation UI.

---

## What's left behind

Even with ALLM in place, unllmtd still owns domain-specific code. These modules should not be touched by the migration:

- **`agentic_prompt_builder.ex`** — prompt templates, `compress_messages/1`, `refresh_state_context/2`. These operate on `ALLM.Thread.messages` (plain lists of `ALLM.Message`), so the module's inputs change but its logic doesn't.
- **`agentic_tools.ex` / `agentic_tool_registry.ex`** — tool *handlers* and *business logic*. Each becomes the `handler:` function of an `ALLM.Tool`. The registry shrinks to "return a list of `ALLM.Tool` values for a given pipeline phase".
- **`generation_state.ex`** — pipeline state (nodes, edges, validation results, phase). Today it also duplicates the message list; after ALLM, `session.thread.messages` is the source of truth and `GenerationState` keeps only the non-LLM pipeline fields.
- **`generation_state_store.ex`** — swap the "serialize the messages we've collected" logic for "serialize the `ALLM.Session`". Same shape (it's already JSON), fewer fields to maintain.
- **`schema_compatibility.ex`, `boundary_node_generator.ex`, `credential_detector.ex` parsers, `web_fetch_adapter.ex`** — unchanged. These are unllmtd's actual business logic.

## Rough savings

Lines of code that can be **deleted or collapsed**:

| Module | Current LoC | After ALLM |
|---|---|---|
| `llm/anthropic_client.ex` | 289 | 0 (use `ALLM.Providers.Anthropic`) |
| `llm/openai_client.ex` | 259 | 0 (use `ALLM.Providers.OpenAI`) |
| `llm/message_formatter.ex` | 154 | 0 (adapter-owned) |
| `llm/models.ex` | 47 | ~10 (keep the `@default_models` map; drop the rest) |
| `llm/executor.ex` | 167 | ~40 (keeps template rendering + tool-node wrapping) |
| `ai/llm_adapter.ex` | 259 | ~50 (just engine-construction helpers) |
| `run_llm_loop/5` in `agent_generator.ex` | ~150 | 0 (ALLM.chat/stream) |
| `run_loop/4` in `node_generation_subagent.ex` | ~80 | 0 |
| `run_fix_loop/4` in `fix_subagent.ex` | ~80 | 0 |
| `run_loop/4` in `connection_fix_subagent.ex` | ~80 | 0 |
| **Total LLM plumbing** | **~1,565** | **~100** |

**Net: ~1,450 LoC of plumbing deleted**, replaced by four patterns: `ALLM.Engine.new/1`, `ALLM.chat/3`, `ALLM.stream/3`, and `ALLM.Session.reply/4`. Retry/backoff moves to a Req middleware layer. Streaming works for the first time. Telemetry replaces the hand-rolled `on_progress` broadcast code for anything the UI doesn't directly consume.

## What ALLM would need that isn't in v0.2

Two things unllmtd does that don't map cleanly to the current spec:

1. **Per-call retry with exponential backoff on 429/500/503** (`LLMAdapter.with_retries/2`). The spec punts retries to `Req` middleware via `prepare_request/2` (§7.1). unllmtd would need to either wire a `Req.Request.append_retry/2` into its adapter construction, or wrap `ALLM.Providers.OpenAI`/`Anthropic` in a thin adapter that adds retry. Not hard, but it *is* a move from "central" (one `with_retries/2`) to "peripheral" (per-engine).

2. **Tool-call suspension as a first-class status** (`phase: :awaiting_user` in `GenerationState`). v0.2 has `:awaiting_tools` for manual mode (§12) but not a direct `:awaiting_user` status. unllmtd can get the same effect by having the `ask_user` tool handler return `{:error, {:pause, question}}` and handling that in the caller, or by using `mode: :manual` and treating a question as a pending tool. This works, but the spec could plausibly grow an explicit "the assistant requested user input" signal to model this cleanly.

Neither blocks migration.
