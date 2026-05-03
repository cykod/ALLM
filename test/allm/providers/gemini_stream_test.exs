defmodule ALLM.Providers.GeminiStreamTest do
  @moduledoc """
  Phase 16.2 streaming-wire tests for `ALLM.Providers.Gemini.stream/2`.

  Each row uses `ALLM.Test.FinchStub` (injected via `:finch_module`) to
  replay synthesized SSE chunks; no live Gemini connection is opened.
  Per Phase 16 Decisions #1 (single translator), #11 (usage), #12
  (intermediate usage), #13 (terminate on connection close), and #14
  (finish_reason mapping).

  Per CLAUDE.md and spec §10.1, mid-stream errors fold into the response
  via terminal `{:error, _}` events; the `{:ok, stream}` call-site tuple
  is preserved. Pre-flight failures surface as `{:error, _}` synchronously
  only when they occur before the first SSE event is decoded — matches
  the existing OpenAI / Anthropic precedents at
  `test/allm/providers/openai_stream_wire_test.exs` Rows 4–9 and
  `test/allm/providers/anthropic_stream_wire_test.exs`.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.Message
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.GeminiTestFixtures, as: Fx
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.FinchStub

  setup do
    ALLM.Keys.put(:gemini, "AIza-stream-test")
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    :ok
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "gemini-2.5-flash"], opts)
    )
  end

  defp install_stub(chunks, opts \\ []) do
    FinchStub.install(chunks, opts)
  end

  defp call_stream(stub_ref, request, extra_opts \\ []) do
    Gemini.stream(
      request,
      Keyword.merge(
        [
          finch_module: FinchStub,
          finch_stub_ref: stub_ref
        ],
        extra_opts
      )
    )
  end

  defp consume(stream), do: Enum.to_list(stream)

  defp collect(events) do
    state = Enum.reduce(events, StreamCollector.new(), &StreamCollector.apply_event(&2, &1))
    StreamCollector.to_response(state)
  end

  # ---------------------------------------------------------------------------
  # Row 1 — :message_started → :text_delta+ → :message_completed
  # ---------------------------------------------------------------------------

  test "multi-chunk text → :message_started, :text_delta+, :message_completed" do
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert match?({:message_started, _}, hd(events))
    text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
    assert length(text_deltas) >= 2

    completed = Enum.filter(events, &match?({:message_completed, _}, &1))
    assert length(completed) == 1

    response = collect(events)
    assert response.output_text == "hello world" or response.message.content == "hello world"
    assert response.finish_reason == :stop
  end

  # ---------------------------------------------------------------------------
  # Row 2 — :usage event from final-chunk usageMetadata
  # ---------------------------------------------------------------------------

  test "usageMetadata on the final chunk → :usage event populated" do
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))

    response = collect(events)
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 2
    assert response.usage.total_tokens == 5
  end

  # ---------------------------------------------------------------------------
  # Row 3 — :usage event for intermediate chunks (Decision #12)
  # ---------------------------------------------------------------------------

  test "usageMetadata on intermediate chunks → :usage emitted; collector overwrites" do
    chunks = Fx.stream_chunks(:intermediate_usage_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    usage_events = Enum.filter(events, &match?({:raw_chunk, {:usage, _}}, &1))
    assert length(usage_events) >= 2

    response = collect(events)
    # Last usage on the wire wins per Decision #12
    assert response.usage.output_tokens == 3
    assert response.usage.total_tokens == 7
  end

  # ---------------------------------------------------------------------------
  # Row 4 — functionCall part → :tool_call_started + :tool_call_completed
  # ---------------------------------------------------------------------------

  test "single-event functionCall part → :tool_call_started + :tool_call_completed (zero deltas)" do
    chunks = Fx.stream_chunks(:function_call_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "fc_1", name: "get_weather"}}, &1)
           )

    refute Enum.any?(events, &match?({:tool_call_delta, _}, &1))

    assert Enum.any?(
             events,
             &match?({:tool_call_completed, %{id: "fc_1", name: "get_weather"}}, &1)
           )

    response = collect(events)
    assert [tc] = response.tool_calls
    assert tc.arguments == %{"city" => "Boston"}
    assert tc.raw_arguments == ~s({"city":"Boston"})
    assert response.finish_reason == :tool_calls
  end

  # ---------------------------------------------------------------------------
  # Row 5 — promptFeedback.blockReason on first event → :error terminator
  # ---------------------------------------------------------------------------

  test "promptFeedback.blockReason on first event → terminal {:error, %AdapterError{:content_filter}}" do
    chunks = Fx.stream_chunks(:prompt_blocked_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :content_filter}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 6 — mid-stream HTTP 429
  # ---------------------------------------------------------------------------

  test "mid-stream 429 → terminal {:error, %AdapterError{:rate_limited}}" do
    chunks = Fx.stream_chunks(:mid_stream_error) ++ [{:terminal_status, 429}]
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    assert {:error, %AdapterError{reason: :rate_limited, status: 429}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 7 — Stream.take/2 halt → cancel_async_request fires within 500ms
  # ---------------------------------------------------------------------------

  test "Stream.take/2 halts early → cancel_count increments within 500ms" do
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks, delay_ms: 50)

    {:ok, stream} = call_stream(stub, req())

    started_at = System.monotonic_time(:millisecond)
    _ = Enum.take(stream, 2)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert FinchStub.cancel_count(stub) >= 1
    assert elapsed <= 500
  end

  # ---------------------------------------------------------------------------
  # Row 8 — :stream_timeout → :timeout terminator
  # ---------------------------------------------------------------------------

  test "stream_timeout exceeded → terminal {:error, %AdapterError{:timeout}}" do
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks, delay_ms: 100)

    {:ok, stream} = call_stream(stub, req(), stream_timeout: 20)
    events = consume(stream)

    assert {:error, %AdapterError{reason: :timeout}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 9 — :finch_module / :finch_name injection
  # ---------------------------------------------------------------------------

  test "opts[:finch_module] is honored (FinchStub replaces Finch)" do
    # Implicit in every other test: the call_stream/3 helper passes
    # finch_module: FinchStub. This row pins it explicitly with a happy
    # text fixture and asserts the stream produced events.
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks)

    {:ok, stream} =
      Gemini.stream(req(),
        finch_module: FinchStub,
        finch_name: :ignored_when_module_overridden,
        finch_stub_ref: stub
      )

    events = consume(stream)
    assert Enum.any?(events, &match?({:text_delta, _}, &1))
  end

  # ---------------------------------------------------------------------------
  # Row 10 — pre-flight 401 → terminal {:error, _} event (call-site is {:ok, stream})
  # ---------------------------------------------------------------------------

  test "pre-flight 401 (status before any data chunk) → terminal {:error, %AdapterError{:authentication_failed}}" do
    # Per CLAUDE.md mid-stream-error invariant + StreamAdapter Invariant 1:
    # the streaming HTTP transport (Finch async) cannot synchronously fail
    # with HTTP-level errors before the consumer reduces — the {:status, 401}
    # frame arrives in the receive loop and folds to a terminal {:error, _}
    # event. The call-site tuple stays {:ok, stream}.
    stub = install_stub([], initial_status: 401)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :authentication_failed, status: 401}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 11 — pre-flight 400 + context-window substring → :context_length_exceeded terminator
  # ---------------------------------------------------------------------------
  #
  # The context-window detection runs inside the synchronous decode_response
  # path (Phase 16.1's classify_error/3 reads the JSON body's error.message).
  # The streaming path's status-frame handler routes through the same
  # classifier; without a body it surfaces as :invalid_request. To exercise
  # :context_length_exceeded we use the synchronous prepare_request +
  # generate path on a 400 response — covered in gemini_test.exs. The
  # streaming-side row is exercised at unit level via classify_error/3 here
  # to keep the streaming chunk-mapper covered.
  test "classify_error/3 with 400 + context-window substring → :context_length_exceeded" do
    body = %{
      "error" => %{
        "code" => 400,
        "status" => "INVALID_ARGUMENT",
        "message" =>
          "The input token count (50000) exceeds the maximum number of tokens allowed (32768)."
      }
    }

    err = Gemini.classify_error(400, body, [])
    assert err.reason == :context_length_exceeded
    assert err.status == 400
  end

  # ---------------------------------------------------------------------------
  # Row 12 — mid-stream 5xx folds to :error event (NOT call-site {:error, _})
  # ---------------------------------------------------------------------------

  test "mid-stream 5xx → terminal {:error, %AdapterError{:provider_unavailable}}; call-site stays {:ok, _stream}" do
    chunks = Fx.stream_chunks(:mid_stream_error) ++ [{:terminal_status, 503}]
    stub = install_stub(chunks)

    # Per CLAUDE.md mid-stream-error fold invariant: the call-site tuple is
    # {:ok, stream}, never {:error, _}, for any error after the first SSE event.
    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :provider_unavailable, status: 503}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Stream-equivalence property — Phase 16.2 Test Plan bullet "≥10 scripted
  # multi-chunk fixtures". Per design §16.2.1, this is adapter-internal; the
  # main project's chat-equivalence harness only iterates Fake.
  # ---------------------------------------------------------------------------
  #
  # NOTE on raw_finish_reason: the design line "{content, tool_calls,
  # finish_reason, usage, metadata.raw_finish_reason}" is correct in spirit
  # but the codebase stores `raw_finish_reason` directly on `%Response{}`
  # (not under `metadata`), and `StreamCollector.to_response/1` does NOT
  # propagate it from the `:message_completed` event payload (state field
  # initialized at nil; never written). This is a Phase 5/6-era StreamCollector
  # limitation outside Phase 16.2's scope per CLAUDE.md "cross-phase bug
  # discipline." Equivalence is asserted on
  # {content, tool_calls (id+name+arguments+raw_arguments), finish_reason,
  # usage}; raw_finish_reason is exercised separately at unit level via
  # Gemini.parse_finish_reason/1 doctests.

  # 10+ pure-equivalence fixtures (no functionCall parts). The two
  # functionCall fixtures (:equiv_function_call, :equiv_text_then_function_call)
  # are exercised below on a sub-projection that excludes tool_calls — Phase
  # 16.1's non-streaming decoder leaves `tool_calls: []` until 16.3 lands the
  # functionCall part decoder. Per CLAUDE.md "cross-phase bug discipline,"
  # 16.2 does NOT extend the 16.1 lib/ decoder; the 16.3 design will adjust
  # both arms together. Fixtures are still useful for streaming-side coverage
  # and pin the wire shape for 16.3.

  @full_equivalence_fixtures [
    :equiv_simple_text,
    :equiv_multi_chunk_text,
    :equiv_max_tokens,
    :equiv_safety_filter,
    :equiv_recitation,
    :equiv_three_chunks,
    :equiv_intermediate_usage,
    :equiv_no_finish_reason,
    :equiv_other_finish,
    :equiv_long_text
  ]

  for fixture <- @full_equivalence_fixtures do
    @fixture fixture
    test "stream-equivalence: #{@fixture} streams collect to the same projection as decode_response/2" do
      sse_chunks = Fx.stream_chunks(@fixture)
      stub = install_stub(sse_chunks)

      {:ok, stream} = call_stream(stub, req())
      events = consume(stream)
      streamed = collect(events)

      json_body = Fx.synthesized(@fixture)
      non_streamed = Gemini.decode_response(json_body, [])

      streamed_text =
        streamed.output_text || (streamed.message && streamed.message.content) || ""

      non_streamed_text =
        non_streamed.output_text || (non_streamed.message && non_streamed.message.content) || ""

      assert streamed_text == non_streamed_text,
             "text mismatch for #{@fixture}: streamed=#{inspect(streamed_text)} vs non=#{inspect(non_streamed_text)}"

      assert tool_call_projection(streamed.tool_calls) ==
               tool_call_projection(non_streamed.tool_calls),
             "tool_calls mismatch for #{@fixture}"

      assert streamed.finish_reason == non_streamed.finish_reason,
             "finish_reason mismatch for #{@fixture}: streamed=#{inspect(streamed.finish_reason)} vs non=#{inspect(non_streamed.finish_reason)}"

      assert streamed.usage.input_tokens == non_streamed.usage.input_tokens,
             "usage.input_tokens mismatch for #{@fixture}"

      assert streamed.usage.output_tokens == non_streamed.usage.output_tokens,
             "usage.output_tokens mismatch for #{@fixture}"

      assert streamed.usage.total_tokens == non_streamed.usage.total_tokens,
             "usage.total_tokens mismatch for #{@fixture}"
    end
  end

  # Sub-projection for functionCall fixtures: text + usage match across
  # modes today; tool_calls + finish_reason converge once 16.3 ships. The
  # streaming side already extracts tool_calls into the response (verified
  # in Row 4 above), so these tests pin the streaming-side decode is right
  # while keeping 16.1's lib/ untouched.
  @functioncall_fixtures [
    :equiv_function_call,
    :equiv_text_then_function_call
  ]

  for fixture <- @functioncall_fixtures do
    @fixture fixture
    test "stream-equivalence (functionCall sub-projection): #{@fixture} text + usage match" do
      sse_chunks = Fx.stream_chunks(@fixture)
      stub = install_stub(sse_chunks)

      {:ok, stream} = call_stream(stub, req())
      events = consume(stream)
      streamed = collect(events)

      json_body = Fx.synthesized(@fixture)
      non_streamed = Gemini.decode_response(json_body, [])

      streamed_text =
        streamed.output_text || (streamed.message && streamed.message.content) || ""

      non_streamed_text =
        non_streamed.output_text || (non_streamed.message && non_streamed.message.content) || ""

      assert streamed_text == non_streamed_text,
             "text mismatch for #{@fixture}"

      assert streamed.usage.input_tokens == non_streamed.usage.input_tokens
      assert streamed.usage.output_tokens == non_streamed.usage.output_tokens
      assert streamed.usage.total_tokens == non_streamed.usage.total_tokens

      # Phase 16.3 closed the relaxation: both arms now promote
      # finish_reason to :tool_calls when STOP + functionCall parts are
      # present (Decision #14 override). Pre-16.3 this test asserted
      # `non_streamed.finish_reason == :stop`; the close-out assertion
      # is `streamed.finish_reason == non_streamed.finish_reason`.
      assert streamed.finish_reason == :tool_calls
      assert non_streamed.finish_reason == :tool_calls
    end
  end

  defp tool_call_projection(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{id: tc.id, name: tc.name, arguments: tc.arguments, raw_arguments: tc.raw_arguments}
    end)
  end
end
