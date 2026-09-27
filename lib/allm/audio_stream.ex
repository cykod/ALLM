defmodule ALLM.AudioStream do
  @moduledoc """
  Reducers and adapters for streamed audio. Layer C, pure functions over
  enumerables.

    * `collect_speech/1` folds an `ALLM.SpeechEvent` stream (from
      `ALLM.stream_synthesize/3` or `ALLM.stream_synthesize_input/3`) into
      the `ALLM.SpeechResponse` that `ALLM.synthesize/3` would return.
    * `collect_transcription/1` folds an `ALLM.TranscriptionEvent` stream
      (from `ALLM.stream_transcribe/3`) into an `ALLM.TranscriptionResponse`.
    * `text_deltas/1` turns a chat event stream (from `ALLM.stream/3` or
      `ALLM.stream_generate/3`) into the text chunks
      `ALLM.stream_synthesize_input/3` reads.

  ## A failed stream is an error, not a partial response

  An audio stream that fails after it opened ends with `{:error, err}`, and
  the collectors return `{:error, err}`. This differs from chat, where a
  mid-stream error folds into a response with `finish_reason: :error`: a
  speech response has no finish reason, and a half-rendered clip is not a
  valid response. What did arrive is described on the error's `:metadata`:

    * `collect_speech/1` adds `bytes_received`, the count of audio bytes
      before the error. The bytes themselves are not kept on the error:
      errors encode to JSON, and raw audio is not UTF-8.
    * `collect_transcription/1` adds `committed_text`, the committed
      segments so far, trimmed and joined with one space.

  When the failure came from the input enumerable rather than the provider,
  `metadata.cause` is `:input_raised` (the input raised, threw or exited) or
  `:input_crashed` (a process linked inside the input crashed), and the
  error's `:cause` is a map `%{kind: kind, message: text}`, where `kind` is
  the atom `:error`, `:throw` or `:exit` and `text` is a string, never the
  raw exception or exit term. After a JSON round-trip `kind` reads back as a
  string (`"error"`).

  ## Speaking a chat stream

  `text_deltas/1` keeps only the text of `:text_delta` events. A chat
  `{:error, err}` event **raises** inside the speech adapter's input
  reduction, so the speech stream ends with `{:error, _}`,
  `metadata.cause: :input_raised`, and the chat error's reason and message
  in the error's `:cause` map. A truncated answer therefore never finishes
  as a successful clip. To speak whatever arrived before a chat failure,
  filter the chat stream before `text_deltas/1`.
  """

  alias ALLM.{Audio, SpeechResponse, TranscriptionResponse}
  alias ALLM.AudioStream.ChatStreamError
  alias ALLM.Error.{SpeechAdapterError, TranscriptionAdapterError}

  @doc """
  Fold a speech event stream into an `ALLM.SpeechResponse`.

  `:model`, `:provider`, `:format`, `:sample_rate` and the audio's MIME type
  come from `:speech_started`; `:usage`, `:id`, `:request_id` and
  `:metadata` from `:speech_completed`. The audio is every `:audio_delta`
  payload concatenated, as an `ALLM.Audio`. `:raw` is `nil`.

  An `{:error, err}` event returns `{:error, err}` with
  `metadata.bytes_received` set. A stream that ends without a terminal
  event, or completes without a `:speech_started`, returns
  `{:error, %ALLM.Error.SpeechAdapterError{reason: :malformed_response}}`.
  Reduction stops at the first terminal event.

  ## Examples

      iex> events = [
      ...>   ALLM.SpeechEvent.speech_started(%{request_id: "r1", model: "m", provider: :fake,
      ...>     format: :pcm, mime_type: "audio/pcm", sample_rate: 24_000}),
      ...>   ALLM.SpeechEvent.audio_delta("ab"),
      ...>   ALLM.SpeechEvent.audio_delta("c"),
      ...>   ALLM.SpeechEvent.speech_completed(%{request_id: "r1", id: nil,
      ...>     usage: %ALLM.Usage{}, metadata: %{}})
      ...> ]
      iex> {:ok, resp} = ALLM.AudioStream.collect_speech(events)
      iex> {ALLM.Audio.to_binary(resp.audio), resp.format, resp.sample_rate}
      {{:ok, "abc"}, :pcm, 24000}

      iex> err = ALLM.Error.SpeechAdapterError.new(:timeout)
      iex> {:error, err} = ALLM.AudioStream.collect_speech([{:audio_delta, "abc"}, {:error, err}])
      iex> err.metadata.bytes_received
      3
  """
  @spec collect_speech(Enumerable.t(ALLM.SpeechEvent.t())) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def collect_speech(events) do
    events
    |> Enum.reduce_while(%{started: nil, deltas: [], bytes: 0}, &speech_step/2)
    |> case do
      {:done, result} ->
        result

      %{} ->
        {:error,
         SpeechAdapterError.new(:malformed_response,
           message: "the speech stream ended without a terminal event"
         )}
    end
  end

  defp speech_step({:speech_started, started}, acc), do: {:cont, %{acc | started: started}}

  defp speech_step({:audio_delta, bytes}, acc),
    do: {:cont, %{acc | deltas: [acc.deltas, bytes], bytes: acc.bytes + byte_size(bytes)}}

  defp speech_step({:speech_completed, _completed}, %{started: nil}) do
    {:halt,
     {:done,
      {:error,
       SpeechAdapterError.new(:malformed_response,
         message: "the speech stream completed without a :speech_started event"
       )}}}
  end

  defp speech_step({:speech_completed, completed}, acc) do
    started = acc.started

    response = %SpeechResponse{
      audio: Audio.from_binary(IO.iodata_to_binary(acc.deltas), started.mime_type),
      format: started.format,
      sample_rate: started.sample_rate,
      model: started.model,
      provider: started.provider,
      usage: completed.usage,
      id: completed.id,
      request_id: completed.request_id,
      metadata: completed.metadata,
      raw: nil
    }

    {:halt, {:done, {:ok, response}}}
  end

  defp speech_step({:error, %SpeechAdapterError{} = err}, acc) do
    metadata = Map.put(err.metadata || %{}, :bytes_received, acc.bytes)
    {:halt, {:done, {:error, %{err | metadata: metadata}}}}
  end

  defp speech_step(_other, acc), do: {:cont, acc}

  @doc """
  Fold a transcription event stream into an `ALLM.TranscriptionResponse`.

  `:text`, `:language`, `:duration_seconds`, `:usage`, `:request_id` and
  `:metadata` come from `:transcription_completed`, whose `:text` is
  already the adapter's join of the committed segments; `:model`,
  `:provider` and `:id` (the realtime session id) from
  `:transcription_started`. `:raw` is `nil`.

  An `{:error, err}` event returns `{:error, err}` with
  `metadata.committed_text` set to the committed segments so far. A stream
  that ends without a terminal event returns
  `{:error, %ALLM.Error.TranscriptionAdapterError{reason: :malformed_response}}`.

  Unlike `collect_speech/1`, a missing `:transcription_started` is not an
  error: the transcript itself is on the completed event, so the response
  is returned with `:model`, `:provider` and `:id` nil. (Speech needs the
  start event's `:format` and `:mime_type` to build its `ALLM.Audio`.)

  ## Examples

      iex> events = [
      ...>   ALLM.TranscriptionEvent.transcription_started(%{request_id: "r1", model: nil,
      ...>     provider: :fake, session_id: "s1"}),
      ...>   ALLM.TranscriptionEvent.partial_transcript("hel"),
      ...>   ALLM.TranscriptionEvent.committed_transcript("hello"),
      ...>   ALLM.TranscriptionEvent.transcription_completed(%{text: "hello", language: nil,
      ...>     duration_seconds: 0.5, request_id: "r1", usage: %ALLM.Usage{}, metadata: %{}})
      ...> ]
      iex> {:ok, resp} = ALLM.AudioStream.collect_transcription(events)
      iex> {resp.text, resp.id, resp.duration_seconds}
      {"hello", "s1", 0.5}
  """
  @spec collect_transcription(Enumerable.t(ALLM.TranscriptionEvent.t())) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def collect_transcription(events) do
    events
    |> Enum.reduce_while(%{started: nil, committed: []}, &transcription_step/2)
    |> case do
      {:done, result} ->
        result

      %{} ->
        {:error,
         TranscriptionAdapterError.new(:malformed_response,
           message: "the transcription stream ended without a terminal event"
         )}
    end
  end

  defp transcription_step({:transcription_started, started}, acc),
    do: {:cont, %{acc | started: started}}

  defp transcription_step({:committed_transcript, %{text: text}}, acc),
    do: {:cont, %{acc | committed: [text | acc.committed]}}

  defp transcription_step({:transcription_completed, completed}, acc) do
    started = acc.started || %{}

    response = %TranscriptionResponse{
      text: completed.text,
      language: completed.language,
      duration_seconds: completed.duration_seconds,
      usage: completed.usage,
      request_id: completed.request_id,
      metadata: completed.metadata,
      model: Map.get(started, :model),
      provider: Map.get(started, :provider),
      id: Map.get(started, :session_id),
      raw: nil
    }

    {:halt, {:done, {:ok, response}}}
  end

  defp transcription_step({:error, %TranscriptionAdapterError{} = err}, acc) do
    committed =
      acc.committed
      |> Enum.reverse()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    metadata = Map.put(err.metadata || %{}, :committed_text, committed)
    {:halt, {:done, {:error, %{err | metadata: metadata}}}}
  end

  defp transcription_step(_other, acc), do: {:cont, acc}

  @doc """
  Turn a chat event stream into the text chunks it carries. Lazy.

  Each `{:text_delta, %{delta: text}}` becomes `text`; every other event is
  dropped. A chat `{:error, err}` event raises when the stream is reduced,
  so passed to `ALLM.stream_synthesize_input/3` it ends the speech stream
  with `metadata.cause: :input_raised` and the chat error's reason and
  message in the speech error's `:cause` map (see the moduledoc).

  ## Examples

      iex> chat = [
      ...>   {:message_started, %{message: ALLM.assistant("")}},
      ...>   {:text_delta, %{id: nil, delta: "Hel"}},
      ...>   {:text_delta, %{id: nil, delta: "lo."}}
      ...> ]
      iex> chat |> ALLM.AudioStream.text_deltas() |> Enum.to_list()
      ["Hel", "lo."]
  """
  @spec text_deltas(Enumerable.t(ALLM.Event.t())) :: Enumerable.t(String.t())
  def text_deltas(chat_events) do
    Stream.flat_map(chat_events, fn
      {:text_delta, %{delta: delta}} when is_binary(delta) -> [delta]
      {:error, err} -> raise ChatStreamError, err
      _other -> []
    end)
  end
end
