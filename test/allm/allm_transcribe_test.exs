defmodule ALLM.ALLMTranscribeTest do
  @moduledoc """
  Layer-C `ALLM.transcribe/3` and `ALLM.transcription_request/2` over
  `ALLM.Providers.FakeTranscription`.

  Transcription has no streaming counterpart, so there is no
  stream-equivalence property to write.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which filters by
  owner PID; a bare global handler attach in an `async: true` module would
  capture other tests' `[:allm, :transcribe, :*]` events.

  **Script arithmetic matters here.** A non-empty `:transcription_script`
  that runs off the end returns `:transcription_script_exhausted` rather than
  defaulting, so every scripted test below scripts exactly as many entries as
  it drives calls.
  """

  use ExUnit.Case, async: true

  doctest ALLM, only: [transcribe: 3, transcription_request: 2]

  alias ALLM.{Audio, Engine, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.{EngineError, TranscriptionAdapterError, ValidationError}
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Test.{FakeAudioFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Inline non-conforming stubs — scope is this file only.
  # ---------------------------------------------------------------------------

  defmodule BareMapAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionAdapter

    @impl ALLM.TranscriptionAdapter
    def max_audio_bytes, do: 1024

    # Deliberately non-conforming: the response struct bare rather than in an
    # `{:ok, _}` tuple — `ALLM.TranscriptionAdapter` invariant 1.
    @impl ALLM.TranscriptionAdapter
    def transcribe(%ALLM.TranscriptionRequest{}, _opts), do: %ALLM.TranscriptionResponse{}
  end

  defmodule ProviderRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionAdapter

    @impl ALLM.TranscriptionAdapter
    def max_audio_bytes, do: 1024

    @impl ALLM.TranscriptionAdapter
    def transcribe(%ALLM.TranscriptionRequest{}, _opts),
      do: {:ok, %ALLM.TranscriptionResponse{request_id: "provider-rid", text: "t"}}
  end

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionAdapter

    @impl ALLM.TranscriptionAdapter
    def max_audio_bytes, do: 1024

    @impl ALLM.TranscriptionAdapter
    def transcribe(%ALLM.TranscriptionRequest{}, _opts), do: raise("boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Default 3-attempt budget with the backoff collapsed, so retry tests do not
  # sleep 500 ms per attempt.
  @fast_retry [base_delay_ms: 1, max_delay_ms: 1, jitter_ms: 0]

  defp clip, do: FakeAudioFixtures.clip(16)

  defp fake_engine(opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [
          transcription_adapter: FakeTranscription,
          adapter_opts: [capture_pid: self()] ++ adapter_opts
        ],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  defp captured_calls(acc \\ []) do
    receive do
      {FakeTranscription, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # transcription_request/2
  # ---------------------------------------------------------------------------

  describe "transcription_request/2" do
    test "wraps the audio value" do
      audio = clip()
      req = ALLM.transcription_request(audio)
      assert %TranscriptionRequest{audio: ^audio, model: nil} = req
    end

    test "lifts request-field opts onto the struct" do
      req =
        ALLM.transcription_request(clip(),
          model: "whisper-1",
          language: "en",
          prompt: "names: Ada",
          options: %{a: 1},
          metadata: %{t: 1}
        )

      assert req.model == "whisper-1"
      assert req.language == "en"
      assert req.prompt == "names: Ada"
      assert req.options == %{a: 1}
      assert req.metadata == %{t: 1}
    end

    test "ignores call-control opts that are not TranscriptionRequest fields" do
      audio = clip()

      req =
        ALLM.transcription_request(audio,
          request_id: "rid",
          request_timeout: 5_000,
          retry: false,
          adapter_opts: [foo: 1],
          api_key: "sk-nope",
          stream: true,
          audio: :overridden?,
          totally_unknown: :whatever
        )

      assert req == TranscriptionRequest.new(audio: audio)
    end

    test "every TranscriptionRequest field except :audio is reachable through the allow-list" do
      # Symmetry invariant, computed from `Map.keys/1` — a field added to the
      # struct without an allow-list entry, or a typo'd entry, goes red here.
      # Direction NOT bound: an allow-listed non-field (see the synthesize
      # sibling test for why).
      struct_fields =
        %TranscriptionRequest{}
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--([:audio])

      for field <- struct_fields do
        req = ALLM.transcription_request(clip(), [{field, :__sentinel__}])

        assert Map.fetch!(req, field) == :__sentinel__,
               "#{inspect(field)} is a TranscriptionRequest field but is not reachable " <>
                 "through ALLM.transcription_request/2's opts allow-list"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — input shapes
  # ---------------------------------------------------------------------------

  describe "transcribe/3 input shapes" do
    test "an %Audio{} is wrapped into a TranscriptionRequest" do
      engine = fake_engine(adapter_opts: FakeAudioFixtures.transcript("hello there"))
      audio = clip()

      assert {:ok, %TranscriptionResponse{text: "hello there"}} = ALLM.transcribe(engine, audio)
      assert [%{request: %TranscriptionRequest{audio: ^audio}}] = captured_calls()
    end

    test "a pre-built request dispatches verbatim and is NOT merged with opts" do
      engine = fake_engine()

      request =
        TranscriptionRequest.new(audio: clip(), language: "fr", metadata: %{from: :req})

      assert {:ok, _} =
               ALLM.transcribe(engine, request, language: "en", metadata: %{from: :opts})

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched == request
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — gates
  # ---------------------------------------------------------------------------

  describe "transcribe/3 gates" do
    test "an engine with no transcription_adapter returns :no_transcription_adapter" do
      assert {:error, %EngineError{reason: :no_transcription_adapter}} =
               ALLM.transcribe(Engine.new(), clip())
    end

    test ":no_transcription_adapter fires even when the request would also fail validation" do
      request = TranscriptionRequest.new(audio: nil)

      assert {:error, %EngineError{reason: :no_transcription_adapter}} =
               ALLM.transcribe(Engine.new(), request)
    end

    test "an invalid request returns :invalid_transcription_request before any adapter call" do
      engine = fake_engine()
      request = TranscriptionRequest.new(audio: nil)

      assert {:error, %ValidationError{reason: :invalid_transcription_request} = err} =
               ALLM.transcribe(engine, request)

      assert err.errors == [{:audio, :invalid_shape}]
      assert captured_calls() == []
    end

    test "an adapter gate error (oversized audio) surfaces unchanged and is not retried" do
      engine = fake_engine()

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: md}} =
               ALLM.transcribe(engine, FakeAudioFixtures.clip(1025))

      assert md.count == 1025
      assert length(captured_calls()) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — opts plumbing
  # ---------------------------------------------------------------------------

  describe "transcribe/3 opts" do
    test "request-field opts lift onto the request and are not forwarded as dispatch opts" do
      engine = fake_engine()

      assert {:ok, _} =
               ALLM.transcribe(engine, clip(),
                 language: "en",
                 prompt: "p",
                 options: %{o: 1},
                 metadata: %{t: 1}
               )

      assert [%{request: request, opts: opts}] = captured_calls()
      assert request.language == "en"
      assert request.prompt == "p"
      assert request.options == %{o: 1}
      assert request.metadata == %{t: 1}

      for key <- [:model, :language, :prompt, :options, :metadata] do
        refute Keyword.has_key?(opts, key), "#{inspect(key)} leaked into dispatch opts"
      end
    end

    test "an unknown opt is forwarded to the adapter untouched" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.transcribe(engine, clip(), request_timeout: 1234, provider_knob: :on)

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_timeout) == 1234
      assert Keyword.get(opts, :provider_knob) == :on
    end

    test "stream: true is silently dropped" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.transcribe(engine, clip(), stream: true)

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
    end

    test "no :retry_policy key leaks into the dispatch opts" do
      engine = fake_engine()
      assert {:ok, _} = ALLM.transcribe(engine, clip())
      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :retry_policy)
    end

    test "opts[:request_id] wins over the generated id and reaches the adapter" do
      engine = fake_engine()

      assert {:ok, %TranscriptionResponse{request_id: "rid-explicit"}} =
               ALLM.transcribe(engine, clip(), request_id: "rid-explicit")

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_id) == "rid-explicit"
    end

    test "a generated request_id is filled when the adapter leaves it nil" do
      scripted = %TranscriptionResponse{text: "t"}
      engine = fake_engine(adapter_opts: [transcription_script: [{:ok, scripted}]])

      assert {:ok, %TranscriptionResponse{request_id: "rid-fill"}} =
               ALLM.transcribe(engine, clip(), request_id: "rid-fill")
    end

    test "an adapter-populated request_id is preserved" do
      engine = Engine.new(transcription_adapter: ProviderRequestIdAdapter)

      assert {:ok, %TranscriptionResponse{request_id: "provider-rid"}} =
               ALLM.transcribe(engine, clip(), request_id: "rid-fill")
    end

    test "engine adapter_opts win over call-site adapter_opts on collision" do
      engine = fake_engine(adapter_opts: [tag: :engine])

      assert {:ok, _} = ALLM.transcribe(engine, clip(), adapter_opts: [tag: :call, extra: 1])

      assert [%{opts: opts}] = captured_calls()
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)
      assert Keyword.get(adapter_opts, :tag) == :engine
      assert Keyword.get(adapter_opts, :extra) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — model resolution (per-slot, never engine.model)
  # ---------------------------------------------------------------------------

  describe "transcribe/3 model resolution" do
    test "engine.transcription_model fills a nil request.model" do
      engine = fake_engine(transcription_model: "stt-slot")

      assert {:ok, %TranscriptionResponse{model: "stt-slot"}} = ALLM.transcribe(engine, clip())
      assert [%{request: %TranscriptionRequest{model: "stt-slot"}}] = captured_calls()
    end

    test "a set request.model wins over engine.transcription_model" do
      engine = fake_engine(transcription_model: "stt-slot")
      request = TranscriptionRequest.new(audio: clip(), model: "stt-explicit")

      assert {:ok, _} = ALLM.transcribe(engine, request)
      assert [%{request: %TranscriptionRequest{model: "stt-explicit"}}] = captured_calls()
    end

    test "engine.model (the chat model) never reaches the transcription adapter" do
      engine = fake_engine(model: "chat-x")

      assert {:ok, _} = ALLM.transcribe(engine, clip())
      assert [%{request: %TranscriptionRequest{model: nil}}] = captured_calls()
    end

    test "opts[:model] on the %Audio{} shape lands on the request and beats the slot" do
      engine = fake_engine(transcription_model: "stt-slot")

      assert {:ok, _} = ALLM.transcribe(engine, clip(), model: "stt-opt")
      assert [%{request: %TranscriptionRequest{model: "stt-opt"}}] = captured_calls()
    end

    test "opts[:model] is ignored for a pre-built request" do
      engine = fake_engine(transcription_model: "stt-slot")
      request = TranscriptionRequest.new(audio: clip())

      assert {:ok, _} = ALLM.transcribe(engine, request, model: "stt-opt")
      assert [%{request: %TranscriptionRequest{model: "stt-slot"}}] = captured_calls()
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — retry and invariant enforcement
  # ---------------------------------------------------------------------------

  describe "transcribe/3 retry" do
    test "a :rate_limited error retries and then succeeds" do
      engine =
        fake_engine(
          retry: @fast_retry,
          adapter_opts: FakeAudioFixtures.transcription_retry_until_call(2, "done")
        )

      assert {:ok, %TranscriptionResponse{text: "done"}} = ALLM.transcribe(engine, clip())
      assert length(captured_calls()) == 2
    end

    test "the default budget caps an always-failing upload at 3 attempts" do
      err = TranscriptionAdapterError.new(:provider_unavailable, retry_after_ms: 0)
      script = [{:error, err}, {:error, err}, {:error, err}]
      engine = fake_engine(retry: @fast_retry, adapter_opts: [transcription_script: script])

      assert {:error, %TranscriptionAdapterError{reason: :provider_unavailable}} =
               ALLM.transcribe(engine, clip())

      assert length(captured_calls()) == 3
    end

    test ":invalid_request is NOT retried" do
      err = TranscriptionAdapterError.new(:invalid_request, message: "nope")
      engine = fake_engine(adapter_opts: [transcription_script: [{:error, err}]])

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               ALLM.transcribe(engine, clip())

      assert length(captured_calls()) == 1
    end

    test ":content_filter is NOT retried" do
      err = TranscriptionAdapterError.new(:content_filter, message: "blocked")
      engine = fake_engine(adapter_opts: [transcription_script: [{:error, err}]])

      assert {:error, %TranscriptionAdapterError{reason: :content_filter}} =
               ALLM.transcribe(engine, clip())

      assert length(captured_calls()) == 1
    end

    test "a positive retry_after_ms is honoured as the retry delay" do
      TelemetryCapture.attach([[:allm, :adapter, :retry]])
      on_exit(&TelemetryCapture.detach/0)
      err = TranscriptionAdapterError.new(:rate_limited, retry_after_ms: 50)

      engine =
        fake_engine(
          retry: @fast_retry,
          adapter_opts: [transcription_script: [{:error, err}, {:ok, "done"}]]
        )

      assert {:ok, %TranscriptionResponse{text: "done"}} = ALLM.transcribe(engine, clip())
      # `@fast_retry` backs off 1 ms with no jitter, so a 50 ms delay can only
      # come from the error's `retry_after_ms`.
      assert [{[:allm, :adapter, :retry], _, %{delay_ms: 50}}] = TelemetryCapture.events()
    end

    test "each of the four retryable reasons is retried" do
      for reason <- [:rate_limited, :provider_unavailable, :timeout, :network_error] do
        err = TranscriptionAdapterError.new(reason, retry_after_ms: 0)

        engine =
          fake_engine(
            retry: @fast_retry,
            adapter_opts: [transcription_script: [{:error, err}, {:ok, "done"}]]
          )

        assert {:ok, %TranscriptionResponse{text: "done"}} = ALLM.transcribe(engine, clip()),
               "#{reason} was not retried"

        assert length(captured_calls()) == 2
      end
    end

    test "an adapter returning a bare struct raises ArgumentError naming the adapter and invariant 1" do
      engine = Engine.new(transcription_adapter: BareMapAdapter)

      assert_raise ArgumentError, ~r/BareMapAdapter.*invariant 1/s, fn ->
        ALLM.transcribe(engine, clip())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # transcribe/3 — cursor isolation
  # ---------------------------------------------------------------------------

  describe "transcribe/3 cursor" do
    test "the engine :id is injected as adapter_opts[:cursor_key]" do
      engine = fake_engine(id: 434_343)

      assert {:ok, _} = ALLM.transcribe(engine, clip())
      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:cursor_key) == 434_343
    end

    test "two content-equal engines with distinct ids read independent cursors" do
      script = [transcription_script: [{:ok, "first"}, {:ok, "second"}]]
      a = Engine.new(transcription_adapter: FakeTranscription, adapter_opts: script, id: 111_111)
      b = Engine.new(transcription_adapter: FakeTranscription, adapter_opts: script, id: 222_222)

      assert {:ok, %TranscriptionResponse{text: "first"}} = ALLM.transcribe(a, clip())
      # Falsifier: a shared cursor hands engine B entry 2.
      assert {:ok, %TranscriptionResponse{text: "first"}} = ALLM.transcribe(b, clip())
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "transcribe/3 telemetry" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :transcribe, :start],
          [:allm, :transcribe, :stop],
          [:allm, :transcribe, :exception]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":start and :stop carry the documented keys on success" do
      engine =
        fake_engine(
          transcription_model: "stt-slot",
          model: "chat-x",
          adapter_opts: FakeAudioFixtures.transcript("héllo wörld")
        )

      assert {:ok, resp} = ALLM.transcribe(engine, clip(), request_id: "rid-t")

      assert [
               {[:allm, :transcribe, :start], _start_m, start_md},
               {[:allm, :transcribe, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-t"
      assert start_md.engine == engine
      assert start_md.model == "stt-slot"
      assert start_md.audio_mime == "audio/mpeg"

      assert is_integer(stop_m.duration)
      assert stop_m.text_length == String.length("héllo wörld")
      assert stop_md.response == resp
      assert stop_md.usage == resp.usage
      assert stop_md.error == nil
    end

    test ":start fires when the adapter is missing; :stop carries the error and zero length" do
      assert {:error, %EngineError{}} = ALLM.transcribe(Engine.new(), clip())

      assert [
               {[:allm, :transcribe, :start], _, _},
               {[:allm, :transcribe, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert stop_m.text_length == 0
      assert %EngineError{reason: :no_transcription_adapter} = stop_md.error
      assert stop_md.response == nil
      assert Map.has_key?(stop_md, :usage)
    end

    test ":start fires on an invalid request with a non-%Audio{} :audio without raising" do
      engine = fake_engine()

      for bad <- [nil, "raw bytes", %{mime_type: "audio/mpeg"}] do
        request = %TranscriptionRequest{TranscriptionRequest.new() | audio: bad}
        assert {:error, %ValidationError{}} = ALLM.transcribe(engine, request)
      end

      starts = for {[:allm, :transcribe, :start], _, md} <- TelemetryCapture.events(), do: md
      assert length(starts) == 3
      assert Enum.all?(starts, &(&1.audio_mime == nil))
    end

    test ":start audio_mime is nil for an %Audio{} with no mime type" do
      engine = fake_engine()
      audio = %Audio{clip() | mime_type: nil}
      assert {:ok, _} = ALLM.transcribe(engine, audio)

      assert [{[:allm, :transcribe, :start], _, start_md} | _] = TelemetryCapture.events()
      assert start_md.audio_mime == nil
    end

    test "a Fake-generated error (provider: nil) reaches :stop without raising" do
      engine =
        fake_engine(retry: false, adapter_opts: [transcription_script: [{:retry_until_call, 2}]])

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, provider: nil}} =
               ALLM.transcribe(engine, clip())

      assert [_, {[:allm, :transcribe, :stop], %{text_length: 0}, %{error: err}}] =
               TelemetryCapture.events()

      assert err.provider == nil
    end

    test "a response whose text is not a binary reports text_length 0 instead of raising" do
      scripted = %TranscriptionResponse{text: nil}
      engine = fake_engine(adapter_opts: [transcription_script: [{:ok, scripted}]])

      assert {:ok, _} = ALLM.transcribe(engine, clip())

      assert [_, {[:allm, :transcribe, :stop], %{text_length: 0}, _}] =
               TelemetryCapture.events()
    end

    test ":exception fires when the adapter raises" do
      engine = Engine.new(transcription_adapter: RaisingAdapter)

      assert_raise RuntimeError, "boom", fn -> ALLM.transcribe(engine, clip()) end

      assert [
               {[:allm, :transcribe, :start], _, _},
               {[:allm, :transcribe, :exception], _, md}
             ] = TelemetryCapture.events()

      assert %RuntimeError{message: "boom"} = md.reason
    end
  end
end
