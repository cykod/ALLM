defmodule ALLM.Session do
  @moduledoc """
  A stateful, serializable chat session. See spec §5.7 and §11.

  Layer A — pure serializable data; Layer D — stateful continuation
  operations (`start/3`, `reply/4`, `continue/3`, `step/3`,
  `submit_tool_result/3`, `submit_tool_results/2`) shipped in Phase 8 wrap
  Phase 7's `ALLM.Chat.run/3` and `ALLM.Chat.step/3`.

  ## Status + `pending_*` fields

  The `:status` atom is a closed union:

    * `:idle` — the session is ready for a new user turn.
    * `:awaiting_user` — the loop halted mid-step requesting user input;
      `:pending_question` is a non-nil binary carrying the question and
      `:pending_tool_call_id` binds the answer to the originating tool call.
    * `:awaiting_tools` — the loop halted with pending tool calls the caller
      must execute; `:pending_tool_calls` is the non-empty list.
    * `:completed` — the loop terminated normally.
    * `:error` — an unrecoverable adapter or tool error occurred. By
      convention `metadata[:error]` holds the underlying `%ALLM.Error.*{}`
      struct for post-mortem inspection. `ALLM.Validate.session/1`
      (sub-phase 1.4) enforces this.

  ## Status transitions (Phase 8)

  Phase-8 operations form the closed state-machine arrows over the status
  union. The full matrix lives in `steering/PHASE_8_DESIGN.md` §Overview;
  the abridged shape:

  | From \\ Op | `start/3` | `reply/4` | `continue/3` | `step/3` | `submit_tool_result/3` |
  |-----------|-----------|-----------|--------------|----------|------------------------|
  | `:idle` | n/a (fresh-session entry) | legal | legal | legal | **`ArgumentError`** |
  | `:awaiting_user` | n/a | legal — clears pending fields | **`ArgumentError`** (\\*) | **`ArgumentError`** | **`ArgumentError`** |
  | `:awaiting_tools` | n/a | **`ArgumentError`** | legal IFF `nil` message AND `pending_tool_calls == []` | **`ArgumentError`** | legal |
  | `:completed` | n/a | legal (treated as `:idle`) | legal (treated as `:idle`) | legal (treated as `:idle`) | **`ArgumentError`** |
  | `:error` | n/a | `{:error, %SessionError{}}` | `{:error, %SessionError{}}` | `{:error, %SessionError{}}` | `{:error, %SessionError{}}` |

  **Status-precondition violations RAISE `ArgumentError`** — they're
  programmer errors (Decision #7). **Data mismatches return `{:error,
  %SessionError{}}`** — `unknown_tool_call_id` on `submit_tool_result/3` is
  the canonical case. `:error`-status sessions return
  `{:error, %SessionError{reason: :session_in_error_state}}` on every
  Phase-8 operation; construct a fresh session to recover.

  > #### (\\*) `continue/3` on `:awaiting_user` {: .info}
  >
  > `continue/3` raises `ArgumentError` on `:awaiting_user` for the
  > common case (caller should use `reply/4`). The one exception is the
  > delegation path: `reply/4` is implemented as
  > `continue(engine, session, ALLM.user(text), opts)` (Decision #4), so
  > `continue/3` accepts a `%Message{role: :user}` on `:awaiting_user`
  > as the legal `reply/4`-equivalent dispatch. Calling `continue/3`
  > directly with any other shape on `:awaiting_user` raises. Prefer
  > `reply/4` for clarity at call sites.

  ## Mid-stream errors

  When `ALLM.Chat.run/3` returns a `%ChatResult{halted_reason: :error}`
  (mid-stream adapter error folded into the response per CLAUDE.md), the
  resulting session has `status: :error` and `metadata.error` populated
  with the underlying `%ALLM.Error.AdapterError{}` (or other Phase 1
  error struct). The call-site tuple stays `{:ok, _}`; the failure is on
  the session, not on the tuple.

  ## Manual-mode tool cycle

  `mode: :manual` halts at the first tool-call response with
  `status: :awaiting_tools` and `pending_tool_calls` populated. The
  caller submits results via `submit_tool_result/3` (single) or
  `submit_tool_results/2` (batch); each call appends a `:tool`-role
  message to `session.thread`, removes the matching tool call from
  `pending_tool_calls`, and flips `status` back to `:idle` when the last
  pending call is submitted. The caller then invokes `continue/3` with a
  `nil` message to drive the next adapter turn.

  ## Per-tool manual cycle (Phase 18)

  When `mode: :auto` and any called tool has `manual: true`,
  `:awaiting_tools` is entered with `pending_tool_calls` containing
  **only** the manual subset; auto tools have already executed and their
  `:tool` messages are in `session.thread`. The same
  `submit_tool_result/3` flow resolves the manual subset; submitting a
  result for an AUTO-bucket id returns
  `{:error, %SessionError{reason: :unknown_tool_call_id}}` because that
  id already ran and is not in `pending_tool_calls`. `mode: :manual`
  whole-loop wins over per-tool flags (Phase 18 Decision #5): under
  `mode: :manual`, `pending_tool_calls` is the full
  `response.tool_calls` list regardless of any tool's `manual` flag.

  ## `context` is caller-owned

  The `:context` field is a free-form `map()` the library threads through
  to arity-2 tool handlers (spec §5.2). The library does **not** walk or
  validate its contents — a caller stuffing `DateTime`, `Decimal`, an
  `Ecto.Repo` reference, or a callback module is legitimate.

  The Layer A serializability invariant is preserved **only for values the
  caller knows are serializable**. Stuffing a PID, ref, or anonymous
  function into `:context` will cause `:erlang.term_to_binary/1` to raise
  `ArgumentError` at persist time; this is the caller's responsibility,
  not the library's. See the Phase 1 design (non-obvious decision #8) for
  the rationale. A typed `serializable()` walk may land in v0.3.

  ## `context` propagation (Phase 8 — Decision #10)

  Every Phase-8 operation sets `:context` on the opts forwarded to
  `ALLM.Chat.run/3` / `ALLM.Chat.step/3` to `session.context` UNLESS the
  caller has already passed `context:` in the call opts (caller-wins).
  The resolution chain is `caller_opts > session.context >
  engine.context`; this is enforced by `merge_session_opts/2`, the single
  resolution point.

  ## `session_id` propagation (Phase 8 — Decision #9)

  Symmetric to `:context`: every Phase-8 operation sets `:session_id` on
  the opts forwarded to `ALLM.Chat.run/3` / `ALLM.Chat.step/3` to
  `session.id` UNLESS the caller has already passed `session_id:` in the
  call opts. When `session.id` is `nil` (no id assigned), no opt is
  added — the tool handler sees `nil`.
  """

  alias ALLM.{Chat, ChatResult, Engine, Message, StepResult, Thread, ToolCall}
  alias ALLM.Error.{AdapterError, EngineError, SessionError, ValidationError}

  @type status :: :idle | :awaiting_user | :awaiting_tools | :completed | :error

  @type t :: %__MODULE__{
          id: String.t() | nil,
          thread: Thread.t(),
          status: status(),
          pending_tool_calls: [ToolCall.t()],
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          context: map(),
          metadata: map()
        }

  @typedoc """
  Options accepted by `start/3`, `reply/4`, `continue/3`, `step/3`. A
  superset of `ALLM.Chat.chat_opts/0`; everything not listed below flows
  verbatim to `ALLM.Chat.run/3` / `ALLM.Chat.step/3`.

    * `:mode` — `:auto` (default) or `:manual`. Per-call; not sticky.
    * `:max_turns` — `pos_integer()`; same precedence as Phase 7.
    * `:halt_when` — `(StepResult.t() -> boolean())`; runtime fun, NEVER
      stored on `%Session{}`.
    * `:on_tool_error`, `:tool_timeout`, `:tool_executor`,
      `:tool_result_encoder` — Phase 6/7 pass-through.
    * `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
      `:on_event` — Phase 5 stream-filter pass-through.
    * `:session_id`, `:context` — caller-wins overrides; default to
      `session.id` / `session.context`.
  """
  @type session_opts :: keyword()

  @typedoc """
  Input shape accepted where the spec calls for `[Message.t()]`. A
  `%Session{}` passes through; a `%Thread{}` or `[Message.t()]` is wrapped
  via `Session.new/1`. Anything else surfaces as
  `{:error, %ValidationError{reason: :invalid_session_input}}`.
  """
  @type session_input :: t() | Thread.t() | [Message.t()]

  defstruct [
    :id,
    :pending_question,
    :pending_tool_call_id,
    thread: %Thread{},
    status: :idle,
    pending_tool_calls: [],
    context: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec append(t(), Message.t()) :: t()
  def append(%__MODULE__{thread: thread} = s, %Message{} = m),
    do: %{s | thread: Thread.add_message(thread, m)}

  @spec append_user(t(), String.t()) :: t()
  def append_user(s, text), do: append(s, %Message{role: :user, content: text})

  @spec append_tool_result(t(), String.t(), String.t() | map()) :: t()
  def append_tool_result(s, tool_call_id, content) do
    append(s, %Message{role: :tool, tool_call_id: tool_call_id, content: content})
  end

  @spec pending_tool_calls(t()) :: [ToolCall.t()]
  def pending_tool_calls(%__MODULE__{pending_tool_calls: calls}), do: calls

  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{thread: thread}), do: Thread.messages(thread)

  # ===========================================================================
  # Phase 8 — non-streaming Layer D operations
  # ===========================================================================

  @doc """
  Start a new session by running `ALLM.Chat.run/3` against `engine` and
  the supplied input.

  `session_input` may be a `%Session{}` (preserves `:id`, `:context`,
  `:metadata`), a `%Thread{}`, or a list of `%Message{}` (per Decision
  #2). Anything else returns
  `{:error, %ValidationError{reason: :invalid_session_input}}`.

  Returns `{:ok, %Session{}, %ChatResult{}}` on a successful adapter
  round-trip. The session's `:status` reflects the chat result's
  `:halted_reason` (see status-transition table in the moduledoc).

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> {:ok, session, result} = ALLM.Session.start(engine, [ALLM.user("hello")])
      iex> session.status
      :completed
      iex> result.halted_reason
      :completed
  """
  @spec start(Engine.t(), session_input(), session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def start(%Engine{} = engine, session_input, opts \\ []) when is_list(opts) do
    with {:ok, session} <- coerce_session_input(session_input),
         :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :start),
         merged_opts <- merge_session_opts(session, opts),
         {:ok, %ChatResult{} = chat_result} <- Chat.run(engine, session.thread, merged_opts) do
      {:ok, apply_chat_result(session, chat_result), chat_result}
    end
  end

  @doc """
  Append a `:user`-role message with `user_text` and run `ALLM.Chat.run/3`.

  Equivalent to `continue(engine, session, ALLM.user(user_text), opts)`.
  See `continue/3`.

  Legal on `:idle`, `:awaiting_user` (clears the pending fields), and
  `:completed` (treated as `:idle` per Decision #5). Raises
  `ArgumentError` on `:awaiting_tools`. Returns
  `{:error, %SessionError{reason: :session_in_error_state}}` on `:error`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:text, "ok"}, {:finish, :stop}],
      ...>       [{:text, "again"}, {:finish, :stop}]
      ...>     ]
      ...>   ]
      ...> )
      iex> {:ok, s, _} = ALLM.Session.start(engine, [ALLM.user("hi")])
      iex> {:ok, s2, _} = ALLM.Session.reply(engine, s, "again")
      iex> length(ALLM.Session.messages(s2)) > length(ALLM.Session.messages(s))
      true
  """
  @spec reply(Engine.t(), t(), String.t(), session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def reply(%Engine{} = engine, %__MODULE__{} = session, user_text, opts \\ [])
      when is_binary(user_text) and is_list(opts) do
    continue(engine, session, %Message{role: :user, content: user_text}, opts)
  end

  @doc """
  Drive the next adapter turn on a session.

  When `message` is a `%Message{}`, it is appended to `session.thread`
  before the adapter call. When `message` is `nil`, no append happens —
  this form is used for manual-tool-cycle resumption after the caller
  has populated tool-role messages via `submit_tool_result/3` (see
  Decision #4).

  Status preconditions:

    * `:idle`, `:completed` — legal with any `message`.
    * `:awaiting_user` — raises `ArgumentError` (caller should use
      `reply/4` to clear pending fields and supply user text). The
      `reply/4` delegation passes a `%Message{role: :user}` through
      this function, so a user-role message on `:awaiting_user` is
      legal as the delegated path; any other shape raises.
    * `:awaiting_tools` — legal **only** with `message == nil` AND
      `pending_tool_calls == []` (i.e., the caller has already submitted
      every pending tool result and the session has flipped back to
      `:idle`). Calling on `:awaiting_tools` while `pending_tool_calls`
      is non-empty raises `ArgumentError`.
    * `:error` — returns `{:error, %SessionError{reason:
      :session_in_error_state}}`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:text, "first"}, {:finish, :stop}],
      ...>       [{:text, "second"}, {:finish, :stop}]
      ...>     ]
      ...>   ]
      ...> )
      iex> {:ok, s, _} = ALLM.Session.start(engine, [ALLM.user("hi")])
      iex> {:ok, s2, _} = ALLM.Session.continue(engine, s, ALLM.user("more"))
      iex> s2.status
      :completed
  """
  @spec continue(Engine.t(), t(), Message.t() | nil, session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def continue(%Engine{} = engine, %__MODULE__{} = session, message, opts \\ [])
      when is_list(opts) and (is_nil(message) or is_struct(message, Message)) do
    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, {:continue, message}),
         session <- maybe_append_message(session, message),
         session <- clear_pending_for_continue(session),
         merged_opts <- merge_session_opts(session, opts),
         {:ok, %ChatResult{} = chat_result} <- Chat.run(engine, session.thread, merged_opts) do
      {:ok, apply_chat_result(session, chat_result), chat_result}
    end
  end

  @doc """
  Run a single adapter turn (`ALLM.Chat.step/3`) on the session.

  Unlike `continue/3`, `step/3` does not loop — it dispatches one
  adapter call and returns the resulting `%StepResult{}` projected onto
  the session via `apply_step_result/2`. Status follows Phase 6's
  semantics; see `steering/PHASE_8_DESIGN.md` Decision #6 for the table.

  Legal on `:idle` and `:completed` (treated as `:idle`). Raises
  `ArgumentError` on `:awaiting_user` and `:awaiting_tools`. Returns
  `{:error, %SessionError{reason: :session_in_error_state}}` on
  `:error`.

  ## Examples

  `step/3` is a single-turn entry point; this doctest seeds the thread
  directly via `Session.new/1` to keep the example focused on the
  single-step return shape. The `start/3 → step/3` flow is tested in
  `test/allm/session_test.exs`.

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> {:ok, s, sr} = ALLM.Session.step(engine, ALLM.Session.new(thread: ALLM.Thread.from_messages([ALLM.user("hi")])))
      iex> sr.done?
      true
      iex> s.status
      :completed
  """
  @spec step(Engine.t(), t(), session_opts()) ::
          {:ok, t(), StepResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def step(%Engine{} = engine, %__MODULE__{} = session, opts \\ []) when is_list(opts) do
    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :step),
         merged_opts <- merge_session_opts(session, opts),
         {:ok, %StepResult{} = step_result} <- Chat.step(engine, session.thread, merged_opts) do
      {:ok, apply_step_result(session, step_result), step_result}
    end
  end

  # ===========================================================================
  # Phase 8 — streaming Layer D operations (sub-phase 8.3)
  # ===========================================================================

  @doc """
  Streaming counterpart to `start/3`. Returns `{:ok, stream}` where the
  stream is the inner `ALLM.Chat.stream/3` enumerable verbatim.

  Pre-flight errors (missing adapter, `coerce_session_input/1` failure,
  status precondition, `:error`-status session) are returned `{:error,
  _}` SYNCHRONOUSLY before any stream is constructed. Mid-stream adapter
  errors fold into the terminal `:chat_completed` event's
  `result.halted_reason: :error`; the call-site tuple stays `{:ok,
  stream}`. Mirrors Phase 7's `Chat.stream/3` synchronous-vs-lazy split.

  The consumer drives `ALLM.Session.StreamReducer` themselves to recover
  the post-call session and `%ChatResult{}` (see Decision #15). No
  session-side state changes happen until `StreamReducer.finalize/1`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> {:ok, stream} = ALLM.Session.stream_start(engine, [ALLM.user("hello")])
      iex> events = Enum.to_list(stream)
      iex> Enum.count(events, &match?({:chat_completed, _}, &1))
      1
  """
  @spec stream_start(Engine.t(), session_input(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def stream_start(%Engine{} = engine, session_input, opts \\ []) when is_list(opts) do
    with {:ok, session} <- coerce_session_input(session_input),
         :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :start),
         merged_opts <- merge_session_opts(session, opts) do
      Chat.stream(engine, session.thread, merged_opts)
    end
  end

  @doc """
  Streaming counterpart to `reply/4`. Appends a `:user`-role message
  with `user_text` to `session.thread`, then dispatches via
  `ALLM.Chat.stream/3`. Returns `{:ok, stream}` whose terminal event is
  `:chat_completed`.

  Status preconditions (synchronous, BEFORE the stream is constructed):

    * `:idle`, `:completed` — legal.
    * `:awaiting_user` — legal; pending fields are cleared at
      `StreamReducer.finalize/1` time via `apply_chat_result/2`.
    * `:awaiting_tools` — raises `ArgumentError`.
    * `:error` — returns `{:error, %SessionError{reason:
      :session_in_error_state}}`.

  Pre-flight errors (missing adapter, validation, status precondition)
  surface synchronously; mid-stream adapter errors fold into the
  terminal `:chat_completed` event's `result.halted_reason: :error`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:text, "ok"}, {:finish, :stop}],
      ...>       [{:text, "again"}, {:finish, :stop}]
      ...>     ]
      ...>   ]
      ...> )
      iex> {:ok, s, _} = ALLM.Session.start(engine, [ALLM.user("hi")])
      iex> {:ok, stream} = ALLM.Session.stream_reply(engine, s, "again")
      iex> Enum.count(Enum.to_list(stream), &match?({:chat_completed, _}, &1))
      1
  """
  @spec stream_reply(Engine.t(), t(), String.t(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def stream_reply(%Engine{} = engine, %__MODULE__{} = session, user_text, opts \\ [])
      when is_binary(user_text) and is_list(opts) do
    message = %Message{role: :user, content: user_text}

    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, {:continue, message}),
         session <- maybe_append_message(session, message),
         session <- clear_pending_for_continue(session),
         merged_opts <- merge_session_opts(session, opts) do
      Chat.stream(engine, session.thread, merged_opts)
    end
  end

  @doc """
  Streaming counterpart to `step/3`. Returns `{:ok, stream}` whose
  terminal event is `:step_completed` (NOT `:chat_completed` — per
  Decision #11). Composes `ALLM.Chat.stream_step/3`; the stream
  represents one adapter turn.

  Pre-flight errors (missing adapter, status precondition, `:error`
  state) surface synchronously. Consumers fold the stream through
  `ALLM.Session.StreamReducer.new(session, mode: :step)` to recover
  `{updated_session, %StepResult{}}`.

  Legal on `:idle` and `:completed`. Raises `ArgumentError` on
  `:awaiting_user` and `:awaiting_tools`. Returns
  `{:error, %SessionError{reason: :session_in_error_state}}` on
  `:error`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> session = ALLM.Session.new(thread: ALLM.Thread.from_messages([ALLM.user("hi")]))
      iex> {:ok, stream} = ALLM.Session.stream_step(engine, session)
      iex> events = Enum.to_list(stream)
      iex> Enum.count(events, &match?({:step_completed, _}, &1))
      1
  """
  @spec stream_step(Engine.t(), t(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def stream_step(%Engine{} = engine, %__MODULE__{} = session, opts \\ []) when is_list(opts) do
    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :step),
         merged_opts <- merge_session_opts(session, opts) do
      Chat.stream_step(engine, session.thread, merged_opts)
    end
  end

  @doc """
  Submit a tool-role result for one pending tool call. In-process state
  mutation only; this does NOT call the adapter (Decision #3).

  Appends a `:tool`-role message to `session.thread` with the supplied
  `tool_call_id` and `content`, removes the matching `%ToolCall{}` from
  `pending_tool_calls`, and flips `status` back to `:idle` when the last
  pending call is submitted.

  Returns the updated `%Session{}` on success or `{:error,
  %SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id:
  id}}}` when the id doesn't match any pending call (Decision #14 —
  data-validation, not a programmer-flow error).

  Raises `ArgumentError` if `session.status != :awaiting_tools`
  (Decision #7).

  > #### Doctest setup {: .info}
  >
  > Per `steering/PHASE_8_DESIGN.md` §8.2.2, this doctest constructs an
  > `:awaiting_tools` session by hand instead of driving through
  > `start/3` to keep the example focused.

  ## Examples

      iex> tc = %ALLM.ToolCall{id: "c0", name: "echo", arguments: %{}}
      iex> session = ALLM.Session.new(
      ...>   status: :awaiting_tools,
      ...>   pending_tool_calls: [tc],
      ...>   thread: ALLM.Thread.from_messages([ALLM.user("hi")])
      ...> )
      iex> updated = ALLM.Session.submit_tool_result(session, "c0", %{ok: true})
      iex> updated.status
      :idle
      iex> updated.pending_tool_calls
      []
  """
  @spec submit_tool_result(t(), String.t(), String.t() | map()) ::
          t() | {:error, SessionError.t()}
  def submit_tool_result(%__MODULE__{} = session, tool_call_id, content)
      when is_binary(tool_call_id) do
    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :submit_tool_result) do
      do_submit_tool_result(session, tool_call_id, content)
    end
  end

  defp do_submit_tool_result(%__MODULE__{} = session, tool_call_id, content) do
    case Enum.split_with(session.pending_tool_calls, fn tc -> tc.id == tool_call_id end) do
      {[], _} ->
        {:error,
         SessionError.new(:unknown_tool_call_id,
           message: "tool_call_id #{inspect(tool_call_id)} not in pending_tool_calls",
           metadata: %{tool_call_id: tool_call_id}
         )}

      {[_match], remaining} ->
        new_thread =
          Thread.add_message(session.thread, %Message{
            role: :tool,
            tool_call_id: tool_call_id,
            content: encode_tool_content(content)
          })

        new_status = if remaining == [], do: :idle, else: :awaiting_tools

        %{
          session
          | thread: new_thread,
            pending_tool_calls: remaining,
            status: new_status
        }
    end
  end

  @doc """
  Submit a batch of tool-role results in order.

  Equivalent to folding `submit_tool_result/3` over `results`; on the
  first `{:error, _}` the fold short-circuits and returns that error
  unchanged — no partial submissions land (matches `ALLM.Validate`'s
  hard-reject semantics).

  An empty list is identity (returns the session unchanged).

  Errors mirror `submit_tool_result/3`: an unknown id yields
  `{:error, %SessionError{reason: :unknown_tool_call_id}}`. A status
  mismatch raises `ArgumentError`.

  ## Examples

      iex> tc0 = %ALLM.ToolCall{id: "c0", name: "echo", arguments: %{}}
      iex> tc1 = %ALLM.ToolCall{id: "c1", name: "echo", arguments: %{}}
      iex> session = ALLM.Session.new(
      ...>   status: :awaiting_tools,
      ...>   pending_tool_calls: [tc0, tc1],
      ...>   thread: ALLM.Thread.from_messages([ALLM.user("hi")])
      ...> )
      iex> updated = ALLM.Session.submit_tool_results(session, [{"c0", "r0"}, {"c1", "r1"}])
      iex> updated.status
      :idle
      iex> updated.pending_tool_calls
      []
  """
  @spec submit_tool_results(t(), [{String.t(), String.t() | map()}]) ::
          t() | {:error, SessionError.t()}
  def submit_tool_results(%__MODULE__{} = session, []), do: session

  def submit_tool_results(%__MODULE__{} = session, results) when is_list(results) do
    with :ok <- check_session_alive(session),
         :ok <- ensure_status!(session, :submit_tool_result) do
      Enum.reduce_while(results, session, &submit_tool_results_step/2)
    end
  end

  defp submit_tool_results_step({id, content}, acc) do
    case submit_tool_result(acc, id, content) do
      %__MODULE__{} = next -> {:cont, next}
      {:error, _} = err -> {:halt, err}
    end
  end

  # ===========================================================================
  # @doc false — internal helpers (called by ALLM.Session.StreamReducer in
  # the `lib/allm/session/stream_reducer.ex` module). Kept on `def @doc false`
  # rather than `defp` per PHASE_8_DESIGN.md §8.1.2 "Visibility decision" so
  # cross-module dispatch works without duplicating the Decision-#3 field-source
  # map. NOT public API.
  # ===========================================================================

  @doc false
  @spec apply_chat_result(t(), ChatResult.t()) :: t()
  def apply_chat_result(%__MODULE__{} = session, %ChatResult{} = cr) do
    base = %{
      session
      | thread: cr.thread,
        pending_tool_calls: [],
        pending_question: nil,
        pending_tool_call_id: nil,
        metadata: Map.merge(session.metadata, cr.metadata || %{})
    }

    project_chat_result(base, cr)
  end

  defp project_chat_result(base, %ChatResult{halted_reason: :ask_user} = cr) do
    %{
      base
      | status: :awaiting_user,
        pending_question: cr.pending_question,
        pending_tool_call_id: cr.pending_tool_call_id
    }
  end

  defp project_chat_result(base, %ChatResult{halted_reason: :manual_tool_calls} = cr) do
    tool_calls = manual_tool_calls(cr)
    %{base | status: :awaiting_tools, pending_tool_calls: tool_calls}
  end

  defp project_chat_result(base, %ChatResult{halted_reason: :tool_error} = cr) do
    error_term = chat_result_error(cr, :on_tool_error_exception)
    %{base | status: :error, metadata: Map.put(base.metadata, :error, error_term)}
  end

  defp project_chat_result(base, %ChatResult{halted_reason: :error} = cr) do
    error_term = chat_result_error(cr, :error)
    %{base | status: :error, metadata: Map.put(base.metadata, :error, error_term)}
  end

  defp project_chat_result(base, %ChatResult{}) do
    # :completed, :max_turns, :halt_when, :cancelled, custom-atom from
    # handler — all map to a `:completed` session with cleared pending
    # fields. The pending-fields invariant (Decision #7) is established
    # by the `base` map above.
    %{base | status: :completed}
  end

  # Phase 18.4 — per-tool manual: prefer `metadata.manual_tool_calls` (the
  # partition path's bucket) over `final_response.tool_calls` (the whole-loop
  # path's full list). The empty-list guard (`tcs != []`) on the first clause
  # is load-bearing: it prevents a future `metadata.manual_tool_calls: []`
  # write (e.g., from a defensively-merged StreamCollector fold) from masking
  # the whole-loop fallback. See PHASE_18_DESIGN.md Decision #8.
  defp manual_tool_calls(%ChatResult{metadata: %{manual_tool_calls: tcs}})
       when is_list(tcs) and tcs != [],
       do: tcs

  defp manual_tool_calls(%ChatResult{final_response: %{tool_calls: tcs}}) when is_list(tcs),
    do: tcs

  defp manual_tool_calls(_), do: []

  defp chat_result_error(%ChatResult{metadata: meta}, key) when is_map(meta) do
    Map.get(meta, key) || meta
  end

  defp chat_result_error(%ChatResult{metadata: meta}, _key), do: meta

  @doc false
  @spec apply_step_result(t(), StepResult.t()) :: t()
  def apply_step_result(%__MODULE__{} = session, %StepResult{} = sr) do
    base = %{
      session
      | thread: sr.thread,
        pending_tool_calls: [],
        pending_question: nil,
        pending_tool_call_id: nil,
        metadata: Map.merge(session.metadata, sr.metadata || %{})
    }

    project_step_result(base, sr)
  end

  defp project_step_result(base, %StepResult{} = sr) do
    case classify_step(sr) do
      :ask_user -> step_ask_user(base, sr)
      :tool_error -> step_tool_error(base, sr)
      :manual_tool_calls -> step_manual(base, sr)
      :error -> step_error(base, sr)
      :completed -> %{base | status: :completed}
      :idle -> %{base | status: :idle}
    end
  end

  defp classify_step(%StepResult{metadata: meta, response: response, done?: done?}) do
    cond do
      meta[:halted_reason] == :ask_user ->
        :ask_user

      meta[:halted_reason] == :tool_error ->
        :tool_error

      # Phase 18.4 — per-tool manual halt classification (Decision #11). The
      # new clause is inserted BEFORE the `meta[:mode] == :manual` clause;
      # the per-tool path NEVER sets `metadata.mode == :manual`, so the
      # whole-loop path's behavior is unchanged.
      per_tool_manual_step?(meta) ->
        :manual_tool_calls

      meta[:mode] == :manual and response.finish_reason == :tool_calls ->
        :manual_tool_calls

      response.finish_reason == :error ->
        :error

      done? ->
        :completed

      true ->
        :idle
    end
  end

  defp per_tool_manual_step?(meta) do
    is_list(meta[:manual_tool_calls]) and meta.manual_tool_calls != []
  end

  defp step_ask_user(base, %StepResult{metadata: meta}) do
    %{
      base
      | status: :awaiting_user,
        pending_question: meta[:pending_question],
        pending_tool_call_id: meta[:pending_tool_call_id]
    }
  end

  defp step_tool_error(base, %StepResult{metadata: meta}) do
    error_term =
      Map.get(meta, :on_tool_error_exception) || Map.get(meta, :error) || meta

    %{base | status: :error, metadata: Map.put(base.metadata, :error, error_term)}
  end

  # Phase 18.4 — per-tool manual: prefer `metadata.manual_tool_calls` (the
  # partition path's bucket) over `response.tool_calls` (the whole-loop
  # path's full list). The empty-list guard on the first clause mirrors
  # `manual_tool_calls/1` above (Decision #8 — `tcs != []` prevents an
  # empty-list write from masking the whole-loop fallback).
  defp step_manual(base, %StepResult{metadata: %{manual_tool_calls: tcs}})
       when is_list(tcs) and tcs != [] do
    %{base | status: :awaiting_tools, pending_tool_calls: tcs}
  end

  defp step_manual(base, %StepResult{response: response}) do
    %{base | status: :awaiting_tools, pending_tool_calls: response.tool_calls || []}
  end

  defp step_error(base, %StepResult{response: response, metadata: meta}) do
    error_term = (response.metadata && response.metadata[:error]) || meta
    %{base | status: :error, metadata: Map.put(base.metadata, :error, error_term)}
  end

  # ---------------------------------------------------------------------------
  # Status-precondition helpers
  # ---------------------------------------------------------------------------

  # Pure data-validation gate. Returns `:ok` for any non-`:error` status;
  # returns `{:error, %SessionError{reason: :session_in_error_state}}` for
  # `:error`-status sessions. NEVER raises. Used as the first step of
  # `with`-chains so callers can match on `{:error, _}` without rescue.
  # Per PHASE_8_DESIGN.md Retro F6: the `:error`-status check is data
  # validation (a session field), not a programmer-flow precondition, so it
  # is split from `ensure_status!/2`.
  @spec check_session_alive(t()) :: :ok | {:error, SessionError.t()}
  defp check_session_alive(%__MODULE__{status: :error}) do
    {:error,
     SessionError.new(:session_in_error_state,
       message: "session is in :error state; construct a fresh session"
     )}
  end

  defp check_session_alive(%__MODULE__{}), do: :ok

  # Programmer-flow precondition. Pattern-matches on legal status atoms
  # for the given operation; raises `ArgumentError` on illegal status.
  # NEVER returns `{:error, _}` — `:error`-status sessions must be filtered
  # by `check_session_alive/1` before reaching this helper.
  defp ensure_status!(%__MODULE__{status: status}, :start)
       when status in [:idle, :completed],
       do: :ok

  defp ensure_status!(%__MODULE__{status: status} = s, :start),
    do: raise_status_error(s, :start, status)

  defp ensure_status!(%__MODULE__{status: status}, {:continue, _msg})
       when status in [:idle, :completed],
       do: :ok

  defp ensure_status!(%__MODULE__{status: :awaiting_user} = s, {:continue, %Message{role: :user}}),
    do: ensure_continue_legal_for_awaiting_user(s)

  defp ensure_status!(%__MODULE__{status: :awaiting_user} = s, {:continue, _msg}),
    do: raise_continue_on_awaiting_user(s)

  defp ensure_status!(
         %__MODULE__{status: :awaiting_tools, pending_tool_calls: []},
         {:continue, nil}
       ),
       do: :ok

  defp ensure_status!(%__MODULE__{status: :awaiting_tools} = s, {:continue, _msg}),
    do: raise_continue_on_awaiting_tools(s)

  defp ensure_status!(%__MODULE__{status: status}, :step)
       when status in [:idle, :completed],
       do: :ok

  defp ensure_status!(%__MODULE__{status: status} = s, :step),
    do: raise_status_error(s, :step, status)

  defp ensure_status!(%__MODULE__{status: :awaiting_tools}, :submit_tool_result),
    do: :ok

  defp ensure_status!(%__MODULE__{status: status} = s, :submit_tool_result),
    do: raise_status_error(s, :submit_tool_result, status)

  # `:awaiting_user` + user-message `continue/3` — the design treats
  # `reply/4` as the canonical resume; `continue/3` with a user message
  # delegates from `reply/4`, so we accept it (`reply/4` IS `continue/3`).
  # The pending fields are cleared in `clear_pending_for_continue/1`.
  defp ensure_continue_legal_for_awaiting_user(%__MODULE__{}), do: :ok

  defp raise_continue_on_awaiting_user(%__MODULE__{}) do
    raise ArgumentError,
          "ALLM.Session.continue/3 (or stream_reply/4) is illegal on :awaiting_user " <>
            "with a non-user message; call ALLM.Session.reply/4 (or stream_reply/4) " <>
            "to clear the pending question and append a user message."
  end

  defp raise_continue_on_awaiting_tools(%__MODULE__{}) do
    raise ArgumentError,
          "ALLM.Session.continue/3 (or stream_reply/4) is illegal on :awaiting_tools; " <>
            "call ALLM.Session.submit_tool_result/3 (or submit_tool_results/2) " <>
            "for each pending call, then continue/3 with `nil` to drive the " <>
            "next adapter turn."
  end

  defp raise_status_error(%__MODULE__{}, op, status) do
    raise ArgumentError,
          "ALLM.Session.#{op}/x is illegal on session.status: #{inspect(status)}; " <>
            "see ALLM.Session moduledoc for the status-transition matrix."
  end

  # ---------------------------------------------------------------------------
  # session_input coercion + opts merging
  # ---------------------------------------------------------------------------

  defp coerce_session_input(%__MODULE__{} = session), do: {:ok, session}

  defp coerce_session_input(%Thread{} = thread), do: {:ok, new(thread: thread)}

  defp coerce_session_input(messages) when is_list(messages) do
    if Enum.all?(messages, &is_struct(&1, Message)) do
      {:ok, new(thread: Thread.from_messages(messages))}
    else
      {:error, invalid_session_input_error(messages)}
    end
  end

  defp coerce_session_input(other), do: {:error, invalid_session_input_error(other)}

  defp invalid_session_input_error(_other) do
    ValidationError.new(
      :invalid_session_input,
      [{:session_input, :invalid_type}],
      message: "session_input must be a %Session{}, %Thread{}, or list of %Message{}"
    )
  end

  defp merge_session_opts(%__MODULE__{} = session, opts) do
    opts
    |> Keyword.put_new(:context, session.context)
    |> put_session_id_if_set(session)
  end

  defp put_session_id_if_set(opts, %__MODULE__{id: nil}), do: opts

  defp put_session_id_if_set(opts, %__MODULE__{id: id}) when is_binary(id),
    do: Keyword.put_new(opts, :session_id, id)

  defp maybe_append_message(session, nil), do: session
  defp maybe_append_message(session, %Message{} = msg), do: append(session, msg)

  # Encode a tool result for storage on a `:tool`-role message. Binary
  # content passes through verbatim (caller has already formatted for the
  # model); a map is JSON-encoded so the resulting `%Message{}` passes
  # `ALLM.Validate.thread/1` (which requires `:content` to be a binary or
  # a list of structured parts). Lists of parts pass through; anything
  # else falls back to `inspect/1` (degenerate but visible).
  defp encode_tool_content(content) when is_binary(content), do: content
  defp encode_tool_content(content) when is_list(content), do: content
  defp encode_tool_content(content) when is_map(content), do: Jason.encode!(content)
  defp encode_tool_content(other), do: inspect(other)

  # Idempotent clear of `:awaiting_user` pending fields ahead of a
  # `{:continue, _msg}` dispatch.
  #
  # Contract: called by every operation whose `ensure_status!/2` shape is
  # `{:continue, _msg}` — currently `continue/3` and `stream_reply/4`. Adding
  # a third caller means it dispatches through `{:continue, _}`; if not, audit.
  #
  # Only `:awaiting_user` carries pending fields that need pre-clearing here:
  # `submit_tool_result/3` is the sole writer of `pending_tool_calls` and
  # eagerly flips `status: :awaiting_tools → :idle` when the last pending
  # call is submitted (see `do_submit_tool_result/3`), so by the time
  # `continue/3` runs on a tool flow the session is `:idle`. The catch-all
  # clause is a passthrough for `:idle`/`:completed` (the legal `:start`-
  # like statuses for `{:continue, _}`).
  defp clear_pending_for_continue(%__MODULE__{status: :awaiting_user} = s) do
    %{s | pending_question: nil, pending_tool_call_id: nil, status: :idle}
  end

  defp clear_pending_for_continue(%__MODULE__{} = s), do: s

  # ===========================================================================
  # Phase 1 hydrator — preserved verbatim
  # ===========================================================================

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      thread: hydrate_thread(data["thread"]),
      status: ALLM.Serializer.to_atom_field(data["status"]) || :idle,
      pending_tool_calls: ALLM.Serializer.hydrate(data["pending_tool_calls"] || []),
      pending_question: data["pending_question"],
      pending_tool_call_id: data["pending_tool_call_id"],
      context: data["context"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_thread(nil), do: %Thread{}
  defp hydrate_thread(value), do: ALLM.Serializer.hydrate(value)
end

defimpl Jason.Encoder, for: ALLM.Session do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
