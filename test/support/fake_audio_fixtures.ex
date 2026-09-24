defmodule ALLM.Test.FakeAudioFixtures do
  @moduledoc """
  Named scripted fixtures for `ALLM.Providers.FakeSpeech` and
  `ALLM.Providers.FakeTranscription`. Every script builder returns a keyword
  `adapter_opts` ready to pass to `ALLM.Engine.new/1` under the
  `adapter_opts:` key, or straight into a direct `synthesize/2` /
  `transcribe/2` call.

  Layer B (test support) — lives under `test/support/` and is not part of the
  published Hex package. The Fakes themselves ship in `lib/`; their named
  test fixtures stay test-only.
  """

  alias ALLM.{Audio, Engine}
  alias ALLM.Error.{SpeechAdapterError, TranscriptionAdapterError}
  alias ALLM.Providers.{FakeSpeech, FakeTranscription}

  @doc """
  An engine wired to `ALLM.Providers.FakeSpeech`, carrying `adapter_opts` and
  a stable `:id` (so the per-engine cursor key applies).
  """
  @spec speech_engine(keyword()) :: Engine.t()
  def speech_engine(adapter_opts \\ []) when is_list(adapter_opts),
    do: Engine.new(speech_adapter: FakeSpeech, adapter_opts: adapter_opts)

  @doc """
  An engine wired to `ALLM.Providers.FakeTranscription`, carrying
  `adapter_opts` and a stable `:id`.
  """
  @spec transcription_engine(keyword()) :: Engine.t()
  def transcription_engine(adapter_opts \\ []) when is_list(adapter_opts),
    do: Engine.new(transcription_adapter: FakeTranscription, adapter_opts: adapter_opts)

  @doc "Script returning `bytes` as the synthesized audio in one call."
  @spec speech_bytes(binary()) :: keyword()
  def speech_bytes(bytes) when is_binary(bytes), do: [speech_script: [{:ok, bytes}]]

  @doc "Script returning `text` as the transcript in one call."
  @spec transcript(String.t()) :: keyword()
  def transcript(text) when is_binary(text), do: [transcription_script: [{:ok, text}]]

  @doc "Script returning a scripted `:rate_limited` speech error verbatim."
  @spec speech_rate_limited() :: keyword()
  def speech_rate_limited do
    err =
      SpeechAdapterError.new(:rate_limited,
        message: "scripted rate limit",
        provider: :fake,
        retry_after_ms: 250
      )

    [speech_script: [{:error, err}]]
  end

  @doc "Script returning a scripted `:rate_limited` transcription error verbatim."
  @spec transcription_rate_limited() :: keyword()
  def transcription_rate_limited do
    err =
      TranscriptionAdapterError.new(:rate_limited,
        message: "scripted rate limit",
        provider: :fake,
        retry_after_ms: 250
      )

    [transcription_script: [{:error, err}]]
  end

  @doc """
  Speech script failing with a synthetic `:rate_limited` for the first
  `n - 1` calls, then returning `bytes`.
  """
  @spec speech_retry_until_call(pos_integer(), binary()) :: keyword()
  def speech_retry_until_call(n, bytes) when is_integer(n) and n >= 1 and is_binary(bytes),
    do: [speech_script: [{:retry_until_call, n}, {:ok, bytes}]]

  @doc """
  Transcription script failing with a synthetic `:rate_limited` for the
  first `n - 1` calls, then returning `text`.
  """
  @spec transcription_retry_until_call(pos_integer(), String.t()) :: keyword()
  def transcription_retry_until_call(n, text) when is_integer(n) and n >= 1 and is_binary(text),
    do: [transcription_script: [{:retry_until_call, n}, {:ok, text}]]

  @doc "An in-memory `audio/mpeg` clip of exactly `n` bytes."
  @spec clip(non_neg_integer()) :: Audio.t()
  def clip(n) when is_integer(n) and n >= 0,
    do: Audio.from_binary(:binary.copy(<<0>>, n), "audio/mpeg")
end
