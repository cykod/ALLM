defmodule ALLM.Providers.Support.TranscriptionAdapterTest do
  @moduledoc """
  Unit tests for `ALLM.Providers.Support.TranscriptionAdapter`. Every helper
  is exercised once per bundled transcription adapter, so a helper that
  hard-codes one provider atom into `:provider` or a message fails for the
  other.
  """

  use ExUnit.Case, async: true

  alias ALLM.{
    Audio,
    TranscriptionRequest,
    TranscriptionResponse,
    TranscriptionStreamRequest,
    TranscriptSpan
  }

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.OpenAI
  alias ALLM.Providers.Support.TranscriptionAdapter, as: Support

  @providers [
    {:openai, OpenAI.Transcription, "sk-support-test", %{"text" => "hello"}},
    {:gemini, Gemini.Transcription, "AIza-support-test",
     %{
       "candidates" => [
         %{"content" => %{"parts" => [%{"text" => "hello"}]}, "finishReason" => "STOP"}
       ]
     }}
  ]

  defp mp3, do: Audio.from_binary("ID3", "audio/mpeg")

  for {provider, adapter, key, ok_body} <- @providers do
    describe "#{provider}" do
      @provider provider
      @adapter adapter
      @key key
      @ok_body ok_body

      setup do
        {:ok,
         stub: String.to_atom("stt_support_#{@provider}_#{System.unique_integer([:positive])}")}
      end

      test "fetch_transcription_script/1 reads adapter_opts[:transcription_script]" do
        assert Support.fetch_transcription_script(adapter_opts: [transcription_script: [:x]]) ==
                 [:x]

        assert Support.fetch_transcription_script([]) == nil
      end

      test "with_own_cap/2 sets the adapter's cap and keeps the other adapter_opts" do
        opts =
          Support.with_own_cap(
            [api_key: @key, adapter_opts: [transcription_script: [:x]]],
            @adapter.max_audio_bytes()
          )

        assert opts[:api_key] == @key
        assert opts[:adapter_opts][:transcription_script] == [:x]
        assert opts[:adapter_opts][:max_audio_bytes] == @adapter.max_audio_bytes()
      end

      test "measure/3 counts resolvable audio and reports unresolvable audio" do
        assert Support.measure(mp3(), @provider, []) == {:ok, 3}

        assert {:error, %TranscriptionAdapterError{provider: @provider} = err} =
                 Support.measure(Audio.from_file("/nonexistent.mp3"), @provider, request_id: "r1")

        assert err.metadata == %{field: :audio, cause: :enoent, request_id: "r1"}

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :invalid_source}}} =
                 Support.measure(:not_audio, @provider, [])
      end

      test "gate_size/4 passes at the cap and refuses one byte over it" do
        assert Support.gate_size(10, 10, @provider, []) == :ok

        assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
                 Support.gate_size(11, 10, @provider, request_id: "r1")

        assert err.provider == @provider
        assert err.message == "audio is 11 bytes, over max_audio_bytes 10"
        assert err.metadata == %{field: :audio, count: 11, max: 10, request_id: "r1"}
      end

      test "unresolvable_error/3 names the cause and the provider" do
        err = Support.unresolvable_error(:eisdir, @provider, [])
        assert %TranscriptionAdapterError{reason: :invalid_request, provider: @provider} = err
        assert err.message == "audio bytes could not be resolved (:eisdir)"
        assert err.metadata == %{field: :audio, cause: :eisdir}
      end

      test "stub_error/2 is an :unknown error for the provider" do
        assert %TranscriptionAdapterError{reason: :unknown, provider: @provider} =
                 err = Support.stub_error(@provider, request_id: "r1")

        assert err.metadata == %{request_id: "r1"}
      end

      test "transport_error/5 builds the provider's error and sanitises a decode cause" do
        {:error, cause} = Jason.decode("{secret")
        err = Support.transport_error(:network_error, "boom", cause, @provider, [])

        assert %TranscriptionAdapterError{reason: :network_error, provider: @provider} = err
        assert %Jason.DecodeError{data: "", position: 0} = err.cause
      end

      test "resolve_bytes/3 returns the bytes or the provider's unresolvable error" do
        assert Support.resolve_bytes(mp3(), @provider, []) == {:ok, "ID3"}

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :enoent}}} =
                 Support.resolve_bytes(Audio.from_file("/nonexistent.mp3"), @provider, [])
      end

      test "do_transcribe/4 runs the adapter's gates before key resolution" do
        request = TranscriptionRequest.new(audio: Audio.from_file("/nonexistent.mp3"))

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :enoent}}} =
                 Support.do_transcribe(@adapter, @provider, request, [])
      end

      test "do_transcribe/4 makes exactly one attempt and decodes through the adapter", %{
        stub: stub
      } do
        parent = self()

        Req.Test.stub(stub, fn conn ->
          send(parent, :attempt)
          Req.Test.json(conn, @ok_body)
        end)

        opts = [api_key: @key, adapter_opts: [plug: {Req.Test, stub}]]

        assert {:ok, %TranscriptionResponse{text: "hello", provider: @provider}} =
                 Support.do_transcribe(
                   @adapter,
                   @provider,
                   TranscriptionRequest.new(audio: mp3()),
                   opts
                 )

        assert_received :attempt
        refute_received :attempt
      end

      test "run_one_attempt/5 classifies non-2xx, transport and undecodable responses", %{
        stub: stub
      } do
        request = TranscriptionRequest.new(audio: mp3())
        http = Req.new(url: "https://example.invalid", retry: false, plug: {Req.Test, stub})

        Req.Test.stub(stub, &Plug.Conn.send_resp(&1, 503, ""))

        assert {:error,
                %TranscriptionAdapterError{reason: :provider_unavailable, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

        assert {:error, %TranscriptionAdapterError{reason: :timeout, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))

        assert {:error, %TranscriptionAdapterError{reason: :network_error, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "{not json")
        end)

        assert {:error, %TranscriptionAdapterError{reason: :malformed_response} = err} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        assert err.provider == @provider
        assert %Jason.DecodeError{data: "", position: 0} = err.cause
      end
    end
  end

  # Provider-independent: added in 26.6 when ElevenLabs.Transcription became
  # the second multipart transcription adapter.
  describe "multipart option helpers" do
    test "optional_field/2 is empty for nil and one field otherwise" do
      assert Support.optional_field("language", nil) == []
      assert Support.optional_field("language", "en") == [{"language", "en"}]
    end

    test "option_fields/2 stringifies, sorts, expands lists and encodes values" do
      options = %{
        :z => 1,
        "a" => ["x", "y"],
        "m" => nil,
        "flag" => true,
        "map" => %{"k" => 1},
        "model" => "dropped"
      }

      assert Support.option_fields(options, ["model"]) ==
               {[
                  {"a", "x"},
                  {"a", "y"},
                  {"flag", "true"},
                  {"map", ~s({"k":1})},
                  {"z", "1"}
                ], ["model"]}
    end

    test "option_fields/2 on a non-map is empty" do
      assert Support.option_fields(nil, ["model"]) == {[], []}
    end
  end

  describe "span helpers" do
    test "span_from/6 keeps times only under timestamps: true and logprob only under logprobs: true" do
      cells = [
        {false, false, nil, nil, nil},
        {true, false, 1.0, 1.5, nil},
        {false, true, nil, nil, -0.25},
        {true, true, 1.0, 1.5, -0.25}
      ]

      for {ts, lp, start, stop, logprob} <- cells,
          request <- [
            TranscriptionRequest.new(audio: mp3(), timestamps: ts, logprobs: lp),
            TranscriptionStreamRequest.new(timestamps: ts, logprobs: lp)
          ] do
        assert Support.span_from("fox", :word, 1.0, 1.5, -0.25, request) ==
                 %TranscriptSpan{
                   text: "fox",
                   kind: :word,
                   start_seconds: start,
                   end_seconds: stop,
                   logprob: logprob
                 },
               "cell timestamps: #{ts}, logprobs: #{lp} on #{inspect(request.__struct__)}"
      end
    end

    test "span_from/6 treats a non-true flag value as off" do
      request = %TranscriptionRequest{audio: mp3(), timestamps: "yes", logprobs: 1}

      assert %TranscriptSpan{start_seconds: nil, end_seconds: nil, logprob: nil} =
               Support.span_from("fox", :word, 1.0, 1.5, -0.25, request)
    end

    test "decode_span_list/3 builds spans in order from maps with a binary text key" do
      build = fn entry, text -> {text, entry["n"]} end

      assert Support.decode_span_list([%{"t" => "a", "n" => 1}, %{"t" => "b"}], "t", build) ==
               {:ok, [{"a", 1}, {"b", nil}]}

      assert Support.decode_span_list([], "t", build) == {:ok, []}
    end

    test "decode_span_list/3 is :error for a non-list or any off-shape entry" do
      build = fn _entry, text -> text end

      for entries <- [
            nil,
            %{"t" => "a"},
            "a",
            [%{"t" => "a"}, %{"other" => "b"}],
            [%{"t" => 1}],
            [%{"t" => "a"}, "b"]
          ] do
        assert Support.decode_span_list(entries, "t", build) == :error, inspect(entries)
      end
    end

    test "number_or_nil/1 keeps numbers and nils everything else" do
      assert Support.number_or_nil(1) == 1
      assert Support.number_or_nil(-0.5) == -0.5
      assert Support.number_or_nil("1.0") == nil
      assert Support.number_or_nil(nil) == nil
    end

    test "gate_flags/4 refuses :timestamps before :logprobs" do
      request = TranscriptionRequest.new(audio: mp3(), timestamps: true, logprobs: true)

      assert {:error,
              %TranscriptionAdapterError{
                reason: :unsupported_feature,
                provider: :openai,
                metadata: %{field: :timestamps}
              }} = Support.gate_flags(request, [], :openai, [])

      assert {:error, %TranscriptionAdapterError{metadata: %{field: :logprobs}}} =
               Support.gate_flags(request, [:timestamps], :openai, [])
    end

    test "gate_flags/4 carries the provider (nil allowed) and the request id" do
      request = TranscriptionStreamRequest.new(logprobs: true)

      assert {:error, %TranscriptionAdapterError{provider: nil} = err} =
               Support.gate_flags(request, [:timestamps], nil, request_id: "rid-g")

      assert err.metadata == %{field: :logprobs, request_id: "rid-g"}
      assert err.message =~ "logprobs"
    end

    test "gate_flags/4 passes supported flags, unset flags and non-true values" do
      assert :ok =
               Support.gate_flags(
                 TranscriptionRequest.new(audio: mp3(), timestamps: true, logprobs: true),
                 [:timestamps, :logprobs],
                 :elevenlabs,
                 []
               )

      assert :ok = Support.gate_flags(TranscriptionRequest.new(audio: mp3()), [], :openai, [])

      assert :ok =
               Support.gate_flags(
                 %TranscriptionRequest{audio: mp3(), timestamps: "no", logprobs: 1},
                 [],
                 :openai,
                 []
               )
    end

    test "with_span_flags/2 stores the list at adapter_opts[:span_flags] and keeps the rest" do
      opts = [request_id: "r", adapter_opts: [transcription_script: [{:ok, "x"}]]]
      out = Support.with_span_flags(opts, [:logprobs])

      assert out[:adapter_opts][:span_flags] == [:logprobs]
      assert out[:adapter_opts][:transcription_script] == [{:ok, "x"}]
      assert out[:request_id] == "r"
      assert Support.with_span_flags([], [])[:adapter_opts] == [span_flags: []]
    end

    test "flag_on?/2 and spans_requested?/1 count a flag only when it is exactly true" do
      for base <- [TranscriptionRequest.new(audio: mp3()), TranscriptionStreamRequest.new()],
          off <- [false, nil, "true", 1, :yes] do
        req = %{base | timestamps: off, logprobs: off}
        refute Support.flag_on?(req, :timestamps)
        refute Support.flag_on?(req, :logprobs)
        refute Support.spans_requested?(req)
      end

      base = TranscriptionRequest.new(audio: mp3())
      assert Support.spans_requested?(%{base | timestamps: true})
      assert Support.spans_requested?(%{base | logprobs: true})
      assert Support.flag_on?(%{base | logprobs: true}, :logprobs)
      refute Support.flag_on?(%{base | logprobs: true}, :timestamps)
    end

    test "blank_text?/1 is true only for empty-after-trim text" do
      for blank <- ["", " ", "\n\t  "], do: assert(Support.blank_text?(blank))
      for text <- ["a", " a ", "."], do: refute(Support.blank_text?(text))
    end

    test "absent_spans/5 on a blank transcript is {:ok, []}" do
      for request <- [
            TranscriptionRequest.new(audio: mp3(), timestamps: true),
            TranscriptionStreamRequest.new(logprobs: true)
          ] do
        assert Support.absent_spans("  ", request, :openai, "src", []) == {:ok, []}
      end
    end

    test "absent_spans/5 on a non-blank transcript is :unsupported_feature naming the first flag" do
      for {provider, ts, lp, field} <- [
            {:elevenlabs, true, false, :timestamps},
            {:openai, false, true, :logprobs},
            {:gemini, true, true, :timestamps},
            {nil, true, true, :timestamps}
          ] do
        request = TranscriptionRequest.new(audio: mp3(), timestamps: ts, logprobs: lp)

        assert {:error,
                %TranscriptionAdapterError{reason: :unsupported_feature, provider: ^provider} =
                  err} =
                 Support.absent_spans("hi there", request, provider, "X returned no spans",
                   request_id: "rid-a"
                 )

        assert err.metadata == %{
                 field: field,
                 cause: :absent_from_response,
                 text: "hi there",
                 request_id: "rid-a"
               }

        assert err.message == "X returned no spans for #{field}: true"
      end
    end

    test "put_adapter_opt/3 sets one adapter opt and keeps the rest" do
      out = Support.put_adapter_opt([api_key: "x", adapter_opts: [cursor_key: 7]], :k, :v)

      assert out[:adapter_opts][:k] == :v
      assert out[:adapter_opts][:cursor_key] == 7
      assert out[:api_key] == "x"
      assert Support.put_adapter_opt([], :k, 1) == [adapter_opts: [k: 1]]
    end
  end

  # The sub-phase closing the bundled transcription family (28.5) owns its
  # internal consistency: every adapter refuses or passes each span-flag cell
  # exactly as the design's wire-field map says, with no I/O. Pass cells
  # drive `prepare_request/2` (gates + build, never sent) with an explicit
  # key. Refusal cells assert the refusal three ways: from `gate_audio/2`
  # itself, which `do_transcribe/4` runs before `build_request/2` (where
  # `Keys.fetch!/2` lives) — this is what pins gate-before-key regardless of
  # any `*_API_KEY` the shell exports; from `prepare_request/2`; and keyless
  # through `transcribe/2` behind a plug that flunks, which pins
  # gate-before-HTTP only (with a key exported, a gate moved after
  # `Keys.fetch!/2` but before the send would still pass that assertion).
  # The ElevenLabs realtime column
  # uses `ALLM.Test.RaisingWebSocket`, which raises if a socket is opened.
  describe "span-flag family consistency (no I/O)" do
    @cells [
      {false, false},
      {true, false},
      {false, true},
      {true, true}
    ]

    # {adapter, {timestamps, logprobs}} => :pass | {:refuse, field}
    @expected %{
      {ALLM.Providers.ElevenLabs.Transcription, {false, false}} => :pass,
      {ALLM.Providers.ElevenLabs.Transcription, {true, false}} => :pass,
      {ALLM.Providers.ElevenLabs.Transcription, {false, true}} => :pass,
      {ALLM.Providers.ElevenLabs.Transcription, {true, true}} => :pass,
      {OpenAI.Transcription, {false, false}} => :pass,
      {OpenAI.Transcription, {true, false}} => {:refuse, :timestamps},
      {OpenAI.Transcription, {false, true}} => :pass,
      {OpenAI.Transcription, {true, true}} => {:refuse, :timestamps},
      {Gemini.Transcription, {false, false}} => :pass,
      {Gemini.Transcription, {true, false}} => {:refuse, :timestamps},
      {Gemini.Transcription, {false, true}} => {:refuse, :logprobs},
      {Gemini.Transcription, {true, true}} => {:refuse, :timestamps}
    }

    @flunk_plug [adapter_opts: [plug: &__MODULE__.flunk_plug/1]]
    def flunk_plug(_conn), do: flunk("a refused span flag reached HTTP")

    test "the expectation table covers every adapter x flag cell" do
      assert map_size(@expected) == 3 * length(@cells)
    end

    for {{adapter, {ts, lp}}, outcome} <- @expected do
      @adapter adapter
      @ts ts
      @lp lp
      @outcome outcome

      test "#{inspect(adapter)} batch timestamps: #{ts}, logprobs: #{lp} -> #{inspect(outcome)}" do
        request = TranscriptionRequest.new(audio: mp3(), timestamps: @ts, logprobs: @lp)

        case @outcome do
          :pass ->
            assert {:ok, %Req.Request{}} = @adapter.prepare_request(request, api_key: "test-key")

          {:refuse, field} ->
            assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature} = gated} =
                     @adapter.gate_audio(request, [])

            assert gated.metadata.field == field

            assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature} = err} =
                     @adapter.prepare_request(request, api_key: "test-key")

            assert err.metadata.field == field

            assert {:error, %TranscriptionAdapterError{reason: :unsupported_feature} = keyless} =
                     @adapter.transcribe(request, @flunk_plug)

            assert keyless.metadata.field == field
        end
      end
    end

    for {ts, lp} <- @cells do
      @ts ts
      @lp lp

      test "ElevenLabs realtime timestamps: #{ts}, logprobs: #{lp} -> :pass (no socket opened)" do
        request = TranscriptionStreamRequest.new(timestamps: @ts, logprobs: @lp)

        assert {:ok, _events} =
                 ALLM.Providers.ElevenLabs.Transcription.stream_transcribe(request, [],
                   api_key: "test-key",
                   ws_module: ALLM.Test.RaisingWebSocket
                 )
      end
    end
  end
end
