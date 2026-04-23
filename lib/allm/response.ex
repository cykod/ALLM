defmodule ALLM.Response do
  @moduledoc """
  A single LLM response. See spec §5.5.

  Layer A — pure serializable data. Carries the assistant `:message`, optional
  top-level `:output_text` convenience, `:tool_calls` the model wants invoked,
  `:finish_reason` (closed union), and `:usage` / `:raw` provider extras.

  `:output_text` exists so callers can read the flat text payload without
  re-deriving it from `:message.content`; use `text/1` for the canonical
  fallback behaviour.
  """

  alias ALLM.{Message, ToolCall, Usage}

  @typedoc "Canonical finish-reason atom; see spec §5.5."
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

  @doc """
  Build a `%Response{}` from keyword opts.

  Every field is optional. Unknown keys raise `ArgumentError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.Response.new(output_text: "hi", finish_reason: :stop)
      iex> resp.output_text
      "hi"
      iex> resp.finish_reason
      :stop
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Return the flat text of a response: `:output_text` if set, else the string
  `:content` of `:message`, else `nil`.

  A list-shaped `message.content` (structured parts) returns `nil` — callers
  that need to flatten structured parts should do so explicitly.

  ## Examples

      iex> ALLM.Response.text(ALLM.Response.new(output_text: "direct"))
      "direct"

      iex> ALLM.Response.text(ALLM.Response.new(message: %ALLM.Message{role: :assistant, content: "from-msg"}))
      "from-msg"

      iex> ALLM.Response.text(ALLM.Response.new([]))
      nil
  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{output_text: t}) when is_binary(t), do: t
  def text(%__MODULE__{message: %Message{content: c}}) when is_binary(c), do: c
  def text(%__MODULE__{}), do: nil

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      message: hydrate_optional(data["message"]),
      output_text: data["output_text"],
      tool_calls: ALLM.Serializer.hydrate(data["tool_calls"] || []),
      finish_reason: ALLM.Serializer.to_atom_field(data["finish_reason"]),
      raw_finish_reason: data["raw_finish_reason"],
      usage: hydrate_usage(data["usage"]),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_optional(nil), do: nil
  defp hydrate_optional(value), do: ALLM.Serializer.hydrate(value)

  defp hydrate_usage(nil), do: %Usage{}
  defp hydrate_usage(value), do: ALLM.Serializer.hydrate(value)
end

defimpl Jason.Encoder, for: ALLM.Response do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
