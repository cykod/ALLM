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
  | `:prompt_cache` | `nil \\| %{key: String.t \\| nil, retention: :short \\| :long}` | `nil` | Provider-neutral prompt-cache request. See "Prompt caching". |
  | `:options` | `map` | `%{}` | Adapter-opaque pass-through. |
  | `:metadata` | `map` | `%{}` | Caller-owned. |

  Validation lives in `ALLM.Validate.request/1`. `new/2` itself does not
  validate — it stays composable so callers opt into validation
  explicitly.

  ## Prompt caching

  `:prompt_cache` asks the provider to cache the request's prompt prefix.
  It is `nil` (no request) or a map with exactly two keys:

    * `:key` — a routing key some providers use to send related requests to
      the same cache, or `nil`. Sent verbatim; never hashed or transformed.
    * `:retention` — `:short` keeps the provider's default cache lifetime
      and sends no lifetime field. `:long` asks for the longest per-request
      lifetime the provider offers.

  `ALLM.Validate.request/1` rejects any other shape with
  `{:prompt_cache, :invalid_shape}`. The field is typed rather than an
  `:options` entry so it has one validated shape and survives a JSON
  round-trip with its atoms restored. Raw provider cache parameters placed
  in `:options` are still sent as-is and take precedence over what an
  adapter derives from this field.

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}],
      ...>   prompt_cache: %{key: "recipe-42", retention: :long})
      iex> ALLM.Validate.request(req)
      :ok
      iex> {:ok, decoded} = ALLM.Serializer.from_json(ALLM.Serializer.to_json!(req))
      iex> decoded.prompt_cache
      %{key: "recipe-42", retention: :long}

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

  @type prompt_cache :: nil | %{key: String.t() | nil, retention: :short | :long}

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
          prompt_cache: prompt_cache(),
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
    prompt_cache: nil,
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
      prompt_cache: decode_prompt_cache(data["prompt_cache"]),
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

  # Restores the atom-keyed `prompt_cache` map. Only the exact two-key shape is
  # decoded; anything else (a partial or over-full persisted map, a non-map)
  # passes through unchanged so `ALLM.Validate.request/1` rejects it rather
  # than the decoder raising or silently dropping keys.
  defp decode_prompt_cache(nil), do: nil

  defp decode_prompt_cache(%{"key" => key, "retention" => retention} = map)
       when map_size(map) == 2 do
    %{key: key, retention: decode_retention(retention)}
  end

  defp decode_prompt_cache(other), do: other

  @doc false
  # Shared with the call-opt normalization of `prompt_cache:`, which receives
  # string-keyed maps from JSON round-tripped engine params. Never mints an
  # atom: unknown values pass through so validation rejects them.
  @spec decode_retention(term()) :: term()
  def decode_retention("short"), do: :short
  def decode_retention("long"), do: :long
  def decode_retention(other), do: other

  @doc false
  # The one definition of a valid `prompt_cache` value (`nil` excluded):
  # a map with exactly `:key` (nil or a non-empty binary) and `:retention`
  # (`:short` or `:long`). `ALLM.Validate.request/1` rejects anything else,
  # and each adapter's `put_prompt_cache/2` translates only what it accepts,
  # so a direct adapter call with an invalid value leaves the body unchanged.
  defguard is_prompt_cache(value)
           when is_map(value) and map_size(value) == 2 and is_map_key(value, :key) and
                  is_map_key(value, :retention) and
                  value.retention in [:short, :long] and
                  (value.key == nil or
                     (is_binary(value.key) and
                        value.key != ""))
end

defimpl Jason.Encoder, for: ALLM.Request do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
