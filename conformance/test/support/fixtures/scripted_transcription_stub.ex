defmodule ALLM.Test.Fixtures.ScriptedTranscriptionStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.TranscriptionAdapter`. Used
  by `allm_conformance`'s self-test for
  `ALLM.Test.TranscriptionAdapterConformance`.

  ## Script contract

      adapter_opts: [
        transcription_script: [
          {:ok, "text"},
          {:ok, %ALLM.TranscriptionResponse{...}},
          {:error, %ALLM.Error.TranscriptionAdapterError{...}}
        ]
      ]

  The stub reads entry 0 on every call. An absent script returns an empty
  transcript. It does not implement `{:retry_until_call, n}` or the
  reference's spent-script error; no conformance case scripts either.

  ## Real gates

  This stub evaluates the resolvable gate, then the size gate, ahead of the
  script and ahead of anything resembling credential resolution — the gate
  order every transcription adapter follows. `max_audio_bytes/0` is `600`:
  above the 512-byte clip the scripted case uses, and small enough that the
  oversized case allocates almost nothing.
  """

  @behaviour ALLM.TranscriptionAdapter

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError

  @max_audio_bytes 600

  @impl ALLM.TranscriptionAdapter
  def max_audio_bytes, do: @max_audio_bytes

  @impl ALLM.TranscriptionAdapter
  def transcribe(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case gate(request.audio) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  defp gate(%Audio{} = audio) do
    case Audio.size(audio) do
      {:error, cause} ->
        {:error, TranscriptionAdapterError.new(:invalid_request, metadata: %{cause: cause})}

      {:ok, count} when count > @max_audio_bytes ->
        {:error,
         TranscriptionAdapterError.new(:invalid_request,
           metadata: %{count: count, max: @max_audio_bytes}
         )}

      {:ok, _count} ->
        :ok
    end
  end

  defp gate(_other) do
    {:error, TranscriptionAdapterError.new(:invalid_request, metadata: %{cause: :invalid_source})}
  end

  defp run_scripted(%TranscriptionRequest{} = request, opts) do
    script = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:transcription_script, [])

    case List.first(script) do
      nil -> {:ok, build_response("", request, opts)}
      {:ok, %TranscriptionResponse{} = response} -> {:ok, response}
      {:ok, text} when is_binary(text) -> {:ok, build_response(text, request, opts)}
      {:error, %TranscriptionAdapterError{} = err} -> {:error, err}
    end
  end

  defp build_response(text, %TranscriptionRequest{} = request, opts) do
    %TranscriptionResponse{
      text: text,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :stub,
      metadata: request.metadata
    }
  end
end
