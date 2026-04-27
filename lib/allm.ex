defmodule ALLM do
  @moduledoc """
  Top-level facade for the ALLM library — provider-neutral LLM execution with
  first-class streaming and serializable conversation state.

  ALLM is organized into four conceptual layers (see
  `steering/allm_engine_session_streaming_spec_v0_2.md` §2):

    * **Layer A — Serializable data.** Plain structs (`ALLM.Message`,
      `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, …) that
      round-trip through `:erlang.term_to_binary/1` and JSON via
      `ALLM.Serializer`. No PIDs, refs, funs, or API keys.
    * **Layer B — Runtime.** `ALLM.Engine` plus the `ALLM.Adapter`,
      `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, and `ALLM.ToolResultEncoder`
      behaviours. Holds the non-serializable dependencies (modules, funs,
      Finch names, keys resolved at call time).
    * **Layer C — Stateless execution.** `generate/3`, `stream_generate/3`,
      `step/3`, `stream_step/3`, `chat/3`, `stream/3` on this module. Each
      call takes an engine explicitly.
    * **Layer D — Stateful continuation.** `ALLM.Session` operations over a
      persisted `%ALLM.Session{}`.

  Phase 1 (this release) ships Layer A: the data structs, `ALLM.Validate`,
  `ALLM.Serializer`, and the constructors on this facade. Layers B/C/D
  (engines, adapters, streaming, sessions) land in later phases.

  ## Getting Started

  Drive a `chat/3` round-trip against the deterministic `ALLM.Providers.Fake`
  adapter — no API key, no network. Parallel to the README's Getting Started
  snippet (kept in sync by visual review):

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]])
      iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} = ALLM.chat(engine, [ALLM.user("Hi.")])
      iex> text
      "Hello, ALLM!"

  ## Example

      iex> messages = [ALLM.system("Be helpful."), ALLM.user("Name three primes.")]
      iex> req = ALLM.request(messages, model: "fake:gpt-test")
      iex> :ok = ALLM.Validate.request(req)
      iex> json = ALLM.Serializer.to_json!(req)
      iex> {:ok, ^req} = ALLM.Serializer.from_json(json)

  See `steering/allm_engine_session_streaming_spec_v0_2.md` §4 for the full
  public API surface.
  """

  alias ALLM.{
    ChatResult,
    Engine,
    Image,
    ImageRequest,
    ImageResponse,
    Message,
    Request,
    StepResult,
    Thread,
    Tool
  }

  alias ALLM.Error.{AdapterError, EngineError, ImageAdapterError, ValidationError}

  @doc """
  Build a system-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.system("be helpful")
      %ALLM.Message{role: :system, content: "be helpful", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec system(String.t()) :: Message.t()
  def system(text), do: %Message{role: :system, content: text}

  @doc """
  Build a user-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.user("hi")
      %ALLM.Message{role: :user, content: "hi", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec user(String.t()) :: Message.t()
  def user(text), do: %Message{role: :user, content: text}

  @doc """
  Build an assistant-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.assistant("hello")
      %ALLM.Message{role: :assistant, content: "hello", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec assistant(String.t()) :: Message.t()
  def assistant(text), do: %Message{role: :assistant, content: text}

  @doc """
  Build a tool-role `%ALLM.Message{}` carrying a tool-call result.

  `tool_call_id` must match the `:id` of the `ALLM.ToolCall` that produced
  this result so the provider can match results to calls. `content` is either
  a binary or a JSON-serializable map.

  ## Examples

      iex> msg = ALLM.tool_result("call_abc", %{ok: true})
      iex> {msg.role, msg.tool_call_id, msg.content}
      {:tool, "call_abc", %{ok: true}}
  """
  @spec tool_result(String.t(), String.t() | map()) :: Message.t()
  def tool_result(tool_call_id, content) do
    %Message{role: :tool, tool_call_id: tool_call_id, content: content}
  end

  @doc """
  Build an `%ALLM.Tool{}` from keyword opts. Delegates to `ALLM.Tool.new/1`.

  `:name`, `:description`, and `:schema` are required; omitting any raises
  `ArgumentError`. `:handler` is optional.

  ## Examples

      iex> tool = ALLM.tool(name: "weather", description: "weather by city", schema: %{"type" => "object"})
      iex> {tool.name, tool.description}
      {"weather", "weather by city"}
  """
  @spec tool(keyword()) :: Tool.t()
  def tool(opts), do: Tool.new(opts)

  @doc """
  Build the canonical tagged map for a JSON-schema response format (spec §5.4).

  Returns `%{type: :json_schema, name: name, schema: schema, strict: boolean}`.
  `:strict` defaults to `true`; pass `strict: false` to relax provider-side
  schema enforcement.

  ## Examples

      iex> ALLM.json_schema("person", %{"type" => "object"})
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: true}

      iex> ALLM.json_schema("person", %{"type" => "object"}, strict: false)
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: false}
  """
  @spec json_schema(String.t(), map(), keyword()) :: map()
  def json_schema(name, schema, opts \\ []) do
    %{
      type: :json_schema,
      name: name,
      schema: schema,
      strict: Keyword.get(opts, :strict, true)
    }
  end

  @doc """
  Build an `%ALLM.ImageRequest{}` from a prompt and keyword opts.
  Delegates to `ALLM.ImageRequest.new/1` after putting `:prompt` last in
  the opts list — the positional `prompt` is authoritative.

  Does **not** validate — call `ALLM.Validate.image_request/1` to check
  operation-arity and field rules. Mirrors `request/2`'s no-validate
  precedent (Phase 13.3 design Decision #7). Unknown opts raise `KeyError`
  via `struct!/2`.

  Callers wanting `:variation` (which forbids a non-empty `:prompt`) should
  build the struct directly via `ALLM.ImageRequest.new/1`.

  ## Examples

      iex> req = ALLM.image_request("a kestrel")
      iex> {req.operation, req.prompt, req.n, req.response_format}
      {:generate, "a kestrel", 1, :binary}

      iex> req = ALLM.image_request("a watercolor kestrel", model: "gpt-image-1", size: {1024, 1024}, n: 2)
      iex> :ok = ALLM.Validate.image_request(req)
      iex> json = ALLM.Serializer.to_json!(req)
      iex> {:ok, ^req} = ALLM.Serializer.from_json(json)
      iex> {req.model, req.size, req.n}
      {"gpt-image-1", {1024, 1024}, 2}
  """
  @spec image_request(String.t(), keyword()) :: ALLM.ImageRequest.t()
  def image_request(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    ALLM.ImageRequest.new(Keyword.put(opts, :prompt, prompt))
  end

  @doc """
  Build an `%ALLM.Request{}` from a list of messages and keyword opts.
  Delegates to `ALLM.Request.new/2`.

  Does **not** validate — validation runs at the adapter boundary (Phase 5)
  or via an explicit `ALLM.Validate.request/1` call. Keeping construction
  composable matches the Non-obvious Decision #7 of the Phase 1 design:
  `request/2` returns a `%Request{}` directly, not `{:ok | :error}`.

  ## Examples

      iex> req = ALLM.request([ALLM.user("hi")])
      iex> {length(req.messages), req.stream, req.tools}
      {1, false, []}

      iex> req = ALLM.request([ALLM.user("hi")], model: "gpt-4.1-mini", response_format: %{type: :json_object})
      iex> {req.model, req.response_format}
      {"gpt-4.1-mini", %{type: :json_object}}
  """
  @spec request([Message.t()], keyword()) :: Request.t()
  def request(messages, opts \\ []), do: Request.new(messages, opts)

  @doc """
  Open a streaming generation against the engine's adapter. See spec §4 and
  §10.2.

  Returns `{:ok, enumerable}` where the enumerable is a lazy stream of
  `ALLM.Event` values (no event fires until the caller reduces), or
  `{:error, struct}` on a synchronous pre-flight failure (missing adapter,
  invalid request, adapter-reported pre-flight error).

  ## Options

  In addition to any provider-specific opts the adapter honours, the
  following Phase 5 streaming-layer keys are consumed by this function:

    * `:emit_text_deltas` — `true` (default) keeps `:text_delta` events in
      the stream; `false` drops them. `:text_completed` and
      `:message_completed` are unaffected.
    * `:emit_tool_deltas` — `true` (default) keeps `:tool_call_delta`
      events; `false` drops them.
    * `:include_raw_chunks` — `false` (default) drops `:raw_chunk` events
      EXCEPT those with payload `{:usage, _}`, which always pass so
      `%Response.usage` can be populated downstream.
    * `:on_event` — a 1-arity function invoked for every event BEFORE the
      filters apply. Exceptions raised inside the callback surface in the
      consumer's reducing process, not at this call site.

  Phase 7 orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are
  silently stripped here; `stream_generate/3` is single-request.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> req = ALLM.request([ALLM.user("say hi")])
      iex> {:ok, stream} = ALLM.stream_generate(engine, req)
      iex> Enum.any?(Enum.to_list(stream), &match?({:message_completed, _}, &1))
      true
  """
  @spec stream_generate(Engine.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_generate(engine, request, opts \\ []),
    do: ALLM.StreamRunner.run(engine, request, opts)

  @doc """
  Execute a non-streaming generation against the engine's adapter. See
  spec §4 and §10.1.

  Implemented as a reducer over `stream_generate/3` (spec §3) — the
  streaming path is the primitive. A mid-stream adapter error folds into
  `response.finish_reason == :error` with the error struct under
  `response.metadata.error`; pre-flight errors surface directly as
  `{:error, struct}`.

  ## Options

  Accepts the same options as `stream_generate/3`. `:include_raw_chunks`
  defaults to `false` but `{:usage, _}` raw chunks always survive the
  filter so `response.usage` is populated regardless.

  See `ALLM.Runner` for the full mid-stream error contract and the
  stream-first reducer rationale.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> req = ALLM.request([ALLM.user("say hi")])
      iex> {:ok, response} = ALLM.generate(engine, req)
      iex> {response.output_text, response.finish_reason}
      {"hi", :stop}
  """
  @spec generate(Engine.t(), Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def generate(engine, request, opts \\ []),
    do: ALLM.Runner.run(engine, request, opts)

  @doc """
  Execute a single chat step (one adapter round-trip plus any auto-executed
  tool calls) and return a `%ALLM.StepResult{}`. See spec §4 and §10.3.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}` (normalised via `ALLM.Thread.from_messages/1`). The
  thread is validated via `ALLM.Validate.thread/1` at entry. Pure
  one-line delegation to `ALLM.Chat.step/3`; see that module for the
  full behaviour contract (mode dispatch, on_tool_error policy, halt
  metadata).

  ## Options

  In addition to any provider-specific opts the adapter honours:

    * `:mode` — `:auto` (default) executes tool calls; `:manual` returns
      them for the caller to submit results.
    * `:tool_timeout` — milliseconds per tool (default 30_000).
    * `:on_tool_error` — `:continue` (default) or `:halt`.
    * `:tool_executor`, `:tool_result_encoder` — module overrides.
    * Phase 5 stream filter opts are accepted but have no effect on this
      non-streaming path.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     script: [
      ...>       {:tool_call, id: "call_0", name: "weather", arguments: %{"city" => "NYC"}},
      ...>       {:finish, :tool_calls}
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "weather",
      ...>     description: "forecast by city",
      ...>     schema: %{"type" => "object"},
      ...>     handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
      ...>   )]
      ...> )
      iex> {:ok, sr} = ALLM.step(engine, [ALLM.user("weather in NYC?")])
      iex> {sr.done?, length(sr.tool_results)}
      {false, 1}
  """
  @spec step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, StepResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def step(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.step(engine, thread_or_messages, opts)

  @doc """
  Execute a single chat step as a lazy stream of `ALLM.Event` values. See
  spec §4 and §10.4.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}`. The returned stream is open — no events fire until
  the caller reduces. Events are emitted in this order: all adapter
  events (pass-through from `stream_generate/3`), then zero-to-N
  tool-execution event groups (per tool: `:tool_execution_started` →
  `:tool_execution_completed` → `:tool_result_encoded` /
  `:ask_user_requested` / `:tool_halt`), then exactly one terminal
  `:step_completed` event.

  Pure one-line delegation to `ALLM.Chat.stream_step/3`; see that
  module for the three-phase `Stream.resource/3` state machine and the
  unknown-tool error-in-stream contract.

  ## Options

  Same as `step/3`. Additionally accepts the Phase 5 streaming filter
  opts (`:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
  `:on_event`) — they apply to the adapter-stream pass-through phase.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     script: [
      ...>       {:tool_call, id: "call_0", name: "weather", arguments: %{"city" => "NYC"}},
      ...>       {:finish, :tool_calls}
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "weather",
      ...>     description: "forecast by city",
      ...>     schema: %{"type" => "object"},
      ...>     handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
      ...>   )]
      ...> )
      iex> {:ok, stream} = ALLM.stream_step(engine, [ALLM.user("weather in NYC?")])
      iex> events = Enum.to_list(stream)
      iex> Enum.any?(events, &match?({:step_completed, _}, &1))
      true
  """
  @spec stream_step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_step(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.stream_step(engine, thread_or_messages, opts)

  @doc """
  Run a multi-turn chat loop against the engine and return a
  `%ALLM.ChatResult{}`. See spec §4 and §10.5.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}` (normalised via `ALLM.Thread.from_messages/1`). The
  thread is validated via `ALLM.Validate.thread/1` at entry. Pure
  one-line delegation to `ALLM.Chat.run/3`; see that module for the
  full multi-turn loop semantics, the seven-entry terminal-condition
  ordering, and the `%ChatResult{}` shape.

  ## Mode

    * `:auto` (default) — the loop executes tool calls automatically.
      Each step appends tool-result messages to the thread before the
      next adapter call. Halt reasons follow the table below.
    * `:manual` — the FIRST step whose response carries
      `finish_reason: :tool_calls` halts with `halted_reason:
      :manual_tool_calls`. The caller submits tool results via a fresh
      `chat/3` call with the augmented thread (no executor runs).
      Pure-text steps under `:manual` continue normally.

  ## `:max_turns` precedence

  The loop bound resolves at entry through this chain (call opts wins
  on the left):

      call opts > engine.params[:max_turns] > Application.get_env(:allm, :max_turns) > library default 8

  Per Phase 7 design Non-obvious Decision #9. `max_turns` must be a
  `pos_integer()`; non-positive integers raise `ArgumentError`.

  ## `:halt_when` semantics

  `:halt_when` is a `(StepResult.t() -> boolean())` callback invoked
  AFTER the step's thread mutation has been applied (Phase 7 design
  Non-obvious Decision #11). It is the LAST per-step gate consulted —
  ask-user, handler `{:halt, _, _}`, `on_tool_error: :halt`,
  `:manual_tool_calls`, and adapter `finish_reason ∈ {:stop, :error,
  :length, :content_filter}` all preempt it. Exceptions raised inside
  `halt_when` propagate to the caller of `chat/3`; they are NOT
  caught.

  ## `:on_tool_error`

  Atom forms `:continue` (default) and `:halt` behave as in Phase 6.
  The function form `(ToolCall.t(), term() -> {:continue, term()} |
  :halt)` was deferred from Phase 6 and lands in Phase 7. The
  function is invoked synchronously inside the per-tool task after
  the handler's return / encoder failure resolves to an error term
  (Phase 7 Non-obvious Decision #8): `{:continue, replacement}`
  encodes `replacement` as the tool-result content; `:halt` halts the
  batch with `halted_reason: :tool_error`. An invalid return shape or
  a raise from inside the function is wrapped as `%ALLM.Error.ToolError{reason:
  :invalid_return}` and treated as `:halt`.

  ## `:on_event` scope

  Inherits the Phase 5 contract: `:on_event` observes only
  adapter-emitted events (text deltas, tool-call deltas, message
  bookends, `:raw_chunk`, adapter-emitted `:error`). Phase 6 / Phase
  7 chat-layer events (`:tool_execution_*`, `:tool_result_encoded`,
  `:ask_user_requested`, `:tool_halt`, `:step_completed`,
  `:chat_completed`) are NOT delivered to `:on_event` — they fire
  outside `ALLM.StreamRunner`. Per Phase 7 Non-obvious Decision #13.

  ## Halt-reason table

  | Reason | Fires when | `metadata` keys populated |
  |--------|------------|---------------------------|
  | `:completed` | Adapter `finish_reason ∈ {:stop, :length, :content_filter}` | `%{}` |
  | `:error` | Adapter `finish_reason: :error` (mid-stream error folds in) | `%{error: error_struct}` (when present) |
  | `:max_turns` | `step_index + 1 >= max_turns` after a non-halting step | `%{max_turns: N}` |
  | `:halt_when` | `halt_when.(step_result)` returned `true` | `%{halt_when_step_index: idx}` |
  | `:ask_user` | Handler returned `{:ask_user, _}` / `{:ask_user, _, _}` | `%{pending_question: q, pending_tool_call_id: id, ask_user_opts: opts}` (also on top-level `%ChatResult{}`) |
  | `:tool_error` | `on_tool_error: :halt`, fun returned `:halt`, or fun raised | `%{halt_tool_call_id: id}` (plus `:on_tool_error_exception` if fun raised) |
  | `:manual_tool_calls` | `mode: :manual` and step's `response.finish_reason == :tool_calls` | `%{manual_turn_index: idx}` |
  | atom() (user) | Handler returned `{:halt, reason, result}` not in the above set | `%{halt_tool_call_id: id, halt_result: result}` |

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>        {:finish, :tool_calls}],
      ...>       [{:text, "done"}, {:finish, :stop}]
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "echo",
      ...>     description: "",
      ...>     schema: %{},
      ...>     handler: fn args -> {:ok, args} end
      ...>   )]
      ...> )
      iex> {:ok, %ALLM.ChatResult{} = result} = ALLM.chat(engine, [ALLM.user("echo please")])
      iex> {result.halted_reason, length(result.steps)}
      {:completed, 2}
  """
  @spec chat(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, ChatResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def chat(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.run(engine, thread_or_messages, opts)

  @doc """
  Stream a multi-turn chat loop as a lazy enumerable of `ALLM.Event`
  values terminating in exactly one `:chat_completed` event. See spec
  §4 and §10.6.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}`. The returned stream is open — no events fire
  until the caller reduces. Pure one-line delegation to
  `ALLM.Chat.stream/3`; see that module for the two-phase
  `Stream.resource/3` state machine and the cleanup chain.

  ## Single terminal `:chat_completed`

  A naturally-terminating stream emits adapter events plus tool
  events for each turn, one `:step_completed` per turn, and exactly
  one trailing `{:chat_completed, %{result: %ChatResult{}}}` event
  (Phase 7 Non-obvious Decision #3). Both `chat/3` and
  `stream/3 |> ALLM.StreamCollector.to_chat_result/1` produce the
  SAME `%ChatResult{}` for identical inputs because both paths
  construct it via the same `ALLM.Chat.build_chat_result/1` helper
  (Phase 7 Non-obvious Decision #4).

  Consumer halts (`Enum.take/2`, `Stream.take_while/2`) produce NO
  `:chat_completed` event; callers needing a final `%ChatResult{}`
  for a cancelled stream collect events and call
  `ALLM.StreamCollector.to_chat_result/1` on the partial state — the
  fallback path returns `halted_reason: :cancelled`.

  ## Stream-first

  `chat/3` is a reducer over this stream (per spec §3). The streaming
  path is the primitive; the non-streaming variant exists so callers
  who don't need event-level visibility get a synchronous result.

  ## Ask-user thread asymmetry

  When a step's handler returns `{:ask_user, _}`, the streamed
  `:step_completed.thread` does NOT include the assistant question
  message — only the terminal `:chat_completed.result.thread` does
  (Phase 7 Invariant 8). Consumers persisting thread state across
  turns must read `ChatResult.thread`, never `:step_completed.thread`.

  ## `:on_event` scope

  Same as `chat/3` and `stream_generate/3`: `:on_event` observes only
  adapter-emitted events. Chat-layer events
  (`:tool_execution_*`, `:tool_result_encoded`, `:ask_user_requested`,
  `:tool_halt`, `:step_completed`, `:chat_completed`) are NOT
  delivered to `:on_event` — they fire outside `ALLM.StreamRunner`.
  Per Phase 7 Non-obvious Decision #13.

  ## Options

  Same options as `chat/3`. The Phase 5 streaming filter opts
  (`:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
  `:on_event`) apply to each turn's adapter pass-through.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>        {:finish, :tool_calls}],
      ...>       [{:text, "done"}, {:finish, :stop}]
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "echo",
      ...>     description: "",
      ...>     schema: %{},
      ...>     handler: fn args -> {:ok, args} end
      ...>   )]
      ...> )
      iex> {:ok, stream} = ALLM.stream(engine, [ALLM.user("echo please")])
      iex> events = Enum.to_list(stream)
      iex> Enum.count(events, &match?({:chat_completed, _}, &1))
      1
  """
  @spec stream(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.stream(engine, thread_or_messages, opts)

  @doc """
  Generate one or more images against the engine's `:image_adapter`. See
  spec §35.4, §35.5.

  Layer C façade. Two input shapes:

    * Binary `prompt` — sugar over `ALLM.image_request/2`. Opts merge into
      the built `%ALLM.ImageRequest{operation: :generate}`.
    * Pre-built `%ALLM.ImageRequest{}` — dispatched verbatim.

  ## Adapter-presence gate

  Returns `{:error, %ALLM.Error.EngineError{reason: :no_image_adapter}}`
  when `engine.image_adapter == nil`. This is the first gate; no other
  validation runs (per Phase 14.2 design Decision #5).

  ## Validation policy (Decision #13)

  The façade does NOT call `ALLM.Validate.image_request/1`. Caller-opt-in
  only — mirrors `request/2`'s no-validate precedent. A manually-built
  request that the validator would reject (e.g., empty prompt for
  `:generate`) still dispatches.

  ## `request_id` precedence (Decision #7)

  `opts[:request_id]` wins over an auto-generated id from
  `ALLM.Telemetry.request_id/0`. The id is forwarded to the adapter via
  `opts[:request_id]`. After the call, `response.request_id` is filled
  from the forwarded id IFF the adapter left it `nil`; an
  adapter-populated `:request_id` (e.g. provider's `x-request-id`
  header) is preserved.

  ## `:stream` opt is silently dropped

  Image generation is non-streaming in v0.3 (phasing principle #2).
  Passing `stream: true` does not error — the opt is ignored.

  ## Unknown opts

  Forwarded to the adapter via `opts` (matches the chat-side
  `Engine.resolve_params/2` pass-through pattern).

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> engine = ALLM.Engine.new(
      ...>   image_adapter: ALLM.Providers.FakeImages,
      ...>   adapter_opts: [image_script: [{:ok, [img]}]]
      ...> )
      iex> {:ok, %ALLM.ImageResponse{images: [_]}} = ALLM.generate_image(engine, "a kestrel")
      iex> :ok
      :ok

      iex> engine = ALLM.Engine.new()
      iex> {:error, %ALLM.Error.EngineError{reason: :no_image_adapter}} =
      ...>   ALLM.generate_image(engine, "a kestrel")
      iex> :ok
      :ok
  """
  @spec generate_image(Engine.t(), String.t() | ImageRequest.t(), keyword()) ::
          {:ok, ImageResponse.t()}
          | {:error, EngineError.t() | ValidationError.t() | ImageAdapterError.t()}
  def generate_image(engine, prompt_or_request, opts \\ [])

  def generate_image(%Engine{} = engine, prompt, opts) when is_binary(prompt) do
    request = ALLM.image_request(prompt, drop_request_opts(opts))
    do_generate_image(engine, request, opts)
  end

  def generate_image(%Engine{} = engine, %ImageRequest{} = request, opts) do
    do_generate_image(engine, request, opts)
  end

  @doc """
  Edit a base image (optionally with a mask) against the engine's
  `:image_adapter`. See spec §35.4, §35.5.

  Three call shapes (Phase 14.2 design Decision #6):

    * `edit_image(engine, base_image, prompt)` — single base, no mask;
      builds `%ImageRequest{operation: :edit, input_images: [base], mask: nil}`.
    * `edit_image(engine, [base, mask], prompt)` — 2-element list; both
      images become `:input_images`, `:mask` stays `nil`. The list form
      does NOT auto-promote the second element to `:mask` — use the
      explicit `mask:` keyword for that.
    * `edit_image(engine, base, prompt, mask: mask)` — explicit mask
      keyword; builds `input_images: [base], mask: mask`.

  Returns `{:error, %EngineError{reason: :no_image_adapter}}` when the
  engine has no image adapter (first gate, before any other validation).

  Forwards opts (n, size, quality, etc.) onto the request struct via
  `ALLM.ImageRequest.new/1`. See `generate_image/3` for the full
  `request_id` and `:stream`-drop semantics — they apply identically.

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> engine = ALLM.Engine.new(
      ...>   image_adapter: ALLM.Providers.FakeImages,
      ...>   adapter_opts: [image_script: [{:ok, [img]}]]
      ...> )
      iex> base = ALLM.Image.from_binary(<<1, 2, 3>>, "image/png")
      iex> {:ok, %ALLM.ImageResponse{images: [_]}} =
      ...>   ALLM.edit_image(engine, base, "make sky pink")
      iex> :ok
      :ok
  """
  @spec edit_image(Engine.t(), Image.t() | [Image.t()], String.t(), keyword()) ::
          {:ok, ImageResponse.t()}
          | {:error, EngineError.t() | ValidationError.t() | ImageAdapterError.t()}
  def edit_image(engine, image_or_list, prompt, opts \\ [])

  def edit_image(%Engine{} = engine, %Image{} = base, prompt, opts) when is_binary(prompt) do
    {mask, rest} = Keyword.pop(opts, :mask)
    request_opts = drop_request_opts(rest)

    request =
      ImageRequest.new(
        Keyword.merge(request_opts,
          operation: :edit,
          prompt: prompt,
          input_images: [base],
          mask: mask
        )
      )

    do_generate_image(engine, request, opts)
  end

  def edit_image(%Engine{} = engine, images, prompt, opts)
      when is_list(images) and is_binary(prompt) do
    request_opts = drop_request_opts(opts)

    request =
      ImageRequest.new(
        Keyword.merge(request_opts,
          operation: :edit,
          prompt: prompt,
          input_images: images,
          mask: nil
        )
      )

    do_generate_image(engine, request, opts)
  end

  @doc """
  Build variations of a single input image against the engine's
  `:image_adapter`. See spec §35.4, §35.5.

  Builds `%ImageRequest{operation: :variation, input_images: [image],
  prompt: nil}` and forwards opts. Returns
  `{:error, %EngineError{reason: :no_image_adapter}}` when the engine
  has no image adapter (first gate).

  See `generate_image/3` for the full `request_id` and `:stream`-drop
  semantics.

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> engine = ALLM.Engine.new(
      ...>   image_adapter: ALLM.Providers.FakeImages,
      ...>   adapter_opts: [image_script: [{:ok, [img]}]]
      ...> )
      iex> input = ALLM.Image.from_binary(<<1, 2, 3>>, "image/png")
      iex> {:ok, %ALLM.ImageResponse{images: [_]}} = ALLM.image_variations(engine, input)
      iex> :ok
      :ok
  """
  @spec image_variations(Engine.t(), Image.t(), keyword()) ::
          {:ok, ImageResponse.t()}
          | {:error, EngineError.t() | ValidationError.t() | ImageAdapterError.t()}
  def image_variations(engine, image, opts \\ [])

  def image_variations(%Engine{} = engine, %Image{} = image, opts) do
    request_opts = drop_request_opts(opts)

    request =
      ImageRequest.new(
        Keyword.merge(request_opts,
          operation: :variation,
          input_images: [image],
          prompt: nil
        )
      )

    do_generate_image(engine, request, opts)
  end

  # ---------------------------------------------------------------------------
  # Internals — Phase 14.2 bare dispatch (no telemetry, no preflight, no retry).
  # ---------------------------------------------------------------------------

  # Drop call-control opts that would collide with `ImageRequest` struct
  # fields when merged into `ImageRequest.new/1`. `:request_id`, `:stream`,
  # and `:adapter_opts` are call/dispatch-site concerns, not request fields
  # — `ImageRequest.new/1` would `KeyError` on them via `struct!/2`. `:mask`
  # is consumed at the `edit_image/4` boundary.
  defp drop_request_opts(opts) when is_list(opts) do
    Keyword.drop(opts, [:request_id, :stream, :mask, :adapter_opts])
  end

  # Bare `with`-chain: adapter-presence gate, then dispatch. Phase 14.3
  # will wrap this in `Telemetry.span(:image, ...)` + `Capability.preflight_image/2`
  # + `Retry.run/3`.
  defp do_generate_image(%Engine{image_adapter: nil}, _request, _opts) do
    {:error, EngineError.new(:no_image_adapter)}
  end

  defp do_generate_image(%Engine{image_adapter: adapter} = engine, %ImageRequest{} = request, opts) do
    request_id = Keyword.get(opts, :request_id) || ALLM.Telemetry.request_id()

    # Concat engine.adapter_opts with call-site adapter_opts. `Keyword.get/2`
    # returns the FIRST occurrence on duplicate keys, so engine wins on
    # collision. Mirrors the chat-side `StreamRunner.build_dispatch_opts/2`
    # adapter_opts concat at `lib/allm/stream_runner.ex:229-230` (NOT
    # `Keyword.merge/2`, which would have OPPOSITE precedence — call wins).
    merged_adapter_opts =
      engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, [])

    dispatch_opts =
      opts
      |> Keyword.drop([:stream])
      |> Keyword.put(:request_id, request_id)
      |> Keyword.put(:adapter_opts, merged_adapter_opts)

    case adapter.generate(request, dispatch_opts) do
      {:ok, %ImageResponse{request_id: nil} = response} ->
        {:ok, %{response | request_id: request_id}}

      {:ok, %ImageResponse{} = response} ->
        {:ok, response}

      {:error, _} = err ->
        err
    end
  end
end
