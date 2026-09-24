defmodule ALLM.ALLMSynthesizeTest do
  @moduledoc """
  Layer-C `ALLM.synthesize/3` and `ALLM.speech_request/2` over
  `ALLM.Providers.FakeSpeech`.

  Speech has no streaming counterpart, so there is no stream-equivalence
  property to write, exactly as for images, embeddings and moderation.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which filters by
  owner PID; a bare global handler attach in an `async: true` module would
  capture other tests' `[:allm, :synthesize, :*]` events.

  **Script arithmetic matters here.** A non-empty `:speech_script` that runs
  off the end returns `:speech_script_exhausted` rather than defaulting, so
  every scripted test below scripts exactly as many entries as it drives
  calls.
  """

  use ExUnit.Case, async: true

  doctest ALLM, only: [synthesize: 3, speech_request: 2]

  alias ALLM.{Audio, Engine, SpeechRequest, SpeechResponse}
  alias ALLM.Error.{EngineError, SpeechAdapterError, ValidationError}
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Test.{FakeAudioFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Inline non-conforming stubs — scope is this file only.
  # ---------------------------------------------------------------------------

  defmodule BareMapAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter

    # Deliberately non-conforming: the response struct bare rather than in an
    # `{:ok, _}` tuple — `ALLM.SpeechAdapter` invariant 1.
    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts), do: %ALLM.SpeechResponse{}
  end

  defmodule ProviderRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter

    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts) do
      {:ok,
       %ALLM.SpeechResponse{
         request_id: "provider-rid",
         audio: ALLM.Audio.from_binary("x", "audio/mpeg")
       }}
    end
  end

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour ALLM.SpeechAdapter

    @impl ALLM.SpeechAdapter
    def synthesize(%ALLM.SpeechRequest{}, _opts), do: raise("boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Default 3-attempt budget with the backoff collapsed, so retry tests do not
  # sleep 500 ms per attempt.
  @fast_retry [base_delay_ms: 1, max_delay_ms: 1, jitter_ms: 0]

  defp fake_engine(opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [speech_adapter: FakeSpeech, adapter_opts: [capture_pid: self()] ++ adapter_opts],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  defp captured_calls(acc \\ []) do
    receive do
      {FakeSpeech, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp audio_bytes(%SpeechResponse{audio: audio}) do
    {:ok, bytes} = Audio.to_binary(audio)
    bytes
  end

  # ---------------------------------------------------------------------------
  # speech_request/2
  # ---------------------------------------------------------------------------

  describe "speech_request/2" do
    test "wraps the input string" do
      req = ALLM.speech_request("Hello.")
      assert %SpeechRequest{input: "Hello."} = req
      assert req.model == nil
    end

    test "lifts request-field opts onto the struct" do
      req =
        ALLM.speech_request("x",
          model: "tts-1",
          voice: "alloy",
          format: :wav,
          instructions: "calm",
          speed: 1.5,
          options: %{a: 1},
          metadata: %{t: 1}
        )

      assert req.model == "tts-1"
      assert req.voice == "alloy"
      assert req.format == :wav
      assert req.instructions == "calm"
      assert req.speed == 1.5
      assert req.options == %{a: 1}
      assert req.metadata == %{t: 1}
    end

    test "ignores call-control opts that are not SpeechRequest fields" do
      req =
        ALLM.speech_request("x",
          request_id: "rid",
          request_timeout: 5_000,
          retry: false,
          adapter_opts: [foo: 1],
          api_key: "sk-nope",
          stream: true,
          input: "overridden?",
          totally_unknown: :whatever
        )

      assert req == SpeechRequest.new(input: "x")
    end

    test "every SpeechRequest field except :input is reachable through the allow-list" do
      # Symmetry invariant, computed from `Map.keys/1` — a field added to the
      # struct without an allow-list entry, or a typo'd entry, goes red here.
      # Direction NOT bound: an allow-listed non-field (it would raise
      # `KeyError` in the bare `struct!/2` the first time a caller passed it).
      # Binding that needs a `@doc false` accessor on the façade, which the
      # moderation sibling deliberately does not add either.
      struct_fields =
        %SpeechRequest{}
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--([:input])

      for field <- struct_fields do
        req = ALLM.speech_request("x", [{field, :__sentinel__}])

        assert Map.fetch!(req, field) == :__sentinel__,
               "#{inspect(field)} is a SpeechRequest field but is not reachable " <>
                 "through ALLM.speech_request/2's opts allow-list"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — input shapes
  # ---------------------------------------------------------------------------

  describe "synthesize/3 input shapes" do
    test "a binary is wrapped into a SpeechRequest" do
      engine = fake_engine()

      assert {:ok, %SpeechResponse{} = resp} = ALLM.synthesize(engine, "Hello.")
      assert audio_bytes(resp) == "FAKE-AUDIO:Hello."

      assert [%{request: %SpeechRequest{input: "Hello."}}] = captured_calls()
    end

    test "a pre-built request dispatches verbatim and is NOT merged with opts" do
      engine = fake_engine()
      request = SpeechRequest.new(input: "Hi.", voice: "from-request", metadata: %{from: :req})

      assert {:ok, _} =
               ALLM.synthesize(engine, request, voice: "from-opts", metadata: %{from: :opts})

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched == request
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — gates
  # ---------------------------------------------------------------------------

  describe "synthesize/3 gates" do
    test "an engine with no speech_adapter returns :no_speech_adapter" do
      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.synthesize(Engine.new(), "x")
    end

    test ":no_speech_adapter fires even when the request would also fail validation" do
      assert {:error, %EngineError{reason: :no_speech_adapter}} =
               ALLM.synthesize(Engine.new(), "")
    end

    test "an invalid request returns :invalid_speech_request before any adapter call" do
      engine = fake_engine()

      assert {:error, %ValidationError{reason: :invalid_speech_request} = err} =
               ALLM.synthesize(engine, "")

      assert {:input, :empty} in err.errors
      assert captured_calls() == []
    end

    test "a non-binary :input on a hand-built request is rejected without raising" do
      engine = fake_engine()
      request = %SpeechRequest{SpeechRequest.new() | input: 42}

      assert {:error, %ValidationError{reason: :invalid_speech_request} = err} =
               ALLM.synthesize(engine, request)

      assert err.errors == [{:input, :invalid_shape}]
      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — opts plumbing
  # ---------------------------------------------------------------------------

  describe "synthesize/3 opts" do
    test "request-field opts lift onto the request and are not forwarded as dispatch opts" do
      engine = fake_engine()

      assert {:ok, %SpeechResponse{format: :wav}} =
               ALLM.synthesize(engine, "x",
                 voice: "alloy",
                 format: :wav,
                 speed: 1.25,
                 metadata: %{t: 1}
               )

      assert [%{request: request, opts: opts}] = captured_calls()
      assert request.voice == "alloy"
      assert request.format == :wav
      assert request.speed == 1.25
      assert request.metadata == %{t: 1}

      for key <- [:model, :voice, :format, :instructions, :speed, :options, :metadata] do
        refute Keyword.has_key?(opts, key), "#{inspect(key)} leaked into dispatch opts"
      end
    end

    test "an unknown opt is forwarded to the adapter untouched" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.synthesize(engine, "x", request_timeout: 1234, provider_knob: :on)

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_timeout) == 1234
      assert Keyword.get(opts, :provider_knob) == :on
    end

    test "stream: true is silently dropped" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.synthesize(engine, "x", stream: true)

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
    end

    test "no :retry_policy key leaks into the dispatch opts" do
      engine = fake_engine()
      assert {:ok, _} = ALLM.synthesize(engine, "x")
      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :retry_policy)
    end

    test "opts[:request_id] wins over the generated id and reaches the adapter" do
      engine = fake_engine()

      assert {:ok, %SpeechResponse{request_id: "rid-explicit"}} =
               ALLM.synthesize(engine, "x", request_id: "rid-explicit")

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_id) == "rid-explicit"
    end

    test "a generated request_id is filled when the adapter leaves it nil" do
      # A verbatim `{:ok, %SpeechResponse{}}` script entry is returned
      # unstamped by FakeSpeech, so the fill is the façade's.
      scripted = %SpeechResponse{audio: Audio.from_binary("b", "audio/mpeg")}
      engine = fake_engine(adapter_opts: [speech_script: [{:ok, scripted}]])

      assert {:ok, %SpeechResponse{request_id: "rid-fill"}} =
               ALLM.synthesize(engine, "x", request_id: "rid-fill")
    end

    test "an adapter-populated request_id is preserved" do
      engine = Engine.new(speech_adapter: ProviderRequestIdAdapter)

      assert {:ok, %SpeechResponse{request_id: "provider-rid"}} =
               ALLM.synthesize(engine, "x", request_id: "rid-fill")
    end

    test "engine adapter_opts win over call-site adapter_opts on collision" do
      engine = fake_engine(adapter_opts: [tag: :engine])

      assert {:ok, _} = ALLM.synthesize(engine, "x", adapter_opts: [tag: :call, extra: 1])

      assert [%{opts: opts}] = captured_calls()
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)
      assert Keyword.get(adapter_opts, :tag) == :engine
      assert Keyword.get(adapter_opts, :extra) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — model resolution (per-slot, never engine.model)
  # ---------------------------------------------------------------------------

  describe "synthesize/3 model resolution" do
    test "engine.speech_model fills a nil request.model" do
      engine = fake_engine(speech_model: "tts-slot")

      assert {:ok, %SpeechResponse{model: "tts-slot"}} = ALLM.synthesize(engine, "x")
      assert [%{request: %SpeechRequest{model: "tts-slot"}}] = captured_calls()
    end

    test "a set request.model wins over engine.speech_model" do
      engine = fake_engine(speech_model: "tts-slot")
      request = SpeechRequest.new(input: "x", model: "tts-explicit")

      assert {:ok, _} = ALLM.synthesize(engine, request)
      assert [%{request: %SpeechRequest{model: "tts-explicit"}}] = captured_calls()
    end

    test "engine.model (the chat model) never reaches the speech adapter" do
      engine = fake_engine(model: "chat-x")

      assert {:ok, _} = ALLM.synthesize(engine, "x")
      assert [%{request: %SpeechRequest{model: nil}}] = captured_calls()
    end

    test "opts[:model] on the string shape lands on the request and beats the slot" do
      engine = fake_engine(speech_model: "tts-slot")

      assert {:ok, _} = ALLM.synthesize(engine, "x", model: "tts-opt")
      assert [%{request: %SpeechRequest{model: "tts-opt"}}] = captured_calls()
    end

    test "opts[:model] is ignored for a pre-built request" do
      engine = fake_engine(speech_model: "tts-slot")

      assert {:ok, _} = ALLM.synthesize(engine, SpeechRequest.new(input: "x"), model: "tts-opt")
      assert [%{request: %SpeechRequest{model: "tts-slot"}}] = captured_calls()
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — retry and invariant enforcement
  # ---------------------------------------------------------------------------

  describe "synthesize/3 retry" do
    test "a :rate_limited error retries and then succeeds" do
      engine =
        fake_engine(
          retry: @fast_retry,
          adapter_opts: FakeAudioFixtures.speech_retry_until_call(2, "ok")
        )

      assert {:ok, resp} = ALLM.synthesize(engine, "x")
      assert audio_bytes(resp) == "ok"
      # Two calls against the retry entry: one synthetic :rate_limited, then
      # the advancing call that reads {:ok, "ok"}.
      assert length(captured_calls()) == 2
    end

    test ":invalid_request is NOT retried" do
      err = SpeechAdapterError.new(:invalid_request, message: "nope")
      engine = fake_engine(adapter_opts: [speech_script: [{:error, err}]])

      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               ALLM.synthesize(engine, "x")

      assert length(captured_calls()) == 1
    end

    test "retry: false disables retry for a retryable reason" do
      err = SpeechAdapterError.new(:rate_limited, retry_after_ms: 0)
      engine = fake_engine(retry: false, adapter_opts: [speech_script: [{:error, err}]])

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} = ALLM.synthesize(engine, "x")
      assert length(captured_calls()) == 1
    end

    test "a positive retry_after_ms is honoured as the retry delay" do
      TelemetryCapture.attach([[:allm, :adapter, :retry]])
      on_exit(&TelemetryCapture.detach/0)
      err = SpeechAdapterError.new(:rate_limited, retry_after_ms: 50)

      engine =
        fake_engine(
          retry: @fast_retry,
          adapter_opts: [speech_script: [{:error, err}, {:ok, "done"}]]
        )

      assert {:ok, %SpeechResponse{}} = ALLM.synthesize(engine, "x")
      # `@fast_retry` backs off 1 ms with no jitter, so a 50 ms delay can only
      # come from the error's `retry_after_ms`.
      assert [{[:allm, :adapter, :retry], _, %{delay_ms: 50}}] = TelemetryCapture.events()
    end

    test "each of the four retryable reasons is retried" do
      for reason <- [:rate_limited, :provider_unavailable, :timeout, :network_error] do
        err = SpeechAdapterError.new(reason, retry_after_ms: 0)

        engine =
          fake_engine(
            retry: @fast_retry,
            adapter_opts: [speech_script: [{:error, err}, {:ok, "done"}]]
          )

        assert {:ok, resp} = ALLM.synthesize(engine, "x"), "#{reason} was not retried"
        assert audio_bytes(resp) == "done"
        assert length(captured_calls()) == 2
      end
    end

    test "an adapter returning a bare struct raises ArgumentError naming the adapter and invariant 1" do
      engine = Engine.new(speech_adapter: BareMapAdapter)

      assert_raise ArgumentError, ~r/BareMapAdapter.*invariant 1/s, fn ->
        ALLM.synthesize(engine, "x")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # synthesize/3 — cursor isolation
  # ---------------------------------------------------------------------------

  describe "synthesize/3 cursor" do
    test "the engine :id is injected as adapter_opts[:cursor_key]" do
      engine = fake_engine(id: 424_242)

      assert {:ok, _} = ALLM.synthesize(engine, "x")
      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:cursor_key) == 424_242
    end

    test "two content-equal engines with distinct ids read independent cursors" do
      script = [speech_script: [{:ok, "first"}, {:ok, "second"}]]
      a = Engine.new(speech_adapter: FakeSpeech, adapter_opts: script, id: 111_111)
      b = Engine.new(speech_adapter: FakeSpeech, adapter_opts: script, id: 222_222)

      assert {:ok, ra} = ALLM.synthesize(a, "x")
      assert audio_bytes(ra) == "first"

      # Falsifier: a shared cursor hands engine B entry 2.
      assert {:ok, rb} = ALLM.synthesize(b, "x")
      assert audio_bytes(rb) == "first"
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "synthesize/3 telemetry" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :synthesize, :start],
          [:allm, :synthesize, :stop],
          [:allm, :synthesize, :exception]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":start and :stop carry the documented keys on success" do
      engine = fake_engine(speech_model: "tts-slot", model: "chat-x")

      assert {:ok, resp} = ALLM.synthesize(engine, "Héllo", request_id: "rid-t")

      assert [
               {[:allm, :synthesize, :start], _start_m, start_md},
               {[:allm, :synthesize, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-t"
      assert start_md.engine == engine
      assert start_md.model == "tts-slot"
      assert start_md.input_length == 5

      assert is_integer(stop_m.duration)
      assert stop_m.audio_bytes == byte_size("FAKE-AUDIO:Héllo")
      assert stop_md.response == resp
      assert stop_md.usage == resp.usage
      assert stop_md.error == nil
    end

    test ":start model is nil when neither the request nor the slot names one" do
      engine = fake_engine(model: "chat-x")
      assert {:ok, _} = ALLM.synthesize(engine, "x")

      assert [{[:allm, :synthesize, :start], _, start_md} | _] = TelemetryCapture.events()
      assert start_md.model == nil
    end

    test ":start fires when the adapter is missing; :stop carries the error and zero bytes" do
      assert {:error, %EngineError{}} = ALLM.synthesize(Engine.new(), "x")

      assert [
               {[:allm, :synthesize, :start], _, _},
               {[:allm, :synthesize, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert stop_m.audio_bytes == 0
      assert %EngineError{reason: :no_speech_adapter} = stop_md.error
      assert stop_md.response == nil
      assert Map.has_key?(stop_md, :usage)
    end

    test ":start fires on an invalid request with a non-binary :input without raising" do
      engine = fake_engine()
      request = %SpeechRequest{SpeechRequest.new() | input: 42}

      assert {:error, %ValidationError{}} = ALLM.synthesize(engine, request)

      assert [
               {[:allm, :synthesize, :start], _, start_md},
               {[:allm, :synthesize, :stop], stop_m, _}
             ] = TelemetryCapture.events()

      assert start_md.input_length == 0
      assert stop_m.audio_bytes == 0
    end

    test "a Fake-generated error (provider: nil) reaches :stop without raising" do
      engine = fake_engine(retry: false, adapter_opts: [speech_script: [{:retry_until_call, 2}]])

      assert {:error, %SpeechAdapterError{reason: :rate_limited, provider: nil}} =
               ALLM.synthesize(engine, "x")

      assert [_, {[:allm, :synthesize, :stop], %{audio_bytes: 0}, %{error: err}}] =
               TelemetryCapture.events()

      assert err.provider == nil
    end

    test "a response without resolvable audio reports audio_bytes 0 instead of raising" do
      # Breaks invariant 2, but the span must still close cleanly: the
      # measurement helper tolerates a nil audio and an unresolvable source.
      for audio <- [nil, Audio.from_file("/nonexistent/allm-synth.mp3")] do
        engine =
          fake_engine(adapter_opts: [speech_script: [{:ok, %SpeechResponse{audio: audio}}]])

        assert {:ok, _} = ALLM.synthesize(engine, "x")
      end

      stops = for {[:allm, :synthesize, :stop], m, _} <- TelemetryCapture.events(), do: m
      assert Enum.map(stops, & &1.audio_bytes) == [0, 0]
    end

    test ":exception fires when the adapter raises" do
      engine = Engine.new(speech_adapter: RaisingAdapter)

      assert_raise RuntimeError, "boom", fn -> ALLM.synthesize(engine, "x") end

      assert [
               {[:allm, :synthesize, :start], _, _},
               {[:allm, :synthesize, :exception], _, md}
             ] = TelemetryCapture.events()

      assert %RuntimeError{message: "boom"} = md.reason
    end
  end
end
