defmodule ALLM.Test.Fixtures.ScriptedTranscriptionStreamStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.TranscriptionStreamAdapter`.
  Used by `allm_conformance`'s self-test for
  `ALLM.Test.TranscriptionStreamAdapterConformance`.

  ## Script contract

      adapter_opts: [transcription_script: [{:ok, "text"}]]

  The stub reads entry 0 on every call. After consuming the whole input it
  emits one `:committed_transcript` of the text (none for an absent script)
  and `:transcription_completed`. It emits no partials; the grammar allows
  that.

  ## Real gates and input handling

  `stream_sample_rates/0` is `[16_000]`, and the sample-rate gate runs
  synchronously, ahead of the script. The input is reduced in the consuming
  process with a running byte count, so an odd total length is caught at
  end of input.
  """

  @behaviour ALLM.TranscriptionStreamAdapter

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.{TranscriptionStreamRequest, Usage}

  @impl ALLM.TranscriptionStreamAdapter
  def stream_sample_rates, do: [16_000]

  @impl ALLM.TranscriptionStreamAdapter
  def stream_transcribe(%TranscriptionStreamRequest{sample_rate: rate} = request, input, opts) do
    if rate in stream_sample_rates() do
      {:ok, Stream.flat_map([:run], fn :run -> run(request, input, opts) end)}
    else
      {:error, TranscriptionAdapterError.new(:invalid_request, metadata: %{sample_rate: rate})}
    end
  end

  defp run(request, input, opts) do
    started =
      {:transcription_started,
       %{request_id: Keyword.get(opts, :request_id), model: nil, provider: :stub, session_id: nil}}

    text =
      case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:transcription_script, []) do
        [{:ok, text} | _] -> text
        _ -> ""
      end

    case count_bytes(input) do
      {:ok, bytes} when rem(bytes, 2) == 0 ->
        segments =
          if text == "", do: [], else: [{:committed_transcript, %{text: text, language: nil}}]

        [started | segments] ++ [completed(text, bytes, request, opts)]

      _ ->
        [started, invalid_chunk()]
    end
  end

  defp count_bytes(input) do
    Enum.reduce_while(input, {:ok, 0}, fn
      chunk, {:ok, n} when is_binary(chunk) -> {:cont, {:ok, n + byte_size(chunk)}}
      :commit, acc -> {:cont, acc}
      _other, _acc -> {:halt, :invalid}
    end)
  end

  defp completed(text, bytes, request, opts) do
    {:transcription_completed,
     %{
       text: String.trim(text),
       language: nil,
       duration_seconds: bytes / (request.sample_rate * 2),
       request_id: Keyword.get(opts, :request_id),
       usage: %Usage{},
       metadata: request.metadata
     }}
  end

  defp invalid_chunk do
    {:error,
     TranscriptionAdapterError.new(:invalid_request, metadata: %{cause: :invalid_input_chunk})}
  end
end
