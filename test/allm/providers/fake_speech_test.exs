defmodule ALLM.Providers.FakeSpeechTest do
  use ExUnit.Case, async: true

  alias ALLM.{Audio, Engine, SpeechRequest, SpeechResponse, Usage}
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
end
