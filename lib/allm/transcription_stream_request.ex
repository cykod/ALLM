defmodule ALLM.TranscriptionStreamRequest do
  @moduledoc """
  The configuration of a streaming (realtime) transcription session.
  Layer A serializable data.

      iex> cfg = ALLM.TranscriptionStreamRequest.new(sample_rate: 16_000, language: "en")
      iex> ALLM.Validate.transcription_stream_request(cfg)
      :ok

  The audio itself is not a field. It is an enumerable passed alongside
  this struct, whose elements are 16-bit little-endian mono PCM binaries at
  `:sample_rate`, or the atom `:commit` to end a segment under `:manual`
  commit. An enumerable is not serializable data, which is why it stays out
  of the struct.

  ## Fields

  - `:model`: the realtime model, or `nil` for the adapter's default. There
    is no fallback to the engine's transcription model: batch and realtime
    model names are separate namespaces on some providers, so a batch model
    would be rejected here.
  - `:language`: an optional hint for the spoken language (for example
    `"en"`).
  - `:sample_rate`: the rate in Hz of the PCM being sent. Defaults to
    16,000. Each adapter accepts its own set of rates.
  - `:commit_strategy`: `:vad` (the default) lets the provider decide when
    a segment ends; `:manual` ends one only when the input yields `:commit`.
    One of `commit_strategies/0`.
  - `:timestamps`: `true` asks for per-word start and end times on each
    committed segment's `:spans` (see `ALLM.TranscriptSpan` and
    `ALLM.TranscriptionEvent`). Defaults to `false`.
  - `:logprobs`: `true` asks for per-word or per-token log-probabilities
    on each committed segment's `:spans`. Defaults to `false`. With both
    flags `false`, no event carries a `:spans` key.
  - `:options`: a raw provider passthrough for parameters ALLM does not
    model. An adapter merges it under the fields it sets itself.
  - `:metadata`: caller-owned. Use string keys when it will round-trip
    through JSON.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise
  `KeyError`, and nothing else is checked. `new(sample_rate: 0)` constructs,
  and `ALLM.Validate.transcription_stream_request/1` is what rejects it.
  """

  alias ALLM.Serializer

  @typedoc "How a streaming transcription session decides a segment has ended."
  @type commit_strategy :: :vad | :manual

  @type t :: %__MODULE__{
          model: String.t() | nil,
          language: String.t() | nil,
          sample_rate: pos_integer(),
          commit_strategy: commit_strategy(),
          timestamps: boolean(),
          logprobs: boolean(),
          options: map(),
          metadata: map()
        }

  @default_sample_rate 16_000
  @default_commit_strategy :vad

  defstruct [
    :model,
    :language,
    sample_rate: @default_sample_rate,
    commit_strategy: @default_commit_strategy,
    timestamps: false,
    logprobs: false,
    options: %{},
    metadata: %{}
  ]

  @commit_strategies [:vad, :manual]

  @doc """
  Build a `%TranscriptionStreamRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. Call
  `ALLM.Validate.transcription_stream_request/1` to check the field rules.

  ## Examples

      iex> cfg = ALLM.TranscriptionStreamRequest.new()
      iex> {cfg.sample_rate, cfg.commit_strategy, cfg.model}
      {16000, :vad, nil}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The closed list of `:commit_strategy` values.

  ## Examples

      iex> ALLM.TranscriptionStreamRequest.commit_strategies()
      [:vad, :manual]
  """
  @spec commit_strategies() :: [commit_strategy()]
  def commit_strategies, do: @commit_strategies

  # Explicit decode pairs for `sample_rate` and `commit_strategy` rather
  # than `data["k"] || default`, per the CLAUDE.md truthy-default rule.
  # Neither field has a legal falsy value, so the pair is equivalent to `||`
  # today; it stays correct if one is ever added. An absent (or `nil`) key
  # decodes to the default; any other value is kept.
  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      model: data["model"],
      language: data["language"],
      sample_rate: decode_sample_rate(data["sample_rate"]),
      commit_strategy: decode_commit_strategy(data["commit_strategy"]),
      timestamps: data["timestamps"] || false,
      logprobs: data["logprobs"] || false,
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  defp decode_sample_rate(nil), do: @default_sample_rate
  defp decode_sample_rate(rate), do: rate

  defp decode_commit_strategy(nil), do: @default_commit_strategy
  defp decode_commit_strategy(strategy), do: Serializer.to_atom_field(strategy)
end

defimpl Jason.Encoder, for: ALLM.TranscriptionStreamRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
