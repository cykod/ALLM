defmodule ALLM.ALLMStreamSynthesizeTest do
  @moduledoc """
  Layer-C `ALLM.stream_synthesize/3` and `ALLM.stream_synthesize_input/3`
  over `ALLM.Providers.FakeSpeech` and test-local stream adapters.

  Rows mirror the `synthesize/3` façade matrix for both façades: input
  shapes, gate order (alone and combined), model resolution, opts plumbing,
  cursor isolation, laziness, the wrapper's invariant checks, and telemetry.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which records only
  events fired in the test's own process; a bare global handler attach in an
  `async: true` module would capture other tests' events.
  """

  use ExUnit.Case, async: true

  doctest ALLM, only: [stream_synthesize: 3, stream_synthesize_input: 3]

  alias ALLM.{AudioStream, Engine, SpeechEvent, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.{EngineError, SpeechAdapterError, ValidationError}
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Test.TelemetryCapture

  # ---------------------------------------------------------------------------
  # Test-local adapters
  # ---------------------------------------------------------------------------

  defmodule SynthesizeOnlyAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter

    # A Phase-25-style adapter: non-streaming only.
    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts),
      do: {:error, SpeechAdapterError.new(:unknown)}
  end

  defmodule WholeTextStreamAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter
    @behaviour ALLM.SpeechStreamAdapter

    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts),
      do: {:error, SpeechAdapterError.new(:unknown)}

    @impl ALLM.SpeechStreamAdapter
    def stream_synthesize(%ALLM.SpeechRequest{}, _opts), do: {:ok, []}
  end

  defmodule ProbeAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter
    @behaviour ALLM.SpeechStreamAdapter

    # Streams `adapter_opts[:events]` through a `Stream.resource/3` whose
    # start function sends `:started` and whose after function sends
    # `:cleaned_up` to `adapter_opts[:probe]`.
    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts),
      do: {:error, SpeechAdapterError.new(:unknown)}

    @impl ALLM.SpeechStreamAdapter
    def stream_synthesize(%ALLM.SpeechRequest{}, opts) do
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
    @behaviour ALLM.SpeechAdapter
    @behaviour ALLM.SpeechStreamAdapter

    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts),
      do: {:error, SpeechAdapterError.new(:unknown)}

    # Deliberately non-conforming: the enumerable is not wrapped in `{:ok, _}`.
    @impl ALLM.SpeechStreamAdapter
    def stream_synthesize(%ALLM.SpeechRequest{}, _opts), do: []
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fake_engine(opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [speech_adapter: FakeSpeech, adapter_opts: [capture_pid: self()] ++ adapter_opts],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  defp probe_engine(events) do
    Engine.new(speech_adapter: ProbeAdapter, adapter_opts: [probe: self(), events: events])
  end

  defp captured_calls(acc \\ []) do
    receive do
      {FakeSpeech, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp deltas(events), do: for({:audio_delta, bytes} <- events, do: bytes)

  defp happy_events do
    [
      SpeechEvent.speech_started(%{
        request_id: nil,
        model: "probe-model",
        provider: :probe,
        format: :pcm,
        mime_type: "audio/pcm",
        sample_rate: 24_000
      }),
      SpeechEvent.audio_delta("a"),
      SpeechEvent.speech_completed(%{request_id: nil, id: nil, usage: %Usage{}, metadata: %{}})
    ]
  end

  # One valid, non-default value per `SpeechRequest` field except `:input`.
  @speech_field_values %{
    model: "tts-x",
    voice: "alloy",
    format: :wav,
    instructions: "calm",
    speed: 1.5,
    sample_rate: 24_000,
    options: %{"k" => 1},
    metadata: %{"t" => 1}
  }

  # ---------------------------------------------------------------------------
  # Input shapes
  # ---------------------------------------------------------------------------

  describe "input shapes" do
    test "stream_synthesize/3 wraps a binary into a SpeechRequest" do
      assert {:ok, events} = ALLM.stream_synthesize(fake_engine(), "Hello.")
      assert IO.iodata_to_binary(deltas(events)) == "FAKE-AUDIO:Hello."
      assert [%{request: %SpeechRequest{input: "Hello."}}] = captured_calls()
    end

    test "stream_synthesize/3 dispatches a pre-built request verbatim, not merged with opts" do
      request = SpeechRequest.new(input: "Hi.", voice: "from-request")

      assert {:ok, _} = ALLM.stream_synthesize(fake_engine(), request, voice: "from-opts")
      assert [%{request: ^request}] = captured_calls()
    end

    test "stream_synthesize_input/3 takes an enumerable and builds the request from opts" do
      assert {:ok, events} =
               ALLM.stream_synthesize_input(fake_engine(), Stream.map(["a", "b"], & &1),
                 voice: "alloy",
                 format: :pcm
               )

      assert deltas(events) == ["FAKE-AUDIO:a", "FAKE-AUDIO:b"]
      assert [%{request: request}] = captured_calls()
      assert %SpeechRequest{input: "", voice: "alloy", format: :pcm} = request
    end

    test "stream_synthesize_input/3 treats opts[:request] as authoritative" do
      request = SpeechRequest.new(input: "ignored", voice: "from-request")

      assert {:ok, _} =
               ALLM.stream_synthesize_input(fake_engine(), ["a"],
                 request: request,
                 voice: "from-opts"
               )

      assert [%{request: dispatched, opts: opts}] = captured_calls()
      assert dispatched.voice == "from-request"
      refute Keyword.has_key?(opts, :voice)
      refute Keyword.has_key?(opts, :request)
    end

    test "stream_synthesize_input/3 raises ArgumentError on a non-SpeechRequest opts[:request]" do
      error =
        assert_raise ArgumentError, fn ->
          ALLM.stream_synthesize_input(fake_engine(), ["a"], request: %{voice: "v"})
        end

      assert error.message =~ "opts[:request] must be a %ALLM.SpeechRequest{}"
      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Gate order
  # ---------------------------------------------------------------------------

  describe "gate order" do
    test "a nil slot gives :no_speech_adapter from both façades" do
      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.stream_synthesize(Engine.new(), "x")

      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.stream_synthesize_input(Engine.new(), ["x"])
    end

    test "a slot with only synthesize/2 gives :missing_stream_adapter, not UndefinedFunctionError" do
      engine = Engine.new(speech_adapter: SynthesizeOnlyAdapter)

      assert {:error, %EngineError{reason: :missing_stream_adapter} = err} =
               ALLM.stream_synthesize(engine, "x")

      assert err.message =~ "stream_synthesize/2"

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               ALLM.stream_synthesize_input(engine, ["x"])
    end

    test "a slot that streams whole texts only gives :missing_stream_adapter from the input form" do
      engine = Engine.new(speech_adapter: WholeTextStreamAdapter)

      assert {:ok, _} = ALLM.stream_synthesize(engine, "x")

      assert {:error, %EngineError{reason: :missing_stream_adapter} = err} =
               ALLM.stream_synthesize_input(engine, ["x"])

      assert err.message =~ "stream_synthesize_input/3"
      assert err.message =~ "whole texts only"
    end

    test "an invalid request gives a ValidationError before dispatch" do
      engine = fake_engine()

      assert {:error, %ValidationError{reason: :invalid_speech_request} = err} =
               ALLM.stream_synthesize(engine, "")

      assert {:input, :empty} in err.errors

      assert {:error, %ValidationError{reason: :invalid_speech_request} = err} =
               ALLM.stream_synthesize_input(engine, ["x"], format: :bogus)

      assert {:format, :unknown} in err.errors
      assert captured_calls() == []
    end

    test "the input form accepts an empty request input (it is ignored)" do
      assert {:ok, _} = ALLM.stream_synthesize_input(fake_engine(), ["x"])
    end

    test "a nil slot wins over an invalid request" do
      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.stream_synthesize(Engine.new(), "")

      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.stream_synthesize_input(Engine.new(), ["x"], format: :bogus)
    end

    test "a missing stream callback wins over an invalid request" do
      engine = Engine.new(speech_adapter: SynthesizeOnlyAdapter)

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               ALLM.stream_synthesize(engine, "")
    end

    test "a non-enumerable input gives the input-shape ValidationError on a streaming slot" do
      engine = fake_engine()

      for input <- [42, "a whole string", nil] do
        assert {:error, %ValidationError{reason: :invalid_speech_request} = err} =
                 ALLM.stream_synthesize_input(engine, input)

        assert {:input, :invalid_shape} in err.errors
      end

      assert captured_calls() == []
    end

    test "the slot gates win over a non-enumerable input" do
      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.stream_synthesize_input(Engine.new(), 42)

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               ALLM.stream_synthesize_input(Engine.new(speech_adapter: WholeTextStreamAdapter), 42)
    end

    test "the input-shape gate wins over an invalid request" do
      assert {:error, %ValidationError{errors: [{:input, :invalid_shape}]}} =
               ALLM.stream_synthesize_input(fake_engine(), 42, format: :bogus)
    end

    test "an adapter's synchronous error is returned as-is" do
      engine = fake_engine(adapter_opts: [speech_script: [{:ok, "only"}]])
      assert {:ok, _} = ALLM.stream_synthesize(engine, "x")

      assert {:error, %SpeechAdapterError{metadata: %{cause: :speech_script_exhausted}}} =
               ALLM.stream_synthesize(engine, "x")
    end

    test "a retryable error is not retried: one adapter call, the error ends the stream" do
      engine =
        fake_engine(
          retry: [base_delay_ms: 1, max_delay_ms: 1, jitter_ms: 0],
          adapter_opts: [speech_script: [{:retry_until_call, 2}, {:ok, "late"}]]
        )

      assert {:ok, events} = ALLM.stream_synthesize(engine, "x")
      assert [{:error, %SpeechAdapterError{reason: :rate_limited}}] = Enum.to_list(events)
      assert length(captured_calls()) == 1
    end

    test "an adapter returning a bare enumerable raises ArgumentError naming it and invariant 1" do
      engine = Engine.new(speech_adapter: BareReturnAdapter)

      assert_raise ArgumentError, ~r/BareReturnAdapter.*SpeechStreamAdapter invariant 1/s, fn ->
        ALLM.stream_synthesize(engine, "x")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Model resolution
  # ---------------------------------------------------------------------------

  describe "model resolution" do
    test "engine.speech_model fills a nil request.model on both façades" do
      engine = fake_engine(speech_model: "tts-slot", model: "chat-x")

      assert {:ok, _} = ALLM.stream_synthesize(engine, "x")
      assert {:ok, _} = ALLM.stream_synthesize_input(engine, ["x"])

      assert [%{request: %{model: "tts-slot"}}, %{request: %{model: "tts-slot"}}] =
               captured_calls()
    end

    test "a set request.model wins over the slot, also through opts[:request]" do
      engine = fake_engine(speech_model: "tts-slot")

      assert {:ok, _} = ALLM.stream_synthesize(engine, "x", model: "tts-opt")

      assert {:ok, _} =
               ALLM.stream_synthesize_input(engine, ["x"],
                 request: SpeechRequest.new(model: "tts-req")
               )

      assert [%{request: %{model: "tts-opt"}}, %{request: %{model: "tts-req"}}] =
               captured_calls()
    end

    test "engine.model (the chat model) never reaches the speech adapter" do
      engine = fake_engine(model: "chat-x")

      assert {:ok, _} = ALLM.stream_synthesize(engine, "x")
      assert {:ok, _} = ALLM.stream_synthesize_input(engine, ["x"])
      assert [%{request: %{model: nil}}, %{request: %{model: nil}}] = captured_calls()
    end
  end

  # ---------------------------------------------------------------------------
  # Opts
  # ---------------------------------------------------------------------------

  describe "opts" do
    test "every SpeechRequest field except :input is reachable through both façades" do
      # Symmetry invariant computed from `Map.keys/1`: a field added to the
      # struct without an entry in the value table, or without an allow-list
      # entry, goes red here.
      fields = %SpeechRequest{} |> Map.from_struct() |> Map.keys() |> Kernel.--([:input])

      for field <- fields do
        assert Map.has_key?(@speech_field_values, field),
               "add a valid value for SpeechRequest.#{field} to @speech_field_values"

        opts = [{field, Map.fetch!(@speech_field_values, field)}]
        assert {:ok, _} = ALLM.stream_synthesize(fake_engine(), "x", opts)
        assert {:ok, _} = ALLM.stream_synthesize_input(fake_engine(), ["x"], opts)

        for %{request: request, opts: dispatch_opts} <- captured_calls() do
          assert Map.fetch!(request, field) == Map.fetch!(@speech_field_values, field),
                 "#{inspect(field)} did not reach the request"

          refute Keyword.has_key?(dispatch_opts, field),
                 "#{inspect(field)} leaked into the dispatch opts"
        end
      end
    end

    test "stream: true is dropped and other opts are forwarded" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.stream_synthesize(engine, "x", stream: true, stream_timeout: 123)
      assert {:ok, _} = ALLM.stream_synthesize_input(engine, ["x"], stream: true, knob: :on)

      assert [%{opts: a}, %{opts: b}] = captured_calls()
      refute Keyword.has_key?(a, :stream)
      refute Keyword.has_key?(b, :stream)
      assert Keyword.get(a, :stream_timeout) == 123
      assert Keyword.get(b, :knob) == :on
      refute Keyword.has_key?(a, :retry_policy)
    end

    test "opts[:request_id] reaches the adapter and both envelope events" do
      assert {:ok, events} = ALLM.stream_synthesize(fake_engine(), "x", request_id: "rid-s")
      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_id) == "rid-s"

      assert [{:speech_started, %{request_id: "rid-s"}} | _] = Enum.to_list(events)
      assert {:ok, %SpeechResponse{request_id: "rid-s"}} = AudioStream.collect_speech(events)
    end

    test "two content-equal engines with distinct ids read independent cursors" do
      script = [speech_script: [{:ok, "first"}, {:ok, "second"}]]
      a = Engine.new(speech_adapter: FakeSpeech, adapter_opts: script, id: 111_111)
      b = Engine.new(speech_adapter: FakeSpeech, adapter_opts: script, id: 222_222)

      assert {:ok, ea} = ALLM.stream_synthesize(a, "x")
      assert {:ok, eb} = ALLM.stream_synthesize(b, "x")

      # Falsifier: a shared cursor hands engine B entry 2.
      assert deltas(ea) == ["first"]
      assert deltas(eb) == ["first"]
    end
  end

  # ---------------------------------------------------------------------------
  # Laziness and the wrapper
  # ---------------------------------------------------------------------------

  describe "laziness and the wrapper" do
    test "stream_synthesize/3 returns before any adapter I/O" do
      assert {:ok, events} = ALLM.stream_synthesize(probe_engine(happy_events()), "x")
      refute_received :started

      assert [{:speech_started, _}] = Enum.take(events, 1)
      assert_received :started
      assert_received :cleaned_up
    end

    test "an element outside the SpeechEvent union raises naming the adapter and invariant 3" do
      events = [hd(happy_events()), {:text_delta, %{id: nil, delta: "hi"}}]
      assert {:ok, stream} = ALLM.stream_synthesize(probe_engine(events), "x")

      assert_raise ArgumentError, ~r/ProbeAdapter.*invariant 3/s, fn -> Enum.to_list(stream) end
    end

    test "the inner stream's after function still runs when the invariant-3 raise fires" do
      assert {:ok, stream} =
               ALLM.stream_synthesize(probe_engine([{:text_delta, %{id: nil, delta: "x"}}]), "x")

      assert_raise ArgumentError, fn -> Enum.to_list(stream) end
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
          [:allm, :stream_synthesize, :start],
          [:allm, :stream_synthesize, :stop],
          [:allm, :stream_synthesize, :exception],
          [:allm, :audio, :first_chunk]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test "stream_synthesize/3 :start and :stop carry the documented keys" do
      engine = fake_engine(speech_model: "tts-slot")

      assert {:ok, _} = ALLM.stream_synthesize(engine, "Héllo", request_id: "rid-t")

      assert [
               {[:allm, :stream_synthesize, :start], _, start_md},
               {[:allm, :stream_synthesize, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-t"
      assert start_md.engine == engine
      assert start_md.model == "tts-slot"
      assert start_md.input_length == 5
      assert is_integer(stop_m.duration)
      assert stop_md.response == nil
    end

    test "stream_synthesize_input/3 shares the :stream_synthesize span with input_length nil" do
      assert {:ok, _} = ALLM.stream_synthesize_input(fake_engine(), ["x"], request_id: "rid-i")

      assert [
               {[:allm, :stream_synthesize, :start], _, start_md},
               {[:allm, :stream_synthesize, :stop], _, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-i"
      assert start_md.input_length == nil
      assert stop_md.response == nil
    end

    test "the span fires on a gate failure too" do
      assert {:error, %EngineError{}} = ALLM.stream_synthesize(Engine.new(), "x")

      assert [
               {[:allm, :stream_synthesize, :start], _, _},
               {[:allm, :stream_synthesize, :stop], _, %{response: nil}}
             ] = TelemetryCapture.events()
    end

    test ":first_chunk fires exactly once on a 3-delta stream, with a positive latency" do
      engine = fake_engine(speech_model: "tts-slot", adapter_opts: [chunk_bytes: 6])

      assert {:ok, events} = ALLM.stream_synthesize(engine, "abcdefg", request_id: "rid-f")
      # "FAKE-AUDIO:abcdefg" is 18 bytes: three 6-byte deltas.
      assert length(deltas(events)) == 3

      assert [{[:allm, :audio, :first_chunk], measurements, metadata}] =
               for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)

      assert measurements.latency > 0
      assert metadata == %{request_id: "rid-f", capability: :speech, provider_model: "tts-slot"}
    end

    test ":first_chunk fires once per stream on the input form too" do
      assert {:ok, events} = ALLM.stream_synthesize_input(fake_engine(), ["a", "b", "c"])
      assert length(deltas(events)) == 3

      assert [_] =
               for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)
    end

    test ":first_chunk does not fire on a stream that errors before any delta" do
      err = SpeechAdapterError.new(:provider_unavailable)
      engine = fake_engine(adapter_opts: [speech_script: [{:error, err}]])

      assert {:ok, events} = ALLM.stream_synthesize(engine, "x")
      assert [{:speech_started, _}, {:error, ^err}] = Enum.to_list(events)

      assert [] = for({[:allm, :audio, :first_chunk], _, _} = e <- TelemetryCapture.events(), do: e)
    end
  end
end
