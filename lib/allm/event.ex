defmodule ALLM.Event do
  @moduledoc "See spec §8 — closed tagged-tuple union emitted by stream runners."

  alias ALLM.{ChatResult, Message, Response, Thread}

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
             %{
               tool_call_id: String.t(),
               tool_name: String.t(),
               question: String.t(),
               opts: keyword()
             }}
          | {:tool_halt, %{tool_call_id: String.t(), reason: atom(), result: term()}}
          | {:message_completed, %{message: Message.t()}}
          | {:step_completed, %{response: Response.t(), thread: Thread.t()}}
          | {:chat_completed, %{result: ChatResult.t()}}
          | {:raw_chunk, term()}
          | {:error, term()}
end
