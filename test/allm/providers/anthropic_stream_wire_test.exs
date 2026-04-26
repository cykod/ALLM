defmodule ALLM.Providers.AnthropicStreamWireTest do
  @moduledoc """
  Phase 11.2 streaming-wire tests for `ALLM.Providers.Anthropic.stream/2`.

  Each row uses `ALLM.Test.FinchStub` (injected via the `:finch_module` opt)
  to replay synthesized SSE chunks; no live Anthropic connection is opened.
  Per Phase 11 design Decision #11, named-event SSE fixtures live under
  `test/fixtures/anthropic/messages/*.sse` (recorded happy-path) and
  `test/fixtures/anthropic/synthesized/*.sse` (hand-crafted, leading-comment
  provenance).

  Per CLAUDE.md and spec §10.1, mid-stream errors fold into the response via
  terminal `{:error, _}` events; the `{:ok, stream}` call-site tuple is
  preserved. Pre-flight failures surface as `{:error, _}` synchronously.

  The streamed-structured-output row (design 11.2.1 row 14) ships alongside
  `lift_structured_output/1` and asserts the rewritten event shape
  (`:text_delta` / `:text_completed`) per Decision #5b — see Row 14 below.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.Error.StreamError
  alias ALLM.Message
  alias ALLM.Providers.Anthropic
  alias ALLM.Providers.AnthropicTestFixtures, as: Fx
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.FinchStub

  setup do
    ALLM.Keys.put(:anthropic, "sk-ant-stream-test")
    on_exit(fn -> ALLM.Keys.delete(:anthropic) end)
    :ok
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "claude-sonnet-4-6", max_tokens: 64], opts)
    )
  end

  defp install_stub(chunks, opts \\ []) do
    FinchStub.install(chunks, opts)
  end

  defp call_stream(stub_ref, request, extra_opts \\ []) do
    Anthropic.stream(
      request,
      Keyword.merge(
        [finch_module: FinchStub, finch_stub_ref: stub_ref],
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

  test "happy text streaming → message_started, text_delta+, text_completed, message_completed" do
    chunks = Fx.stream_chunks(:happy_text)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert match?({:message_started, _}, hd(events))

    text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
    assert length(text_deltas) >= 2

    assert Enum.any?(events, &match?({:text_completed, _}, &1))

    completed = Enum.filter(events, &match?({:message_completed, _}, &1))
    assert length(completed) == 1

    response = collect(events)
    assert response.output_text == "hello" or response.message.content == "hello"
    assert response.finish_reason == :stop
  end

  # ---------------------------------------------------------------------------
  # Row 2 — tool_use deltas
  # ---------------------------------------------------------------------------

  test "tool_use deltas → tool_call_started, tool_call_delta+, tool_call_completed, message_completed" do
    chunks = Fx.stream_chunks(:tool_use_deltas)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(
             events,
             &match?({:tool_call_started, %{id: "toolu_abc123", name: "get_weather"}}, &1)
           )

    assert Enum.any?(events, &match?({:tool_call_delta, %{id: "toolu_abc123"}}, &1))

    assert Enum.any?(
             events,
             &match?({:tool_call_completed, %{id: "toolu_abc123", name: "get_weather"}}, &1)
           )

    assert Enum.any?(events, &match?({:message_completed, _}, &1))

    response = collect(events)
    assert [tc] = response.tool_calls
    assert tc.id == "toolu_abc123"
    assert tc.name == "get_weather"
    assert tc.arguments == %{"city" => "Boston"}
    assert tc.raw_arguments == ~s({"city":"Boston"})
    assert response.finish_reason == :tool_calls
  end

  # ---------------------------------------------------------------------------
  # Row 3 — parallel tool_use deltas
  # ---------------------------------------------------------------------------

  test "parallel tool_use deltas → both ids preserved with reassembled arguments" do
    chunks = Fx.stream_chunks(:parallel_tool_use_deltas)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    started_ids =
      events
      |> Enum.flat_map(fn
        {:tool_call_started, %{id: id}} -> [id]
        _ -> []
      end)
      |> Enum.sort()

    assert started_ids == ["toolu_a", "toolu_b"]

    completed_ids =
      events
      |> Enum.flat_map(fn
        {:tool_call_completed, %{id: id}} -> [id]
        _ -> []
      end)
      |> Enum.sort()

    assert completed_ids == ["toolu_a", "toolu_b"]

    response = collect(events)
    by_id = Map.new(response.tool_calls, &{&1.id, &1})
    assert by_id["toolu_a"].arguments == %{"city" => "Boston"}
    assert by_id["toolu_b"].arguments == %{"city" => "Seattle"}
    assert response.finish_reason == :tool_calls
  end

  # ---------------------------------------------------------------------------
  # Row 4 — :authentication_failed first chunk (401 before any data)
  # ---------------------------------------------------------------------------

  test "401 before any chunk → terminal {:error, _} with :authentication_failed" do
    stub = install_stub([], initial_status: 401)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :authentication_failed, status: 401}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 5 — :invalid_request first chunk (400 before any data)
  # ---------------------------------------------------------------------------

  test "400 before any chunk → terminal {:error, _} with :invalid_request" do
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
  # Row 7 — mid-stream 529 Overloaded (Anthropic-specific)
  # ---------------------------------------------------------------------------

  test "mid-stream 529 → terminal {:error, _} with :provider_unavailable, status: 529" do
    chunks = Fx.stream_chunks(:mid_stream_overloaded) ++ [{:terminal_status, 529}]
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    assert {:error, %AdapterError{reason: :provider_unavailable, status: 529}} =
             List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 8 — mid-stream :content_filter (refusal stop_reason)
  # ---------------------------------------------------------------------------
  #
  # Anthropic signals content-filter via stop_reason: "refusal" on
  # message_delta — this is a NORMAL terminal, not a mid-stream error
  # event. The synthesized :message_completed carries
  # finish_reason: :content_filter so StreamCollector.to_response/1 lifts
  # it onto Response.finish_reason.

  test "stop_reason: \"refusal\" → :message_completed with finish_reason: :content_filter" do
    chunks = Fx.stream_chunks(:content_filter_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    last = List.last(events)
    assert match?({:message_completed, %{finish_reason: :content_filter}}, last)

    response = collect(events)
    assert response.finish_reason == :content_filter
  end

  # ---------------------------------------------------------------------------
  # Row 9 — mid-stream :network_error (TCP drop)
  # ---------------------------------------------------------------------------

  test "transport error mid-stream → terminal {:error, _} with :network_error" do
    transport_err = %Mint.TransportError{reason: :closed}
    chunks = Fx.stream_chunks(:happy_text) |> Enum.take(2)
    stub = install_stub(chunks ++ [{:terminal_error, transport_err}])

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %AdapterError{reason: :network_error}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 10 — mid-stream malformed event
  # ---------------------------------------------------------------------------

  test "malformed SSE data line → terminal {:error, %StreamError{reason: :malformed_event}}" do
    chunks = Fx.stream_chunks(:malformed_event)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert {:error, %StreamError{reason: :malformed_event}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Row 11 — consumer halt → cancel_async_request fires within 500 ms
  # ---------------------------------------------------------------------------

  test "Stream.take/2 halts early → cancel_count increments within 500 ms" do
    chunks = Fx.stream_chunks(:happy_text)
    stub = install_stub(chunks, delay_ms: 50)

    {:ok, stream} = call_stream(stub, req())

    started_at = System.monotonic_time(:millisecond)
    _ = Enum.take(stream, 2)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert FinchStub.cancel_count(stub) >= 1
    assert elapsed <= 500
  end

  # ---------------------------------------------------------------------------
  # Row 12 — :usage raw chunk → Response.usage populated post-collection
  # ---------------------------------------------------------------------------

  test "message_delta usage → :raw_chunk emitted; Response.usage populated post-collection" do
    chunks = Fx.stream_chunks(:usage_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))

    response = collect(events)
    assert response.usage.output_tokens == 3
  end

  # ---------------------------------------------------------------------------
  # Row 13 — streaming-no-retry meta-row
  # ---------------------------------------------------------------------------

  # Telemetry handler — module function (not anonymous fun) to avoid
  # `:telemetry`'s perf warning about local-function attaches. Forwards
  # `{:retry, meta}` to the parent pid carried in `config`.
  @doc false
  def handle_retry_event(_event, _measurements, meta, config) do
    send(config.parent, {:retry, meta})
    :ok
  end

  test "streaming never retries — zero [:allm, :adapter, :retry] events on mid-stream 5xx" do
    handler_id = "anthropic_stream_no_retry_test_#{System.unique_integer([:positive])}"

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

  # ---------------------------------------------------------------------------
  # Coverage rider — extended-thinking pass-through (Decision #8)
  # ---------------------------------------------------------------------------
  #
  # Anthropic's extended-thinking reasoning blocks emit a
  # `content_block_start` of type "thinking" followed by
  # `content_block_delta` events with `delta.type: "thinking_delta"`.
  # Per Decision #8 the adapter passes them through as :raw_chunk events
  # (so a power-user reducer can inspect them) but does NOT lift the
  # thinking content onto Response.metadata.reasoning. Verifies the
  # mapper at anthropic.ex content_block_start/thinking_delta paths.

  test "thinking blocks → {:raw_chunk, {:thinking_start|:thinking_delta, _}} pass-through" do
    chunks = Fx.stream_chunks(:thinking_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, &match?({:raw_chunk, {:thinking_start, %{index: _}}}, &1))

    thinking_deltas =
      Enum.filter(events, fn
        {:raw_chunk, {:thinking_delta, %{index: _, delta: text}}}
        when is_binary(text) and text != "" ->
          true

        _ ->
          false
      end)

    assert length(thinking_deltas) >= 2

    # Normal text content still flows through.
    assert Enum.any?(events, &match?({:text_delta, _}, &1))
    assert Enum.any?(events, &match?({:text_completed, _}, &1))
    assert Enum.any?(events, &match?({:message_completed, _}, &1))
  end

  # ---------------------------------------------------------------------------
  # Coverage rider — Anthropic SSE `error` named event (Decision #14 row 12)
  # ---------------------------------------------------------------------------
  #
  # Distinct from the HTTP-level `{:terminal_status, 5xx}` injection
  # exercised by rows 6-7: this asserts the well-formed-Anthropic-shape
  # `event: error\ndata: {"type":"error","error":{...}}` SSE frame is
  # mapped to a terminal `{:error, %AdapterError{}}` event by
  # anthropic_chunk_to_events("error", _, _) at anthropic.ex:1237-1245.
  # The handler always emits :provider_unavailable for SSE error events
  # (regardless of inner error.type) per the implementation.

  test "Anthropic SSE `error` event → terminal {:error, _} with :provider_unavailable" do
    chunks = Fx.stream_chunks(:error_event_stream)
    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    # Some normal text deltas flow before the error.
    assert Enum.any?(events, &match?({:text_delta, _}, &1))

    last = List.last(events)
    assert {:error, %AdapterError{reason: :provider_unavailable, provider: :anthropic}} = last
    assert match?({:error, %AdapterError{cause: %{"type" => "overloaded_error"}}}, last)
  end

  # ---------------------------------------------------------------------------
  # Coverage rider — :stream_timeout
  # ---------------------------------------------------------------------------

  test "stream_timeout exceeded → terminal {:error, _} with :timeout" do
    chunks = Fx.stream_chunks(:happy_text)
    stub = install_stub(chunks, delay_ms: 100)

    {:ok, stream} = call_stream(stub, req(), stream_timeout: 20)
    events = consume(stream)

    assert {:error, %AdapterError{reason: :timeout}} = List.last(events)
  end

  # ---------------------------------------------------------------------------
  # Coverage rider — unknown event names emit :raw_chunk for forward-compat
  # ---------------------------------------------------------------------------

  test "unknown SSE event name → emits {:raw_chunk, {:unknown_event, name, data}}" do
    chunks = [
      "event: future_event\ndata: {\"type\":\"future_event\",\"value\":\"x\"}\n\n",
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    ]

    stub = install_stub(chunks)

    {:ok, stream} = call_stream(stub, req())
    events = consume(stream)

    assert Enum.any?(events, fn
             {:raw_chunk, {:unknown_event, "future_event", _}} -> true
             _ -> false
           end)
  end

  # ---------------------------------------------------------------------------
  # Row 14 — streamed structured output (tool-forcing) — Phase 11.3
  # ---------------------------------------------------------------------------

  test "streamed structured output: tool_use deltas → wrapped to text-stream + lifted message_completed" do
    chunks = Fx.stream_chunks(:structured_output_stream)
    stub = install_stub(chunks)

    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}, "age" => %{"type" => "integer"}}
    }

    request = req(response_format: ALLM.json_schema("person", schema))

    {:ok, stream} = call_stream(stub, request)
    events = consume(stream)

    # Per Decision #5b: the synthetic-tool wrap rewrites the tool_use stream
    # into a text-stream so `StreamCollector.to_response/1` produces a clean
    # `%Response{}` matching the non-streaming arm byte-for-byte (including
    # `metadata.structured_output_tool: true` per invariant 14). Consumers
    # see `:text_delta` events carrying partial JSON as the model emits it
    # — matching OpenAI's native `:json_schema` streaming so provider-neutral
    # consumer code can pattern-match `:text_delta`.
    assert Enum.any?(events, &match?({:text_delta, _}, &1))
    assert Enum.any?(events, &match?({:text_completed, _}, &1))
    refute Enum.any?(events, &match?({:tool_call_started, _}, &1))
    refute Enum.any?(events, &match?({:tool_call_delta, _}, &1))
    refute Enum.any?(events, &match?({:tool_call_completed, _}, &1))

    completed = Enum.filter(events, &match?({:message_completed, _}, &1))
    assert length(completed) == 1
    [{:message_completed, payload}] = completed
    assert payload.finish_reason == :stop
    assert Jason.decode!(payload.message.content) == %{"name" => "Alice", "age" => 30}

    # StreamCollector.to_response/1 yields `%Response{output_text: encoded_json,
    # finish_reason: :stop, tool_calls: []}` per the deferred-row 14 spec.
    response = collect(events)
    assert response.finish_reason == :stop
    assert response.tool_calls == []
    assert is_binary(response.output_text)
    assert Jason.decode!(response.output_text) == %{"name" => "Alice", "age" => 30}
    assert response.metadata[:structured_output_tool] == true
  end
end
