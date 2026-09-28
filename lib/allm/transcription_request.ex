defmodule ALLM.TranscriptionRequest do
  @moduledoc """
  A speech-to-text request. Layer A serializable data.

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("clip.mp3"), language: "en")
      iex> ALLM.Validate.transcription_request(req)
      :ok

  ## Fields

  - `:audio`: the clip to transcribe, an `t:ALLM.Audio.t/0`. `nil` is
    constructible, and `ALLM.Validate.transcription_request/1` is what
    rejects it. The validator checks the value's shape only. Whether a file
    exists, how large it is, and whether its type is accepted are checked by
    the adapter, because the limits differ per provider.
  - `:model`: `nil` means late-resolved (the engine's transcription model,
    then the adapter's default).
  - `:language`: an optional hint for the spoken language, as a string
    (for example `"en"`).
  - `:prompt`: optional context to guide the transcript, such as spellings
    of names or the previous sentence.
  - `:timestamps`: `true` asks for per-word start and end times on the
    response's `:spans` (see `ALLM.TranscriptSpan`). Defaults to `false`.
  - `:logprobs`: `true` asks for per-word or per-token log-probabilities
    on the response's `:spans`. Defaults to `false`.

    The two flags are separate because providers support them separately:
    some return both, some only log-probabilities. An adapter that cannot
    honour a flag that is `true` refuses the request with
    `:unsupported_feature` before sending anything. If the provider
    accepted the request but its response carries no span data, a blank
    transcript succeeds with `spans: []`, and any other transcript fails
    with `:unsupported_feature` whose `metadata.cause` is
    `:absent_from_response` and whose `metadata.text` holds the
    transcript. With both flags `false`, the response's `:spans` is `nil`.
  - `:options`: a raw provider-body passthrough for fields ALLM does not
    model. An adapter merges it *under* the fields it sets itself, so an
    option can never override a structural field, and fields that would
    change the response shape are dropped.
  - `:metadata`: caller-owned. Use string keys when it will round-trip
    through JSON.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise
  `KeyError`, and nothing else is checked.
  """

  alias ALLM.Serializer

  @type t :: %__MODULE__{
          audio: ALLM.Audio.t() | nil,
          model: String.t() | nil,
          language: String.t() | nil,
          prompt: String.t() | nil,
          timestamps: boolean(),
          logprobs: boolean(),
          options: map(),
          metadata: map()
        }

  defstruct [
    :audio,
    :model,
    :language,
    :prompt,
    timestamps: false,
    logprobs: false,
    options: %{},
    metadata: %{}
  ]

  @doc """
  Build a `%TranscriptionRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. Call
  `ALLM.Validate.transcription_request/1` to check the field rules.

  ## Examples

      iex> req = ALLM.TranscriptionRequest.new()
      iex> {req.audio, req.model, req.options}
      {nil, nil, %{}}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      audio: Serializer.hydrate(data["audio"]),
      model: data["model"],
      language: data["language"],
      prompt: data["prompt"],
      timestamps: data["timestamps"] || false,
      logprobs: data["logprobs"] || false,
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.TranscriptionRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
