defmodule ALLM.Test.Fixtures.ScriptedSpeechStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.SpeechAdapter`. Used by
  `allm_conformance`'s self-test for `ALLM.Test.SpeechAdapterConformance`.

  ## Script contract

      adapter_opts: [
        speech_script: [
          {:ok, <<bytes>>},
          {:ok, %ALLM.SpeechResponse{...}},
          {:error, %ALLM.Error.SpeechAdapterError{...}}
        ]
      ]

  The stub reads entry 0 on every call (the single-call contract every
  conformance case uses). An absent script returns `"STUB-AUDIO:" <> input`
  as `audio/mpeg`. It does not implement `{:retry_until_call, n}` or the
  reference's spent-script error; no conformance case scripts either, so it
  is not a second reference implementation.

  ## Real gates

  Unlike a scripted real provider adapter — which hands off to
  `ALLM.Providers.FakeSpeech` before its own gates run — this stub evaluates
  the empty-input gate ahead of the script, and ahead of anything resembling
  credential resolution.
  """

  @behaviour ALLM.SpeechAdapter

  alias ALLM.{Audio, SpeechRequest, SpeechResponse}
  alias ALLM.Error.SpeechAdapterError

  @impl ALLM.SpeechAdapter
  def synthesize(%SpeechRequest{input: ""}, _opts) do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       message: "input must not be empty",
       metadata: %{field: :input}
     )}
  end

  def synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    script = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:speech_script, [])

    case List.first(script) do
      nil -> {:ok, build_response("STUB-AUDIO:" <> request.input, request, opts)}
      {:ok, %SpeechResponse{} = response} -> {:ok, response}
      {:ok, bytes} when is_binary(bytes) -> {:ok, build_response(bytes, request, opts)}
      {:error, %SpeechAdapterError{} = err} -> {:error, err}
    end
  end

  defp build_response(bytes, %SpeechRequest{} = request, opts) do
    %SpeechResponse{
      audio: Audio.from_binary(bytes, "audio/mpeg"),
      format: :mp3,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :stub,
      metadata: request.metadata
    }
  end
end
