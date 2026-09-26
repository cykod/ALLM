defmodule ALLM.Providers.OpenAI.SpeechStreamTest do
  @moduledoc """
  Wire tests for `ALLM.Providers.OpenAI.Speech.stream_synthesize/2`, driven
  through `ALLM.Test.FinchStub` (the `:finch_module` seam), plus a replay of
  the recorded streaming fixtures in the framing OpenAI used.

  The keyless gate tests pass a `:finch_module` that raises, so a gate moved
  after key resolution or after the transport call fails even in a shell
  that exports `OPENAI_API_KEY`.
  """

  use ExUnit.Case, async: true

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.OpenAI.Speech
  alias ALLM.Providers.OpenAITestFixtures, as: Fixtures
  alias ALLM.SpeechEvent
  alias ALLM.SpeechRequest
  alias ALLM.Test.{FinchStub, RaisingFinch}

  # Delivers every frame synchronously inside `async_request/3`, so all of
  # them are already queued in the caller's mailbox before the stream reads
  # the first one. Counts cancels in the caller's process dictionary.
  defmodule BurstFinch do
    @moduledoc false
    def async_request(_req, _name, opts) do
      ref = make_ref()
      send(self(), {ref, {:status, 200}})
      send(self(), {ref, {:headers, [{"content-type", "audio/pcm"}]}})
      for chunk <- Keyword.fetch!(opts, :finch_stub_ref), do: send(self(), {ref, {:data, chunk}})
      send(self(), {ref, :done})
      Process.put(:burst_ref, ref)
      ref
    end

    def cancel_async_request(ref) do
      Process.put({:burst_cancel, ref}, Process.get({:burst_cancel, ref}, 0) + 1)
      :ok
    end
  end

  # Forwards to FinchStub after telling the reducing process (here, the test
  # process) which request and pool it was asked for.
  defmodule CapturingFinch do
    @moduledoc false
    def async_request(req, name, opts) do
      send(self(), {:finch_request, req, name})
      FinchStub.async_request(req, name, opts)
    end

    defdelegate cancel_async_request(ref), to: FinchStub
  end

  @pcm_headers [{"content-type", "audio/pcm"}, {"x-request-id", "req_stub"}]

  defp req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))

  defp stub_opts(stub_ref, opts \\ []) do
    Keyword.merge(
      [api_key: "sk-stream-test", finch_module: FinchStub, finch_stub_ref: stub_ref],
      opts
    )
  end

  defp keyless_raising, do: [finch_module: RaisingFinch]

  # ---------------------------------------------------------------------------
  # Happy path and laziness
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "200 + audio/pcm + three chunks -> started, three deltas, completed" do
      ref = FinchStub.install(["a", "bb", "ccc"], initial_headers: @pcm_headers)

      assert {:ok, stream} =
               Speech.stream_synthesize(
                 req(format: :pcm, metadata: %{"k" => "v"}),
                 stub_opts(ref, request_id: "rid-1")
               )

      assert [
               {:speech_started, started},
               {:audio_delta, "a"},
               {:audio_delta, "bb"},
               {:audio_delta, "ccc"},
               {:speech_completed, completed}
             ] = Enum.to_list(stream)

      assert started == %{
               request_id: "rid-1",
               model: "gpt-4o-mini-tts",
               provider: :openai,
               format: :pcm,
               mime_type: "audio/pcm",
               sample_rate: 24_000
             }

      assert completed == %{
               request_id: "rid-1",
               id: nil,
               usage: %ALLM.Usage{},
               metadata: %{"k" => "v"}
             }
    end

    test "an mp3 stream reports sample_rate nil, and x-request-id is the fallback id" do
      ref =
        FinchStub.install(["ID3"],
          initial_headers: [{"content-type", "audio/mpeg"}, {"x-request-id", "req_hdr"}]
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))
      [{:speech_started, started} | _] = events = Enum.to_list(stream)

      assert %{format: :mp3, sample_rate: nil, request_id: "req_hdr"} = started
      assert {:speech_completed, %{request_id: "req_hdr"}} = List.last(events)
    end

    test "the request body is the non-streaming body, JSON-encoded" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers)
      finch_module = CapturingFinch

      request = req(format: :pcm)
      {:ok, stream} = Speech.stream_synthesize(request, stub_opts(ref, finch_module: finch_module))
      Enum.to_list(stream)

      assert_received {:finch_request, %Finch.Request{} = finch_req, ALLM.Finch}
      assert finch_req.method == "POST"
      assert finch_req.path == "/v1/audio/speech"
      assert Jason.decode!(finch_req.body) == Speech.to_json_body(request, [])
      refute Map.has_key?(Jason.decode!(finch_req.body), "stream_format")
    end

    test "stream_synthesize/2 does not call async_request until the stream is reduced" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers)
      assert {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))
      assert FinchStub.captured_opts(ref) == nil

      Enum.to_list(stream)
      assert is_list(FinchStub.captured_opts(ref))
    end

    test "engine adapter_opts transport opts reach the adapter through the facade, and the receive timeout sits above stream_timeout" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers)

      engine =
        ALLM.Engine.new(
          speech_adapter: Speech,
          adapter_opts: [finch_module: FinchStub, finch_stub_ref: ref, stream_timeout: 5_000]
        )

      {:ok, stream} = ALLM.stream_synthesize(engine, req(format: :pcm), api_key: "sk-x")

      assert [{:speech_started, _}, {:audio_delta, "a"}, {:speech_completed, _}] =
               Enum.to_list(stream)

      assert FinchStub.captured_opts(ref)[:receive_timeout] == 35_000
    end

    test "every emitted element is a SpeechEvent" do
      ref = FinchStub.install(["a", "b"], initial_headers: @pcm_headers)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))
      assert Enum.all?(Enum.to_list(stream), &SpeechEvent.event?/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Gates (keyless, before any Finch call)
  # ---------------------------------------------------------------------------

  describe "pre-flight gates (keyless, raising :finch_module)" do
    test "4097 code points -> synchronous :context_length_exceeded" do
      assert {:error, %SpeechAdapterError{reason: :context_length_exceeded}} =
               Speech.stream_synthesize(req(input: String.duplicate("a", 4097)), keyless_raising())
    end

    test "empty input -> synchronous :invalid_request" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{field: :input}}} =
               Speech.stream_synthesize(req(input: ""), keyless_raising())
    end

    test "pcm at 16_000 -> :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature, metadata: meta}} =
               Speech.stream_synthesize(req(format: :pcm, sample_rate: 16_000), keyless_raising())

      assert %{field: :sample_rate, sample_rate: 16_000, format: :pcm} = meta
    end

    test "mp3 at 24_000 -> :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature}} =
               Speech.stream_synthesize(req(format: :mp3, sample_rate: 24_000), keyless_raising())
    end

    # Falsifier: a gate that accepts 24_000 only for :pcm.
    for format <- [:pcm, :wav] do
      test "#{format} at 24_000 passes the gate and reaches the transport" do
        ref = FinchStub.install(["x"], initial_headers: @pcm_headers)

        {:ok, stream} =
          Speech.stream_synthesize(
            req(format: unquote(format), sample_rate: 24_000),
            stub_opts(ref)
          )

        Enum.to_list(stream)
        assert is_list(FinchStub.captured_opts(ref))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-stream errors
  # ---------------------------------------------------------------------------

  describe "HTTP error status (body buffered, then classified)" do
    test "401 with a planted sk- token -> :authentication_failed, redacted" do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" => "Incorrect API key provided: sk-proj-PLANTEDabcdef123456.",
            "type" => "invalid_request_error",
            "code" => "invalid_api_key sk-PLANTEDzzzzzzzz"
          }
        })

      {part1, part2} = String.split_at(body, 20)

      ref =
        FinchStub.install([],
          initial_status: 401,
          initial_headers: [{"content-type", "text/plain"}],
          error_body: [part1, part2]
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))
      assert [{:error, %SpeechAdapterError{} = err}] = Enum.to_list(stream)

      assert err.reason == :authentication_failed
      assert err.status == 401
      assert err.message =~ "Incorrect API key provided"
      refute inspect(err) =~ "sk-proj-PLANTED"
      refute inspect(err) =~ "sk-PLANTED"
      assert inspect(err) =~ "[REDACTED]"
      refute Jason.encode!(err) =~ ~r/sk-[A-Za-z]/
    end

    test "a 400 string_too_long body -> :context_length_exceeded" do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" =>
              "[{'type': 'string_too_long', 'msg': 'String should have at most 4096 characters'}]",
            "type" => "invalid_request_error",
            "code" => nil
          }
        })

      ref =
        FinchStub.install([],
          initial_status: 400,
          initial_headers: [{"content-type", "application/json"}],
          error_body: body
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :context_length_exceeded}}] =
               Enum.to_list(stream)
    end

    test "429 honours Retry-After on the terminal error" do
      ref =
        FinchStub.install([],
          initial_status: 429,
          initial_headers: [{"retry-after", "2"}],
          error_body: ~s({"error":{"message":"slow down"}})
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 2_000}}] =
               Enum.to_list(stream)
    end

    test "200 with content-type application/json -> :malformed_response, and the request is cancelled" do
      ref =
        FinchStub.install([~s({"not":"audio"})],
          initial_headers: [{"content-type", "application/json"}],
          delay_ms: 50
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))
      assert [{:error, %SpeechAdapterError{reason: :malformed_response}}] = Enum.to_list(stream)
      assert FinchStub.cancel_count(ref) == 1
    end

    test "200 with no audio bytes -> :invalid_request, cause :empty_input" do
      ref = FinchStub.install([], initial_headers: @pcm_headers)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))

      assert [
               {:speech_started, _},
               {:error,
                %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}
             ] = Enum.to_list(stream)
    end

    test "a transport error mid-stream -> :network_error after the deltas already sent" do
      ref =
        FinchStub.install(["a", {:terminal_error, %Mint.TransportError{reason: :closed}}],
          initial_headers: @pcm_headers
        )

      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))

      assert [
               {:speech_started, _},
               {:audio_delta, "a"},
               {:error, %SpeechAdapterError{reason: :network_error}}
             ] = Enum.to_list(stream)

      # The transport reported its end, so nothing is left to cancel.
      assert FinchStub.cancel_count(ref) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Halt, drain, timeout
  # ---------------------------------------------------------------------------

  describe "halt-safety and stream_timeout" do
    test "Enum.take/2 halts the stream and cancels the request once" do
      ref = FinchStub.install(["a", "b", "c", "d"], initial_headers: @pcm_headers, delay_ms: 20)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))

      assert [{:speech_started, _}, {:audio_delta, "a"}] = Enum.take(stream, 2)
      assert FinchStub.cancel_count(ref) == 1
    end

    test "a completed stream is not cancelled" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), stub_opts(ref))
      Enum.to_list(stream)
      assert FinchStub.cancel_count(ref) == 0
    end

    # Every frame is queued before the first is read, so chunks are still in
    # the mailbox when `Enum.take/2` halts. Falsifier: an after function that
    # cancels without draining leaves `{ref, _}` messages behind.
    test "a halt drains the request's queued messages from the mailbox" do
      chunks = ["1", "2", "3", "4", "5"]

      {:ok, stream} =
        Speech.stream_synthesize(req(format: :pcm),
          api_key: "sk-x",
          finch_module: BurstFinch,
          finch_stub_ref: chunks
        )

      assert [{:speech_started, _}, {:audio_delta, "1"}] = Enum.take(stream, 2)

      ref = Process.get(:burst_ref)
      assert Process.get({:burst_cancel, ref}) == 1
      refute_received {^ref, _}
    end

    test "stream_timeout: 50 with 200 ms between chunks -> terminal :timeout" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers, delay_ms: 200)

      {:ok, stream} =
        Speech.stream_synthesize(req(format: :pcm), stub_opts(ref, stream_timeout: 50))

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :timeout}}] =
               Enum.to_list(stream)

      assert FinchStub.cancel_count(ref) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Script hand-off
  # ---------------------------------------------------------------------------

  describe "script hand-off" do
    test "with speech_script set, the Fake stream runs and Finch is never called" do
      long = String.duplicate("a", 4097)

      assert {:ok, stream} =
               Speech.stream_synthesize(
                 req(input: long),
                 finch_module: RaisingFinch,
                 adapter_opts: [speech_script: [{:ok, "AUDIO"}]]
               )

      assert [{:speech_started, _}, {:audio_delta, "AUDIO"}, {:speech_completed, _}] =
               Enum.to_list(stream)
    end
  end

  # ---------------------------------------------------------------------------
  # FinchStub defaults (the 26.5 install options leave existing callers alone)
  # ---------------------------------------------------------------------------

  describe "FinchStub install options" do
    test "the defaults leave the frame sequence unchanged" do
      ref = FinchStub.install(["x", "y"], [])
      ^ref = FinchStub.async_request(:req, :name, finch_stub_ref: ref)

      frames = collect_frames(ref)

      assert frames == [
               {:status, 200},
               {:headers, []},
               {:data, "x"},
               {:data, "y"},
               :done
             ]
    end

    test ":initial_headers and :error_body send status, headers, body parts, :done" do
      ref =
        FinchStub.install(["ignored"],
          initial_status: 500,
          initial_headers: [{"content-type", "text/plain"}],
          error_body: ["e1", "e2"]
        )

      ^ref = FinchStub.async_request(:req, :name, finch_stub_ref: ref)

      assert collect_frames(ref) == [
               {:status, 500},
               {:headers, [{"content-type", "text/plain"}]},
               {:data, "e1"},
               {:data, "e2"},
               :done
             ]
    end
  end

  defp collect_frames(ref, acc \\ []) do
    receive do
      {^ref, :done} -> Enum.reverse([:done | acc])
      {^ref, frame} -> collect_frames(ref, [frame | acc])
    after
      1_000 -> flunk("stub stopped before :done; got #{inspect(Enum.reverse(acc))}")
    end
  end

  # ---------------------------------------------------------------------------
  # Recorded streaming fixtures, replayed in OpenAI's own framing
  # ---------------------------------------------------------------------------

  describe "recorded streaming fixtures" do
    for {name, format, rate} <- [{:stream_pcm, :pcm, 24_000}, {:stream_mp3_tts1, :mp3, nil}] do
      test "#{name}: one delta per recorded chunk, concatenating to the recorded body" do
        env = Fixtures.speech_recorded(unquote(name))
        chunks = Fixtures.speech_stream_chunks(env)
        headers = Enum.to_list(env["headers"])

        # The recorded response really streamed: many chunks, spread in time.
        assert length(env["chunks"]) >= 2
        assert hd(env["chunks"])["t_ms"] < List.last(env["chunks"])["t_ms"]
        assert env["headers"]["transfer-encoding"] == "chunked"

        ref = FinchStub.install(chunks, initial_headers: headers, delay_ms: 0)
        {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref, request_id: nil))
        events = Enum.to_list(stream)

        assert {:speech_started, %{format: unquote(format), sample_rate: unquote(rate)} = started} =
                 hd(events)

        assert started.request_id == env["headers"]["x-request-id"]
        assert {:speech_completed, _} = List.last(events)

        deltas = for {:audio_delta, bytes} <- events, do: bytes
        assert length(deltas) == length(chunks)
        assert IO.iodata_to_binary(deltas) == Fixtures.envelope_bytes(env)
      end
    end

    test "stream_error_401: the recorded text/plain body classifies as :authentication_failed" do
      env = Fixtures.speech_recorded(:stream_error_401)
      assert env["headers"]["content-type"] == "text/plain"

      ref =
        FinchStub.install([],
          initial_status: env["status"],
          initial_headers: Enum.to_list(env["headers"]),
          error_body: Fixtures.speech_stream_chunks(env)
        )

      {:ok, stream} = Speech.stream_synthesize(req(), stub_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :authentication_failed} = err}] =
               Enum.to_list(stream)

      assert err.metadata.openai_code == "invalid_api_key"
      assert err.message =~ "Incorrect API key provided"
    end
  end
end
