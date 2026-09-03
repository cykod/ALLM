# ALLM (Agent LLM) Engine / Session / Streaming Spec (v0.2 Draft)

## Status

Draft specification for an Elixir library that provides:

- provider-neutral LLM execution
- runtime dependency injection through an `ALLM.Engine`
- serializable conversation state through `ALLM.Session` and `ALLM.Thread`
- first-class streaming via normalized `ALLM.Event` values
- tool calling as part of the core execution model

---

## 1. Design goals

The package should optimize for:

1. **Explicit data flow**
   - Requests, messages, tool calls, responses, sessions, and events are plain data.
2. **Runtime capability separation**
   - Non-serializable runtime concerns live in `ALLM.Engine`.
3. **Serializable session state**
   - Ongoing conversation state can be saved and restored safely.
4. **First-class streaming**
   - Streaming is a primary execution model, not an afterthought.
5. **Composable layers**
   - Low-level execution primitives compose into higher-level chat and session helpers.
6. **Provider neutrality**
   - Core modules do not leak OpenAI-, Anthropic-, or provider-specific request/response shapes.
7. **Tooling support**
   - Tools are treated as core execution primitives, including streamed tool-call deltas.
8. **Testability**
   - Adapters and tool execution are injectable and swappable.

---

## 2. Core architecture

The package is split into four conceptual layers.

### Layer A: Serializable data

These structs are plain data and should be safe to persist:

- `ALLM.Message`
- `ALLM.ToolCall`
- `ALLM.Request`
- `ALLM.Response`
- `ALLM.Thread`
- `ALLM.Session`
- `ALLM.StepResult`
- `ALLM.ChatResult`

### Layer B: Runtime execution environment

These represent execution capabilities and may contain non-serializable references:

- `ALLM.Engine`
- `ALLM.Adapter` behaviour
- `ALLM.StreamAdapter` behaviour
- `ALLM.ToolExecutor` behaviour
- `ALLM.ToolResultEncoder` behaviour

### Layer C: Stateless execution API

These run work against a supplied engine:

- `ALLM.generate/3`
- `ALLM.stream_generate/3`
- `ALLM.step/3`
- `ALLM.stream_step/3`
- `ALLM.chat/3`
- `ALLM.stream/3`

### Layer D: Stateful continuation API

These operate over persisted `ALLM.Session` values:

- `ALLM.Session.start/3`
- `ALLM.Session.stream_start/3`
- `ALLM.Session.reply/4`
- `ALLM.Session.stream_reply/4`
- `ALLM.Session.step/3`
- `ALLM.Session.stream_step/3`

---

## 3. Foundational principle: stream-first execution

Streaming is the primitive execution model.

The package should model an LLM run as a stream of normalized `ALLM.Event` values.

This means:

- `stream_*` functions return event streams
- non-streaming functions are implemented by reducing those streams into final results
- tool execution and multi-turn orchestration are represented in the same event model

### Consequences

1. `ALLM.stream/3` is more primitive than `ALLM.chat/3`.
2. `ALLM.stream_step/3` is more primitive than `ALLM.step/3`.
3. `ALLM.stream_generate/3` is more primitive than `ALLM.generate/3`.
4. Session reducers can consume streamed events to produce final updated sessions.

---

## 4. Core public facade

```elixir
defmodule ALLM do
  @spec system(String.t()) :: ALLM.Message.t()
  def system(text)

  @spec user(String.t()) :: ALLM.Message.t()
  def user(text)

  @spec assistant(String.t()) :: ALLM.Message.t()
  def assistant(text)

  @spec tool_result(String.t(), String.t() | map()) :: ALLM.Message.t()
  def tool_result(tool_call_id, content)

  @spec tool(keyword()) :: ALLM.Tool.t()
  def tool(opts)

  @spec json_schema(name :: String.t(), schema :: map(), keyword()) :: map()
  def json_schema(name, schema, opts \\ [])

  @spec request([ALLM.Message.t()], keyword()) :: ALLM.Request.t()
  def request(messages, opts \\ [])

  @spec generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, term()}
  def generate(engine, request, opts \\ [])

  @spec stream_generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_generate(engine, request, opts \\ [])

  @spec step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, ALLM.StepResult.t()} | {:error, term()}
  def step(engine, thread_or_messages, opts \\ [])

  @spec stream_step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_step(engine, thread_or_messages, opts \\ [])

  @spec chat(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, ALLM.ChatResult.t()} | {:error, term()}
  def chat(engine, thread_or_messages, opts \\ [])

  @spec stream(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(engine, thread_or_messages, opts \\ [])
end
```

---

## 5. Data structures

### 5.1 `ALLM.Message`

```elixir
defmodule ALLM.Message do
  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | list(map()),
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :role,
    :content,
    :name,
    :tool_call_id,
    metadata: %{}
  ]
end
```

### 5.2 `ALLM.Tool`

```elixir
defmodule ALLM.Tool do
  @type schema :: map()

  @type handler_result ::
          {:ok, term()}
          | {:error, term()}
          | {:ask_user, question :: String.t()}
          | {:ask_user, question :: String.t(), keyword()}
          | {:halt, reason :: atom(), result :: term()}

  @type handler ::
          (map() -> handler_result())
          | (map(), keyword() -> handler_result())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: schema(),
          handler: handler() | nil,
          manual: boolean(),
          metadata: map()
        }

  defstruct [
    :name,
    :description,
    :schema,
    :handler,
    manual: false,
    metadata: %{}
  ]
end
```

> **Phase 18 amendment (commits `2a7fa7c..f56cfa6`).** The `:manual` field
> declares this tool is per-tool manual: when set to `true`, the chat
> orchestrator partitions a turn's tool calls into auto + manual buckets and
> halts the loop with `halted_reason: :manual_tool_calls` whenever any manual
> tool is called. Auto tools execute eagerly; manual ones surface in
> `metadata.manual_tool_calls` (or `pending_tool_calls` on a `%Session{}`)
> for caller resolution. Default `false` preserves existing behavior. The
> partition lives in `ALLM.Chat` (`lib/allm/chat.ex:1044` non-streaming
> `do_step/4` and `lib/allm/chat.ex:1337` streaming `transition_a_to_b/1`),
> NOT in `ALLM.ToolRunner`. Under `mode: :manual` (whole-loop) the per-tool
> flag is silent — the existing whole-loop short-circuit fires before the
> partition runs. See §12.4.

#### Handler return values

- `{:ok, result}` — normal completion; `result` is encoded as the tool-result message and the orchestrator continues.
- `{:error, reason}` — tool failure; handled by the engine's `on_tool_error` policy (§19).
- `{:ask_user, question}` / `{:ask_user, question, opts}` — suspend the loop and request user input. Valid in both `:auto` and `:manual` mode. See §12.3.
- `{:halt, reason, result}` — stop the loop cleanly with `ChatResult.halted_reason: reason`. The `result` is still encoded as the tool-result message so downstream consumers see why the loop ended. Callers pick `reason` (e.g. `:plan_submitted`, `:budget_exceeded`). Reserved atoms: `:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`, `:completed` — do not reuse. See §30 for the full orchestrator behaviour.

#### Handler `opts` (arity-2 form)

When the handler has arity 2, the second argument is a keyword list injected by the runtime:

- `:context` — the engine's context map (see `ALLM.Engine.put_context/3`, §6.2)
- `:session_id` — session id if the call is session-bound, else `nil`
- `:request_id` — correlates with telemetry / response `request_id`
- `:tool_call` — the full `%ALLM.ToolCall{}` being executed (id, name, arguments)
- `:engine` — the engine value (read-only; rarely needed)

### 5.3 `ALLM.ToolCall`

```elixir
defmodule ALLM.ToolCall do
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          raw_arguments: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :name,
    :arguments,
    :raw_arguments,
    metadata: %{}
  ]
end
```

### 5.4 `ALLM.Request`

```elixir
defmodule ALLM.Request do
  @type response_format ::
          nil
          | :text
          | %{type: :json_object}
          | %{type: :json_schema, name: String.t(), schema: map(), strict: boolean()}

  @type t :: %__MODULE__{
          model: String.t() | nil,
          messages: [ALLM.Message.t()],
          tools: [ALLM.Tool.t()],
          tool_choice: :auto | :none | :required | String.t() | map() | nil,
          temperature: number() | nil,
          max_tokens: non_neg_integer() | nil,
          stream: boolean(),
          response_format: response_format(),
          structured_finalize: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :messages,
    tools: [],
    tool_choice: nil,
    temperature: nil,
    max_tokens: nil,
    stream: false,
    response_format: nil,
    structured_finalize: false,
    options: %{},
    metadata: %{}
  ]
end
```

#### `response_format` canonical shape

ALLM normalizes structured-output requests into one of the tagged maps above. Adapters translate to each provider's native wire format:

- OpenAI Chat Completions: `%{type: "json_schema", json_schema: %{name:, schema:, strict:}}`
- OpenAI Responses API: `text: %{format: %{type: "json_schema", name:, schema:, strict:}}`
- Anthropic: prepends a tool-forcing pattern (no native schema enforcement)

Prefer the `ALLM.json_schema/3` helper:

```elixir
ALLM.json_schema("committee", Schemas.Committee.schema(), strict: true)
# => %{type: :json_schema, name: "committee", schema: %{...}, strict: true}
```

Passing a raw provider-shaped map is tolerated for escape-hatch use, but adapters may reject shapes they cannot translate with `{:error, {:unsupported_response_format, inspect}}`.

#### `structured_finalize`

Some providers (notably OpenAI at the time of writing) forbid combining `tools` with `response_format: json_schema` in one call. Setting `structured_finalize: true` makes `ALLM.chat/3` / `ALLM.stream/3`:

1. Run the tool loop with tools enabled and `response_format: nil`.
2. After the model finishes tool-calling (finish reason is `:stop`, `:length`, or `halt_when` fires without `:ask_user`), issue one final adapter call over the same thread with `tools: []` and the original `response_format` attached. The final user-nudge message (e.g. `"Now provide your final structured response."`) is appended automatically; override via `structured_finalize_nudge:` on the chat opts.
3. Return a single `ALLM.ChatResult` whose `final_response` is the structured one; the tool-calling steps are preserved in `steps`.

Adapters declare whether they need the two-pass dance via a `requires_structured_finalize?/1` adapter callback. Capability pre-flight (§6.3) automatically sets `structured_finalize: true` when the combination is used against an adapter that needs it — callers rarely set it by hand.

### 5.5 `ALLM.Response`

```elixir
defmodule ALLM.Response do
  @type finish_reason ::
          :stop
          | :length
          | :tool_calls
          | :content_filter
          | :error
          | :other

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          message: ALLM.Message.t() | nil,
          output_text: String.t() | nil,
          tool_calls: [ALLM.ToolCall.t()],
          finish_reason: finish_reason() | nil,
          raw_finish_reason: String.t() | nil,
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :message,
    :output_text,
    :finish_reason,
    :raw_finish_reason,
    :raw,
    tool_calls: [],
    usage: %ALLM.Usage{},
    metadata: %{}
  ]
end
```

`finish_reason` is a closed enum — providers map their own strings onto these. The raw provider token, when preserved, goes in `raw_finish_reason`. `request_id` correlates all telemetry events, streamed events, and the final response for one logical call.

### 5.6 `ALLM.Thread`

```elixir
defmodule ALLM.Thread do
  @type t :: %__MODULE__{
          messages: [ALLM.Message.t()],
          metadata: map()
        }

  defstruct messages: [], metadata: %{}
end
```

### 5.7 `ALLM.Session`

```elixir
defmodule ALLM.Session do
  @type status :: :idle | :awaiting_user | :awaiting_tools | :completed | :error

  @type t :: %__MODULE__{
          id: String.t() | nil,
          thread: ALLM.Thread.t(),
          status: status(),
          pending_tool_calls: [ALLM.ToolCall.t()],
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          context: map(),
          metadata: map()
        }

  defstruct [
    :id,
    :thread,
    :pending_question,
    :pending_tool_call_id,
    status: :idle,
    pending_tool_calls: [],
    context: %{},
    metadata: %{}
  ]
end
```

`status` values and what produces them:

- `:idle` — freshly constructed, never run
- `:awaiting_tools` — last step produced tool calls and the session is in `mode: :manual` (caller must `submit_tool_result/3` — see §11)
- `:awaiting_user` — a tool handler returned `{:ask_user, question, _}` during `:auto` or `:manual` orchestration (§12.3). `pending_question` and `pending_tool_call_id` are populated. Resume via `ALLM.Session.reply/4`.
- `:completed` — last step ended with a non-tool finish reason (`:stop`, `:length`, etc.) or `halt_when` fired
- `:error` — unrecoverable adapter/tool error; see `metadata.error`

### 5.8 `ALLM.StepResult`

```elixir
defmodule ALLM.StepResult do
  @type t :: %__MODULE__{
          thread: ALLM.Thread.t(),
          response: ALLM.Response.t(),
          tool_results: [ALLM.Message.t()],
          done?: boolean(),
          metadata: map()
        }

  defstruct [
    :thread,
    :response,
    tool_results: [],
    done?: false,
    metadata: %{}
  ]
end
```

### 5.9a `ALLM.Usage`

```elixir
defmodule ALLM.Usage do
  @type cost :: float()

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          input_cost: cost() | nil,
          output_cost: cost() | nil,
          total_cost: cost() | nil,
          tool_usage: map(),
          extra: map()
        }

  defstruct [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :reasoning_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    tool_usage: %{},
    extra: %{}
  ]
end
```

Token counts come from the provider response. Cost fields are only populated when the engine can resolve per-million pricing for the model — see §6.3. `tool_usage` carries provider-specific tool costs (e.g. `%{web_search: %{count: 2, unit: "call"}}`). `extra` is the escape hatch for provider-specific counters.

### 5.9 `ALLM.ChatResult`

```elixir
defmodule ALLM.ChatResult do
  @type halted_reason ::
          :completed
          | :max_turns
          | :halt_when
          | :ask_user
          | :tool_error
          | :cancelled
          | atom()               # user-defined halt reasons from {:halt, reason, _}

  @type t :: %__MODULE__{
          thread: ALLM.Thread.t(),
          final_response: ALLM.Response.t(),
          steps: [ALLM.StepResult.t()],
          halted_reason: halted_reason(),
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :thread,
    :final_response,
    :halted_reason,
    :pending_question,
    :pending_tool_call_id,
    steps: [],
    metadata: %{}
  ]
end
```

When `halted_reason` is `:ask_user`, `pending_question` carries the question the tool asked and `pending_tool_call_id` carries the tool-call id that requested it — so a caller using `ALLM.chat/3` (no session) can present the question and re-enter the loop by appending `ALLM.user(answer)` and calling `ALLM.chat/3` again. Session-based callers don't need these fields — they're also persisted on `ALLM.Session` (§5.7).

---

## 6. Runtime execution environment

### 6.1 `ALLM.Engine`

```elixir
defmodule ALLM.Engine do
  @type retry :: :default | false | keyword()

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_opts: keyword(),
          model: String.t() | nil,
          tools: [ALLM.Tool.t()],
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          image_adapter: module() | nil,
          params: map(),
          context: map(),
          retry: retry(),
          middleware: [module()],
          metadata: map()
        }

  defstruct [
    :adapter,
    adapter_opts: [],
    :model,
    tools: [],
    :tool_executor,
    :tool_result_encoder,
    :image_adapter,
    params: %{},
    context: %{},
    retry: :default,
    middleware: [],
    metadata: %{}
  ]
end
```

#### Retry policy

`retry` controls transient-error retry for non-streaming adapter calls. Streaming calls are not retried automatically (partial output has already been delivered to the consumer).

- `:default` — retry up to 3 times on `429`, `500`, `502`, `503`, `504`, and `{:error, :timeout}`. Delay: `min(30s, 500ms * 2^n) + jitter(0..250ms)`. The `Retry-After` header, when present, overrides the computed delay.
- `false` — never retry; surface the first error to the caller.
- keyword list — override individual knobs:
  - `:max_attempts` (non-neg int, default `3`) — total attempts including the first
  - `:base_delay_ms` (default `500`)
  - `:max_delay_ms` (default `30_000`)
  - `:retry_on` (list of status codes and error atoms; default `[429, 500, 502, 503, 504, :timeout]`)
  - `:jitter_ms` (default `250`)
  - `:respect_retry_after` (default `true`)

