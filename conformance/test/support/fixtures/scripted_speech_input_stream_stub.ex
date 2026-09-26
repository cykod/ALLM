defmodule ALLM.Test.Fixtures.ScriptedSpeechInputStreamStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.SpeechStreamAdapter`
  including the optional `stream_synthesize_input/3`. Used by
  `allm_conformance`'s self-test for
  `ALLM.Test.SpeechInputStreamAdapterConformance`.

  ## Script contract

      adapter_opts: [speech_script: [{:ok, <<bytes>>}]]

  The stub reads entry 0 on every call. After consuming the whole input it
  emits the scripted bytes (or `"STUB-AUDIO"` with no script) through
  `ALLM.Test.Fixtures.ScriptedSpeechStreamStub.audio_events/3`.

  ## Real gates and input handling

  The request shape gate (`:format` must be `nil` or one of
  `ALLM.SpeechRequest.formats/0`) runs synchronously, ahead of the script.
  Unlike the reference Fake, the stub reduces the input **in the consuming
  process**, inside the stream, with a `try`/`catch`: it is a second
  implementation of the input invariants, not a copy of the reference's
  pump.
  """

  @behaviour ALLM.SpeechStreamAdapter

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.SpeechRequest
  alias ALLM.Test.Fixtures.ScriptedSpeechStreamStub

  @impl ALLM.SpeechStreamAdapter
  defdelegate stream_synthesize(request, opts), to: ScriptedSpeechStreamStub

  @impl ALLM.SpeechStreamAdapter
  def stream_synthesize_input(%SpeechRequest{format: format} = request, input, opts) do
    if is_nil(format) or format in SpeechRequest.formats() do
      {:ok, Stream.flat_map([:run], fn :run -> run(request, input, opts) end)}
    else
      {:error, SpeechAdapterError.new(:invalid_request, metadata: %{field: :format})}
    end
  end

  defp run(request, input, opts) do
    script = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:speech_script, [])

    bytes =
      case List.first(script) do
        {:ok, bytes} -> bytes
        nil -> "STUB-AUDIO"
      end

    case consume(input) do
      :ok ->
        ScriptedSpeechStreamStub.audio_events(bytes, request, opts)

      {:error, cause, extra} ->
        [ScriptedSpeechStreamStub.started(request, opts), error(cause, extra)]
    end
  end

  defp consume(input) do
    spoke? =
      Enum.reduce(input, false, fn
        chunk, spoke? when is_binary(chunk) -> spoke? or chunk != ""
        _other, _spoke? -> throw(:invalid_input_chunk)
      end)

    if spoke?, do: :ok, else: {:error, :empty_input, nil}
  catch
    :throw, :invalid_input_chunk ->
      {:error, :invalid_input_chunk, nil}

    kind, reason ->
      {:error, :input_raised, %{kind: kind, message: Exception.format_banner(kind, reason)}}
  end

  defp error(cause, extra) do
    {:error, SpeechAdapterError.new(:invalid_request, metadata: %{cause: cause}, cause: extra)}
  end
end
