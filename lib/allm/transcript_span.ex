defmodule ALLM.TranscriptSpan do
  @moduledoc """
  One timed or scored unit of a transcript: a word, the spacing between
  two words, a non-speech audio event, or a model token. Layer A
  serializable data.

      iex> span = ALLM.TranscriptSpan.new(text: "fox", kind: :word, start_seconds: 1.2, end_seconds: 1.5, logprob: -0.02)
      iex> {span.text, span.kind, span.start_seconds}
      {"fox", :word, 1.2}

  Spans appear on `ALLM.TranscriptionResponse`'s `:spans` field and on the
  `:committed_transcript` and `:transcription_completed` events of a
  streaming transcription, and only when the request opted in with
  `timestamps: true` or `logprobs: true`.

  ## Fields

  - `:text`: the unit's text, as the provider returned it.
  - `:kind`: one of `kinds/0`. `:word`, `:spacing` and `:audio_event` are
    the units of a word-timed transcript (an `:audio_event` is a
    non-speech sound such as laughter). `:token` is a model token, the unit
    a token-level log-probability attaches to. `:other` is any unit a
    provider labels with a type outside that list.
  - `:start_seconds`, `:end_seconds`: where the unit starts and ends in the
    audio, in seconds. Set only when the request asked for
    `timestamps: true`, and `nil` otherwise, even when the provider sent
    them. Not checked for `start_seconds <= end_seconds`; they are the
    provider's values.
  - `:logprob`: the natural-log probability the model assigned to the
    unit, normally zero or negative. Set only when the request asked for
    `logprobs: true`, and `nil` otherwise, even when the provider sent it.

  A requested attribute can still be `nil` on a span when the provider
  omitted it for that unit. The output depends on the request, not on
  which attributes a provider happens to send.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through. `:text` and `:kind` are
  required, so leaving either out raises `ArgumentError`. Unknown keys
  raise `KeyError`. Field values are not checked.

  ## Serializability

  Round-trips through `:erlang.term_to_binary/1` and through
  `ALLM.Serializer`'s JSON encoding. A decoded `:kind` string outside
  `kinds/0` becomes `:other` rather than raising.
  """

  @typedoc "What a span measures. See `kinds/0`."
  @type kind :: :word | :spacing | :audio_event | :token | :other

  @type t :: %__MODULE__{
          text: String.t(),
          kind: kind(),
          start_seconds: number() | nil,
          end_seconds: number() | nil,
          logprob: number() | nil
        }

  @enforce_keys [:text, :kind]
  defstruct [:text, :kind, :start_seconds, :end_seconds, :logprob]

  @kinds [:word, :spacing, :audio_event, :token, :other]

  # A literal string -> atom table, so decoding never calls
  # `String.to_atom/1` or `String.to_existing_atom/1` on persisted input.
  @kind_by_string Map.new(@kinds, &{Atom.to_string(&1), &1})

  @doc """
  Build a `%TranscriptSpan{}` from keyword opts.

  Raises `ArgumentError` when `:text` or `:kind` is missing, and `KeyError`
  on an unknown key.

  ## Examples

      iex> ALLM.TranscriptSpan.new(text: "hello", kind: :token, logprob: -0.5)
      %ALLM.TranscriptSpan{text: "hello", kind: :token, start_seconds: nil, end_seconds: nil, logprob: -0.5}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The closed list of `:kind` values.

  ## Examples

      iex> ALLM.TranscriptSpan.kinds()
      [:word, :spacing, :audio_event, :token, :other]
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      text: data["text"],
      kind: decode_kind(data["kind"]),
      start_seconds: data["start_seconds"],
      end_seconds: data["end_seconds"],
      logprob: data["logprob"]
    }
  end

  defp decode_kind(kind) when is_binary(kind), do: Map.get(@kind_by_string, kind, :other)
  defp decode_kind(_), do: :other
end

defimpl Jason.Encoder, for: ALLM.TranscriptSpan do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
