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

> **Phase 23 amendment (commits `9b74416..d8b3ae2`; docs land in the 23.4 commit).** `ALLM.Tool` gains two
> serializable fields, both defaulted so every existing tool is unchanged on
> the wire:
>
> ```elixir
> compact: boolean(),          # default false
> summary: String.t() | nil,   # default nil
> ```
>
> `compact: true` asks the chat loop to send the tool to the model as a
> one-line stub and to offer the built-in `tool_help` meta-tool (§40).
> `summary` overrides the stub's one-line summary; `nil` derives it from the
> first sentence of `description`. `Tool.new/1` guards `:compact` with
> `is_boolean/1` and raises `ArgumentError` otherwise (`lib/allm/tool.ex:159-161`),
> the same form as the `:manual` guard; `:summary` is not guarded by the
> constructor and is checked by `ALLM.Validate.tool/1` instead (§16).
> `__from_tagged__/1` decodes `compact` as `data["compact"] || false`, which is
> safe because both defaults are falsy (`lib/allm/tool.ex:181`).

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

> **Phase 27 amendment (commits `55196e8..24d55b7`; docs land in the 27.5 commit).** `ALLM.Request` gains one typed field, `prompt_cache :: nil | %{key: String.t() | nil, retention: :short | :long}`, default `nil` (`lib/allm/request.ex:77`, `:89`, `:104`). It is a provider-neutral request to cache the prompt prefix. `:short` keeps the provider's default lifetime and sends no retention field; `:long` asks for the longest per-request lifetime the provider offers. `Request.new/2` stays a `struct!/2` pass-through; shape discipline lives in `ALLM.Validate.request/1`, which adds exactly one `{:prompt_cache, :invalid_shape}` when the value is not `nil` and not a map with exactly `:key` (nil or a non-empty binary) and `:retention` (`:short` or `:long`) (`lib/allm/validate.ex:616-620`, over the shared `defguard Request.is_prompt_cache/1` at `lib/allm/request.ex:215`). JSON decoding restores the atoms without `String.to_atom/1`; an unknown retention string passes through undecoded and fails validation.
>
> Adapter translation runs before `request.options` is merged, so a raw provider option in `options` wins on the wire:
>
> | Adapter / endpoint | `nil` | `%{key: k, retention: :short}` | `%{key: k, retention: :long}` |
> |---|---|---|---|
> | OpenAI Chat Completions and Responses (one helper, `lib/allm/providers/openai.ex:1599-1610`) | body unchanged | `"prompt_cache_key" => k`, omitted when `k` is nil | same plus `"prompt_cache_retention" => "24h"` |
> | Anthropic (`lib/allm/providers/anthropic.ex:615-618`) | body unchanged | top-level `"cache_control" => %{"type" => "ephemeral"}`; `k` is never sent | `"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}` |
> | Gemini | body unchanged | ignored without error (implicit caching; no request field) | ignored |
>
> A direct adapter call with an invalid `prompt_cache` leaves the body unchanged (no pre-flight validation runs outside the facade). Acceptance of every translated field, on `gpt-5.6`, `gpt-6-luna`, `gpt-5.4-nano` (Responses), `gpt-4o-mini` (Chat Completions), `claude-haiku-4-5-20251001`, `claude-sonnet-5` and `claude-sonnet-4-6`, is asserted live by `scripts/record_prompt_cache_fixtures.exs --only acceptance`, each paired with an invented-field control that the provider rejects with 400.

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

