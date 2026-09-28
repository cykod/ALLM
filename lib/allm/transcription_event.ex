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
    segment. Committed segments are appended. When the request set
    `timestamps: true` or `logprobs: true`, the payload also carries a
    `:spans` key: the segment's `t:ALLM.TranscriptSpan.t/0` list, or `nil`
    when the adapter has no trustworthy span data for that segment. With
    both flags off the key is absent, not `nil`.
  - `{:transcription_completed, completed}`: the stream finished. The
    payload carries `:text`, `:language`, `:duration_seconds`,
    `:request_id`, `:usage` (an `t:ALLM.Usage.t/0`) and `:metadata`. When
    a flag was set it also carries an optional `:spans` key: the
    committed segments' spans concatenated in order, `[]` when none were
    committed.
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

  `:spans`, when present, is likewise the adapter's concatenation of the
  committed segments' spans. It is optional, so
  `transcription_completed/1` does not require it.

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
  alias ALLM.TranscriptSpan

  @typedoc "Payload of `:transcription_started`."
  @type started :: %{
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          session_id: String.t() | nil
        }

  @typedoc "Payload of `:committed_transcript`. `:spans` is present only when a span flag was set."
  @type committed :: %{
          required(:text) => String.t(),
          required(:language) => String.t() | nil,
          optional(:spans) => [TranscriptSpan.t()] | nil
        }

  @typedoc "Payload of `:transcription_completed`. `:spans` is present only when a span flag was set."
  @type completed :: %{
          required(:text) => String.t(),
          required(:language) => String.t() | nil,
          required(:duration_seconds) => number() | nil,
          required(:request_id) => String.t() | nil,
          required(:usage) => ALLM.Usage.t(),
          required(:metadata) => map(),
          optional(:spans) => [TranscriptSpan.t()]
        }

  @type t ::
          {:transcription_started, started()}
          | {:partial_transcript, %{text: String.t()}}
          | {:committed_transcript, committed()}
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

  The payload has exactly `:text` and `:language`, and no `:spans` key.
  `committed_transcript/3` is the form that carries spans.

  ## Examples

      iex> ALLM.TranscriptionEvent.committed_transcript("hello", "en")
      {:committed_transcript, %{text: "hello", language: "en"}}
  """
  @spec committed_transcript(String.t(), String.t() | nil) :: t()
  def committed_transcript(text, language \\ nil)
      when is_binary(text) and (is_binary(language) or is_nil(language)),
      do: {:committed_transcript, %{text: text, language: language}}

  @doc """
  Build a `:committed_transcript` event carrying the segment's spans.

  Always writes the `:spans` key, even when it is `nil` (the adapter has no
  trustworthy span data for this segment). An adapter uses this form for
  every committed segment when the request set `timestamps: true` or
  `logprobs: true`, and `committed_transcript/2` otherwise. Raises
  `FunctionClauseError` when `spans` is neither a list nor `nil`.

  ## Examples

      iex> span = ALLM.TranscriptSpan.new(text: "hello", kind: :word, start_seconds: 0.0, end_seconds: 0.4)
      iex> {:committed_transcript, payload} = ALLM.TranscriptionEvent.committed_transcript("hello", "en", [span])
      iex> payload.spans == [span]
      true
  """
  @spec committed_transcript(String.t(), String.t() | nil, [TranscriptSpan.t()] | nil) :: t()
  def committed_transcript(text, language, spans)
      when is_binary(text) and (is_binary(language) or is_nil(language)) and
             (is_list(spans) or is_nil(spans)),
      do: {:committed_transcript, %{text: text, language: language, spans: spans}}

  @doc """
  Build a `:transcription_completed` event.

  Raises `ArgumentError` when `payload` lacks any of `:text`, `:language`,
  `:duration_seconds`, `:request_id`, `:usage` or `:metadata`. `:spans` is
  optional and passes through when present.

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
