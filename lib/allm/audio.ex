defmodule ALLM.Audio do
  @moduledoc """
  A serializable audio value, used as transcription input and as speech
  synthesis output. Layer A serializable data.

  One value type serves both directions. `ALLM.TranscriptionRequest` carries
  an `%Audio{}` in `:audio`, and `ALLM.SpeechResponse` returns the synthesized
  bytes as `%Audio{source: {:binary, bytes}}`.

      iex> audio = ALLM.Audio.from_binary(<<1, 2, 3>>, "audio/wav")
      iex> ALLM.Audio.size(audio)
      {:ok, 3}

  ## Source variants

  - `{:binary, bytes}`: raw audio bytes plus an explicit `:mime_type`, via
    `from_binary/2`.
  - `{:base64, encoded}`: standard base64-encoded bytes plus an explicit
    `:mime_type`, via `from_base64/2`. The string is stored as given and is
    not checked until `to_binary/1` or `size/1` decodes it.
  - `{:file, path}`: a local filesystem path, via `from_file/1`. Building
    one does no I/O. The file is read only by `to_binary/1`, and `size/1`
    only stats it.

  There is no URL variant: no bundled provider accepts a URL for audio input.

  ## MIME types

  `from_file/1` infers `:mime_type` from the lowercased extension:
  `.mp3`, `.mpeg`, `.mpga` → `audio/mpeg`; `.mp4`, `.m4a` → `audio/mp4`;
  `.wav` → `audio/wav`; `.webm` → `audio/webm`; `.ogg`, `.oga` →
  `audio/ogg`; `.flac` → `audio/flac`; `.aac` → `audio/aac`; `.opus` →
  `audio/opus`; `.aiff` → `audio/aiff`. Any other extension leaves it `nil`,
  and the adapter decides what to do with an unknown type.

  ## Construction

  Build values with the `from_*` functions. There is no `new/1`. `:source` is
  enforced, so `struct!(ALLM.Audio, [])` raises `ArgumentError`.

  ## Inspection

  `inspect/1` prints a payload as its size, never its bytes, so a
  multi-megabyte clip in an error message, a test failure diff, a log line
  or a telemetry handler costs one short line:

      iex> inspect(ALLM.Audio.from_binary(<<0, 0, 0, 0>>, "audio/wav"))
      ~s(#ALLM.Audio<source: {:binary, <<4 bytes>>}, mime_type: "audio/wav", metadata: %{}>)

  ## Serializability

  ETF round-trip preserves every source variant verbatim. JSON round-trip
  through `ALLM.Serializer` writes `:source` as
  `%{"type" => "<kind>", "value" => <value>}`, and the `{:binary, _}` variant
  base64-encodes its bytes so that non-UTF-8 audio survives as JSON text.
  A `"binary"` source whose value is not valid base64 decodes to the field
  error `{[:source], :invalid_base64}`. An unknown source type decodes to
  `{:_unknown, :atom_decode_failed}`.

  `:metadata` is caller-owned. Use string keys when it will round-trip
  through JSON: atom keys come back as strings.
  """

  alias ALLM.Error.ValidationError

  @type source :: {:binary, binary()} | {:base64, String.t()} | {:file, Path.t()}

  @type t :: %__MODULE__{
          source: source(),
          mime_type: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:source]
  defstruct [:source, :mime_type, metadata: %{}]

  @ext_to_mime %{
    ".mp3" => "audio/mpeg",
    ".mp4" => "audio/mp4",
    ".m4a" => "audio/mp4",
    ".mpeg" => "audio/mpeg",
    ".mpga" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm",
    ".ogg" => "audio/ogg",
    ".oga" => "audio/ogg",
    ".flac" => "audio/flac",
    ".aac" => "audio/aac",
    ".opus" => "audio/opus",
    ".aiff" => "audio/aiff"
  }

  @doc """
  Build an `%Audio{}` from a local filesystem path.

  Does no I/O: the path is stored as given, so a path that does not exist
  yet builds fine. `:mime_type` is inferred from the lowercased extension,
  or `nil` when the extension is missing or not in the table.

  ## Examples

      iex> audio = ALLM.Audio.from_file("/tmp/clip.MP3")
      iex> audio.source
      {:file, "/tmp/clip.MP3"}
      iex> audio.mime_type
      "audio/mpeg"

      iex> ALLM.Audio.from_file("/tmp/clip.xyz").mime_type
      nil
  """
  @spec from_file(Path.t()) :: t()
  def from_file(path) when is_binary(path) do
    mime = Map.get(@ext_to_mime, path |> Path.extname() |> String.downcase())
    %__MODULE__{source: {:file, path}, mime_type: mime}
  end

  @doc """
  Build an `%Audio{}` from raw bytes plus an explicit MIME type.

  ## Examples

      iex> audio = ALLM.Audio.from_binary(<<0, 255>>, "audio/wav")
      iex> audio.source
      {:binary, <<0, 255>>}
      iex> audio.mime_type
      "audio/wav"
  """
  @spec from_binary(binary(), String.t()) :: t()
  def from_binary(bytes, mime_type) when is_binary(bytes) and is_binary(mime_type) do
    %__MODULE__{source: {:binary, bytes}, mime_type: mime_type}
  end

  @doc """
  Build an `%Audio{}` from a base64-encoded string plus an explicit MIME type.

  The string is not decoded here. Invalid base64 surfaces later, as
  `{:error, :invalid_base64}` from `to_binary/1` or `size/1`.

  ## Examples

      iex> audio = ALLM.Audio.from_base64("aGk=", "audio/mpeg")
      iex> audio.source
      {:base64, "aGk="}
  """
  @spec from_base64(String.t(), String.t()) :: t()
  def from_base64(encoded, mime_type) when is_binary(encoded) and is_binary(mime_type) do
    %__MODULE__{source: {:base64, encoded}, mime_type: mime_type}
  end

  @doc """
  Resolve the audio's `:source` to raw bytes.

  - `{:binary, b}` returns `{:ok, b}`.
  - `{:base64, s}` decodes, or returns `{:error, :invalid_base64}`.
  - `{:file, path}` reads the file, returning `File.read/1`'s error on
    failure (`{:error, :enoent}` for a missing file).
  - Any other `:source` shape (only reachable by building the struct by
    hand) returns `{:error, :invalid_source}`.

  ## Examples

      iex> ALLM.Audio.to_binary(ALLM.Audio.from_base64("aGk=", "audio/wav"))
      {:ok, "hi"}

      iex> ALLM.Audio.to_binary(ALLM.Audio.from_file("/definitely/not/here.mp3"))
      {:error, :enoent}
  """
  @spec to_binary(t()) ::
          {:ok, binary()} | {:error, :invalid_base64 | :invalid_source | File.posix()}
  def to_binary(%__MODULE__{source: {:binary, b}}) when is_binary(b), do: {:ok, b}
  def to_binary(%__MODULE__{source: {:base64, s}}) when is_binary(s), do: decode64(s)
  def to_binary(%__MODULE__{source: {:file, path}}) when is_binary(path), do: File.read(path)
  def to_binary(%__MODULE__{}), do: {:error, :invalid_source}

  @doc """
  The audio payload's size in bytes, without reading a file.

  - `{:binary, b}` measures the bytes.
  - `{:base64, s}` decodes and measures, or returns
    `{:error, :invalid_base64}`.
  - `{:file, path}` stats the file and never reads it; a missing file
    returns `{:error, :enoent}`, and a directory returns
    `{:error, :eisdir}`, the same error `to_binary/1` gives for it.
  - Any other `:source` shape returns `{:error, :invalid_source}`.

  ## Examples

      iex> ALLM.Audio.size(ALLM.Audio.from_binary(<<1, 2, 3>>, "audio/wav"))
      {:ok, 3}

      iex> ALLM.Audio.size(ALLM.Audio.from_base64("%%%", "audio/wav"))
      {:error, :invalid_base64}
  """
  @spec size(t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_base64 | :invalid_source | File.posix()}
  def size(%__MODULE__{source: {:binary, b}}) when is_binary(b), do: {:ok, byte_size(b)}

  def size(%__MODULE__{source: {:base64, s}}) when is_binary(s) do
    with {:ok, b} <- decode64(s), do: {:ok, byte_size(b)}
  end

  def size(%__MODULE__{source: {:file, path}}) when is_binary(path) do
    case File.stat(path) do
      # A directory's stat size is its inode size, not audio bytes; refuse
      # it here so a size gate cannot accept what `to_binary/1` rejects.
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, _} = error -> error
    end
  end

  def size(%__MODULE__{}), do: {:error, :invalid_source}

  defp decode64(s) do
    case Base.decode64(s) do
      {:ok, b} -> {:ok, b}
      :error -> {:error, :invalid_base64}
    end
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      source: decode_source(data["source"]),
      mime_type: data["mime_type"],
      metadata: data["metadata"] || %{}
    }
  end

  defp decode_source(%{"type" => "binary", "value" => v}) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, b} ->
        {:binary, b}

      :error ->
        # A pre-built ValidationError survives Serializer's ArgumentError
        # rescue with its field path intact; an ArgumentError would collapse
        # to `:atom_decode_failed`.
        raise ValidationError.new(:invalid_request, [{[:source], :invalid_base64}],
                message: "invalid base64 in ALLM.Audio source"
              )
    end
  end

  defp decode_source(%{"type" => "base64", "value" => v}) when is_binary(v), do: {:base64, v}
  defp decode_source(%{"type" => "file", "value" => v}) when is_binary(v), do: {:file, v}

  # Unknown type → ArgumentError → `{:_unknown, :atom_decode_failed}`.
  defp decode_source(other) do
    raise ArgumentError, "unknown ALLM.Audio source #{inspect(other)}"
  end