Retries are adapter-implemented (the adapter owns the HTTP loop and knows what counts as retryable for its provider's error shape). The engine-level `retry` field is the single source of truth — adapters must not apply hidden additional retries.

Each retry attempt emits `[:allm, :adapter, :retry]` telemetry with `%{attempt, delay_ms, reason}` metadata (§29).

### 6.2 `ALLM.Engine` API

```elixir
defmodule ALLM.Engine do
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  @spec put_tool(t(), ALLM.Tool.t()) :: t()
  def put_tool(engine, tool)

  @spec put_tools(t(), [ALLM.Tool.t()]) :: t()
  def put_tools(engine, tools)

  @spec put_param(t(), atom() | String.t(), term()) :: t()
  def put_param(engine, key, value)

  @spec put_context(t(), atom() | String.t(), term()) :: t()
  def put_context(engine, key, value)

  @spec with_model(t(), String.t()) :: t()
  def with_model(engine, model)

  @spec merge_opts(t(), keyword()) :: t()
  def merge_opts(engine, opts)

  @spec resolve_model(t(), keyword()) :: String.t() | nil
  def resolve_model(engine, opts)

  @spec resolve_tools(t(), keyword()) :: [ALLM.Tool.t()]
  def resolve_tools(engine, opts)

  @spec resolve_params(t(), keyword()) :: map()
  def resolve_params(engine, opts)
end
```

Resolution order should be:

1. explicit per-call opts
2. engine defaults
3. application defaults

### 6.3 Model catalog integration (optional `llm_db`)

`ALLM.Request.model` and `ALLM.Engine.model` accept any of:

```elixir
"gpt-4.1-mini"                   # bare ID — adapter must know what to do
"openai:gpt-4.1-mini"            # canonical provider:id spec
"gpt-4.1-mini@openai"            # filesystem-safe alias of the above
{:openai, "gpt-4.1-mini"}        # tuple form
%ALLM.ModelRef{}                  # pre-resolved struct (see below)
```

If the optional [`llm_db`](https://hexdocs.pm/llm_db) dependency is present, `ALLM.Engine` resolves model strings at request-build time through `LLMDB.model/1`. The result is a `%ALLM.ModelRef{}` carrying:

```elixir
defmodule ALLM.ModelRef do
  @type t :: %__MODULE__{
          provider: atom(),
          id: String.t(),                 # canonical ID (aliases resolved)
          capabilities: map(),            # chat, tools, json_native, streaming, ...
          limits: %{context: pos_integer(), output: pos_integer()} | map(),
          pricing: %{input: number(), output: number()} | nil,
          metadata: map()
        }

  defstruct [:provider, :id, :capabilities, :limits, :pricing, metadata: %{}]
end
```

The engine uses this to:

- **Pre-flight validation** — reject requests that use tools against a model whose `capabilities.tools.enabled` is false, or `response_format: :json_schema` against a model whose `capabilities.json_native` is false. Surfaces as `{:error, {:unsupported_capability, :tools}}` before any network call.
- **Cost population** — after a response comes back, `ALLM.Usage.{input_cost,output_cost,total_cost}` are filled from `pricing`. When the catalog has no pricing, the cost fields stay `nil`.
- **Capability-based selection** — callers may skip naming a model and instead pass `select:` to the request:

  ```elixir
  ALLM.request(messages,
    select: [require: [chat: true, tools: true, json_native: true],
             prefer: [:anthropic, :openai]]
  )
  ```

  `ALLM.Engine.resolve_model/2` delegates to `LLMDB.select/1` and caches the choice on the engine for subsequent calls.

When `llm_db` is **not** present, model strings are passed through verbatim, capability pre-flight is skipped, and cost fields remain `nil`. The catalog dependency is strictly additive — nothing in the core API requires it.

### 6.4 API key management

`ALLM.Engine` does not carry API keys directly. Keys are resolved through `ALLM.Keys` with this precedence:

1. explicit per-call `api_key:` opt
2. `ALLM.Keys.put/2` in-process override
3. `config :llm, keys: %{openai: "..."}`
4. environment variables — conventional names per provider (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …)
5. `.env` file at project root (opt-in via `config :llm, load_dotenv: true`)

```elixir
defmodule ALLM.Keys do
  @spec put(atom(), String.t()) :: :ok
  def put(provider, key)

  @spec get(atom()) :: {:ok, String.t(), source :: atom()} | {:error, :missing}
  def get(provider)

  @spec fetch!(atom(), keyword()) :: String.t()
  def fetch!(provider, opts \\ [])
end
```

Adapters call `ALLM.Keys.fetch!/2` during request preparation, passing any `api_key:` override from opts. Keys never appear in serialized `ALLM.Session`, `ALLM.Request`, or `ALLM.Response` values.

---

## 7. Behaviours

### 7.1 `ALLM.Adapter`

```elixir
defmodule ALLM.Adapter do
  @callback generate(ALLM.Request.t(), keyword()) ::
              {:ok, ALLM.Response.t()} | {:error, term()}

  @callback prepare_request(ALLM.Request.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @callback translate_options(keyword(), ALLM.Request.t()) :: keyword()

  @optional_callbacks prepare_request: 2, translate_options: 2
end
```

`prepare_request/2` is the low-level escape hatch: it returns a configured `Req.Request` that the caller can further customize (headers, retries, middleware) before passing to `Req.request/1`. This mirrors req_llm's pattern and lets applications plug ALLM adapters into existing Req pipelines without losing orchestration.

`translate_options/2` lets providers rename or reshape engine-level params to their API dialect — e.g. OpenAI's newer endpoints require `max_completion_tokens` instead of `max_tokens`, and Anthropic uses `system` as a top-level field rather than a system-role message. The default implementation is identity.

### 7.2 `ALLM.StreamAdapter`

```elixir
defmodule ALLM.StreamAdapter do
  @callback stream(ALLM.Request.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
```

**HTTP transport guidance.** Adapters should use `Req` for non-streaming calls and `Finch` directly for streaming. Req's SSE support does not cover every provider's chunked-response quirks, and Finch HTTP/1 is the proven path (HTTP/2 flow control breaks for request bodies >64KB — the same issue documented in req_llm). Engines may inject a custom Finch name via `adapter_opts: [finch_name: MyApp.Finch]`.

### 7.3 `ALLM.ToolExecutor`

```elixir
defmodule ALLM.ToolExecutor do
  @callback execute(ALLM.Tool.t(), map(), keyword()) ::
              ALLM.Tool.handler_result()
end
```

Executors are expected to pass handler return values through unchanged so the orchestrator can dispatch on `{:ok, _}`, `{:error, _}`, `{:ask_user, ...}`, and `{:halt, ...}`. See §12.3 (ask-user) and §30 (handler halt + tool error policy) for the orchestrator's behaviour for each variant.

### 7.4 `ALLM.ToolResultEncoder`

```elixir
defmodule ALLM.ToolResultEncoder do
  @callback encode(term()) :: String.t()
end
```

---

## 8. Event protocol

```elixir
defmodule ALLM.Event do
  @type t ::
          {:message_started, map()}
          | {:text_delta, %{id: String.t() | nil, delta: String.t()}}
          | {:text_completed, %{id: String.t() | nil, text: String.t()}}
          | {:tool_call_started, %{id: String.t(), name: String.t()}}
          | {:tool_call_delta, %{id: String.t(), arguments_delta: String.t()}}
          | {:tool_call_completed,
             %{id: String.t(), name: String.t(), arguments: map(), raw_arguments: String.t()}}
          | {:tool_execution_started,
             %{id: String.t(), name: String.t(), arguments: map()}}
          | {:tool_execution_completed,
             %{id: String.t(), name: String.t(), result: term()}}
          | {:tool_result_encoded, %{id: String.t(), content: String.t()}}
          | {:ask_user_requested,
             %{tool_call_id: String.t(), tool_name: String.t(), question: String.t(), opts: keyword()}}
          | {:tool_halt, %{tool_call_id: String.t(), reason: atom(), result: term()}}
          | {:message_completed, %{message: ALLM.Message.t()}}
          | {:step_completed, %{response: ALLM.Response.t(), thread: ALLM.Thread.t()}}
          | {:chat_completed, %{result: ALLM.ChatResult.t()}}
          | {:raw_chunk, term()}
          | {:error, term()}
end
```

> **Payload extension — Phase 10.6.** The `:message_completed` payload may
> carry an optional `:metadata` (map) key — added Phase 10.6 to surface
> terminal provider-specific completion metadata such as
> `Response.metadata.reasoning.summary` from the OpenAI Responses-API
> streaming path. `ALLM.StreamCollector.apply_event/2` merges the map into
> `state.metadata` via `Map.merge/2`. Adapters that don't populate it omit
> the key entirely; consumers that don't read it continue to match
> non-exhaustively.

---

## 9. Request building

```elixir
@spec request([ALLM.Message.t()], keyword()) :: ALLM.Request.t()
```

Accepted options:

```elixir
[
  model: String.t(),
  tools: [ALLM.Tool.t()],
  tool_choice: :auto | :none | String.t() | map(),
  temperature: number(),
  max_tokens: non_neg_integer(),
  stream: boolean(),
  response_format: map(),
  options: keyword() | map(),
  metadata: map()
]
```

---

## 10. Stateless execution API

### Option precedence

All functions in §10 accept `opts :: keyword()` as the final argument. When an option is set in multiple places, the precedence (highest wins) is:

1. **call `opts`** — `ALLM.generate(engine, request, model: "gpt-5-nano")` overrides everything else for this call
2. **`ALLM.Request` field** — `request.model`, `request.temperature`, etc.
3. **engine defaults** — `engine.model`, `engine.params`, `engine.retry`, etc.
4. **application config** — `config :allm, …`
5. **library defaults** — documented per option

Unknown options in `opts` are forwarded to the adapter unchanged (after `translate_options/2`, §7.1). This is how provider-specific params flow through — e.g. `reasoning_effort: :high` for OpenAI o-series models.

### 10.1 `ALLM.generate/3`

```elixir
@spec generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
        {:ok, ALLM.Response.t()} | {:error, term()}
```

Single provider request. No orchestration loop.

### 10.2 `ALLM.stream_generate/3`

```elixir
@spec stream_generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
        {:ok, Enumerable.t()} | {:error, term()}
```

Primitive streaming execution for a single request.

### 10.3 `ALLM.step/3`

```elixir
@spec step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
        {:ok, ALLM.StepResult.t()} | {:error, term()}
```

One logical assistant step.

### 10.4 `ALLM.stream_step/3`

```elixir
@spec stream_step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
        {:ok, Enumerable.t()} | {:error, term()}
```

One streamed assistant step.

### 10.5 `ALLM.chat/3`

```elixir
@spec chat(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
        {:ok, ALLM.ChatResult.t()} | {:error, term()}
```

Full orchestration loop.

> **Phase 18 amendment (commits `2a7fa7c..f56cfa6`).** The `:manual_tool_calls`
> halt-reason fires under TWO conditions:
>
> 1. **Whole-loop manual** — the call site passes `mode: :manual` and the
>    response surfaces tool calls. `metadata.mode == :manual` distinguishes
>    this path; tool calls live on `final_response.tool_calls`.
>    (`lib/allm/chat.ex:1058` writes `metadata: %{mode: :manual}` for this
>    path; `lib/allm/chat.ex:945` is the loop halt detector.)
> 2. **Per-tool manual under `mode: :auto`** — any called tool has
>    `manual: true` (§5.2). Auto-bucket tools have already executed and
>    their `:tool` messages are in `result.thread`; the manual bucket
>    surfaces in `metadata.manual_tool_calls` as a `[%ToolCall{}]` list.
>    (`lib/allm/chat.ex:944` is the loop halt detector;
>    `lib/allm/chat.ex:961` writes the `manual_tool_calls` halt-metadata.)
>
> Consumers that only need "tool calls await caller resolution" don't have
> to distinguish; consumers that need to (e.g. for telemetry) inspect
> either `metadata.mode` or `metadata.manual_tool_calls`. See §12.4.

### 10.6 `ALLM.stream/3`

```elixir
@spec stream(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
        {:ok, Enumerable.t()} | {:error, term()}
```

Streams the full orchestration lifecycle end to end.

---

## 11. Stateful continuation API

```elixir
defmodule ALLM.Session do
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  @spec start(ALLM.Engine.t(), [ALLM.Message.t()], keyword()) ::
          {:ok, t(), ALLM.ChatResult.t()} | {:error, term()}
  def start(engine, messages, opts \\ [])

  @spec stream_start(ALLM.Engine.t(), [ALLM.Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_start(engine, messages, opts \\ [])

  @spec reply(ALLM.Engine.t(), t(), String.t(), keyword()) ::
          {:ok, t(), ALLM.ChatResult.t()} | {:error, term()}
  def reply(engine, session, user_text, opts \\ [])

  @spec stream_reply(ALLM.Engine.t(), t(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_reply(engine, session, user_text, opts \\ [])

  @spec continue(ALLM.Engine.t(), t(), ALLM.Message.t(), keyword()) ::
          {:ok, t(), ALLM.ChatResult.t()} | {:error, term()}
  def continue(engine, session, message, opts \\ [])

  @spec step(ALLM.Engine.t(), t(), keyword()) ::
          {:ok, t(), ALLM.StepResult.t()} | {:error, term()}
  def step(engine, session, opts \\ [])

  @spec stream_step(ALLM.Engine.t(), t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_step(engine, session, opts \\ [])

  @spec append(t(), ALLM.Message.t()) :: t()
  def append(session, message)

  @spec append_user(t(), String.t()) :: t()
  def append_user(session, text)

  @spec append_tool_result(t(), String.t(), String.t() | map()) :: t()
  def append_tool_result(session, tool_call_id, content)

  @spec submit_tool_result(t(), String.t(), term()) ::
          t() | {:error, ALLM.Error.SessionError.t()}
  def submit_tool_result(session, tool_call_id, result)

  @spec submit_tool_results(t(), [{String.t(), term()}]) ::
          t() | {:error, ALLM.Error.SessionError.t()}
  def submit_tool_results(session, results)
  # Amendment: return widened from `t()` to include `{:error,
  # %SessionError{reason: :unknown_tool_call_id}}` — see
  # `steering/PHASE_8_DESIGN.md` Non-obvious Decision #14: an unknown id is
  # data-validation, not a programmer-flow error, so it returns rather than
  # raises. `submit_tool_results/2` short-circuits on the first error.

  @spec pending_tool_calls(t()) :: [ALLM.ToolCall.t()]
  def pending_tool_calls(session)

  @spec messages(t()) :: [ALLM.Message.t()]
  def messages(session)
end
```

Session statuses and the events that produce each are defined on `ALLM.Session` (§5.7). The ask-user transition is covered in §12.3.

---

## 12. Manual vs automatic orchestration

Supported values:

```elixir
mode: :auto | :manual
```

### `mode: :auto`

- tools execute automatically
- the system continues after tool results are appended

### `mode: :manual`

- execution stops after tool calls are surfaced
- session status becomes `:awaiting_tools`
- caller submits tool results later

### 12.3 Ask-user suspension (both modes)

A tool may request user input mid-run by returning `{:ask_user, question}` or `{:ask_user, question, opts}` from its handler. This works in both `:auto` and `:manual` orchestration — it does not require switching to manual mode.

When the orchestrator sees this return value:

1. The tool result is encoded (using the configured `ALLM.ToolResultEncoder`) as the text `"<awaiting user response>"` so the thread stays well-formed; provider-specific encoders may override.
2. The question is appended to the thread as an `:assistant` message with `metadata: %{ask_user: true, tool_call_id: id}`.
3. The loop halts before the next adapter call.
4. **Session callers** — `ALLM.Session` transitions to `status: :awaiting_user`; `pending_question` and `pending_tool_call_id` are populated; the returned `ALLM.ChatResult.halted_reason` is `:ask_user`.
5. **Chat callers** (`ALLM.chat/3` without a session) — the returned `ALLM.ChatResult` has `halted_reason: :ask_user`, `pending_question: question`, and `pending_tool_call_id: id`. Resume by appending `ALLM.user(answer)` to `result.thread` and calling `ALLM.chat/3` again.
6. **Stream callers** — the stream emits `{:ask_user_requested, %{tool_call_id, tool_name, question, opts}}` followed by `{:chat_completed, %{result: chat_result}}` and terminates.

`opts` in the handler return value is passed through verbatim in the event and `ChatResult.metadata.ask_user_opts`. Typical uses:

- `[choices: ["yes", "no", "skip"]]` — hint to a UI that this should render as buttons, not a free-text field
- `[mask: true]` — input is sensitive (a password, API key); suggest the UI obscure it
- `[timeout_ms: 60_000]` — soft timeout hint for the UI

None of these are enforced by the library; they're application-level hints.

Resuming via `ALLM.Session.reply/4` clears `pending_question` and `pending_tool_call_id`, appends the answer as a `:user` message, and resumes orchestration using the session's current mode.

### 12.4 Per-tool manual (Phase 18)

> Added in Phase 18 (commits `2a7fa7c..f56cfa6`). The amendment is additive
> — pre-Phase-18 callers who never set `manual: true` on a tool see zero
> behaviour change.

`%ALLM.Tool{manual: true}` (§5.2) opts a single tool out of auto-execution
under `mode: :auto`. Without this flag, the only way to halt the loop on a
specific tool was to flip the entire engine to `mode: :manual` (which
suspends auto-execution for *every* tool). Per-tool manual makes the split
first-class.

**Partition.** When a response arrives under `mode: :auto` with
`finish_reason: :tool_calls`, the chat orchestrator partitions the
response's `tool_calls` against the engine's resolved tools list, splitting
into two buckets:

- **auto** — tools where `manual` is `false` (default).
- **manual** — tools where `manual` is `true`.

Auto tools execute eagerly via `ALLM.ToolRunner` (§17). The loop then halts
with `halted_reason: :manual_tool_calls`, surfacing the manual bucket in
`metadata.manual_tool_calls` as a `[%ToolCall{}]` list. The returned
`%ChatResult.thread` includes the assistant message AND the auto bucket's
`:tool` messages, but NOT placeholder `:tool` messages for the manual
ones — the caller must append those before re-issuing `chat/3`.

The partition runs in `ALLM.Chat`, not in `ALLM.ToolRunner` (§17 amendment).

**Three cases per turn:**

1. **Pure auto** — every called tool has `manual: false`. Identical to
   pre-Phase-18 behaviour; no halt.
2. **Pure manual** — every called tool has `manual: true`. No tools
   execute; loop halts with `:manual_tool_calls` and
   `metadata.manual_tool_calls` populated. Equivalent to whole-loop
   `mode: :manual` for this turn (and distinguishable downstream — the
   per-tool path leaves `metadata.mode` UNSET to `:manual`).
3. **Mixed** — auto tools run eagerly; loop halts with
   `:manual_tool_calls` and the manual bucket surfaces.

**Worked example — `chat/3`:**

```elixir
weather = ALLM.tool(name: "weather", schema: %{}, handler: fn _ -> {:ok, %{forecast: "sunny"}} end)
charge  = ALLM.tool(name: "charge_card", schema: %{}, handler: fn _ -> {:ok, "ok"} end, manual: true)

engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, tools: [weather, charge])

{:ok, result} = ALLM.chat(engine, [ALLM.user("Charge $20 if sunny in Boston.")])

result.halted_reason
# => :manual_tool_calls

result.metadata.manual_tool_calls
# => [%ALLM.ToolCall{id: "c1", name: "charge_card", ...}]

# `weather` already ran; its result is in result.thread.
Enum.count(result.thread.messages, &(&1.role == :tool))
# => 1
```

**Worked example — `Session`:**

```elixir
{:ok, session, _} = ALLM.Session.start(engine, [ALLM.user("Charge $20 if sunny in Boston.")])

session.status
# => :awaiting_tools

session.pending_tool_calls
# => [%ALLM.ToolCall{name: "charge_card", ...}]   # NOT weather — auto already ran

session = ALLM.Session.submit_tool_result(session, "c1", %{status: "approved"})
{:ok, session, _} = ALLM.Session.continue(engine, session, nil)

session.status
# => :completed
```

**Streaming.** Stream consumers see `:tool_execution_started` /
`:tool_execution_completed` events only for the auto bucket. The trailing
`:step_completed` payload carries an additive `:manual_tool_calls` key
(empty list when no manual tools were involved — additive payload key,
non-breaking per CLAUDE.md "adding a key to an existing event's payload
map is NOT breaking"). The `:chat_completed` event's
`payload.result.halted_reason` is `:manual_tool_calls` and
`payload.result.metadata.manual_tool_calls` mirrors the non-streaming
result.

**Interaction with `:mode`.** When `mode: :manual` is passed at the call
site, the existing whole-loop short-circuit fires *before* the partition
runs. The `:manual` flag on individual tools is irrelevant under
`mode: :manual` — the whole loop suspends, no tools execute, every called
tool is surfaced for resolution.

**Re-issue contract.** Raw `chat/3` callers MUST append `:tool` messages
for every id in `metadata.manual_tool_calls` before re-issuing. Naively
calling `chat/3` again on `result.thread` without first appending tool
results sends a malformed request to the provider (assistant tool_call
ids without matching tool results), surfacing as
`%ALLM.Error.AdapterError{reason: :invalid_request}`. The Session API
enforces this via `pending_tool_calls` and `submit_tool_result/3`.

---

## 13. Streaming reducers and collectors

### 13.1 `ALLM.StreamCollector`

```elixir
defmodule ALLM.StreamCollector do
  @type state :: %__MODULE__{
          thread: ALLM.Thread.t(),
          current_text: String.t(),
          current_tool_calls: map(),
          last_response: ALLM.Response.t() | nil,
          steps: [ALLM.StepResult.t()],
          done?: boolean(),
          metadata: map()
        }

  defstruct [
    :thread,
    current_text: "",
    current_tool_calls: %{},
    last_response: nil,
    steps: [],
    done?: false,
    metadata: %{}
  ]

  @spec new(ALLM.Thread.t()) :: state()
  def new(thread)

  @spec apply_event(state(), ALLM.Event.t()) :: state()
  def apply_event(state, event)

  @spec to_step_result(state()) :: ALLM.StepResult.t()
  def to_step_result(state)

  @spec to_chat_result(state()) :: ALLM.ChatResult.t()
  def to_chat_result(state)
end
```

### 13.2 `ALLM.Session.StreamReducer`

```elixir
defmodule ALLM.Session.StreamReducer do
  @spec new(ALLM.Session.t()) :: map()
  def new(session)

  @spec apply_event(map(), ALLM.Event.t()) :: map()
  def apply_event(state, event)

  @spec finalize(map()) :: {ALLM.Session.t(), ALLM.StepResult.t() | ALLM.ChatResult.t()}
  def finalize(state)
end
```

---

## 14. Thread helpers

```elixir
defmodule ALLM.Thread do
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  @spec from_messages([ALLM.Message.t()]) :: t()
  def from_messages(messages)

  @spec add_message(t(), ALLM.Message.t()) :: t()
  def add_message(thread, message)

  @spec add_messages(t(), [ALLM.Message.t()]) :: t()
  def add_messages(thread, messages)

  @spec add_system(t(), String.t()) :: t()
  def add_system(thread, text)

  @spec add_user(t(), String.t()) :: t()
  def add_user(thread, text)

  @spec add_assistant(t(), String.t()) :: t()
  def add_assistant(thread, text)

  @spec messages(t()) :: [ALLM.Message.t()]
  def messages(thread)

  @spec last_message(t()) :: ALLM.Message.t() | nil
  def last_message(thread)
end
```

---

## 15. Tool helpers

```elixir
defmodule ALLM.Tool do
  @spec new(keyword()) :: t()
  def new(opts)

  @spec validate(t()) :: :ok | {:error, [term()]}
  def validate(tool)

  @spec call(t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(tool, args, opts \\ [])
end
```

---

## 16. Validation

```elixir
defmodule ALLM.Validate do
  @spec request(ALLM.Request.t()) :: :ok | {:error, [term()]}
  def request(request)

  @spec message(ALLM.Message.t()) :: :ok | {:error, [term()]}
  def message(message)

  @spec tool(ALLM.Tool.t()) :: :ok | {:error, [term()]}
  def tool(tool)

  @spec thread(ALLM.Thread.t()) :: :ok | {:error, [term()]}
  def thread(thread)

  @spec session(ALLM.Session.t()) :: :ok | {:error, [term()]}
  def session(session)
end
```

Minimum validation rules:

- request messages are not empty
- message roles are valid
- tool names are unique
- `:tool` messages include `tool_call_id`

---

## 17. Internal modules

```elixir
defmodule ALLM.Runner do
  @spec run(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, term()}
  def run(engine, request, opts)
end
```

```elixir
defmodule ALLM.StreamRunner do
  @spec run(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def run(engine, request, opts)
end
```

```elixir
defmodule ALLM.ToolRunner do
  @spec run_tool_calls([ALLM.ToolCall.t()], [ALLM.Tool.t()], keyword()) ::
          {:ok, [ALLM.Message.t()]} | {:error, term()}
  def run_tool_calls(tool_calls, tools, opts)
end
```

> **Phase 18 amendment (commits `2a7fa7c..f56cfa6`).** Under `mode: :auto`,
> `run_tool_calls/3` and `stream_tool_calls/3` receive the **auto bucket
> only** when any tool in the response has `manual: true` (§5.2). The
> auto/manual partition is upstream in `ALLM.Chat` (`do_step/4` at
> `lib/allm/chat.ex:1044`; streaming `transition_a_to_b/1` at
> `lib/allm/chat.ex:1337`); the runner's contract — "execute these tool
> calls" — is unchanged. The runner sees a partial subset and never
> observes the manual ones. Chat-layer `preflight_unknown_tools/2` runs
> BEFORE the partition, so the runner's internal preflight is
> defence-in-depth (it never observes an unknown tool name in the
> per-tool path).

```elixir
defmodule ALLM.Chat do
  @spec step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, ALLM.StepResult.t()} | {:error, term()}
  def step(engine, thread_or_messages, opts)

  @spec stream_step(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_step(engine, thread_or_messages, opts)

  @spec run(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, ALLM.ChatResult.t()} | {:error, term()}
  def run(engine, thread_or_messages, opts)

  @spec stream(ALLM.Engine.t(), ALLM.Thread.t() | [ALLM.Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(engine, thread_or_messages, opts)
end
```

---

## 18. Default implementations

### `ALLM.ToolExecutor.Default`

```elixir
defmodule ALLM.ToolExecutor.Default do
  @behaviour ALLM.ToolExecutor

  @impl true
  def execute(%ALLM.Tool{handler: handler}, args, opts)
end
```

### `ALLM.ToolResultEncoder.JSON`

```elixir
defmodule ALLM.ToolResultEncoder.JSON do
  @behaviour ALLM.ToolResultEncoder

  @impl true
  def encode(term)
end
```

---

## 19. Streaming options

```elixir
[
  mode: :auto | :manual,
  emit_text_deltas: boolean(),
  emit_tool_deltas: boolean(),
  include_raw_chunks: boolean(),
  on_event: (ALLM.Event.t() -> any()),
  max_turns: pos_integer(),
  halt_when: (ALLM.StepResult.t() -> boolean())
]
```

---

## 20. Error model

Standard return shapes:

```elixir
{:ok, value}
{:error, reason}
```

Common reasons:

```elixir
:missing_adapter
:invalid_request
:invalid_tool
:tool_not_found
:no_handler
:max_turns_exceeded
{:adapter_error, term()}
{:tool_error, String.t(), term()}
{:validation_error, [term()]}
```

---

## 21. Sample engine construction

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-4.1-mini",
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON,
    tools: [
      ALLM.tool(
        name: "get_weather",
        description: "Get current weather by city",
        schema: %{
          type: "object",
          properties: %{
            city: %{type: "string"}
          },
          required: ["city"]
        },
        handler: &MyApp.Tools.get_weather/1
      )
    ],
    params: %{
      temperature: 0.2,
      max_turns: 8
    }
  )
```

---

## 22. Sample stateless usage

```elixir
request =
  ALLM.request(
    [
      ALLM.system("You are concise."),
      ALLM.user("Explain OTP in one paragraph.")
    ],
    max_tokens: 300
  )

{:ok, response} =
  ALLM.generate(engine, request)
```

```elixir
{:ok, result} =
  ALLM.chat(
    engine,
    [
      ALLM.system("You may use tools."),
      ALLM.user("What's the weather in Boston and should I bring a jacket?")
    ]
  )
```

---

## 23. Sample streaming usage

```elixir
{:ok, stream} =
  ALLM.stream(
    engine,
    [
      ALLM.system("You are concise."),
      ALLM.user("Write a haiku about Elixir processes.")
    ]
  )

Enum.each(stream, fn
  {:text_delta, %{delta: delta}} ->
    IO.write(delta)

  {:tool_execution_started, %{name: name}} ->
    IO.puts("\n[tool: #{name}]")

  {:chat_completed, %{result: _result}} ->
    IO.puts("\n--- done ---")

  _ ->
    :ok
end)
```

```elixir
{:ok, stream} = ALLM.stream(engine, thread)

collector =
  Enum.reduce(stream, ALLM.StreamCollector.new(thread), fn event, acc ->
    ALLM.StreamCollector.apply_event(acc, event)
  end)

result = ALLM.StreamCollector.to_chat_result(collector)
```

---

## 24. Sample session usage

```elixir
{:ok, session, result} =
  ALLM.Session.start(
    engine,
    [
      ALLM.system("You are a helpful travel planner."),
      ALLM.user("Help me plan a 5-day Kyoto trip.")
    ],
    id: "trip_123"
  )

MyApp.ChatStore.save!(session)
```

```elixir
session = MyApp.ChatStore.load!("trip_123")

{:ok, session, result} =
  ALLM.Session.reply(
    engine,
    session,
    "My budget is around $2,000."
  )

MyApp.ChatStore.save!(session)
```

---

## 25. Sample manual tool orchestration

```elixir
{:ok, session, result} =
  ALLM.Session.reply(
    engine,
    session,
    "Check tomorrow's weather in Boston.",
    mode: :manual
  )

session.status
# => :awaiting_tools
```

```elixir
session =
  ALLM.Session.submit_tool_result(
    session,
    "call_123",
    %{forecast: "rain", high_f: 56}
  )

{:ok, session, step_result} =
  ALLM.Session.step(engine, session)
```

---

## 26. Sample streamed session reply

```elixir
{:ok, stream} =
  ALLM.Session.stream_reply(
    engine,
    session,
    "Now make that more whimsical."
  )

reducer = ALLM.Session.StreamReducer.new(session)

reducer =
  Enum.reduce(stream, reducer, fn event, reducer ->
    case event do
      {:text_delta, %{delta: delta}} ->
        MyUI.append_token(delta)

      {:tool_execution_started, %{name: name}} ->
        MyUI.set_status("Running #{name}...")

      {:message_completed, %{message: _msg}} ->
        MyUI.clear_status()

      _ ->
        :ok
    end

    ALLM.Session.StreamReducer.apply_event(reducer, event)
  end)

{session, result} = ALLM.Session.StreamReducer.finalize(reducer)
```

---

## 27. Suggested module tree

```text
lib/
  llm.ex
  llm/message.ex
  llm/tool.ex
  llm/tool_call.ex
  llm/request.ex
  llm/response.ex
  llm/thread.ex
  llm/session.ex
  llm/step_result.ex
  llm/chat_result.ex
  llm/event.ex

  llm/engine.ex
  llm/adapter.ex
  llm/stream_adapter.ex
  llm/tool_executor.ex
  llm/tool_result_encoder.ex

  llm/validate.ex
  llm/runner.ex
  llm/stream_runner.ex
  llm/tool_runner.ex
  llm/chat.ex
  llm/stream_collector.ex

  llm/tool_executor/default.ex
  llm/tool_result_encoder/json.ex
  llm/session/stream_reducer.ex

  llm/providers/openai.ex
  llm/providers/anthropic.ex
  llm/providers/fake.ex
```

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** The embeddings capability (§36) adds the following modules. Paths are given under the shipped `lib/allm/` prefix rather than the `llm/` prefix used in the tree above, which predates the package rename.
>
> ```text
> lib/allm/embedding.ex                  # Layer A — one vector + index
> lib/allm/embedding_request.ex          # Layer A
> lib/allm/embedding_response.ex         # Layer A
> lib/allm/embedding_adapter.ex          # Layer B — behaviour
> lib/allm/embedding_batch.ex            # Layer C — chunk / dispatch / merge (@moduledoc false)
> lib/allm/error/embedding_adapter_error.ex
> lib/allm/providers/fake_embeddings.ex
> lib/allm/providers/openai/embeddings.ex
> lib/allm/providers/gemini/embeddings.ex
> lib/allm/providers/voyage/embeddings.ex
> ```
>
> Existing modules extended: `ALLM` (`embed/3`, `embedding_request/2`), `ALLM.Engine` (`:embed_adapter`), `ALLM.Validate` (`embedding_request/1`), `ALLM.Capability` (`preflight_embedding/2`), `ALLM.Telemetry` (`:embed` span), `ALLM.Serializer` (four registry entries), `ALLM.Error.EngineError` (`:no_embed_adapter`), `ALLM.Error.ValidationError` (`:invalid_embedding_request`).

> **Phase 22 amendment (commits `cf8e340..5a73da6`; docs land in the 22.6 commit).** The content-moderation capability (§39) adds the following modules, likewise under the shipped `lib/allm/` prefix.
>
> ```text
> lib/allm/moderation_request.ex         # Layer A
> lib/allm/moderation_result.ex          # Layer A — one verdict + index
> lib/allm/moderation_response.ex        # Layer A
> lib/allm/moderation_adapter.ex         # Layer B — behaviour
> lib/allm/error/moderation_adapter_error.ex
> lib/allm/providers/fake_moderation.ex
> lib/allm/providers/openai/moderation.ex
> ```
>
> There is no moderation counterpart to `lib/allm/embedding_batch.ex`: the façade does not chunk (§39.6).
>
> Existing modules extended: `ALLM` (`moderate/3`, `moderation_request/2`), `ALLM.Engine` (`:moderation_adapter`), `ALLM.Validate` (`moderation_request/1`), `ALLM.Capability` (`preflight_moderation/2`), `ALLM.Telemetry` (`:moderate` span), `ALLM.Serializer` (four registry entries), `ALLM.Error.EngineError` (`:no_moderation_adapter`), `ALLM.Error.ValidationError` (`:invalid_moderation_request`).

---

## 28. Implementation guidance

Recommended build order:

1. data structs
2. `Engine`
3. behaviours
4. `Event`
5. stream runner + fake streaming adapter
6. collectors/reducers
7. streaming APIs
8. non-streaming wrappers
9. session helpers
10. provider adapters

---

## 29. Telemetry

The package emits `:telemetry` events using the `[:llm, ...]` namespace. Telemetry is the primary extension point for logging, metrics, and tracing.

### Event names

```elixir
[:llm, :generate, :start | :stop | :exception]
[:llm, :stream,   :start | :stop | :exception]
[:llm, :step,     :start | :stop]
[:llm, :chat,     :start | :stop]
[:llm, :tool,     :start | :stop | :exception]
```

### Measurements

- `:start` — `%{system_time: integer()}`
- `:stop` — `%{duration: integer()}` (monotonic native units)
- `:exception` — `%{duration: integer()}`

### Metadata

Common to every span: `:engine`, `:request_id`, `:model`.

Additional per-span metadata:

- `generate` / `stream` — `:request`, plus `:response` (on `:stop`), or `:kind` + `:reason` + `:stacktrace` (on `:exception`)
- `step` — `:step_result` on `:stop`
- `chat` — `:chat_result` on `:stop`
- `tool` — `:tool`, `:tool_call`, plus `:result` on `:stop` or `:kind` + `:reason` + `:stacktrace` on `:exception`

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** The embeddings capability (§36) adds one span:
>
> ```elixir
> [:allm, :embed, :start | :stop]
> ```
>
> - `:start` — measurements `%{system_time: integer()}`; metadata `:request_id`, `:engine`, `:model`, `:input_count`.
> - `:stop` — measurements `%{duration: integer(), embedding_count: non_neg_integer(), chunk_count: non_neg_integer()}`; metadata `:request_id`, `:model`, `:usage`, `:response`, `:error` (`nil` on success).
>
> Both extra measurement keys are present on the success and error paths alike (`0` on error), so a handler written against the `[:allm, :image, :stop]` span does not `KeyError` when pointed at this one. `chunk_count` is the only signal that a single `ALLM.embed/3` call became N HTTP requests.
>
> **Namespace note.** This section writes the namespace `[:llm, …]`, which is a pre-existing error: the shipped code and §35.9 both emit `[:allm, …]`. The embeddings events above use `[:allm, …]` and deliberately do not propagate the mistake. The `[:llm, …]` spellings in the Event names block are stale and should be read as `[:allm, …]`.

> **Phase 22 amendment (commits `cf8e340..5a73da6`; docs land in the 22.6 commit).** The content-moderation capability (§39) adds one span:
>
> ```elixir
> [:allm, :moderate, :start | :stop | :exception]
> ```
>
> - `:start` — measurements `%{system_time: integer()}`; metadata `:request_id`, `:engine`, `:model`, `:input_count`, `:multimodal`.
> - `:stop` — measurements `%{duration: integer(), result_count: non_neg_integer(), flagged_count: non_neg_integer()}`; metadata `:request_id`, `:model`, `:input_count`, `:multimodal`, `:usage`, `:response`, `:error` (`nil` on success).
> - `:exception` — measurements `%{duration: integer()}`; metadata `:kind`, `:reason`, `:stacktrace`. Emitted instead of `:stop`, then re-raised.
>
> Both extra measurement keys are present on the success and error paths alike (`0` on error). `:usage` is carried as `nil` unconditionally even though `%ALLM.ModerationResponse{}` has no `:usage` field, so a handler written against the `[:allm, :embed, :stop]` or `[:allm, :image, :stop]` span does not `KeyError` when pointed at this one. `:input_count` is the raw element count, **not** the provider's item count, which is `1` whenever `:multimodal` is true — see §39.9.
>
> The namespace note above applies unchanged: these events use `[:allm, …]`.

### Relationship to `middleware`

The `middleware` field on `ALLM.Engine` is reserved for a later version. In v0.2 it must be an empty list. Cross-cutting concerns (logging, metrics, retry, rate-limiting) are expressed either through telemetry handlers or by wrapping an adapter module.

---

## 30. Timeouts and cancellation

### Timeouts

Engines and per-call `opts` accept:

```elixir
[
  request_timeout: timeout(),   # whole non-streaming call; default :infinity
  stream_timeout:  timeout(),   # max time between consecutive events; default :infinity
  tool_timeout:    timeout()    # single tool execution; default 30_000
]
```

Resolution follows the same order as other params (§6.2): explicit opts > engine defaults > application defaults.

Adapters are expected to honor `request_timeout` and `stream_timeout` via their HTTP client. Exceeding a timeout surfaces as `{:error, :timeout}` for non-streaming calls, or as a terminating `{:error, :timeout}` event for streams.

`tool_timeout` is enforced by `ALLM.ToolRunner`. Tools that exceed it receive `{:error, {:tool_error, name, :timeout}}` and the orchestrator treats the tool as failed — it may append an error tool-result message and continue, or halt, depending on engine `on_tool_error` policy (see below).

### Handler-requested halt

A tool handler may end the loop cleanly by returning `{:halt, reason, result}`. The orchestrator:

1. Encodes `result` as the tool-result message and appends it to the thread (so the ended loop has a well-formed transcript).
2. Emits `{:tool_halt, %{tool_call_id: id, reason: reason, result: result}}` on streams.
3. Stops before the next adapter call and returns `ALLM.ChatResult{halted_reason: reason}`.

Reserved reason atoms are listed in §5.2. Any other atom is accepted as a user-defined halt reason; callers typically use one per halt-site (`:plan_submitted`, `:budget_exceeded`, `:user_cancelled`).

### Tool error policy

```elixir
on_tool_error: :halt | :continue | (ALLM.ToolCall.t(), term() -> {:continue, term()} | :halt)
```

- `:halt` — orchestrator stops with `halted_reason: :tool_error`
- `:continue` — the encoded error becomes the tool-result content and execution proceeds
- function form — caller decides per call; the returned term is encoded as the tool result

Default: `:continue`.

### Cancellation

Streams returned by `stream_*` must be resource-safe.

- If the consumer stops iterating (drops the stream), the underlying HTTP request must be cancelled by the adapter.
- If the consuming process exits, in-flight work is released. Implementations should use a linked `Task` or a monitored producer so consumer crashes don't leak connections.
- Mid-orchestration cancellation inside `ALLM.chat/3` and `ALLM.stream/3` is cooperative: use `halt_when/1` on a per-step basis. For hard cancellation, the consumer terminates the stream.

A cancelled stream terminates without emitting `:chat_completed`. If a final event is required (e.g. for logging), pass `emit_cancelled: true` and the producer emits `{:error, :cancelled}` before closing.

---

## 31. Testing and fake adapter

The package ships `ALLM.Providers.Fake` implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. It makes every orchestration path deterministically testable without network access.

### Scripted responses

Scripts are always a list-of-lists: each inner list scripts the events for one adapter call. The singular `script:` option is shorthand for `scripts: [script]` (a one-call fake). Mixing both raises on engine construction.

```elixir
# single-call fake
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      script: [
        {:text, "Hello "},
        {:text, "world"},
        {:finish, :stop}
      ]
    ]
  )

# multi-call fake — one inner list per round-trip
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      scripts: [
        [
          {:tool_call, id: "t1", name: "get_weather", arguments: %{city: "Boston"}},
          {:finish, :tool_calls}
        ],
        [
          {:text, "It's 72°F in Boston."},
          {:finish, :stop}
        ]
      ]
    ]
  )
```

Calls beyond the last scripted turn return `{:error, :no_scripted_response}`.

Supported script entries:

```elixir
{:text, String.t()}
{:tool_call, keyword()}              # :id, :name, :arguments
{:tool_call_delta, keyword()}        # :id, :arguments_delta (streaming only)
{:usage, map()}
{:raw_chunk, term()}
{:finish, ALLM.Response.finish_reason()}
{:error, term()}                     # terminate stream with error
{:delay, non_neg_integer()}          # insert latency (ms) between events
```

Each script entry corresponds 1:1 with an emitted event so tests can assert exact event sequences. The historical alias `{:sleep, ms}` is accepted but deprecated — prefer `{:delay, ms}`.

### Assertion helpers

```elixir
defmodule ALLM.Test do
  @spec collect(Enumerable.t()) :: [ALLM.Event.t()]
  def collect(stream)

  @spec text(Enumerable.t() | [ALLM.Event.t()]) :: String.t()
  def text(events_or_stream)

  @spec tool_calls(Enumerable.t() | [ALLM.Event.t()]) :: [ALLM.ToolCall.t()]
  def tool_calls(events_or_stream)
end
```

### Property-style coverage

Targeted scenarios every implementation must pass:

- pure text streaming with and without `emit_text_deltas: false`
- single tool call with `mode: :auto` and `mode: :manual`
- parallel tool calls in one assistant turn
- `max_turns` cap hit mid-loop (`halted_reason: :max_turns`)
- `halt_when` returns true (`halted_reason: :halt_when`)
- tool handler raises — see `on_tool_error` policy
- mid-stream adapter error — stream terminates with `{:error, reason}`
- consumer cancellation releases the adapter's HTTP request
- session round-trip: `start` → serialize → deserialize → `reply` yields the same thread tail as an in-memory run

---

## 32. Relationship to the Elixir LLM ecosystem

ALLM does not depend on any other provider-layer library. It ships hand-written adapters and uses the existing ecosystem as a **reference**, not as a dependency.

### 32.1 Initial bundled adapters

v0.2 / v0.3 ships three first-party chat adapters, talking to each provider's API directly over `Req`:

- `ALLM.Providers.OpenAI` — OpenAI Chat Completions + Responses API
- `ALLM.Providers.Anthropic` — Anthropic Messages API
- `ALLM.Providers.Gemini` — Google Generative Language API (`generateContent` / `streamGenerateContent`)

All three implement `ALLM.Adapter` and `ALLM.StreamAdapter`. Additional providers are opt-in and expected to live in separate packages using the same behaviours.

### 32.2 Why no `req_llm` dependency

[`req_llm`](https://github.com/agentjido/req_llm) is a multi-provider HTTP layer (Req + Finch, ~18 providers, structured output, embeddings, image generation) that was evaluated as a dependency and declined:

- provider-layer libraries in this ecosystem move slowly and several have gone unmaintained; taking a hard dependency couples ALLM's release cadence to theirs
- provider APIs change quickly and ALLM needs to track them on its own schedule
- ALLM wants to own the Req-level request shape so that `prepare_request/2` (§7.1) hands callers a clean `Req.Request` without a second translation layer in between

`req_llm` remains a useful design **reference** for provider quirks, header conventions, and SSE framing across providers. ALLM borrows patterns (the `prepare_request/2` escape hatch — §7.1 — is directly inspired by it), but not code.

### 32.3 Other reference projects

- **[`openai_ex`](https://hexdocs.pm/openai_ex/)** — single-provider, thin client. Useful reference for OpenAI endpoint coverage and request shapes.
- **[`llm_db`](https://hexdocs.pm/llm_db)** — model metadata catalog (capabilities, pricing, aliases). Referenced in §6.3 as an **optional** dependency; core ALLM functions without it.

### 32.4 What ALLM owns

- `ALLM.Session` and the `:awaiting_user | :awaiting_tools | :completed` state machine
- `ALLM.Event` as the unified streaming protocol
- `ALLM.StepResult` and `ALLM.ChatResult` as orchestration data
- manual vs auto tool orchestration (§12)
- engine composition (§6), telemetry (§29), cancellation (§30), deterministic testing (§31)
- direct provider adapters for OpenAI and Anthropic (§32.1), including HTTP, SSE parsing, retries, and per-provider param/header translation

### 32.5 Explicitly out of scope for v0.2

- audio — callers drop down to a provider SDK directly
- image generation — candidate for a first-class non-streaming primitive in a later version; not shipped in v0.2

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** **Embeddings are no longer out of scope** — they ship in v0.5 as a first-class non-streaming primitive (`ALLM.embed/3`, `%ALLM.EmbeddingRequest{}` / `%ALLM.EmbeddingResponse{}`, the `ALLM.EmbeddingAdapter` behaviour, and the `:embed_adapter` engine slot). See **§36**. The line above is amended to remove "embeddings"; audio remains out of scope. Image generation likewise shipped in v0.3 (§35) but is left in the list above because that line is scoped to *v0.2* and is preserved as a historical record of what v0.2 excluded.

---

## 33. v0.2 non-goals

Out of scope for the initial version:

- prompt templating DSLs
- memory stores and retrieval systems
- advanced agent planning layers
- workflow schedulers
- hard-coded provider-specific abstractions in the core API
- audio input/output (see §32.5)
- dependency on `req_llm` or any other multi-provider HTTP library (see §32.2)

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** The line above previously read `embeddings, audio input/output, image generation (see §32.5)`. Two of its three entries were stale:
>
> - **image generation** shipped in v0.3 (**§35**) and was never struck when it did — corrected here;
> - **embeddings** ship in v0.5 (**§36**) — struck here.
>
> Audio input/output remains a genuine non-goal.

---

## 34. Summary

This spec defines a package with a clear separation of concerns:

- **`ALLM.Engine`** is the runtime execution environment
- **`ALLM.Session`** is persisted conversation state
- **`ALLM.Thread`** is raw message history
- **`ALLM.Event`** is the first-class streaming protocol
- **`ALLM.stream*`** functions are primitive
- **`ALLM.generate/step/chat`** are reducers over the streaming layer

That keeps the package serializable where it should be, runtime-capable where it needs to be, and stream-native from the start.

---

## 35. v0.3 — Image generation and image processing

v0.3 extends ALLM with non-streaming primitives for working with images. Image workloads are request/response (generation and edits return a final artifact, not a token stream), so the design stays parallel to the chat pipeline but skips the streaming layer entirely.

### 35.1 Design goals

1. **Parallel to the chat pipeline, not entangled with it.** Image requests, responses, and adapters are separate types. Chat adapters do not need to implement image support, and vice versa.
2. **Non-streaming.** No `stream_generate_image/3`. Providers that stream partial image previews can expose it via `options`, but core API is request/response.
3. **Opt-in per engine.** An `ALLM.Engine` without an `image_adapter` returns `{:error, :no_image_adapter}` for image calls. No implicit wiring.
4. **Image *input* (vision) is chat-side.** Multimodal prompts flow through the existing `ALLM.Message.content` list; v0.3 adds structured content-part types so adapters don't hand-translate untyped maps.
5. **Reuse engine plumbing.** Keys (§6.4), model resolution and capability pre-flight (§6.3), telemetry (§29), and deterministic fakes (§31) apply identically to image calls.

### 35.2 Data model

#### 35.2.1 `ALLM.Image`

Single image value — used for both inputs (vision, edits) and outputs (generated images).

```elixir
defmodule ALLM.Image do
  @type source ::
          {:binary, binary()}
          | {:base64, String.t()}
          | {:url, String.t()}
          | {:file, Path.t()}

  @type t :: %__MODULE__{
          source: source(),
          mime_type: String.t() | nil,         # "image/png", "image/jpeg", "image/webp"
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          prompt: String.t() | nil,            # populated on generated images
          revised_prompt: String.t() | nil,    # OpenAI DALL-E 3 returns a revised prompt
          metadata: map()
        }

  defstruct [:source, :mime_type, :width, :height, :prompt, :revised_prompt, metadata: %{}]

  @spec from_file(Path.t()) :: t()
  @spec from_binary(binary(), String.t()) :: t()
  @spec from_url(String.t()) :: t()
  @spec from_base64(String.t(), String.t()) :: t()

  @spec to_binary(t()) :: {:ok, binary()} | {:error, term()}
  @spec to_data_uri(t()) :: {:ok, String.t()} | {:error, term()}
end
```

`ALLM.Image` is serializable when `source` is `{:url, _}`, `{:base64, _}`, or `{:binary, _}` (via `Base.encode64/1` round-trip) and opaque when `{:file, _}`. Sessions that persist generated images should prefer `{:base64, _}` or `{:url, _}`.

#### 35.2.2 `ALLM.ImageRequest`

Single struct covering generation, edits, and variations. The `operation` field selects between them.

```elixir
defmodule ALLM.ImageRequest do
  @type operation :: :generate | :edit | :variation
  @type size :: {pos_integer(), pos_integer()} | String.t() | :auto
  @type quality :: :low | :standard | :high | :hd | :auto | String.t()
  @type response_format :: :binary | :base64 | :url

  @type t :: %__MODULE__{
          operation: operation(),
          model: String.t() | nil,
          prompt: String.t() | nil,
          n: pos_integer(),
          size: size() | nil,
          quality: quality() | nil,
          style: :natural | :vivid | nil,
          background: :transparent | :opaque | nil,
          response_format: response_format(),
          # inputs for :edit and :variation
          input_images: [ALLM.Image.t()],
          mask: ALLM.Image.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :prompt,
    :size,
    :quality,
    :style,
    :background,
    :mask,
    operation: :generate,
    n: 1,
    response_format: :binary,
    input_images: [],
    options: %{},
    metadata: %{}
  ]
end
```

- `:generate` — requires `prompt`; `input_images` must be empty.
- `:edit` — requires `prompt` and exactly one `input_images` entry (two for inpaint-with-mask); `mask` optional.
- `:variation` — requires exactly one `input_images` entry; `prompt` must be `nil` or ignored.

Validation lives in `ALLM.Validate.image_request/1` (analogous to §14).

#### 35.2.3 `ALLM.ImageResponse`

```elixir
defmodule ALLM.ImageResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          images: [ALLM.Image.t()],
          usage: ALLM.ImageUsage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :raw,
    images: [],
    usage: %ALLM.ImageUsage{},
    metadata: %{}
  ]
end
```

#### 35.2.4 `ALLM.ImageUsage`

Image pricing is not token-based in general, so `ALLM.Usage` is a poor fit. `gpt-image-1` is an exception — it charges both input/output tokens *and* image units — so token fields are kept as optional.

```elixir
defmodule ALLM.ImageUsage do
  @type t :: %__MODULE__{
          images: non_neg_integer(),
          size: String.t() | nil,
          quality: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          input_cost: Decimal.t() | nil,
          output_cost: Decimal.t() | nil,
          total_cost: Decimal.t() | nil
        }

  defstruct [
    :size,
    :quality,
    :input_tokens,
    :output_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    images: 0
  ]
end
```

Costs are populated from `llm_db` (§6.3) when available; otherwise `nil`.

### 35.3 `ALLM.ImageAdapter` behaviour

```elixir
defmodule ALLM.ImageAdapter do
  @callback generate(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, ALLM.ImageResponse.t()} | {:error, term()}

  @callback prepare_request(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @callback supported_operations() :: [ALLM.ImageRequest.operation()]

  @optional_callbacks prepare_request: 2
end
```

- `generate/2` handles all three operations — adapters switch on `request.operation`.
- `supported_operations/0` lets the engine pre-flight before dispatching; a request whose operation isn't in the list returns `{:error, {:unsupported_operation, op}}` before any HTTP call.
- `prepare_request/2` is the low-level escape hatch (same role as §7.1).

There is no `ImageStreamAdapter` — streaming is deliberately out of scope.

### 35.4 Engine integration

`ALLM.Engine.t()` gains one field:

```elixir
image_adapter: module() | nil
```

Engines configured with only a chat adapter are unchanged. Engines configured with only an image adapter can still call `ALLM.generate_image/3` but not `ALLM.chat/3`. A single engine may combine providers — e.g. Anthropic for chat and OpenAI for images — since the adapters are independent:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    image_adapter: ALLM.Providers.OpenAI.Images,
    model: "claude-sonnet-4-6"
  )
```

Key resolution (§6.4) uses the adapter's declared provider key namespace, so mixing providers requires both keys to be available.

### 35.5 Public API

```elixir
defmodule ALLM do
  @spec generate_image(ALLM.Engine.t(), String.t() | ALLM.ImageRequest.t(), keyword()) ::
          {:ok, ALLM.ImageResponse.t()} | {:error, term()}

  @spec edit_image(
          ALLM.Engine.t(),
          ALLM.Image.t() | [ALLM.Image.t()],
          String.t(),
          keyword()
        ) :: {:ok, ALLM.ImageResponse.t()} | {:error, term()}

  @spec image_variations(ALLM.Engine.t(), ALLM.Image.t(), keyword()) ::
          {:ok, ALLM.ImageResponse.t()} | {:error, term()}

  @spec image_request(String.t(), keyword()) :: ALLM.ImageRequest.t()
end
```

`generate_image/3` accepts either a bare prompt string (options form the rest of the request) or a fully constructed `%ALLM.ImageRequest{}`. `edit_image/4` and `image_variations/3` are sugar that build the appropriate `ALLM.ImageRequest` under the hood.

Example:

```elixir
{:ok, response} =
  ALLM.generate_image(engine, "a watercolor kestrel perched on a cedar branch",
    model: "gpt-image-1",
    size: {1024, 1024},
    quality: :high,
    n: 2
  )

[image, _] = response.images
File.write!("kestrel.png", elem(image.source, 1))  # {:binary, <<...>>}
```

### 35.6 Image input (vision) in chat messages

`ALLM.Message.content` remains `String.t() | [part]`, with `part` now a tagged struct rather than an untyped map.

```elixir
defmodule ALLM.TextPart do
  @type t :: %__MODULE__{text: String.t(), metadata: map()}
  defstruct [:text, metadata: %{}]
end

defmodule ALLM.ImagePart do
  @type detail :: :auto | :low | :high
  @type t :: %__MODULE__{
          image: ALLM.Image.t(),
          detail: detail(),
          metadata: map()
        }
  defstruct [:image, detail: :auto, metadata: %{}]
end
```

Example user message with a mix of text and image:

```elixir
%ALLM.Message{
  role: :user,
  content: [
    %ALLM.TextPart{text: "What's the failure mode in this diagram?"},
    %ALLM.ImagePart{image: ALLM.Image.from_file("arch.png"), detail: :high}
  ]
}
```

Chat adapters translate parts to provider-specific wire shapes:

- **OpenAI** — `{type: "input_text", text: ...}` and `{type: "input_image", image_url: <data-uri-or-url>}` (Responses API) or the legacy Chat Completions `image_url` form.
- **Anthropic** — `{type: "text", text: ...}` and `{type: "image", source: {type: "base64", media_type: ..., data: ...}}` or `{type: "url", url: ...}`.

Assistant responses that contain images (rare today, but supported by some models) deserialize to the same `ALLM.ImagePart` shape. String content is still accepted for backward-compatibility and is treated as a single `ALLM.TextPart`.

### 35.7 Provider adapters in v0.3

**Bundled-adapter rule.** v0.3 bundles `ALLM.Providers.OpenAI.Images` and `ALLM.Providers.Gemini.Images`. Both implement `ALLM.ImageAdapter` against their provider's image-generation surface that **shares a translator with the same provider's chat surface** — OpenAI's `/v1/images/*` reuses prompt-text and base64 part shapes; Gemini-native image generation IS the chat surface (`generateContent` with `responseModalities`). Adapters covering wholly distinct image-only API surfaces — Imagen `:predict` (`imagen-4.0-*`), Stability, Replicate, fal.ai — are out of core and ship as separate Hex packages implementing the same `ALLM.ImageAdapter` behaviour. The principle is pragmatic, not architectural: in-tree adapters are the ones whose maintenance overlaps with their provider's already-bundled chat adapter.

Concrete consequence: a future `ALLM.Providers.Gemini.Imagen` (covering Imagen `:predict`) is structurally identical to a bundled adapter — same behaviour, same `Engine.image_adapter` plug-in — but ships as a separate package because its translator does not amortize with `Gemini`'s chat translator.

- **`ALLM.Providers.OpenAI.Images`** — wraps `/v1/images/generations`, `/v1/images/edits`, `/v1/images/variations`. Supports `dall-e-2`, `dall-e-3`, and `gpt-image-1`. `supported_operations/0` returns model-aware: `gpt-image-1` supports generate + edit; `dall-e-3` generate only; `dall-e-2` all three.
- **`ALLM.Providers.Gemini.Images`** (Phase 16.5) — wraps `generateContent` with `responseModalities: ["TEXT", "IMAGE"]`. Supports `gemini-3.1-flash-image-preview` and successors. `supported_operations/0` returns `[:generate, :edit]`; `:variation` is rejected as `:unsupported_operation`. The translator delegates to `ALLM.Providers.Gemini.to_gemini_request_body/2`.
- **No Anthropic image-generation adapter.** Anthropic does not offer image generation as of v0.3. The Anthropic chat adapter continues to accept `ALLM.ImagePart` inputs for vision.

Third-party image providers (Stability, Replicate, Google Imagen `:predict`, fal.ai) remain out of core per the bundled-adapter rule above.

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** The bundled-adapter rule gains a **second admission criterion**, scoped narrowly.
>
> As written above, the rule admits an adapter when its maintenance overlaps with the same provider's already-bundled chat adapter. That criterion was authored for image generation, where every candidate had a chat-adapter sibling. It does not decide the embeddings case for Anthropic, because **Anthropic ships no embeddings endpoint at all** and so has no sibling to amortize against — leaving the most common ALLM configuration with no in-tree embeddings path.
>
> The amended rule:
>
> > An adapter may be bundled when **either** (a) its maintenance overlaps with its provider's already-bundled chat adapter, **or** (b) it is the provider's own officially-recommended path for a capability that provider does not itself offer.
>
> Criterion (b) has exactly one beneficiary today: `ALLM.Providers.Voyage.Embeddings`, bundled because Anthropic publicly names Voyage AI as its recommended embeddings partner and publishes a cookbook for it. Its translator shares nothing with the Anthropic chat adapter, so (a) does not apply and the carve-out is what admits it.
>
> **This is a carve-out, not a widening.** Criterion (b) requires the *provider* to have made the recommendation — a third party being popular, or well-suited, or cheaper does not qualify. Cohere, Mistral, and Jina embeddings remain out of core and ship as separate packages implementing `ALLM.EmbeddingAdapter`, exactly as third-party image adapters do. See §36.7.

> **Phase 22 amendment (commits `cf8e340..5a73da6`; docs land in the 22.6 commit).** The rule takes a **second scoped carve-out**, this one about a family's *shape* rather than an individual adapter's admission.
>
> Criteria (a) and (b) each decide whether one adapter belongs in core. Neither decides what to do when a capability exists on **only one** bundled provider — the v0.3 and v0.5 families each had two or three, so the question never arose. Content moderation (§39) has exactly one: `ALLM.Providers.OpenAI.Moderation` qualifies under (a), and there is no candidate for the other two bundled providers under either criterion.
>
> The addition:
>
> > A capability family may be bundled with **exactly one** provider adapter when that provider is already bundled for chat, and the capability's absence on the other bundled providers is **documented rather than backfilled with a proxy**.
>
> Its one beneficiary today is the moderation family. Anthropic ships no moderation endpoint and names no partner for one, so criterion (b) has nothing to admit; Google exposes safety ratings inline on `generateContent` rather than as a standalone classification call, so there is no endpoint to implement `c:ALLM.ModerationAdapter.moderate/2` against. Both absences are documented in §39.7 and in `guides/moderation.md`.
>
> **This is a carve-out, not a widening**, on the same terms as the v0.5 one. It does not license shipping a one-provider family for a capability the other bundled providers *do* offer — that is a gap to be filled, not a shape to be documented. It licenses declining to invent a module for a provider that does not offer the capability at all, and it forbids satisfying the family's shape with a proxy (wrapping a chat call, or naming a third party after a provider that never recommended it). Third-party moderation providers remain out of core and ship as separate packages implementing `ALLM.ModerationAdapter`. See §39.7.

### 35.8 Testing

`ALLM.Providers.FakeImages` implements `ALLM.ImageAdapter` with scripted responses — analogous to `ALLM.Providers.Fake` (§31).

```elixir
engine =
  ALLM.Engine.new(
    image_adapter: ALLM.Providers.FakeImages,
    adapter_opts: [
      images: [
        %ALLM.Image{source: {:binary, <<137, 80, 78, 71, ...>>}, mime_type: "image/png"}
      ]
    ]
  )
```

Every call returns the scripted images in order; exhausting the script returns `{:error, :no_scripted_image}`. Deterministic, no network.

### 35.9 Telemetry

Two telemetry events, mirroring chat:

- `[:allm, :image, :start]` — measurements: `system_time`; metadata: `request_id`, `operation`, `model`, `n`.
- `[:allm, :image, :stop]` — measurements: `duration`, `image_count`; metadata: `request_id`, `operation`, `model`, `usage`, `error` (nil on success).

### 35.10 Out of scope for v0.3

- streaming image previews (provider-specific; expose via `options` if desired)
- image-to-video
- image classification / object detection as distinct primitives — users build these on top of chat + vision
- batch image endpoints (OpenAI batch API) — candidate for a later version
- OCR, upscaling, background removal as distinct primitives — out of core; third-party adapter territory

---

## 36. v0.5 — Text embeddings

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** This section is new. It supersedes the "embeddings" entries struck from §32.5 and §33, and it is the named beneficiary of the §35.7 bundled-adapter amendment.

v0.5 extends ALLM with a non-streaming primitive for turning text into vectors. Embeddings are request/response — there is no token stream — so the design stays parallel to the image capability (§35) and skips the streaming layer entirely. Embeddings are a *strictly simpler* instance of that pattern: no operations enum, no multipart bodies, no binary payloads.

The one place embeddings are harder than images is **batching**. The bundled providers cap a single request at 2048, 100, and 1000 inputs respectively, and bulk-loading a vector store routinely exceeds all three. That asymmetry is absorbed once, behind the façade (§36.6).

### 36.1 Design goals

1. **Parallel to the chat pipeline, not entangled with it.** Embedding requests, responses, and adapters are separate types. Chat adapters do not implement embedding support, and vice versa.
2. **Non-streaming.** No `ALLM.EmbeddingStreamAdapter` and no `stream_embed/3`. Same reasoning as §35.1 item 2.
3. **Opt-in per engine.** An `ALLM.Engine` without an `:embed_adapter` returns `{:error, %ALLM.Error.EngineError{reason: :no_embed_adapter}}` for embedding calls, ahead of every other gate. No implicit wiring, and no fallback to `:adapter` or `:image_adapter`.
4. **The output is plain data.** `ALLM.EmbeddingResponse.vectors/1` returns `[[float()]]`, ready for a `vector(N)` column. ALLM depends on no storage library and ships no repo or migration helpers; the vector store is the caller's.
5. **Reuse engine plumbing.** Keys (§6.4), model resolution and capability pre-flight (§6.3), retries, telemetry (§29), and deterministic fakes (§31) apply identically to embedding calls.

### 36.2 Data model

#### 36.2.1 `ALLM.Embedding`

One vector, plus the index that ties it back to its input.

```elixir
defmodule ALLM.Embedding do
  @enforce_keys [:vector]
  defstruct [:vector, index: 0, metadata: %{}]

  @type t :: %__MODULE__{
          vector: [float()],
          index: non_neg_integer(),
          metadata: map()
        }

  @spec new(keyword()) :: t()

  @spec normalize(t()) :: t()      # L2; returns the input unchanged at magnitude 0.0
  @spec magnitude(t()) :: float()  # Euclidean norm
end
```

`:index` is **always** an integer, never `nil` — batch chunking (§36.6) rebases indices across chunk boundaries, and a sometimes-`nil` field would make that arithmetic conditional and the sort in `vectors/1` unstable.

An adapter that would construct `%Embedding{vector: []}` from a provider response returns `%ALLM.Error.EmbeddingAdapterError{reason: :malformed_response}` instead.

#### 36.2.2 `ALLM.EmbeddingRequest`

```elixir
defmodule ALLM.EmbeddingRequest do
  @type task_type ::
          :search_document | :search_query | :classification | :clustering | :similarity

  @type t :: %__MODULE__{
          input: [String.t()],
          model: String.t() | nil,
          dimensions: pos_integer() | nil,
          task_type: task_type() | nil,
          truncate: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :dimensions,
    :task_type,
    input: [],
    truncate: true,
    options: %{},
    metadata: %{}
  ]
end
```

- `:input` is **always a list on the struct**. The bare-string call shape is normalized at `ALLM.embedding_request/2`, so no adapter or validator handles a union.
- `:task_type` is a provider-neutral closed enum for asymmetric embedding — encoding a search query differently from the documents it searches. Providers that lack an equivalent **drop the field** rather than erroring (see §36.7), matching the contract images set for `response_format` on `gpt-image-1`.
- `:truncate` defaults to `true`, the provider-side default on every bundled target, so the field is omitted from the wire when `true` and sent explicitly only when `false`.
- `:options` is the documented home for provider-specific opaque knobs (OpenAI's request-level `user`, for one).

Validation lives in `ALLM.Validate.embedding_request/1` (analogous to §16), and unlike `generate_image/3` the façade calls it — an empty-string input is a guaranteed provider rejection, and in a chunked call it should fail before the other forty-nine round-trips are spent.

#### 36.2.3 `ALLM.EmbeddingResponse`

```elixir
defmodule ALLM.EmbeddingResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          embeddings: [ALLM.Embedding.t()],
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [:id, :request_id, :model, :raw, embeddings: [], usage: %ALLM.Usage{}, metadata: %{}]

  @spec vectors(t()) :: [[float()]]                       # sorted by :index, flattened
  @spec dimensions(t()) :: non_neg_integer() | nil        # width of the first vector
end
```

Three invariants:

- **Order correspondence.** `Enum.at(vectors(response), i)` is the embedding of `Enum.at(request.input, i)` for every `i` — preserved across chunk merges by the rebasing in §36.6 and by `vectors/1` sorting on `:index` before flattening. Providers document an index field precisely because array order is not contractual.
- **Uniform dimensionality.** Every vector in `:embeddings` has the same length.
- **Cardinality.** `length(response.embeddings) == length(request.input)` on success.

`:usage` defaults to `%ALLM.Usage{}` and is never `nil`. **`ALLM.Usage` is reused rather than given an embeddings-specific twin**: embeddings bill in tokens, which `Usage` already models, and every one of its numeric fields is already documented as optional and `nil`-able. `:output_tokens` is always `nil` — embeddings produce no completion tokens — and which of the remaining counters a provider populates varies (§36.7).

#### 36.2.4 `ALLM.Error.EmbeddingAdapterError`

Same shape as `ALLM.Error.ImageAdapterError`: a closed reason enum, a `new/2` that raises `ArgumentError` on an unlisted atom, a `legal_reasons/0` accessor, and a `defexception` with a `message/1` catch-all.

```elixir
@type reason ::
        :authentication_failed
      | :rate_limited
      | :invalid_request
      | :context_length_exceeded
      | :provider_unavailable
      | :timeout
      | :network_error
      | :malformed_response
      | :unsupported_feature
      | :batch_too_large
      | :unknown
```

Eleven atoms. Against `ImageAdapterError`'s twelve: `−:content_filter`, `−:unsupported_operation` (no operations enum here), `+:batch_too_large`.

`ALLM.Error.EngineError` gains `:no_embed_adapter` and `ALLM.Error.ValidationError` gains `:invalid_embedding_request`.

### 36.3 `ALLM.EmbeddingAdapter` behaviour

```elixir
defmodule ALLM.EmbeddingAdapter do
  @callback embed(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, ALLM.EmbeddingResponse.t()}
              | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @callback max_batch_size() :: pos_integer()

  @callback prepare_request(ALLM.EmbeddingRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.EmbeddingAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
```

- `embed/2` is `ALLM.embed/3`'s dispatch target, and is synchronous — it returns only after the HTTP response is read in full.
- `max_batch_size/0` is read by the batching layer **and** by callers doing their own chunking. It is per-module and constant, not per-model; per-model limits are the adapter's internal concern.
- `prepare_request/2` is the low-level escape hatch (same role as §7.1), returning an unfired `Req.Request` configured exactly as `embed/2` would fire it.

There is no `EmbeddingStreamAdapter` — streaming is deliberately out of scope.

**Contract invariants.** 1–6 are asserted by the conformance suite (§36.8); 7 is documentary in v0.5 — the conformance case that would bind it (assert `Jason.encode!/1` of an error contains no substring of the `opts[:api_key]` handed in) is filed as a ticket, not shipped.

1. `embed/2` never raises for HTTP-shaped failures. Network failures, 4xx, and 5xx all convert to `{:error, %EmbeddingAdapterError{}}`. The one sanctioned exception is `ALLM.Keys.fetch!/2`, which raises `%EngineError{reason: :missing_key}` by documented design (§6.4) and is not rescued.
2. `embed/2` honors `opts[:request_timeout]`, producing `reason: :timeout`.
3. `length(input) > max_batch_size()` returns `reason: :batch_too_large` with `metadata: %{count:, max:}` **before key resolution** — not merely before HTTP I/O, so the gate is exercisable in a keyless environment.
4. `input: []` returns `reason: :invalid_request`, likewise before key resolution.
5. `opts[:request_id]` is preserved onto `response.request_id`; `request.metadata` round-trips onto `response.metadata` unchanged.
6. On success, exactly `length(request.input)` embeddings come back with `:index` values `0..length-1` and a uniform, non-zero vector width.
7. **Error-struct hygiene.** `%EmbeddingAdapterError{}` derives `Jason.Encoder` and is commonly logged and persisted, so no raw response body, no request header, and no `Authorization` / `x-api-key` / `x-goog-api-key` value ever reaches `:message`, `:cause`, or `:metadata`. Provider messages that may echo the offending credential (OpenAI's 401 text is the known case) are passed through a key-shaped-token redactor first; a decode failure's captured payload is blanked rather than attached; and `:malformed_response` metadata carries the body's sorted top-level key list, not a body excerpt. All three bundled adapters carry this as an `## Error-struct hygiene` moduledoc section — it is stated here because §36.3 is the contract a third-party adapter author implements against, and the obligation is invisible from the callback signatures alone.

There is no cleanup invariant: there is no `Stream.resource/3` and no Finch reference, because `Req.request/1` owns its own connection lifecycle. Stated so the absence reads as intent.

### 36.4 Engine integration

`ALLM.Engine.t()` gains one field:

```elixir
embed_adapter: module() | nil
```

It is a **peer** to `:adapter` and `:image_adapter`, never a fallback for either. A single engine may combine three providers, since the adapters are independent:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,                # chat
    image_adapter: ALLM.Providers.OpenAI.Images,      # images
    embed_adapter: ALLM.Providers.Voyage.Embeddings,  # embeddings
    model: "claude-sonnet-4-6"
  )
```

Key resolution (§6.4) uses each adapter's own provider key namespace, so mixing providers requires each provider's key to be resolvable. Engines remain free of key material and safe to serialize.

### 36.5 Public API

```elixir
defmodule ALLM do
  @spec embedding_request(String.t() | [String.t()], keyword()) :: ALLM.EmbeddingRequest.t()

  @spec embed(
          ALLM.Engine.t(),
          String.t() | [String.t()] | ALLM.EmbeddingRequest.t(),
          keyword()
        ) ::
          {:ok, ALLM.EmbeddingResponse.t()}
          | {:error,
             ALLM.Error.EngineError.t()
             | ALLM.Error.ValidationError.t()
             | ALLM.Error.EmbeddingAdapterError.t()}
end
```

`embed/3` accepts a bare string (sugar for a one-element batch), a list of strings, or a fully constructed `%ALLM.EmbeddingRequest{}` (dispatched verbatim; opts are not merged onto it). For the first two shapes, opts named after `EmbeddingRequest` fields lift onto the built request and everything else is treated as a call-control opt.

Example:

```elixir
engine =
  ALLM.Engine.new(
    embed_adapter: ALLM.Providers.OpenAI.Embeddings,
    model: "text-embedding-3-small"
  )

{:ok, response} = ALLM.embed(engine, chunks, task_type: :search_document)

vectors = ALLM.EmbeddingResponse.vectors(response)   # [[float()]], input order
width   = ALLM.EmbeddingResponse.dimensions(response) # size the vector(N) column
```

Dispatch order is fixed, and the ordering is load-bearing:

1. adapter-presence gate (`:no_embed_adapter`) — first, so a misconfigured engine never surfaces as a request problem;
2. `ALLM.Validate.embedding_request/1` (`:invalid_embedding_request`);
3. `ALLM.Capability.preflight_embedding/2` (`:unsupported_capability`) — a no-op without a model catalog, per §6.3;
4. model stamping, adapter-opt merge, then batching and dispatch.

There is deliberately **no Layer D**. Embeddings carry no conversation state, so `ALLM.Session` is untouched.

### 36.6 Batching and normalization

#### Batching

The façade chunks; **adapters never see more than `max_batch_size/0` inputs**. One implementation serves every adapter, adapters stay thin, and retry plus telemetry wrap each chunk — which is what a rate-limited provider wants. A caller who wants per-request control keeps it: `max_batch_size/0` is public, and `:batch_too_large` still fires for direct adapter calls.

Chunks dispatch **sequentially**, not in parallel. Firing fifty chunks concurrently is the fastest route to a rate-limit storm, and the retry layer would serialize them anyway with backoff attached. Sequential dispatch is also the backpressure mechanism: at most one in-flight request per call.

Merge semantics:

| Field | Rule |
|---|---|
| `:embeddings` | concatenated with indices rebased by chunk offset, then sorted by `:index` |
| `:usage` | every numeric field summed across chunks, skipping `nil`; the result is `nil` only if every chunk was `nil`. Map fields merge with the earlier chunk winning. No field is dropped, so usage does not depend on how many chunks the call became |
| `:model`, `:id`, `:request_id` | first non-`nil` |
| `:raw` | the first chunk's only |
| `:metadata` | the first chunk's, plus `:chunk_count` |

A single-chunk call skips the merge entirely, so `:raw` survives intact for the common case.

**Budgets are per chunk, and there is no total deadline.** Retry attempts, `opts[:request_timeout]`, and backoff each apply per chunk, so a fifty-chunk ingest's worst case is fifty times each — 150 HTTP requests at the default three attempts, and an unbounded wall clock under sustained rate limiting. **`:timeout` is the exception and costs 3×:** each adapter runs its own `ALLM.Retry.run/3` with the default policy and `ALLM.embed/3` wraps a second, widened one, and `:timeout` is the only reason present in *both* `retry_on` lists, so the budgets multiply to 9 attempts per chunk (450 requests for the fifty-chunk case) against 3 for `:rate_limited` / `:provider_unavailable` / `:network_error`, which only the outer loop retries. A direct adapter `embed/2` call takes the inner loop only and makes 3. This is a pre-existing library-wide characteristic shared with `ALLM.generate_image/3` rather than an embeddings one — it is tracked as a ticket and must be corrected in the façade and both image adapters at once, not per-adapter. The `[:allm, :embed]` span reports one `duration` for all of it. No aggregate-attempt or deadline option is introduced in v0.5: the escape hatch already exists, since a caller who chunks against `max_batch_size/0` gets per-call control of both budgets for free — the same loop resumability needs. The obligation this creates is documentary, and `@doc ALLM.embed/3` carries the budget table.

**A mid-batch failure fails the whole call.** No partial vectors are returned; the error is the failing chunk's own, with `metadata.completed_chunks` and `metadata.completed_inputs` merged in for diagnostics. An `{:ok, response, error}` triple or a partially-filled response would overload the return shape. Callers needing resumability chunk themselves.

#### Normalization

`ALLM.Embedding.normalize/1` is L2 normalization, idempotent to within `1.0e-9`, and returns a zero-magnitude vector unchanged rather than producing `NaN`.

**`ALLM.Providers.Gemini.Embeddings` normalizes in-adapter whenever `:dimensions` is set to anything other than the single constant `3072` — unconditionally across models, by design.** The predicate is `@pre_normalized_dimensions 3072`, `gemini-embedding-001`'s native width, and it is a constant rather than a per-model lookup: the adapter does not know any model's native width, so a future Gemini embedding model with a different native width would be normalized *at* its own native width too. Google returns pre-normalized vectors at `gemini-embedding-001`'s native dimensionality but not at truncated ones (a recorded 768-wide response measures ≈ 0.585), while newer models auto-normalize truncated output too. The rule does not branch on model id: re-normalizing an already-unit vector is a no-op, so the unconditional form is safe on the models that self-normalize, correct on the ones that do not, and does not go stale when the next model ships — where a hard-coded allow-list would silently mis-handle it.

The visible consequence, called out in the adapter's `@moduledoc` and in `guides/embeddings.md`: **a `dimensions: 768` response from ALLM differs numerically from the same request issued with `curl`.** That is the intended trade. A vector table holding a mix of normalized and unnormalized rows is unrecoverable after the fact — cosine distance tolerates unnormalized input, but inner-product operators silently return wrong rankings and nothing in the data says which rows are which.

### 36.7 Provider adapters in v0.5

v0.5 bundles three embedding adapters. `ALLM.Providers.OpenAI.Embeddings` and `ALLM.Providers.Gemini.Embeddings` qualify under §35.7 criterion (a) — each shares key resolution, header construction, and error-envelope handling with its provider's already-bundled chat adapter. `ALLM.Providers.Voyage.Embeddings` qualifies under criterion (b), the amendment this phase added: Anthropic ships no embeddings endpoint and names Voyage AI as its recommended partner.

There is deliberately **no `ALLM.Providers.Anthropic.Embeddings`**. That name would assert a wire that does not exist, and the key resolves from `VOYAGE_API_KEY`, not `ANTHROPIC_API_KEY`.

| | OpenAI | Gemini | Voyage |
|---|---|---|---|
| Endpoint | `POST /v1/embeddings` | `POST {base}/models/<model>:batchEmbedContents` | `POST /v1/embeddings` |
| Base URL overridable | no | yes, via `adapter_opts[:endpoint]` | no |
| Auth | `authorization: Bearer` | `x-goog-api-key` header | `authorization: Bearer` |
| Key atom / env var | `:openai` / `OPENAI_API_KEY` | `:gemini` / `GEMINI_API_KEY` | `:voyage` / `VOYAGE_API_KEY` |
| Model field | top-level `model` | **required on every sub-request**, `models/`-prefixed | top-level `model` |
| Dimensions field | `dimensions` | `outputDimensionality` | `output_dimension` (snake_case) |
| Task-type field | **none** — dropped | `taskType`, all five mapped | `input_type`, query/document only |
| Truncate field | **none** — over-length is a 400 | `embedContentConfig.autoTruncate`, per sub-request | `truncation` |
| Vector path | `data[].embedding` | `embeddings[].values` | `data[].embedding` |
| Index | `data[].index` | **none** — positional | `data[].index` |
| `max_batch_size/0` | 2048 | 100 | 1000 |
| `ALLM.Usage` populated | `input_tokens` + `total_tokens` | **nothing** | `total_tokens` only |
| Error envelope | `{"error": {message, type, code}}` | `{"error": {code, message, status}}` | `{"detail": "<string>"}` |

Four provider behaviours are worth stating in the spec because each falsified an assumption during implementation and each is invisible from the type signatures:

1. **Gemini returns no usage metadata at all.** A live `batchEmbedContents` 200 carries exactly `{"embeddings": [{"values": […]}, …]}`. `response.usage` is therefore an all-`nil` `%ALLM.Usage{}` on that provider; the decoder reads the field defensively and will populate automatically if Google starts reporting it.
2. **Voyage reports `usage.total_tokens` only**, with no `prompt_tokens` sibling, so `input_tokens` is `nil` there.
3. **OpenAI's per-request token cap is separate from its item cap.** 2048 array items, but also 300,000 tokens summed across a single request — reachable well below 2048 inputs. A 400 carrying the token-budget marker maps to `:context_length_exceeded`, and the marker rides on the envelope's `type`, not its `code`.
4. **OpenAI rejects `dimensions` on `text-embedding-ada-002`** pre-flight, as `:unsupported_feature` with `metadata: %{feature: :dimensions, model: model}` — a request the adapter can see is malformed without spending a round-trip.

Voyage's `:task_type` mapping is **lossy and documented as such**: `:search_document → "document"`, `:search_query → "query"`, and `:classification` / `:clustering` / `:similarity` omit the field entirely, which is Voyage's documented behaviour for symmetric tasks. A dropped task type is never an error on any provider.

Third-party embedding providers (Cohere, Mistral, Jina, and local models per §32) remain out of core and ship as separate packages implementing `ALLM.EmbeddingAdapter`.

### 36.8 Testing

`ALLM.Providers.FakeEmbeddings` implements `ALLM.EmbeddingAdapter` with scripted responses — analogous to `ALLM.Providers.Fake` (§31) and `ALLM.Providers.FakeImages` (§35.8). It ships in `lib/`, not `test/support/`, because downstream applications need it for their own tests.

```elixir
engine =
  ALLM.Engine.new(
    embed_adapter: ALLM.Providers.FakeEmbeddings,
    adapter_opts: [
      embedding_script: [
        {:ok, [%ALLM.Embedding{vector: [0.1, 0.2], index: 0}]},
        {:error, %ALLM.Error.EmbeddingAdapterError{reason: :invalid_request}},
        {:retry_until_call, 3}
      ]
    ]
  )
```

Each call advances a cursor keyed on engine identity, so `async: true` is safe and two engines built with content-equal scripts each start at index 0. `{:retry_until_call, n}` returns a synthetic retryable error for the first `n - 1` calls against that entry, which is the vehicle for exercising retry integration. Exhausting the script returns `reason: :unknown` with `cause: :no_scripted_embedding`.

`ALLM.Test.EmbeddingAdapterConformance` ships in the `allm_conformance` package with **ten cases**, covering `max_batch_size/0`'s shape, the two pre-flight gates, cardinality, index range, uniform width, `request_id` and `metadata` plumbing, and `usage` never being `nil`. Third-party adapter authors add the package as a test-only dep and `use` the suite.

One limitation is binding on anyone reading a green conformance run: the suite drives a real adapter through a script short-circuit that returns the scripted embeddings verbatim, so **the adapter's own response decoder is never reached on the success path**. For a delegating adapter the cardinality, index, and uniformity cases assert that the harness's script round-trips, not that the decoder indexes correctly. Each bundled adapter therefore carries its own decoder tests against recorded wire fixtures. The cases bind fully for an adapter that implements `embed/2` itself, which is the third-party author the published suite exists to serve.

### 36.9 Telemetry

Three events, mirroring the image span (§35.9):

- `[:allm, :embed, :start]` — measurements: `system_time`; metadata: `request_id`, `engine`, `model`, `input_count`.
- `[:allm, :embed, :stop]` — measurements: `duration`, `embedding_count`, `chunk_count`; metadata: `request_id`, `model`, `usage`, `response`, `error` (`nil` on success).
- `[:allm, :embed, :exception]` — measurements: `duration`; metadata: `kind`, `reason`, `stacktrace`. Emitted **instead of** `:stop` and then re-raised, via `:telemetry.span/3`. Two paths reach it: `ALLM.Keys.fetch!/2`'s `%EngineError{reason: :missing_key}` (§6.4) and the `ArgumentError` a non-conforming `:embed_adapter` triggers in `ALLM.EmbeddingBatch`. `ALLM.Telemetry` already registers the triple; the event is named here so `guides/embeddings.md` can tell a handler author that a `:start`/`:stop`-only attachment leaves an unterminated span on every missing key.

`embedding_count` and `chunk_count` are present on **both** `:stop` paths, reporting `0` on error, so the measurement key set is stable for a metrics backend and a handler written against the `:image` span does not `KeyError` here. `chunk_count` is the observability payoff for §36.6 — the only signal that one `ALLM.embed/3` call became fifty HTTP requests.

**Operator note.** The `:stop` metadata carries `response:`, which means it carries the full vectors. Embedding vectors are partially invertible to their source text, so a handler that serializes the whole metadata map to an external backend exports a lossy encoding of the corpus to that vendor. This is established precedent rather than new exposure — the `:image` span has carried `response:` with image bytes since v0.3 — and it requires explicit operator opt-in, so it is a documentation obligation and `guides/embeddings.md` carries it. The embedded *text* is never emitted: `:start` and the retry-path metadata carry only `input_count`, a bare count.

### 36.10 Out of scope for v0.5

- **streaming** — embeddings are request/response; there is no `stream_embed/3` and no relaxation budget for a stream-equivalence property, because no streaming counterpart exists
- **multimodal / image embeddings** — different endpoint, different input union; a separate capability
- **`encoding_format: "base64"`** — not provider-neutral (Gemini's batch endpoint has no base64 form) and it changes no Layer A value; revisit only if profiling shows JSON float parsing dominating bulk ingest
- **quantized output (`int8`, `binary`)** — needs a `vector` vs `halfvec` vs `bit` decision that belongs to the caller's schema
- **reranking** (`/rerank` on Voyage and Cohere) — a different primitive returning scores, not vectors
- **token counting / pre-truncation** — requires a tokenizer per provider; the provider-side `truncate` default covers the common case
- **vector-store integration code** — ALLM returns `[[float()]]` and depends on no storage library; the `pgvector` recipe is documented in `guides/embeddings.md`, not shipped as code
- **`ALLM.Session` integration** — embeddings carry no conversation state
- **parallel chunk dispatch** — sequential is the safe default under provider rate limits (§36.6)
- **multi-vector / late-interaction models** — the provider matrix does not support it

---

## 39. v0.6 — Content moderation

> **Phase 22 amendment (commits `cf8e340..5a73da6`; docs land in the 22.6 commit).** This section is new. It amends §27 (module tree), §29 (telemetry), and §35.7 (bundled-adapter rule — a second scoped beneficiary). §32.5 and §33 are untouched: neither list named moderation, so there is nothing to strike.

v0.6 extends ALLM with a non-streaming primitive for screening content against a provider's safety policy — before a chat call is spent on it, or before model output is published. Moderation is request/response, so the design stays parallel to images (§35) and embeddings (§36) and skips the streaming layer entirely.

ALLM already models the *reactive* half of this problem as first-class data: `:content_filter` is an `ALLM.Response` finish reason and an `AdapterError` reason mapped from provider signals. That is post-hoc, after the generation is paid for. §39 adds the proactive half.

Against embeddings, moderation drops batching, drops usage, drops cost population, and drops two of the three provider adapters. Against images it drops multipart bodies, binary payloads, and the operations enum. What it adds that neither has is a **result type whose per-category map is deliberately not normalized** (§39.2.2) and an **input union whose cardinality is type-dependent** (§39.2.1) — the two places a reviewer should look hardest.

**Why a classification primitive is admitted where object detection is not.** §35.10 places *"image classification / object detection as distinct primitives — users build these on top of chat + vision"* out of scope. Moderation is a classification primitive and is nonetheless admitted, on two grounds that do not generalize to the excluded cases: it has a **dedicated, free, single-call endpoint** that no amount of chat + vision composition reproduces (composition would cost a generation call, return prose rather than a score map, and have no provider policy behind its verdict), and it is the gate a safety-conscious application runs *before* the chat call that such a composition would be built on. The §35.10 line stands unamended for object detection, OCR, and upscaling.

### 39.1 Design goals

1. **Parallel to the chat pipeline, not entangled with it.** Moderation requests, responses, and adapters are separate types. Chat adapters do not implement moderation support, and vice versa. There is no automatic moderation inside `chat/3` or `generate/3`: a hidden second HTTP call per turn would double latency and silently change `chat/3`'s error union. Screening is a caller-side two-liner, or a telemetry-handler concern (§29).
2. **Non-streaming.** No `ALLM.ModerationStreamAdapter` and no `stream_moderate/3`. Same reasoning as §35.1 item 2 and §36.1 item 2. A `stream: true` opt is silently ignored rather than erroring.
3. **Opt-in per engine.** An `ALLM.Engine` without a `:moderation_adapter` returns `{:error, %ALLM.Error.EngineError{reason: :no_moderation_adapter}}` for moderation calls, ahead of every other gate. No implicit wiring, and no fallback to `:adapter`, `:image_adapter`, or `:embed_adapter`.
4. **The library does not decide what "unsafe" means.** ALLM returns the provider's `flagged` boolean and the provider's per-category scores. It ships no default threshold, no policy DSL, and no `block?/2`. A moderation threshold is a product decision that varies by jurisdiction, audience, and appetite; a library default would be quietly wrong for most callers and would be read as an endorsement.
5. **Reuse engine plumbing.** Keys (§6.4), model resolution and capability pre-flight (§6.3), retries, telemetry (§29), and deterministic fakes (§31) apply identically to moderation calls.

### 39.2 Data model

#### 39.2.1 `ALLM.ModerationRequest`

```elixir
defmodule ALLM.ModerationRequest do
  @type item :: String.t() | ALLM.ImagePart.t()

  @type t :: %__MODULE__{
          input: [item()],
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:model, input: [], options: %{}, metadata: %{}]

  @spec new(keyword()) :: t()
  @spec multimodal?(t()) :: boolean()   # true iff any element is an %ALLM.ImagePart{}
end
```

- `:input` is **always a list on the struct**. The bare-string call shape is normalized at `ALLM.moderation_request/2`, so no adapter or validator handles a union.
- `:options` is the documented home for provider-specific opaque knobs.

**Cardinality is type-dependent, and this is the one normative surprise in the section.** It is a property of the provider endpoint, not an ALLM choice:

- **All-strings `:input`** — a batch of `length(input)` independent items. `length(response.results) == length(request.input)`, and `Enum.at(results, i)` is the verdict for `Enum.at(input, i)`.
- **Any `ALLM.ImagePart` present** — the whole `:input` list is **one** multimodal item (text plus its images, judged together), so there is exactly **one** result, at `index: 0`, however long the list is.

`multimodal?/1` reports which shape a request is in, so the count is derivable *before* the call. The rule is stated normatively on `@moduledoc ALLM.ModerationRequest`; every other site cites it. Two consequences follow directly:

1. the caller-side chunking loop of §39.6 applies to an all-strings `:input` **only** — splitting a multimodal list would sever an image from the text it belongs to;
2. an adapter's `max_batch_size/0` gate measures the **item** count, which is `1` for any multimodal request, not `length(request.input)`.

Validation lives in `ALLM.Validate.moderation_request/1`, and — like `embed/3`, unlike `generate_image/3` — the façade calls it. An empty `:input` list and an empty-string item are both guaranteed provider rejections and should fail before the round-trip.

#### 39.2.2 `ALLM.ModerationResult`

One verdict, plus the index that ties it back to its input.

```elixir
defmodule ALLM.ModerationResult do
  @type t :: %__MODULE__{
          flagged: boolean(),
          categories: %{String.t() => boolean()},
          category_scores: %{String.t() => float()},
          applied_input_types: %{String.t() => [String.t()]},
          index: non_neg_integer(),
          metadata: map()
        }

  @enforce_keys [:flagged]
  defstruct [:flagged, categories: %{}, category_scores: %{},
             applied_input_types: %{}, index: 0, metadata: %{}]

  @spec new(keyword()) :: t()
  @spec flagged_categories(t()) :: [String.t()]   # sorted names whose :categories value is true
  @spec score(t(), String.t()) :: float() | nil   # nil for a category the provider did not report
end
```

**Only `:flagged` is normalized. `:categories` and `:category_scores` are provider-shaped and string-keyed**, passed through as identity by `__from_tagged__/1` — no decode hook, no safelist, no drift when the provider adds a category. Three arguments against a normalized atom taxonomy, each independently sufficient:

1. **Atom-table growth.** A provider-controlled key set converted with `String.to_atom/1` grows the atom table on whatever the provider ships next; `String.to_existing_atom/1` would instead *drop* new categories silently, which is worse.
2. **There is nothing to normalize against.** A cross-provider taxonomy needs a second provider, and moderation is a single-provider capability (§39.7). A taxonomy invented against one provider's thirteen categories is that provider's taxonomy wearing a neutral name.
3. **The plausible second provider reports a different shape entirely.** Google's safety ratings are four harm categories on an ordinal `NEGLIGIBLE | LOW | MEDIUM | HIGH` enum attached to a generation call — not a float map, and not a standalone classification (§39.7).

The cost is stated plainly in the public docs: reading `scores["violence"]` is writing provider-specific code and the compiler will not catch a typo. `score/2` exists so the miss is a `nil` rather than a raise.

`:index` is **always** a `non_neg_integer()`, never `nil` — mirroring `ALLM.Embedding.index` (§36.2.1) and preserving `Enum.at(response.results, i) ↔ Enum.at(request.input, i)` for the all-strings shape. In the multimodal shape there is exactly one result and its index is `0`.

`:applied_input_types` reports, per category, which parts of a multimodal input triggered it (`%{"violence" => ["image"]}`). It is `%{}` when the provider does not report it — an empty map is the honest representation of "not reported", never of "nothing applied". It is the only observable distinguishing "the image was classified and found clean" from "the image was ignored".

**The `:flagged` decoder repairs rather than passes through, and it is the only one in the family that does.** On the JSON decode path (`ALLM.Serializer.from_json/1`) a `"flagged"` that is not a boolean — absent, `null`, the string `"true"`, a truncated or tampered payload — deserializes to `false`. The declared `t:boolean/0` is preserved rather than admitting a `nil`, and a decode glitch cannot manufacture a `true` that blocks legitimate content. Two consequences are stated in the public docs because both invert a reflex carried over from §36: a corrupted persisted verdict deserializes to *clean* rather than to a decode error (the honest signal being that `:categories` and `:category_scores` come back empty alongside it), and ETF and JSON round-trips are therefore **not** interchangeable for an off-contract `flagged: nil`.

#### 39.2.3 `ALLM.ModerationResponse`

```elixir
defmodule ALLM.ModerationResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          results: [ALLM.ModerationResult.t()],
          raw: term(),
          metadata: map()
        }

  defstruct [:id, :request_id, :model, :provider, :raw, results: [], metadata: %{}]

  @spec flagged?(t()) :: boolean()                 # true iff ANY result is flagged
  @spec flagged_categories(t()) :: [String.t()]    # sorted union across flagged results
end
```

**There is no `:usage` field, and its absence is deliberate rather than an omission.** The endpoint is free and returns no usage object, so a field that is structurally always empty would be a promise the capability cannot keep. This diverges from `ALLM.EmbeddingResponse` and `ALLM.ImageResponse`, both of which carry one.

The telemetry span nonetheless carries `usage: nil` unconditionally (§39.9) — a stable metadata key set across capability spans is what a metrics backend wants, and a handler written against `[:allm, :embed, :stop]` must not `KeyError` when pointed at `[:allm, :moderate, :stop]`. The struct and the span therefore disagree on purpose; the reasoning is recorded on both.

`flagged?/1` is the 95%-case accessor: one call answers "did anything here trip the provider's policy". `flagged_categories/1` is the sorted union across every flagged result, so "which policies" needs no list walk.

#### 39.2.4 `ALLM.Error.ModerationAdapterError`

Same shape as `ALLM.Error.EmbeddingAdapterError` (§36.2.4): a closed reason enum, a `new/2` that raises `ArgumentError` on an unlisted atom, a `legal_reasons/0` accessor, and a `defexception` with a `message/1` catch-all.

```elixir
@type reason ::
        :authentication_failed
      | :rate_limited
      | :invalid_request
      | :context_length_exceeded
      | :provider_unavailable
      | :timeout
      | :network_error
      | :malformed_response
      | :unsupported_feature
      | :batch_too_large
      | :unknown
```

Eleven atoms — the same eleven as `EmbeddingAdapterError`. `ALLM.Error.EngineError` gains `:no_moderation_adapter` and `ALLM.Error.ValidationError` gains `:invalid_moderation_request`. Both are closed enums, so an exhaustive `case` over either union needs a new clause.

**`moderate/2` returns only `ModerationAdapterError`, never `ValidationError`.** This matches `c:ALLM.ImageAdapter.generate/2` and `c:ALLM.EmbeddingAdapter.embed/2`, and deliberately does not copy `ALLM.Providers.OpenAI.generate/2`, whose concrete `@spec` widens beyond its own `@callback` to surface MIME validation. An adapter's image gate therefore converts MIME, byte-size, and resolvability failures into `%ModerationAdapterError{reason: :invalid_request}` with the detail on `:metadata`, rather than widening the union.

### 39.3 `ALLM.ModerationAdapter` behaviour

```elixir
defmodule ALLM.ModerationAdapter do
  @callback moderate(ALLM.ModerationRequest.t(), keyword()) ::
              {:ok, ALLM.ModerationResponse.t()}
              | {:error, ALLM.Error.ModerationAdapterError.t()}

  @callback max_batch_size() :: pos_integer()

  @callback prepare_request(ALLM.ModerationRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ModerationAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
```

- `moderate/2` is `ALLM.moderate/3`'s dispatch target, and is synchronous — it returns only after the HTTP response is read in full.
- `max_batch_size/0` is read by callers doing their own chunking, and gates direct adapter calls. It is per-module and constant, not per-model. Unlike §36 there is **no** batching layer reading it: the façade does not chunk (§39.6).
- `prepare_request/2` is the low-level escape hatch (same role as §7.1 and §36.3), returning an unfired `Req.Request` configured exactly as `moderate/2` would fire it.

There is no `ModerationStreamAdapter` — streaming is deliberately out of scope.

**Contract invariants.** The numbering below is normative and matches `@moduledoc ALLM.ModerationAdapter` exactly, because conformance case names and forward-binding notes cite these by number. Invariants **1–8 are frozen**; 9 and 10 were *appended* rather than slotted in, and anything further appends at 11.

1. `max_batch_size/0` returns a `pos_integer()` and is per-module — one number for the adapter, not per-call-with-model-argument. Per-model limits are the adapter's internal concern.
2. `moderate/2` returns exactly `{:ok, %ModerationResponse{}}` or `{:error, %ModerationAdapterError{}}` — never a bare struct, never a three-tuple. Network failures, 4xx, and 5xx all convert to the error tuple. The one sanctioned exception is `ALLM.Keys.fetch!/2`, which raises `%EngineError{reason: :missing_key}` by documented design (§6.4) and is not rescued. **Enforced, not merely documented:** `ALLM.moderate/3` raises `ArgumentError` naming the adapter and this invariant on any other shape. The conformance suite cannot observe this — the enforcement lives at the façade, not inside any adapter — so a green conformance run is not evidence that every failure shape has been converted.
3. Result cardinality follows §39.2.1's normative rule: `length(request.input)` results for an all-strings `:input`; exactly **one** result when any `%ALLM.ImagePart{}` is present.
4. `:index` values on the returned results are exactly `0..length(results)-1`.
5. An **item count** exceeding `max_batch_size()` returns `reason: :batch_too_large` with `metadata: %{count:, max:}`, before any I/O and — for an adapter that resolves credentials — **before** `ALLM.Keys.fetch!/2`, so a keyless environment observes the rejection rather than a missing-key raise. The item count is the one invariant 3 defines, **not** the raw list length: it is `1` for any multimodal request, so a multimodal request never trips this gate. That is what keeps the published suite correct for an adapter whose cap is `1`.
6. `input: []` returns `reason: :invalid_request`, under the same before-I/O and before-key ordering. The bar holds at the adapter for direct callers even though the façade also validates.
7. `opts[:request_id]` is preserved onto `response.request_id` when supplied. When absent, the adapter may populate it from a provider-supplied correlation id.
8. `request.metadata` round-trips onto `response.metadata` unchanged — the library treats request/response metadata as opaque.
9. `moderate/2` honours `opts[:request_timeout]`, producing `reason: :timeout`. Without this obligation nothing in a conforming adapter would ever emit `:timeout` and the façade's retry policy would cover a reason no implementation produces.
10. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `moderate/2` would fire it, and is defined only for a request whose item count is `<= max_batch_size()`. Callers may mutate the returned request before firing.

**Error-struct hygiene** is an obligation on adapter authors that carries no invariant number, because the numbering was frozen before it was stated. It is not optional. `%ModerationAdapterError{}` derives `Jason.Encoder` and is commonly logged and persisted, so no raw response body, no request header, and no `Authorization` value may reach `:message`, `:cause`, or `:metadata`. Provider messages that may echo the offending credential are passed through a key-shaped-token redactor at the adapter's single error funnel — structurally, not conditioned on status — and there is deliberately **no `:body_preview` field** on the struct. Each provider needs its **own** redaction pattern; inheriting a sibling's is a silent no-op, so the pattern ships with a companion assertion that the sibling providers' patterns match nothing in the same fixture. The bundled adapter honours this in full; the published conformance suite does not bind it.

There is no cleanup invariant: there is no `Stream.resource/3` and no Finch reference, because `Req.request/1` owns its own connection lifecycle. Stated so the absence reads as intent.

### 39.4 Engine integration

`ALLM.Engine.t()` gains one field:

```elixir
moderation_adapter: module() | nil
```

It is a **peer** to `:adapter`, `:image_adapter`, and `:embed_adapter`, never a fallback for any of them. A single engine may combine four providers, since the adapters are independent:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,                     # chat
    image_adapter: ALLM.Providers.OpenAI.Images,           # images
    embed_adapter: ALLM.Providers.Voyage.Embeddings,       # embeddings
    moderation_adapter: ALLM.Providers.OpenAI.Moderation,  # moderation
    model: "claude-sonnet-4-6"
  )
```

Key resolution (§6.4) uses each adapter's own provider key namespace, so mixing providers requires each provider's key to be resolvable. Engines remain free of key material and safe to serialize.

### 39.5 Public API

```elixir
defmodule ALLM do
  @spec moderation_request(String.t() | [ALLM.ModerationRequest.item()], keyword()) ::
          ALLM.ModerationRequest.t()

  @spec moderate(
          ALLM.Engine.t(),
          String.t() | [ALLM.ModerationRequest.item()] | ALLM.ModerationRequest.t(),
          keyword()
        ) ::
          {:ok, ALLM.ModerationResponse.t()}
          | {:error,
             ALLM.Error.EngineError.t()
             | ALLM.Error.ValidationError.t()
             | ALLM.Error.ModerationAdapterError.t()}
end
```

`moderate/3` accepts a bare string (sugar for a one-element batch), a list of items, or a fully constructed `%ALLM.ModerationRequest{}` (dispatched verbatim; opts are not merged onto it). For the first two shapes, opts named after `ModerationRequest` fields lift onto the built request and everything else is treated as a call-control opt or forwarded to the adapter.

Example:

```elixir
engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.OpenAI.Moderation)

{:ok, response} = ALLM.moderate(engine, user_text)

if ALLM.ModerationResponse.flagged?(response) do
  reject(ALLM.ModerationResponse.flagged_categories(response))
end
```

Dispatch order is fixed, and the ordering is load-bearing:

1. adapter-presence gate (`:no_moderation_adapter`) — first, so a misconfigured engine never surfaces as a request problem;
2. `ALLM.Validate.moderation_request/1` (`:invalid_moderation_request`);
3. `ALLM.Capability.preflight_moderation/2` (`:unsupported_capability`) — a no-op without a model catalog, per §6.3;
4. model stamping, adapter-opt merge, then dispatch.

**Capability pre-flight runs at the façade, not inside `moderate/2`.** A direct adapter call bypasses the capability gate by design; callers wanting the gate go through `ALLM.moderate/3`. The adapter's own pre-flight covers wire-shape validation only — empty input, batch size, image MIME, image byte size — and every one of those gates runs *ahead* of `ALLM.Keys.fetch!/2` so a request that is going to be rejected never needs a valid key.

There is deliberately **no Layer D**. A moderation verdict carries no conversation state, so `ALLM.Session` is untouched.

### 39.6 Batching — the deliberate divergence from §36.6

**The façade does not chunk, and adapters may see an input longer than they accept.** This inverts §36.6 and is the one place the two capabilities were expected to match and do not. Two reasons, either sufficient:

1. **Ids do not merge.** One moderation call returns exactly one provider `id` per HTTP request. Merging N chunks would produce N ids with nowhere to put them — `ALLM.EmbeddingResponse` absorbs this by taking the first non-`nil` because its ids are diagnostic, whereas a moderation `id` is the receipt for a verdict a caller may need to cite.
2. **The endpoint is free.** The cost pressure that makes a fifty-round-trip embedding ingest worth hiding does not exist here.

`max_batch_size/0` remains public and `:batch_too_large` still fires, so the caller-side loop is explicit and owns its own cursor:

```elixir
adapter = engine.moderation_adapter

input
|> Enum.chunk_every(adapter.max_batch_size())
|> Enum.map(&ALLM.moderate(engine, &1))
```

That loop applies to an **all-strings** `:input` only. Per §39.2.1 a list carrying an `ALLM.ImagePart` is one item judged as a whole, so there is nothing to chunk; gate on `ALLM.ModerationRequest.multimodal?/1` when the shape is not known statically.

**Retry budgets still nest.** `opts[:retry]` is forwarded verbatim in the adapter's dispatch opts, so an adapter running its own `ALLM.Retry.run/3` loop sits inside the façade's and the two budgets multiply for any reason both loops treat as retryable — up to 9 adapter calls under the default 3-attempt policy, against 3 for a reason retryable at one layer only. This is the library-wide characteristic §36.6 documents, not a moderation one; it is restated because there is no chunking layer here to attribute it to.

### 39.7 Provider adapters in v0.6, and the §35.7 carve-out

v0.6 bundles **one** moderation adapter, `ALLM.Providers.OpenAI.Moderation`, against `POST /v1/moderations`.

| | OpenAI |
|---|---|
| Endpoint | `POST https://api.openai.com/v1/moderations` (not overridable) |
| Auth | `authorization: Bearer` |
| Key atom / env var | `:openai` / `OPENAI_API_KEY` |
| Models | `omni-moderation-latest`, `omni-moderation-2024-09-26` |
| Text input | `input` — always an array, even for one string |
| Multimodal input | `input` — content blocks: `{"type":"text",…}` and `{"type":"image_url",{"url":…}}` |
| Image source | a `{:url, _}` `ALLM.Image` forwards its URL verbatim; every other source inlines as a `data:` URI |
| `ALLM.ImagePart.detail` | **never sent** — dropped with a one-per-process deferred-form `Logger.debug/1` |
| Verdict | `results[].flagged` |
| Categories / scores | `results[].categories`, `results[].category_scores` — 13 slash-named string keys |
| Applied types | `results[].category_applied_input_types` → `:applied_input_types` |
| Index | **absent from the wire** — assigned from array position |
| Usage / cost | **none.** The endpoint is free |
| Response id | top-level `id` (`"modr-…"`), one per HTTP call |
| Correlation | `x-request-id` response header |
| Error envelope | `{"error": {"message", "type", "param", "code"}}` |
| `max_batch_size/0` | 1000 |

Five provider behaviours are worth stating in the spec because each falsified an assumption during implementation and each is invisible from the type signatures:

1. **`/v1/moderations` returns 200 for unknown fields and silently ignores them.** The recorder's negative-control arm confirmed it live. Two consequences: an unrecognised `ModerationRequest.options` key is dropped by the provider rather than surfacing a 400, and — the load-bearing half — "the API accepted it" is **not** evidence that a field is part of this endpoint's schema. Only an observable in the *response* can promote a wire-field row at this endpoint.
2. **`detail` inside `image_url` is therefore unresolvable from this wire, and is recorded as inferred.** The decision to drop it rests on the provider's documented request shape, which carries no `detail` key. A paired live arm sending `detail: "low"` returned 200 with identical `category_scores`, which promotes nothing — acceptance is not evidence at a permissive endpoint, and score equality is not evidence either. A contract test asserting no `detail` key is emitted, at any `:detail` value, for either image source, is the only thing binding the behaviour.
3. **`max_batch_size/0` of 1000 is a demonstrated floor, not a documented cap.** OpenAI documents no maximum `input` array length; a live ladder found every rung of `[1, 32, 100, 128, 1000]` accepted with no upper bound observed. The number is the ladder's top rung, chosen so the adapter never promises more than has been demonstrated.
4. **The multimodal cardinality rule is confirmed on the wire, and the confirmation is stronger than a count.** A two-block `input` (one text, one inlined image) returned exactly one `results` entry whose `category_applied_input_types` listed `"image"` for six of thirteen categories — so the image was genuinely classified rather than silently dropped, which a bare result count could not have distinguished.
5. **The response carries no free-text echo of the submitted input.** Verified by a recursive walk of a recorded body and asserted by the recorder as a precondition to writing, so the property is enforced on every re-record. This is what makes `response:` in the `:stop` telemetry metadata (§39.9) an exposure of *verdicts* rather than of user content.

The `text-moderation-*` family (`text-moderation-latest`, `-stable`, `-007`) was **shut down on 2025-10-27** with `omni-moderation` as the stated replacement, and is not implemented. The adapter maintains no denylist — whatever `:model` the caller sets is forwarded, and a shut-down name comes back as the provider's own 400, which is clearer and more current than a hard-coded list that goes stale the moment a new model ships. A `nil` model is **omitted from the wire entirely**, letting OpenAI apply its own current default rather than pinning a name ALLM must chase.

#### The §35.7 amendment

§35.7's bundled-adapter rule, as amended in v0.5, admits an adapter when **either** (a) its maintenance overlaps with its provider's already-bundled chat adapter, **or** (b) it is the provider's own officially-recommended path for a capability that provider does not itself offer.

`ALLM.Providers.OpenAI.Moderation` qualifies under (a) — it shares key resolution, header construction, and error-envelope handling with the bundled OpenAI chat adapter. The amendment moderation needs is not about *this* adapter's admission but about the family's **shape**:

> A capability family may be bundled with **exactly one** provider adapter when that provider is already bundled for chat, and the capability's absence on the other bundled providers is **documented rather than backfilled with a proxy**.

This is the second scoped carve-out to §35.7 and, like the v0.5 one, it is a carve-out rather than a widening. It does not license shipping a one-provider family for a capability the other providers *do* offer; it licenses declining to invent a module for providers that do not offer it at all.

There is deliberately **no `ALLM.Providers.Anthropic.Moderation`** and **no `ALLM.Providers.Gemini.Moderation`**:

- **Anthropic** ships no moderation endpoint and, unlike the embeddings case, names no partner for one. There is no honest module to write — criterion (b) has no candidate to admit.
- **Google** exposes safety ratings *inline on `generateContent`*: `promptFeedback.safetyRatings` and `candidates[].safetyRatings`, four `HARM_CATEGORY_*` values on an ordinal `NEGLIGIBLE | LOW | MEDIUM | HIGH` enum. That is a property of a *generation call*, not a standalone classification endpoint, and cannot implement `c:ALLM.ModerationAdapter.moderate/2` without inventing a generation call to attach itself to. Surfacing those ratings belongs on `ALLM.Response.metadata` in a chat-adapter phase.

This asymmetry is also what drives the score-map decision of §39.2.2: there is no second provider to normalize against, and the plausible one reports a different shape on a different call.

Third-party moderation providers (Mistral, AWS Comprehend, Perspective API, local classifiers) remain out of core and ship as separate packages implementing `ALLM.ModerationAdapter`, exactly as third-party image and embedding adapters do.

### 39.8 Testing

`ALLM.Providers.FakeModeration` implements `ALLM.ModerationAdapter` with scripted responses — analogous to `ALLM.Providers.Fake` (§31), `ALLM.Providers.FakeImages` (§35.8), and `ALLM.Providers.FakeEmbeddings` (§36.8). It ships in `lib/`, not `test/support/`, because downstream applications need it for their own tests.

```elixir
engine =
  ALLM.Engine.new(
    moderation_adapter: ALLM.Providers.FakeModeration,
    adapter_opts: [
      moderation_script: [
        {:ok, [%ALLM.ModerationResult{flagged: false}]},
        {:flagged, ["violence"]},
        {:error, %ALLM.Error.ModerationAdapterError{reason: :rate_limited}},
        {:retry_until_call, 3}
      ]
    ]
  )
```

`{:flagged, categories}` is the shorthand for the overwhelmingly common test — "assert my app rejects flagged content" — and synthesizes a single flagged result with those names `true` at score `1.0` and every other category `false` at `0.0`. `{:retry_until_call, n}` returns a synthetic retryable error for the first `n - 1` calls against that entry, which is the vehicle for exercising retry integration; consecutive entries chain, which is how a layered retry budget is scripted.

Each call advances a cursor keyed on engine identity, so `async: true` is safe and two engines built with content-equal scripts each start at index 0. The content-hash fallback — and with it the shared-cursor footgun — remains only for **direct** adapter calls made without an engine.

Two behaviours diverge deliberately from `FakeEmbeddings` and are stated here because both are load-bearing for test authors:

1. **No script yields a clean verdict, not an error.** With `moderation_script` absent or `[]`, every call returns one unflagged result per item carrying the full category set at score `0.0`. A clean verdict is a meaningful default that costs a caller nothing, whereas a synthesized embedding vector is not.
2. **A non-empty script that runs off the end IS an error** — `reason: :unknown` with `metadata.cause: :moderation_script_exhausted`. "I scripted nothing, give me a benign default" is a convenience; "my script ran out" is almost always an off-by-one in the caller's expectation of how many times `moderate/2` gets invoked, and answering it with an unflagged pass would hide that. In particular a truncated `[{:retry_until_call, 1}]` script would otherwise report success on call 1 with no retry ever exercised.

`ALLM.Test.ModerationAdapterConformance` ships in the `allm_conformance` package with **ten cases**, covering `max_batch_size/0`'s shape, the two pre-flight gates, cardinality in the single-string and all-strings shapes, index range, `:flagged`'s type and the category maps' string keying, `metadata` round-tripping, `request_id` preservation, and the multimodal single-result rule. Third-party adapter authors add the package as a test-only dep and `use` the suite. Its cases size their input as `min(<wanted>, adapter.max_batch_size())`, so the published suite certifies a conforming adapter at **any** cap, including `1`; a literal input size in a case would make the suite fail for a conservative adapter.

The §36.8 limitation applies here verbatim and is worth restating: the suite drives a real adapter through a script short-circuit, so **the adapter's own response decoder is never reached on the success path**. Each bundled adapter therefore carries its own decoder tests against recorded wire fixtures. The cases bind fully for an adapter that implements `moderate/2` itself, which is the third-party author the published suite exists to serve.

### 39.9 Telemetry

One span, mirroring §35.9 and §36.9:

- `[:allm, :moderate, :start]` — measurements: `system_time`; metadata: `request_id`, `engine`, `model`, `input_count`, `multimodal`.
- `[:allm, :moderate, :stop]` — measurements: `duration`, `result_count`, `flagged_count`; metadata: `request_id`, `model`, `input_count`, `multimodal`, `usage`, `response`, `error` (`nil` on success).
- `[:allm, :moderate, :exception]` — measurements: `duration`; metadata: `kind`, `reason`, `stacktrace`. Emitted **instead of** `:stop` and then re-raised, via `:telemetry.span/3`. Two paths reach it: `ALLM.Keys.fetch!/2`'s `%EngineError{reason: :missing_key}` (§6.4) and the `ArgumentError` a non-conforming `:moderation_adapter` triggers (invariant 2). A `:start`/`:stop`-only attachment leaves an unterminated span on every missing key.

`result_count` and `flagged_count` are present on **both** `:stop` paths, reporting `0` on error, so the measurement key set is stable for a metrics backend. `usage` is carried in metadata as `nil` unconditionally even though `%ModerationResponse{}` has no such field (§39.2.3), for the same reason: a handler written against the `:embed` or `:image` span must not `KeyError` here.

**`input_count` is the raw element count, not the item count.** A two-element multimodal request reports `input_count: 2, multimodal: true` while the provider's item count is `1` (§39.2.1). The divergence is deliberate: `multimodal` rides alongside so a consumer derives the item count without a second measurement. Changing this derivation requires amending the façade `@doc`, `ALLM.Telemetry`'s moduledoc, this section, and the test that pins it — together.

**Operator note.** `:stop` metadata carries `response:`, whose `:raw` is the provider body. The bundled provider does not echo submitted input there (§39.7 item 5), so this is an export of *verdicts about* user content rather than of the content itself — but a handler that serializes the whole metadata map to an external backend is still exporting moderation judgements about identifiable users to that vendor. Established precedent rather than new exposure (the `:image` span has carried `response:` with image bytes since v0.3), and it requires explicit operator opt-in, so it is a documentation obligation carried by `guides/moderation.md`.

### 39.10 Out of scope for v0.6

- **streaming** — moderation is request/response; there is no `stream_moderate/3`, and `stream: true` is silently ignored rather than erroring
- **`text-moderation-*` models** — shut down 2025-10-27 (§39.7); shipping a code path for a model the provider has switched off would be shipping a guaranteed 404
- **a normalized cross-provider category taxonomy** — one bundled provider, and the plausible second reports a different shape on a different call (§39.2.2)
- **a default "unsafe" threshold, `block?/2`, or a policy DSL** — a product decision, not a library one (§39.1 item 4)
- **`ALLM.Providers.Gemini.Moderation` / `ALLM.Providers.Anthropic.Moderation`** — no standalone endpoint exists on either (§39.7)
- **transparent batch chunking** — ids do not merge and the endpoint is free (§39.6)
- **automatic moderation inside `chat/3` / `generate/3`** — a hidden second HTTP call per turn, doubling latency and silently changing `chat/3`'s error union
- **`ALLM.Session` integration** — a moderation verdict carries no conversation state
- **moderating tool results or assistant output as a distinct API** — the same call with a different input string; no new surface is needed
