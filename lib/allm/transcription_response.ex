defmodule ALLM.TranscriptionResponse do
  @moduledoc """
  A speech-to-text response. Layer A serializable data.

      iex> resp = ALLM.TranscriptionResponse.new(text: "The quick brown fox.")
      iex> resp.text
      "The quick brown fox."

  ## Fields

  - `:text`: the transcript, as plain text.
  - `:spans`: the transcript's words or tokens as `t:ALLM.TranscriptSpan.t/0`
    values, in order, carrying start and end times when the request set
    `timestamps: true` and log-probabilities when it set `logprobs: true`.
    `nil` means neither flag was set; `[]` means a flag was set and nothing
    was spoken. Segment-level timestamps, speaker labels and subtitle
    formats are not modelled, and the provider's full body stays on `:raw`
    for callers who need them. `mean_logprob/1` summarizes the spans.
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

  alias ALLM.{Serializer, TranscriptSpan, Usage}

  @type t :: %__MODULE__{
          text: String.t(),
          language: String.t() | nil,
          duration_seconds: number() | nil,
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          usage: Usage.t(),
          spans: [TranscriptSpan.t()] | nil,
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
    :spans,
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

  @doc """
  The mean log-probability of the response's spoken units, or `nil`.

  Averages `:logprob` over the spans whose `:kind` is `:word` or `:token`
  and whose `:logprob` is a number. `:spacing` and `:audio_event` spans are
  left out because they are not spoken units, and some providers copy the
  next word's log-probability onto the spacing before it, which would
  count that word twice. Returns `nil` when `:spans` is `nil` or no span
  qualifies.

  ## Examples

      iex> spans = [
      ...>   ALLM.TranscriptSpan.new(text: "quick", kind: :word, logprob: -0.25),
      ...>   ALLM.TranscriptSpan.new(text: " ", kind: :spacing, logprob: -0.25),
      ...>   ALLM.TranscriptSpan.new(text: "fox", kind: :word, logprob: -0.5)
      ...> ]
      iex> ALLM.TranscriptionResponse.mean_logprob(ALLM.TranscriptionResponse.new(spans: spans))
      -0.375

      iex> ALLM.TranscriptionResponse.mean_logprob(ALLM.TranscriptionResponse.new())
      nil
  """
  @spec mean_logprob(t()) :: float() | nil
  def mean_logprob(%__MODULE__{spans: spans}) when is_list(spans) do
    spans
    |> Enum.filter(&spoken_logprob?/1)
    |> Enum.map(& &1.logprob)
    |> mean()
  end

  def mean_logprob(%__MODULE__{}), do: nil

  defp spoken_logprob?(%TranscriptSpan{kind: kind, logprob: lp}),
    do: kind in [:word, :token] and is_number(lp)

  defp spoken_logprob?(_), do: false

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

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
      spans: Serializer.hydrate(data["spans"]),
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
