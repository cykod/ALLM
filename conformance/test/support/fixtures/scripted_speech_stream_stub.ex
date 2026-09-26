defmodule ALLM.Test.Fixtures.ScriptedSpeechStreamStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.SpeechStreamAdapter` without
  the optional input callback. Used by `allm_conformance`'s self-test for
  `ALLM.Test.SpeechStreamAdapterConformance`.

  ## Script contract

      adapter_opts: [speech_script: [{:ok, <<bytes>>} | {:error, %ALLM.Error.SpeechAdapterError{}}]]

  The stub reads entry 0 on every call. An absent script speaks
  `"STUB-AUDIO:" <> input`. The audio is emitted as two deltas (halves), so
  a harness that checked only the first delta would fail case 2. It does
  not implement `{:retry_until_call, n}`, `{:events, _}` or the reference's
  spent-script error; no conformance case scripts them.

  ## Real gates

  The empty-input gate runs ahead of the script and ahead of anything
  resembling credential resolution, and returns synchronously.
  """

  @behaviour ALLM.SpeechStreamAdapter

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.{SpeechRequest, Usage}

  @impl ALLM.SpeechStreamAdapter
  def stream_synthesize(%SpeechRequest{input: ""}, _opts) do
    {:error, SpeechAdapterError.new(:invalid_request, metadata: %{field: :input})}
  end

  def stream_synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    script = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:speech_script, [])

    events =
      case List.first(script) do
        nil -> audio_events("STUB-AUDIO:" <> request.input, request, opts)
        {:ok, bytes} when is_binary(bytes) -> audio_events(bytes, request, opts)
        {:error, %SpeechAdapterError{} = err} -> [started(request, opts), {:error, err}]
      end

    {:ok, Stream.map(events, & &1)}
  end

  @doc false
  def audio_events(bytes, request, opts) do
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), second::binary>> = bytes
    deltas = for chunk <- [first, second], chunk != "", do: {:audio_delta, chunk}

    [started(request, opts) | deltas] ++
      [
        {:speech_completed,
         %{
           request_id: Keyword.get(opts, :request_id),
           id: nil,
           usage: %Usage{},
           metadata: request.metadata
         }}
      ]
  end

  @doc false
  def started(request, opts) do
    {:speech_started,
     %{
       request_id: Keyword.get(opts, :request_id),
       model: request.model,
       provider: :stub,
       format: :mp3,
       mime_type: "audio/mpeg",
       sample_rate: nil
     }}
  end
end
