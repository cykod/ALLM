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

  Phase 6 adds two new fields, `:tool_results` and `:halt`, populated by
  fold clauses for orchestration tags. Phase 7 adds `:chat_result` and
  populates `:steps` via the `:step_completed` fold clause.

  ## Phase 7 extension

  The `:step_completed` fold appends a `%StepResult{}` (built from the
  PRE-RESET collector state — see Phase 7 Non-obvious Decision #6) to
  `:steps` and resets the per-step sub-state (`:current_text`,
  `:current_tool_calls`, `:tool_call_order`, `:tool_results`, `:halt`,
  `:finish_reason`, `:raw_finish_reason`, `:last_message`). `:error`
  and `:metadata` are NOT reset — adapter mid-stream errors and
  accumulated metadata persist across step boundaries so that
  `to_chat_result/1`'s fallback path can preserve them.

  The `:chat_completed` fold stores the event's `:result` verbatim in
  `:chat_result` and sets `:done? = true`. `to_chat_result/1` short-
  circuits to the stored result when present; otherwise it falls back
  to a computed `%ChatResult{}` whose `halted_reason` is `:cancelled`
  (consumer halted early) or `:error` (mid-stream adapter error).

  ## Fold semantics — Phase 5 subset plus Phase 6 + Phase 7 extensions

  `apply_event/2` ships explicit clauses for the nine Phase-5 adapter-emitted
  tags (`:message_started`, `:text_delta`, `:text_completed`,
  `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`,
  `:message_completed`, `:raw_chunk`, `:error`), three Phase-6
  orchestration tags (`:tool_result_encoded`, `:tool_halt`,
  `:ask_user_requested`), and two Phase-7 orchestration tags
  (`:step_completed`, `:chat_completed`). Every other tag —
  `:tool_execution_started`, `:tool_execution_completed`, plus any
  malformed event — falls through a single catch-all
  `apply_event(state, _), do: state`.

  | Tag | Fold | Rationale |
  |-----|------|-----------|
  | `:tool_result_encoded` | append `%Message{role: :tool, tool_call_id: id, content: content}` to `state.tool_results`. | `to_step_result/1` reads `:tool_results` from the struct, enabling `step ≡ stream_step \\|> collect_step`. |
  | `:tool_halt` | when `state.halt == nil`, set `state.halt = {:halt, reason, id, result}` AND append the encoded sentinel `%Message{role: :tool, ...}` (from payload `:content`) to `state.tool_results`. Subsequent halts are no-ops (first-halt-wins). | Halt metadata lives separately from `:finish_reason` so `done?/1` can combine both signals. The sentinel append (Phase 7.6 cleanup B1) keeps `tool_results` aligned with the non-streaming `Chat.do_step/4` path. |
  | `:ask_user_requested` | when `state.halt == nil`, set `state.halt = {:ask_user, :ask_user, id, q, o}` AND append a `<awaiting user response>` sentinel message to `state.tool_results`. First-halt-wins. | Same channel as `:tool_halt`; the sentinel append (Phase 7.6 cleanup B1) mirrors spec §12.3 step 1. |
  | `:step_completed` | append `%StepResult{}` (PRE-RESET state) to `state.steps`; set `state.thread = thread`; reset per-step sub-state. | Multi-step `Chat.stream/3` reductions need a clean per-step boundary. `:error` / `:metadata` deliberately persist. |
  | `:chat_completed` | set `state.chat_result = result`; set `state.done? = true`. | The chat-layer terminal event; `to_chat_result/1` short-circuits to the stored value when present. |

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

  The `:halt` shape carries the handler's raw `result` term as the fourth
  element so `merge_halt_metadata/2` can project it onto `:halt_result`,
  matching the non-streaming `ToolRunner.run_tool_calls/3` halt_metadata
  shape (Phase 7.6 cleanup — chat-equivalence blocker B2).
  """
  @type halt_state ::
          nil
          | {:halt, reason :: atom(), tool_call_id :: String.t(), result :: term()}
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
          chat_result: ChatResult.t() | nil,
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
            chat_result: nil,
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
         %{id: id, name: name, arguments: arguments, raw_arguments: raw_arguments} = payload}
      )
      when is_binary(id) and is_binary(name) and is_map(arguments) and is_binary(raw_arguments) do
    tool_call = %ToolCall{
      id: id,
      name: name,
      arguments: arguments,
      raw_arguments: raw_arguments,
      metadata: Map.get(payload, :metadata, %{})
    }

    %{
      state
      | current_tool_calls: Map.put(state.current_tool_calls, id, tool_call),
        tool_call_order: append_order(state.tool_call_order, id)
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:message_completed, %{message: %Message{} = msg, finish_reason: fr} = payload}
      ) do
    %{
      state
      | last_message: msg,
        finish_reason: fr || state.finish_reason,
        metadata: merge_message_completed_metadata(state.metadata, payload)
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:message_completed, %{message: %Message{} = msg} = payload}
      ) do
    %{
      state
      | last_message: msg,
        metadata: merge_message_completed_metadata(state.metadata, payload)
    }
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
        {:tool_halt, %{tool_call_id: id, reason: reason, result: result} = p}
      )
      when is_binary(id) and is_atom(reason) do
    # Phase 7.6 cleanup — chat-equivalence blocker B1: append the encoded
    # sentinel tool message to state.tool_results so `:tool_halt` events
    # contribute to the same `tool_results` shape that the non-streaming
    # `Chat.do_step/4` produces. Payload's optional `:content` key carries
    # the pre-encoded sentinel content (added by ToolRunner; see
    # `Event.tool_halt/4`). Falls back to `inspect/1` for callers that
    # build the event via `tool_halt/3`.
    content = Map.get_lazy(p, :content, fn -> inspect(result) end)
    tool_msg = %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}

    %{
      state
      | halt: {:halt, reason, id, result},
        tool_results: state.tool_results ++ [tool_msg]
    }
  end

  def apply_event(
        %__MODULE__{halt: nil} = state,
        {:ask_user_requested, %{tool_call_id: id, question: q, opts: o}}
      )
      when is_binary(id) and is_binary(q) and is_list(o) do
    # Phase 7.6 cleanup — chat-equivalence blocker B1: append the
    # `<awaiting user response>` sentinel tool message to state.tool_results
    # to mirror spec §12.3 step 1 / non-streaming `Chat.do_step/4`.
    tool_msg = %Message{
      role: :tool,
      tool_call_id: id,
      content: "<awaiting user response>",
      metadata: %{}
    }

    %{
      state
      | halt: {:ask_user, :ask_user, id, q, o},
        tool_results: state.tool_results ++ [tool_msg]
    }
  end

  # ---------------------------------------------------------------------------
  # Phase 7 orchestration folds (inserted before the catch-all per Phase 5
  # Non-obvious Decision #5). See Phase 7 design Non-obvious Decisions #6 / #7.
  # ---------------------------------------------------------------------------

  def apply_event(
        %__MODULE__{} = state,
        {:step_completed, %{response: %Response{} = response, thread: %Thread{} = thread} = p}
      ) do
    # Build StepResult from the PRE-RESET collector state — see Phase 7
    # Non-obvious Decision #6. The map-update below replaces per-step
    # fields with reset defaults, but the right-hand-side reads of
    # `state.tool_results`, `state.halt`, etc. see the original values.
    #
    # Phase 7 retro F1: the payload's optional `:mode` key (added by
    # `Event.step_completed/3`) lets the fold mirror the non-streaming
    # `Chat.do_step/4` shape — `mode: :manual` with `finish_reason:
    # :tool_calls` injects `metadata.mode = :manual` so chat-layer
    # `terminal_condition/5` halts with `:manual_tool_calls`.
    mode = Map.get(p, :mode, :auto)

    # Phase 18.3 / Decision #12: extract `:manual_tool_calls` from the
    # payload (added by `Event.step_completed/4`); merge onto step
    # metadata IFF non-empty. Empty list is the absence-of-key default —
    # writing `manual_tool_calls: []` for pure-auto turns would diverge
    # from the non-streaming arm (`Chat.do_step/4` only sets the key when
    # the partition produces a non-empty bucket) and break chat-equivalence.
    manual_tcs = Map.get(p, :manual_tool_calls, [])

    base_metadata = merge_halt_metadata(%{}, state.halt)

    metadata =
      if mode == :manual and response.finish_reason == :tool_calls do
        Map.put(base_metadata, :mode, :manual)
      else
        base_metadata
      end

    metadata =
      if manual_tcs != [] do
        Map.put(metadata, :manual_tool_calls, manual_tcs)
      else
        metadata
      end

    step_result = %StepResult{
      thread: thread,
      response: response,
      tool_results: state.tool_results,
      done?: step_done?(state),
      metadata: metadata
    }

    %{
      state
      | steps: state.steps ++ [step_result],
        thread: thread,
        current_text: "",
        current_tool_calls: %{},
        tool_call_order: [],
        tool_results: [],
        halt: nil,
        finish_reason: nil,
        raw_finish_reason: nil,
        last_message: nil
    }
  end

  def apply_event(
        %__MODULE__{} = state,
        {:chat_completed, %{result: %ChatResult{} = chat_result}}
      ) do
    %{state | chat_result: chat_result, done?: true}
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

  `:tool_results` is populated from the `:tool_result_encoded` fold clause
  AND from the `:tool_halt` / `:ask_user_requested` sentinel appends
  (Phase 7.6 cleanup B1).

  `:metadata` merges halt metadata when `state.halt != nil` (see Phase 6
  design §StreamCollector extension):
    * `{:halt, reason, id, result}` → `%{halted_reason: reason,
      halt_tool_call_id: id, halt_result: result}`.
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
  Build a `%ALLM.ChatResult{}` from the collector state.

  Two branches (Phase 7 Non-obvious Decision #7):

    * **Stored.** When `state.chat_result` is set (from a `:chat_completed`
      fold), return it verbatim — even when `state.thread` is `nil`. The
      stored result is authoritative; the orchestrator already constructed
      the canonical ChatResult.
    * **Fallback (computed).** When `state.chat_result` is `nil` and
      `state.thread` is set, build a `%ChatResult{}` from collector state.
      `:halted_reason` is `:error` when `state.error != nil` (mid-stream
      adapter error); otherwise ALWAYS `:cancelled` (the consumer halted
      the stream early; non-empty `state.steps` does NOT promote to
      `:completed`). `:final_response` is the last step's response when
      `state.steps != []`, or `to_response(state)` when no steps were
      observed.

  Raises `ArgumentError` when both `state.chat_result` and `state.thread`
  are `nil`.
  """
  @spec to_chat_result(state()) :: ChatResult.t()
  def to_chat_result(%__MODULE__{chat_result: %ChatResult{} = stored}), do: stored

  def to_chat_result(%__MODULE__{chat_result: nil, thread: nil}),
    do:
      raise(ArgumentError, """
      StreamCollector.to_chat_result/1 requires a thread; use new/1 with a thread, \
      or call to_response/1 for thread-less collection\
      """)

  def to_chat_result(%__MODULE__{chat_result: nil, thread: %Thread{} = thread} = state) do
    halted_reason = if state.error, do: :error, else: :cancelled

    final_response =
      case state.steps do
        [] -> to_response(state)
        steps -> List.last(steps).response
      end

    %ChatResult{
      thread: thread,
      final_response: final_response,
      steps: state.steps,
      halted_reason: halted_reason,
      metadata: state.metadata
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

  @doc false
  # Phase 6: step is done when a halt event fired OR the adapter finish_reason
  # is terminal (anything outside :tool_calls / nil). See Phase 6 design
  # §StreamCollector extension Invariant 4.
  #
  # Phase 7 retro F2: promoted from `defp` to `def` because `ALLM.Chat`'s
  # multi-turn streaming path (`step_result_from_outer_collector/3`) is the
  # second caller of this exact data-shaping rule. Marked `@doc false` —
  # public for cross-module reuse, not part of the documented surface.
  @spec step_done?(state()) :: boolean()
  def step_done?(%__MODULE__{halt: halt, finish_reason: fr}) do
    halt != nil or fr in [:stop, :length, :content_filter, :error]
  end

  @doc false
  # Phase 6: fold the halt tuple into the step result's metadata map. Merging
  # into the existing metadata preserves adapter-contributed keys (e.g.
  # `:error`) when a halt also fired.
  #
  # Phase 7 retro F2: promoted from `defp` to `def` for the same reason as
  # `step_done?/1` above. `@doc false` — internal cross-module reuse.
  @spec merge_halt_metadata(map(), halt_state()) :: map()
  def merge_halt_metadata(base, nil), do: base

  def merge_halt_metadata(base, {:halt, :tool_error, id, _result}) do
    # Phase 7.6 cleanup B2: `:tool_error` halt metadata mirrors
    # `ToolRunner.build_tool_error_halt_metadata/2` — `:halt_result` is
    # NOT projected (the encoded error already lives on the sentinel
    # tool message; halt_result is reserved for handler-declared halts).
    Map.merge(base, %{halted_reason: :tool_error, halt_tool_call_id: id})
  end

  def merge_halt_metadata(base, {:halt, reason, id, result}) do
    Map.merge(base, %{halted_reason: reason, halt_tool_call_id: id, halt_result: result})
  end

  def merge_halt_metadata(base, {:ask_user, :ask_user, id, question, opts}) do
    Map.merge(base, %{
      halted_reason: :ask_user,
      pending_tool_call_id: id,
      pending_question: question,
      ask_user_opts: opts
    })
  end

  # Phase 10.6 — `:message_completed` payloads may carry an optional
  # `:metadata` map (currently used by `ALLM.Providers.OpenAI`'s Responses
  # streaming path to surface accumulated `reasoning.summary` text). The
  # adapter's contribution merges into `state.metadata` so it lands on
  # `Response.metadata` post-collection. Adapter keys win on collision.
  defp merge_message_completed_metadata(base, %{metadata: extra}) when is_map(extra) do
    Map.merge(base, extra)
  end

  defp merge_message_completed_metadata(base, _payload), do: base
end
