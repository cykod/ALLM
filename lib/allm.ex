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

  ## Example

      iex> messages = [ALLM.system("Be helpful."), ALLM.user("Name three primes.")]
      iex> req = ALLM.request(messages, model: "fake:gpt-test")
      iex> :ok = ALLM.Validate.request(req)
      iex> json = ALLM.Serializer.to_json!(req)
      iex> {:ok, ^req} = ALLM.Serializer.from_json(json)

  See `steering/allm_engine_session_streaming_spec_v0_2.md` §4 for the full
  public API surface.
  """

  alias ALLM.{Engine, Message, Request, StepResult, Thread, Tool}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

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
end
