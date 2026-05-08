defmodule ALLM.Request do
  @moduledoc """
  A single LLM request — Layer A serializable data.

  Carries the `:messages` list, optional `:model`, `:tools`, `:tool_choice`,
  `:temperature`, `:max_tokens`, `:response_format`, and adapter-opaque
  `:options` and `:metadata`.

  ## Fields

  | Field | Type | Default | Notes |
  |-------|------|---------|-------|
  | `:messages` | `[%Message{}]` | (required) | The conversation. |
  | `:model` | `String.t \\| nil` | `nil` | Late-resolved against the engine. |
  | `:tools` | `[%Tool{}]` | `[]` | Declared tools. |
  | `:tool_choice` | `:auto \\| :none \\| :required \\| String.t \\| map \\| nil` | `nil` | Provider-specific shapes pass through verbatim. |
  | `:temperature` | `number \\| nil` | `nil` | |
  | `:max_tokens` | `non_neg_integer \\| nil` | `nil` | Anthropic's adapter injects `1024` if `nil`. |
  | `:response_format` | `nil \\| :text \\| %{type: :json_object} \\| %{type: :json_schema, ...}` | `nil` | Build with `ALLM.json_schema/3`. |
  | `:stream` | `boolean` | `false` | |
  | `:structured_finalize` | `boolean` | `false` | Synthetic-tool fallback for providers without native JSON-schema mode. |
  | `:options` | `map` | `%{}` | Adapter-opaque pass-through. |
  | `:metadata` | `map` | `%{}` | Caller-owned. |

  Validation lives in `ALLM.Validate.request/1`. `new/2` itself does not
  validate — it stays composable so callers opt into validation
  explicitly.

  ## Round-trip

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], model: "fake:x")
      iex> json = ALLM.Serializer.to_json!(req)
      iex> {:ok, ^req} = ALLM.Serializer.from_json(json)
      iex> req.model
      "fake:x"

  See also `guides/getting_started.md`.
  """

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

  @doc """
  Build a `%Request{}` from a list of messages and keyword opts.

  `messages` is required and becomes the `:messages` field. `opts` may set any
  other struct field; unknown keys raise `ArgumentError` via `struct!/2`.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}])
      iex> req.stream
      false
      iex> length(req.messages)
      1

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], model: "fake:x", temperature: 0.2)
      iex> {req.model, req.temperature}
      {"fake:x", 0.2}
  """
  @spec new([Message.t()], keyword()) :: t()
  def new(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    struct!(__MODULE__, [{:messages, messages} | opts])
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      model: data["model"],
      messages: ALLM.Serializer.hydrate(data["messages"] || []),
      tools: ALLM.Serializer.hydrate(data["tools"] || []),
      tool_choice: decode_tool_choice(data["tool_choice"]),
      temperature: data["temperature"],
      max_tokens: data["max_tokens"],
      stream: data["stream"] || false,
      response_format: decode_response_format(data["response_format"]),
      structured_finalize: data["structured_finalize"] || false,
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  defp decode_tool_choice(nil), do: nil
  defp decode_tool_choice("auto"), do: :auto
  defp decode_tool_choice("none"), do: :none
  defp decode_tool_choice("required"), do: :required
  defp decode_tool_choice(other), do: other

  defp decode_response_format(nil), do: nil
  defp decode_response_format("text"), do: :text
  defp decode_response_format(other), do: restore_response_format(other)

  # Restores atom-keyed `response_format` map shapes from their JSON-decoded
  # string-keyed counterparts. The two recognized shapes (per `@type
  # response_format` above):
  #
  #   * `%{"type" => "json_object"}` -> `%{type: :json_object}`
  #   * `%{"type" => "json_schema", "name" => _, "schema" => _, "strict" => _}`
  #     -> `%{type: :json_schema, name: _, schema: _, strict: _}`
  #
  # Any other map passes through unchanged — the escape-hatch per spec §5.4,
  # where callers may attach provider-specific shapes the core does not model.
  # Non-map, non-nil, non-"text" values also pass through unchanged.
  defp restore_response_format(%{"type" => "json_object"} = map) when map_size(map) == 1 do
    %{type: :json_object}
  end

  defp restore_response_format(%{
         "type" => "json_schema",
         "name" => name,
         "schema" => schema,
         "strict" => strict
       }) do
    %{type: :json_schema, name: name, schema: schema, strict: strict}
  end

  defp restore_response_format(other), do: other
end

defimpl Jason.Encoder, for: ALLM.Request do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
