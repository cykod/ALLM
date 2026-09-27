defmodule ALLM.ClassificationResponse do
  @moduledoc """
  A typed-classification response — Layer A serializable data.

      iex> a = ALLM.ClassificationAnswer.new(type: :choice, choice: "billing", confidence: 0.88)
      iex> resp = ALLM.ClassificationResponse.new(answers: %{"department" => a})
      iex> ALLM.ClassificationResponse.answer(resp, :department).choice
      "billing"

  ## Answers

  `:answers` is keyed by the same question ids the request used, one
  `ALLM.ClassificationAnswer` per question. Use `answer/2` to read one.

  ## Usage

  `:usage` is an `ALLM.Usage`, never `nil`. An adapter populates
  `:input_tokens` and `:output_tokens` from the provider and sets
  `:total_tokens` to their sum. The cost fields stay `nil`: no model
  catalog carries classification pricing, but pricing is per input token,
  so a caller who knows the rate can compute the cost.

  ## Identifiers

  `:id` is the provider's own identifier for the call — the value to quote
  to the provider's support team — or `nil` when the provider sends none.
  `:request_id` is ALLM's own correlation id. The two are never mixed: the
  provider's id is not copied into `:request_id`, and it is not put in
  `:metadata`, which is caller-owned.

  ## Other fields

  `:model` is the model the provider reports as having answered. For a
  provider with moving aliases this is the pinned version, not the alias
  that was sent. `:provider` is the provider atom. `:raw` carries the same
  caller-responsibility contract as `ALLM.Response.raw`: a
  non-JSON-encodable `:raw` raises at encode time.
  """

  alias ALLM.{Serializer, Usage}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          answers: %{String.t() => ALLM.ClassificationAnswer.t()},
          usage: Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :provider,
    :raw,
    answers: %{},
    usage: %Usage{},
    metadata: %{}
  ]

  @doc """
  Build a `%ClassificationResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.ClassificationResponse.new(model: "jev-1.13.0")
      iex> {resp.answers, resp.usage}
      {%{}, %ALLM.Usage{}}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The answer for `id`, or nil. Atom ids are stringified.

  ## Examples

      iex> a = ALLM.ClassificationAnswer.new(type: :yes_no, yes_probability: 0.93)
      iex> resp = ALLM.ClassificationResponse.new(answers: %{"refund" => a})
      iex> ALLM.ClassificationResponse.answer(resp, "refund").yes_probability
      0.93
      iex> ALLM.ClassificationResponse.answer(resp, "missing")
      nil
  """
  @spec answer(t(), String.t() | atom()) :: ALLM.ClassificationAnswer.t() | nil
  def answer(%__MODULE__{} = response, id) when is_atom(id),
    do: answer(response, Atom.to_string(id))

  def answer(%__MODULE__{answers: answers}, id) when is_binary(id), do: Map.get(answers, id)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      # `String.to_existing_atom/1` through the serializer helper; a bare
      # `String.to_atom/1` would be untrusted-input atom growth.
      provider: Serializer.to_atom_field(data["provider"]),
      answers: decode_answers(data["answers"] || %{}),
      usage: hydrate_usage(data["usage"]),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end

  defp decode_answers(answers) when is_map(answers),
    do: Map.new(answers, fn {id, answer} -> {id, Serializer.hydrate(answer)} end)

  defp decode_answers(other), do: other

  # Mirrors `ALLM.EmbeddingResponse`'s `hydrate_usage/1` so `:usage` is never
  # `nil` after a decode, including for payloads whose `"usage"` key is
  # absent or explicitly `null` (`Serializer.hydrate(nil)` returns `nil`).
  defp hydrate_usage(nil), do: %Usage{}

  defp hydrate_usage(%{"__type__" => _} = tagged) do
    case Serializer.hydrate(tagged) do
      %Usage{} = usage -> usage
      _ -> %Usage{}
    end
  end

  defp hydrate_usage(other), do: other
end

defimpl Jason.Encoder, for: ALLM.ClassificationResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
