defmodule ALLM.Providers.OpenAIStreamWireTest do
  @moduledoc """
  Phase 10.3 streaming-wire tests for `ALLM.Providers.OpenAI.stream/2`.

  Each row uses `FinchStub` (injected via the `:finch_module` opt)
  to replay synthesized SSE chunks; no live OpenAI connection is opened.
  Per design Decision #11 the SSE fixtures live under
  `test/fixtures/openai/synthesized/*.sse` and each carries a leading
  SSE-comment line citing its OpenAI doc reference.

  Per CLAUDE.md and spec §10.1, mid-stream errors fold into the response
  via terminal `{:error, _}` events; the `{:ok, stream}` call-site tuple is
  preserved. Pre-flight failures surface as `{:error, _}` synchronously.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.Error.StreamError
  alias ALLM.Message
  alias ALLM.Providers.OpenAI
  alias ALLM.Providers.OpenAITestFixtures, as: Fx
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.FinchStub

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "gpt-4o-mini"], opts)
    )
  end

  defp install_stub(chunks, opts \\ []) do
    FinchStub.install(chunks, opts)
  end

  defp call_stream(stub_ref, request, extra_opts \\ []) do
    OpenAI.stream(
      request,
      Keyword.merge(
        [
          api_key: "sk-stream-test",
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
  # Row 1 — happy text streaming
  # ---------------------------------------------------------------------------

  test "happy text streaming → :text_delta… :message_completed; collected output_text" do
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
    assert length(text_deltas) >= 2

    completed = Enum.filter(events, &match?({:message_completed, _}, &1))
    assert length(completed) == 1

    response = collect(events)
    assert response.output_text == "hello" or response.message.content == "hello"
    assert response.finish_reason == :stop
  end

  # ---------------------------------------------------------------------------
  # Row 2 — tool call deltas
  # ---------------------------------------------------------------------------

  test "tool call deltas → started, deltas, completed, message_completed" do
    chunks = Fx.stream_chunks(:tool_call_deltas)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "call_abc123", name: "get_weather"}}, &1)
           )

    assert Enum.any?(events, &match?({:tool_call_delta, _}, &1))
    assert Enum.any?(events, &match?({:tool_call_completed, _}, &1))
    assert Enum.any?(events, &match?({:message_completed, _}, &1))

    response = collect(events)
    assert [tc] = response.tool_calls
    assert tc.id == "call_abc123"
    assert tc.name == "get_weather"
    assert tc.arguments == %{"city" => "Boston"}
  end

  # ---------------------------------------------------------------------------
  # Row 3 — parallel tool-call deltas
  # ---------------------------------------------------------------------------

  test "parallel tool-call deltas → both ids preserved with reassembled args" do
    chunks = Fx.stream_chunks(:parallel_tool_calls_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    response = collect(events)

    ids = response.tool_calls |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["call_a", "call_b"]

    by_id = Map.new(response.tool_calls, &{&1.id, &1})
    assert by_id["call_a"].arguments == %{"city" => "Boston"}
    assert by_id["call_b"].arguments == %{"tz" => "UTC"}
  end

  # ---------------------------------------------------------------------------
  # Row 4 — :authentication_failed pre-flight (401 before any data chunk)
  # ---------------------------------------------------------------------------

  test "401 before any chunk → terminal {:error, _} event with :authentication_failed" do
    # Stub responds with status 401 — no data chunks. Per design, the
    # adapter buffers a terminal AdapterError event and halts. The
    # call-site tuple stays {:ok, stream} because the failure is observed
    # only after the consumer reduces — pre-flight here means "before any
    # SSE data has been emitted to the consumer".
    stub = install_stub([], initial_status: 401)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :authentication_failed, status: 401}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 5 — :invalid_request pre-flight (400 before any data chunk)
  # ---------------------------------------------------------------------------

  test "400 before any chunk → terminal {:error, _} event with :invalid_request" do
    stub = install_stub([], initial_status: 400)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :invalid_request, status: 400}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 6 — mid-stream 5xx
  # ---------------------------------------------------------------------------

  test "mid-stream 5xx terminal status → terminal {:error, _} with :provider_unavailable" do
    chunks = Fx.stream_chunks(:mid_stream_error) ++ [{:terminal_status, 503}]
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    assert {:error, %AdapterError{reason: :provider_unavailable, status: 503}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 7 — content_filter mid-stream
  # ---------------------------------------------------------------------------

  test "content_filter terminal frame → terminal {:error, _} with :content_filter" do
    chunks = Fx.stream_chunks(:content_filter_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    assert {:error, %AdapterError{reason: :content_filter}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 8 — mid-stream :network_error (TCP drop)
  # ---------------------------------------------------------------------------

  test "transport error mid-stream → terminal {:error, _} with :network_error" do
    transport_err = %Mint.TransportError{reason: :closed}
    chunks = Fx.stream_chunks(:happy_text_stream) |> Enum.take(2)
    stub = install_stub(chunks ++ [{:terminal_error, transport_err}])

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :network_error}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 9 — mid-stream malformed event
  # ---------------------------------------------------------------------------

  test "malformed SSE data line → terminal {:error, %StreamError{reason: :malformed_event}}" do
    chunks = Fx.stream_chunks(:malformed_event)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %StreamError{reason: :malformed_event}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 10 — consumer halt → cancel_async_request fires within 500 ms
  # ---------------------------------------------------------------------------

  test "Stream.take/2 halts early → cancel_count increments within 500 ms" do
    # Delay each chunk by 50ms so the consumer halts well before the stream
    # naturally drains.
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
  # Row 11 — :usage raw chunk passthrough
  # ---------------------------------------------------------------------------

  test "usage chunk → Response.usage populated post-collection" do
    chunks = Fx.stream_chunks(:usage_chunk)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))

    response = collect(events)
    assert response.usage.input_tokens == 12
    assert response.usage.output_tokens == 3
    assert response.usage.total_tokens == 15
  end

  # ---------------------------------------------------------------------------
  # Row 12 — [DONE] sentinel produces :message_completed before stream end
  # ---------------------------------------------------------------------------

  test "[DONE]-only stream → synthetic :message_completed event before stream end" do
    chunks = Fx.stream_chunks(:done_only)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:message_completed, _}, &1))
  end

  # ---------------------------------------------------------------------------
  # Coverage rider — Finch :done bookend path
  # ---------------------------------------------------------------------------
  #
  # When the SSE chunks omit the [DONE] sentinel, the SSE-side never
  # synthesizes :message_completed; the Finch :done message that arrives
  # after the last :data chunk triggers the adapter's synthetic completion
  # path (handle_finch_payload(:done) when message_completed_emitted? ==
  # false). Validates Invariant 9's "synthesized :message_completed event
  # after the SSE [DONE] sentinel" doesn't depend on [DONE] being present.
  test "stream without [DONE] sentinel → Finch :done synthesizes :message_completed" do
    chunks = Fx.stream_chunks(:no_done_marker)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:message_completed, _}, &1))
    response = collect(events)
    assert response.output_text == "ok" or response.message.content == "ok"
  end

  # ---------------------------------------------------------------------------
  # Coverage rider — :stream_timeout
  # ---------------------------------------------------------------------------

  test "stream_timeout exceeded → terminal {:error, _} with :timeout" do
    # Slow chunks; tight timeout. The receive's after-clause fires before
    # the next chunk arrives.
    chunks = Fx.stream_chunks(:happy_text_stream)
    stub = install_stub(chunks, delay_ms: 100)

    {:ok, stream} = call_stream(stub, req(), stream_timeout: 20)
    events = consume(stream)

    assert {:error, %AdapterError{reason: :timeout}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 13 — streaming-no-retry meta-row
  # ---------------------------------------------------------------------------

  # Telemetry handler — module function (NOT an anonymous fun) to avoid
  # `:telemetry`'s perf warning about local-function attaches. Forwards
  # `{:retry, meta}` to the parent pid in `config` ONLY when the emitting
  # process IS the parent. Cross-test contamination (a parallel `async:
  # true` Anthropic/Gemini test emitting `[:allm, :adapter, :retry]`) is
  # otherwise indistinguishable from a real retry on the SUT — the
  # handler is application-global per CLAUDE.md "`:telemetry.attach/4 +
  # async: true` foot-gun". `self()` here is the emitting process.
  @doc false
  def handle_retry_event(_event, _measurements, meta, config) do
    if self() == config.parent, do: send(config.parent, {:retry, meta})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Phase 10.6 — Responses-API streaming (semantic SSE event names)
  # ---------------------------------------------------------------------------

  test "Phase 10.6: Responses-API happy stream → text deltas + completed" do
    chunks = Fx.responses_stream_chunks(:happy_text)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req(model: "gpt-5.5"))
    events = consume(stream)

    text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
    assert length(text_deltas) >= 2

    response = collect(events)
    assert response.output_text == "hello" or response.message.content == "hello"
    assert response.finish_reason == :stop
  end

  # Bug #5 (Phase 10 retro): Responses-API streaming previously dropped
  # function_call items entirely. These two rows lock in the new
  # three-phase lifecycle (output_item.added / function_call_arguments.delta
  # / output_item.done), the synthesized close-out events, and the
  # finish_reason promotion.
  test "Phase 10 retro: Responses-API single tool-call stream → start/delta/completed events + final response" do
    chunks = Fx.responses_stream_chunks(:tool_call_deltas)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req(model: "gpt-5.4-nano"))
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "call_stream_1", name: "get_weather"}}, &1)
           )

    assert Enum.any?(events, &match?({:tool_call_delta, %{id: "call_stream_1"}}, &1))
    assert Enum.any?(events, &match?({:tool_call_completed, %{id: "call_stream_1"}}, &1))
    assert Enum.any?(events, &match?({:message_completed, _}, &1))

    response = collect(events)
    assert [tc] = response.tool_calls
    assert tc.id == "call_stream_1"
    assert tc.name == "get_weather"
    assert tc.arguments == %{"city" => "Boston"}
    assert response.finish_reason == :tool_calls
  end

  test "Phase 10 retro: Responses-API parallel tool-call stream → both ids surface in events AND final response" do
    chunks = Fx.responses_stream_chunks(:parallel_tool_call_deltas)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req(model: "gpt-5.4-nano"))
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "call_a", name: "get_weather"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "call_b", name: "get_time"}}, &1)
           )

    completed_ids =
      events
      |> Enum.flat_map(fn
        {:tool_call_completed, %{id: id}} -> [id]
        _ -> []
      end)
      |> Enum.sort()

    assert completed_ids == ["call_a", "call_b"]

    response = collect(events)
    ids = response.tool_calls |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["call_a", "call_b"]

    by_id = Map.new(response.tool_calls, &{&1.id, &1})
    assert by_id["call_a"].arguments == %{"city" => "Boston"}
    assert by_id["call_b"].arguments == %{"tz" => "UTC"}

    assert response.finish_reason == :tool_calls
  end

  test "Phase 10.6: Responses-API reasoning_stream — summary deltas surface on metadata.reasoning.summary, output_text holds output deltas only" do
    chunks = Fx.responses_stream_chunks(:reasoning_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req(model: "gpt-5.5"))
    events = consume(stream)

    response = collect(events)

    # The two streams do not cross-contaminate.
    assert response.output_text == "Final answer." or
             response.message.content == "Final answer."

    assert response.metadata.reasoning.summary == "Thinking carefully."
  end

  # Regression: `maybe_apply_usage_from_response/2` was a no-op, so every
  # gpt-5* Responses-API stream landed `response.usage == %Usage{}` (all
  # nils). The fix routes usage through `:raw_chunk {:usage, _}` mirroring
  # the Chat-Completions streaming path and using `decode_responses_usage/1`'s
  # field shape (input_tokens/output_tokens/total_tokens/reasoning_tokens/extra).
  test "Responses-API streaming: response.completed.usage folds into response.usage with reasoning_tokens" do
    chunks = Fx.responses_stream_chunks(:happy_text_with_usage)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req(model: "gpt-5.5"))
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?(
               {:raw_chunk,
                {:usage,
                 %{
                   input_tokens: 12,
                   output_tokens: 7,
                   total_tokens: 19,
                   reasoning_tokens: 4
                 }}},
               &1
             )
           )

    response = collect(events)
    assert response.usage.input_tokens == 12
    assert response.usage.output_tokens == 7
    assert response.usage.total_tokens == 19
    assert response.usage.reasoning_tokens == 4
  end

  test "streaming never retries — zero [:allm, :adapter, :retry] events on mid-stream 5xx" do
    handler_id = "openai_stream_no_retry_test_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:allm, :adapter, :retry],
      &__MODULE__.handle_retry_event/4,
      %{parent: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    chunks = Fx.stream_chunks(:mid_stream_error) ++ [{:terminal_status, 503}]
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :provider_unavailable}} = List.last(events)

    refute_received {:retry, _}
  end
end
