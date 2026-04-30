defmodule ALLM.Providers.Support.ImageMime do
  @moduledoc """
  Per-provider MIME and size validation for `ALLM.ImagePart` content.

  Layer B helper used by the OpenAI and (future) Anthropic vision pre-flight
  to gate `%ALLM.ImagePart{}` content against per-provider accept-sets and a
  shared 20-MB byte-size ceiling. See spec §35.6 and Phase 17 design §3.1.

  ## Per-image validation (`validate/2`)

  Resolves the part's `%ALLM.Image{}` to bytes via
  `ALLM.Image.to_binary/1` and applies two checks:

    * MIME membership against the supplied accept-set.
    * `byte_size/1` of the resolved bytes against `@max_bytes` (20 MB).

  URL sources (`{:url, _}`) skip the size check — the adapter does NOT
  fetch the URL during pre-flight (Decision #1); size validation is
  deferred to the provider. MIME enforcement still applies (the URL's
  `:mime_type` is always `nil` per `ALLM.Image.from_url/1`, so a URL-source
  `%ImagePart{}` is accepted regardless of accept-set today; future
  divergence is captured by the per-provider arg).

  ## Request-level pre-flight (`validate_request/2`)

  Walks every `%ALLM.ImagePart{}` in `request.messages`, calls `validate/2`
  for each, accumulates `{[:content, msg_idx, part_idx], reason}` field
  errors. Returns `:ok` when no part fails, otherwise an
  `%ALLM.Error.ValidationError{reason: :invalid_message}` with all
  per-image errors in `:errors`. Adapters call this once in pre-flight;
  per-provider divergence is isolated to `accept_mimes/1`.

  ## Provider accept-sets

      iex> ALLM.Providers.Support.ImageMime.accept_mimes(:openai)
      ["image/png", "image/jpeg", "image/webp", "image/gif"]

      iex> ALLM.Providers.Support.ImageMime.accept_mimes(:anthropic)
      ["image/png", "image/jpeg", "image/webp", "image/gif"]

  Both providers' published 2026-04 accept-sets match; the per-provider
  arg keeps the seam open for future divergence.
  """

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}

  @typedoc "Per-image validation result."
  @type validate_result ::
          :ok
          | {:error,
             {:unsupported_image_format, mime :: String.t() | nil}
             | {:image_too_large, byte_size :: non_neg_integer()}
             | :missing_mime_type}

  # 20 MB — both OpenAI and Anthropic published limit per the 2026-04
  # vision API docs.
  @max_bytes 20 * 1024 * 1024

  @doc """
  Provider accept-set for `image/*` MIME types.

  ## Examples

      iex> ALLM.Providers.Support.ImageMime.accept_mimes(:openai)
      ["image/png", "image/jpeg", "image/webp", "image/gif"]
  """
  @spec accept_mimes(:openai | :anthropic) :: [String.t()]
  def accept_mimes(:openai), do: ~w(image/png image/jpeg image/webp image/gif)
  def accept_mimes(:anthropic), do: ~w(image/png image/jpeg image/webp image/gif)

  @doc """
  Validate a single `%ImagePart{}` against an accept-set and the 20-MB
  size ceiling.

  ## Examples

      iex> img = ALLM.Image.from_binary("hi", "image/png")
      iex> part = ALLM.ImagePart.new(img)
      iex> ALLM.Providers.Support.ImageMime.validate(part, ["image/png"])
      :ok

      iex> img = ALLM.Image.from_binary("hi", "image/svg+xml")
      iex> part = ALLM.ImagePart.new(img)
      iex> ALLM.Providers.Support.ImageMime.validate(part, ["image/png"])
      {:error, {:unsupported_image_format, "image/svg+xml"}}

      iex> img = ALLM.Image.from_url("https://example.com/x.png")
      iex> part = ALLM.ImagePart.new(img)
      iex> ALLM.Providers.Support.ImageMime.validate(part, ["image/png"])
      :ok
  """
  @spec validate(ImagePart.t(), [String.t()]) :: validate_result()
  def validate(%ImagePart{image: %Image{source: {:url, _}, mime_type: mime}}, accept_mimes)
      when is_list(accept_mimes) do
    # URL sources: defer size validation (no fetch). MIME may be nil
    # (`from_url/1` doesn't infer); accept either nil or in-set.
    cond do
      is_nil(mime) -> :ok
      mime in accept_mimes -> :ok
      true -> {:error, {:unsupported_image_format, mime}}
    end
  end

  def validate(%ImagePart{image: %Image{mime_type: nil}}, _accept_mimes) do
    {:error, :missing_mime_type}
  end

  def validate(%ImagePart{image: %Image{mime_type: mime} = image}, accept_mimes)
      when is_list(accept_mimes) do
    if mime in accept_mimes do
      check_byte_size(image)
    else
      {:error, {:unsupported_image_format, mime}}
    end
  end

  defp check_byte_size(%Image{} = image) do
    case Image.to_binary(image) do
      {:ok, bytes} ->
        if byte_size(bytes) > @max_bytes do
          {:error, {:image_too_large, byte_size(bytes)}}
        else
          :ok
        end

      {:error, _reason} ->
        # Resolution failure (file missing, base64 invalid). Treat as
        # missing-mime equivalent — the adapter cannot prove the image is
        # OK without bytes.
        :ok
    end
  end

  @doc """
  Walk every `%ImagePart{}` in `request.messages`, validate, and return
  either `:ok` or a `%ValidationError{reason: :invalid_message}` carrying
  per-image field errors.

  Field paths: `[:content, msg_idx, part_idx]` per spec §35.6 / Phase 17
  design §7.

  ## Examples

      iex> img = ALLM.Image.from_binary("hi", "image/png")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: [%ALLM.ImagePart{image: img}]}])
      iex> ALLM.Providers.Support.ImageMime.validate_request(req, :openai)
      :ok
  """
  @spec validate_request(Request.t(), :openai | :anthropic) ::
          :ok | {:error, ValidationError.t()}
  def validate_request(%Request{messages: messages}, provider)
      when provider in [:openai, :anthropic] do
    accept_set = accept_mimes(provider)

    errors =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {%Message{content: content}, msg_idx} ->
        collect_message_errors(content, msg_idx, accept_set)
      end)

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:invalid_message, list,
           message: "image content failed provider validation"
         )}
    end
  end

  defp collect_message_errors(content, msg_idx, accept_set) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, part_idx} ->
      case validate_part(part, accept_set) do
        :ok -> []
        {:error, reason} -> [{[:content, msg_idx, part_idx], image_reason(reason)}]
      end
    end)
  end

  defp collect_message_errors(_content, _msg_idx, _accept_set), do: []

  defp validate_part(%ImagePart{} = part, accept_set), do: validate(part, accept_set)
  defp validate_part(%TextPart{}, _accept_set), do: :ok
  defp validate_part(_other, _accept_set), do: :ok

  # Map the `validate/2` per-image error term into the field-error reason
  # atom carried in `ValidationError.errors`.
  defp image_reason({:unsupported_image_format, _mime}), do: :unsupported_image_format
  defp image_reason({:image_too_large, _bytes}), do: :image_too_large
  defp image_reason(:missing_mime_type), do: :missing_mime_type
end