> **Phase 27 amendment (commits `55196e8..24d55b7`; docs land in the 27.5 commit).** `ALLM.Usage` gains `cache_write_input_tokens :: non_neg_integer() | nil` (default `nil`), the prompt tokens written to the provider's cache on this call (`lib/allm/usage.ex:40`). The cache counters now have one cross-provider meaning: `input_tokens` is the TOTAL prompt count, cached reads and cache writes included; `cached_input_tokens` is the part served from the cache. So `cached_input_tokens + (cache_write_input_tokens || 0) <= input_tokens` whenever both are integers, and `cached_input_tokens / input_tokens` is a hit ratio on every provider. `nil` means the provider did not report the counter; no adapter substitutes `0`.
>
> | Adapter / endpoint | `input_tokens` | `cached_input_tokens` | `cache_write_input_tokens` |
> |---|---|---|---|
> | OpenAI Chat Completions | `prompt_tokens` | `prompt_tokens_details.cached_tokens` | `prompt_tokens_details.cache_write_tokens` (absent on `gpt-5.4-nano`, live 2026-09-27 → `nil`) |
> | OpenAI Responses | `input_tokens` | `input_tokens_details.cached_tokens` | `input_tokens_details.cache_write_tokens` |
> | Anthropic | `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (the raw count moves to `extra["uncached_input_tokens"]`) | `cache_read_input_tokens` | `cache_creation_input_tokens` |
> | Gemini | `promptTokenCount` | `cachedContentTokenCount` | `nil` (not reported) |
>
> The lifted keys leave `extra`; any other key of a details object stays (OpenAI's `lift_cache_details/2`, `lib/allm/providers/openai.ex:2129`; Anthropic's `decode_usage/1`, `lib/allm/providers/anthropic.ex:1276`; Gemini's `parse_usage/1`, `lib/allm/providers/gemini.ex:1208`). **Behaviour change for Anthropic:** on a cache-active request `input_tokens` and `total_tokens` are larger than before (inclusive), and because cost population prices every `input_tokens` token at the plain input rate, `input_cost` rises too; a request with no cache activity is unchanged. Cache-aware pricing is not implemented. Each adapter's streaming path emits `Map.from_struct/1` of the same non-streaming decoder, so streamed and non-streamed usage are equal field for field (pinned by `test/allm/providers/cache_usage_family_test.exs`); Anthropic merges `message_start` and `message_delta` usage (non-nil delta keys win) and emits once, and OpenAI Chat Completions streaming bodies now carry `"stream_options" => %{"include_usage" => true}` via `Map.put_new/3`, so a caller's own `stream_options` in `request.options` wins (`lib/allm/providers/openai.ex:996-999`). Recorded live fixtures under `test/fixtures/{openai,anthropic,gemini}/*/recorded/prompt_cache_*` confirm the `input_tokens` and `cached_input_tokens` columns on real cache hits; every recorded hit carries a cache-write count of `0` (or omits it), so the `cache_write_input_tokens` column's field names are confirmed live by `scripts/record_prompt_cache_fixtures.exs`'s asserts (a non-zero Anthropic `cache_creation_input_tokens` was observed live) but not recorded with a non-zero value. The request-side acceptance arms (`prompt_cache_key`, `"24h"`, `cache_control`) are likewise asserted live and write no fixture by design; only their unknown-field controls are recorded.

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

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming audio does **not** extend this union. Its events live in two separate closed unions, `ALLM.SpeechEvent` (`:speech_started`, `:audio_delta`, `:speech_completed`, `:error`) and `ALLM.TranscriptionEvent` (`:transcription_started`, `:partial_transcript`, `:committed_transcript`, `:transcription_completed`, `:error`), specified in §37.11.1, so no reducer of `ALLM.Event` changes. The same rule applies to them: adding a variant is breaking for their reducers; adding a payload key is not. They round-trip ETF, not JSON (`:audio_delta` carries raw bytes).

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

> **Phase 27 amendment (commits `55196e8..24d55b7`; docs land in the 27.5 commit).** `prompt_cache:` is accepted as a request option (`ALLM.request/2` sets the typed `Request.prompt_cache` field, §5.4) and, by `chat/3`, `stream/3`, `step/3`, `stream_step/3` and every `ALLM.Session` operation, as a call option or an `engine.params` key (call opts win). `Chat.build_request/4` normalizes it (`lib/allm/chat.ex:2032`, `normalize_prompt_cache/2` at `:2050-2071`): `nil` / `false` → `nil`; `true`, `%{}` or `[]` → `%{key: <session_id or nil>, retention: :short}`; a map or keyword with `:key` and/or `:retention` gets a missing `:retention` defaulted to `:short` and a missing or nil `:key` defaulted to the call's `:session_id` when that is a non-empty binary (`:2084-2087`); a string-keyed map (a JSON round-tripped engine's `params`) is converted to atom keys first; anything else passes through for `Validate.request/1` to reject. `:prompt_cache` is consumed into the typed field and never reaches `request.options`. The key default is opt-in: a `:session_id` alone never turns caching on. `ALLM.Session` already forwards `session.id` as `:session_id`, so a session's id is its cache key unless the caller passes one. `generate/3` and `stream_generate/3` take a caller-built `%Request{}`, so those callers set `Request.prompt_cache` directly.

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

> **Phase 23 amendment (commits `9b74416..d8b3ae2`; docs land in the 23.4 commit).** `ALLM.Validate.tool/1` gains one
> rule, `{:summary, :not_a_string}`: a tool's `:summary` must be `nil` or a
> binary (`lib/allm/validate.ex:514-515`). Through `ALLM.Validate.request/1`
> the path is prefixed as `[:tools, idx, :summary]`. `:compact` gets no
> validator rule, mirroring `:manual`: the constructor guard is its only gate,
> and a hand-built `%Tool{compact: :yes}` is treated as not compact (sent in
> full), which is the safe direction. No new reason atom is added. The
> existing "tool names are unique" rule is what rejects a caller's own tool
> named `tool_help` beside a compact tool (§40.4).

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

> **Phase 23 amendment (commits `9b74416..d8b3ae2`; docs land in the 23.4 commit).** Compact tool disclosure (§40) adds one module, under the shipped `lib/allm/` prefix:
>
> ```text
> lib/allm/tool_help.ex                  # pure runtime helper — stub projection, tool_help rendering, required-key check
> ```
>
> Existing modules extended: `ALLM.Tool` (`:compact`, `:summary`), `ALLM.Validate` (`{:summary, :not_a_string}`), `ALLM.Chat` (the wire list goes through `ToolHelp.project/2`; execution sites see the full list plus the meta-tool), `ALLM.ToolRunner` (answers `tool_help`, runs the required-key check for compact tools). No adapter, `ALLM.Event` variant, or `ALLM.Engine` field changes.

> **Phase 25 amendment (commits `da277bf..e91cdb0`; docs land in the 25.6 commit).** The audio capability (§37) adds the following modules, under the shipped `lib/allm/` prefix.
>
> ```text
> lib/allm/audio.ex                      # Layer A — shared audio value (STT input, TTS output)
> lib/allm/speech_request.ex             # Layer A
> lib/allm/speech_response.ex            # Layer A
> lib/allm/transcription_request.ex      # Layer A
> lib/allm/transcription_response.ex     # Layer A
> lib/allm/speech_adapter.ex             # Layer B — behaviour
> lib/allm/transcription_adapter.ex      # Layer B — behaviour
> lib/allm/error/speech_adapter_error.ex
> lib/allm/error/transcription_adapter_error.ex
> lib/allm/providers/fake_speech.ex
> lib/allm/providers/fake_transcription.ex
> lib/allm/providers/openai/speech.ex
> lib/allm/providers/openai/transcription.ex
> lib/allm/providers/gemini/transcription.ex
> ```
>
> Existing modules extended: `ALLM` (`synthesize/3`, `speech_request/2`, `transcribe/3`, `transcription_request/2`), `ALLM.Engine` (`:speech_adapter`, `:transcription_adapter`, `:speech_model`, `:transcription_model`), `ALLM.Validate` (`speech_request/1`, `transcription_request/1`), `ALLM.Telemetry` (`:synthesize` and `:transcribe` spans), `ALLM.Serializer` (seven registry entries), `ALLM.Error.EngineError` (`:no_speech_adapter`, `:no_transcription_adapter`), `ALLM.Error.ValidationError` (`:invalid_speech_request`, `:invalid_transcription_request`). `ALLM.Capability` is **not** extended (§37.1 item 5). The published conformance suites live in the `conformance/` project: `ALLM.Test.SpeechAdapterConformance`, `ALLM.Test.TranscriptionAdapterConformance`.

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming audio (§37.11) and the ElevenLabs adapters (§37.7.4) add the following modules, under the shipped `lib/allm/` prefix.
>
> ```text
> lib/allm/speech_event.ex                         # Layer A — closed union (ETF-only)
> lib/allm/transcription_event.ex                  # Layer A — closed union (ETF-only)
> lib/allm/transcription_stream_request.ex         # Layer A
> lib/allm/speech_stream_adapter.ex                # Layer B — behaviour
> lib/allm/transcription_stream_adapter.ex         # Layer B — behaviour
> lib/allm/audio_stream.ex                         # Layer C — collect_speech/1, collect_transcription/1, text_deltas/1
> lib/allm/audio_stream/chat_stream_error.ex       # private exception raised by text_deltas/1 (@moduledoc false)
> lib/allm/providers/elevenlabs/speech.ex
> lib/allm/providers/elevenlabs/transcription.ex
> lib/allm/providers/support/elevenlabs.ex         # headers, base URL, output_format/2, error classification, redaction
> lib/allm/providers/support/http_response.ex      # provider HTTP helpers shared by every Req-based adapter
> lib/allm/providers/support/transcription_adapter.ex  # the shared STT contract (gates, Fake hand-off, one attempt)
> lib/allm/providers/support/speech_adapter.ex     # the shared TTS contract and the Finch stream state machine
> lib/allm/providers/support/input_pump.ex         # reduces a streamed input in a monitored helper process
> lib/allm/providers/support/web_socket.ex         # behaviour
> lib/allm/providers/support/web_socket/mint.ex    # default implementation, over :mint_web_socket
> lib/allm/providers/support/web_socket/input_loop.ex  # the shared WebSocket owner loop
> ```
>
> Existing modules extended: `ALLM` (`stream_synthesize/3`, `stream_synthesize_input/3`, `stream_transcribe/3`), `ALLM.SpeechRequest` / `ALLM.SpeechResponse` (`:sample_rate`), `ALLM.Validate` (`speech_request/2`, `transcription_stream_request/1`), `ALLM.Serializer` (one registry entry, `TranscriptionStreamRequest`; the event unions are not registered), `ALLM.Telemetry` (two span names and the `[:allm, :audio, :first_chunk]` event), `ALLM.Error.SpeechAdapterError` / `ALLM.Error.TranscriptionAdapterError` (`:unsupported_feature`), `ALLM.Adapter` (`hoist_transport_opts/2`, shared by the chat runner and the audio stream façades), `ALLM.Providers.Support.Transport` (`cancel_and_drain/3`), `ALLM.Providers.FakeSpeech` / `ALLM.Providers.FakeTranscription` (both streaming behaviours) and `ALLM.Providers.OpenAI.Speech` (`stream_synthesize/2`). `ALLM.Engine` is **not** extended. New dependency: `:mint_web_socket` (`~> 1.0`). The published conformance suites gain `ALLM.Test.SpeechStreamAdapterConformance`, `ALLM.Test.SpeechInputStreamAdapterConformance` and `ALLM.Test.TranscriptionStreamAdapterConformance`.

> **Phase 24 amendment (commits `7de1c1c..0c9c8b5`; docs land in the 24.5 commit).** Typed classification (§41) adds the following modules, under the shipped `lib/allm/` prefix.
>
> ```text
> lib/allm/classification_question.ex              # Layer A — one typed question (:choice | :score | :yes_no)
> lib/allm/classification_request.ex               # Layer A
> lib/allm/classification_answer.ex                # Layer A — one typed answer (tagged union in one struct)
> lib/allm/classification_response.ex              # Layer A
> lib/allm/classification_adapter.ex               # Layer B — behaviour
> lib/allm/error/classification_adapter_error.ex
> lib/allm/providers/fake_classification.ex
> lib/allm/providers/typesafe/classification.ex    # TypeSafe Jev, admitted under the §35.7 classification carve-out
> ```
>
> Existing modules extended: `ALLM` (`classify/3`, `classification_request/2`), `ALLM.Engine` (`:classification_adapter`, `:classification_model`), `ALLM.Validate` (`classification_request/1`), `ALLM.Telemetry` (`:classify` span), `ALLM.Serializer` (five registry entries), `ALLM.Error.EngineError` (`:no_classification_adapter`), `ALLM.Error.ValidationError` (`:invalid_classification_request`), `ALLM.Providers.Support.Redact` (`typesafe/1`). `ALLM.Capability` and `ALLM.Keys` are **not** extended (§41.5, §41.7). The published conformance suite lives in the `conformance/` project: `ALLM.Test.ClassificationAdapterConformance`.

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

> **Phase 25 amendment (commits `da277bf..e91cdb0`; docs land in the 25.6 commit).** The audio capability (§37) adds two spans:
>
> ```elixir
> [:allm, :synthesize, :start | :stop | :exception]
> [:allm, :transcribe, :start | :stop | :exception]
> ```
>
> - `:synthesize` `:start` — measurements `%{system_time: integer()}`; metadata `:request_id`, `:engine`, `:model`, `:input_length` (`String.length/1` of `:input` — graphemes, **not** the code-point count the OpenAI 4096 gate uses; `0` when not a binary).
> - `:synthesize` `:stop` — measurements `%{duration: integer(), audio_bytes: non_neg_integer()}`; metadata as `:start` plus `:usage`, `:response`, `:error` (`nil` on success).
> - `:transcribe` `:start` — measurements `%{system_time: integer()}`; metadata `:request_id`, `:engine`, `:model`, `:audio_mime` (the request audio's `:mime_type`; the audio itself is never carried).
> - `:transcribe` `:stop` — measurements `%{duration: integer(), text_length: non_neg_integer()}`; metadata as `:start` plus `:usage`, `:response`, `:error`.
> - `:exception` on both — measurements `%{duration: integer()}`; metadata `:kind`, `:reason`, `:stacktrace`.
>
> Stable keys as for `:embed` and `:moderate`: `audio_bytes` / `text_length` are `0` and `:usage` is `nil` on the error path. `:model` is the audio slot's model (`request.model || engine.speech_model` / `engine.transcription_model`), never the chat `engine.model`, and is `nil` when neither is set (the adapter default applies after the span starts). **`[:allm, :synthesize, :stop]` metadata carries the audio**: `:response` holds the full synthesized bytes, so a handler that ships it wholesale moves the whole clip per call. The namespace note above applies: these events use `[:allm, …]`.

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming audio (§37.11) adds two spans and one non-span event:
>
> ```elixir
> [:allm, :stream_synthesize, :start | :stop | :exception]
> [:allm, :stream_transcribe, :start | :stop | :exception]
> [:allm, :audio, :first_chunk]
> ```
>
> - `:stream_synthesize` — both `ALLM.stream_synthesize/3` and `ALLM.stream_synthesize_input/3`. `:start` metadata `:request_id`, `:engine`, `:model`, `:input_length` (`nil` for the input form).
> - `:stream_transcribe` — `:start` metadata `:request_id`, `:engine`, `:model`, `:sample_rate`.
> - Both spans' `:stop` fires when the enumerable is **returned**, not when it drains (the chat `:stream` carve-out), so its metadata is `%{response: nil}` and carries no audio, usage or error; `:exception` as for the other spans.
> - `[:allm, :audio, :first_chunk]` — emitted once per stream, at its first `:audio_delta` (speech) or `:partial_transcript` (transcription); never for a stream that fails first. Measurements `%{latency: integer()}` in native units from the façade call; metadata `:request_id`, `:capability` (`:speech | :transcription`), `:provider_model` (the model the start event reports when it is a binary, else the dispatched `request.model`). Because the spans stop before any audio, this is the event that measures time to first audio.
>
> None of the three carries audio bytes or transcript text.

> **Phase 24 amendment (commits `7de1c1c..0c9c8b5`; docs land in the 24.5 commit).** Typed classification (§41) adds one span:
>
> ```elixir
> [:allm, :classify, :start | :stop | :exception]
> ```
>
> - `:start` — measurements `%{system_time: integer()}`; metadata `:request_id`, `:engine`, `:model`, `:question_count`.
> - `:stop` — measurements `%{duration: integer(), answer_count: non_neg_integer()}`; metadata as `:start` plus `:usage`, `:response`, `:error` (`nil` on success).
> - `:exception` — measurements `%{duration: integer()}`; metadata `:kind`, `:reason`, `:stacktrace`. Emitted instead of `:stop`, then re-raised.
>
> Stable keys as for `:embed`, `:moderate` and the audio spans: `answer_count` is `0` and `:usage` is `nil` on the error path. `:model` is the classification slot's model (`request.model || engine.classification_model`), never the chat `engine.model`, and is `nil` when neither is set (the adapter's default applies after the span starts). `:question_count` is `0` for a non-map `:questions`, because `:start` is emitted before validation. The namespace note above applies: these events use `[:allm, …]`.

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

- ~~audio — callers drop down to a provider SDK directly~~ (struck by the Phase 25 amendment below)
- image generation — candidate for a first-class non-streaming primitive in a later version; not shipped in v0.2

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** **Embeddings are no longer out of scope** — they ship in v0.5 as a first-class non-streaming primitive (`ALLM.embed/3`, `%ALLM.EmbeddingRequest{}` / `%ALLM.EmbeddingResponse{}`, the `ALLM.EmbeddingAdapter` behaviour, and the `:embed_adapter` engine slot). See **§36**. The line above is amended to remove "embeddings"; audio remains out of scope. Image generation likewise shipped in v0.3 (§35) but is left in the list above because that line is scoped to *v0.2* and is preserved as a historical record of what v0.2 excluded.

> **Phase 25 amendment (commits `da277bf..e91cdb0`; docs land in the 25.6 commit).** **Audio is no longer out of scope** — it ships in v0.6 as two first-class non-streaming primitives, `ALLM.synthesize/3` (text-to-speech) and `ALLM.transcribe/3` (speech-to-text), with the `ALLM.SpeechAdapter` / `ALLM.TranscriptionAdapter` behaviours and their own engine slots. See **§37**. The "audio" line above is struck rather than deleted, so the record of what v0.2 excluded survives; callers no longer need to drop down to a provider SDK for request/response TTS and STT. Streaming TTS and real-time STT remain out of scope (§37.10).

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming TTS and real-time STT are no longer out of scope: they ship as `ALLM.stream_synthesize/3`, `ALLM.stream_synthesize_input/3` and `ALLM.stream_transcribe/3` (**§37.11**). The last sentence of the Phase 25 note above is superseded.

---

## 33. v0.2 non-goals

Out of scope for the initial version:

- prompt templating DSLs
- memory stores and retrieval systems
- advanced agent planning layers
- workflow schedulers
- hard-coded provider-specific abstractions in the core API
- ~~audio input/output (see §32.5)~~ (struck by the Phase 25 amendment below)
- dependency on `req_llm` or any other multi-provider HTTP library (see §32.2)

> **Phase 20 amendment (commits `ac5d845..c3aefce`; docs land in the 20.7 commit).** The line above previously read `embeddings, audio input/output, image generation (see §32.5)`. Two of its three entries were stale:
>
> - **image generation** shipped in v0.3 (**§35**) and was never struck when it did — corrected here;
> - **embeddings** ship in v0.5 (**§36**) — struck here.
>
> Audio input/output remains a genuine non-goal.

> **Phase 25 amendment (commits `da277bf..e91cdb0`; docs land in the 25.6 commit).** The sentence above is superseded, and the `audio input/output` line in the list is struck (not deleted): request/response audio ships in v0.6 (**§37**). What remains a non-goal is *streaming* audio (streaming TTS, real-time STT) and audio as a chat `Message` content part (§37.10).

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming audio ships (**§37.11**), so the only remaining audio non-goal from the note above is audio as a chat `Message` content part (§37.10).

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

Single struct covering generation and edits. The `operation` field selects between them.

```elixir
defmodule ALLM.ImageRequest do
  @type operation :: :generate | :edit
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
          # inputs for :edit
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

Validation lives in `ALLM.Validate.image_request/1` (analogous to §14).

> **v0.6.0 amendment:** The `:variation` operation is removed. v0.3 through v0.5 also defined `:variation` (exactly one `input_images` entry; `prompt` `nil` or ignored), served only by OpenAI's `/v1/images/variations` on `dall-e-2`. OpenAI has since retired that endpoint (a bare 404 for every model) and dropped `dall-e-2` and `dall-e-3` from `/v1/models`, and `ALLM.Providers.Gemini.Images` never supported it, so no bundled provider could serve it. `operation` is now the closed set `:generate | :edit`. Legacy data is rejected deterministically rather than migrated: a persisted JSON `ImageRequest` with `"operation": "variation"` fails `ALLM.Serializer.from_json/1` with a `ValidationError` carrying `{:_unknown, :atom_decode_failed}` (the operation is decoded against its closed set, not via `String.to_existing_atom/1`), and an in-memory or ETF-restored struct with `operation: :variation` fails `ALLM.Validate.image_request/1` with `{:operation, :unknown}`.

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

- `generate/2` handles both operations — adapters switch on `request.operation`.
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

  @spec image_request(String.t(), keyword()) :: ALLM.ImageRequest.t()
end
```

`generate_image/3` accepts either a bare prompt string (options form the rest of the request) or a fully constructed `%ALLM.ImageRequest{}`. `edit_image/4` is sugar that builds the appropriate `ALLM.ImageRequest` under the hood.

> **v0.6.0 amendment:** `ALLM.image_variations/3` is removed along with the `:variation` operation (§35.2.2). It was sugar for `%ALLM.ImageRequest{operation: :variation, input_images: [image], prompt: nil}`; there is no replacement.

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

- **`ALLM.Providers.OpenAI.Images`** — wraps `/v1/images/generations` and `/v1/images/edits`. Supports `dall-e-2`, `dall-e-3`, and `gpt-image-1`. `supported_operations/0` returns `[:generate, :edit]`; per-model gating: `gpt-image-1` and `dall-e-2` support generate + edit; `dall-e-3` generate only.
- **`ALLM.Providers.Gemini.Images`** (Phase 16.5) — wraps `generateContent` with `responseModalities: ["TEXT", "IMAGE"]`. Supports `gemini-3.1-flash-image-preview` and successors. `supported_operations/0` returns `[:generate, :edit]`; any other operation is rejected as `:unsupported_operation`. The translator delegates to `ALLM.Providers.Gemini.to_gemini_request_body/2`.
- **No Anthropic image-generation adapter.** Anthropic does not offer image generation as of v0.3. The Anthropic chat adapter continues to accept `ALLM.ImagePart` inputs for vision.

> **v0.6.0 amendment:** `ALLM.Providers.OpenAI.Images` no longer wraps `/v1/images/variations`; through v0.5 it did, for `dall-e-2` only (§35.2.2). Separately, OpenAI has retired `dall-e-2` and `dall-e-3` — neither is listed by `GET /v1/models` as of 2026-09-24. Their per-model gating rows are kept so a request naming them is still gated pre-flight, but `gpt-image-1` is the model to use.

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

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** The rule takes a **third scoped carve-out**, for the audio family (§37), on the owner's decision to bundle ElevenLabs in core rather than as a separate package.
>
> ElevenLabs fails every criterion above: (a) it has no bundled chat adapter to share maintenance with; (b) no bundled provider names it as a recommended partner; and the Phase 22 family-shape rule requires the provider to be bundled for chat. Yet the audio family's streaming behaviours (§37.11) would otherwise ship with no real provider behind their input-streaming callbacks: OpenAI's text-in and realtime speech are its Realtime API, which is out of scope, and Gemini has no streaming audio endpoint in ALLM.
>
> The addition:
>
> > An adapter from a provider with no bundled chat adapter may be bundled into the audio family (§37) when it is the family's first bundled implementation of an input-streaming audio callback — `c:ALLM.SpeechStreamAdapter.stream_synthesize_input/3` or `c:ALLM.TranscriptionStreamAdapter.stream_transcribe/3` — so that a published streaming behaviour ships with a real provider behind it. An adapter so admitted may also implement the family's other audio behaviours.
>
> Its one beneficiary is ElevenLabs: `ALLM.Providers.ElevenLabs.Speech` (the first `stream_synthesize_input/3`) and `ALLM.Providers.ElevenLabs.Transcription` (the first `stream_transcribe/3`), each also implementing the non-streaming behaviour of its direction. See §37.7.4.
>
> **This is a carve-out, not a widening.** Both input-streaming callbacks now have a bundled implementation, so the criterion admits no second specialist: Deepgram, Cartesia, AssemblyAI and other audio providers stay out of core and ship as separate packages implementing the same behaviours. It admits nothing outside §37 — ElevenLabs gets no chat, image, embedding or moderation adapter by this route.

> **Phase 24 amendment (commits `7de1c1c..0c9c8b5`; docs land in the 24.5 commit).** The rule takes a **fourth scoped carve-out**, for the typed-classification family (§41), on the owner's decision to bundle TypeSafe in core rather than as a separate package.
>
> TypeSafe fails every criterion above: (a) it has no bundled chat adapter — its Jev model is not a chat model and generates no text; (b) no bundled provider names it as a partner; the Phase 22 family-shape rule requires the sole provider to be bundled for chat; and the Phase 26 carve-out admits nothing outside §37. Yet no bundled provider offers typed classification through a dedicated endpoint, so without an admission the §41 family would ship with no real provider behind its behaviour.
>
> The addition:
>
> > An adapter from a provider with no bundled chat adapter may be bundled into the classification family (§41), as its **sole** member, when (i) no bundled provider offers typed classification through a dedicated endpoint, (ii) the provider's API for it is a single, documented HTTP surface, and (iii) the capability's absence on every bundled chat provider is documented rather than backfilled with a proxy.
>
> Its one beneficiary is `ALLM.Providers.TypeSafe.Classification` (§41.7). It sits **alongside** the Phase 26 carve-out and does not generalise it: it covers both admission and family shape for §41 only, exempting the classification family from the Phase 22 carve-out's *"already bundled for chat"* condition and from nothing else.
>
> **This is a carve-out, not a widening.** Condition (i) closes it behind its beneficiary: once one provider is bundled, a second TypeSafe-shaped provider for the same capability is not admitted by this route, and third-party classification providers ship as separate packages implementing `ALLM.ClassificationAdapter`. It admits nothing outside §41 — TypeSafe gets no chat, image, embedding, moderation or audio adapter by this route. Condition (iii) forbids satisfying the family's shape with an LLM-backed classification adapter over a bundled chat provider, whose probabilities would be invented rather than calibrated.

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

## 37. v0.6 — Audio: speech synthesis and transcription

> **Phase 25 amendment (commits `da277bf..e91cdb0`; docs land in the 25.6 commit).** This section is new. §37 was reserved for audio when the v0.4-era audio design (`steering/PHASE_19_DESIGN.md`, never built) was written; that design is superseded by `steering/2026-09-24_SST_SUPPORT.md`. This section amends §27 (module tree), §29 (telemetry), §32.5 and §33 (audio struck from out-of-scope). §35.7 is **not** amended: both audio providers are already bundled for chat, so every new adapter qualifies under its existing criterion.

v0.6 adds two request/response audio primitives: `ALLM.synthesize/3` (text-to-speech, TTS) and `ALLM.transcribe/3` (speech-to-text, STT). Structurally the section is the moderation family (§39) twice over — Layer A request/response pair, a per-capability behaviour and error enum, an engine slot, a façade, a telemetry span, a Fake, and a published conformance suite — plus four things that family does not have:

- a **binary payload** crossing the serializer (`ALLM.Audio`, §37.2.1);
- a **multipart upload** (OpenAI STT);
- a provider whose **transcription is prompted chat** (Gemini `generateContent`), whose output is a language model's answer rather than a dedicated model's transcript (§37.7.3);
- **per-slot models on the engine** (§37.4), because an audio model never shares the chat model's namespace.

There is no Layer D: audio carries no conversation state and `ALLM.Session` is untouched.

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Streaming audio is added as **§37.11**, and ElevenLabs joins the bundled audio adapters (§37.7.4) under a new scoped §35.7 carve-out. This amendment also touches §8 (a pointer: the audio event unions are not `ALLM.Event`), §27 (module tree), §29 (telemetry), §32.5 and §33 (streaming audio struck from out-of-scope), §37.2.5 (`:unsupported_feature`), §37.7 (provider matrix) and §37.10 (two items struck). The design is `steering/2026-09-25_ELEVENLABS_TTS_SST.md`; its probe-corrected wire facts are what this section states.

### 37.1 Design goals

1. **One behaviour per capability.** `ALLM.SpeechAdapter` and `ALLM.TranscriptionAdapter` are separate behaviours with separate engine slots (`:speech_adapter`, `:transcription_adapter`), so one engine can pair providers per direction (e.g. Gemini STT with OpenAI TTS). A single `AudioAdapter` with an operations enum was rejected: one slot could not serve two providers, and every adapter would need an unsupported-operation path.
2. **Non-streaming.** Both providers can stream TTS audio, but neither shape fits the closed `ALLM.Event` union (§8), and adding a variant breaks every reducer. `SpeechRequest` has no `:stream` field, and a `stream: true` opt is silently ignored, as for `embed/3` and `moderate/3`. Streaming TTS is deferred to its own design.
   > **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Decided in §37.11: streaming is a separate set of façades over two new closed event unions outside `ALLM.Event`, so no chat reducer changes. `synthesize/3` and `transcribe/3` stay non-streaming and are unchanged; there is still no `:stream` field, and `stream: true` is still ignored.
3. **Opt-in per engine.** An engine without the slot returns `{:error, %ALLM.Error.EngineError{reason: :no_speech_adapter | :no_transcription_adapter}}` ahead of every other gate. No fallback to `:adapter` or any other slot.
4. **No voice catalogue.** Voice names are provider strings forwarded verbatim. OpenAI's valid set differs per model (`tts-1` rejects voices the newer models accept) and Gemini's names are disjoint from OpenAI's, so a library-side enum would be wrong for at least one model.
5. **Reuse engine plumbing.** Keys (§6.4), retries, telemetry (§29) and deterministic fakes (§31) apply unchanged. No capability pre-flight is added: `llm_db` has no audio capability keys to check (§6.3), and inventing them would be speculative.

### 37.2 Data model

#### 37.2.1 `ALLM.Audio`

```elixir
defmodule ALLM.Audio do
  @type source :: {:binary, binary()} | {:base64, String.t()} | {:file, Path.t()}
  @type t :: %__MODULE__{source: source(), mime_type: String.t() | nil, metadata: map()}

  @enforce_keys [:source]
  defstruct [:source, :mime_type, metadata: %{}]

  @spec from_file(Path.t()) :: t()                 # no I/O; MIME from extension, else nil
  @spec from_binary(binary(), String.t()) :: t()
  @spec from_base64(String.t(), String.t()) :: t()
  @spec to_binary(t()) :: {:ok, binary()} | {:error, :invalid_base64 | :invalid_source | File.posix()}
  @spec size(t()) :: {:ok, non_neg_integer()} | {:error, :invalid_base64 | :invalid_source | File.posix()}
end
```

One value type serves both directions — the STT input and the TTS output — following `ALLM.Image`, which is both the vision input and the image-generation output. It mirrors `ALLM.Image` minus the `{:url, _}` source (neither provider accepts an audio URL). A `{:binary, bytes}` source is base64-encoded on JSON, so non-UTF-8 audio round-trips; invalid base64 in a persisted `"binary"` source decodes to a `ValidationError` naming `[:source]`. `size/1` stats a `{:file, _}` source without reading it and returns `{:error, :eisdir}` for a directory. `Inspect` prints a byte count, never the payload.

#### 37.2.2 `ALLM.SpeechRequest` / `ALLM.SpeechResponse`

```elixir
defmodule ALLM.SpeechRequest do
  @type format :: :mp3 | :opus | :aac | :flac | :wav | :pcm | :ulaw | :alaw
  defstruct [:model, :voice, :format, :instructions, :speed, input: "", options: %{}, metadata: %{}]
  @spec formats() :: [format()]
end

defmodule ALLM.SpeechResponse do
  defstruct [:audio, :format, :id, :request_id, :model, :provider, :raw,
             usage: %ALLM.Usage{}, metadata: %{}]
  @spec mime_to_format(String.t() | nil) :: ALLM.SpeechRequest.format() | nil
  @spec format_to_mime(ALLM.SpeechRequest.format()) :: String.t()
end
```

- `:format` is a closed enum naming **file formats**, not a provider parameter; `nil` means "provider default". The six atoms are exactly OpenAI's `response_format` values; a future adapter maps them onto its own wire or refuses the ones it cannot produce.
- `SpeechResponse.format` is **derived from the response content type** via `mime_to_format/1`, not echoed from the request, and is `nil` when the MIME type is outside the table. The request says what was asked for; the response says what arrived.
- `SpeechResponse.usage` is never `nil`. OpenAI's non-streaming TTS body is raw audio with no usage, so its counts are all `nil`.
- The audio bytes live once, in `:audio`. `:raw` is `nil` for OpenAI TTS.

> **v0.6.0 amendment (commit `6e97db3`).** `:format` gains the two G.711 telephony formats `:ulaw` and `:alaw` (8 kHz, the only rate either provider offers), so the enum has eight atoms and the "six atoms are exactly OpenAI's `response_format` values" bullet above now describes only the first six. `format_to_mime/1` maps `:ulaw` → `audio/basic` (RFC 2046) and `:alaw` → `audio/alaw`; `mime_to_format/1` also reads `audio/ulaw` (ElevenLabs' observed 200 `content-type`) as `:ulaw`. ElevenLabs sends them as `ulaw_8000` / `alaw_8000` on the sync, `/stream` and `/stream-input` endpoints and refuses any other `:sample_rate` with `:unsupported_feature` (field `:sample_rate`); OpenAI has no G.711 output and refuses both with `:unsupported_feature` (field `:format`) before any I/O and before key resolution. The enum is closed, so this is breaking for an exhaustive `case` on `SpeechRequest.format()`.

#### 37.2.3 `ALLM.TranscriptionRequest` / `ALLM.TranscriptionResponse`

```elixir
defmodule ALLM.TranscriptionRequest do
  defstruct [:audio, :model, :language, :prompt, options: %{}, metadata: %{}]
end

defmodule ALLM.TranscriptionResponse do
  defstruct [:language, :duration_seconds, :id, :request_id, :model, :provider, :raw,
             text: "", usage: %ALLM.Usage{}, metadata: %{}]
end
```

- `:text` is the transcript. Output is **text only**: word/segment timestamps, diarization and `srt`/`vtt` are model-specific and out of scope; the provider body stays on `:raw`.
- `:usage` is an `%ALLM.Usage{}`, **never `nil`** (the `EmbeddingResponse` rule). Providers that bill by the second report it on the typed `:duration_seconds` field instead of tokens (OpenAI `whisper-1` and `gpt-transcribe`: `{"type": "duration", "seconds": n}`); token-billed models populate `:usage` (OpenAI `gpt-4o-mini-transcribe`, Gemini). A typed field survives JSON round-trip without the atom/string key drift `Usage.extra` would have.

#### 37.2.4 `options` — a raw provider-body passthrough

On both request structs, `:options` reaches provider fields ALLM does not model without a library release. It is merged **under** the fields the adapter sets, so it can never override one. Fields that would change the response *shape* the decoder relies on are also reserved and dropped with a deferred debug log: OpenAI TTS `stream_format`, OpenAI STT `response_format`. Placement per adapter: OpenAI TTS top-level JSON; OpenAI STT one multipart form field per entry; Gemini STT deep-merged into `generationConfig`.

#### 37.2.5 Errors and enum extensions

`ALLM.Error.SpeechAdapterError` (10 reasons) and `ALLM.Error.TranscriptionAdapterError` (the same 10 plus `:content_filter`), one type per capability as for images, embeddings and moderation, so each façade and conformance suite can pattern-match on the error module:

```elixir
:authentication_failed | :rate_limited | :invalid_request | :context_length_exceeded
| :provider_unavailable | :timeout | :network_error | :malformed_response
| :unsupported_feature | :unknown
# TranscriptionAdapterError adds :content_filter
```

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Both enums gain `:unsupported_feature` (Phase 25 shipped 9 and 10 reasons; the counts above are current). It is returned, before any I/O and before key resolution, for a request field the provider cannot express: ElevenLabs `:instructions`, `format: :aac | :flac`, a `:sample_rate` outside the format's set, and `TranscriptionRequest.prompt`; OpenAI a `:sample_rate` other than `nil`/24,000 for `:pcm`/`:wav` or any non-`nil` rate for other formats. ElevenLabs' tier-gate 403 (`subscription_required`) classifies to it too. Both are closed enums, so this is breaking for an exhaustive `case`.

> **v0.6.0 amendment (commits `94f427d`, `6e97db3`).** Two classification changes. (a) ElevenLabs' 403 `invalid_output_format` (`detail.type` `validation_error`, observed 2026-09-27 for an `output_format` the provider does not offer) now classifies to `:unsupported_feature`; it was `:authentication_failed` (`6e97db3`). OpenAI's `:ulaw` / `:alaw` refusal (§37.2.2) is also `:unsupported_feature`. (b) The chat stream adapters (OpenAI on both endpoints, Anthropic, Gemini) no longer classify a streamed 4xx/5xx from the status alone: the error body and headers are buffered to the transport's `:done` and classified with the same `(status, body, headers)` classifier the non-streaming path uses, so a streamed error carries the provider's message (key material redacted), `retry_after_ms` and the body-keyed reasons, as the speech streams already did (§37.11.8). A halted chat stream now also drains its Finch messages (`94f427d`). Streams are still never retried, so `retry_after_ms` on a streamed 429 is informational.

There is no `:batch_too_large`: neither endpoint takes more than one input per call, so neither behaviour has a `max_batch_size/0`.

Closed enums extended (breaking for an exhaustive `case`): `EngineError` gains `:no_speech_adapter`, `:no_transcription_adapter`; `ValidationError` gains `:invalid_speech_request`, `:invalid_transcription_request`. `ALLM.Serializer` registers the seven new modules.

#### 37.2.6 Validation

`ALLM.Validate.speech_request/1`: `:input` a non-empty, valid UTF-8 binary (`{:input, :empty}`, `{:input, :invalid_encoding}`; a non-binary hard-rejects as `:invalid_shape`); `:model`, `:voice`, `:instructions` `nil` or binary; `:format` `nil` or in `formats/0` (`{:format, :unknown}`); `:speed` `nil` or a number > 0 (`{:speed, :out_of_range}`). Voice names and per-provider speed ranges are not checked.

`ALLM.Validate.transcription_request/1`: `:audio` an `%ALLM.Audio{}` (hard-reject otherwise) whose `:source` is one of the three shapes with a binary payload; `:model`, `:language`, `:prompt` `nil` or binary. File existence, byte size and MIME type are **adapter** gates (§37.3), because the limits are per provider.

### 37.3 Behaviours

```elixir
defmodule ALLM.SpeechAdapter do
  @callback synthesize(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, ALLM.SpeechResponse.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}
  @callback prepare_request(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}
  @optional_callbacks prepare_request: 2
end

defmodule ALLM.TranscriptionAdapter do
  @callback transcribe(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, ALLM.TranscriptionResponse.t()} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
  @callback max_audio_bytes() :: pos_integer()
  @callback prepare_request(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
  @optional_callbacks prepare_request: 2
end
```

The numbered invariants live in each behaviour's `@moduledoc`; the load-bearing ones:

- **Return shape.** Exactly `{:ok, response}` or `{:error, capability_error}`. The one exception is `ALLM.Keys.fetch!/2` raising `EngineError{reason: :missing_key}`. The façade raises `ArgumentError` on any other shape.
- **Speech success.** `response.audio` is `%ALLM.Audio{source: {:binary, bytes}}` with `byte_size(bytes) > 0` and a `:mime_type` beginning `audio/`; a successful HTTP response whose payload is not audio, or whose body is empty, is `:malformed_response`. (The streaming mapping of an empty clip differs, §37.11.3: `:invalid_request` with `metadata.cause: :empty_input`. `ALLM.Providers.FakeSpeech` mirrors each path: this corrects `8bfc7d5`, which gave its batch path the stream error.) `response.format` is `nil` or in `SpeechRequest.formats/0`, derived via `mime_to_format/1`.
- **Speech empty input** is `:invalid_request` before any I/O and before `ALLM.Keys.fetch!/2`.
- **Transcription gate order.** All before `ALLM.Keys.fetch!/2`: **resolvable** (unresolvable audio → `:invalid_request` with `metadata.cause`) → **size** (over `max_audio_bytes/0` → `:invalid_request` with `metadata.count` and `metadata.max`) → **MIME** (adapter-specific) → key. MIME acceptance is not a behaviour invariant because the accepted set differs per provider.
- `opts[:request_id]` reflects onto `response.request_id`; `request.metadata` round-trips onto `response.metadata`; `opts[:request_timeout]` expiry is `:timeout`.
- **Cleanup: none.** `Req.request/1` owns the connection lifecycle.

### 37.4 Engine integration

Four `ALLM.Engine` fields, all serializable (no key ever lives on the engine):

| Field | Type |
|-------|------|
| `:speech_adapter` | `module() \| nil` |
| `:transcription_adapter` | `module() \| nil` |
| `:speech_model` | `String.t() \| nil` |
| `:transcription_model` | `String.t() \| nil` |

**Each audio slot carries its own model, and the audio façades never read `engine.model`.** `engine.model` is the chat model, and an audio model never shares its namespace: a Gemini chat model sent to a Gemini TTS request returns 200 with a *text* part instead of audio (probed 2026-09-24). Resolution, normative: `request.model || engine.<slot>_model`, then the adapter's own default when still `nil`. On the string/`%Audio{}` call shapes `opts[:model]` reaches `request.model`; a pre-built request is authoritative and not merged. This is the one place the audio façades differ from `generate_image/3`, `embed/3` and `moderate/3`, which fall back to `engine.model`. Per-slot fields keep each adapter's model persisted with its adapter, so a serialized engine pairing a chat provider with two different audio providers round-trips intact.

### 37.5 Public API

```elixir
@spec speech_request(String.t(), keyword()) :: ALLM.SpeechRequest.t()
@spec synthesize(ALLM.Engine.t(), String.t() | ALLM.SpeechRequest.t(), keyword()) ::
        {:ok, ALLM.SpeechResponse.t()}
        | {:error, ALLM.Error.EngineError.t() | ALLM.Error.ValidationError.t() | ALLM.Error.SpeechAdapterError.t()}

@spec transcription_request(ALLM.Audio.t(), keyword()) :: ALLM.TranscriptionRequest.t()
@spec transcribe(ALLM.Engine.t(), ALLM.Audio.t() | ALLM.TranscriptionRequest.t(), keyword()) ::
        {:ok, ALLM.TranscriptionResponse.t()}
        | {:error, ALLM.Error.EngineError.t() | ALLM.Error.ValidationError.t() | ALLM.Error.TranscriptionAdapterError.t()}
```

- The `*_request/2` builders read only the struct's own field names from opts (an **allow-list**), so call-control opts (`:request_id`, `:request_timeout`, `:retry`, `:adapter_opts`, `:api_key`, `:stream`) never land on the struct.
- **Gate order:** empty slot → `EngineError`; `Validate.*_request/1` → `ValidationError`; dispatch under the retry policy. Unknown opts are forwarded to the adapter untouched.
- **Retry:** `:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error` are retried under the engine's `:retry` policy; every other reason (including `:content_filter`) surfaces immediately. The bundled transcription adapters make **one** HTTP attempt per call, because each attempt re-uploads the clip, so the façade's loop is the only one (at most 3 uploads at the default policy). `ALLM.Providers.OpenAI.Speech` is the opposite case: it runs its own `ALLM.Retry.run/3` per call (`lib/allm/providers/openai/speech.ex`, moduledoc "Retry"), whose default policy retries `:timeout` only, so through `ALLM.synthesize/3` a synthesis `:timeout` costs up to **9** attempts at the default policy against 3 for the other retryable reasons — the same nested-loop shape as `embed/3`.
- `opts[:request_id]` wins over a generated id, and fills `response.request_id` only when the adapter left it `nil`.

### 37.6 Limits

| Adapter | Limit | Source |
|---------|-------|--------|
| `OpenAI.Speech` | input ≤ **4096 Unicode code points**, gated before key resolution as `:context_length_exceeded` with `metadata.count`/`max`; a provider 400 naming `string_too_long` maps to the same reason | documented limit; unit settled by probe (2049 × `e`+U+0301 rejected, 4096 × U+00E9 accepted) |
| `OpenAI.Transcription` | `max_audio_bytes/0` = **26,148,864** (25 MiB whole-body cap minus 64 KiB for the rest of the form) | probe ladder: 413 *"Maximum content size limit (26214400) exceeded"*; no duration cap found at 1800 s |
| `Gemini.Transcription` | `max_audio_bytes/0` = **15,679,488** (the raw size whose base64 fits 20 MiB minus 64 KiB) | documented 20 MB inline limit; a 15,831,040-byte clip was accepted, so the cap is conservative |
| `FakeTranscription` | `max_audio_bytes/0` = 1024, overridable via `adapter_opts[:max_audio_bytes]` | test vehicle |

Gemini documents no per-request TTS character limit (and Gemini TTS is not bundled). No batching: both endpoints take one input per call.

### 37.7 Provider adapters in v0.6

| Adapter | Endpoint | Default model |
|---------|----------|---------------|
| `ALLM.Providers.OpenAI.Speech` | `POST /v1/audio/speech`, JSON | `gpt-4o-mini-tts`; voice `"alloy"` when `nil` |
| `ALLM.Providers.OpenAI.Transcription` | `POST /v1/audio/transcriptions`, multipart | `gpt-transcribe` |
| `ALLM.Providers.Gemini.Transcription` | `POST …/models/<model>:generateContent`, inline audio | `gemini-flash-latest` |

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** The matrix gains ElevenLabs (admitted under the §35.7 audio carve-out; §37.7.4) and the streaming columns of §37.11:

| Adapter | `synthesize/3` / `transcribe/3` | `stream_synthesize/3` | `stream_synthesize_input/3` | `stream_transcribe/3` | Default model |
|---------|------|------|------|------|------|
| `ALLM.Providers.OpenAI.Speech` | yes | yes — the same `POST /v1/audio/speech`, chunked | — (OpenAI's text-in streaming is its Realtime API; out of scope) | — | `gpt-4o-mini-tts` |
| `ALLM.Providers.OpenAI.Transcription` | yes | — | — | — | `gpt-transcribe` |
| `ALLM.Providers.Gemini.Transcription` | yes | — | — | — | `gemini-flash-latest` |
| `ALLM.Providers.ElevenLabs.Speech` | yes — `POST /v1/text-to-speech/{voice_id}` | yes — `POST …/{voice_id}/stream`, chunked | yes — `wss://…/{voice_id}/stream-input` | — | `eleven_flash_v2_5`; voice `JBFqnCBsd6RMkjVDRZzb` when `nil` |
| `ALLM.Providers.ElevenLabs.Transcription` | yes — `POST /v1/speech-to-text`, multipart | — | — | yes — `wss://…/v1/speech-to-text/realtime` | `scribe_v2` (batch); `scribe_v2_realtime` (realtime) |

Gemini TTS was probed and works, but is **not bundled** in v0.6. Anthropic has no audio endpoint. Every injected default is stated in the adapter's public `@doc` and its body builder's `@doc false`.

#### 37.7.1 OpenAI speech

The 200 body is raw audio; `response.format` comes from its `content-type`. The 401 is sent as `text/plain`. Unknown body fields are **ignored** (200), so on OpenAI request acceptance confirms nothing and only response observables settled wire rows.

#### 37.7.2 OpenAI transcription

`response_format` is always `json`. The upload is named by the file's basename for a `{:file, _}` source, else `audio.<ext>` from the MIME type; OpenAI picks the decoder from the filename extension (a valid MP3 named `audio.bin` got 400 *"Unsupported file format bin"*), so a non-file source whose MIME type maps to no known extension is refused locally. Usage arrives as `{"type": "duration", …}` → `:duration_seconds` or `{"type": "tokens", …}` → `:usage`, per model. `languages[0].code` → `:language` where present.

#### 37.7.3 Gemini transcription — prompted chat

Gemini has no transcription endpoint. The adapter sends a fixed instruction ("Generate a verbatim transcript of this audio. Output only the transcript.") plus the audio as camelCase `inlineData`; `:language` is added as a one-sentence hint and `:prompt` as a context block. Consequences, all documented in the adapter moduledoc and `guides/audio.md`:

- **Not guaranteed verbatim.** An LLM transcript can paraphrase or tidy disfluencies where a Whisper-family model cannot.
- **Silence is not an empty transcript.** Given ~490 s of digital silence, the model returned fluent, invented speech (observed 2026-09-24 on `gemini-flash-latest`, which then resolved to `gemini-3.8-flash`). Non-empty text is not proof the clip contained speech.
- **Text** is the concatenation of the first candidate's `text` parts, excluding parts marked `"thought": true`. The decoder does not reuse the chat path's `Gemini.Decode.candidate_parts/1`, which turns every `inlineData` into an image part.
- **Finish reasons:** `MAX_TOKENS` returns `{:ok, response}` with the partial text and `metadata.finish_reason: :length`; `SAFETY`, `RECITATION` and other content-policy stops, and `promptFeedback.blockReason`, return `:content_filter` (recited material such as lyrics can trip `RECITATION`).
- **Accepted MIME types:** `audio/wav`, `audio/mpeg`, `audio/aiff`, `audio/aac`, `audio/ogg`, `audio/opus`, `audio/flac` (all but `aiff` probed), after parameter/case normalization.
- Unknown body fields are **rejected** (400 `Unknown name`), so a mistyped `:options` key surfaces as `:invalid_request`. A bad key is `API_KEY_INVALID` on a 400 and classifies as `:authentication_failed`. No request-id header came back on recorded responses; `responseId` → `:id`.
- Audio tokenizes at about 25 tokens per second (observed).

#### 37.7.4 ElevenLabs

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** New. Both adapters resolve the key as `:elevenlabs` (`ELEVENLABS_API_KEY`, through `ALLM.Keys`' `<PROVIDER>_API_KEY` fallback) after every local gate; auth is the `xi-api-key` header, including on the WebSocket upgrade. `opts[:base_url]` or `adapter_opts[:base_url]` selects a data-residency host. Probed 2026-09-26..27 by `scripts/record_elevenlabs_audio_fixtures.exs`; every row below is observed unless marked documented or inferred.

- **Speech request.** JSON `{"text", "model_id", "voice_settings"?: {"speed"}}`, voice in the URL path. `:options` merges under the structural fields (a `"voice_settings"` map merges with `speed`); `options["query"]` adds URL query parameters; `output_format`, `model_id` and `text` are reserved and dropped. Unknown body fields are **ignored** (200), so acceptance confirms nothing.
- **Format map** (`ALLM.Providers.Support.ElevenLabs.output_format/2`, the only home of the table): `:mp3`/`nil` → `mp3_22050_32 | mp3_24000_48 | mp3_44100_128` (default 44,100); `:opus` → `opus_48000_64`; `:pcm`/`:wav` → `pcm_<rate>`/`wav_<rate>` for 8,000, 16,000, 22,050, 24,000 (default), 32,000, 44,100, 48,000; `:ulaw`/`:alaw` → `ulaw_8000`/`alaw_8000` (8,000 only; v0.6.0 amendment, `6e97db3`); `:aac`, `:flac` → `:unsupported_feature`. 44.1 kHz PCM/WAV is tier-gated (observed 403 `subscription_required` / `output_format_not_allowed`, classified `:unsupported_feature`). The 200 `content-type` is `audio/mpeg`, `audio/pcm`, `audio/wav` or `audio/opus`, each mapping through `mime_to_format/1`, so `response.format` is derived from the response as §37.2.2 requires; `sample_rate` is the requested one (the response does not state it).
- **Correlation.** Speech: `request-id` header → `response.id`, `character-cost` header → `response.raw` as `%{"character_cost" => n}`. Transcription: no `request-id` header; `transcription_id` → `:id`. `usage` is all-`nil` on both.
- **Transcription.** Multipart `file`, `model_id`, `language_code`?; `:prompt` → `:unsupported_feature`. ElevenLabs sniffs the content (an MP3 named `audio.bin` transcribed correctly), so there is no filename/MIME gate. `language_code` is ISO 639-3 (`"eng"`), passed through. `max_audio_bytes/0` = 4,999,999,999 (documented "less than 5.0GB"; **not probed**). One attempt per call, as for the other transcription adapters.
- **Limits.** No local speech length gate (the limit is per model, documented 40,000 characters for flash, 5,000 for `eleven_v3`); the documented 400 `text_too_long` maps to `:context_length_exceeded` (documented only: a 5,001-character `eleven_v3` probe answered 200 and was billed, so no length arm runs).
- **Errors.** Envelope `{"detail": {"type", "code", "message", "status", "request_id", "param"?}}`; a 422 `detail` is a list. A body with `detail.type: "authentication_error"` is `:authentication_failed` whatever the status (an invalid key is a 400 or a 401 depending on its shape); quota/`payment_required` is `:invalid_request` (never retried); 429 `:rate_limited`; 5xx `:provider_unavailable`. Provider strings pass a redactor for the `sk_…` key shape (the invalid-key body does not echo the key; the redactor is defence in depth).
- **Retry.** `ElevenLabs.Speech.synthesize/2` runs its own `ALLM.Retry.run/3` per call, as `OpenAI.Speech` does (so a `:timeout` through `synthesize/3` costs up to 9 attempts at the default policy). Streams are never retried.

### 37.8 Testing

- `ALLM.Providers.FakeSpeech` and `ALLM.Providers.FakeTranscription` ship in `lib/`. With no script, speech returns the bytes `"FAKE-AUDIO:" <> input` (format `request.format || :mp3`) and transcription returns `text: ""`. Scripts under `adapter_opts[:speech_script]` / `[:transcription_script]` accept `{:ok, bytes | text}`, `{:ok, %Response{}}`, `{:error, %AdapterError{}}` and `{:retry_until_call, n}`. A non-empty script that runs dry returns `:unknown` with `metadata.cause: :speech_script_exhausted` / `:transcription_script_exhausted`, never a default answer. Cursors key on engine identity at the façade.
- The real adapters hand a call carrying a script key to the matching Fake **before** their own gates run; the transcription adapters pass their own cap as `adapter_opts[:max_audio_bytes]` so a real clip is not rejected by the Fake's 1024-byte default.
- Published conformance suites: `ALLM.Test.SpeechAdapterConformance` (6 cases) and `ALLM.Test.TranscriptionAdapterConformance` (6 cases), run against both Fakes and all three real adapters.
- Recorded fixtures: OpenAI TTS returns raw audio, so each `recorded/` TTS fixture is a JSON envelope (`status`, `headers`, `body_base64`, `byte_size`, `sha256`). Recorders `scripts/record_openai_audio_fixtures.exs` and `scripts/record_gemini_audio_fixtures.exs` carry the live wire probes.

### 37.9 Telemetry

See the §29 amendment: `[:allm, :synthesize, …]` and `[:allm, :transcribe, …]` spans. The `:synthesize` `:stop` metadata carries the whole response, **including the audio bytes**; handlers should read the `audio_bytes` measurement rather than ship `metadata.response`.

### 37.10 Out of scope for v0.6

- ~~**streaming TTS / real-time STT** — needs an event-protocol decision (§8)~~ (struck by the Phase 26 amendment: see §37.11)
- **OpenAI `/v1/audio/translations`** — English-only, `whisper-1`-only
- **timestamps, diarization, `srt`/`vtt`** — model-specific; `response.raw` carries the body
- **OpenAI custom voices** (`{"id": "voice_…"}`) — gated behind OpenAI's approval process; reachable later through `:options`
- **Gemini TTS** — probed and working; deferred to a later phase
- ~~**ElevenLabs TTS / STT** — not bundled for chat, so admission needs a §35.7 criterion; the contracts (string voices, file-format atoms, per-slot models) were checked against its shape~~ (struck by the Phase 26 amendment: admitted under the §35.7 audio carve-out; see §37.7.4)
- **Gemini Files API for audio above the inline cap** — a second upload round trip
- **`ALLM.Audio.from_url/1`** — neither provider accepts an audio URL
- **audio as a chat `Message` content part** — a chat-adapter change across both OpenAI translators and Gemini's
- **capability pre-flight** — no `llm_db` audio capability keys exist
- **a voice catalogue** — §37.1 item 4
- **`ALLM.Session` integration** — no conversation state

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** Still out of scope after streaming shipped: OpenAI STT streaming and OpenAI Realtime; Gemini TTS and any Gemini streaming; `ulaw`/`alaw` telephony formats (`SpeechRequest.formats/0` stays closed); word/character alignment (a new `SpeechEvent` variant, breaking for that union's reducers); ElevenLabs multi-context `/multi-stream-input` (barge-in); single-use tokens for browser clients; voice cloning and voice-library CRUD; batch STT diarization/keyterms/timestamps (reachable through `:options`, body on `:raw`); WebSocket pooling and connection pre-warming; retrying a stream after it has opened; `ALLM.Session` integration.

> **v0.6.0 amendment (commit `6e97db3`).** `ulaw`/`alaw` telephony formats are no longer out of scope: `SpeechRequest.formats/0` gains `:ulaw` and `:alaw` (§37.2.2). The rest of the list above stands.

### 37.11 Streaming audio

> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).** New. The latency-critical voice loop is: microphone PCM → `stream_transcribe/3` → the committed transcript → `ALLM.stream/3` → `AudioStream.text_deltas/1` → `stream_synthesize_input/3` → audio chunks. Transcription must complete before the chat call (it needs the whole question); chat and speech overlap.

#### 37.11.1 Event unions

Two new closed unions, **outside** `ALLM.Event` (§8), so no chat reducer changes:

```elixir
defmodule ALLM.SpeechEvent do
  @type t ::
          {:speech_started, %{request_id, model, provider, format, mime_type, sample_rate}}
          | {:audio_delta, binary()}                      # non-empty
          | {:speech_completed, %{request_id, id, usage, metadata}}
          | {:error, ALLM.Error.SpeechAdapterError.t()}
end

defmodule ALLM.TranscriptionEvent do
  @type t ::
          {:transcription_started, %{request_id, model, provider, session_id}}
          | {:partial_transcript, %{text: String.t()}}
          | {:committed_transcript, %{text: String.t(), language: String.t() | nil}}
          | {:transcription_completed, %{text, language, duration_seconds, request_id, usage, metadata}}
          | {:error, ALLM.Error.TranscriptionAdapterError.t()}
end
```

- **Grammar.** Speech success is `speech_started · audio_delta+ · speech_completed`; transcription success is `transcription_started · (partial* · committed)* · partial* · transcription_completed`. A failure ends `…· {:error, err}`, and nothing follows a terminal event. A speech stream whose input yields no text, or whose provider sends zero audio bytes, ends `:invalid_request` with `metadata.cause: :empty_input`, so a successful speech stream always has ≥ 1 delta.
- **Semantics.** A partial **replaces** the previous partial of the current segment; a committed segment is final and **appended**. `completed.text` is normative: each committed text `String.trim/1`-ed, empties dropped, joined with one space (the adapter computes it). Streaming `duration_seconds` is **computed** as `bytes_sent / (sample_rate * 2)`, not provider-reported.
- **Serializability.** Both unions round-trip `:erlang.term_to_binary/1` and are **not** JSON-encoded (`:audio_delta` carries raw bytes); they are not registered with `ALLM.Serializer`. Adding a variant is breaking for reducers of that union, the §8 rule. Constructors (`speech_started/1`, `audio_delta/1` — raises on `""` —, `transcription_started/1`, `committed_transcript/2`, …) and `event?/1` mirror `ALLM.Event`'s style; `event?/1` on `{:error, _}` accepts only the family's own error struct.

#### 37.11.2 Layer A additions

- `ALLM.TranscriptionStreamRequest` — `%{model, language, sample_rate: 16_000, commit_strategy: :vad | :manual, options: %{}, metadata: %{}}`, a bare `struct!/2` constructor, `commit_strategies/0`. JSON-serializable and registered with the serializer; `__from_tagged__/1` decodes the two truthy defaults explicitly, so a persisted `8_000`/`:manual` survives.
- `SpeechRequest` and `SpeechResponse` gain `:sample_rate` (`pos_integer() | nil`). `nil` on the request means the adapter's default for the format; adapters report the actual rate on the response and on `:speech_started`. **The cross-provider PCM default is 24,000 Hz** (OpenAI PCM is fixed at 24 kHz), so switching providers never changes a playback rate silently.
- `ALLM.Validate.speech_request/2` (`speech_request/1` delegates with `[]`); `input: :streamed` skips the three `:input` rows. `:sample_rate` not `nil`/`pos_integer()` → `{:sample_rate, :out_of_range}`. `ALLM.Validate.transcription_stream_request/1`: `:sample_rate` (`:out_of_range`), `:commit_strategy` (`:unknown`), `:model`/`:language` (`:invalid_shape`), `:options`/`:metadata` (`:invalid_shape`). Both reuse the existing `:invalid_speech_request` / `:invalid_transcription_request` reasons.

#### 37.11.3 Behaviours

A module opts in to streaming by implementing a **second behaviour on the same engine slot**, detected with `Code.ensure_loaded?/1` + `function_exported?/3` (the chat precedent). `ALLM.Engine` is unchanged.

```elixir
defmodule ALLM.SpeechStreamAdapter do
  @callback stream_synthesize(ALLM.SpeechRequest.t(), keyword()) ::
              {:ok, Enumerable.t(ALLM.SpeechEvent.t())} | {:error, ALLM.Error.SpeechAdapterError.t()}
  @callback stream_synthesize_input(ALLM.SpeechRequest.t(), Enumerable.t(String.t()), keyword()) ::
              {:ok, Enumerable.t(ALLM.SpeechEvent.t())} | {:error, ALLM.Error.SpeechAdapterError.t()}
  @optional_callbacks stream_synthesize_input: 3
end

defmodule ALLM.TranscriptionStreamAdapter do
  @callback stream_transcribe(ALLM.TranscriptionStreamRequest.t(), Enumerable.t(binary() | :commit), keyword()) ::
              {:ok, Enumerable.t(ALLM.TranscriptionEvent.t())} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
  @callback stream_sample_rates() :: [pos_integer()]
end
```

Normative invariants (numbered in each moduledoc):

1. The synchronous return is exactly `{:ok, enumerable}` or `{:error, capability_error}`; `ALLM.Keys.fetch!/2` raising is the one exception.
2. **Lazy.** No I/O until the enumerable is reduced. Pre-flight gates return `{:error, _}` synchronously, before `Keys.fetch!/2` and before the enumerable is returned.
3. The enumerable obeys the union's grammar.
4. **Halt-safe.** A consumer halt releases the transport (Finch ref cancelled, or socket closed and input pump stopped). On WebSocket and input-pump paths it leaves no stream-owned message in the consumer's mailbox. On HTTP paths the drain is best-effort: messages queued at the halt are removed, but Finch cancels asynchronously, so one late message from the cancelled request may still arrive.
5. `opts[:stream_timeout]` (ms of silence, default 60,000) resets on every transport message **and** every input element, so a slow input does not time out a waiting socket; expiry ends the stream `:timeout`.
6. `opts[:request_id]` appears on the start and terminal events; `request.metadata` on the terminal event.
7. **Input.** An element of the wrong shape (non-UTF-8-string for speech; neither a binary nor `:commit` for transcription) ends the stream `:invalid_request`, `metadata.cause: :invalid_input_chunk`; an empty text chunk is skipped. An input that raises, throws or exits ends it with `:input_raised`, and a crash of a process linked inside the input with `:input_crashed`; `err.cause` is then `%{kind: :error | :throw | :exit, message: String.t()}`, never the raw term (pids and refs are forbidden on Layer A and are not JSON-encodable). The consumer process is never killed. Transcription chunk boundaries are the caller's: an odd trailing byte is carried to the next chunk, and one left at the end of input is `:invalid_input_chunk`; a chunk over the adapter's maximum frame is split.
8. **End of input** (transcription). Uncommitted audio is committed, and the stream waits for the final committed segment before `:transcription_completed`.
9. **Ordering of I/O.** On a WebSocket path the socket is connected (and, for STT, the provider's session started) **before** the input is reduced, so a refused upgrade never reduces the input. A provider that accepts the upgrade and then rejects the key by an error frame (ElevenLabs does, on both endpoints) can still see the input reduced on the TTS path; the STT path waits for `session_started` and does not.

`stream_sample_rates/0` plays the role of `max_audio_bytes/0`: a caller checks it before opening a microphone. The input is reduced by `ALLM.Providers.Support.InputPump` in a helper process (unlinked, monitored, with a watchdog and a credit window, default 8) so the consumer can keep reading the socket while the input blocks. **Consequence for callers:** an input that reads the caller's mailbox or process dictionary must be relayed (subscribe from inside the stream's start function). A halt kills the pump; a killed process runs no after functions, so the input's own resources are released by process exit.

#### 37.11.4 Façades

```elixir
@spec stream_synthesize(Engine.t(), String.t() | SpeechRequest.t(), keyword()) ::
        {:ok, Enumerable.t(SpeechEvent.t())} | {:error, EngineError.t() | ValidationError.t() | SpeechAdapterError.t()}
@spec stream_synthesize_input(Engine.t(), Enumerable.t(String.t()), keyword()) ::
        {:ok, Enumerable.t(SpeechEvent.t())} | {:error, EngineError.t() | ValidationError.t() | SpeechAdapterError.t()}
@spec stream_transcribe(Engine.t(), Enumerable.t(binary() | :commit), keyword()) ::
        {:ok, Enumerable.t(TranscriptionEvent.t())} | {:error, EngineError.t() | ValidationError.t() | TranscriptionAdapterError.t()}
```

- **Request construction.** `stream_synthesize/3` reuses `speech_request/2`'s allow-list. The input forms build from their struct's field opts, or take `opts[:request]` (authoritative; any other value than the expected request struct raises `ArgumentError` before the span opens — a caller bug, not a runtime condition). `stream_transcribe/3`'s allow-list is all six `TranscriptionStreamRequest` fields.
- **Gate order**, each synchronous: (1) nil slot → `EngineError :no_speech_adapter | :no_transcription_adapter`; (2) the slot lacks the callback → `EngineError :missing_stream_adapter` (the chat atom, reused; `stream_synthesize_input/3` also fires it for an adapter that streams whole texts only); (3) input forms only: a binary or non-enumerable input → `ValidationError` with `{:input, :invalid_shape}`; (4) the validator; (5) model stamping; (6) dispatch.
- **Model resolution.** `stream_synthesize*` use `request.model || engine.speech_model`, then the adapter default. **`stream_transcribe/3` never reads `engine.transcription_model`**: batch and realtime model namespaces are disjoint (ElevenLabs `scribe_v2` vs `scribe_v2_realtime`), so it is `request.model`, else the adapter's realtime default.
- **No retry.** No `Retry.run/3` on any stream path; a stream is never retried after it opens.
- **Wrapping.** The returned enumerable is wrapped once: it emits `[:allm, :audio, :first_chunk]` at the first `:audio_delta` / `:partial_transcript`, and raises `ArgumentError` naming the adapter if an element is not an event of the union (or if the synchronous return violates invariant 1).

#### 37.11.5 Mid-stream errors do not fold into a response

Deliberately unlike chat (§10.1's fold into `finish_reason: :error`): a stream that fails after opening ends with a terminal `{:error, err}` event, and `ALLM.AudioStream.collect_speech/1` / `collect_transcription/1` return `{:error, err}`. `SpeechResponse` has no `finish_reason`, and a half-rendered clip is not a valid `SpeechResponse`. What arrived is on the error's metadata: `bytes_received` (speech) or `committed_text` (transcription). Audio bytes never enter an error (errors derive `Jason.Encoder`; raw audio is not UTF-8). Only pre-flight failures are synchronous `{:error, _}`.

#### 37.11.6 `ALLM.AudioStream`

Layer C, pure. `collect_speech/1` folds a speech stream into the `SpeechResponse` `synthesize/3` would return (format, mime, rate, model and provider from `:speech_started`; the rest from `:speech_completed`; a stream without a terminal event is `:malformed_response`). `collect_transcription/1` folds a transcription stream into a `TranscriptionResponse` (`id` is the realtime `session_id`); unlike speech, a missing `:transcription_started` is not an error — the response comes back with `model`, `provider` and `id` nil, since the transcript rides the completed event. `text_deltas/1` maps chat `{:text_delta, %{delta: d}}` to `d` and drops everything else; a chat `{:error, err}` **raises** (`ALLM.AudioStream.ChatStreamError`, carrying the reason and message, never the struct), so a TTS stream fed a failed chat stream ends `:input_raised` and a truncated answer is never spoken as a successful clip.

#### 37.11.7 Stream-first, as an equivalence property

`synthesize/3` and `transcribe/3` are **not** re-routed through the streams: every bundled provider streams on a different endpoint (ElevenLabs) or not at all (Gemini, OpenAI STT). §3's stream-first rule is honoured in testable form instead: a StreamData property over the Fakes asserts `synthesize(e, r) ≡ stream_synthesize(e, r) |> collect_speech` (bytes, format, sample rate, model, provider, usage, request id, metadata) and `transcribe(...).text ≡ stream_transcribe(...) |> collect_transcription |> .text`.

#### 37.11.8 Transport

- **HTTP streaming** (OpenAI `/v1/audio/speech`, ElevenLabs `/stream`): `Finch.async_request/3` on the HTTP/1 `ALLM.Finch` pool, as for chat (§7.2). A non-2xx status's body is buffered to its end and classified with the non-streaming table, so the redactor and body-keyed rules see the message (since `94f427d` the chat stream adapters do the same, through the same `ALLM.Providers.Support.Transport.buffer_error_payload/2` helper; §37.2.5). Observed framing: OpenAI raw chunked audio (`gpt-4o-mini-tts`, 405 characters of PCM: 90 data messages, first at 1,728 ms), no SSE (`stream_format` stays reserved); ElevenLabs raw chunked audio (44 characters of `pcm_24000`: 26 messages from 425 ms).
- **WebSocket** (`ALLM.Providers.Support.WebSocket`, a behaviour; default `…WebSocket.Mint` over `:mint_web_socket`): an HTTP/1 connection opened **in the process that reduces the stream**, no helper process for the socket; the API key goes in the upgrade request's headers, **never the URL** (ElevenLabs also accepts `?authorization=`, which ALLM never uses: URLs reach logs and telemetry). Control frames (ping/pong) never leave the module. `:ws_module` is the test seam, as `:finch_module` is for Finch.

#### 37.11.9 ElevenLabs streaming wire (observed 2026-09-27)

- **`/stream-input` (text in).** Query `model_id`, `output_format`, `inactivity_timeout = min(180, ceil(stream_timeout / 1000))` (180 for `:infinity`) and `auto_mode=true` by default (`options["query"]` may override it). Initial message `{"text": " "}` plus `voice_settings`/other options; text frames `{"text": chunk}` with no space appended; end of input `{"text": "", "flush": true}` then `{"text": ""}`, answered by the last audio, `{"audio": null, "isFinal": true}` and a close 1000. Keep-alive `{"text": " "}` after half of `inactivity_timeout` without a client frame. **Latency default:** first audio 238 ms after the first text frame under `auto_mode`, 563 ms under the default `chunk_length_schedule` (one probe of `["Hel", "lo", " world", "."]`); `auto_mode` voices each frame as its own clip, so while it is on the adapter buffers text to a word boundary (whitespace, `! ? ;`, CJK full-width marks) and sends whole words only (whitespace includes the no-break space, and `? ! ;` split even inside a token, so a URL breaks after its `?`); `auto_mode` counts as on for `true` or any string equal to `"true"` ignoring case; with it off, chunks go verbatim (owner decision 2026-09-27). A bad or missing key and an unknown voice **upgrade with 101**, then send `{"code": 1008, "error": <code>, "message"}` and close 1008 (`invalid_api_key` / `authentication_required` → `:authentication_failed`, `voice_id_does_not_exist` → `:invalid_request`); a bare 1008 is `:invalid_request`; any other close before `isFinal` is `:network_error`. `eleven_v3` is refused **at the upgrade** (HTTP 400 `unsupported_model`, `:invalid_request`); there is no model fallback.
- **Realtime STT.** `wss://…/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_<rate>&commit_strategy=vad|manual[&language_code]`, other `options` as query parameters; `stream_sample_rates/0` = `[8_000, 16_000, 22_050, 24_000, 44_100, 48_000]`. Client frames `{"message_type": "input_audio_chunk", "audio_base_64", "commit", "sample_rate"}`, at most 1,000 ms of audio each (a 1,000 ms and an exploratory 3,000 ms chunk were accepted); `:commit` sends an empty-audio `commit: true` frame. Unpaced upload is accepted. The server does not close after the final commit (the adapter closes). A commit covering < 0.3 s of new audio is refused with `commit_throttled` and a close: mid-stream `:rate_limited`; after the end of input it completes the stream, and the adapter sends a final commit only when audio went out since the last one. Partials can arrive after their segment's commit. Timestamped commits (`committed_transcript_with_timestamps`) are sent only with `include_timestamps=true`, carry a language (ISO 639-1) only with `include_language_detection=true`, and arrive before or after their plain frame; with either option set, each segment is held until its language arrives or for at most 1,000 ms (`adapter_opts[:language_hold_ms]`, a positive integer, else a synchronous `:invalid_request`), paired by commit order (owner decision 2026-09-27); the `stream_timeout` silence deadline also releases a held segment, and a session complete but for the hold completes rather than ending `:timeout`; without them nothing is held and `language` is `nil`. A bad key upgrades with 101, then `auth_error` and a close 1000; the input is not reduced (the pump starts on `session_started`).

#### 37.11.10 Fakes and conformance

`FakeSpeech` and `FakeTranscription` implement both streaming behaviours, reduce input through the same `InputPump` (so a mailbox-dependent input fails under the Fake as in production), advance their script cursor at **call** time, and accept `{:events, [event]}` (emitted verbatim; `:unknown`/`:stream_only_script_entry` on the non-streaming path). `adapter_opts[:chunk_bytes]` (default 1,024) splits scripted speech bytes; `FakeTranscription.stream_sample_rates/0` = `[8_000, 16_000, 24_000]` (overridable by `adapter_opts[:stream_sample_rates]`). Real adapters hand a scripted call to the Fake before their own gates. Published suites, six cases each: `ALLM.Test.SpeechStreamAdapterConformance`, `ALLM.Test.SpeechInputStreamAdapterConformance` (only for adapters exporting the optional callback), `ALLM.Test.TranscriptionStreamAdapterConformance`. `ALLM.Test.TranscriptionAdapterConformance` gains `skip_cases:`; the ElevenLabs mount skips case 4 (its `max_audio_bytes() + 1` clip is 5 GB), and a sparse-file test binds that adapter's size gate instead.

#### 37.11.11 Telemetry

See the §29 amendment: `[:allm, :stream_synthesize, …]`, `[:allm, :stream_transcribe, …]` and the non-span `[:allm, :audio, :first_chunk]`.

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

**The `:flagged` decoder repairs rather than passes through, and it is the only one in the family that does.** On the JSON decode path (`ALLM.Serializer.from_json/1`) a `"flagged"` that is not a boolean — absent, `null`, the string `"true"`, a truncated or tampered payload — deserializes to `false`. The declared `t:boolean/0` is preserved rather than admitting a `nil`, and a decode glitch cannot manufacture a `true` that blocks legitimate content. Two consequences are stated in the public docs because both invert a reflex carried over from §36. First, a corrupted persisted verdict deserializes to *clean* rather than to a decode error, and **the repair is silent**: `:categories` and `:category_scores` decode independently of `:flagged`, so a tampered payload — or one carrying the string `"true"` — comes back `flagged: false` beside a fully populated category map, with nothing in the struct marking it as repaired. Only a payload truncated so badly that all three keys are missing arrives with the category maps empty, and that is the absence of data rather than a signal about the repair; detecting a corrupted verdict requires validating the payload before decoding, or comparing `:flagged` against `:categories`. Second, ETF and JSON round-trips are therefore **not** interchangeable for an off-contract `flagged: nil`.

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

---

## 40. Compact tool disclosure

> **Phase 23 amendment (commits `9b74416..d8b3ae2`; docs land in the 23.4 commit).** This section is new. It amends §5.2 (`ALLM.Tool` fields), §16 (validation) and §27 (module tree). No closed union changes: no `ALLM.Event` variant, no error reason atom, no adapter callback.

### 40.1 Motivation

Every tool definition is sent to the model on every step. A catalog of dozens of tools spends most of its prompt on descriptions and JSON Schemas of tools the turn never calls, and tool-selection accuracy degrades as the catalog grows. A tool marked `compact: true` is sent as a one-line stub instead, and the model pulls the full definition on demand through one built-in `tool_help` tool, the way a CLI prints a usage line and answers `--help`.

The opt-in is per tool, like `:manual` (§5.2). Callers keep their few most-used tools full and compact the long tail. There is no engine-level or call-level switch; `Enum.map(tools, &%{&1 | compact: true})` does the same.

### 40.2 The stub and the meta-tool

The normative definitions are the `@doc`s of `ALLM.ToolHelp` (`lib/allm/tool_help.ex`); this section summarises them.

- **Stub** (`ToolHelp.stub/1`, via `project/2`). Same `name`. `description` is `<summary> Args: <required, …> [<optional, …>] [compact]`, where the summary is `:summary` when set and non-empty and otherwise the first sentence of `:description` (cut at 160 graphemes), required names follow the schema's `"required"` order, and optional names are sorted. The `Args:` hint lists only names declared in `"properties"`: a `"required"` name with no property is left out of the hint but is still enforced by the usage error below, an empty `"properties"` map gives `Args: none`, and a schema with no `"properties"` map gives no hint at all (`ToolHelp.signature/1`). `schema` is exactly `%{"type" => "object"}`, the one shape every bundled provider accepted when measured. `handler` is `nil`, so the wire list holds no funs.
- **Meta-tool** (`ToolHelp.meta_tool/0`). Named `tool_help`, taking `{"names": ["tool_name", …]}`, with no handler. It is recognised by the string-keyed marker `metadata: %{"allm_builtin" => "tool_help"}`, not by its name, so the marker survives a JSON round trip. It is appended once whenever at least one compact tool is present.
- **Answer** (`ToolHelp.render/2`). One section per requested name: the full description and the schema as compact JSON. Unknown names and malformed arguments get an explanatory string, never an error. It never raises.
- **Usage error** (`ToolHelp.check_args/2`). A compact tool called without one of its top-level `"required"` keys does not reach its handler. It returns `{:error, "missing required argument(s): …\n\n" <> <that tool's help>}`, routed through `on_tool_error` like any handler error (§19): `:continue` feeds it back, `:halt` stops the loop with `:tool_error`. Only key presence is checked; there is no type or nested validation, and full tools are never checked.
- **Forced tool.** When `tool_choice` forces a single compact tool (a binary name, `{:tool, name}`, or any single-tool provider map shape the adapters accept), that one tool is sent in full.

### 40.3 Where it runs

- **Wire side.** `ALLM.Chat.build_request/4` sends `ToolHelp.project(Engine.resolve_tools(engine, opts), tool_choice)` (`lib/allm/chat.ex:2020`, shared by the streaming and non-streaming paths).
- **Execution side.** Every tool-executing site in `ALLM.Chat` uses the private `effective_tools/2` (`lib/allm/chat.ex:2001`), which is the full resolved list plus the meta-tool. For every name, the wire list and the execution list both contain it or both lack it, so the `:unknown_tool` pre-flight never rejects a stub or `tool_help`.
- **Tool runner.** `ALLM.ToolRunner.execute_one_tool/3` (`lib/allm/tool_runner.ex:537`) answers the meta-tool with `render/2` over the full list without reaching the configured `tool_executor`, so a custom executor that dispatches by name never sees `tool_help`; otherwise it runs `check_args/2` before the executor (`:548`). Direct callers of `run_tool_calls/3` / `stream_tool_calls/3` get the same check, and get `tool_help` answered only if their list contains `meta_tool/0`.
- **Not affected.** `ALLM.generate/3` / `stream_generate/3` with a caller-built `%Request{}` never pass through `build_request/4`, so `request.tools` is sent as built. `Engine.resolve_tools/2`'s public contract is unchanged; the meta-tool is injected only inside `ALLM.Chat`. `ALLM.Session` stores no tools, and `tool_help` exchanges live in the thread as ordinary `:tool` messages.

### 40.4 Invariants

1. **Cache stability.** `project/2` is deterministic, and the engine and `opts` are fixed across the steps of one run, so `request.tools` is `==` on every step. Learning about a tool adds a `:tool` message, never a tool definition, so provider prompt caches keyed on the tool list survive. (Anthropic with `response_format: json_schema` drops its own synthetic tool after it has been called, independent of this feature.)
2. **Compact-off is a no-op.** With no `compact: true` tool, `project/2` returns its input unchanged and `check_args/2` is `:ok`: existing callers are byte-identical on the wire.
3. **Name collision.** When at least one compact tool is present, a caller's own tool named `tool_help` collides with the injected one and the request is rejected pre-flight with `{:tools, :duplicate_name}` (§16). With no compact tool, such a tool is ordinary.
4. **Turns.** Each `tool_help` call is a round trip: it uses a `max_turns` turn and counts as a tool result for `halt_when`.

### 40.5 Manual modes

- **Whole-loop `mode: :manual`** (§12): the caller runs everything, `tool_help` included. Its call surfaces like any other; `ToolHelp.answer/2` builds the content to submit. Compact tools executed by the caller never pass through `ToolRunner`, so they get no usage-error check unless the caller calls `check_args/2`.
- **Per-tool manual** (§12.4): the meta-tool has `manual: false`, so it lands in the auto bucket and runs, while a compact tool with `manual: true` halts the loop as usual.

### 40.6 Choice of mechanism

Five patterns exist for large tool catalogs (survey 2026-09-21):

| | Pattern | Cache | Provider-neutral |
|---|---|---|---|
| A | Native deferral + server-side search (Anthropic `tool_search_tool_*`, OpenAI Responses `tool_search`) | kept | no — two of four translators, newer models only |
| B | Client search meta-tool; discovered definitions appended to the next request's `tools` | broken on every discovery | yes |
| **C** | **Callable stubs + a describe meta-tool (this section)** | **kept** | **yes** |
| D | One dispatcher tool `call_tool({name, args})` | kept | yes, but loses per-tool events, `:manual`, `on_tool_error` |
| E | Code mode (the model writes code against the tools) | kept | no — needs a sandbox |

C is the only pattern that is cache-stable, works on every translator with no adapter change, and keeps each compact tool a first-class `%Tool{}`. A later adapter phase may map `compact: true` onto native deferral (A) where a provider supports it; that changes semantics (a deferred tool is invisible until searched, a stub is visible) and needs its own design.

### 40.7 Measured behaviour (2026-09-22)

`examples/21_compact_tools.exs` runs the eight-tool fixture (`examples/fixtures/compact_tools.exs`) once all compact and once all full, with the prompt *"File an issue in acme/web titled 'Login button broken' with label bug."*, on each bundled chat provider's default example model:

| Provider (model) | Step-1 input tokens compact / full | Run-total input compact / full | `tool_help` called first? | `labels` an array? |
|---|---|---|---|---|
| OpenAI (`gpt-5.4-nano`) | 348 / 755 (−54%) | 766 / 1676 | no | yes |
| Gemini (`gemini-3-flash-preview`) | 471 / 1294 (−64%) | 1120 / 2716 | no | yes |
| Anthropic (`claude-sonnet-4-6`) | 1054 / 1899 (−44%) | 2243 / 3933 | no | yes |

All three providers accept the stub schema `{"type":"object"}`, and all three filled in every required argument straight from the `Args:` hint without calling `tool_help`. This is one easy prompt; it shows the mechanism works end to end, not how often models need `tool_help` on harder tasks.

### 40.8 Out of scope

- native provider deferral (§40.6, pattern A)
- a hidden tier where tool names are withheld and found by search
- engine-level or call-level compaction switches
- full JSON Schema argument validation; only the required-key check ships
- compaction of a caller-built `%Request{}` passed to `generate/3` / `stream_generate/3`

---

## 41. v0.6 — Typed classification

> **Phase 24 amendment (commits `7de1c1c..0c9c8b5`; docs land in the 24.5 commit).** This section is new. It amends §27 (module tree), §29 (telemetry) and §35.7 (bundled-adapter rule — a fourth scoped carve-out, family-scoped to this section). §35.10 is reconciled in the paragraph below rather than amended. §32.5 and §33 are untouched: neither list named classification. The design is `steering/2026-09-22_JEV_SUPPORT.md`; the wire facts below are the ones its 24.4 live probe observed, not its first guesses.

v0.6 extends ALLM with a non-streaming primitive for asking a calibrated model **closed-form questions** about a piece of state — pick one option, place on an ordered scale, yes/no — and getting **typed answers with probabilities** back, without generating any text. Structurally it is the moderation family again (§39): a Layer A request/response pair, a dedicated behaviour with its own closed error enum, one `Engine` adapter field, one façade function, one telemetry span, one `Fake*` adapter and one published conformance suite. It takes the audio family's (§37) slot model, adapter HTTP shape and absence of capability pre-flight.

It differs from both in three places, and those are where a reviewer should look hardest: the **request carries typed questions**, not an input list, so validation is per question type (§41.2.2); the **answer is a tagged union carried in one struct**, with a normative per-type field-population table (§41.2.3); and the **only provider is capability-only** — it has no chat adapter — which is what the §35.7 carve-out of §41.7 is for.

**Why a classification primitive is admitted where object detection is not.** §35.10 places *"image classification / object detection as distinct primitives — users build these on top of chat + vision"* out of scope, and §39 admitted moderation as a narrow exception. Typed classification is admitted on the same two grounds, neither of which generalizes to the excluded cases: it has a **dedicated, single-call endpoint** returning **calibrated per-option probabilities**, which chat composition cannot reproduce (composition costs a generation call, returns prose that has to be parsed back, and its "probabilities" would be self-reports, not calibration); and it answers every question about one state in one call, which is the cost shape an application routing tickets or screening content needs. The §35.10 line stands unamended for object detection, OCR and upscaling, and it still stands for *image* classification: classification state is text only (§41.2.2).

**Departures from §39.1 goal 5.** §39.1 goal 5 says model resolution and capability pre-flight *"apply identically"* to moderation. Two of that goal's parts do not carry over, deliberately: classification resolves its model from its own engine slot and never reads `engine.model` (§41.4, following §37.4), and there is no capability pre-flight (§41.5).

### 41.1 Design goals

1. **Parallel to the chat pipeline, not entangled with it.** Classification requests, responses and adapters are separate types. A classification provider is never wired as a chat adapter: Jev generates no text, holds no conversation and has no stream, so every `ALLM.Adapter` invariant would be false for it. There is no automatic classification inside `chat/3`.
2. **Non-streaming.** No `ALLM.ClassificationStreamAdapter` and no `stream_classify/3`, following §35.1 item 2, §36.1 item 2 and §39.1 item 2. A `stream: true` opt is silently ignored.
3. **Opt-in per engine.** An engine without a `:classification_adapter` returns `{:error, %ALLM.Error.EngineError{reason: :no_classification_adapter}}`, ahead of every other gate. No fallback to any other adapter slot.
4. **The library does not decide thresholds.** ALLM returns the probabilities, score position and confidence the provider reports. There is no default confidence floor, no `yes?/2` and no routing DSL; the provider's own guidance is that *"the thresholds live in your code"* (TypeSafe, Noul page). Same stance as §39.1 item 4.
5. **One call, many questions.** A request is one state plus N named questions, answered independently against that state in one call. The façade does not chunk questions and enforces no question count (§41.6).
6. **Reuse engine plumbing** — keys (§6.4), retries, telemetry (§29) and deterministic fakes (§31) — with the two departures stated above.

### 41.2 Data model

All five types are Layer A: plain structs that round-trip through `:erlang.term_to_binary/1` and JSON, registered in `ALLM.Serializer`'s `@known_modules`.

#### 41.2.1 `ALLM.ClassificationQuestion`

```elixir
defmodule ALLM.ClassificationQuestion do
  @type question_type :: :choice | :score | :yes_no
  @type structured :: String.t() | map() | list()

  @type t :: %__MODULE__{
          type: question_type() | nil,
          instructions: structured() | nil,
          criteria: %{String.t() => structured() | nil} | [structured()] | map() | nil
        }

  defstruct [:type, :instructions, :criteria]

  @spec new(keyword()) :: t()
  @spec choice(structured(), [String.t() | atom()] | %{(String.t() | atom()) => structured() | nil}) :: t()
  @spec score(structured(), [structured()]) :: t()
  @spec yes_no(structured(), keyword()) :: t()
end
```

| Type | `criteria` | Built by |
|------|-----------|----------|
| `:choice` | `%{String.t() => structured() \| nil}`, one key per option | `choice/2`; a list of names becomes a map with `nil` descriptions, atom names are stringified |
| `:score` | `[structured()]`, index = level, low to high | `score/2`, verbatim |
| `:yes_no` | `nil`, or a map whose keys ⊆ `["true", "false"]` | `yes_no/2`; keys only for the `true:` / `false:` opts given |

`:yes_no` is the only Layer A spelling. TypeSafe calls the type `noul`; the translation lives in the TypeSafe adapter and nowhere else. `new/1` is a bare `struct!/2` pass-through. The builders raise on a wrongly typed argument (`FunctionClauseError`; `ArgumentError` for an unknown `yes_no/2` opt, and for `choice/2` option names that collide once stringified, such as `:billing` and `"billing"`); counts, emptiness and provider caps are the validator's and the adapter's, so a builder-made and a hand-built question are judged by the same rules.

#### 41.2.2 `ALLM.ClassificationRequest`

```elixir
defmodule ALLM.ClassificationRequest do
  @type state :: String.t() | map() | list()

  @type t :: %__MODULE__{
          state: state() | nil,
          questions: %{String.t() => ALLM.ClassificationQuestion.t()},
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:state, :model, questions: %{}, options: %{}, metadata: %{}]
end
```

- **State is text only**: a string, a JSON object or a JSON array. No image, audio or video (TypeSafe, Models page: *"Text only. String, JSON object, or array of text values."*). A map state with atom keys is sent with string keys and comes back from a JSON round trip with string keys.
- **Question ids are non-empty binaries.** `ALLM.classification_request/2` stringifies atom ids for ergonomics; the struct does not, and the validator rejects a non-binary key on a hand-built struct, because an atom key does not survive JSON.
- `:options` is the home for provider-specific knobs; the bundled adapter forwards nothing from it. `:metadata` round-trips onto the response.

Validation lives in `ALLM.Validate.classification_request/1`, returning `%ALLM.Error.ValidationError{reason: :invalid_classification_request, errors: [...]}` with the exhaustive `{path, atom}` list. The vocabulary is closed: `:questions` (`:invalid_shape` — a hard reject — or `:empty`); `:state` (`:empty`, `:invalid_shape` — including a struct or a keyword list — or `:not_json_encodable`, at most one, in that order); `:model` (`:invalid_shape`); and per question `[:questions, id]` (`:invalid_id`, `:invalid_question`), `[:questions, id, :type]` (`:invalid_type`), `[:questions, id, :instructions]` (`:empty`, `:invalid_shape`, `:not_json_encodable`), `[:questions, id, :criteria]` (`:invalid_shape`, `:empty`, `:too_few_levels` for a one-level score, `:not_json_encodable`) and `[:questions, id, :criteria, option]` (`:invalid_option`). Criteria rules run only for a known type, so errors do not cascade. Provider caps (option and level counts) are deliberately **not** validator rules: they are one provider's wire facts and live in its adapter (§41.7).

#### 41.2.3 `ALLM.ClassificationAnswer`

```elixir
defmodule ALLM.ClassificationAnswer do
  @type t :: %__MODULE__{
          type: ALLM.ClassificationQuestion.question_type(),
          choice: String.t() | nil,
          score: float() | nil,
          yes_probability: float() | nil,
          probabilities: %{String.t() => float()} | [float()] | nil,
          legend: [term()] | nil,
          confidence: float() | nil,
          metadata: map()
        }

  @enforce_keys [:type]
  @spec value(t()) :: String.t() | float()   # choice → option, score → position, yes_no → P(yes)
end
```

**Field population by type (normative; conformance cases 2–5 bind it):**

| Field | `:choice` | `:score` (n levels) | `:yes_no` |
|-------|-----------|---------------------|-----------|
| `choice` | option name, a key of the question's criteria | `nil` | `nil` |
| `score` | `nil` | float, `0.0 ≤ x ≤ n − 1` | `nil` |
| `yes_probability` | `nil` | `nil` | float, `0.0 ≤ x ≤ 1.0` |
| `probabilities` | `%{option => float}`, keys = criteria keys | `[float]`, length n | `nil` |
| `legend` | `nil` | `[term]`, length n | `nil` |
| `confidence` | float, `0.0 ≤ x ≤ 1.0` | float, `0.0 ≤ x ≤ 1.0` | `nil` |

Score lists are index = level, because an integer-keyed map does not survive a JSON round trip; choice probabilities stay a string-keyed map, because options are caller names with no order. **Confidence is reported, never computed**: a `:yes_no` answer carries `confidence: nil` because TypeSafe reports none (*"Noul has no separate `confidence`"*, Primitives page). An adapter coerces every float with `* 1.0` when decoding (JSON `1` decodes as an integer); decoding a persisted answer does not coerce.

#### 41.2.4 `ALLM.ClassificationResponse`

```elixir
defmodule ALLM.ClassificationResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          answers: %{String.t() => ALLM.ClassificationAnswer.t()},
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  @spec answer(t(), String.t() | atom()) :: ALLM.ClassificationAnswer.t() | nil
end
```

- `:answers` is keyed by the request's question ids.
- `:id` is the **provider's** request id — the value its support team asks for; `:request_id` is ALLM's own correlation id. They are never mixed, and the provider id never goes in caller-owned `:metadata`. This matches every sibling response struct.
- `:model` is the versioned id the provider reports as having answered (`"jev-1.13.0"`), not the alias that was sent.
- `:usage` is never `nil`: `input_tokens` and `output_tokens` from the provider, `total_tokens` their sum; every cost field and both prompt-cache counters stay `nil`. Pricing is per input token and needs no catalog, but no catalog carries it, so cost population is out of scope (§41.10).

#### 41.2.5 `ALLM.Error.ClassificationAdapterError`

A closed enum of **nine** reasons: the moderation enum minus `:unsupported_feature` and `:batch_too_large`, neither of which has a use site (a classification request has no optional field a provider could fail to express, and questions are never chunked).

```elixir
@type reason ::
        :authentication_failed | :rate_limited | :invalid_request
        | :context_length_exceeded | :provider_unavailable | :timeout
        | :network_error | :malformed_response | :unknown
```

`:malformed_response` covers a 200 whose body does not match the questions asked: an unparseable body, a missing `answers` object, an answer for an id not asked, a requested id with no answer, or an answer whose type differs from its question's. The struct implements `Jason.Encoder`; an adapter must never store a raw exception in `:cause`, because an exception can carry the caller's data or a pid and make the error itself unencodable. The condition is reported as data instead (`metadata: %{cause: :unencodable_body}`, `metadata.transport_reason`).

The closed-enum extensions elsewhere: `ALLM.Error.EngineError` gains `:no_classification_adapter`, `ALLM.Error.ValidationError` gains `:invalid_classification_request`, and `ALLM.Telemetry` gains the `:classify` span name — each in both its `@type` union and its runtime list. Adding a reason is breaking for an exhaustive `case`.

### 41.3 `ALLM.ClassificationAdapter` behaviour

```elixir
defmodule ALLM.ClassificationAdapter do
  @callback classify(ALLM.ClassificationRequest.t(), keyword()) ::
              {:ok, ALLM.ClassificationResponse.t()}
              | {:error, ALLM.Error.ClassificationAdapterError.t()}

  @callback prepare_request(ALLM.ClassificationRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ClassificationAdapterError.t()}

  @optional_callbacks prepare_request: 2
end
```

There is no `max_batch_size/0` (§41.6). **Contract invariants** — the numbering matches `@moduledoc ALLM.ClassificationAdapter` and is cited by number:

1. `classify/2` returns exactly `{:ok, %ClassificationResponse{}}` or `{:error, %ClassificationAdapterError{}}`. The one sanctioned exception is `ALLM.Keys.fetch!/2`'s `%EngineError{reason: :missing_key}` raise (§6.4). **Enforced:** `ALLM.classify/3` raises `ArgumentError` naming the adapter and this invariant on any other shape. No conformance run can observe it.
2. On `{:ok, _}`, `Map.keys(response.answers)` equals `Map.keys(request.questions)` as sets.
3. Each answer's `:type` equals its question's `:type`, and its fields follow §41.2.3's table.
4. A `:choice` answer's `choice` is a key of that question's criteria, and its `probabilities` keys equal the criteria keys.
5. A `:score` answer's `probabilities` and `legend` each have length `length(criteria)`.
6. `questions: %{}` is rejected with `:invalid_request` before any I/O and before `ALLM.Keys.fetch!/2`, so a keyless environment observes the rejection rather than a missing-key raise.
7. `request.metadata` round-trips onto `response.metadata` unchanged, and `opts[:request_id]` is reflected onto `response.request_id` unchanged.
8. `opts[:request_timeout]` is honoured; exceeding it yields `:timeout`.
9. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `classify/2` would fire it.

**Cleanup invariant: none.** `Req.request/1` owns its connection lifecycle; there is no `Stream.resource/3` and no Finch reference.

### 41.4 Engine integration

`ALLM.Engine.t()` gains two fields:

```elixir
classification_adapter: module() | nil
classification_model: String.t() | nil
```

`:classification_adapter` is a peer to every other adapter slot, never a fallback. `:classification_model` is the slot's own model, following §37.4: **the classification façade never reads `engine.model`**, because a chat model name sent to a classification endpoint is a guaranteed rejection. Resolution, normative: `request.model || engine.classification_model`, then the adapter's documented default when still `nil`. On the state call shape `opts[:model]` reaches `request.model`; a pre-built request is authoritative and `opts[:model]` is not merged onto it. The per-slot field keeps the classification model persisted with its adapter, so an engine pairing a chat provider with a classification provider round-trips intact:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    model: "claude-sonnet-4-6",
    classification_adapter: ALLM.Providers.TypeSafe.Classification,
    classification_model: "jev-1.13.0"
  )
```

Both fields join `@engine_field_keys` (the `resolve_params/2` deny-list); `:classification_adapter` joins `@module_fields`. Key resolution (§6.4) uses the adapter's own provider namespace; engines stay free of key material.

### 41.5 Public API

```elixir
defmodule ALLM do
  @spec classification_request(ALLM.ClassificationRequest.state(), keyword()) ::
          ALLM.ClassificationRequest.t()

  @spec classify(
          ALLM.Engine.t(),
          ALLM.ClassificationRequest.state() | ALLM.ClassificationRequest.t(),
          keyword()
        ) ::
          {:ok, ALLM.ClassificationResponse.t()}
          | {:error,
             ALLM.Error.EngineError.t()
             | ALLM.Error.ValidationError.t()
             | ALLM.Error.ClassificationAdapterError.t()}
end
```

`classify/3` accepts a state (dispatched through `classification_request/2`, whose opt allow-list is exactly the request's field set minus `:state`: `:questions`, `:model`, `:options`, `:metadata`) or a pre-built `%ClassificationRequest{}` (dispatched verbatim). Any other struct, and a keyword list, enter as state and are rejected by the validator's `{:state, :invalid_shape}` row rather than raising or reaching the provider. Other non-state terms raise `FunctionClauseError`.

Example:

```elixir
questions = %{
  "department" => ALLM.ClassificationQuestion.choice("Which team?", ["billing", "technical", "sales"]),
  "refund" => ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
}

{:ok, response} = ALLM.classify(engine, ticket_text, questions: questions)
%{choice: team, confidence: c} = ALLM.ClassificationResponse.answer(response, "department")
```

Gate order, inside the span, is fixed:

1. adapter presence (`:no_classification_adapter`);
2. `ALLM.Validate.classification_request/1` (`:invalid_classification_request`);
3. slot-model stamping (§41.4);
4. dispatch under `ALLM.Retry.run/3`, retrying `:rate_limited`, `:provider_unavailable`, `:timeout` and `:network_error` under `engine.retry`.

**There is no capability pre-flight** (`ALLM.Capability` is not extended), following §37.1 item 5. Its only possible input is an `llm_db` catalog entry; `llm_db` is not a dependency and no catalog carries a classification model. Dispatch opts go through the shared capability builder, which drops `:stream` and injects the engine's cursor key, so façade-driven Fake scripts on content-equal engines never share a cursor. A missing key is **raised**, not returned. There is deliberately **no Layer D**: a classification carries no conversation state.

### 41.6 One call, many questions

**The façade does not chunk, and there is no question-count callback.** Unlike moderation (§39.6), splitting questions across calls would be well-defined — answers are independent per question — but every extra call re-sends and re-bills the whole state, and the provider's own guidance is that *"batching every question into one TypeSafe call is 12.2x cheaper and 10.0x faster"* (TypeSafe, Parallel questions cookbook). The limit that matters is a per-request token budget, not a count (§41.7). A caller with more questions than one budget holds splits them itself.

### 41.7 Provider adapters in v0.6, and the §35.7 carve-out

v0.6 bundles **one** classification adapter, `ALLM.Providers.TypeSafe.Classification`, against TypeSafe's Jev model. Each row is marked **documented** (TypeSafe's published docs, fetched 2026-09-22), **observed** (the live probe in `scripts/record_typesafe_classification_fixtures.exs`, run 2026-09-27; bodies under `test/fixtures/typesafe/classification/recorded/`) or **inferred**.

| | TypeSafe | Status |
|---|---|---|
| Endpoint | `POST https://api.typesafe.ai/v1/systemone` (not overridable) | documented |
| Auth | `authorization: Bearer <key>` | documented; observed |
| Key atom / env var | `:typesafe` / `TYPESAFE_API_KEY` (through `ALLM.Keys`' `<PROVIDER>_API_KEY` fallback; no `ALLM.Keys` change) | — |
| Request | `{"state", "model", "questions": {"<id>": {"type", "instructions", "criteria"}}}` | documented |
| Question type | `:choice` → `"choice"`, `:score` → `"score"`, `:yes_no` → `"noul"` | documented |
| Default model | `"jev-latest"`, injected when the effective model is `nil` (the wire requires `model`); an alias that moves — pin `"jev-1.13.0"` when tuning thresholds | documented |
| Response | `{"model", "answers": {…}, "usage": {"input_tokens", "output_tokens"}}` | documented; observed |
| Score answer | `probabilities` and `legend` keyed `"0".."n-1"`, decoded to lists; object levels come back as objects in `legend` | documented; object echo observed |
| Provider request id | `x-typesafe-request-id` header on **every** response, success and error → `ClassificationResponse.id`, or error `metadata.typesafe_request_id` | observed |
| Limits | at most 255 choice options and 10 score levels, gated in the adapter before I/O and key resolution (`:invalid_request`, `metadata: %{question:, limit:}`); 255 and 10 accepted, 256 and 11 → 400 | documented; observed |
| Question count | none documented; 1, 32, 128 and 512 questions all accepted | observed |
| Token budget | 64k tokens per request; 32k for the state plus the longest question | documented |
| Unknown fields | **ignored** — an invented question field returns 200 (observed); an invented top-level field returned 200 in one exploratory call that is not in the recorder and has no fixture (RECORDS §24.4) | observed (question field); observed once, not recorded (top-level field) |
| Unknown type / unknown model / over a limit | **400** (not 422) | observed |
| Schema validation failure (e.g. `questions: {}`) | **422**, FastAPI `detail` list | observed |
| Context length | **400** with `{"detail": {"error_type": "max_tokens_exceeded"}}`, no message → `:context_length_exceeded` | observed |
| Bad key | 401 `{"detail": {"error_type": "authentication_error", "message": …}}`; the body does not echo the key | observed |
| Error envelope | always `{"detail": …}`: a string (limit breaches), an object with `error_type` and usually `message`, or a list of `{"loc", "msg", …}` (422) | observed |
| 429 / 529 | `:rate_limited` / `:provider_unavailable` (529 is "Overloaded") | documented; not provoked |
| 500 / 502 / 503 / 504 | `:provider_unavailable` | inferred |
| `Retry-After` / `retry-after-ms` | neither observed; `Retry-After` is parsed when present | inferred |
| Usage / cost | `input_tokens` populated; *"$0.042 / Mtok … Charged per input token. Output tokens are free."*; ALLM leaves cost `nil` | documented |

Four provider behaviours are stated here because each falsified an assumption and each is invisible from the types:

1. **TypeSafe ignores unknown fields** (recorded for a question-level field; a top-level field was seen only in one unrecorded exploratory call). "The API accepted it" is therefore not evidence of schema membership at this endpoint; only facts with a distinguishing *response* (the limit, model, type, context-length and empty-questions arms) are settled request-side facts.
2. **Most rejections are 400, and 422 means only schema validation.** Unknown question type, unknown model and a limit breach all return 400; `:invalid_request` covers 400, 404 and 422 alike.
3. **Context length has a signal of its own**, a 400 whose `detail.error_type` is `"max_tokens_exceeded"`; it is the only way `:context_length_exceeded` fires.
4. **The request-id header is always present**, so `ClassificationResponse.id` is populated on every success, and every error carries it as `metadata.typesafe_request_id` next to `status` and `typesafe_error_type` (the body's `detail.error_type`, when present); a transport failure adds `transport_reason`.

The adapter makes **one HTTP attempt per call** with no inner retry loop (the audio precedent, `ALLM.Providers.Support.TranscriptionAdapter`); `ALLM.classify/3`'s `Retry.run/3` is the only loop, so `:timeout` costs 3 attempts, not the 9 an adapter-plus-façade nesting produces. A list state holding a non-string element is rejected before I/O (`metadata: %{field: :state}`) because TypeSafe documents list state as *"array of text values"*, although the live API accepted `["a", 1]` (observed). A body that cannot be JSON-encoded is `:invalid_request` with `metadata: %{cause: :unencodable_body}`. Every error has `cause: nil`. Provider-authored strings pass a redactor that removes the resolved key literally (keys of 8 bytes or more) and any `apikey_…`-shaped token by pattern (`ALLM.Providers.Support.Redact.typesafe/1`); the 401 body does not echo the key, so this is defence in depth. `opts[:adapter_opts][:classification_script]` (any non-nil value) short-circuits to `ALLM.Providers.FakeClassification`, which is how the conformance suite drives it without HTTP.

#### The §35.7 amendment

TypeSafe fails every §35.7 criterion as amended through v0.6: it has no bundled chat adapter (a), no bundled provider names it as a partner (b), a one-adapter family's only provider is not bundled for chat (the Phase 22 carve-out), and the Phase 26 carve-out admits nothing outside §37. The owner decided (2026-09-22) to bundle it in core rather than as a separate package, so §35.7 takes a fourth scoped carve-out, stated there and repeated here:

> An adapter from a provider with no bundled chat adapter may be bundled into the classification family (§41), as its **sole** member, when (i) no bundled provider offers typed classification through a dedicated endpoint, (ii) the provider's API for it is a single, documented HTTP surface, and (iii) the capability's absence on every bundled chat provider is documented rather than backfilled with a proxy.

There is deliberately **no OpenAI, Anthropic, Gemini or Voyage classification adapter**: none offers typed classification through a dedicated endpoint, and producing choice/score/yes-no answers from a chat model's structured output would be the proxy the carve-out forbids — its "probabilities" would be invented from logprobs or self-reports rather than calibrated. The behaviour does not foreclose such an adapter as a separate package. Third-party classification providers ship as separate packages implementing `ALLM.ClassificationAdapter`.

### 41.8 Testing

`ALLM.Providers.FakeClassification` implements `ALLM.ClassificationAdapter` with scripted answers, in `lib/` so downstream applications can use it. Following the moderation split (§39.8), **no script yields default answers** — a choice picks the lexicographically first option at probability `1.0`, a score answers level `0`, a yes/no answers `0.0` — and **a non-empty script that runs off the end is an error** (`reason: :unknown`, `metadata.cause: :classification_script_exhausted`). Script entries: `{:answers, %{id => value}}` (a string is a choice's option; a number is a score position or a yes probability; an `%ALLM.ClassificationAnswer{}` is verbatim; unlisted ids get their default; a value that does not fit its question raises `ArgumentError`), `{:error, %ClassificationAdapterError{}}`, and `{:retry_until_call, n}` (a synthetic `:rate_limited` for the first `n - 1` calls; consecutive entries chain). The cursor keys on engine identity through the façade. **The Fake's confidence convention is its own and is not TypeSafe's formula.**

`ALLM.Test.ClassificationAdapterConformance` ships in the `allm_conformance` package with **nine cases**: answer keys equal question keys; answer types equal question types; choice, score and yes_no field population; empty questions rejected with `:invalid_request`; `metadata` round-trip; `request_id` preservation; `usage` is an `%ALLM.Usage{}`. Every case but the empty-questions one passes `classification_script: [{:answers, %{}}]`, so an adapter under test either answers the scripted call itself or short-circuits it to a Fake. The §36.8 limitation therefore applies verbatim: for a short-circuiting adapter the suite exercises the Fake, not the adapter's decoder, and the bundled adapter carries its own decoder tests over the recorded fixtures. The suite does not bind invariant 1 (enforced at the façade) or invariant 8.

### 41.9 Telemetry

One span:

- `[:allm, :classify, :start]` — measurements `system_time`; metadata `request_id`, `engine`, `model` (`request.model || engine.classification_model`, `nil` when the adapter's default will apply), `question_count` (`0` for a non-map `:questions`, since `:start` precedes validation).
- `[:allm, :classify, :stop]` — measurements `duration`, `answer_count` (`0` on error); metadata as `:start` plus `usage` (`nil` on error), `response`, `error` (`nil` on success).
- `[:allm, :classify, :exception]` — measurements `duration`; metadata `kind`, `reason`, `stacktrace`. Emitted instead of `:stop` for a missing key or an invariant-1 `ArgumentError`, then re-raised.

The measurement key set is stable across both `:stop` paths, as for `:embed`, `:moderate` and the audio spans. `response:` carries the typed answers and the provider's `raw` body, which are judgements about the caller's text; exporting whole metadata maps is an operator decision.

### 41.10 Out of scope for v0.6

- **streaming** — there is no `stream_classify/3`; `stream: true` is ignored
- **a default threshold, `yes?/2`, or a routing DSL** — §41.1 item 4
- **client-side chunking of questions** — §41.6
- **image, audio or video state** — the provider is text-only
- **an LLM-backed generic classification adapter** — its probabilities would not be calibrated (§41.7)
- **capability pre-flight** — no catalog carries a classification model (§41.5)
- **cost population** — needs `llm_db` (§6.3)
- **model listing and version-pin helpers** — a model string is a model string; `response.model` reports the version that answered
- **`ALLM.Session` integration, or automatic classification inside `chat/3`** — no conversation state; a hidden second call per turn
