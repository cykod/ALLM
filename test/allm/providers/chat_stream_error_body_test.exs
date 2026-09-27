defmodule ALLM.Providers.ChatStreamErrorBodyTest do
  @moduledoc """
  Family tests for the three bundled chat stream adapters
  (`ALLM.Providers.OpenAI` on both endpoints, `ALLM.Providers.Anthropic`,
  `ALLM.Providers.Gemini`) on two axes they share with
  `ALLM.Providers.OpenAI.Speech.stream_synthesize/2`:

    * a non-2xx response's body and headers are buffered until the
      transport's `:done` and handed to the adapter's error classifier, so
      the terminal `{:error, %AdapterError{}}` carries the provider's
      message (key material redacted) and `retry_after_ms`;
    * a stream the consumer halts early leaves no `{ref, _}` Finch message
      in the reducing process's mailbox.

  Driven through `ALLM.Test.FinchStub` and a burst stub; no host is
  reached. Keys are passed per call.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.Message
  alias ALLM.Providers.{Anthropic, Gemini, OpenAI}
  alias ALLM.Providers.AnthropicTestFixtures
  alias ALLM.Providers.GeminiTestFixtures
  alias ALLM.Providers.OpenAITestFixtures
  alias ALLM.Request
  alias ALLM.Response
  alias ALLM.Test.FinchStub

  # Delivers every frame synchronously inside `async_request/3`, so all of
  # them are queued in the caller's mailbox before the stream reads the
  # first. Counts cancels in the caller's process dictionary.
  defmodule BurstFinch do
    @moduledoc false
    def async_request(_req, _name, opts) do
      ref = make_ref()
      send(self(), {ref, {:status, 200}})
      send(self(), {ref, {:headers, []}})
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

  @arms [:openai_chat, :openai_responses, :anthropic, :gemini]

  defp adapter(:openai_chat), do: OpenAI
  defp adapter(:openai_responses), do: OpenAI
  defp adapter(:anthropic), do: Anthropic
  defp adapter(:gemini), do: Gemini

  defp model(:openai_chat), do: "gpt-4o-mini"
  defp model(:openai_responses), do: "gpt-5.5"
  defp model(:anthropic), do: "claude-sonnet-4-6"
  defp model(:gemini), do: "gemini-2.5-flash"

  defp api_key(:anthropic), do: "sk-ant-stream-test"
  defp api_key(:gemini), do: "AIza-stream-test"
  defp api_key(_openai), do: "sk-stream-test"

  defp provider(:anthropic), do: :anthropic
  defp provider(:gemini), do: :gemini
  defp provider(_openai), do: :openai

  defp happy_chunks(:openai_chat), do: OpenAITestFixtures.stream_chunks(:happy_text_stream)
  defp happy_chunks(:openai_responses), do: OpenAITestFixtures.responses_stream_chunks(:happy_text)
  defp happy_chunks(:anthropic), do: AnthropicTestFixtures.stream_chunks(:happy_text)
  defp happy_chunks(:gemini), do: GeminiTestFixtures.stream_chunks(:happy_text_stream)

  # Provider-shaped 429 envelopes.
  defp rate_limit_body(:anthropic, message),
    do: Jason.encode!(%{type: "error", error: %{type: "rate_limit_error", message: message}})

  defp rate_limit_body(:gemini, message),
    do: Jason.encode!(%{error: %{code: 429, message: message, status: "RESOURCE_EXHAUSTED"}})

  defp rate_limit_body(_openai, message),
    do:
      Jason.encode!(%{
        error: %{message: message, type: "requests", code: "rate_limit_exceeded"}
      })

  # A key-shaped token in each provider's own credential format.
  defp planted_key(:anthropic), do: "sk-ant-api03-PLANTEDsecret0123456789"
  defp planted_key(:gemini), do: "AIzaPLANTEDsecret0123456789"
  defp planted_key(_openai), do: "sk-proj-PLANTEDsecret0123456789"

  defp auth_body(:anthropic, message),
    do: Jason.encode!(%{type: "error", error: %{type: "authentication_error", message: message}})

  defp auth_body(:gemini, message),
    do: Jason.encode!(%{error: %{code: 401, message: message, status: "UNAUTHENTICATED"}})

  defp auth_body(_openai, message),
    do: Jason.encode!(%{error: %{message: message, type: "invalid_request_error", code: nil}})

  defp req(arm) do
    Request.new([%Message{role: :user, content: "hi"}], model: model(arm), max_tokens: 64)
  end

  defp stream_events(arm, stub_opts) do
    stub = FinchStub.install([], stub_opts)

    {:ok, stream} =
      adapter(arm).stream(req(arm),
        api_key: api_key(arm),
        finch_module: FinchStub,
        finch_stub_ref: stub
      )

    Enum.to_list(stream)
  end

  for arm <- @arms do
    describe "#{arm}: streamed error body" do
      @arm arm

      test "429 JSON body + retry-after -> provider message and retry_after_ms" do
        message = "Rate limit reached for requests (#{@arm})"

        events =
          stream_events(@arm,
            initial_status: 429,
            initial_headers: [{"content-type", "application/json"}, {"Retry-After", "7"}],
            error_body: rate_limit_body(@arm, message)
          )

        provider = provider(@arm)

        assert {:error,
                %AdapterError{
                  reason: :rate_limited,
                  status: 429,
                  provider: ^provider,
                  message: ^message,
                  retry_after_ms: 7_000
                }} = List.last(events)

        refute Enum.any?(events, &match?({:message_completed, _}, &1))
      end

      test "an error body split across several data frames is reassembled" do
        message = "Rate limit reached across frames (#{@arm})"
        body = rate_limit_body(@arm, message)
        {left, right} = String.split_at(body, div(byte_size(body), 2))
        {mid, right} = String.split_at(right, div(byte_size(right), 2))

        events =
          stream_events(@arm,
            initial_status: 429,
            initial_headers: [{"retry-after", "2"}],
            error_body: [left, mid, right]
          )

        assert {:error, %AdapterError{message: ^message, retry_after_ms: 2_000}} =
                 List.last(events)
      end

      test "401 body echoing a key-shaped token is redacted" do
        key = planted_key(@arm)

        events =
          stream_events(@arm,
            initial_status: 401,
            error_body: auth_body(@arm, "Incorrect API key provided: #{key}.")
          )

        assert {:error, %AdapterError{reason: :authentication_failed, status: 401} = err} =
                 List.last(events)

        assert err.message =~ "[REDACTED]"
        refute inspect(err) =~ "PLANTED"
        refute Jason.encode!(err) =~ "PLANTED"
      end

      test "a non-JSON error body yields the status-only error" do
        events =
          stream_events(@arm,
            initial_status: 502,
            initial_headers: [{"content-type", "text/html"}],
            error_body: "<html><body>502 Bad Gateway</body></html>"
          )

        assert {:error, %AdapterError{reason: :provider_unavailable, status: 502} = err} =
                 List.last(events)

        assert err.message =~ "HTTP 502"
        assert err.retry_after_ms == nil
      end

      test "an empty error body yields the status-only error" do
        events = stream_events(@arm, initial_status: 500, error_body: "")

        assert {:error, %AdapterError{reason: :provider_unavailable, status: 500} = err} =
                 List.last(events)

        assert err.message =~ "HTTP 500"
      end

      test "a bare-string \"error\" field becomes the message" do
        events =
          stream_events(@arm,
            initial_status: 400,
            error_body: Jason.encode!(%{error: "plain string failure"})
          )

        assert {:error, %AdapterError{reason: :invalid_request, message: "plain string failure"}} =
                 List.last(events)
      end

      test "the error folds into {:ok, %Response{finish_reason: :error}} at the facade" do
        message = "Rate limit reached via facade (#{@arm})"

        stub =
          FinchStub.install([],
            initial_status: 429,
            initial_headers: [{"retry-after", "3"}],
            error_body: rate_limit_body(@arm, message)
          )

        engine = ALLM.Engine.new(adapter: adapter(@arm), model: model(@arm))

        assert {:ok, %Response{finish_reason: :error, metadata: %{error: err}}} =
                 ALLM.generate(engine, req(@arm),
                   api_key: api_key(@arm),
                   adapter_opts: [finch_module: FinchStub, finch_stub_ref: stub]
                 )

        assert %AdapterError{reason: :rate_limited, message: ^message, retry_after_ms: 3_000} =
                 err
      end
    end

    describe "#{arm}: halt drains the mailbox" do
      @arm arm

      # Every frame is queued before the first is read, so SSE chunks are
      # still in the mailbox when `Enum.take/2` halts. Falsifier: an after
      # function that cancels without draining leaves `{ref, _}` behind.
      test "Enum.take/2 cancels once and leaves no {ref, _} message" do
        {:ok, stream} =
          adapter(@arm).stream(req(@arm),
            api_key: api_key(@arm),
            finch_module: BurstFinch,
            finch_stub_ref: happy_chunks(@arm)
          )

        assert [_, _] = Enum.take(stream, 2)

        ref = Process.get(:burst_ref)
        assert Process.get({:burst_cancel, ref}) == 1
        refute_received {^ref, _}
      end

      test "a stream read to completion is not cancelled and leaves no {ref, _} message" do
        {:ok, stream} =
          adapter(@arm).stream(req(@arm),
            api_key: api_key(@arm),
            finch_module: BurstFinch,
            finch_stub_ref: happy_chunks(@arm)
          )

        events = Enum.to_list(stream)
        assert Enum.any?(events, &match?({:message_completed, _}, &1))

        ref = Process.get(:burst_ref)
        assert Process.get({:burst_cancel, ref}) == nil
        refute_received {^ref, _}
      end
    end
  end

  # The classifiers are the seam `generate/2` shares with the stream path,
  # so the redaction binds the non-streaming error too.
  describe "error classifiers" do
    test "each classifier redacts its own provider's key shape" do
      openai = OpenAI.from_openai_error(401, auth_json(:openai_chat), [])
      anthropic = Anthropic.from_anthropic_error(401, auth_json(:anthropic), [])
      gemini = Gemini.classify_error(401, auth_json(:gemini), [])

      for err <- [openai, anthropic, gemini] do
        assert err.message =~ "[REDACTED]"
        refute err.message =~ "PLANTED"
      end
    end

    # Companion: the Anthropic and Gemini patterns are their own, not the
    # OpenAI `sk-` pattern inherited verbatim, so a sibling's token passes.
    test "the Anthropic and Gemini patterns do not match a sibling's token" do
      sibling = "keys sk-proj-SIBLINGsecret0123 and AIzaSIBLINGsecret0123"
      body = %{"error" => %{"message" => sibling}}

      assert Anthropic.from_anthropic_error(401, body, []).message =~ "AIzaSIBLING"
      assert Anthropic.from_anthropic_error(401, body, []).message =~ "sk-proj-SIBLING"
      assert Gemini.classify_error(401, body, []).message =~ "sk-proj-SIBLING"
    end

    test "a body without a message falls back to the status line" do
      assert OpenAI.from_openai_error(503, %{}, []).message == "OpenAI HTTP 503"

      assert Anthropic.from_anthropic_error(503, %{"error" => 7}, []).message ==
               "Anthropic HTTP 503"

      assert Gemini.classify_error(503, %{"error" => %{"message" => nil}}, []).message ==
               "Gemini HTTP 503"
    end
  end

  defp auth_json(arm) do
    arm
    |> auth_body("Incorrect API key provided: #{planted_key(arm)}.")
    |> Jason.decode!()
  end
end
