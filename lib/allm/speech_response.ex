defmodule ALLM.SpeechResponse do
  @moduledoc """
  A text-to-speech response. Layer A serializable data.

      iex> resp = ALLM.SpeechResponse.new(audio: ALLM.Audio.from_binary(<<1, 2>>, "audio/mpeg"), format: :mp3)
      iex> ALLM.Audio.size(resp.audio)
      {:ok, 2}

  ## Fields

  - `:audio`: the synthesized audio, as `%ALLM.Audio{source: {:binary, bytes}}`.
  - `:format`: the format that *arrived*, derived from the response's
    content type through `mime_to_format/1`. It is not an echo of the
    request's `:format`, and the two differ whenever the request left
    `:format` as `nil`. It is `nil` when the content type is not in the
    table.
  - `:id`, `:request_id`, `:model`, `:provider`: provider correlation.
  - `:usage`: an `t:ALLM.Usage.t/0`, never `nil`. A provider that reports
    no counters for speech leaves every field `nil`.
  - `:raw`: the provider's non-audio body, or `nil`. Audio bytes are never
    stored in `:raw`: they live once, in `:audio`, so a persisted response
    does not hold the audio twice. An adapter whose body carries encoded
    audio replaces it in `:raw` with a `"<N bytes>"` placeholder.
  - `:metadata`: caller-owned.

  ## Format tables

  `format_to_mime/1` and `mime_to_format/1` are the only MIME-to-format
  tables in the library. They are separate functions so that a provider's
  extra content type can extend the reverse table without changing the
  forward one.
  """

  alias ALLM.{Serializer, SpeechRequest, Usage}

  @type t :: %__MODULE__{
          audio: ALLM.Audio.t() | nil,
          format: SpeechRequest.format() | nil,
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          usage: Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :audio,
    :format,
    :id,
    :request_id,
    :model,
    :provider,
    :raw,
    usage: %Usage{},
    metadata: %{}
  ]

  @format_to_mime %{
    mp3: "audio/mpeg",
    opus: "audio/opus",
    aac: "audio/aac",
    flac: "audio/flac",
    wav: "audio/wav",
    pcm: "audio/pcm"
  }

  @mime_to_format Map.new(@format_to_mime, fn {format, mime} -> {mime, format} end)

  @doc """
  Build a `%SpeechResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.SpeechResponse.new(model: "tts-1")
      iex> resp.usage
      %ALLM.Usage{}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Map a response content type to a format atom.

  Media-type parameters after `;` are stripped and the type is compared
  case-insensitively. A content type not in the table, or `nil`, returns
  `nil`.

  ## Examples

      iex> ALLM.SpeechResponse.mime_to_format("audio/mpeg")
      :mp3

      iex> ALLM.SpeechResponse.mime_to_format("audio/wav; codecs=1")
      :wav

      iex> ALLM.SpeechResponse.mime_to_format("video/mp4")
      nil
  """
  @spec mime_to_format(String.t() | nil) :: SpeechRequest.format() | nil
  def mime_to_format(nil), do: nil

  def mime_to_format(mime) when is_binary(mime) do
    Map.get(@mime_to_format, ALLM.Audio.normalize_mime(mime))
  end

  @doc """
  Map a format atom to its content type.

  ## Examples

      iex> ALLM.SpeechResponse.format_to_mime(:mp3)
      "audio/mpeg"
  """
  @spec format_to_mime(SpeechRequest.format()) :: String.t()
  def format_to_mime(format) when is_map_key(@format_to_mime, format),
    do: Map.fetch!(@format_to_mime, format)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      audio: Serializer.hydrate(data["audio"]),
      format: Serializer.to_atom_field(data["format"]),
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

defimpl Jason.Encoder, for: ALLM.SpeechResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
