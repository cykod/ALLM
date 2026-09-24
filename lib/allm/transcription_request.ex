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
          options: map(),
          metadata: map()
        }

  defstruct [:audio, :model, :language, :prompt, options: %{}, metadata: %{}]

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
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.TranscriptionRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