end

defimpl Jason.Encoder, for: ALLM.Audio do
  # Pre-pass `:source` from a tuple into a JSON-encodable map; the binary
  # variant base64-encodes so non-UTF-8 bytes survive as JSON text.
  def encode(%ALLM.Audio{source: source} = value, opts) do
    ALLM.Serializer.encode_tagged(%{value | source: source_to_map(source)}, opts)
  end

  defp source_to_map({:binary, b}), do: %{"type" => "binary", "value" => Base.encode64(b)}
  defp source_to_map({:base64, s}), do: %{"type" => "base64", "value" => s}
  defp source_to_map({:file, p}), do: %{"type" => "file", "value" => p}
end

defimpl Inspect, for: ALLM.Audio do
  import Inspect.Algebra

  # The payload renders as a size, never its bytes: audio is routinely
  # megabytes, and this struct reaches error messages, test diffs, logs and
  # telemetry handlers.
  def inspect(%ALLM.Audio{source: source, mime_type: mime, metadata: metadata}, opts) do
    concat([
      "#ALLM.Audio<source: ",
      source_doc(source, opts),
      ", mime_type: ",
      to_doc(mime, opts),
      ", metadata: ",
      to_doc(metadata, opts),
      ">"
    ])
  end

  defp source_doc({:binary, b}, _opts) when is_binary(b),
    do: "{:binary, <<#{byte_size(b)} bytes>>}"

  defp source_doc({:base64, s}, _opts) when is_binary(s),
    do: "{:base64, <<#{byte_size(s)} chars>>}"

  defp source_doc(other, opts), do: to_doc(other, opts)
end
