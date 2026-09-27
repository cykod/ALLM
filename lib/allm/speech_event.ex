defmodule ALLM.SpeechEvent do
  @moduledoc """
  Closed tagged-tuple union emitted by a streaming speech-synthesis call.
  Layer A data.

  Every event is `{tag, payload}`, one of:

  - `{:speech_started, started}`: the provider accepted the request. The
    payload carries correlation (`:request_id`, `:model`, `:provider`) and
    what the audio will be (`:format`, `:mime_type`, `:sample_rate`).
    `:mime_type` begins `audio/`, and `:sample_rate` is the rate the bytes
    are encoded at, which is what a `:pcm` stream is played back at.
  - `{:audio_delta, bytes}`: the next slice of audio, never empty.
  - `{:speech_completed, completed}`: the stream finished. The payload
    carries `:request_id`, `:id`, `:usage` (an `t:ALLM.Usage.t/0`) and
    `:metadata`.
  - `{:error, %ALLM.Error.SpeechAdapterError{}}`: the stream failed.

  ## Stream grammar

  A successful stream is one `:speech_started`, then one or more
  `:audio_delta` events, then one `:speech_completed`. A failed stream is an
  optional `:speech_started`, zero or more `:audio_delta` events, then one
  `:error`. Nothing follows a terminal event (`:speech_completed` or
  `:error`).

  A stream that reaches its end with zero audio bytes, including one whose
  text input produced nothing to speak, ends with
  `{:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}`,
  so a successful stream always carries at least one delta.

  Concatenating every `:audio_delta` payload in order yields a valid file
  of the started `:format`, or raw PCM at `:sample_rate` for `:pcm`.

  ## Serializability

  Events round-trip through `:erlang.term_to_binary/1`. They are **not**
  JSON-encoded: `:audio_delta` carries raw audio bytes, which are not UTF-8.
  The same holds for `ALLM.TranscriptionEvent`.

  ## Closed union

  Adding a variant is a breaking change for any reducer of this union, the
  same rule as `ALLM.Event`. Adding a key to an existing payload map is not.
  The union is separate from `ALLM.Event`: `event?/1` is `false` on every
  chat event. The reverse does not hold: `ALLM.Event.event?/1` treats `:error`
  payloads as opaque, so it also returns `true` on this union's `:error`
  event. Route by this module's `event?/1`, or by the error struct.

  Build events with the variant constructors (`speech_started/1`,
  `audio_delta/1`, `speech_completed/1`), which check the payload's required
  keys. `:error` has no constructor; its payload is the error struct.
  """

  alias ALLM.Error.SpeechAdapterError

  @typedoc "Payload of `:speech_started`."
  @type started :: %{
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          format: ALLM.SpeechRequest.format() | nil,
          mime_type: String.t(),
          sample_rate: pos_integer() | nil
        }

  @typedoc "Payload of `:speech_completed`."
  @type completed :: %{
          request_id: String.t() | nil,
          id: String.t() | nil,
          usage: ALLM.Usage.t(),
          metadata: map()
        }

  @type t ::
          {:speech_started, started()}
          | {:audio_delta, binary()}
          | {:speech_completed, completed()}
          | {:error, SpeechAdapterError.t()}

  @started_keys [:request_id, :model, :provider, :format, :mime_type, :sample_rate]
  @completed_keys [:request_id, :id, :usage, :metadata]

  @doc """
  Build a `:speech_started` event.

  Raises `ArgumentError` when `payload` lacks any of `:request_id`,
  `:model`, `:provider`, `:format`, `:mime_type` or `:sample_rate` (a key
  may be present with a `nil` value).

  ## Examples

      iex> {:speech_started, p} =
      ...>   ALLM.SpeechEvent.speech_started(%{
      ...>     request_id: nil, model: "tts-1", provider: :openai,
      ...>     format: :pcm, mime_type: "audio/pcm", sample_rate: 24_000
      ...>   })
      iex> p.sample_rate
      24000
  """
  @spec speech_started(started()) :: t()
  def speech_started(payload) when is_map(payload) do
    require_keys!(payload, @started_keys, :speech_started)
    {:speech_started, payload}
  end

  @doc """
  Build an `:audio_delta` event. Raises `ArgumentError` on `""`: a delta is
  never empty.

  ## Examples

      iex> ALLM.SpeechEvent.audio_delta(<<1, 2, 3>>)
      {:audio_delta, <<1, 2, 3>>}
  """
  @spec audio_delta(binary()) :: t()
  def audio_delta(""), do: raise(ArgumentError, "an :audio_delta payload must not be empty")
  def audio_delta(bytes) when is_binary(bytes), do: {:audio_delta, bytes}

  @doc """
  Build a `:speech_completed` event.

  Raises `ArgumentError` when `payload` lacks any of `:request_id`, `:id`,
  `:usage` or `:metadata`.

  ## Examples

      iex> ALLM.SpeechEvent.speech_completed(%{request_id: "r", id: nil, usage: %ALLM.Usage{}, metadata: %{}})
      {:speech_completed, %{request_id: "r", id: nil, usage: %ALLM.Usage{}, metadata: %{}}}
  """
  @spec speech_completed(completed()) :: t()
  def speech_completed(payload) when is_map(payload) do
    require_keys!(payload, @completed_keys, :speech_completed)
    {:speech_completed, payload}
  end

  @doc """
  Return `true` when `value` is a well-shaped `ALLM.SpeechEvent`.

  The tag must be one of the four variants. `:speech_started` and
  `:speech_completed` need a map payload, `:audio_delta` a non-empty
  binary, and `:error` an `%ALLM.Error.SpeechAdapterError{}`. Payload keys
  are not checked here; the constructors check them.

  ## Examples

      iex> ALLM.SpeechEvent.event?({:audio_delta, "ab"})
      true

      iex> ALLM.SpeechEvent.event?({:audio_delta, 1})
      false

      iex> ALLM.SpeechEvent.event?({:text_delta, %{id: nil, delta: "hi"}})
      false
  """
  @spec event?(term()) :: boolean()
  def event?({:speech_started, payload}) when is_map(payload), do: true
  def event?({:audio_delta, bytes}) when is_binary(bytes) and bytes != "", do: true
  def event?({:speech_completed, payload}) when is_map(payload), do: true
  def event?({:error, %SpeechAdapterError{}}), do: true
  def event?(_), do: false

  defp require_keys!(payload, keys, tag) do
    case Enum.reject(keys, &Map.has_key?(payload, &1)) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "#{inspect(tag)} payload is missing required keys #{inspect(missing)}"
    end
  end
end
