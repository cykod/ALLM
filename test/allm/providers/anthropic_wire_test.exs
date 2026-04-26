defmodule ALLM.Providers.AnthropicWireTest do
  @moduledoc """
  Phase 11.1 wire-shape tests for `ALLM.Providers.Anthropic.generate/2`.

  Each row covers one `AdapterError.@type reason` atom (or a happy-path
  shape) against a synthesized Anthropic response body using `Req.Test.stub`.
  Per Phase 11 design Decision #11, recorded fixtures live under
  `test/fixtures/anthropic/messages/`; synthesized error fixtures under
  `test/fixtures/anthropic/synthesized/`.

  The 14 + key-thread row enumerated in design §11.1.1 are implemented here.
  Per-test process-isolated stubs via `Req.Test.stub/2` keep rows truly
  `async: true`. The `:vision_rejection` row exercises the upstream
  `ALLM.Validate.request/1` path — the adapter is never invoked when the
  validator catches the request first.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.Error.ValidationError
  alias ALLM.Message
  alias ALLM.Providers.Anthropic
  alias ALLM.Providers.AnthropicTestFixtures, as: Fx
  alias ALLM.Request

  setup do
    stub = String.to_atom("anthropic_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub}
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "claude-sonnet-4-6"], opts)
    )
  end

  defp call(stub, request, opts \\ []) do
    Anthropic.generate(
      request,
      Keyword.merge(
        [api_key: "sk-ant-wire-test"],
        Keyword.merge(opts, adapter_opts: [plug: {Req.Test, stub}])
      )
    )
  end

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp respond_with(conn, status, body, headers) when is_list(headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  @doc false
  def handle_retry_event(_event, _measurements, meta, config) do
    %{parent: parent, request_id: request_id} = config

    if Map.get(meta, :request_id) == request_id do
      send(parent, {:retry, meta.attempt})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Row 1 — happy text 200
  # ---------------------------------------------------------------------------

  test "200 happy text → {:ok, %Response{output_text: \"hello\", finish_reason: :stop}}", %{
    stub: stub
  } do
    body = Fx.messages_response(:happy_text)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.output_text == "hello"
    assert response.finish_reason == :stop
    assert response.id == "msg_synth_happy"
    assert response.usage.input_tokens == 9
    assert response.usage.output_tokens == 1
    assert response.usage.total_tokens == 10
  end

  # ---------------------------------------------------------------------------
  # Row 2 — single tool_use
  # ---------------------------------------------------------------------------

  test "200 single tool_use → finish_reason: :tool_calls, tool_calls populated", %{stub: stub} do
    body = Fx.messages_response(:single_tool_use)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.finish_reason == :tool_calls
    assert [tc] = response.tool_calls
    assert tc.id == "toolu_abc123"
    assert tc.name == "get_weather"
    assert tc.arguments == %{"city" => "Boston"}
    # Decision #6: raw_arguments computed from input map for OpenAI parity.
    assert is_binary(tc.raw_arguments)
  end

  # ---------------------------------------------------------------------------
  # Row 3 — parallel tool_use
  # ---------------------------------------------------------------------------

  test "200 parallel tool_use → both ids preserved", %{stub: stub} do
    body = Fx.messages_response(:parallel_tool_use)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.finish_reason == :tool_calls
    assert [a, b] = response.tool_calls
    assert a.id == "toolu_a1"
    assert a.arguments == %{"city" => "Boston"}
    assert b.id == "toolu_b2"
    assert b.arguments == %{"city" => "Seattle"}
  end

  # ---------------------------------------------------------------------------
  # Row 4 — 401 authentication_failed
  # ---------------------------------------------------------------------------

  test "401 → {:error, :authentication_failed}", %{stub: stub} do
    body = Fx.synthesized(:auth_failed)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 401, body) end)

    assert {:error, %AdapterError{} = err} = call(stub, req())
    assert err.reason == :authentication_failed
    assert err.status == 401
    assert err.provider == :anthropic
  end

  # ---------------------------------------------------------------------------
  # Row 5 — 400 invalid_request
  # ---------------------------------------------------------------------------

  test "400 → {:error, :invalid_request}", %{stub: stub} do
    body = Fx.synthesized(:bad_request)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

    assert {:error, %AdapterError{reason: :invalid_request, status: 400}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 6 — 400 with prompt-too-long marker
  # ---------------------------------------------------------------------------

  test "400 with 'prompt is too long' marker → {:error, :context_length_exceeded}", %{stub: stub} do
    body = Fx.synthesized(:context_length_exceeded)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

    assert {:error, %AdapterError{reason: :context_length_exceeded}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 7 — 413 request_too_large
  # ---------------------------------------------------------------------------

  test "413 → {:error, :invalid_request, status: 413}", %{stub: stub} do
    body = Fx.synthesized(:request_too_large)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 413, body) end)

    assert {:error, %AdapterError{reason: :invalid_request, status: 413}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 8 — 429 with Retry-After: 1 retried successfully on attempt 2
  # ---------------------------------------------------------------------------

  test "429 with Retry-After: 1 → retries; emits one [:allm, :adapter, :retry] event", %{stub: stub} do
    body_429 = Fx.synthesized(:rate_limited)
    headers_429 = Fx.synthesized_headers(:rate_limited)
    body_ok = Fx.messages_response(:happy_text)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)

      if n == 0 do
        respond_with(conn, 429, body_429, [
          {"retry-after", Map.get(headers_429, "Retry-After", "1")}
        ])
      else
        respond_json(conn, 200, body_ok)
      end
    end)

    handler_id = "anthropic-wire-test-retry-#{System.unique_integer([:positive])}"
    request_id = "wt-retry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:allm, :adapter, :retry],
      &__MODULE__.handle_retry_event/4,
      %{parent: parent, request_id: request_id}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, response} =
             call(stub, req(),
               retry: [base_delay_ms: 1, jitter_ms: 0, respect_retry_after: false],
               request_id: request_id
             )

    assert response.finish_reason == :stop
    assert_received {:retry, 1}
    refute_received {:retry, 2}
  end

  # ---------------------------------------------------------------------------
  # Row 9 — 429 exhausting retries (3 attempts) → :rate_limited
  # ---------------------------------------------------------------------------

  test "429 exhausting all 3 attempts → {:error, :rate_limited}", %{stub: stub} do
    body = Fx.synthesized(:rate_limited)
    Req.Test.stub(stub, fn conn -> respond_with(conn, 429, body, [{"retry-after", "0"}]) end)

    handler_id = "anthropic-wire-test-rl-exhaust-#{System.unique_integer([:positive])}"
    request_id = "wt-exhaust-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:allm, :adapter, :retry],
      &__MODULE__.handle_retry_event/4,
      %{parent: parent, request_id: request_id}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %AdapterError{reason: :rate_limited, status: 429}} =
             call(stub, req(),
               retry: [base_delay_ms: 1, jitter_ms: 0, respect_retry_after: false],
               request_id: request_id
             )

    assert_received {:retry, 1}
    assert_received {:retry, 2}
    refute_received {:retry, 3}
  end

  # ---------------------------------------------------------------------------
  # Row 10 — 500 retried successfully on attempt 2
  # ---------------------------------------------------------------------------

  test "500 → retries; second attempt 200 → {:ok, _}", %{stub: stub} do
    body_500 = Fx.synthesized(:server_error)
    body_ok = Fx.messages_response(:happy_text)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)
      if n == 0, do: respond_json(conn, 500, body_500), else: respond_json(conn, 200, body_ok)
    end)

    assert {:ok, response} = call(stub, req(), retry: [base_delay_ms: 1, jitter_ms: 0])
    assert response.finish_reason == :stop
  end

  # ---------------------------------------------------------------------------
  # Row 11 — 529 Overloaded retried successfully (Anthropic-specific Decision #2)
  # ---------------------------------------------------------------------------

  test "529 Overloaded (Anthropic-specific) → retries; second attempt 200", %{stub: stub} do
    body_529 = Fx.synthesized(:overloaded)
    body_ok = Fx.messages_response(:happy_text)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)
      if n == 0, do: respond_json(conn, 529, body_529), else: respond_json(conn, 200, body_ok)
    end)

    handler_id = "anthropic-wire-test-529-#{System.unique_integer([:positive])}"
    request_id = "wt-529-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:allm, :adapter, :retry],
      &__MODULE__.handle_retry_event/4,
      %{parent: parent, request_id: request_id}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, response} =
             call(stub, req(),
               retry: [base_delay_ms: 1, jitter_ms: 0],
               request_id: request_id
             )

    assert response.finish_reason == :stop
    assert_received {:retry, 1}
    refute_received {:retry, 2}
  end

  # ---------------------------------------------------------------------------
  # Row 12 — 529 exhausting retries → :provider_unavailable
  # ---------------------------------------------------------------------------

  test "529 exhausting → {:error, :provider_unavailable, status: 529}", %{stub: stub} do
    body = Fx.synthesized(:overloaded)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 529, body) end)

    assert {:error, %AdapterError{reason: :provider_unavailable, status: 529}} =
             call(stub, req(), retry: [base_delay_ms: 1, jitter_ms: 0])
  end

  # ---------------------------------------------------------------------------
  # Row 13 — 200 with malformed JSON body → :malformed_response
  # ---------------------------------------------------------------------------

  test "200 with malformed JSON → {:error, :malformed_response}", %{stub: stub} do
    raw = Fx.synthesized_raw(:malformed)

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, raw)
    end)

    assert {:error, %AdapterError{reason: :malformed_response}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 14 — TCP/connection failure → :network_error
  # ---------------------------------------------------------------------------

  test "transport failure → {:error, :network_error}", %{stub: stub} do
    Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %AdapterError{reason: :network_error} = err} = call(stub, req(), retry: false)
    assert err.provider == :anthropic
  end

  # ---------------------------------------------------------------------------
  # Row 14b — transport timeout → :timeout
  # ---------------------------------------------------------------------------

  test "transport timeout → {:error, :timeout}", %{stub: stub} do
    Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %AdapterError{reason: :timeout} = err} =
             call(stub, req(), retry: false)

    assert err.provider == :anthropic
  end

  # ---------------------------------------------------------------------------
  # Row 14c — 200 with stop_reason: "refusal" → finish_reason: :content_filter
  # ---------------------------------------------------------------------------

  test "200 with stop_reason: \"refusal\" → {:ok, finish_reason: :content_filter}", %{stub: stub} do
    body = Fx.synthesized(:refusal)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.finish_reason == :content_filter
    assert response.raw_finish_reason == "refusal"
  end

  # ---------------------------------------------------------------------------
  # Row 15 — system-extraction round-trip
  # ---------------------------------------------------------------------------

  test "system-extraction round-trip: top-level system field carries the system content", %{
    stub: stub
  } do
    body_ok = Fx.messages_response(:happy_text)
    parent = self()

    Req.Test.stub(stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(raw)
      send(parent, {:request_body, decoded})
      respond_json(conn, 200, body_ok)
    end)

    request =
      Request.new(
        [
          %Message{role: :system, content: "Be concise."},
          %Message{role: :user, content: "Hi"}
        ],
        model: "claude-sonnet-4-6"
      )

    assert {:ok, _} = call(stub, request)
    assert_received {:request_body, body}
    assert body["system"] == "Be concise."
    assert [%{"role" => "user", "content" => "Hi"}] = body["messages"]
  end

  # ---------------------------------------------------------------------------
  # Row 16 — vision rejection (validator-upstream)
  # ---------------------------------------------------------------------------

  test "vision content rejected upstream by ALLM.Validate.request/1", %{stub: _stub} do
    request =
      Request.new(
        [%Message{role: :user, content: [%{"type" => "image"}]}],
        model: "claude-sonnet-4-6"
      )

    assert {:error, %ValidationError{reason: :vision_not_in_v0_2}} = ALLM.Validate.request(request)
  end

  # ---------------------------------------------------------------------------
  # Row 17 — key threading: api_key opt overrides
  # ---------------------------------------------------------------------------

  test "opts[:api_key] overrides; stub asserts the x-api-key header", %{stub: stub} do
    body = Fx.messages_response(:happy_text)
    parent = self()

    Req.Test.stub(stub, fn conn ->
      [key] = Plug.Conn.get_req_header(conn, "x-api-key")
      [version] = Plug.Conn.get_req_header(conn, "anthropic-version")
      send(parent, {:headers, key, version})
      respond_json(conn, 200, body)
    end)

    assert {:ok, _} = call(stub, req(), api_key: "sk-ant-override-1234")
    assert_received {:headers, "sk-ant-override-1234", "2023-06-01"}
  end

  # ---------------------------------------------------------------------------
  # Row 18 — structured output (tool-forcing per Phase 11.3)
  # ---------------------------------------------------------------------------

  test "structured output (tool-forcing) → output_text JSON-decodes; finish_reason :stop", %{
    stub: stub
  } do
    body = Fx.messages_response(:structured_output)
    parent = self()

    Req.Test.stub(stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(raw)
      send(parent, {:wire_body, decoded})
      respond_json(conn, 200, body)
    end)

    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}, "age" => %{"type" => "integer"}}
    }

    request =
      req(response_format: ALLM.json_schema("person", schema))

    assert {:ok, response} = call(stub, request)

    # The wire body MUST carry the synthetic tool + tool_choice forcing.
    assert_receive {:wire_body, sent}
    assert [synthetic] = sent["tools"]
    assert synthetic["name"] == "respond_with_json_person"
    assert sent["tool_choice"]["type"] == "tool"
    assert sent["tool_choice"]["name"] == "respond_with_json_person"

    # Lifted response shape.
    assert response.finish_reason == :stop
    assert response.tool_calls == []
    assert response.metadata.structured_output_tool == true
    assert is_binary(response.output_text)
    assert Jason.decode!(response.output_text) == %{"name" => "Alice", "age" => 30}
  end
end
