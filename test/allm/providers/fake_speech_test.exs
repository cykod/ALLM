defmodule ALLM.Providers.FakeSpeechTest do
  use ExUnit.Case, async: true

  alias ALLM.{Audio, Engine, SpeechEvent, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Test.FakeAudioFixtures, as: Fixtures

  doctest FakeSpeech

  defp request(opts \\ []), do: SpeechRequest.new(Keyword.put_new(opts, :input, "Hello."))

  defp bytes(%SpeechResponse{audio: audio}) do
    {:ok, b} = Audio.to_binary(audio)
    b
  end

  describe "synthesize/2 default (no script)" do
    test "bytes are \"FAKE-AUDIO:\" <> input, so two inputs give two payloads" do
      assert {:ok, a} = FakeSpeech.synthesize(request(input: "one"), [])
      assert {:ok, b} = FakeSpeech.synthesize(request(input: "two"), [])

      assert bytes(a) == "FAKE-AUDIO:one"
      assert bytes(b) == "FAKE-AUDIO:two"
    end

    test "format defaults to :mp3 with the audio/mpeg mime" do
      assert {:ok, resp} = FakeSpeech.synthesize(request(), [])
      assert resp.format == :mp3
      assert resp.audio.mime_type == "audio/mpeg"
      assert resp.audio.source == {:binary, "FAKE-AUDIO:Hello."}
    end

    test "format: :wav yields mime_type audio/wav" do
      assert {:ok, resp} = FakeSpeech.synthesize(request(format: :wav), [])
      assert resp.format == :wav
      assert resp.audio.mime_type == "audio/wav"
    end

    test "format: :ulaw / :alaw yield audio/basic / audio/alaw, synchronously and streamed" do
      for {format, mime} <- [ulaw: "audio/basic", alaw: "audio/alaw"] do
        req = request(format: format, sample_rate: 8_000)
        assert {:ok, resp} = FakeSpeech.synthesize(req, [])
        assert {resp.format, resp.audio.mime_type, resp.sample_rate} == {format, mime, 8_000}

        assert {:ok, events} = FakeSpeech.stream_synthesize(req, [])
        assert [{:speech_started, started} | _] = Enum.to_list(events)
        assert {started.format, started.mime_type} == {format, mime}
      end
    end

    test "every format's mime comes from SpeechResponse.format_to_mime/1" do
      for format <- SpeechRequest.formats() do
        assert {:ok, resp} = FakeSpeech.synthesize(request(format: format), [])
        assert resp.audio.mime_type == SpeechResponse.format_to_mime(format)
      end
    end

    test "an explicit empty script also yields the default" do
      opts = [adapter_opts: [speech_script: []]]
      assert {:ok, resp} = FakeSpeech.synthesize(request(), opts)
      assert bytes(resp) == "FAKE-AUDIO:Hello."
    end

    test "propagates request_id, model, metadata, provider; usage is %Usage{}; raw is nil" do
      req = request(model: "fake-tts", metadata: %{"k" => "v"})
      assert {:ok, resp} = FakeSpeech.synthesize(req, request_id: "rid-1")

      assert resp.request_id == "rid-1"
      assert resp.model == "fake-tts"
      assert resp.metadata == %{"k" => "v"}
      assert resp.provider == :fake
      assert resp.usage == %Usage{}
      assert resp.raw == nil
    end
  end

  describe "synthesize/2 scripted entries" do
    test "{:ok, binary} returns those bytes with the request's format mime" do
      opts = [adapter_opts: Fixtures.speech_bytes(<<0, 255, 1>>)]
      assert {:ok, resp} = FakeSpeech.synthesize(request(format: :flac), opts)

      assert bytes(resp) == <<0, 255, 1>>
      assert resp.format == :flac
      assert resp.audio.mime_type == "audio/flac"
    end

    test "{:ok, %SpeechResponse{}} is returned verbatim" do
      scripted = SpeechResponse.new(audio: Audio.from_binary("x", "audio/ogg"), id: "scripted")
      opts = [adapter_opts: [speech_script: [{:ok, scripted}]]]

      assert {:ok, ^scripted} = FakeSpeech.synthesize(request(), opts)
    end

    # A real batch adapter reports an empty 200 body as :malformed_response
    # (SpeechAdapter invariant 2); a real stream that closes without audio
    # ends with :empty_input (SpeechStreamAdapter invariant 3). The Fake
    # mirrors each path.
    test "{:ok, \"\"} is :malformed_response on the batch path and :empty_input on the stream paths" do
      script = [{:ok, ""}]

      opts = fn ->
        [adapter_opts: [speech_script: script, script_cursor: FakeSpeech.start_script_cursor()]]
      end

      assert {:error, %SpeechAdapterError{reason: :malformed_response, message: message}} =
               FakeSpeech.synthesize(request(), opts.())

      assert message =~ "empty audio body"

      for call <- [
            &FakeSpeech.stream_synthesize(request(), &1),
            &FakeSpeech.stream_synthesize_input(request(), ["a"], &1)
          ] do
        assert {:ok, events} = call.(opts.())

        assert {:error,
                %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}} =
                 List.last(Enum.to_list(events))
      end
    end

    test "{:ok, %SpeechResponse{}} with zero-byte audio is :malformed_response" do
      resp = %SpeechResponse{audio: Audio.from_binary("", "audio/mpeg"), format: :mp3}
      opts = [adapter_opts: [speech_script: [{:ok, resp}]]]

      assert {:error, %SpeechAdapterError{reason: :malformed_response}} =
               FakeSpeech.synthesize(request(), opts)
    end

    test "{:error, %SpeechAdapterError{}} is returned verbatim" do
      opts = [adapter_opts: Fixtures.speech_rate_limited()]

      assert {:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 250}} =
               FakeSpeech.synthesize(request(), opts)
    end

    test "successive calls advance through the script" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: [speech_script: [{:ok, "a"}, {:ok, "b"}], script_cursor: cursor]]

      assert {:ok, first} = FakeSpeech.synthesize(request(), opts)
      assert {:ok, second} = FakeSpeech.synthesize(request(), opts)
      assert {bytes(first), bytes(second)} == {"a", "b"}
      assert FakeSpeech.cursor_index(cursor) == 2
    end

    test "running past the end of a NON-EMPTY script errors with :speech_script_exhausted" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: Fixtures.speech_bytes("a") ++ [script_cursor: cursor]]

      assert {:ok, _} = FakeSpeech.synthesize(request(), opts)

      assert {:error, %SpeechAdapterError{reason: :unknown, metadata: meta}} =
               FakeSpeech.synthesize(request(), opts)

      assert meta.cause == :speech_script_exhausted
    end
  end

  describe "synthesize/2 gates" do
    test "empty input is rejected before consuming a script entry" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: Fixtures.speech_bytes("first") ++ [script_cursor: cursor]]

      assert {:error, %SpeechAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeSpeech.synthesize(request(input: ""), opts)

      assert meta.field == :input
      assert FakeSpeech.cursor_index(cursor) == 0

      # The next call still gets entry 1.
      assert {:ok, resp} = FakeSpeech.synthesize(request(), opts)
      assert bytes(resp) == "first"
    end

    test "a non-binary input is rejected as :invalid_request rather than raising" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               FakeSpeech.synthesize(%SpeechRequest{input: nil}, [])
    end
  end

  describe "cursor precedence" do
    test "two content-equal engines with distinct :id values do not share a cursor" do
      a = Fixtures.speech_engine(Fixtures.speech_bytes("only"))
      b = Fixtures.speech_engine(Fixtures.speech_bytes("only"))

      assert a.adapter_opts == b.adapter_opts
      refute a.id == b.id

      opts_a = [adapter_opts: Engine.put_cursor_key(a.adapter_opts, a)]
      opts_b = [adapter_opts: Engine.put_cursor_key(b.adapter_opts, b)]

      # A shared cursor would push b past the single entry into the
      # :speech_script_exhausted error.
      assert {:ok, first} = FakeSpeech.synthesize(request(), opts_a)
      assert {:ok, second} = FakeSpeech.synthesize(request(), opts_b)
      assert {bytes(first), bytes(second)} == {"only", "only"}
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      opts = [adapter_opts: Fixtures.speech_bytes("only")]

      assert {:ok, _} = FakeSpeech.synthesize(request(), opts)

      assert {:error, %SpeechAdapterError{metadata: %{cause: :speech_script_exhausted}}} =
               FakeSpeech.synthesize(request(), opts)
    end

    test "an explicit :script_cursor Agent pid outranks :cursor_key" do
      cursor = FakeSpeech.start_script_cursor()

      opts = [
        adapter_opts: [
          speech_script: [{:ok, "a"}, {:ok, "b"}],
          cursor_key: 7,
          script_cursor: cursor
        ]
      ]

      assert {:ok, _} = FakeSpeech.synthesize(request(), opts)
      assert {:ok, _} = FakeSpeech.synthesize(request(), opts)
      assert FakeSpeech.cursor_index(cursor) == 2
    end
  end

  describe "capture_pid seam" do
    test "sends the request to :capture_pid before any gate" do
      req = request(input: "")
      opts = [adapter_opts: [capture_pid: self()]]

      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               FakeSpeech.synthesize(req, opts)

      assert_receive {FakeSpeech, :call, %{request: ^req, opts: ^opts}}
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns :rate_limited until the budget is spent, then succeeds" do
      # Driven against synthesize/2 directly with an explicit :cursor_key —
      # the façade's Retry.run/3 would collapse the error sequence. The
      # leading non-error entry is load-bearing: it forces `advance` to WRITE
      # the process-dict slot `peek` later READS.
      script = [{:ok, "lead"}, {:retry_until_call, 3}, {:ok, "after"}]
      opts = [adapter_opts: [speech_script: script, cursor_key: :speech_retry_case]]

      assert {:ok, lead} = FakeSpeech.synthesize(request(), opts)
      assert bytes(lead) == "lead"

      assert {:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeSpeech.synthesize(request(), opts)

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts)

      assert {:ok, resp} = FakeSpeech.synthesize(request(), opts)
      assert bytes(resp) == "after"
    end

    test "consecutive retry entries chain into a layered budget instead of raising" do
      cursor = FakeSpeech.start_script_cursor()
      script = [{:retry_until_call, 2}, {:retry_until_call, 2}, {:ok, "done"}]
      assert :ok = FakeSpeech.script(script)
      opts = [adapter_opts: [speech_script: script, script_cursor: cursor]]

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts)

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts)

      assert {:ok, resp} = FakeSpeech.synthesize(request(), opts)
      assert bytes(resp) == "done"
    end

    test "a retry budget that runs off the end errors rather than reporting success" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: [speech_script: [{:retry_until_call, 1}], script_cursor: cursor]]

      assert {:error, %SpeechAdapterError{reason: :unknown, metadata: meta}} =
               FakeSpeech.synthesize(request(), opts)

      assert meta.cause == :speech_script_exhausted
    end

    test "two content-equal-script engines with distinct :id values do not share a retry budget" do
      e1 = Fixtures.speech_engine(Fixtures.speech_retry_until_call(2, "ok"))
      e2 = Fixtures.speech_engine(Fixtures.speech_retry_until_call(2, "ok"))

      refute e1.id == e2.id

      opts1 = [adapter_opts: Engine.put_cursor_key(e1.adapter_opts, e1)]
      opts2 = [adapter_opts: Engine.put_cursor_key(e2.adapter_opts, e2)]

      # Engine 1 burns its whole budget.
      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts1)

      assert {:ok, _} = FakeSpeech.synthesize(request(), opts1)

      # Engine 2 must start from a fresh budget in the same process — keying
      # the retry counter on :erlang.phash2(script) alone would let it skip
      # straight to the success entry.
      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts2)

      assert {:ok, _} = FakeSpeech.synthesize(request(), opts2)
    end
  end

  describe "script/1" do
    test "accepts every documented entry shape" do
      assert :ok =
               FakeSpeech.script([
                 {:ok, "bytes"},
                 {:ok, SpeechResponse.new()},
                 {:error, SpeechAdapterError.new(:rate_limited)},
                 {:retry_until_call, 2}
               ])
    end

    test "raises ArgumentError on an unrecognized entry" do
      assert_raise ArgumentError, ~r/invalid FakeSpeech script entry/, fn ->
        FakeSpeech.script([{:nope, 1}])
      end
    end
  end

  describe "synthesize/2 streaming-only entries and sample_rate" do
    test "reports request.sample_rate on the response" do
      assert {:ok, resp} = FakeSpeech.synthesize(request(format: :pcm, sample_rate: 16_000), [])
      assert resp.sample_rate == 16_000
    end

    test "an {:events, _} entry is :unknown with cause :stream_only_script_entry" do
      opts = [adapter_opts: Fixtures.speech_events([SpeechEvent.audio_delta("x")])]

      assert {:error, %SpeechAdapterError{reason: :unknown, metadata: meta}} =
               FakeSpeech.synthesize(request(), opts)

      assert meta.cause == :stream_only_script_entry
    end

    test "script/1 accepts an {:events, list} entry" do
      assert :ok = FakeSpeech.script([{:events, []}])
    end
  end

  describe "stream_synthesize/2" do
    test "chunk_bytes: 4 on the 13-byte default audio gives deltas of sizes [4, 4, 4, 1]" do
      opts = [adapter_opts: [chunk_bytes: 4]]
      assert {:ok, events} = FakeSpeech.stream_synthesize(request(input: "hi"), opts)

      deltas = for {:audio_delta, b} <- events, do: b
      assert Enum.map(deltas, &byte_size/1) == [4, 4, 4, 1]
      assert Enum.join(deltas) == "FAKE-AUDIO:hi"
    end

    test "the default chunk size is 1,024 bytes" do
      opts = [adapter_opts: Fixtures.speech_bytes(:binary.copy("a", 2_500))]
      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)

      assert for({:audio_delta, b} <- events, do: byte_size(b)) == [1_024, 1_024, 452]
    end

    test "the envelope carries format, mime, sample_rate, model, request_id and metadata" do
      req = request(format: :pcm, sample_rate: 24_000, model: "m", metadata: %{"k" => "v"})
      assert {:ok, events} = FakeSpeech.stream_synthesize(req, request_id: "rid")

      assert [{:speech_started, started} | _] = events

      assert started == %{
               request_id: "rid",
               model: "m",
               provider: :fake,
               format: :pcm,
               mime_type: "audio/pcm",
               sample_rate: 24_000
             }

      assert {:speech_completed, %{request_id: "rid", metadata: %{"k" => "v"}, usage: %Usage{}}} =
               List.last(events)
    end

    test "an {:events, _} entry is emitted verbatim" do
      err = SpeechAdapterError.new(:network_error, metadata: %{bytes_received: 1})
      scripted = [SpeechEvent.audio_delta("a"), {:error, err}]
      opts = [adapter_opts: Fixtures.speech_events(scripted)]

      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)
      assert Enum.to_list(events) == scripted
    end

    test "an {:error, _} entry emits :speech_started then the error" do
      opts = [adapter_opts: Fixtures.speech_rate_limited()]
      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :rate_limited}}] =
               events
    end

    test "an {:ok, %SpeechResponse{}} entry is emitted from the struct" do
      resp = %SpeechResponse{
        audio: Audio.from_binary("wav-bytes", "audio/wav"),
        format: :wav,
        sample_rate: 8_000,
        provider: :scripted,
        metadata: %{a: 1}
      }

      opts = [adapter_opts: [speech_script: [{:ok, resp}]]]
      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)

      assert [{:speech_started, %{format: :wav, sample_rate: 8_000, mime_type: "audio/wav"}} | _] =
               events

      assert for({:audio_delta, b} <- events, into: "", do: b) == "wav-bytes"
      assert {:speech_completed, %{metadata: %{a: 1}}} = List.last(events)
    end

    test "an {:ok, %SpeechResponse{}} entry with zero-byte audio ends with :empty_input" do
      resp = %SpeechResponse{audio: Audio.from_binary("", "audio/mpeg"), format: :mp3}
      script = [{:ok, resp}]

      for call <- [
            &FakeSpeech.stream_synthesize(request(), &1),
            &FakeSpeech.stream_synthesize_input(request(), ["a"], &1)
          ] do
        cursor = FakeSpeech.start_script_cursor()
        assert {:ok, events} = call.(adapter_opts: [speech_script: script, script_cursor: cursor])

        assert [
                 {:speech_started, %{mime_type: "audio/mpeg"}},
                 {:error,
                  %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}
               ] = Enum.to_list(events)
      end
    end

    test "an {:ok, %SpeechResponse{}} entry with unreadable audio is a stream error, not a raise" do
      missing = Path.join(System.tmp_dir!(), "allm-fake-speech-missing-#{System.unique_integer()}")

      for resp <- [
            SpeechResponse.new(),
            %SpeechResponse{audio: Audio.from_file(missing <> ".mp3")}
          ],
          call <- [
            &FakeSpeech.stream_synthesize(request(), &1),
            &FakeSpeech.stream_synthesize_input(request(), ["a"], &1)
          ] do
        cursor = FakeSpeech.start_script_cursor()
        opts = [adapter_opts: [speech_script: [{:ok, resp}], script_cursor: cursor]]
        assert {:ok, events} = call.(opts)

        assert [
                 {:speech_started, %{provider: :fake}},
                 {:error,
                  %SpeechAdapterError{
                    reason: :unknown,
                    metadata: %{cause: :unreadable_script_audio}
                  }}
               ] = Enum.to_list(events)
      end
    end

    test "empty scripted bytes end with :empty_input" do
      opts = [adapter_opts: Fixtures.speech_bytes("")]
      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{metadata: %{cause: :empty_input}}}] =
               events
    end

    test "empty input is rejected before a script entry is consumed" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: [speech_script: [{:ok, "x"}], script_cursor: cursor]]

      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               FakeSpeech.stream_synthesize(request(input: ""), opts)

      assert FakeSpeech.cursor_index(cursor) == 0
    end
  end

  describe "stream cursor timing" do
    test "two unreduced stream calls consume two entries; a third finds the script exhausted" do
      opts = [adapter_opts: [speech_script: [{:ok, "one"}, {:ok, "two"}]]]

      assert {:ok, _unreduced} = FakeSpeech.stream_synthesize(request(), opts)
      assert {:ok, _unreduced} = FakeSpeech.stream_synthesize_input(request(), ["x"], opts)

      assert {:error, %SpeechAdapterError{metadata: %{cause: :speech_script_exhausted}}} =
               FakeSpeech.stream_synthesize(request(), opts)
    end

    test "{:retry_until_call, 2}: the first stream is only a :rate_limited error, the second emits the next entry" do
      opts = [adapter_opts: Fixtures.speech_retry_until_call(2, "done")]

      assert {:ok, first} = FakeSpeech.stream_synthesize(request(), opts)

      assert [{:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 0}}] =
               Enum.to_list(first)

      assert {:ok, second} = FakeSpeech.stream_synthesize(request(), opts)
      assert for({:audio_delta, b} <- second, into: "", do: b) == "done"
    end

    test "the retry visit counter is shared between synthesize/2 and the stream path" do
      opts = [adapter_opts: Fixtures.speech_retry_until_call(2, "done")]

      assert {:error, %SpeechAdapterError{reason: :rate_limited}} =
               FakeSpeech.synthesize(request(), opts)

      assert {:ok, events} = FakeSpeech.stream_synthesize(request(), opts)
      assert for({:audio_delta, b} <- events, into: "", do: b) == "done"
    end
  end

  describe "stream_synthesize_input/3" do
    test ~s(["a", "", "b"] gives exactly two deltas, one per non-empty chunk) do
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), ["a", "", "b"], [])

      assert for({:audio_delta, b} <- stream, do: b) == ["FAKE-AUDIO:a", "FAKE-AUDIO:b"]
    end

    test "{:ok, bytes} consumes the input, then emits the bytes" do
      opts = [adapter_opts: Fixtures.speech_bytes("scripted") ++ [chunk_bytes: 3]]
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), ["a", "b"], opts)

      assert for({:audio_delta, b} <- stream, do: b) == ["scr", "ipt", "ed"]
    end

    test "a request shape error is synchronous, before the script and the input" do
      cursor = FakeSpeech.start_script_cursor()
      opts = [adapter_opts: [speech_script: [{:ok, "x"}], script_cursor: cursor]]
      test_pid = self()
      input = Stream.map(["a"], fn c -> send(test_pid, :reduced) && c end)

      assert {:error, %SpeechAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeSpeech.stream_synthesize_input(request(format: :bogus), input, opts)

      assert meta.errors == [format: :unknown]

      assert FakeSpeech.cursor_index(cursor) == 0
      refute_received :reduced
    end

    test "a non-binary chunk ends the stream with :invalid_input_chunk" do
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), ["a", 123], [])

      assert {:error, %SpeechAdapterError{metadata: %{cause: :invalid_input_chunk}}} =
               stream |> Enum.to_list() |> List.last()
    end

    test "a non-UTF-8 chunk ends the stream with :invalid_input_chunk" do
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), [<<0xFF>>], [])

      assert {:error, %SpeechAdapterError{metadata: %{cause: :invalid_input_chunk}}} =
               stream |> Enum.to_list() |> List.last()
    end

    test "an input with no non-empty chunk ends with :empty_input" do
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), [], [])

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{metadata: %{cause: :empty_input}}}] =
               Enum.to_list(stream)
    end

    test "an input that raises ends with :input_raised and a string-only, encodable cause" do
      input = Stream.map(["a"], fn _ -> raise "secret-shaped failure" end)
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), input, [])

      assert {:error, %SpeechAdapterError{metadata: %{cause: :input_raised}, cause: cause} = err} =
               stream |> Enum.to_list() |> List.last()

      assert %{kind: :error, message: message} = cause
      assert message =~ "secret-shaped failure"
      assert is_binary(Jason.encode!(err))
    end

    test "an input killed by a linked process's exit ends with :input_crashed; the consumer lives" do
      input =
        Stream.resource(
          fn -> spawn_link(fn -> exit(:boom) end) end,
          fn pid ->
            receive do
            after
              :infinity -> {[], pid}
            end
          end,
          fn _ -> :ok end
        )

      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), input, [])

      assert {:error, %SpeechAdapterError{metadata: %{cause: :input_crashed}, cause: cause}} =
               stream |> Enum.to_list() |> List.last()

      assert cause == %{kind: :exit, message: "** (exit) :boom"}
      assert Process.alive?(self())
      refute_received {:DOWN, _, :process, _, _}
    end

    test "a mailbox-dependent input times out: the input is reduced in another process" do
      input = Stream.repeatedly(fn -> receive(do: ({:t, x} -> x)) end)
      send(self(), {:t, "a"})

      assert {:ok, stream} =
               FakeSpeech.stream_synthesize_input(request(), input, stream_timeout: 100)

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :timeout}}] =
               Enum.to_list(stream)

      # The test process's own message was never consumed by the input.
      assert_received {:t, "a"}
    end

    test "the stream timeout resets on every input message, so a slow but steady input does not time out" do
      input = Stream.map(1..4, fn n -> Process.sleep(60) && "w#{n}" end)

      assert {:ok, stream} =
               FakeSpeech.stream_synthesize_input(request(), input, stream_timeout: 150)

      events = Enum.to_list(stream)
      assert {:speech_completed, _} = List.last(events)
      assert length(for {:audio_delta, _} <- events, do: 1) == 4
    end

    test "a halt stops the pump and leaves no pump message in the consumer's mailbox" do
      test_pid = self()

      input =
        Stream.repeatedly(fn ->
          send(test_pid, {:pump_is, self()})
          "word"
        end)

      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), input, [])
      assert [{:speech_started, _}, {:audio_delta, _}] = Enum.take(stream, 2)

      assert_received {:pump_is, pump}
      assert wait_until(fn -> not Process.alive?(pump) end)
      refute_received {_ref, {:input, _}}
      refute_received {_ref, :input_done}
      refute_received {:DOWN, _, :process, ^pump, _}
    end

    test "adapter_opts[:input_window] bounds the unacknowledged input" do
      test_pid = self()

      input =
        Stream.map(1..100, fn n ->
          send(test_pid, {:pulled, n})
          "w"
        end)

      opts = [adapter_opts: [input_window: 2]]
      assert {:ok, stream} = FakeSpeech.stream_synthesize_input(request(), input, opts)

      # Suspend after :speech_started: the pump is running and nothing has
      # been acknowledged. It pulls a third element, then blocks on credit.
      assert {:suspended, [{:speech_started, _}], continuation} =
               Enumerable.reduce(stream, {:cont, []}, fn event, acc -> {:suspend, [event | acc]} end)

      assert_receive {:pulled, 3}
      refute_receive {:pulled, 4}, 50

      assert {:halted, _} = continuation.({:halt, []})
    end
  end

  defp wait_until(fun, ms \\ 500) do
    Enum.reduce_while(1..div(ms, 5), false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(5) && {:cont, false}
    end)
  end
end
