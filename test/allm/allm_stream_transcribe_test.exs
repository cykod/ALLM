defmodule ALLM.ALLMStreamTranscribeTest do
  @moduledoc """
  Layer-C `ALLM.stream_transcribe/3` over `ALLM.Providers.FakeTranscription`
  and test-local stream adapters.

  Rows mirror the `transcribe/3` façade matrix: input shapes, gate order
  (alone and combined), model resolution (which, unlike every other audio
  façade, never reads the engine's slot model), opts plumbing, cursor
  isolation, laziness, the wrapper's invariant checks, and telemetry.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which records only
  events fired in the test's own process.
  """

  use ExUnit.Case, async: true

  doctest ALLM, only: [stream_transcribe: 3]

  alias ALLM.{AudioStream, Engine, TranscriptionEvent, TranscriptionStreamRequest, Usage}
  alias ALLM.Error.{EngineError, TranscriptionAdapterError, ValidationError}
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Test.{FakeAudioFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Test-local adapters
  # ---------------------------------------------------------------------------

  defmodule BatchOnlyAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionAdapter

    @impl ALLM.TranscriptionAdapter
    def transcribe(%ALLM.TranscriptionRequest{}, _opts),
      do: {:error, TranscriptionAdapterError.new(:unknown)}

    @impl ALLM.TranscriptionAdapter
    def max_audio_bytes, do: 1
  end

  defmodule ProbeAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionStreamAdapter

    # Streams `adapter_opts[:events]` through a `Stream.resource/3` that
    # reports `:started` / `:cleaned_up` to `adapter_opts[:probe]`.
    @impl ALLM.TranscriptionStreamAdapter
    def stream_sample_rates, do: [16_000]

    @impl ALLM.TranscriptionStreamAdapter
    def stream_transcribe(%ALLM.TranscriptionStreamRequest{}, _input, opts) do
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)
      probe = Keyword.fetch!(adapter_opts, :probe)
      events = Keyword.fetch!(adapter_opts, :events)

      stream =
        Stream.resource(
          fn ->
            send(probe, :started)
            events
          end,
          fn
            [] -> {:halt, []}
            [event | rest] -> {[event], rest}
          end,
          fn _ -> send(probe, :cleaned_up) end
        )

      {:ok, stream}
    end
  end

  defmodule BareReturnAdapter do
    @moduledoc false
    @behaviour ALLM.TranscriptionStreamAdapter

    @impl ALLM.TranscriptionStreamAdapter
    def stream_sample_rates, do: [16_000]

    # Deliberately non-conforming: a bare error struct.
    @impl ALLM.TranscriptionStreamAdapter
    def stream_transcribe(_request, _input, _opts),
      do: TranscriptionAdapterError.new(:unknown)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @pcm FakeAudioFixtures.pcm_silence(3_200)

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

  defp probe_engine(events) do
    Engine.new(transcription_adapter: ProbeAdapter, adapter_opts: [probe: self(), events: events])
  end

  defp captured_calls(acc \\ []) do
    receive do
      {FakeTranscription, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp happy_events do
    [
      TranscriptionEvent.transcription_started(%{
        request_id: nil,
        model: "rt-model",
        provider: :probe,
        session_id: nil
      }),
      TranscriptionEvent.partial_transcript("hi"),
      TranscriptionEvent.committed_transcript("hi"),
      TranscriptionEvent.transcription_completed(%{
        text: "hi",
        language: nil,
        duration_seconds: nil,
        request_id: nil,
        usage: %Usage{},
        metadata: %{}
      })
    ]
  end

  # One valid, non-default value per `TranscriptionStreamRequest` field.
  @field_values %{
    model: "rt-x",
    language: "en",
    sample_rate: 8_000,
    commit_strategy: :manual,
    timestamps: true,
    logprobs: true,
    options: %{"k" => 1},
    metadata: %{"t" => 1}
  }

  # ---------------------------------------------------------------------------
  # Input shapes
  # ---------------------------------------------------------------------------

  describe "input shapes" do
    test "the request is built from the field opts" do
      engine = fake_engine(adapter_opts: FakeAudioFixtures.transcript("hello there"))

      assert {:ok, events} =
               ALLM.stream_transcribe(engine, Stream.map([@pcm], & &1),
                 language: "en",
                 sample_rate: 16_000
               )

      assert {:ok, %{text: "hello there"}} = AudioStream.collect_transcription(events)

      assert [%{request: %TranscriptionStreamRequest{language: "en", sample_rate: 16_000}}] =
               captured_calls()
    end

    test "opts[:request] is authoritative" do
      request = TranscriptionStreamRequest.new(language: "de", sample_rate: 8_000)

      assert {:ok, _} =
               ALLM.stream_transcribe(fake_engine(), [@pcm], request: request, language: "en")

      assert [%{request: ^request, opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :language)
      refute Keyword.has_key?(opts, :request)
    end

    test "a non-TranscriptionStreamRequest opts[:request] raises ArgumentError naming the opt" do
      batch =
        ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_binary("secret-bytes", "audio/wav"))

      error =
        assert_raise ArgumentError, fn ->
          ALLM.stream_transcribe(fake_engine(), [@pcm], request: batch)
        end

      assert error.message =~ "opts[:request] must be a %ALLM.TranscriptionStreamRequest{}"
      assert error.message =~ "got: %ALLM.TranscriptionRequest{}"
      refute error.message =~ "secret-bytes"
      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Gate order
  # ---------------------------------------------------------------------------

  describe "gate order" do
    test "a nil slot gives :no_transcription_adapter" do
      assert {:error, %EngineError{reason: :no_transcription_adapter}} =
               ALLM.stream_transcribe(Engine.new(), [@pcm])
    end

    test "a slot with only transcribe/2 gives :missing_stream_adapter, not UndefinedFunctionError" do
      assert {:error, %EngineError{reason: :missing_stream_adapter} = err} =
               ALLM.stream_transcribe(Engine.new(transcription_adapter: BatchOnlyAdapter), [@pcm])

      assert err.message =~ "stream_transcribe/3"
    end

    test "an invalid request gives a ValidationError before dispatch" do
      assert {:error, %ValidationError{reason: :invalid_transcription_request} = err} =
               ALLM.stream_transcribe(fake_engine(), [@pcm], commit_strategy: :bogus)

      assert {:commit_strategy, :unknown} in err.errors
      assert captured_calls() == []
    end

    test "a nil slot wins over an invalid request, and a missing callback does too" do
      assert {:error, %EngineError{reason: :no_transcription_adapter}} =
               ALLM.stream_transcribe(Engine.new(), [@pcm], sample_rate: -1)

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               ALLM.stream_transcribe(
                 Engine.new(transcription_adapter: BatchOnlyAdapter),
                 [@pcm],
                 sample_rate: -1
               )
    end

    test "a non-enumerable input gives the input-shape ValidationError on a streaming slot" do
      for input <- ["pcm-bytes", 42] do
        assert {:error, %ValidationError{reason: :invalid_transcription_request} = err} =
                 ALLM.stream_transcribe(fake_engine(), input, [])

        assert {:input, :invalid_shape} in err.errors
      end

      assert captured_calls() == []
    end

    test "the slot gates win over a non-enumerable input" do
      assert {:error, %EngineError{reason: :no_transcription_adapter}} =
               ALLM.stream_transcribe(Engine.new(), "pcm-bytes")

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               ALLM.stream_transcribe(
                 Engine.new(transcription_adapter: BatchOnlyAdapter),
                 "pcm-bytes"
               )
    end

    test "the input-shape gate wins over an invalid request" do
      assert {:error, %ValidationError{errors: [{:input, :invalid_shape}]}} =
               ALLM.stream_transcribe(fake_engine(), 42, sample_rate: -1)
    end

    test "the adapter's own gate returns synchronously and is not retried" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               ALLM.stream_transcribe(fake_engine(), [@pcm], sample_rate: 44_100)

      assert err.metadata.sample_rate == 44_100
      assert length(captured_calls()) == 1
    end

    test "a retryable error is not retried: one adapter call, the error ends the stream" do
      engine =
        fake_engine(
          retry: [base_delay_ms: 1, max_delay_ms: 1, jitter_ms: 0],
          adapter_opts: FakeAudioFixtures.transcription_retry_until_call(2, "late")
        )

      assert {:ok, events} = ALLM.stream_transcribe(engine, [@pcm])
      assert [{:error, %TranscriptionAdapterError{reason: :rate_limited}}] = Enum.to_list(events)
      assert length(captured_calls()) == 1
    end

    test "an adapter returning a bare error struct raises ArgumentError naming it and invariant 1" do
      assert_raise ArgumentError,
                   ~r/BareReturnAdapter.*TranscriptionStreamAdapter invariant 1/s,
                   fn ->
                     ALLM.stream_transcribe(
                       Engine.new(transcription_adapter: BareReturnAdapter),
                       [@pcm]
                     )
                   end
    end
  end

  # ---------------------------------------------------------------------------
  # Model resolution
  # ---------------------------------------------------------------------------

  describe "model resolution" do
    test "engine.transcription_model is never stamped onto the request" do
      engine = fake_engine(transcription_model: "scribe_v2")

      assert {:ok, _} = ALLM.stream_transcribe(engine, [@pcm])
      # Falsifier: "scribe_v2" (a batch model) reaching the adapter.
      assert [%{request: %TranscriptionStreamRequest{model: nil}}] = captured_calls()
    end

    test "a set request.model reaches the adapter" do
      engine = fake_engine(transcription_model: "scribe_v2")

      assert {:ok, _} = ALLM.stream_transcribe(engine, [@pcm], model: "scribe_v2_realtime")

      assert [%{request: %TranscriptionStreamRequest{model: "scribe_v2_realtime"}}] =
               captured_calls()
    end
  end

  # ---------------------------------------------------------------------------
  # Opts
  # ---------------------------------------------------------------------------

  describe "opts" do
    test "every TranscriptionStreamRequest field is reachable through the allow-list" do
      # Symmetry invariant computed from `Map.keys/1`. The struct has no
      # positional field, so every field must be reachable.
      fields = %TranscriptionStreamRequest{} |> Map.from_struct() |> Map.keys()

      for field <- fields do
        assert Map.has_key?(@field_values, field),
               "add a valid value for TranscriptionStreamRequest.#{field} to @field_values"

        value = Map.fetch!(@field_values, field)
        assert {:ok, _} = ALLM.stream_transcribe(fake_engine(), [@pcm], [{field, value}])

        assert [%{request: request, opts: opts}] = captured_calls()
        assert Map.fetch!(request, field) == value, "#{inspect(field)} did not reach the request"
        refute Keyword.has_key?(opts, field), "#{inspect(field)} leaked into the dispatch opts"
      end
    end

    test "stream: true is dropped; request_id and other opts are forwarded" do
      assert {:ok, events} =
               ALLM.stream_transcribe(fake_engine(), [@pcm],
                 stream: true,
                 stream_timeout: 321,
                 request_id: "rid-x"
               )

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
      refute Keyword.has_key?(opts, :retry_policy)
      assert Keyword.get(opts, :stream_timeout) == 321
      assert Keyword.get(opts, :request_id) == "rid-x"

      assert {:ok, %{request_id: "rid-x"}} = AudioStream.collect_transcription(events)
    end

    test "timestamps: true reaches the adapter on the request and the collected spans are timed" do
      engine = fake_engine(adapter_opts: FakeAudioFixtures.transcript("quick fox"))

      assert {:ok, events} = ALLM.stream_transcribe(engine, [@pcm], timestamps: true)

      assert [%{request: %TranscriptionStreamRequest{timestamps: true, logprobs: false}}] =
               captured_calls()

      assert {:ok, %{spans: spans}} = AudioStream.collect_transcription(events)

      assert [
               %ALLM.TranscriptSpan{
                 text: "quick",
                 start_seconds: +0.0,
                 end_seconds: 0.5,
                 logprob: nil
               },
               %ALLM.TranscriptSpan{text: "fox", start_seconds: 0.5, end_seconds: 1.0, logprob: nil}
             ] = spans
    end

    test "two content-equal engines with distinct ids read independent cursors" do
      script = [transcription_script: [{:ok, "first"}, {:ok, "second"}]]
      a = Engine.new(transcription_adapter: FakeTranscription, adapter_opts: script, id: 111_111)
      b = Engine.new(transcription_adapter: FakeTranscription, adapter_opts: script, id: 222_222)

      assert {:ok, ea} = ALLM.stream_transcribe(a, [@pcm])
      assert {:ok, eb} = ALLM.stream_transcribe(b, [@pcm])

      # Falsifier: a shared cursor hands engine B entry 2.
      assert {:ok, %{text: "first"}} = AudioStream.collect_transcription(ea)
      assert {:ok, %{text: "first"}} = AudioStream.collect_transcription(eb)
    end
  end

  # ---------------------------------------------------------------------------
  # Laziness and the wrapper
  # ---------------------------------------------------------------------------

  describe "laziness and the wrapper" do
    test "stream_transcribe/3 returns before any adapter I/O" do
      assert {:ok, events} = ALLM.stream_transcribe(probe_engine(happy_events()), [@pcm])
      refute_received :started

      assert [{:transcription_started, _}] = Enum.take(events, 1)
      assert_received :started
      assert_received :cleaned_up
    end

    test "an element outside the TranscriptionEvent union raises naming the adapter and invariant 3" do
      events = [hd(happy_events()), {:audio_delta, "pcm"}]
      assert {:ok, stream} = ALLM.stream_transcribe(probe_engine(events), [@pcm])

      assert_raise ArgumentError, ~r/ProbeAdapter.*invariant 3/s, fn -> Enum.to_list(stream) end
      assert_received :cleaned_up
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :stream_transcribe, :start],
          [:allm, :stream_transcribe, :stop],
          [:allm, :stream_transcribe, :exception],
          [:allm, :audio, :first_chunk]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":start and :stop carry the documented keys" do
      engine = fake_engine(transcription_model: "scribe_v2")

      assert {:ok, _} =
               ALLM.stream_transcribe(engine, [@pcm], request_id: "rid-t", sample_rate: 8_000)

      assert [
               {[:allm, :stream_transcribe, :start], _, start_md},
               {[:allm, :stream_transcribe, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-t"
      assert start_md.engine == engine
      assert start_md.model == nil
      assert start_md.sample_rate == 8_000
      assert is_integer(stop_m.duration)
      assert stop_md.response == nil
    end

    test "the span fires on a gate failure too" do
      assert {:error, %EngineError{}} = ALLM.stream_transcribe(Engine.new(), [@pcm])

      assert [
               {[:allm, :stream_transcribe, :start], _, _},
               {[:allm, :stream_transcribe, :stop], _, %{response: nil}}
             ] = TelemetryCapture.events()
    end

    test ":first_chunk fires exactly once, at the first partial, with a positive latency" do
      engine = fake_engine(adapter_opts: FakeAudioFixtures.transcript("one two three"))

      assert {:ok, events} = ALLM.stream_transcribe(engine, [@pcm], request_id: "rid-f")
      assert length(for({:partial_transcript, _} <- events, do: :p)) == 3

      assert [{[:allm, :audio, :first_chunk], measurements, metadata}] =
               for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)

      assert measurements.latency > 0
      assert metadata == %{request_id: "rid-f", capability: :transcription, provider_model: nil}
    end

    test ":first_chunk reports the model from :transcription_started" do
      assert {:ok, events} = ALLM.stream_transcribe(probe_engine(happy_events()), [@pcm])
      assert {:ok, _} = AudioStream.collect_transcription(events)

      assert [{_, _, %{provider_model: "rt-model"}}] =
               for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)
    end

    test ":first_chunk does not fire on a stream that errors before any partial" do
      err = TranscriptionAdapterError.new(:provider_unavailable)
      engine = fake_engine(adapter_opts: [transcription_script: [{:error, err}]])

      assert {:ok, events} = ALLM.stream_transcribe(engine, [@pcm])
      assert [{:transcription_started, _}, {:error, ^err}] = Enum.to_list(events)

      assert [] =
               for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)
    end
  end
end
