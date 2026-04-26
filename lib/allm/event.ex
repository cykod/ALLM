defmodule ALLM.Event do
  @moduledoc """
  Closed tagged-tuple union emitted by stream runners. See spec §8.

  Layer A — every event is `{tag, payload}` where `tag` is an atom from the
  closed set returned by `tags/0`. For every tag except `:raw_chunk` and
  `:error`, `payload` is a `map()` with documented keys; `:raw_chunk` and
  `:error` carry opaque payloads per spec §8.

  Use `event?/1` to test whether a term is a well-shaped event. The variant
  constructors (`text_delta/2`, `tool_call_completed/4`, …) are the
  canonical way to build events from the stream runner; the spec leaves
  `:raw_chunk` and `:error` un-constructed because their payloads are
  opaque.

  ## Payload extensions

  Phase 5 additively extends the `:message_completed` payload with an
  optional `:finish_reason` key of type `t:ALLM.Response.finish_reason/0` or
  `nil`. The tag set is unchanged — the union still has 16 tags. Existing
  consumers that bind `{:message_completed, %{message: msg}}` continue to
  match because Elixir map patterns are non-exhaustive; only consumers that
  want to read `:finish_reason` opt in. The `message_completed/1`
  constructor is preserved and now produces a payload with
  `:finish_reason => nil`; `message_completed/2` threads the caller-supplied
  reason into the payload.

  Phase 10.6 additively extends the `:message_completed` payload with an
  optional `:metadata` map key. Adapters that surface terminal
  provider-specific completion metadata (e.g., the OpenAI Responses-API
  reasoning summary) populate this key; `ALLM.StreamCollector.apply_event/2`
  merges it into `state.metadata`, so the value lands on
  `Response.metadata` after collection. The key is OPTIONAL — adapters
  and existing emitters that don't populate it omit the key entirely, and
  the StreamCollector treats absence as a no-op merge.
  """

  alias ALLM.{ChatResult, Message, Response, Thread}

  @type t ::
          {:message_started, %{message: Message.t()}}
          | {:text_delta, %{id: String.t() | nil, delta: String.t()}}
          | {:text_completed, %{id: String.t() | nil, text: String.t()}}
          | {:tool_call_started, %{id: String.t(), name: String.t()}}
          | {:tool_call_delta, %{id: String.t(), arguments_delta: String.t()}}
          | {:tool_call_completed,
             %{id: String.t(), name: String.t(), arguments: map(), raw_arguments: String.t()}}
          | {:tool_execution_started, %{id: String.t(), name: String.t(), arguments: map()}}
          | {:tool_execution_completed, %{id: String.t(), name: String.t(), result: term()}}
          | {:tool_result_encoded, %{id: String.t(), content: String.t()}}
          | {:ask_user_requested,
             %{
               tool_call_id: String.t(),
               tool_name: String.t(),
               question: String.t(),
               opts: keyword()
             }}
          | {:tool_halt,
             %{
               required(:tool_call_id) => String.t(),
               required(:reason) => atom(),
               required(:result) => term(),
               optional(:content) => String.t()
             }}
          | {:message_completed,
             %{
               required(:message) => Message.t(),
               required(:finish_reason) => Response.finish_reason() | nil,
               optional(:metadata) => map()
             }}
          | {:step_completed,
             %{
               response: Response.t(),
               thread: Thread.t(),
               mode: :auto | :manual
             }}
          | {:chat_completed, %{result: ChatResult.t()}}
          | {:raw_chunk, term()}
          | {:error, term()}

  @tags ~w(
    message_started text_delta text_completed
    tool_call_started tool_call_delta tool_call_completed
    tool_execution_started tool_execution_completed tool_result_encoded
    ask_user_requested tool_halt
    message_completed step_completed chat_completed
    raw_chunk error
  )a

  @opaque_payload_tags [:raw_chunk, :error]

  @doc """
  Return `true` when `value` is a well-shaped `ALLM.Event`.

  Accepts any 2-tuple whose first element is an atom in `tags/0`. For every
  tag except `:raw_chunk` and `:error`, additionally requires the second
  element to be a `map()` (the per-tag key contract is documented by each
  variant constructor, but not enforced here — adapter-emitted events are
  trusted).

  ## Examples

      iex> ALLM.Event.event?({:text_delta, %{id: "a", delta: "b"}})
      true

      iex> ALLM.Event.event?({:raw_chunk, "any opaque term"})
      true

      iex> ALLM.Event.event?({:text_delta, "not a map"})
      false

      iex> ALLM.Event.event?(:not_an_event)
      false
  """
  @spec event?(term()) :: boolean()
  def event?({tag, _payload}) when tag in @opaque_payload_tags, do: true

  def event?({tag, payload}) when is_atom(tag) and is_map(payload) do
    tag in @tags
  end

  def event?(_), do: false

  @doc """
  Return the closed list of 16 event tag atoms — 14 structured variants plus
  `:raw_chunk` and `:error`.

  ## Examples

      iex> tags = ALLM.Event.tags()
      iex> length(tags)
      16
      iex> :raw_chunk in tags and :error in tags
      true
  """
  @spec tags() :: [atom()]
  def tags, do: @tags

  @doc """
  Build a `:text_delta` event. `id` may be `nil` when the adapter doesn't
  associate deltas with a specific message id.

  ## Examples

      iex> ALLM.Event.text_delta("m_1", "hel")
      {:text_delta, %{id: "m_1", delta: "hel"}}
  """
  @spec text_delta(String.t() | nil, String.t()) :: t()
  def text_delta(id, delta) when (is_binary(id) or is_nil(id)) and is_binary(delta),
    do: {:text_delta, %{id: id, delta: delta}}

  @doc """
  Build a `:text_completed` event with the accumulated text for a message.

  ## Examples

      iex> ALLM.Event.text_completed("m_1", "hello")
      {:text_completed, %{id: "m_1", text: "hello"}}
  """
  @spec text_completed(String.t() | nil, String.t()) :: t()
  def text_completed(id, text) when (is_binary(id) or is_nil(id)) and is_binary(text),
    do: {:text_completed, %{id: id, text: text}}

  @doc """
  Build a `:tool_call_started` event.

  ## Examples

      iex> ALLM.Event.tool_call_started("call_1", "weather")
      {:tool_call_started, %{id: "call_1", name: "weather"}}
  """
  @spec tool_call_started(String.t(), String.t()) :: t()
  def tool_call_started(id, name) when is_binary(id) and is_binary(name),
    do: {:tool_call_started, %{id: id, name: name}}

  @doc """
  Build a `:tool_call_delta` event carrying an incremental argument-string
  fragment for the tool call with the given id.

  ## Examples

      iex> ALLM.Event.tool_call_delta("call_1", "{\\"city")
      {:tool_call_delta, %{id: "call_1", arguments_delta: "{\\"city"}}
  """
  @spec tool_call_delta(String.t(), String.t()) :: t()
  def tool_call_delta(id, arguments_delta) when is_binary(id) and is_binary(arguments_delta),
    do: {:tool_call_delta, %{id: id, arguments_delta: arguments_delta}}

  @doc """
  Build a `:tool_call_completed` event with the parsed arguments map and the
  original provider JSON string (`raw_arguments`).

  ## Examples

      iex> ALLM.Event.tool_call_completed("call_1", "weather", %{"city" => "SFO"}, ~S({"city":"SFO"}))
      {:tool_call_completed, %{id: "call_1", name: "weather", arguments: %{"city" => "SFO"}, raw_arguments: ~S({"city":"SFO"})}}
  """
  @spec tool_call_completed(String.t(), String.t(), map(), String.t()) :: t()
  def tool_call_completed(id, name, arguments, raw_arguments)
      when is_binary(id) and is_binary(name) and is_map(arguments) and is_binary(raw_arguments) do
    {:tool_call_completed,
     %{id: id, name: name, arguments: arguments, raw_arguments: raw_arguments}}
  end

  @doc """
  Build a `:tool_execution_started` event.

  ## Examples

      iex> ALLM.Event.tool_execution_started("call_1", "weather", %{"city" => "SFO"})
      {:tool_execution_started, %{id: "call_1", name: "weather", arguments: %{"city" => "SFO"}}}
  """
  @spec tool_execution_started(String.t(), String.t(), map()) :: t()
  def tool_execution_started(id, name, arguments)
      when is_binary(id) and is_binary(name) and is_map(arguments) do
    {:tool_execution_started, %{id: id, name: name, arguments: arguments}}
  end

  @doc """
  Build a `:tool_execution_completed` event with the handler's opaque result
  (pre-encoding).

  ## Examples

      iex> ALLM.Event.tool_execution_completed("call_1", "weather", "sunny")
      {:tool_execution_completed, %{id: "call_1", name: "weather", result: "sunny"}}
  """
  @spec tool_execution_completed(String.t(), String.t(), term()) :: t()
  def tool_execution_completed(id, name, result) when is_binary(id) and is_binary(name) do
    {:tool_execution_completed, %{id: id, name: name, result: result}}
  end

  @doc """
  Build a `:tool_result_encoded` event with the provider-ready text content
  that will become the tool-role message body.

  ## Examples

      iex> ALLM.Event.tool_result_encoded("call_1", "sunny")
      {:tool_result_encoded, %{id: "call_1", content: "sunny"}}
  """
  @spec tool_result_encoded(String.t(), String.t()) :: t()
  def tool_result_encoded(id, content) when is_binary(id) and is_binary(content),
    do: {:tool_result_encoded, %{id: id, content: content}}

  @doc """
  Build an `:ask_user_requested` event signalling that the chat loop halted
  pending a user answer (spec §12.3).

  ## Examples

      iex> ALLM.Event.ask_user_requested("call_1", "weather", "Which city?", [])
      {:ask_user_requested, %{tool_call_id: "call_1", tool_name: "weather", question: "Which city?", opts: []}}
  """
  @spec ask_user_requested(String.t(), String.t(), String.t(), keyword()) :: t()
  def ask_user_requested(tool_call_id, tool_name, question, opts)
      when is_binary(tool_call_id) and is_binary(tool_name) and is_binary(question) and
             is_list(opts) do
    {:ask_user_requested,
     %{
       tool_call_id: tool_call_id,
       tool_name: tool_name,
       question: question,
       opts: opts
     }}
  end

  @doc """
  Build a `:tool_halt` event — the handler returned `{:halt, reason, result}`.

  ## Examples

      iex> ALLM.Event.tool_halt("call_1", :rate_limited, %{retry_after: 30})
      {:tool_halt, %{tool_call_id: "call_1", reason: :rate_limited, result: %{retry_after: 30}}}
  """
  @spec tool_halt(String.t(), atom(), term()) :: t()
  def tool_halt(tool_call_id, reason, result) when is_binary(tool_call_id) and is_atom(reason),
    do: {:tool_halt, %{tool_call_id: tool_call_id, reason: reason, result: result}}

  @doc """
  Build a `:tool_halt` event with the pre-encoded tool-result `content`. The
  payload's `:content` key lets `ALLM.StreamCollector`'s `:tool_halt` fold
  populate `state.tool_results` with the sentinel `:tool`-role message
  without re-running the encoder. See PHASE_7_DESIGN.md Non-obvious
  Decision #6 + Phase 7.6 cleanup.

  ## Examples

      iex> ALLM.Event.tool_halt("call_1", :rate_limited, %{retry_after: 30}, "encoded-body")
      {:tool_halt, %{tool_call_id: "call_1", reason: :rate_limited, result: %{retry_after: 30}, content: "encoded-body"}}
  """
  @spec tool_halt(String.t(), atom(), term(), String.t()) :: t()
  def tool_halt(tool_call_id, reason, result, content)
      when is_binary(tool_call_id) and is_atom(reason) and is_binary(content) do
    {:tool_halt, %{tool_call_id: tool_call_id, reason: reason, result: result, content: content}}
  end

  @doc """
  Build a `:message_started` event with the in-progress assistant message.

  ## Examples

      iex> msg = %ALLM.Message{role: :assistant, content: ""}
      iex> ALLM.Event.message_started(msg)
      {:message_started, %{message: msg}}
  """
  @spec message_started(Message.t()) :: t()
  def message_started(%Message{} = message),
    do: {:message_started, %{message: message}}

  @doc """
  Build a `:message_completed` event with the finalized message. The payload
  carries `:finish_reason => nil`; use `message_completed/2` to populate a
  specific finish reason. See "Payload extensions" in the module doc.

  The payload may also carry an optional `:metadata` map that
  `ALLM.StreamCollector.apply_event/2` merges into `state.metadata` —
  see `message_completed/3` and "Payload extensions" in the module doc.
  This 1-arity helper omits the key (no provider metadata to surface).

  ## Examples

      iex> msg = %ALLM.Message{role: :assistant, content: "ok"}
      iex> ALLM.Event.message_completed(msg)
      {:message_completed, %{message: msg, finish_reason: nil}}
  """
  @spec message_completed(Message.t()) :: t()
  def message_completed(%Message{} = message),
    do: {:message_completed, %{message: message, finish_reason: nil}}

  @doc """
  Build a `:message_completed` event with the finalized message and a
  finish-reason atom (or `nil`). The guard accepts any atom — the closed
  `t:ALLM.Response.finish_reason/0` enum is enforced by `@type t` and by
  `Response.finish_reason/0`, not at the event-construction boundary. This
  lets adapters preserve provider-specific reasons downstream as
  `Response.raw_finish_reason`.

  See `message_completed/3` to additionally attach an optional `:metadata`
  map to the payload (folded onto `Response.metadata` by
  `ALLM.StreamCollector`). This 2-arity helper omits the key.

  ## Examples

      iex> msg = %ALLM.Message{role: :assistant, content: "ok"}
      iex> ALLM.Event.message_completed(msg, :stop)
      {:message_completed, %{message: msg, finish_reason: :stop}}

      iex> msg = %ALLM.Message{role: :assistant, content: "ok"}
      iex> ALLM.Event.message_completed(msg, nil) == ALLM.Event.message_completed(msg)
      true
  """
  @spec message_completed(Message.t(), Response.finish_reason() | nil) :: t()
  def message_completed(%Message{} = message, finish_reason)
      when is_atom(finish_reason) or is_nil(finish_reason),
      do: {:message_completed, %{message: message, finish_reason: finish_reason}}

  @doc """
  Build a `:message_completed` event with the finalized message, a
  finish-reason atom (or `nil`), and an optional `:metadata` map carrying
  terminal provider-specific completion data (Phase 10.6).

  When `metadata` is non-empty, `ALLM.StreamCollector.apply_event/2` merges
  it into `state.metadata` via `Map.merge/2`, so the values land on
  `Response.metadata` after collection. When the map is empty, the key is
  omitted from the payload to keep the event payload identical to
  `message_completed/2` (no observable difference for downstream
  consumers).

  Worked example: the OpenAI Responses-API streaming adapter accumulates
  reasoning-summary delta chunks into a string and emits
  `%{reasoning: %{summary: "..."}}` here; the value surfaces as
  `Response.metadata.reasoning.summary` after stream collection.

  ## Examples

      iex> msg = %ALLM.Message{role: :assistant, content: "Final answer."}
      iex> ALLM.Event.message_completed(msg, :stop, %{reasoning: %{summary: "Thinking"}})
      {:message_completed,
        %{message: msg, finish_reason: :stop, metadata: %{reasoning: %{summary: "Thinking"}}}}

      iex> msg = %ALLM.Message{role: :assistant, content: "ok"}
      iex> ALLM.Event.message_completed(msg, :stop, %{}) == ALLM.Event.message_completed(msg, :stop)
      true
  """
  @spec message_completed(Message.t(), Response.finish_reason() | nil, map()) :: t()
  def message_completed(%Message{} = message, finish_reason, metadata)
      when (is_atom(finish_reason) or is_nil(finish_reason)) and is_map(metadata) do
    if map_size(metadata) == 0 do
      {:message_completed, %{message: message, finish_reason: finish_reason}}
    else
      {:message_completed, %{message: message, finish_reason: finish_reason, metadata: metadata}}
    end
  end

  @doc """
  Build a `:step_completed` event with the response and the updated thread.

  Equivalent to `step_completed(response, thread, :auto)`. The payload's
  `:mode` key carries the orchestration mode the step ran under so that
  reducers (`StreamCollector`'s `:step_completed` fold, multi-turn chat
  orchestrators) can produce StepResult metadata identical to the
  non-streaming `Chat.step/3` path. See Phase 7 retro F1+F3.

  ## Examples

      iex> ALLM.Event.step_completed(%ALLM.Response{output_text: "ok"}, %ALLM.Thread{messages: []})
      {:step_completed, %{response: %ALLM.Response{output_text: "ok"}, thread: %ALLM.Thread{messages: []}, mode: :auto}}
  """
  @spec step_completed(Response.t(), Thread.t()) :: t()
  def step_completed(%Response{} = response, %Thread{} = thread),
    do: step_completed(response, thread, :auto)

  @doc """
  Build a `:step_completed` event with the response, the updated thread,
  and the orchestration mode (`:auto` or `:manual`) the step ran under.

  ## Examples

      iex> ALLM.Event.step_completed(%ALLM.Response{output_text: "ok"}, %ALLM.Thread{messages: []}, :manual)
      {:step_completed, %{response: %ALLM.Response{output_text: "ok"}, thread: %ALLM.Thread{messages: []}, mode: :manual}}
  """
  @spec step_completed(Response.t(), Thread.t(), :auto | :manual) :: t()
  def step_completed(%Response{} = response, %Thread{} = thread, mode)
      when mode in [:auto, :manual],
      do: {:step_completed, %{response: response, thread: thread, mode: mode}}

  @doc """
  Build a `:chat_completed` event wrapping the final `ChatResult`.

  ## Examples

      iex> result = %ALLM.ChatResult{
      ...>   thread: %ALLM.Thread{},
      ...>   final_response: %ALLM.Response{},
      ...>   halted_reason: :completed
      ...> }
      iex> ALLM.Event.chat_completed(result)
      {:chat_completed, %{result: result}}
  """
  @spec chat_completed(ChatResult.t()) :: t()
  def chat_completed(%ChatResult{} = result),
    do: {:chat_completed, %{result: result}}
end
