defmodule ALLM.Serializer do
  @moduledoc """
  Tagged JSON encoding and decoding for Layer A structs.

  Every Layer A struct (`ALLM.Message`, `ALLM.Request`, `ALLM.ChatResult`, and
  so on — including the five `ALLM.Error.*` structs) is encoded as a tagged
  wrapper of the shape:

      %{"__type__" => "ALLM.Message", "data" => %{...every field...}}

  so the decoder can re-hydrate nested values without the caller knowing
  their types at decode time. `ChatResult` containing a `Thread` containing
  `Message`s decodes cleanly by recursing on the `"__type__"` tag. See the
  Phase 1 design, Non-obvious decision #3 "Tagged JSON encoding", and
  sub-phase 1.5 "Field-Error Vocabulary" for the atom set returned on decode
  failure.

  ## Encoding

  `encode_tagged/2` is called by each struct's `defimpl Jason.Encoder` and
  emits the tagged wrapper. All struct fields are serialized — including
  `nil` values — so the decoder sees the complete shape. Do not reach for
  `@derive {Jason.Encoder, only: [...]}`: it silently drops nil fields and
  breaks round-trip equality.

  Convenience wrappers `to_json!/1` and `to_iodata!/1` call `Jason.encode!/1`
  and `Jason.encode_to_iodata!/1` respectively. Encoding raises
  `Jason.EncodeError` on unencodable values (e.g. a PID or an anonymous
  function in a `metadata` map); this is by design — see Phase 1 design §1.5.

  ## Decoding

  `from_json/2` decodes the JSON with `Jason.decode/1` then dispatches on
  the `"__type__"` string. For each Layer A struct module, the decoder
  invokes that module's private-ish `__from_tagged__/1` hydrator which
  rebuilds the struct with atom keys, restoring atom-typed fields via
  `String.to_existing_atom/1`. Nested tagged maps are recursed through
  `hydrate/1`.

  Pass `as: Module` to decode an untagged JSON object as a specific Layer A
  struct — the escape hatch for third-party JSON.

  ## Examples

      iex> msg = ALLM.Message.new(role: :user, content: "hi")
      iex> json = ALLM.Serializer.to_json!(msg)
      iex> {:ok, decoded} = ALLM.Serializer.from_json(json)
      iex> decoded == msg
      true

      iex> json = Jason.encode!(%{"role" => "user", "content" => "hi", "name" => nil, "tool_call_id" => nil, "metadata" => %{}})
      iex> {:ok, %ALLM.Message{role: :user}} = ALLM.Serializer.from_json(json, as: ALLM.Message)
      iex> :ok
      :ok
  """

  alias ALLM.Error.ValidationError

  # ---------------------------------------------------------------------------
  # Known Layer A struct registry. Used both for decode dispatch (__type__
  # string -> module) and for the `:as` hint validation (:unknown_type_tag).
  # ---------------------------------------------------------------------------

  @known_modules [
    ALLM.Message,
    ALLM.Tool,
    ALLM.ToolCall,
    ALLM.Request,
    ALLM.Response,
    ALLM.Thread,
    ALLM.Session,
    ALLM.StepResult,
    ALLM.ChatResult,
    ALLM.Usage,
    ALLM.Engine,
    ALLM.ModelRef,
    ALLM.Error.EngineError,
    ALLM.Error.AdapterError,
    ALLM.Error.StreamError,
    ALLM.Error.ValidationError,
    ALLM.Error.ToolError,
    ALLM.Error.SessionError,
    ALLM.Image,
    ALLM.ImageRequest,
    ALLM.ImageResponse,
    ALLM.ImageUsage
  ]

  @type_tag_index Map.new(@known_modules, fn mod -> {inspect(mod), mod} end)

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  @doc """
  Encode a Layer A struct to a JSON string via Jason.

  Raises `Jason.EncodeError` if any field value is not JSON-serializable (e.g.
  a PID in `:metadata`). See module docs for rationale.

  ## Examples

      iex> msg = ALLM.Message.new(role: :user, content: "hi")
      iex> json = ALLM.Serializer.to_json!(msg)
      iex> decoded = Jason.decode!(json)
      iex> decoded["__type__"]
      "ALLM.Message"
  """
  @spec to_json!(struct()) :: String.t()
  def to_json!(value) when is_struct(value), do: Jason.encode!(value)

  @doc """
  Encode a Layer A struct to iodata via `Jason.encode_to_iodata!/1`.
  """
  @spec to_iodata!(struct()) :: iodata()
  def to_iodata!(value) when is_struct(value), do: Jason.encode_to_iodata!(value)

  @doc """
  Called by each Layer A struct's `defimpl Jason.Encoder` — emits the tagged
  wrapper `%{"__type__" => inspect(module), "data" => Map.from_struct(value)}`
  and forwards to `Jason.Encode.map/2`.

  Every field is emitted, including `nil` values.
  """
  @spec encode_tagged(struct(), Jason.Encode.opts()) :: iodata()
  def encode_tagged(%module{} = value, opts) do
    tagged = %{
      "__type__" => inspect(module),
      "data" => Map.from_struct(value)
    }

    Jason.Encode.map(tagged, opts)
  end

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  @doc """
  Decode a tagged JSON string back to a Layer A struct.

  Returns `{:ok, struct}` on success. On failure returns
  `{:error, %ALLM.Error.ValidationError{reason: :invalid_request, errors: [...]}}`
  with field-error tuples drawn from the Field-Error Vocabulary in the
  Phase 1 design (§1.5).

  ## Options

    * `:as` — module atom. Required when the top-level JSON is an untagged
      object (no `"__type__"` key). Ignored when the JSON is already tagged.

  ## Examples

      iex> msg = ALLM.Message.new(role: :user, content: "hi")
      iex> json = ALLM.Serializer.to_json!(msg)
      iex> {:ok, ^msg} = ALLM.Serializer.from_json(json)
      iex> :ok
      :ok
  """
  @spec from_json(String.t(), keyword()) ::
          {:ok, struct() | map()} | {:error, ValidationError.t()}
  def from_json(json, opts \\ []) when is_binary(json) and is_list(opts) do
    with {:ok, decoded} <- decode_json(json) do
      hint = Keyword.get(opts, :as)
      dispatch(decoded, hint)
    end
  end

  # Public-but-internal: used by each struct's `__from_tagged__/1` to hydrate
  # a nested field value. Recurses on tagged maps, leaves plain values alone.
  # Returns the hydrated term (struct or original value). If the value is a
  # tagged map with an unknown type, it's returned as-is (forward-compat).
  @doc false
  @spec hydrate(term()) :: term()
  def hydrate(%{"__type__" => tag, "data" => data}) when is_binary(tag) and is_map(data) do
    case Map.fetch(@type_tag_index, tag) do
      {:ok, module} -> module.__from_tagged__(data)
      :error -> %{"__type__" => tag, "data" => data}
    end
  end

  def hydrate(list) when is_list(list), do: Enum.map(list, &hydrate/1)
  def hydrate(other), do: other

  # Atom-field restoration helper — restores a string to a pre-existing atom.
  # nil and non-binary values pass through unchanged. Raises (caught by the
  # decoder) on an atom that isn't loaded into the BEAM.
  @doc false
  @spec to_atom_field(term()) :: term()
  def to_atom_field(nil), do: nil
  def to_atom_field(value) when is_binary(value), do: String.to_existing_atom(value)
  def to_atom_field(other), do: other

  # ---------------------------------------------------------------------------
  # Private — JSON decode + dispatch
  # ---------------------------------------------------------------------------

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, validation_error([{:json, :malformed}])}
    end
  end

  # Tagged top-level — dispatch on __type__ even if :as is given.
  defp dispatch(%{"__type__" => tag} = tagged, _hint) when is_binary(tag) do
    case Map.fetch(tagged, "data") do
      {:ok, data} when is_map(data) ->
        case Map.fetch(@type_tag_index, tag) do
          {:ok, module} -> hydrate_with(module, data)
          :error -> {:ok, tagged}
        end

      {:ok, _} ->
        {:error, validation_error([{:data, :malformed_struct}])}

      :error ->
        {:error, validation_error([{:data, :missing}])}
    end
  end

  # Untagged top-level — require an :as hint.
  defp dispatch(decoded, nil) when is_map(decoded) do
    {:error, validation_error([{:format, :missing_type_tag}])}
  end

  defp dispatch(decoded, module) when is_map(decoded) and is_atom(module) do
    if module in @known_modules do
      hydrate_with(module, decoded)
    else
      {:error, validation_error([{:format, :unknown_type_tag}])}
    end
  end

  # Top-level non-object (list, number, etc.) with no hint is a missing tag.
  defp dispatch(_other, nil) do
    {:error, validation_error([{:format, :missing_type_tag}])}
  end

  # Invoke a module's `__from_tagged__/1`, catching atom-decode failures.
  # Closed-enum decode failures bubble out as `ArgumentError` (from
  # `String.to_existing_atom/1`) and collapse to `:atom_decode_failed`. A
  # decoder that needs to surface a precise field-error (e.g.
  # `ALLM.Image.__from_tagged__/1`'s `[:source, :invalid_base64]`) raises a
  # pre-built `ValidationError` directly; the rescue forwards it verbatim.
  defp hydrate_with(module, data) do
    {:ok, module.__from_tagged__(data)}
  rescue
    # ValidationError raises forwarded verbatim — required for
    # `ALLM.Image.__from_tagged__/1`'s `[{[:source], :invalid_base64}]`
    # field-error path (Phase 13.1, design Decision §Error Contract row).
    # ArgumentError stays coerced to `:atom_decode_failed`. Do NOT collapse
    # this clause back into the ArgumentError rescue — reverting it silently
    # breaks the field-error invariant for image-source decode failures.
    err in ValidationError ->
      {:error, err}

    ArgumentError ->
      {:error, validation_error([{:_unknown, :atom_decode_failed}])}
  end

  defp validation_error(errors) do
    ValidationError.new(:invalid_request, errors,
      message: "invalid JSON for ALLM.Serializer.from_json/2"
    )
  end
end
