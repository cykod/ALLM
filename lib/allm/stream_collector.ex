defmodule ALLM.StreamCollector do
  @moduledoc """
  Reduce a stream of `ALLM.Event` values into a collected `%ALLM.Response{}`,
  `%ALLM.StepResult{}`, or `%ALLM.ChatResult{}`. See spec §13.1.

  Layer C — stateless fold state. `StreamCollector` is the shared reducer
  that every non-streaming wrapper (`ALLM.generate/3` in Phase 5, future
  `step/3` and `chat/3`) builds on. Callers fold a stream with the stdlib
  idiom:

      Enum.reduce(stream, ALLM.StreamCollector.new(), fn e, s ->
        ALLM.StreamCollector.apply_event(s, e)
      end)

  then extract the result with `to_response/1` (thread-less) or
  `to_step_result/1` / `to_chat_result/1` (thread-backed).

  ## Phase 5 extensions to spec §13.1

    * `new/0` builds a thread-less collector used by `ALLM.stream_generate/3`.
    * `new/1` additionally accepts `nil` (thread-less) alongside a
      `%ALLM.Thread{}`.
    * `to_response/1` returns the accumulated `%Response{}` and is the
      canonical output for thread-less collection.

  Both fit alongside the spec §13.1 signatures (`new/1`, `apply_event/2`,
  `to_step_result/1`, `to_chat_result/1`) without replacing them.

  The `:last_response` and `:steps` fields are reserved for Phase 7
  orchestration fold clauses (e.g. `:chat_completed`, `:step_completed`)
  and are unused in Phase 5/6. Phase 6 adds two new fields, `:tool_results`
  and `:halt`, populated by the new fold clauses below.

  ## Fold semantics — Phase 5 subset plus Phase 6 extension

  `apply_event/2` ships explicit clauses for the nine Phase-5 adapter-emitted
  tags (`:message_started`, `:text_delta`, `:text_completed`,
  `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`,
  `:message_completed`, `:raw_chunk`, `:error`) and three Phase-6
  orchestration tags (`:tool_result_encoded`, `:tool_halt`,
  `:ask_user_requested`). Every other tag —
  `:tool_execution_started`, `:tool_execution_completed`,
  `:step_completed`, `:chat_completed`, plus any malformed event — falls
  through a single catch-all `apply_event(state, _), do: state`.

  | Tag | Fold | Rationale |
  |-----|------|-----------|
  | `:tool_result_encoded` | append `%Message{role: :tool, tool_call_id: id, content: content}` to `state.tool_results`. | `to_step_result/1` reads `:tool_results` from the struct, enabling `step ≡ stream_step \\|> collect_step`. |
  | `:tool_halt` | when `state.halt == nil`, set `state.halt = {:halt, reason, id}`. Subsequent halts are no-ops (first-halt-wins). | Halt metadata lives separately from `:finish_reason` so `done?/1` can combine both signals. |
  | `:ask_user_requested` | when `state.halt == nil`, set `state.halt = {:ask_user, :ask_user, id, q, o}`. First-halt-wins. | Same channel as `:tool_halt`; the distinct shape lets `to_step_result/1` build the Phase 6-owned ask-user metadata. |

  Phase 7 may insert additional clauses for `:step_completed` (appending
  `%StepResult{}` to `:steps`) and `:chat_completed` (populating
  `:last_response`) ahead of the catch-all.

  ## Totality guarantee

  `apply_event/2` never raises on a well-shaped event in the 16-tag closed
  union. A `:raw_chunk` with payload `{:usage, map}` allows a `KeyError`
  from `struct!(ALLM.Usage, map)` to propagate — that's an adapter bug
  (emitting keys not in `%Usage{}`), not a collector bug.

  ## Adapter-side contract for `:raw_chunk {:usage, _}` (Usage fold)

  The `{:raw_chunk, {:usage, map}}` fold applies `struct!(ALLM.Usage, map)`,
  which raises `KeyError` on any map key outside `%ALLM.Usage{}`'s field set.
  Adapters emitting `{:raw_chunk, {:usage, _}}` events MUST pre-map their
  provider's wire-level usage fields (e.g., OpenAI's `prompt_tokens` /
  `completion_tokens`; Anthropic's `input_tokens` / `output_tokens` /
  `cache_read_input_tokens`) to `%ALLM.Usage{}` field names before emitting.
  An adapter that forwards the raw provider payload will `KeyError` the
  reducer mid-stream, destroying the accumulated collector state. See
  `lib/allm/usage.ex` for the canonical `%Usage{}` field set. This is a
  load-bearing invariant for any real provider adapter implementing
  `ALLM.StreamAdapter`.

  ## Mid-stream errors

  A terminal `{:error, struct}` event folds into the collector's `:error`
  field and sets `:finish_reason` to `:error`. `to_response/1` still
  returns `%Response{}` — a mid-stream error is a *success* at the fold
  layer: the caller reads `response.finish_reason == :error` and
  `response.metadata.error` to detect it. `to_response/1` never returns
  `{:error, _}`.
  """

  alias ALLM.{ChatResult, Message, Response, StepResult, Thread, ToolCall, Usage}
  alias ALLM.Error.{AdapterError, StreamError}

  @typedoc """
  Terminal halt signal derived from `:tool_halt` / `:ask_user_requested`
  events. `nil` until the first halt event is observed; set once and never
  updated (first-halt-wins — see Phase 6 design Invariant 7).
  """
  @type halt_state ::
          nil
          | {:halt, reason :: atom(), tool_call_id :: String.t()}
          | {:ask_user, :ask_user, tool_call_id :: String.t(), question :: String.t(),
             opts :: keyword()}

  @type state :: %__MODULE__{
          thread: Thread.t() | nil,
          current_text: String.t(),
          current_tool_calls: %{String.t() => ToolCall.t()},
          tool_call_order: [String.t()],
          last_message: Message.t() | nil,
          last_response: Response.t() | nil,
          steps: [StepResult.t()],
          tool_results: [Message.t()],
          halt: halt_state(),
          usage: Usage.t(),
          finish_reason: Response.finish_reason() | nil,
          raw_finish_reason: String.t() | nil,
          error: AdapterError.t() | StreamError.t() | term() | nil,
          done?: boolean(),
          metadata: map()
        }

  defstruct thread: nil,
            current_text: "",
            current_tool_calls: %{},
            tool_call_order: [],
            last_message: nil,
            last_response: nil,
            steps: [],
            tool_results: [],
            halt: nil,
            usage: %Usage{},
            finish_reason: nil,
            raw_finish_reason: nil,
            error: nil,
            done?: false,
            metadata: %{}

  @doc """
  Build a thread-less collector. Equivalent to `new(nil)`.

  Use this when reducing `ALLM.stream_generate/3`'s stream into a
  `%Response{}` via `to_response/1`. Calling `to_step_result/1` or
  `to_chat_result/1` on a thread-less collector raises `ArgumentError`.

  ## Examples

      iex> s = ALLM.StreamCollector.new()
      iex> s.thread
      nil
      iex> s.current_text
      ""
  """
  @spec new() :: state()
  def new, do: %__MODULE__{}

  @doc """
  Build a collector either thread-less (`nil`) or seeded with a
  `%ALLM.Thread{}`. The thread is required by `to_step_result/1` and
  `to_chat_result/1`; use `new/0` or `new(nil)` when only `to_response/1`
  will be consumed.

  ## Examples

      iex> thread = ALLM.Thread.new()
      iex> s = ALLM.StreamCollector.new(thread)
      iex> s.thread
      %ALLM.Thread{messages: [], metadata: %{}}

      iex> ALLM.StreamCollector.new(nil).thread
      nil
  """
  @spec new(Thread.t() | nil) :: state()
  def new(nil), do: %__MODULE__{thread: nil}
  def new(%Thread{} = thread), do: %__MODULE__{thread: thread}

  @doc """
  Fold a single `ALLM.Event` into the collector state. Total over the 16-tag
  closed union; unknown tags or malformed payloads are no-ops (state
  unchanged).

  See the module doc's "Fold semantics — Phase 5 subset" section for the
  per-tag state transitions.

  ## Examples

      iex> s = ALLM.StreamCollector.new()
      iex> s = ALLM.StreamCollector.apply_event(s, {:text_delta, %{id: nil, delta: "hel"}})
      iex> s = ALLM.StreamCollector.apply_event(s, {:text_delta, %{id: nil, delta: "lo"}})
      iex> s.current_text
      "hello"
  """
  @spec apply_event(state(), ALLM.Event.t()) :: state()
  def apply_event(%__MODULE__{} = state, {:message_started, %{message: _}}), do: state

  def apply_event(%__MODULE__{} = state, {:text_delta, %{delta: delta}})
      when is_binary(delta) do
    %{state | current_text: state.current_text <> delta}
  end

  def apply_event(%__MODULE__{} = state, {:text_completed, %{text: text}})
      when is_binary(text) do
    %{state | current_text: text}
  end

  def apply_event(%__MODULE__{} = state, {:tool_call_started, %{id: id, name: name}})
      when is_binary(id) and is_binary(name) do
    tool_call = %ToolCall{id: id, name: name, arguments: %{}, raw_arguments: ""}

    %{
      state
      | current_tool_calls: Map.put_new(state.current_tool_calls, id, tool_call),
        tool_call_order: append_order(state.tool_call_order, id)
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:tool_call_delta, %{id: id, arguments_delta: delta}}
      )
      when is_binary(id) and is_binary(delta) do
    initial = %ToolCall{id: id, name: "", arguments: %{}, raw_arguments: ""}

    current_tool_calls =
      Map.update(state.current_tool_calls, id, %{initial | raw_arguments: delta}, fn existing ->
        %{existing | raw_arguments: (existing.raw_arguments || "") <> delta}
      end)

    %{
      state
      | current_tool_calls: current_tool_calls,
        tool_call_order: append_order(state.tool_call_order, id)
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:tool_call_completed,
         %{id: id, name: name, arguments: arguments, raw_arguments: raw_arguments}}
      )
      when is_binary(id) and is_binary(name) and is_map(arguments) and is_binary(raw_arguments) do
    tool_call = %ToolCall{
      id: id,
      name: name,
      arguments: arguments,
      raw_arguments: raw_arguments
    }

    %{
      state
      | current_tool_calls: Map.put(state.current_tool_calls, id, tool_call),
        tool_call_order: append_order(state.tool_call_order, id)
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:message_completed, %{message: %Message{} = msg, finish_reason: fr}}
      ) do
    %{
      state
      | last_message: msg,
        finish_reason: fr || state.finish_reason
    }
  end

  def apply_event(%__MODULE__{} = state, {:message_completed, %{message: %Message{} = msg}}) do
    %{state | last_message: msg}
  end

  def apply_event(%__MODULE__{} = state, {:raw_chunk, {:usage, map}}) when is_map(map) do
    %{state | usage: struct!(Usage, map)}
  end

  def apply_event(%__MODULE__{} = state, {:raw_chunk, _}), do: state

  def apply_event(%__MODULE__{} = state, {:error, struct}) do
    %{state | error: struct, finish_reason: :error}
  end

  # ---------------------------------------------------------------------------
  # Phase 6 orchestration folds (inserted before the catch-all per Phase 5
  # Non-obvious Decision #5). See Phase 6 design §StreamCollector extension.
  # ---------------------------------------------------------------------------

  def apply_event(
        %__MODULE__{} = state,
        {:tool_result_encoded, %{id: id, content: content}}
      )
      when is_binary(id) and is_binary(content) do
    tool_msg = %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
    %{state | tool_results: state.tool_results ++ [tool_msg]}
  end

  def apply_event(
        %__MODULE__{halt: nil} = state,
        {:tool_halt, %{tool_call_id: id, reason: reason}}
      )
      when is_binary(id) and is_atom(reason) do
    %{state | halt: {:halt, reason, id}}
  end

  def apply_event(
        %__MODULE__{halt: nil} = state,
        {:ask_user_requested, %{tool_call_id: id, question: q, opts: o}}
      )
      when is_binary(id) and is_binary(q) and is_list(o) do
    %{state | halt: {:ask_user, :ask_user, id, q, o}}
  end

  def apply_event(%__MODULE__{} = state, _), do: state

  @doc """
  Build a `%ALLM.Response{}` from the collector state.

  Works on any collector (thread-less or not). A mid-stream error surfaces
  as `finish_reason: :error` with the error struct under `metadata.error`;
  this function never returns `{:error, _}`.

  ## Examples

      iex> s = ALLM.StreamCollector.new()
      iex> s = ALLM.StreamCollector.apply_event(s, {:text_delta, %{id: nil, delta: "hi"}})
      iex> s = ALLM.StreamCollector.apply_event(s, {:message_completed, %{message: %ALLM.Message{role: :assistant, content: "hi"}, finish_reason: :stop}})
      iex> resp = ALLM.StreamCollector.to_response(s)
      iex> {resp.output_text, resp.finish_reason}
      {"hi", :stop}
  """
  @spec to_response(state()) :: Response.t()
  def to_response(%__MODULE__{} = state) do
    metadata =
      if state.error, do: Map.put(state.metadata, :error, state.error), else: state.metadata

    %Response{
      message: state.last_message,
      output_text: state.current_text,
      tool_calls: build_tool_calls(state),
      finish_reason: state.finish_reason,
      raw_finish_reason: state.raw_finish_reason,
      usage: state.usage,
      metadata: metadata
    }
  end

  @doc """
  Build a `%ALLM.StepResult{}` from the collector state. Requires a non-nil
  thread (from `new/1` with a `%Thread{}`); raises `ArgumentError` otherwise.

  `:done?` is `true` when `state.halt != nil` (a halt event was folded in)
  or when `finish_reason in [:stop, :length, :content_filter, :error]`;
  `false` otherwise (for `:tool_calls` or `nil` with no halt).

  `:tool_results` is populated from the `:tool_result_encoded` fold clause.
  `:metadata` merges halt metadata when `state.halt != nil` (see Phase 6
  design §StreamCollector extension):
    * `{:halt, reason, id}` → `%{halted_reason: reason, halt_tool_call_id: id}`.
    * `{:ask_user, :ask_user, id, q, o}` → `%{halted_reason: :ask_user,
      pending_tool_call_id: id, pending_question: q, ask_user_opts: o}`.
  """
  @spec to_step_result(state()) :: StepResult.t()
  def to_step_result(%__MODULE__{thread: nil}),
    do:
      raise(ArgumentError, """
      StreamCollector.to_step_result/1 requires a thread; use new/1 with a thread, \
      or call to_response/1 for thread-less collection\
      """)

  def to_step_result(%__MODULE__{thread: %Thread{} = thread} = state) do
    %StepResult{
      thread: thread,
      response: to_response(state),
      tool_results: state.tool_results,
      done?: step_done?(state),
      metadata: merge_halt_metadata(state.metadata, state.halt)
    }
  end

  @doc """
  Build a `%ALLM.ChatResult{}` from the collector state. Requires a non-nil
  thread; raises `ArgumentError` otherwise.

  `:halted_reason` is `:error` when `finish_reason == :error`, else
  `:completed`. Phase 7 will introduce `:max_turns`, `:halt_when`, and
  `:ask_user` as additional halt reasons.
  """
  @spec to_chat_result(state()) :: ChatResult.t()
  def to_chat_result(%__MODULE__{thread: nil}),
    do:
      raise(ArgumentError, """
      StreamCollector.to_chat_result/1 requires a thread; use new/1 with a thread, \
      or call to_response/1 for thread-less collection\
      """)

  def to_chat_result(%__MODULE__{thread: %Thread{} = thread} = state) do
    %ChatResult{
      thread: thread,
      final_response: to_response(state),
      steps: [],
      halted_reason: halted_reason_for_finish_reason(state.finish_reason)
    }
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp append_order(order, id) do
    if id in order, do: order, else: order ++ [id]
  end

  defp build_tool_calls(%__MODULE__{current_tool_calls: tcs, tool_call_order: order}) do
    Enum.map(order, &Map.fetch!(tcs, &1))
  end

  # Phase 6: step is done when a halt event fired OR the adapter finish_reason
  # is terminal (anything outside :tool_calls / nil). See Phase 6 design
  # §StreamCollector extension Invariant 4.
  defp step_done?(%__MODULE__{halt: halt, finish_reason: fr}) do
    halt != nil or fr in [:stop, :length, :content_filter, :error]
  end

  # Phase 6: fold the halt tuple into the step result's metadata map. Merging
  # into the existing metadata preserves adapter-contributed keys (e.g.
  # `:error`) when a halt also fired.
  defp merge_halt_metadata(base, nil), do: base

  defp merge_halt_metadata(base, {:halt, reason, id}) do
    Map.merge(base, %{halted_reason: reason, halt_tool_call_id: id})
  end

  defp merge_halt_metadata(base, {:ask_user, :ask_user, id, question, opts}) do
    Map.merge(base, %{
      halted_reason: :ask_user,
      pending_tool_call_id: id,
      pending_question: question,
      ask_user_opts: opts
    })
  end

  defp halted_reason_for_finish_reason(:error), do: :error
  defp halted_reason_for_finish_reason(_), do: :completed
end
