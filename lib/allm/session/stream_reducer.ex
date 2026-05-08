defmodule ALLM.Session.StreamReducer do
  @moduledoc """
  Folds an `ALLM.stream/3` (or `ALLM.stream_step/3`) event stream into
  both an updated `%ALLM.Session{}` and a terminal `%ALLM.ChatResult{}`
  (or `%ALLM.StepResult{}`) in one pass.

  Layer D — companion to the streaming Session entry points
  (`stream_start/3`, `stream_reply/4`, `stream_step/3`).

  ## Modes

  Two dispatch modes — set at construction via `new/2`'s `:mode` opt:

    * `:chat` (default) — used with `ALLM.Session.stream_start/3`,
      `stream_reply/4`. `finalize/1` returns
      `{updated_session, %ChatResult{}}`. When the consumer halts before
      a `:chat_completed` event arrives, a `:cancelled` `%ChatResult{}`
      is built from the partial collector state.
    * `:step` — used with `ALLM.Session.stream_step/3`. `finalize/1`
      returns `{updated_session, %StepResult{}}` if a `:step_completed`
      event was observed; otherwise a `:cancelled` `%ChatResult{}` is
      built from the empty-step partial state (StepResult cannot
      represent a stream that was cancelled before any step completed).

  ## Examples

      iex> session = ALLM.Session.new()
      iex> reducer = ALLM.Session.StreamReducer.new(session)
      iex> reducer.session == session
      true
      iex> reducer.mode
      :chat

      iex> session = ALLM.Session.new()
      iex> reducer = ALLM.Session.StreamReducer.new(session, mode: :step)
      iex> reducer.mode
      :step
  """

  alias ALLM.{ChatResult, Event, Session, StepResult, StreamCollector, Thread}

  @type mode :: :chat | :step

  @type t :: %__MODULE__{
          session: Session.t(),
          collector: StreamCollector.state(),
          mode: mode()
        }

  defstruct [:session, :collector, mode: :chat]

  @legal_modes [:chat, :step]

  @doc """
  Build a reducer wrapping the originating `%ALLM.Session{}` plus a fresh
  `%ALLM.StreamCollector{}` seeded with `session.thread`.

  Validates `opts[:mode]` against `[:chat, :step]`; unknown values raise
  `ArgumentError` at construction time.

  ## Options

    * `:mode` — `:chat` (default) or `:step`. Selects `finalize/1`'s
      dispatch shape.

  ## Examples

      iex> session = ALLM.Session.new(thread: ALLM.Thread.from_messages([ALLM.user("hi")]))
      iex> reducer = ALLM.Session.StreamReducer.new(session)
      iex> reducer.session.thread == session.thread
      true
      iex> reducer.collector.thread == session.thread
      true
  """
  @spec new(Session.t(), keyword()) :: t()
  def new(%Session{} = session, opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :chat)
    validate_mode!(mode)

    %__MODULE__{
      session: session,
      collector: StreamCollector.new(session.thread),
      mode: mode
    }
  end

  defp validate_mode!(mode) when mode in @legal_modes, do: :ok

  defp validate_mode!(other) do
    raise ArgumentError,
          "ALLM.Session.StreamReducer.new/2 :mode must be :chat or :step; got: " <>
            inspect(other)
  end

  @doc """
  Fold one `ALLM.Event` value into the reducer. Total over the closed
  16-tag event union; unknown tags or malformed payloads are no-ops
  (delegated to `StreamCollector.apply_event/2`'s catch-all).

  Does NOT mutate `state.session` — the originating session is preserved
  through every fold and only updated at `finalize/1`.

  ## Examples

      iex> session = ALLM.Session.new(thread: ALLM.Thread.from_messages([ALLM.user("hi")]))
      iex> reducer = ALLM.Session.StreamReducer.new(session)
      iex> updated = ALLM.Session.StreamReducer.apply_event(reducer, {:text_delta, %{delta: "hi"}})
      iex> updated.collector.current_text
      "hi"
      iex> updated.session == session
      true
  """
  @spec apply_event(t(), Event.t()) :: t()
  def apply_event(%__MODULE__{collector: c} = state, event) do
    %{state | collector: StreamCollector.apply_event(c, event)}
  end

  @doc """
  Project the folded collector state onto an updated `%Session{}` and a
  terminal result tuple.

  Dispatches on `state.mode`:

    * `:chat` + observed `:chat_completed` → `{Session.apply_chat_result(session, cr), cr}`.
    * `:chat` + no `:chat_completed` (consumer halted) → uses
      `StreamCollector.to_chat_result/1`'s `:cancelled` fallback to build
      a `%ChatResult{}`, then projects.
    * `:step` + exactly one observed `:step_completed` →
      `{Session.apply_step_result(session, sr), sr}`.
    * `:step` + no `:step_completed` (consumer halted before any step) →
      `{session, %ChatResult{halted_reason: :cancelled, ...}}`. The
      result tuple's second element is a `%ChatResult{}`, not a
      `%StepResult{}`, because no step was observed to project.

  Idempotent — calling twice with the same state returns equal tuples.

  ## Examples

      iex> session = ALLM.Session.new(thread: ALLM.Thread.from_messages([ALLM.user("hi")]))
      iex> reducer = ALLM.Session.StreamReducer.new(session)
      iex> {s, r} = ALLM.Session.StreamReducer.finalize(reducer)
      iex> s.status
      :completed
      iex> r.halted_reason
      :cancelled
  """
  @spec finalize(t()) :: {Session.t(), ChatResult.t() | StepResult.t()}
  def finalize(%__MODULE__{mode: :chat, session: session, collector: c}) do
    chat_result = StreamCollector.to_chat_result(c)
    {Session.apply_chat_result(session, chat_result), chat_result}
  end

  def finalize(%__MODULE__{mode: :step, session: session, collector: c}) do
    case c.steps do
      [%StepResult{} = sr | _] ->
        # Decision #15 — the FIRST observed step is the result for `:step`
        # mode (StreamCollector prepends to `:steps` per the existing fold;
        # we use the head as the canonical step for this turn).
        {Session.apply_step_result(session, sr), sr}

      [] ->
        thread = c.thread || %Thread{}

        cancelled_result = %ChatResult{
          thread: thread,
          final_response: nil,
          steps: [],
          halted_reason: :cancelled,
          metadata: %{}
        }

        {session, cancelled_result}
    end
  end
end
