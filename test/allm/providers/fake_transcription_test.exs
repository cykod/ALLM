defmodule ALLM.Providers.FakeTranscriptionTest do
  use ExUnit.Case, async: true

  alias ALLM.{
    Audio,
    Engine,
    TranscriptionEvent,
    TranscriptionRequest,
    TranscriptionResponse,
    TranscriptionStreamRequest,
    TranscriptSpan,
    Usage
  }

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Test.FakeAudioFixtures, as: Fixtures

  doctest FakeTranscription

  defp request(opts \\ []),
    do: TranscriptionRequest.new(Keyword.put_new(opts, :audio, Fixtures.clip(16)))

  describe "max_audio_bytes/0" do
    test "returns 1024 — small, so the size boundary is cheap to cross" do
      assert FakeTranscription.max_audio_bytes() == 1024
    end
  end

  describe "transcribe/2 default (no script)" do
    test "returns an empty transcript with %Usage{}" do
      assert {:ok, %TranscriptionResponse{text: "", usage: %Usage{}}} =
               FakeTranscription.transcribe(request(), [])
    end

    test "an explicit empty script also yields the default" do
      assert {:ok, %TranscriptionResponse{text: ""}} =
               FakeTranscription.transcribe(request(), adapter_opts: [transcription_script: []])
    end

    test "propagates request_id, model, metadata and provider" do
      req = request(model: "fake-stt", metadata: %{"k" => "v"})
      assert {:ok, resp} = FakeTranscription.transcribe(req, request_id: "rid-1")

      assert resp.request_id == "rid-1"
      assert resp.model == "fake-stt"
      assert resp.metadata == %{"k" => "v"}
      assert resp.provider == :fake
    end
  end

  describe "transcribe/2 scripted entries" do
    test "{:ok, text} returns that transcript" do
      opts = [adapter_opts: Fixtures.transcript("The quick brown fox.")]

      assert {:ok, %TranscriptionResponse{text: "The quick brown fox.", usage: %Usage{}}} =
               FakeTranscription.transcribe(request(), opts)
    end

    test "{:ok, %TranscriptionResponse{}} is returned verbatim" do
      scripted = TranscriptionResponse.new(text: "verbatim", duration_seconds: 3)
      opts = [adapter_opts: [transcription_script: [{:ok, scripted}]]]

      assert {:ok, ^scripted} = FakeTranscription.transcribe(request(), opts)
    end

    test "{:error, %TranscriptionAdapterError{}} is returned verbatim" do
      opts = [adapter_opts: Fixtures.transcription_rate_limited()]

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 250}} =
               FakeTranscription.transcribe(request(), opts)
    end

    test "successive calls advance through the script" do
      cursor = FakeTranscription.start_script_cursor()

      opts = [
        adapter_opts: [transcription_script: [{:ok, "a"}, {:ok, "b"}], script_cursor: cursor]
      ]

      assert {:ok, %{text: "a"}} = FakeTranscription.transcribe(request(), opts)
      assert {:ok, %{text: "b"}} = FakeTranscription.transcribe(request(), opts)
      assert FakeTranscription.cursor_index(cursor) == 2
    end

    test "running past the end of a NON-EMPTY script errors with :transcription_script_exhausted" do
      cursor = FakeTranscription.start_script_cursor()
      opts = [adapter_opts: Fixtures.transcript("a") ++ [script_cursor: cursor]]

      assert {:ok, _} = FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :unknown, metadata: meta}} =
               FakeTranscription.transcribe(request(), opts)

      assert meta.cause == :transcription_script_exhausted
    end
  end

  describe "transcribe/2 gates" do
    test "max_audio_bytes() + 1 is rejected with metadata.count and metadata.max" do
      req = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes() + 1))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.count == 1025
      assert meta.max == 1024
    end

    test "exactly max_audio_bytes() passes the gate" do
      req = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes()))
      assert {:ok, _} = FakeTranscription.transcribe(req, [])
    end

    test "adapter_opts[:max_audio_bytes] overrides the cap" do
      req = request(audio: Fixtures.clip(2048))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.transcribe(req, [])

      assert {:ok, _} = FakeTranscription.transcribe(req, adapter_opts: [max_audio_bytes: 4096])
    end

    test "a missing file is rejected with metadata.cause == :enoent" do
      req = request(audio: Audio.from_file("/nonexistent/allm-fake-transcription.mp3"))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.cause == :enoent
      assert meta.field == :audio
    end

    test "invalid base64 is rejected with metadata.cause == :invalid_base64" do
      req = request(audio: Audio.from_base64("%%%", "audio/mpeg"))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.cause == :invalid_base64
    end

    test "a non-%Audio{} :audio is rejected rather than raising" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(TranscriptionRequest.new(audio: nil), [])

      assert meta.cause == :invalid_source
    end

    test "gates fire before consuming a script entry" do
      cursor = FakeTranscription.start_script_cursor()
      opts = [adapter_opts: Fixtures.transcript("first") ++ [script_cursor: cursor]]
      bad = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes() + 1))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.transcribe(bad, opts)

      assert FakeTranscription.cursor_index(cursor) == 0
      assert {:ok, %{text: "first"}} = FakeTranscription.transcribe(request(), opts)
    end
  end

  describe "cursor precedence" do
    test "two content-equal engines with distinct :id values do not share a cursor" do
      a = Fixtures.transcription_engine(Fixtures.transcript("only"))
      b = Fixtures.transcription_engine(Fixtures.transcript("only"))

      assert a.adapter_opts == b.adapter_opts
      refute a.id == b.id

      opts_a = [adapter_opts: Engine.put_cursor_key(a.adapter_opts, a)]
      opts_b = [adapter_opts: Engine.put_cursor_key(b.adapter_opts, b)]

      assert {:ok, %{text: "only"}} = FakeTranscription.transcribe(request(), opts_a)
      assert {:ok, %{text: "only"}} = FakeTranscription.transcribe(request(), opts_b)
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      opts = [adapter_opts: Fixtures.transcript("only")]

      assert {:ok, _} = FakeTranscription.transcribe(request(), opts)

      assert {:error,
              %TranscriptionAdapterError{metadata: %{cause: :transcription_script_exhausted}}} =
               FakeTranscription.transcribe(request(), opts)
    end
  end

  describe "capture_pid seam" do
    test "sends the request to :capture_pid before any gate" do
      req = request(audio: nil)
      opts = [adapter_opts: [capture_pid: self()]]

      assert {:error, _} = FakeTranscription.transcribe(req, opts)
      assert_receive {FakeTranscription, :call, %{request: ^req, opts: ^opts}}
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns :rate_limited until the budget is spent, then succeeds" do
      # Direct call with an explicit :cursor_key and a leading non-error
      # entry — see the FakeSpeech counterpart for why both matter.
      script = [{:ok, "lead"}, {:retry_until_call, 3}, {:ok, "after"}]
      opts = [adapter_opts: [transcription_script: script, cursor_key: :stt_retry_case]]

      assert {:ok, %{text: "lead"}} = FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited}} =
               FakeTranscription.transcribe(request(), opts)

      assert {:ok, %{text: "after"}} = FakeTranscription.transcribe(request(), opts)
    end

    test "consecutive retry entries chain into a layered budget instead of raising" do
      cursor = FakeTranscription.start_script_cursor()
      script = [{:retry_until_call, 2}, {:retry_until_call, 2}, {:ok, "done"}]
      assert :ok = FakeTranscription.script(script)
      opts = [adapter_opts: [transcription_script: script, script_cursor: cursor]]

      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts)
      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts)
      assert {:ok, %{text: "done"}} = FakeTranscription.transcribe(request(), opts)
    end

    test "a retry budget that runs off the end errors rather than reporting success" do
      cursor = FakeTranscription.start_script_cursor()

      opts = [
        adapter_opts: [transcription_script: [{:retry_until_call, 1}], script_cursor: cursor]
      ]

      assert {:error, %TranscriptionAdapterError{reason: :unknown, metadata: meta}} =
               FakeTranscription.transcribe(request(), opts)

      assert meta.cause == :transcription_script_exhausted
    end

    test "two content-equal-script engines with distinct :id values do not share a retry budget" do
      e1 = Fixtures.transcription_engine(Fixtures.transcription_retry_until_call(2, "ok"))
      e2 = Fixtures.transcription_engine(Fixtures.transcription_retry_until_call(2, "ok"))

      refute e1.id == e2.id

      opts1 = [adapter_opts: Engine.put_cursor_key(e1.adapter_opts, e1)]
      opts2 = [adapter_opts: Engine.put_cursor_key(e2.adapter_opts, e2)]

      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts1)
      assert {:ok, %{text: "ok"}} = FakeTranscription.transcribe(request(), opts1)

      # A retry counter keyed on :erlang.phash2(script) alone would let
      # engine 2 skip straight to the success entry.
      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts2)
      assert {:ok, %{text: "ok"}} = FakeTranscription.transcribe(request(), opts2)
    end
  end

  describe "script/1" do
    test "accepts every documented entry shape" do
      assert :ok =
               FakeTranscription.script([
                 {:ok, "text"},
                 {:ok, TranscriptionResponse.new()},
                 {:error, TranscriptionAdapterError.new(:content_filter)},
                 {:retry_until_call, 2}
               ])
    end

    test "raises ArgumentError on an unrecognized entry" do
      assert_raise ArgumentError, ~r/invalid FakeTranscription script entry/, fn ->
        FakeTranscription.script([{:nope, 1}])
      end
    end
  end

  describe "transcribe/2 streaming-only entries" do
    test "an {:events, _} entry is :unknown with cause :stream_only_script_entry" do
      opts = [adapter_opts: Fixtures.transcription_events([])]

      assert {:error, %TranscriptionAdapterError{reason: :unknown, metadata: meta}} =
               FakeTranscription.transcribe(request(), opts)

      assert meta.cause == :stream_only_script_entry
    end

    test "script/1 accepts an {:events, list} entry" do
      assert :ok = FakeTranscription.script([{:events, []}])
    end
  end

  defp stream_req(opts \\ []), do: TranscriptionStreamRequest.new(opts)

  defp run_stream(input, opts, req \\ stream_req()) do
    assert {:ok, stream} = FakeTranscription.stream_transcribe(req, input, opts)
    Enum.to_list(stream)
  end

  describe "stream_sample_rates/0" do
    test "is [8_000, 16_000, 24_000]" do
      assert FakeTranscription.stream_sample_rates() == [8_000, 16_000, 24_000]
    end
  end

  describe "stream_transcribe/3" do
    test "{:ok, \"the quick fox\"} gives one partial per cumulative word prefix, then one committed segment" do
      events =
        run_stream([Fixtures.pcm_silence(320)], adapter_opts: Fixtures.transcript("the quick fox"))

      assert for({:partial_transcript, %{text: t}} <- events, do: t) ==
               ["the", "the quick", "the quick fox"]

      assert for({:committed_transcript, %{text: t}} <- events, do: t) == ["the quick fox"]
      assert {:transcription_completed, %{text: "the quick fox"}} = List.last(events)
    end

    test "32,000 bytes at 16 kHz give duration_seconds == 1.0" do
      events = run_stream([Fixtures.pcm_silence(16_000), Fixtures.pcm_silence(16_000)], [])
      assert {:transcription_completed, %{duration_seconds: 1.0}} = List.last(events)
    end

    test "completed.text is the trimmed join, where transcribe/2 returns the text verbatim" do
      # Distinct cursors: the two calls script content-equal entries.
      opts = fn ->
        cursor = FakeTranscription.start_script_cursor()
        [adapter_opts: Fixtures.transcript(" the quick ") ++ [script_cursor: cursor]]
      end

      events = run_stream([Fixtures.pcm_silence(2)], opts.())
      assert {:transcription_completed, %{text: "the quick"}} = List.last(events)

      assert {:ok, %TranscriptionResponse{text: " the quick "}} =
               FakeTranscription.transcribe(request(), opts.())
    end

    test "no script gives only the envelope, with text \"\"" do
      assert [
               {:transcription_started, %{provider: :fake, session_id: nil}},
               {:transcription_completed, %{text: "", usage: %Usage{}}}
             ] = run_stream([Fixtures.pcm_silence(2)], [])
    end

    test "an input whose total length is odd ends with :invalid_input_chunk at end of input" do
      events = run_stream([<<1, 2, 3>>], [])

      assert {:error,
              %TranscriptionAdapterError{
                reason: :invalid_request,
                metadata: %{cause: :invalid_input_chunk}
              }} = List.last(events)
    end

    test "an odd-length chunk followed by one that completes the sample succeeds" do
      events = run_stream([<<1, 2, 3>>, <<4>>], [])
      assert {:transcription_completed, %{duration_seconds: d}} = List.last(events)
      assert d == 4 / 32_000
    end

    test ":commit elements are accepted and carry no bytes" do
      events = run_stream([Fixtures.pcm_silence(2), :commit], [])
      assert {:transcription_completed, _} = List.last(events)
    end

    test "an element that is neither a binary nor :commit ends with :invalid_input_chunk" do
      events = run_stream([:flush], [])

      assert {:error, %TranscriptionAdapterError{metadata: %{cause: :invalid_input_chunk}}} =
               List.last(events)
    end

    test "an input that raises ends with :input_raised and a string-only cause" do
      input = Stream.map([1], fn _ -> raise "mic unplugged" end)

      assert {:error,
              %TranscriptionAdapterError{metadata: %{cause: :input_raised}, cause: cause} = err} =
               run_stream(input, []) |> List.last()

      assert %{kind: :error, message: message} = cause
      assert message =~ "mic unplugged"
      assert is_binary(Jason.encode!(err))
    end

    test "a sample_rate outside the set is a synchronous :invalid_request" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.stream_transcribe(stream_req(sample_rate: 44_100), [], [])

      assert meta.sample_rate == 44_100
    end

    test "adapter_opts[:stream_sample_rates] overrides the rate set" do
      opts = [adapter_opts: [stream_sample_rates: [44_100]]]

      assert {:ok, _} =
               FakeTranscription.stream_transcribe(stream_req(sample_rate: 44_100), [], opts)

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.stream_transcribe(stream_req(sample_rate: 16_000), [], opts)
    end

    test "the sample-rate gate fires before a script entry is consumed" do
      cursor = FakeTranscription.start_script_cursor()
      opts = [adapter_opts: [transcription_script: [{:ok, "x"}], script_cursor: cursor]]

      assert {:error, _} =
               FakeTranscription.stream_transcribe(stream_req(sample_rate: 1), [], opts)

      assert FakeTranscription.cursor_index(cursor) == 0
    end

    test "an {:events, _} entry is emitted verbatim" do
      scripted = [TranscriptionEvent.partial_transcript("a")]

      assert run_stream([], adapter_opts: Fixtures.transcription_events(scripted)) == scripted
    end

    test "an {:error, _} entry emits :transcription_started then the error" do
      assert [
               {:transcription_started, _},
               {:error, %TranscriptionAdapterError{reason: :rate_limited}}
             ] = run_stream([], adapter_opts: Fixtures.transcription_rate_limited())
    end

    test "an {:ok, %TranscriptionResponse{}} entry is emitted from the struct" do
      resp = %TranscriptionResponse{text: "hi", language: "en", duration_seconds: 2.0, id: "s1"}

      events = run_stream([], adapter_opts: [transcription_script: [{:ok, resp}]])

      assert [{:transcription_started, %{session_id: "s1"}} | _] = events
      assert {:committed_transcript, %{text: "hi", language: "en"}} in events

      assert {:transcription_completed, %{text: "hi", language: "en", duration_seconds: 2.0}} =
               List.last(events)
    end

    test "request_id, model and metadata reach the envelope" do
      req = stream_req(model: "rt", metadata: %{"k" => "v"})

      events = run_stream([], [request_id: "rid"], req)

      assert [{:transcription_started, %{request_id: "rid", model: "rt"}} | _] = events

      assert {:transcription_completed, %{request_id: "rid", metadata: %{"k" => "v"}}} =
               List.last(events)
    end

    test "a mailbox-dependent input times out: the input is reduced in another process" do
      input = Stream.repeatedly(fn -> receive(do: ({:pcm, x} -> x)) end)
      send(self(), {:pcm, <<0, 0>>})

      assert [
               {:transcription_started, _},
               {:error, %TranscriptionAdapterError{reason: :timeout}}
             ] = run_stream(input, stream_timeout: 100)

      assert_received {:pcm, <<0, 0>>}
    end
  end

  describe "stream cursor timing" do
    test "two unreduced stream calls consume two entries; a third finds the script exhausted" do
      opts = [adapter_opts: [transcription_script: [{:ok, "one"}, {:ok, "two"}]]]

      assert {:ok, _} = FakeTranscription.stream_transcribe(stream_req(), [], opts)
      assert {:ok, _} = FakeTranscription.stream_transcribe(stream_req(), [], opts)

      assert {:error,
              %TranscriptionAdapterError{metadata: %{cause: :transcription_script_exhausted}}} =
               FakeTranscription.stream_transcribe(stream_req(), [], opts)
    end

    test "{:retry_until_call, 2}: the first stream is only a :rate_limited error, the second emits the next entry" do
      opts = [adapter_opts: Fixtures.transcription_retry_until_call(2, "done")]

      assert [{:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 0}}] =
               run_stream([], opts)

      assert {:transcription_completed, %{text: "done"}} = run_stream([], opts) |> List.last()
    end
  end

  # ---------------------------------------------------------------------------
  # Span flags
  # ---------------------------------------------------------------------------

  @flag_cells [{false, false}, {true, false}, {false, true}, {true, true}]

  # The exact spans the Fake builds for `words` under one flag cell: word i
  # at [i * 0.5, (i + 1) * 0.5] with logprob -0.1, unrequested attributes nil.
  defp expected_spans(_words, false, false), do: nil

  defp expected_spans(words, ts, lp) do
    for {word, i} <- Enum.with_index(words) do
      %TranscriptSpan{
        text: word,
        kind: :word,
        start_seconds: if(ts, do: i * 0.5),
        end_seconds: if(ts, do: (i + 1) * 0.5),
        logprob: if(lp, do: -0.1)
      }
    end
  end

  defp committed_payloads(events), do: for({:committed_transcript, p} <- events, do: p)

  defp completed_payload(events) do
    assert {:transcription_completed, payload} = List.last(events)
    payload
  end

  describe "span flags — transcribe/2" do
    for {ts, lp} <- @flag_cells do
      @ts ts
      @lp lp
      test "{:ok, \"the quick fox\"} under timestamps: #{ts}, logprobs: #{lp}" do
        req = request(timestamps: @ts, logprobs: @lp)
        opts = [adapter_opts: Fixtures.transcript("the quick fox")]

        assert {:ok, resp} = FakeTranscription.transcribe(req, opts)
        assert resp.spans == expected_spans(~w(the quick fox), @ts, @lp)
      end

      test "a scripted %TranscriptionResponse{} is verbatim under timestamps: #{ts}, logprobs: #{lp}" do
        scripted = [TranscriptSpan.new(text: "x", kind: :token)]

        for spans <- [nil, scripted] do
          entry = TranscriptionResponse.new(text: "x", spans: spans)
          opts = [adapter_opts: [transcription_script: [{:ok, entry}]]]

          assert {:ok, ^entry} =
                   FakeTranscription.transcribe(request(timestamps: @ts, logprobs: @lp), opts)
        end
      end
    end

    test "blank text with a flag gives spans: [], without flags spans: nil" do
      for text <- ["", "   "] do
        opts = fn ->
          [
            adapter_opts:
              Fixtures.transcript(text) ++ [script_cursor: FakeTranscription.start_script_cursor()]
          ]
        end

        assert {:ok, %{spans: []}} = FakeTranscription.transcribe(request(logprobs: true), opts.())
        assert {:ok, %{spans: nil}} = FakeTranscription.transcribe(request(), opts.())
      end
    end

    test "the no-script default honours the flags too" do
      assert {:ok, %{spans: []}} = FakeTranscription.transcribe(request(timestamps: true), [])
      assert {:ok, %{spans: nil}} = FakeTranscription.transcribe(request(), [])
    end

    test "a flag value that is not exactly true is off" do
      req = %TranscriptionRequest{request() | timestamps: "yes", logprobs: 1}

      assert {:ok, %{spans: nil}} =
               FakeTranscription.transcribe(req, adapter_opts: Fixtures.transcript("a b"))
    end
  end

  describe "span flags — stream_transcribe/3" do
    for {ts, lp} <- @flag_cells do
      @ts ts
      @lp lp
      test "{:ok, \"the quick fox\"} under timestamps: #{ts}, logprobs: #{lp}" do
        req = stream_req(timestamps: @ts, logprobs: @lp)

        events =
          run_stream(
            [Fixtures.pcm_silence(2)],
            [adapter_opts: Fixtures.transcript("the quick fox")],
            req
          )

        expected = expected_spans(~w(the quick fox), @ts, @lp)

        assert [committed] = committed_payloads(events)
        completed = completed_payload(events)

        if expected do
          assert committed == %{text: "the quick fox", language: nil, spans: expected}
          assert completed.spans == expected
        else
          refute Map.has_key?(committed, :spans)
          refute Map.has_key?(completed, :spans)
        end
      end

      test "a scripted %TranscriptionResponse{} under timestamps: #{ts}, logprobs: #{lp}" do
        spans = [TranscriptSpan.new(text: "hi", kind: :token, logprob: -1.0)]
        req = stream_req(timestamps: @ts, logprobs: @lp)

        with_spans = TranscriptionResponse.new(text: "hi", spans: spans)
        events = run_stream([], [adapter_opts: [transcription_script: [{:ok, with_spans}]]], req)
        assert [%{spans: ^spans}] = committed_payloads(events)
        assert completed_payload(events).spans == spans

        without = TranscriptionResponse.new(text: "hi")
        events = run_stream([], [adapter_opts: [transcription_script: [{:ok, without}]]], req)
        assert [committed] = committed_payloads(events)
        refute Map.has_key?(committed, :spans)
        refute Map.has_key?(completed_payload(events), :spans)
      end
    end

    test "blank text with a flag: no committed event, completed spans: []" do
      for text <- ["", "  "] do
        req = stream_req(timestamps: true, logprobs: true)

        events =
          run_stream([Fixtures.pcm_silence(2)], [adapter_opts: Fixtures.transcript(text)], req)

        assert committed_payloads(events) == []
        assert completed_payload(events).spans == []
      end
    end

    test "the no-script default with a flag completes with spans: [], without one with no :spans key" do
      assert completed_payload(run_stream([], [], stream_req(logprobs: true))).spans == []
      refute Map.has_key?(completed_payload(run_stream([], [])), :spans)
    end

    test "an {:events, _} entry stays verbatim under the flags" do
      events = [TranscriptionEvent.committed_transcript("x")]
      opts = [adapter_opts: Fixtures.transcription_events(events)]
      assert run_stream([], opts, stream_req(timestamps: true)) == events
    end
  end

  describe "span flags — hand-off gate (adapter_opts[:span_flags])" do
    test "transcribe/2: an unsupported set flag is refused before the script is consulted" do
      cursor = FakeTranscription.start_script_cursor()
      adapter_opts = Fixtures.transcript("a b") ++ [script_cursor: cursor, span_flags: [:logprobs]]

      assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature, metadata: meta}} =
               FakeTranscription.transcribe(request(timestamps: true, logprobs: true),
                 adapter_opts: adapter_opts
               )

      assert meta.field == :timestamps
      assert FakeTranscription.cursor_index(cursor) == 0

      assert {:ok, %{spans: [_, _]}} =
               FakeTranscription.transcribe(request(logprobs: true), adapter_opts: adapter_opts)

      assert FakeTranscription.cursor_index(cursor) == 1
    end

    test "transcribe/2: an empty supported list refuses logprobs too" do
      assert {:error,
              %TranscriptionAdapterError{
                reason: :unsupported_feature,
                metadata: %{field: :logprobs}
              }} =
               FakeTranscription.transcribe(request(logprobs: true), adapter_opts: [span_flags: []])
    end

    test "transcribe/2: the audio gates still run first" do
      bad = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes() + 1), timestamps: true)

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.transcribe(bad, adapter_opts: [span_flags: []])
    end

    test "stream_transcribe/3: an unsupported set flag is a synchronous refusal that keeps the cursor" do
      cursor = FakeTranscription.start_script_cursor()
      adapter_opts = Fixtures.transcript("a b") ++ [script_cursor: cursor, span_flags: [:logprobs]]

      assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature, metadata: meta}} =
               FakeTranscription.stream_transcribe(stream_req(timestamps: true), [],
                 adapter_opts: adapter_opts
               )

      assert meta.field == :timestamps
      assert FakeTranscription.cursor_index(cursor) == 0
    end

    test "stream_transcribe/3: the sample-rate gate still runs first" do
      assert {:error,
              %TranscriptionAdapterError{reason: :invalid_request, metadata: %{field: :sample_rate}}} =
               FakeTranscription.stream_transcribe(
                 stream_req(sample_rate: 44_100, timestamps: true),
                 [],
                 adapter_opts: [span_flags: []]
               )
    end
  end
end
