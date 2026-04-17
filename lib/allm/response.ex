defmodule ALLM.Response do
  @moduledoc "See spec §5.5."

  alias ALLM.{Message, ToolCall, Usage}

  @type finish_reason ::
          :stop | :length | :tool_calls | :content_filter | :error | :other

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          message: Message.t() | nil,
          output_text: String.t() | nil,
          tool_calls: [ToolCall.t()],
          finish_reason: finish_reason() | nil,
          raw_finish_reason: String.t() | nil,
          usage: Usage.t(),
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
    usage: %Usage{},
    metadata: %{}
  ]
end
