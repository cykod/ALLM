defmodule ALLM.TranscriptionEvent do
  @moduledoc """
  Closed tagged-tuple union emitted by a streaming transcription call.
  Layer A data.

  Every event is `{tag, payload}`, one of:

  - `{:transcription_started, started}`: the session opened. The payload
    carries `:request_id`, `:model`, `:provider` and the provider's
    `:session_id`, each possibly `nil`.
  - `{:partial_transcript, %{text: text}}`: the current best guess for the
    segment being spoken. It **replaces** the previous partial of the same
    segment; it is not appended.
  - `{:committed_transcript, %{text: text, language: language}}`: a final
    segment. Committed segments are appended.
  - `{:transcription_completed, completed}`: the stream finished. The
    payload carries `:text`, `:language`, `:duration_seconds`,
    `:request_id`, `:usage` (an `t:ALLM.Usage.t/0`) and `:metadata`.
  - `{:error, %ALLM.Error.TranscriptionAdapterError{}}`: the stream failed.

  ## Stream grammar

  A successful stream is one `:transcription_started`, then any number of
  segments (zero or more `:partial_transcript` events followed by one
  `:committed_transcript`), then zero or more trailing `:partial_transcript`
  events, then one `:transcription_completed`. A failed stream ends with one
  `:error`. Nothing follows a terminal event.

  ## The completed payload

  `:text` is the whole transcript: each committed segment's text is
  trimmed, empty segments are dropped, and the rest are joined with one
  space. The adapter computes it, so a consumer does not need to fold the
  segments itself.

  `:duration_seconds` is **computed**, not reported by the provider: the
  audio bytes sent divided by `sample_rate * 2` (16-bit mono PCM).

  ## Serializability

  Events round-trip through `:erlang.term_to_binary/1`. They are not
  JSON-encoded, matching `ALLM.SpeechEvent`.

  ## Closed union

  Adding a variant is a breaking change for any reducer of this union, the
  same rule as `ALLM.Event`. Adding a key to an existing payload map is not.
  `event?/1` is `false` on every chat event. The reverse does not hold:
  `ALLM.Event.event?/1` treats `:error` payloads as opaque, so it also returns
  `true` on this union's `:error` event. Route by this module's `event?/1`, or
  by the error struct.

  Build events with the variant constructors, which check the payload's
  required keys. `:error` has no constructor; its payload is the error
  struct.
  """

  alias ALLM.Error.TranscriptionAdapterError

  @typedoc "Payload of `:transcription_started`."
  @type started :: %{
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          session_id: String.t() | nil
        }

  @typedoc "Payload of `:transcription_completed`."
  @type completed :: %{
          text: String.t(),
          language: String.t() | nil,
          duration_seconds: number() | nil,
          request_id: String.t() | nil,
          usage: ALLM.Usage.t(),
          metadata: map()
        }

  @type t ::
          {:transcription_started, started()}
          | {:partial_transcript, %{text: String.t()}}
          | {:committed_transcript, %{text: String.t(), language: String.t() | nil}}
          | {:transcription_completed, completed()}
          | {:error, TranscriptionAdapterError.t()}

  @started_keys [:request_id, :model, :provider, :session_id]
  @completed_keys [:text, :language, :duration_seconds, :request_id, :usage, :metadata]

  @doc """
  Build a `:transcription_started` event.

  Raises `ArgumentError` when `payload` lacks any of `:request_id`,
  `:model`, `:provider` or `:session_id` (a key may be present with a `nil`
  value).

  ## Examples

      iex> ALLM.TranscriptionEvent.transcription_started(%{request_id: nil, model: "m", provider: :fake, session_id: nil})
      {:transcription_started, %{request_id: nil, model: "m", provider: :fake, session_id: nil}}
  """
  @spec transcription_started(started()) :: t()
  def transcription_started(payload) when is_map(payload) do
    require_keys!(payload, @started_keys, :transcription_started)
    {:transcription_started, payload}
  end

  @doc """
  Build a `:partial_transcript` event.

  ## Examples

      iex> ALLM.TranscriptionEvent.partial_transcript("hel")
      {:partial_transcript, %{text: "hel"}}
  """
  @spec partial_transcript(String.t()) :: t()
  def partial_transcript(text) when is_binary(text), do: {:partial_transcript, %{text: text}}

  @doc """
  Build a `:committed_transcript` event.

  ## Examples

      iex> ALLM.TranscriptionEvent.committed_transcript("hello", "en")
      {:committed_transcript, %{text: "hello", language: "en"}}
  """
  @spec committed_transcript(String.t(), String.t() | nil) :: t()
  def committed_transcript(text, language \\ nil)
      when is_binary(text) and (is_binary(language) or is_nil(language)),
      do: {:committed_transcript, %{text: text, language: language}}

  @doc """
  Build a `:transcription_completed` event.

  Raises `ArgumentError` when `payload` lacks any of `:text`, `:language`,
  `:duration_seconds`, `:request_id`, `:usage` or `:metadata`.

  ## Examples

      iex> {:transcription_completed, p} =
      ...>   ALLM.TranscriptionEvent.transcription_completed(%{
      ...>     text: "hello world", language: nil, duration_seconds: 1.5,
      ...>     request_id: nil, usage: %ALLM.Usage{}, metadata: %{}
      ...>   })
      iex> p.text
      "hello world"
  """
  @spec transcription_completed(completed()) :: t()
  def transcription_completed(payload) when is_map(payload) do
    require_keys!(payload, @completed_keys, :transcription_completed)
    {:transcription_completed, payload}
  end

  @doc """
  Return `true` when `value` is a well-shaped `ALLM.TranscriptionEvent`.

  The tag must be one of the five variants. `:partial_transcript` and
  `:committed_transcript` need a map payload with a binary `:text`, the
  other structured variants a map, and `:error` an
  `%ALLM.Error.TranscriptionAdapterError{}`.

  ## Examples

      iex> ALLM.TranscriptionEvent.event?({:partial_transcript, %{text: "hi"}})
      true

      iex> ALLM.TranscriptionEvent.event?({:text_delta, %{id: nil, delta: "hi"}})
      false
  """
  @spec event?(term()) :: boolean()
  def event?({:transcription_started, payload}) when is_map(payload), do: true
  def event?({:partial_transcript, %{text: text}}) when is_binary(text), do: true
  def event?({:committed_transcript, %{text: text}}) when is_binary(text), do: true
  def event?({:transcription_completed, payload}) when is_map(payload), do: true
  def event?({:error, %TranscriptionAdapterError{}}), do: true
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
