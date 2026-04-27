defmodule ALLM.Image do
  @moduledoc """
  A serializable image value used by image generation, editing, and vision
  inputs. See spec §35.2.1.

  Layer A — pure data. The `:source` is one of four tagged tuples and is the
  only required field. All other fields are nilable to support both inputs
  (vision: only `:source`/`:mime_type`) and outputs (generated:
  `:prompt`/`:revised_prompt`/`:width`/`:height` populated by the adapter).

  ## Source variants

  - `{:binary, bytes}` — raw image bytes; an explicit `:mime_type` MUST be
    supplied via `from_binary/2`.
  - `{:base64, encoded}` — standard base64-encoded bytes (with padding) plus
    explicit `:mime_type`. Constructed via `from_base64/2` — pure data, no
    decode validation. Callers passing URL-safe (`-`/`_`) or unpadded base64
    will round-trip cleanly through ETF / JSON but `to_data_uri/1`'s fast-path
    (which forwards the encoded string verbatim) may emit a `data:` URI a
    consumer rejects.
  - `{:url, url}` — public HTTP/HTTPS URL. `from_url/1` does NOT inspect or
    fetch the URL; `:mime_type` is `nil` and the adapter resolves it. URLs are
    NEVER fetched in Layer A — see `to_binary/1` and `to_data_uri/1` for the
    `:remote_source` error.
  - `{:file, path}` — local filesystem path. `from_file/1` does NOT call
    `File.read/1`; only the path is stored. MIME type is inferred from the
    extension (lowercase) and may be `nil` when the extension is missing or
    unknown. Filesystem I/O happens only in `to_binary/1`/`to_data_uri/1`.

  ## Serializability

  ETF round-trip via `:erlang.term_to_binary/1` preserves every legal source
  shape verbatim. JSON round-trip via `ALLM.Serializer` represents `:source`
  as `%{"type" => "<kind>", "value" => <value>}`; the `{:binary, _}` variant
  Base64-encodes its bytes on the wire so JSON stays text-safe. Decoding
  dispatches on `data["source"]["type"]` against the closed set
  `~w[binary base64 url file]`; an unknown type falls through to the
  `{:_unknown, :atom_decode_failed}` field-error path. A `"binary"` source
  whose `"value"` is not valid base64 surfaces as
  `{[:source], :invalid_base64}` (raised pre-emptively as a
  `ValidationError` so the field-error survives `Serializer.from_json/1`'s
  `ArgumentError` rescue).
  """

  alias ALLM.Error.ValidationError

  @type source ::
          {:binary, binary()}
          | {:base64, String.t()}
          | {:url, String.t()}
          | {:file, Path.t()}

  @type t :: %__MODULE__{
          source: source(),
          mime_type: String.t() | nil,
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          prompt: String.t() | nil,
          revised_prompt: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:source]
  defstruct [:source, :mime_type, :width, :height, :prompt, :revised_prompt, metadata: %{}]

  # Lowercase-extension → MIME-type table (Decision #5 — extension-only
  # detection; unknown/missing → nil, the adapter handles defaulting).
  @ext_to_mime %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc """
  Build an `%Image{}` from a local filesystem path.

  Pure data — does NOT call `File.read/1`. The path is stored verbatim and the
  filesystem is only touched at `to_binary/1` / `to_data_uri/1` time. The
  `:mime_type` is inferred from the lowercased extension against the closed
  set `[".png", ".jpg", ".jpeg", ".webp", ".gif"]`; unknown or missing
  extensions leave `:mime_type` as `nil`.

  ## Examples

      iex> img = ALLM.Image.from_file("/tmp/cat.png")
      iex> img.source
      {:file, "/tmp/cat.png"}
      iex> img.mime_type
      "image/png"

      iex> ALLM.Image.from_file("/tmp/noext").mime_type
      nil
  """
  @spec from_file(Path.t()) :: t()
  def from_file(path) when is_binary(path) do
    mime = Map.get(@ext_to_mime, path |> Path.extname() |> String.downcase())
    %__MODULE__{source: {:file, path}, mime_type: mime}
  end

  @doc """
  Build an `%Image{}` from raw bytes plus an explicit MIME type.

  Both arguments are required and must be binaries — `mime_type: nil` raises
  `FunctionClauseError` (the `is_binary(mime_type)` runtime guard backs the
  `@spec` so callers don't get silently-`nil`-mime structs).

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80>>, "image/png")
      iex> img.source
      {:binary, <<137, 80>>}
      iex> img.mime_type
      "image/png"
  """
  @spec from_binary(binary(), String.t()) :: t()
  def from_binary(bytes, mime_type) when is_binary(bytes) and is_binary(mime_type) do
    %__MODULE__{source: {:binary, bytes}, mime_type: mime_type}
  end

  @doc """
  Build an `%Image{}` from a URL string.

  Pure data — does NOT inspect or fetch the URL. The `:mime_type` is `nil`;
  the adapter that consumes the image resolves the type at request-build
  time. URL fetching is banned in Layer A (Decision #2 / phasing principle
  #8).

  ## Examples

      iex> img = ALLM.Image.from_url("https://example.com/x.png")
      iex> img.source
      {:url, "https://example.com/x.png"}
      iex> img.mime_type
      nil
  """
  @spec from_url(String.t()) :: t()
  def from_url(url) when is_binary(url) do
    %__MODULE__{source: {:url, url}, mime_type: nil}
  end

  @doc """
  Build an `%Image{}` from a base64-encoded string plus an explicit MIME type.

  Pure data — does NOT validate that `encoded` is well-formed base64. Standard
  base64 with padding is the documented contract; URL-safe base64 (`-`/`_`)
  or unpadded variants may produce a struct whose `to_data_uri/1` fast-path
  emits a `data:` URI a downstream consumer rejects. `mime_type: nil` raises
  `FunctionClauseError`.

  ## Examples

      iex> img = ALLM.Image.from_base64("aGk=", "image/png")
      iex> img.source
      {:base64, "aGk="}
      iex> img.mime_type
      "image/png"
  """
  @spec from_base64(String.t(), String.t()) :: t()
  def from_base64(encoded, mime_type) when is_binary(encoded) and is_binary(mime_type) do
    %__MODULE__{source: {:base64, encoded}, mime_type: mime_type}
  end

  @doc """
  Resolve the image's `:source` to raw bytes.

  - `{:binary, b}` returns `{:ok, b}` verbatim.
  - `{:base64, s}` decodes via `Base.decode64/1`; invalid base64 returns
    `{:error, :invalid_base64}`.
  - `{:url, _}` returns `{:error, :remote_source}` — Layer A NEVER fetches
    URLs (Decision #2). Adapters fetch at request-build time.
  - `{:file, path}` reads the file via `File.read/1` and returns its
    `{:ok, _} | {:error, posix()}` shape directly (`:enoent` on missing,
    etc.).

  ## Examples

      iex> ALLM.Image.to_binary(ALLM.Image.from_binary(<<1, 2>>, "image/png"))
      {:ok, <<1, 2>>}

      iex> ALLM.Image.to_binary(ALLM.Image.from_base64("aGVsbG8=", "image/png"))
      {:ok, "hello"}

      iex> ALLM.Image.to_binary(ALLM.Image.from_url("https://example.com/x.png"))
      {:error, :remote_source}
  """
  @spec to_binary(t()) ::
          {:ok, binary()}
          | {:error, :remote_source | :invalid_base64 | File.posix()}
  def to_binary(%__MODULE__{source: {:binary, b}}), do: {:ok, b}

  def to_binary(%__MODULE__{source: {:base64, s}}) do
    case Base.decode64(s) do
      {:ok, b} -> {:ok, b}
      :error -> {:error, :invalid_base64}
    end
  end

  def to_binary(%__MODULE__{source: {:url, _}}), do: {:error, :remote_source}
  def to_binary(%__MODULE__{source: {:file, path}}), do: File.read(path)

  @doc """
  Resolve the image to a `data:<mime>;base64,<...>` URI.

  - `{:binary, b}` with a `:mime_type` Base64-encodes the bytes.
  - `{:base64, s}` with a `:mime_type` forwards `s` verbatim — fast path,
    no decode-then-re-encode.
  - `{:file, path}` with a `:mime_type` reads + Base64-encodes.
  - `{:url, _}` returns `{:error, :remote_source}` (Decision #6) — a `data:`
    URI and an `https:` URI are different addressing schemes; passing the
    URL through verbatim would surprise.
  - Missing `:mime_type` returns `{:error, :missing_mime_type}` — there is
    no default like `application/octet-stream`.

  ## Examples

      iex> ALLM.Image.to_data_uri(ALLM.Image.from_binary("hi", "image/png"))
      {:ok, "data:image/png;base64,aGk="}

      iex> ALLM.Image.to_data_uri(ALLM.Image.from_base64("aGk=", "image/png"))
      {:ok, "data:image/png;base64,aGk="}

      iex> ALLM.Image.to_data_uri(ALLM.Image.from_url("https://example.com/x.png"))
      {:error, :remote_source}
  """
  @spec to_data_uri(t()) ::
          {:ok, String.t()}
          | {:error, :remote_source | :missing_mime_type | :invalid_base64 | File.posix()}
  # `{:url, _}` is unsupported regardless of mime_type — the addressing
  # scheme mismatch (Decision #6) is the user-visible error, not the missing
  # mime. Order matters: this clause must fire before the `mime_type: nil`
  # short-circuit so a URL-source image without a mime returns
  # `:remote_source`, not `:missing_mime_type`.
  def to_data_uri(%__MODULE__{source: {:url, _}}), do: {:error, :remote_source}
  def to_data_uri(%__MODULE__{mime_type: nil}), do: {:error, :missing_mime_type}

  def to_data_uri(%__MODULE__{source: {:binary, b}, mime_type: mime}) do
    {:ok, "data:" <> mime <> ";base64," <> Base.encode64(b)}
  end

  def to_data_uri(%__MODULE__{source: {:base64, s}, mime_type: mime}) do
    {:ok, "data:" <> mime <> ";base64," <> s}
  end

  def to_data_uri(%__MODULE__{source: {:file, path}, mime_type: mime}) do
    case File.read(path) do
      {:ok, b} -> {:ok, "data:" <> mime <> ";base64," <> Base.encode64(b)}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      source: decode_source(data["source"]),
      mime_type: data["mime_type"],
      width: data["width"],
      height: data["height"],
      prompt: data["prompt"],
      revised_prompt: data["revised_prompt"],
      metadata: data["metadata"] || %{}
    }
  end

  defp decode_source(%{"type" => "binary", "value" => v}) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, b} ->
        {:binary, b}

      :error ->
        # Pre-built ValidationError survives the `ArgumentError` rescue at
        # `lib/allm/serializer.ex:240`; raising ArgumentError here would
        # collapse to `:atom_decode_failed` and lose the field path.
        raise ValidationError.new(:invalid_request, [{[:source], :invalid_base64}],
                message: "invalid base64 in ALLM.Image source"
              )
    end
  end

  defp decode_source(%{"type" => "base64", "value" => v}) when is_binary(v), do: {:base64, v}
  defp decode_source(%{"type" => "url", "value" => v}) when is_binary(v), do: {:url, v}
  defp decode_source(%{"type" => "file", "value" => v}) when is_binary(v), do: {:file, v}

  # Unknown "type" value → ArgumentError → caught by Serializer.hydrate_with/2
  # rescue → surfaces as {:_unknown, :atom_decode_failed} (Decision #4).
  defp decode_source(%{"type" => other}) do
    raise ArgumentError, "unknown ALLM.Image source type #{inspect(other)}"
  end
end

defimpl Jason.Encoder, for: ALLM.Image do
  # Pre-pass-transform `:source` from a tuple into a map shape Jason can
  # encode (Decision #4). The `{:binary, b}` variant Base64-encodes its bytes
  # so the JSON wire form is text-safe; every other variant carries a string
  # verbatim. Mirrors the `lib/allm/engine.ex:508` pattern of transforming a
  # tuple-carrying field before delegating to `encode_tagged/2`.
  def encode(%ALLM.Image{source: source} = value, opts) do
    transformed = %{value | source: source_to_map(source)}
    ALLM.Serializer.encode_tagged(transformed, opts)
  end

  defp source_to_map({:binary, b}), do: %{"type" => "binary", "value" => Base.encode64(b)}
  defp source_to_map({:base64, s}), do: %{"type" => "base64", "value" => s}
  defp source_to_map({:url, u}), do: %{"type" => "url", "value" => u}
  defp source_to_map({:file, p}), do: %{"type" => "file", "value" => p}
end
