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
          metadata: map()
        }

  defstruct [
    :name,
    :description,
    :schema,
    :handler,
    metadata: %{}
  ]
end
```

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

- embeddings and audio — callers drop down to a provider SDK directly
- image generation — candidate for a first-class non-streaming primitive in a later version; not shipped in v0.2

---

## 33. v0.2 non-goals

Out of scope for the initial version:

- prompt templating DSLs
- memory stores and retrieval systems
- advanced agent planning layers
- workflow schedulers
- hard-coded provider-specific abstractions in the core API
- embeddings, audio input/output, image generation (see §32.5)
- dependency on `req_llm` or any other multi-provider HTTP library (see §32.2)

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
