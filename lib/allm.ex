defmodule ALLM do
  @moduledoc """
  Provider-neutral LLM execution for Elixir, with first-class streaming and
  serializable conversation state.

  ALLM lets you write LLM workflows once and run them against OpenAI,
  Anthropic, Gemini, or any custom adapter — without code changes at the
  call site. Streaming is the primitive (non-streaming variants are simply
  reducers over the stream), and the data structures that describe a
  conversation (`ALLM.Request`, `ALLM.Thread`, `ALLM.Session`, …) are plain
  structs you can persist to ETF or JSON.

  The package is organised into four small layers:

    * **Data** — plain serializable structs (`ALLM.Message`,
      `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`,
      `ALLM.Event`, …). Round-trip through `:erlang.term_to_binary/1` or
      `ALLM.Serializer.to_json!/1`. No PIDs, refs, funs, or API keys.
    * **Runtime** — `ALLM.Engine` plus the `ALLM.Adapter`,
      `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`,
      and `ALLM.ImageAdapter` behaviours. Engines hold the
      non-serializable bits (modules, key resolvers, Finch names).
    * **Stateless execution** — `generate/3`, `stream_generate/3`,
      `step/3`, `stream_step/3`, `chat/3`, `stream/3` on this module.
      Each call takes an engine explicitly.
    * **Stateful continuation** — the `ALLM.Session` API (`start/3`,
      `reply/4`, `continue/3`, `submit_tool_result/3`, …) over a persisted
      `%ALLM.Session{}`.

  ## Hello, ALLM

  The deterministic `ALLM.Providers.Fake` adapter requires no API key and
  no network — it's the canonical test vehicle and the easiest way to see
  how a `chat/3` round-trip fits together:

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
      ...>)
      iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
      ...> ALLM.chat(engine, [ALLM.user("Hi.")])
      iex> text
      "Hello, ALLM!"

  Once that runs, swap `ALLM.Providers.Fake` for `ALLM.Providers.OpenAI`,
  `ALLM.Providers.Anthropic`, or `ALLM.Providers.Gemini` and provide a
  real `:model`. Keys resolve from per-call opts, engine config, app
  config, or environment variables — see `ALLM.Keys`.

  ## When to reach for what

  | You want to… | Use this | Returns |
  |---|---|---|
  | One-shot completion, no tools | `generate/3` | `{:ok, %ALLM.Response{}}` |
  | One-shot completion, with streaming | `stream_generate/3` | `{:ok, Enumerable.t}` of `t:ALLM.Event.t/0` |
  | Single round-trip with tool execution | `step/3` / `stream_step/3` | `{:ok, %ALLM.StepResult{}}` |
  | Multi-turn loop with auto tool execution | `chat/3` / `stream/3` | `{:ok, %ALLM.ChatResult{}}` |
  | Multi-turn with persistence between turns | `ALLM.Session` API | `{:ok, %ALLM.Session{}}` |
  | Generate or edit images | `generate_image/3`, `edit_image/4`, `image_variations/3` | `{:ok, %ALLM.ImageResponse{}}` |
  | Fold `generate/3` result into `{:ok, text}` | `unwrap/1` | `{:ok, String.t()} \| {:error, term()}` |

  Stateless calls (`generate/3` / `chat/3` / etc.) are pure functions of
  their inputs. The `ALLM.Session` API is what you use when the
  conversation needs to outlive a single request — the session struct
  encodes everything needed to resume after persisting it.

  ## Building messages

  The constructors below produce plain `%ALLM.Message{}` values you pass
  directly to a request or thread:

      iex> [ALLM.system("Be concise."), ALLM.user("Name three primes.")]
      ...> |> hd() |> Map.get(:role)
      :system

  Multi-modal content (text + images) is built with `ALLM.TextPart` and
  `ALLM.ImagePart`; see `guides/vision.md`.

  ## Where to next

    * `guides/getting_started.md` — install, run the Fake example, swap to
      a real provider.
    * `guides/streaming.md` — `stream_generate/3` / `stream/3`, the event
      union, filter opts, cancellation.
    * `guides/tools.md` — declaring tools, `mode: :auto` vs `mode:
      :manual`, per-tool `manual: true`, ask-user.
    * `guides/sessions.md` — multi-turn persistence patterns.
    * Module-by-module reference in the sidebar.
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
  `ArgumentError`. `:handler` is optional. Pass `manual: true` to opt this
  tool out of automatic execution under `chat/3`'s `mode: :auto`.

  ## Examples

      iex> tool = ALLM.tool(name: "weather", description: "weather by city", schema: %{"type" => "object"})
      iex> {tool.name, tool.description}
      {"weather", "weather by city"}
  """
  @spec tool(keyword()) :: Tool.t()
  def tool(opts), do: Tool.new(opts)

  @doc """
  Build the canonical tagged map for a JSON-schema response format.

  Returns `%{type: :json_schema, name: name, schema: schema, strict: boolean}`.
  `:strict` defaults to `true`; pass `strict: false` to relax provider-side
  schema enforcement.

  Pass the returned map as `:response_format` on a request to ask the
  provider to constrain its output to the schema.

  Atom-keyed schemas (and atom values such as `type: :object`) are
  normalized to strings via `ALLM.JsonSchema.normalize/1`, matching
  `ALLM.Tool.new/1`'s `:schema` handling. Pre-stringified maps pass
  through verbatim (fast path).

  ## Examples

      iex> ALLM.json_schema("person", %{"type" => "object"})
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: true}

      iex> ALLM.json_schema("person", %{"type" => "object"}, strict: false)
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: false}

      iex> ALLM.json_schema("person", %{type: :object, properties: %{name: %{type: :string}}}).schema
      %{"properties" => %{"name" => %{"type" => "string"}}, "type" => "object"}
  """
  @spec json_schema(String.t(), map(), keyword()) :: map()
  def json_schema(name, schema, opts \\ []) do
    %{
      type: :json_schema,
      name: name,
      schema: ALLM.JsonSchema.normalize(schema),
      strict: Keyword.get(opts, :strict, true)
    }
  end

  @doc """
  Build an `%ALLM.ImageRequest{}` from a prompt and keyword opts.
  Delegates to `ALLM.ImageRequest.new/1` after putting `:prompt` last in
  the opts list — the positional `prompt` is authoritative.

  Does **not** validate — call `ALLM.Validate.image_request/1` to check
  operation-arity and field rules. Mirrors `request/2`'s no-validate
  precedent: construction is composable, validation is an explicit step.
  Unknown opts raise `KeyError` via `struct!/2`.

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

  Does **not** validate — validation runs at the adapter boundary or via
  an explicit `ALLM.Validate.request/1` call. Construction stays
  composable: `request/2` returns a `%Request{}` directly, not an
  `{:ok | :error}` tuple.

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
  Open a streaming generation against the engine's adapter.

  Returns `{:ok, enumerable}` where the enumerable is a lazy stream of
  `t:ALLM.Event.t/0` values (no event fires until the caller reduces), or
  `{:error, struct}` on a synchronous pre-flight failure (missing adapter,
  invalid request, adapter-reported pre-flight error).

  Mid-stream adapter errors fold into a terminal `:message_completed`
  event with `finish_reason: :error` rather than a call-site error tuple
  — collect events with `ALLM.StreamCollector.to_response/1` to recover
  the full `%ALLM.Response{}` (including `metadata.error` when populated).

  ## Options

  In addition to any provider-specific opts the adapter honours, the
  following streaming-layer keys are consumed by this function:

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

  Multi-turn orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are
  silently stripped — `stream_generate/3` is single-request.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...>)
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
  Execute a non-streaming generation against the engine's adapter.

  Implemented as a reducer over `stream_generate/3` — the streaming path
  is the primitive. A mid-stream adapter error folds into
  `response.finish_reason == :error` with the error struct under
  `response.metadata.error`; pre-flight errors surface directly as
  `{:error, struct}` at the call site. Callers matching only
  `{:error, _}` will silently swallow rate limits, content-filter
  blocks, and stream cancellations — match on
  `response.finish_reason == :error` to handle mid-stream failures.

  ## Options

  Accepts the same options as `stream_generate/3`. `:include_raw_chunks`
  defaults to `false` but `{:usage, _}` raw chunks always survive the
  filter so `response.usage` is populated regardless.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...>)
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
  Fold a `generate/3`-shaped return tuple into `{:ok, text} | {:error, _}`.

  Useful when the caller just wants the response text or a clear error and
  doesn't need the full `%Response{}`. Composes with the
  pipe-into-`generate/3` pattern:

      engine
      |> ALLM.generate(ALLM.request([ALLM.user("hi")]))
      |> ALLM.unwrap()

  ## Clauses

    * `{:ok, %Response{finish_reason: :stop, message: %Message{content: list}}}`
      where `list` is a list (vision / structured parts) →
      `{:error, :structured_content}`. The caller should access
      `:message` directly. This branch fires BEFORE the text fold below.
    * `{:ok, %Response{finish_reason: :stop}}` → delegates to
      `ALLM.Response.text/1` (which prefers `:output_text` over
      `message.content`). Returns `{:ok, text}` when text is a binary;
      `{:error, :empty_stop_response}` when both `:output_text` and
      `message.content` are absent / non-binary.
    * `{:ok, %Response{finish_reason: :error, metadata: %{error: e}}}` →
      `{:error, e}` (mid-stream error folded back to the call site).
    * `{:ok, %Response{finish_reason: other}}` →
      `{:error, {:non_stop_finish, other}}` for non-stop finishes
      (`:length`, `:tool_calls`, `:content_filter`, `:other`).
    * `{:error, _} = err` → `err` (pass-through).

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]
      ...>)
      iex> ALLM.unwrap(ALLM.generate(engine, ALLM.request([ALLM.user("hi")])))
      {:ok, "hello"}
  """
  @spec unwrap({:ok, ALLM.Response.t()} | {:error, term()}) ::
          {:ok, String.t()} | {:error, term()}
  def unwrap({:ok, %ALLM.Response{finish_reason: :stop, message: %Message{content: c}}})
      when is_list(c),
      do: {:error, :structured_content}

  def unwrap({:ok, %ALLM.Response{finish_reason: :stop} = resp}) do
    # Delegate to Response.text/1 so the `:output_text → message.content
    # → nil` fall-back has a single implementation (Phase 21 F1). An
    # explicit `:empty_stop_response` surfaces the case where neither
    # `:output_text` nor `message.content` carries a binary — previously
    # mis-routed through the `:non_stop_finish` clause despite a `:stop`
    # finish.
    case ALLM.Response.text(resp) do
      text when is_binary(text) -> {:ok, text}
      nil -> {:error, :empty_stop_response}
    end
  end

  def unwrap({:ok, %ALLM.Response{finish_reason: :error, metadata: %{error: e}}}),
    do: {:error, e}

  def unwrap({:ok, %ALLM.Response{finish_reason: other}}),
    do: {:error, {:non_stop_finish, other}}

  def unwrap({:error, _} = err), do: err

  @doc """
  Execute a single chat step (one adapter round-trip plus any auto-executed
  tool calls) and return a `%ALLM.StepResult{}`.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}` (normalised via `ALLM.Thread.from_messages/1`). The
  thread is validated via `ALLM.Validate.thread/1` at entry.

  Use `step/3` when you want a single round-trip — one adapter call,
  with any tool calls executed inline — but you don't need the multi-turn
  loop. For full multi-turn behaviour use `chat/3`.

  ## Options

  In addition to any provider-specific opts the adapter honours:

    * `:mode` — `:auto` (default) executes tool calls inline; `:manual`
      returns them on the `%StepResult{}` for the caller to submit results.
    * `:tool_timeout` — milliseconds per tool (default `30_000`).
    * `:on_tool_error` — `:continue` (default) or `:halt`.
    * `:tool_executor`, `:tool_result_encoder` — module overrides.
    * Stream filter opts are accepted but have no effect on this
      non-streaming path.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> script: [
      ...> {:tool_call, id: "call_0", name: "weather", arguments: %{"city" => "NYC"}},
      ...> {:finish, :tool_calls}
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "weather",
      ...> description: "forecast by city",
      ...> schema: %{"type" => "object"},
      ...> handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
      ...>)]
      ...>)
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
  Execute a single chat step as a lazy stream of `t:ALLM.Event.t/0`
  values.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}`. The returned stream is open — no events fire until
  the caller reduces. Events arrive in this order: all adapter events
  (pass-through from `stream_generate/3`), then zero-to-N tool-execution
  event groups (per tool: `:tool_execution_started` →
  `:tool_execution_completed` → `:tool_result_encoded` /
  `:ask_user_requested` / `:tool_halt`), then exactly one terminal
  `:step_completed` event.

  ## Options

  Same as `step/3`. Additionally accepts the streaming filter opts
  (`:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
  `:on_event`) — they apply to the adapter-stream pass-through.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> script: [
      ...> {:tool_call, id: "call_0", name: "weather", arguments: %{"city" => "NYC"}},
      ...> {:finish, :tool_calls}
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "weather",
      ...> description: "forecast by city",
      ...> schema: %{"type" => "object"},
      ...> handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
      ...>)]
      ...>)
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
  `%ALLM.ChatResult{}`.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}` (normalised via `ALLM.Thread.from_messages/1`). The
  thread is validated via `ALLM.Validate.thread/1` at entry.

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

  `max_turns` must be a `pos_integer`; non-positive integers raise
  `ArgumentError`.

  ## `:halt_when` semantics

  `:halt_when` is a `(StepResult.t -> boolean)` callback invoked
  AFTER the step's thread mutation has been applied. It is the LAST
  per-step gate consulted — ask-user, handler `{:halt, _, _}`,
  `on_tool_error: :halt`, `:manual_tool_calls`, and adapter
  `finish_reason ∈ {:stop, :error, :length, :content_filter}` all
  preempt it. Exceptions raised inside `halt_when` propagate to the
  caller of `chat/3`; they are NOT caught.

  ## `:on_tool_error`

  Atom forms `:continue` (default) and `:halt` are the common cases.
  The function form `(ToolCall.t, term -> {:continue, term} |
  :halt)` is invoked synchronously inside the per-tool task after
  the handler's return / encoder failure resolves to an error term:
  `{:continue, replacement}` encodes `replacement` as the tool-result
  content; `:halt` halts the batch with `halted_reason: :tool_error`.
  An invalid return shape or a raise from inside the function is
  wrapped as `%ALLM.Error.ToolError{reason: :invalid_return}` and
  treated as `:halt`.

  ## `:on_event` scope

  `:on_event` observes only adapter-emitted events (text deltas,
  tool-call deltas, message bookends, `:raw_chunk`, adapter-emitted
  `:error`). Chat-layer events (`:tool_execution_*`,
  `:tool_result_encoded`, `:ask_user_requested`, `:tool_halt`,
  `:step_completed`, `:chat_completed`) are NOT delivered to
  `:on_event`.

  ## Halt-reason table

  | Reason | Fires when | `metadata` keys populated |
  |--------|------------|---------------------------|
  | `:completed` | Adapter `finish_reason ∈ {:stop, :length, :content_filter}` | `%{}` |
  | `:error` | Adapter `finish_reason: :error` (mid-stream error folds in) | `%{error: error_struct}` (when present) |
  | `:max_turns` | `step_index + 1 >= max_turns` after a non-halting step | `%{max_turns: N}` |
  | `:halt_when` | `halt_when.(step_result)` returned `true` | `%{halt_when_step_index: idx}` |
  | `:ask_user` | Handler returned `{:ask_user, _}` / `{:ask_user, _, _}` | `%{pending_question: q, pending_tool_call_id: id, ask_user_opts: opts}` (also on top-level `%ChatResult{}`) |
  | `:tool_error` | `on_tool_error: :halt`, fun returned `:halt`, or fun raised | `%{halt_tool_call_id: id}` (plus `:on_tool_error_exception` if fun raised) |
  | `:manual_tool_calls` | `mode: :manual` and step's `response.finish_reason == :tool_calls`, OR `mode: :auto` and one or more called tools have `manual: true` | `%{manual_turn_index: idx}` (whole-loop) — additionally `%{manual_tool_calls: [%ToolCall{}, ...]}` (per-tool, only the manual bucket) |
  | atom (user) | Handler returned `{:halt, reason, result}` not in the above set | `%{halt_tool_call_id: id, halt_result: result}` |

  ## Mixed-bucket re-issue (per-tool manual)

  When `mode: :auto` and at least one called tool has `manual: true`, the
  loop halts with `halted_reason: :manual_tool_calls` after running the
  auto-bucket tools. The returned `result.thread` carries the assistant
  message AND the auto-bucket `:tool` messages — but **NOT** placeholder
  messages for the manual ids. Naively re-issuing `chat/3` on
  `result.thread` sends a malformed request to the provider (assistant
  tool_calls with no matching `:tool` messages for the manual ids),
  surfacing as `%ALLM.Error.AdapterError{reason: :invalid_request}`.

  Callers MUST append a `:tool` message for each id in
  `result.metadata.manual_tool_calls` before re-issuing:

      {:ok, result} = ALLM.chat(engine, [ALLM.user("...")])

      # result.halted_reason == :manual_tool_calls
      # result.metadata.manual_tool_calls == [%ToolCall{id: "cm", ...}]

      # Resolve each manual call out-of-band, then append a :tool message.
      tool_msg = %ALLM.Message{
        role: :tool,
        content: "approved",
        tool_call_id: "cm"
      }
      augmented = ALLM.Thread.add_message(result.thread, tool_msg)

      {:ok, final} = ALLM.chat(engine, augmented)

  The `ALLM.Session` API (`ALLM.Session.start/3` +
  `ALLM.Session.submit_tool_result/3`) enforces this discipline
  automatically; raw `chat/3` callers must guard by hand. Whole-loop
  `mode: :manual` callers are unaffected — every tool call surfaces on
  `result.final_response.tool_calls`, no auto bucket exists.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> scripts: [
      ...> [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}],
      ...> [{:text, "done"}, {:finish, :stop}]
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
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
  Stream a multi-turn chat loop as a lazy enumerable of `t:ALLM.Event.t/0`
  values terminating in exactly one `:chat_completed` event.

  `thread_or_messages` is either an `%ALLM.Thread{}` or a list of
  `%ALLM.Message{}`. The returned stream is open — no events fire
  until the caller reduces.

  ## Single terminal `:chat_completed`

  A naturally-terminating stream emits adapter events plus tool
  events for each turn, one `:step_completed` per turn, and exactly
  one trailing `{:chat_completed, %{result: %ChatResult{}}}` event.
  Both `chat/3` and `stream/3 |> ALLM.StreamCollector.to_chat_result/1`
  produce the SAME `%ChatResult{}` for identical inputs.

  Consumer halts (`Enum.take/2`, `Stream.take_while/2`) produce NO
  `:chat_completed` event; callers needing a final `%ChatResult{}`
  for a cancelled stream collect events and call
  `ALLM.StreamCollector.to_chat_result/1` on the partial state — the
  fallback path returns `halted_reason: :cancelled`.

  ## Stream-first

  `chat/3` is itself a reducer over this stream. The streaming path
  is the primitive; the non-streaming variant exists so callers
  who don't need event-level visibility get a synchronous result.

  ## Ask-user thread asymmetry

  When a step's handler returns `{:ask_user, _}`, the streamed
  `:step_completed.thread` does NOT include the assistant question
  message — only the terminal `:chat_completed.result.thread` does.
  Consumers persisting thread state across turns must read
  `ChatResult.thread`, never `:step_completed.thread`.

  ## `:on_event` scope

  Same as `chat/3` and `stream_generate/3`: `:on_event` observes only
  adapter-emitted events. Chat-layer events
  (`:tool_execution_*`, `:tool_result_encoded`, `:ask_user_requested`,
  `:tool_halt`, `:step_completed`, `:chat_completed`) are NOT
  delivered to `:on_event`.

  ## Options

  Same options as `chat/3`. The streaming filter opts
  (`:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
  `:on_event`) apply to each turn's adapter pass-through.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> scripts: [
      ...> [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}],
      ...> [{:text, "done"}, {:finish, :stop}]
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
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
  Generate one or more images against the engine's `:image_adapter`.

  Layer-C façade. Two input shapes:

    * Binary `prompt` — sugar over `ALLM.image_request/2`. Opts merge into
      the built `%ALLM.ImageRequest{operation: :generate}`.
    * Pre-built `%ALLM.ImageRequest{}` — dispatched verbatim.

  ## Adapter-presence gate

  Returns `{:error, %ALLM.Error.EngineError{reason: :no_image_adapter}}`
  when `engine.image_adapter == nil`. This is the first gate; no other
  validation runs.

  ## Validation policy

  The façade does NOT call `ALLM.Validate.image_request/1`. Caller-opt-in
  only — mirrors `request/2`'s no-validate precedent. A manually-built
  request that the validator would reject (e.g., empty prompt for
  `:generate`) still dispatches.

  ## `request_id` precedence

  `opts[:request_id]` wins over an auto-generated id from
  `ALLM.Telemetry.request_id/0`. The id is forwarded to the adapter via
  `opts[:request_id]`. After the call, `response.request_id` is filled
  from the forwarded id IFF the adapter left it `nil`; an
  adapter-populated `:request_id` (e.g. provider's `x-request-id`
  header) is preserved.

  ## `:stream` opt is silently dropped

  Image generation is non-streaming. Passing `stream: true` does not
  error — the opt is ignored.

  ## Unknown opts

  Forwarded to the adapter via `opts` (matches the chat-side
  `Engine.resolve_params/2` pass-through pattern).

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> engine = ALLM.Engine.new(
      ...> image_adapter: ALLM.Providers.FakeImages,
      ...> adapter_opts: [image_script: [{:ok, [img]}]]
      ...>)
      iex> {:ok, %ALLM.ImageResponse{images: [_]}} = ALLM.generate_image(engine, "a kestrel")
      iex> :ok
      :ok

      iex> engine = ALLM.Engine.new()
      iex> {:error, %ALLM.Error.EngineError{reason: :no_image_adapter}} =
      ...> ALLM.generate_image(engine, "a kestrel")
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
  `:image_adapter`.

  Three call shapes:

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
      ...> image_adapter: ALLM.Providers.FakeImages,
      ...> adapter_opts: [image_script: [{:ok, [img]}]]
      ...>)
      iex> base = ALLM.Image.from_binary(<<1, 2, 3>>, "image/png")
      iex> {:ok, %ALLM.ImageResponse{images: [_]}} =
      ...> ALLM.edit_image(engine, base, "make sky pink")
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
  `:image_adapter`.

  Builds `%ImageRequest{operation: :variation, input_images: [image],
  prompt: nil}` and forwards opts. Returns
  `{:error, %EngineError{reason: :no_image_adapter}}` when the engine
  has no image adapter (first gate).

  See `generate_image/3` for the full `request_id` and `:stream`-drop
  semantics.

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> engine = ALLM.Engine.new(
      ...> image_adapter: ALLM.Providers.FakeImages,
      ...> adapter_opts: [image_script: [{:ok, [img]}]]
      ...>)
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
  # Internals — image telemetry + preflight + retry wrap.
  # ---------------------------------------------------------------------------

  # Image-side retryable reason atoms. Engaged by both
  # `augment_image_retry_policy/1` (extends the chat-side default
  # policy's `retry_on` at the call site) and `dispatch_image_attempt/3`
  # (the per-attempt closure passed to `Retry.run/3`).
  @retryable_image_reasons [:rate_limited, :provider_unavailable, :timeout, :network_error]

  # Drop call-control opts that would collide with `ImageRequest` struct
  # fields when merged into `ImageRequest.new/1`. These are call/dispatch-site
  # concerns, not request fields — `ImageRequest.new/1` would `KeyError` on
  # them via `struct!/2`. `:mask` is consumed at the `edit_image/4` boundary;
  # the rest are forwarded to the adapter via `dispatch_opts`.
  defp drop_request_opts(opts) when is_list(opts) do
    Keyword.drop(opts, [
      :request_id,
      :stream,
      :mask,
      :adapter_opts,
      :request_timeout,
      :retry,
      :api_key,
      :telemetry_metadata
    ])
  end

  # Wrap the entire body in `Telemetry.span(:image, ...)` so the `:start`
  # event ALWAYS fires (even when the adapter is missing or preflight
  # rejects) — observability is uniform. Inside the span, the
  # `with`-chain runs in this order:
  #
  #   (1) adapter-presence gate (`engine.image_adapter != nil`) — FIRST
  #   (2) `Capability.preflight_image/2` (no-op when catalog absent)
  #   (3) `Retry.run/3`-wrapped dispatch
  defp do_generate_image(%Engine{} = engine, %ImageRequest{} = request, opts) do
    request_id = Keyword.get(opts, :request_id) || ALLM.Telemetry.request_id()
    resolved_model = Engine.resolve_model(engine, opts)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: resolved_model,
      operation: request.operation,
      n: request.n
    }

    ALLM.Telemetry.span(:image, start_metadata, fn ->
      result = do_generate_image_body(engine, request, opts, request_id, resolved_model)
      {extras, measurements} = image_stop_extras(result)
      {result, measurements, extras}
    end)
  end

  defp do_generate_image_body(
         %Engine{image_adapter: nil},
         _request,
         _opts,
         _request_id,
         _resolved_model
       ) do
    # Adapter-presence gate fires FIRST so a missing adapter +
    # tools-disabled-model surfaces `:no_image_adapter`, not
    # `:unsupported_capability`.
    {:error, EngineError.new(:no_image_adapter)}
  end

  defp do_generate_image_body(
         %Engine{image_adapter: adapter} = engine,
         %ImageRequest{} = request,
         opts,
         request_id,
         resolved_model
       ) do
    with :ok <- ALLM.Capability.preflight_image(resolved_model, request) do
      # Stamp the engine-resolved model onto the request so adapters that
      # gate / shape the wire body off `request.model` (e.g. OpenAI's
      # multipart `:edit` / `:variation`, which require `model` on the
      # wire) see it. Mirrors the chat-side
      # `StreamRunner.resolve_request_model/3`. Preserves an
      # explicitly-set request model.
      request = %{request | model: request.model || resolved_model}

      # Concat engine.adapter_opts with call-site adapter_opts.
      # `Keyword.get/2` returns the FIRST occurrence on duplicate keys, so
      # engine wins on collision. Mirrors the chat-side
      # `StreamRunner.build_dispatch_opts/2` adapter_opts concat (NOT
      # `Keyword.merge/2`, which would have OPPOSITE precedence — call
      # wins).
      merged_adapter_opts =
        engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, [])

      dispatch_opts =
        opts
        |> Keyword.drop([:stream])
        |> Keyword.put(:request_id, request_id)
        |> Keyword.put(:adapter_opts, merged_adapter_opts)

      # Pass `telemetry_metadata` to `Retry.run/3` so any
      # `[:allm, :adapter, :retry]` event shares the surrounding
      # `:image` span's correlation id.
      telemetry_metadata = %{
        request_id: request_id,
        model: resolved_model,
        operation: request.operation
      }

      # Augment the engine's retry policy with the image-side
      # retryable reasons. The default chat-side policy's `retry_on` is
      # HTTP-status-coded (`[429, 500, 502, 503, 504, :timeout]`); image
      # adapters surface closed-enum atoms (`:rate_limited`,
      # `:provider_unavailable`, `:timeout`, `:network_error`) via
      # `%ImageAdapterError{}`. We extend `retry_on` here at the call
      # site so `ALLM.Retry.error_matches?/2` recognises image atoms,
      # without modifying the chat-side default.
      policy = augment_image_retry_policy(engine.retry)

      result =
        ALLM.Retry.run(policy, telemetry_metadata, fn ->
          dispatch_image_attempt(adapter, request, dispatch_opts)
        end)

      case result do
        {:ok, %ImageResponse{request_id: nil} = response} ->
          {:ok, %{response | request_id: request_id}}

        {:ok, %ImageResponse{} = response} ->
          {:ok, response}

        {:error, _} = err ->
          err
      end
    end
  end

  # Per-attempt closure for `Retry.run/3`. Engages the retry loop on the
  # four documented retryable `ImageAdapterError` reasons (see
  # `@retryable_image_reasons` at the top of this internals block);
  # surfaces any other error verbatim with NO retry attempt.
  defp augment_image_retry_policy(false), do: :no_retry

  defp augment_image_retry_policy(retry_config) do
    case ALLM.Retry.materialize(retry_config) do
      :no_retry ->
        :no_retry

      %{retry_on: existing} = policy ->
        # Append image atoms to the chat-side retry_on. Idempotent —
        # `Enum.uniq/1` keeps the list stable on repeat calls.
        %{policy | retry_on: Enum.uniq(existing ++ @retryable_image_reasons)}
    end
  end

  defp dispatch_image_attempt(adapter, request, dispatch_opts) do
    case adapter.generate(request, dispatch_opts) do
      {:ok, _} = ok ->
        ok

      {:error, %ImageAdapterError{reason: reason} = err}
      when reason in @retryable_image_reasons ->
        delay = err.retry_after_ms || 0
        {:retry, delay, err}

      {:error, _} = err ->
        err
    end
  end

  # Compute `:stop`-event extras: `image_count` is a MEASUREMENT (numeric
  # — the actual number of images on success / `0` on error). `:usage`,
  # `:response`, `:error` are METADATA (structured context). Returns
  # `{metadata_extras, extra_measurements}`.
  defp image_stop_extras({:ok, %ImageResponse{} = response}) do
    metadata = %{
      usage: response.usage,
      response: response,
      error: nil
    }

    measurements = %{image_count: length(response.images)}
    {metadata, measurements}
  end

  defp image_stop_extras({:error, error}) do
    metadata = %{
      usage: nil,
      response: nil,
      error: error
    }

    measurements = %{image_count: 0}
    {metadata, measurements}
  end
end
