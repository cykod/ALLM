defmodule ALLM.TranscriptionResponse do
  @moduledoc """
  A speech-to-text response. Layer A serializable data.

      iex> resp = ALLM.TranscriptionResponse.new(text: "The quick brown fox.")
      iex> resp.text
      "The quick brown fox."

  ## Fields

  - `:text`: the transcript. Plain text only. Timestamps, speaker labels
    and subtitle formats are not modelled, and the provider's full body
    stays on `:raw` for callers who need them.
  - `:language`: the spoken language as the provider reports it, not
    normalized, or `nil`.
  - `:duration_seconds`: billed audio seconds, when the provider bills
    transcription by duration.
  - `:id`, `:request_id`, `:model`, `:provider`: provider correlation.
  - `:usage`: an `t:ALLM.Usage.t/0`, never `nil`. Providers that bill in
    tokens populate it, and a response carrying no counters holds
    `%ALLM.Usage{}` with every field `nil`. Billed seconds go in
    `:duration_seconds` rather than `Usage.extra`, because a typed field
    survives a JSON round-trip without its keys turning from atoms into
    strings.
  - `:raw`: the provider's response body.
  - `:metadata`: caller-owned.

  A transcript produced by a general-purpose model prompted to transcribe,
  rather than by a dedicated speech model, is not guaranteed to be
  verbatim.
  """

  alias ALLM.{Serializer, Usage}

  @type t :: %__MODULE__{
          text: String.t(),
          language: String.t() | nil,
          duration_seconds: number() | nil,
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          usage: Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :language,
    :duration_seconds,
    :id,
    :request_id,
    :model,
    :provider,
    :raw,
    text: "",
    usage: %Usage{},
    metadata: %{}
  ]

  @doc """
  Build a `%TranscriptionResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.TranscriptionResponse.new()
      iex> {resp.text, resp.usage}
      {"", %ALLM.Usage{}}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      text: data["text"] || "",
      language: data["language"],
      duration_seconds: data["duration_seconds"],
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      provider: Serializer.to_atom_field(data["provider"]),
      usage: hydrate_usage(data["usage"]),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end

  # `:usage` is never `nil` after a decode, including when the key is
  # absent or explicitly `null`.
  defp hydrate_usage(nil), do: %Usage{}

  defp hydrate_usage(%{"__type__" => _} = tagged) do
    case Serializer.hydrate(tagged) do
      %Usage{} = usage -> usage
      _ -> %Usage{}
    end
  end

  defp hydrate_usage(other), do: other
end

defimpl Jason.Encoder, for: ALLM.TranscriptionResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
