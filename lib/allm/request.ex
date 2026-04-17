defmodule ALLM.Request do
  @moduledoc "See spec §5.4."

  alias ALLM.{Message, Tool}

  @type response_format ::
          nil
          | :text
          | %{type: :json_object}
          | %{type: :json_schema, name: String.t(), schema: map(), strict: boolean()}

  @type tool_choice :: :auto | :none | :required | String.t() | map() | nil

  @type t :: %__MODULE__{
          model: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()],
          tool_choice: tool_choice(),
          temperature: number() | nil,
          max_tokens: non_neg_integer() | nil,
          stream: boolean(),
          response_format: response_format(),
          structured_finalize: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :messages,
    :temperature,
    :max_tokens,
    :response_format,
    tools: [],
    tool_choice: nil,
    stream: false,
    structured_finalize: false,
    options: %{},
    metadata: %{}
  ]
end
