defmodule ALLM.Providers.Support.HTTPResponse do
  @moduledoc """
  Provider-neutral HTTP helpers shared by the bundled `Req`-based adapters.

  Layer B helper. Every function here was previously a private copy inside
  one or more provider adapters with the same behaviour in each copy; this
  module is the single home for those copies. The functions are
  `@doc false` seams: they carry a `@spec` and are callable from tests, but
  are not part of the public API.

  Credential redaction is per provider: a pattern inherited from a sibling
  provider redacts nothing. The patterns live once each in
  `ALLM.Providers.Support.Redact`, one function per provider. Helpers here
  that redact take that function (or an adapter's wrapper around it) as an
  argument, and any provider name in a message is rendered by the caller.

  ## Contents

    * Response headers: `header_value/2`, `retry_after_ms/1`.
    * Error bodies: `decode_error_body/1` (a map passes through, anything
      else is `%{}`), `decode_json_error_body/1` (additionally
      JSON-decodes a binary body, for providers that send JSON as
      `text/plain`), `error_object/1`, `body_error_message/2`,
      `redacted_error_message/3`, `redact_optional/2`, `sanitize_cause/1`.
    * Error metadata: `build_metadata/2`.
    * Request bodies: `stringify_keys/1`.
    * `Req` request options: `maybe_apply_req_test_stub/2`,
      `maybe_apply_request_timeout/2` (leaves the request unchanged without
      `opts[:request_timeout]`) and `apply_receive_timeout/3` (applies the
      caller's default instead).
  """

  @doc false
  # Case-insensitive lookup on a list of header tuples; exact-key lookup on
  # `Req`'s lower-cased header map. A multi-valued header yields its first
  # value. Anything other than a map or a list has no headers (hence
  # `term()`: other shapes are accepted and yield `nil`, not rejected).
  @spec header_value(term(), String.t()) :: String.t() | nil
  def header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      nil -> nil
      value -> header_value_to_string(value)
    end
  end

  def header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: header_value_to_string(v), else: nil

      _ ->
        nil
    end)
  end

  def header_value(_headers, _name), do: nil

  @doc false
  # `Retry-After` in delta-seconds, as milliseconds. The HTTP-date form, a
  # negative number and any other unparseable value all return `nil`, and
  # the caller's retry loop falls back to its computed backoff.
  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(value)
    end
  end

  @doc false
  # A decoded (map) body passes through; anything else becomes `%{}`.
  @spec decode_error_body(term()) :: map()
  def decode_error_body(body) when is_map(body), do: body
  def decode_error_body(_body), do: %{}

  @doc false
  # As `decode_error_body/1`, but a binary body is JSON-decoded first:
  # OpenAI's audio 401 is JSON sent as `text/plain`, which `Req` leaves
  # undecoded. A binary that is not a JSON object becomes `%{}`.
  @spec decode_json_error_body(term()) :: map()
  def decode_json_error_body(body) when is_map(body), do: body

  def decode_json_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  def decode_json_error_body(_body), do: %{}

  @doc false
  # The body's `"error"` object. A bare string `"error"` becomes
  # `%{"message" => string}`; any other shape becomes `%{}`.
  @spec error_object(map()) :: map()
  def error_object(body) do
    case Map.get(body, "error") do
      e when is_map(e) -> e
      e when is_binary(e) -> %{"message" => e}
      _ -> %{}
    end
  end

  @doc false
  # `body["error"]["message"]` off a decoded error body, whatever its type,
  # else `fallback`. Not redacted: the caller pipes the result through its
  # own redactor, which also handles a non-binary message.
  @spec body_error_message(term(), term()) :: term()
  def body_error_message(body, fallback) do
    case body do
      %{"error" => %{"message" => message}} -> message
      _ -> fallback
    end
  end

  @doc false
  # The error object's `"message"`, passed through `redactor` when it is a
  # binary; otherwise `fallback` (the caller's provider-named message, such
  # as `"OpenAI HTTP 500"`), which is not redacted.
  @spec redacted_error_message(map(), String.t(), (String.t() -> String.t())) :: String.t()
  def redacted_error_message(error, fallback, redactor) do
    case Map.get(error, "message") do
      m when is_binary(m) -> redactor.(m)
      _ -> fallback
    end
  end

  @doc false
  # A binary goes through `redactor`; anything else becomes `nil`. For
  # optional provider-authored metadata fields (`code`, `type`, `status`).
  @spec redact_optional(term(), (String.t() -> String.t())) :: String.t() | nil
  def redact_optional(value, redactor) when is_binary(value), do: redactor.(value)
  def redact_optional(_value, _redactor), do: nil

  @doc false
  # `Jason.DecodeError` carries the undecodable payload on `:data`. Every
  # offset is reset with it, because blanking only `:data` leaves
  # `message/1` raising on the stale position. Any other cause passes
  # through unchanged.
  @spec sanitize_cause(term()) :: term()
  def sanitize_cause(%{__struct__: Jason.DecodeError} = cause),
    do: %{cause | data: "", position: 0, token: nil}

  def sanitize_cause(cause), do: cause

  @doc false
  # Adds `opts[:request_id]` to an error's metadata map when it is set.
  @spec build_metadata(map(), keyword()) :: map()
  def build_metadata(metadata, opts) when is_map(metadata) do
    case Keyword.get(opts, :request_id) do
      nil -> metadata
      request_id -> Map.put(metadata, :request_id, request_id)
    end
  end

  @doc false
  # Atom keys become strings and other keys pass through unchanged, so a
  # request body never mixes atom and string keys. Anything that is not a
  # map becomes `%{}`.
  @spec stringify_keys(term()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def stringify_keys(_other), do: %{}

  @doc false
  # Routes the request through `opts[:adapter_opts][:plug]` (a `Req.Test`
  # stub) when one is given.
  @spec maybe_apply_req_test_stub(Req.Request.t(), keyword()) :: Req.Request.t()
  def maybe_apply_req_test_stub(req, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  @doc false
  # A positive integer `opts[:request_timeout]` becomes `Req`'s
  # `:receive_timeout`; without one the request is unchanged. Any other
  # value raises `CaseClauseError`, as every copy of this helper did.
  @spec maybe_apply_request_timeout(Req.Request.t(), keyword()) :: Req.Request.t()
  def maybe_apply_request_timeout(req, opts) do
    case Keyword.get(opts, :request_timeout) do
      nil -> req
      ms when is_integer(ms) and ms > 0 -> Req.merge(req, receive_timeout: ms)
    end
  end

  @doc false
  # A positive integer `opts[:request_timeout]` becomes `Req`'s
  # `:receive_timeout`; anything else applies `default_ms`, the calling
  # adapter's documented default.
  @spec apply_receive_timeout(Req.Request.t(), keyword(), pos_integer()) :: Req.Request.t()
  def apply_receive_timeout(req, opts, default_ms) do
    case Keyword.get(opts, :request_timeout) do
      ms when is_integer(ms) and ms > 0 -> Req.merge(req, receive_timeout: ms)
      _ -> Req.merge(req, receive_timeout: default_ms)
    end
  end

  defp header_value_to_string([v | _]) when is_binary(v), do: v
  defp header_value_to_string(v) when is_binary(v), do: v
  defp header_value_to_string(_v), do: nil

  # Only ever called with `header_value/2`'s non-nil result, a binary.
  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end
end
