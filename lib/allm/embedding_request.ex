defmodule ALLM.EmbeddingRequest do
  @moduledoc """
  A text-embedding request — Layer A serializable data.

      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"], task_type: :search_document)
      iex> req.truncate
      true

  ## `:input` is always a list

  The bare-string call shape belongs to the façade — `ALLM.embedding_request/2`
  normalizes `"one chunk"` to `["one chunk"]`. On the struct, `:input` is
  always `[String.t()]`, so no adapter or validator arm has to handle a
  union. There is deliberately no `@enforce_keys`: `input: []` must be
  *constructible* so that `ALLM.Validate.embedding_request/1` — not
  `struct!/2` — is what rejects it.

  ## `:task_type`

  A provider-neutral closed enum for asymmetric embedding: encoding a search
  query differently from the documents it will be matched against measurably
  improves retrieval. It maps to Gemini's `taskType` and Voyage's
  `input_type`. OpenAI has no equivalent and its adapter drops the field
  rather than erroring, matching the contract images set for
  `response_format` on `gpt-image-1`.

  `:task_type` is one of ALLM's closed atom enums; an unknown value at
  decode time raises `ArgumentError` and surfaces as
  `{:_unknown, :atom_decode_failed}` per the serializer's rescue contract.
  A value that happens to already exist as an atom decodes through — call
  `ALLM.Validate.embedding_request/1` if you need the enum enforced.

  ## Other fields

  `:truncate` defaults to `true`, matching the provider-side default on
  every bundled target, so adapters omit it from the wire body when `true`
  and send it explicitly only when `false`. `:options` is the documented
  home for provider-specific opaque opts (OpenAI's request-level `user`
  identifier, for example). `:dimensions` requests a truncated output
  dimensionality where the model supports it; per-model caps are not checked
  here — that is `ALLM.Capability.preflight_embedding/2`'s job.
  """

  alias ALLM.Serializer

  @typedoc """
  Closed enum of provider-neutral embedding task types.
  """
  @type task_type ::
          :search_document | :search_query | :classification | :clustering | :similarity

  @type t :: %__MODULE__{
          input: [String.t()],
          model: String.t() | nil,
          dimensions: pos_integer() | nil,
          task_type: task_type() | nil,
          truncate: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :dimensions,
    :task_type,
    input: [],
    truncate: true,
    options: %{},
    metadata: %{}
  ]

  @doc """
  Build an `%EmbeddingRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. No validation — call
  `ALLM.Validate.embedding_request/1` to check the field rules.

  ## Examples

      iex> req = ALLM.EmbeddingRequest.new()
      iex> req.input
      []
      iex> req.task_type
      nil

      iex> req = ALLM.EmbeddingRequest.new(input: ["a", "b"], dimensions: 512)
      iex> length(req.input)
      2
      iex> req.dimensions
      512
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      input: data["input"] || [],
      model: data["model"],
      dimensions: data["dimensions"],
      task_type: Serializer.to_atom_field(data["task_type"]),
      truncate: decode_truncate(data["truncate"]),
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  # `:truncate` defaults to `true`, so the `data["truncate"] || true` idiom
  # used for other defaulted fields would silently flip an explicit `false`
  # back to the default. Only a missing/`nil` value takes the default.
  defp decode_truncate(nil), do: true
  defp decode_truncate(other), do: other
end

defimpl Jason.Encoder, for: ALLM.EmbeddingRequest do
  # No tuple-carrying and no keyword-typed field, so this is a plain
  # `encode_tagged/2` delegate with no pre-pass — contrast
  # `ALLM.ImageRequest`'s `:size` transform.
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
