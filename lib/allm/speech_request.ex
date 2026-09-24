defmodule ALLM.SpeechRequest do
  @moduledoc """
  A text-to-speech request. Layer A serializable data.

      iex> req = ALLM.SpeechRequest.new(input: "Hello.", voice: "alloy", format: :mp3)
      iex> ALLM.Validate.speech_request(req)
      :ok

  ## Fields

  - `:input`: the text to speak. `""` is constructible, and
    `ALLM.Validate.speech_request/1` is what rejects it.
  - `:model`: `nil` means late-resolved (the engine's speech model, then
    the adapter's default).
  - `:voice`: a provider-shaped voice name, forwarded as given. ALLM keeps
    no voice catalogue, because valid names differ per provider and per
    model. `nil` lets the adapter choose.
  - `:format`: the audio file format to produce, one of `formats/0`, or
    `nil` for the provider's default. The atoms name file formats, not any
    one provider's parameter. A provider that cannot produce a format
    refuses the request, and the atoms are protocol-legal rather than a
    promise that every provider accepts every one. The response reports the
    format that actually arrived (`ALLM.SpeechResponse`'s `:format`).
  - `:instructions`: optional delivery guidance for models that accept it.
  - `:speed`: optional playback speed. Only "a number greater than zero"
    is checked here, and each provider enforces its own range.
  - `:options`: a raw provider-body passthrough for fields ALLM does not
    model. An adapter merges it *under* the fields it sets itself, so an
    option can never override `:input`, `:model` or any other structural
    field, and fields that would change the response shape are dropped.
  - `:metadata`: caller-owned. Use string keys when it will round-trip
    through JSON.

  There is no `:stream` field: speech synthesis is non-streaming.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise
  `KeyError`, and nothing else is checked.
  """

  alias ALLM.Serializer

  @typedoc "A synthesized audio file format."
  @type format :: :mp3 | :opus | :aac | :flac | :wav | :pcm

  @type t :: %__MODULE__{
          input: String.t(),
          model: String.t() | nil,
          voice: String.t() | nil,
          format: format() | nil,
          instructions: String.t() | nil,
          speed: number() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:model, :voice, :format, :instructions, :speed, input: "", options: %{}, metadata: %{}]

  @formats [:mp3, :opus, :aac, :flac, :wav, :pcm]

  @doc """
  Build a `%SpeechRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. Call
  `ALLM.Validate.speech_request/1` to check the field rules.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hi.")
      iex> {req.input, req.format, req.options}
      {"Hi.", nil, %{}}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The closed list of `:format` values, and the single source for the
  validator and every adapter's format mapping.

  ## Examples

      iex> ALLM.SpeechRequest.formats()
      [:mp3, :opus, :aac, :flac, :wav, :pcm]
  """
  @spec formats() :: [format()]
  def formats, do: @formats

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      input: data["input"] || "",
      model: data["model"],
      voice: data["voice"],
      format: Serializer.to_atom_field(data["format"]),
      instructions: data["instructions"],
      speed: data["speed"],
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.SpeechRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
