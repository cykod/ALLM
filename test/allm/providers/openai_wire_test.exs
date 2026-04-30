defmodule ALLM.Providers.OpenAIWireTest do
  @moduledoc """
  Phase 10.2 wire-shape tests for `ALLM.Providers.OpenAI.generate/2`.

  Each row covers one `AdapterError.@type reason` atom against a synthesized
  OpenAI response body using `Req.Test.stub`. Per Phase 10 design Decision
  #11, fixtures live under `test/fixtures/openai/{synthesized,chat_completions}/`.

  The 14 rows enumerated in design §10.2.1 are implemented here. Per-test
  process-isolated stubs via `Req.Test.set_req_test_from_context/1` keep
  rows truly `async: true`.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}
  alias ALLM.Providers.OpenAI
  alias ALLM.Providers.OpenAITestFixtures, as: Fx

  setup ctx do
    # Each test uses a unique stub atom (built from the test name) so per-test
    # `Req.Test.stub/2` registrations don't collide. We do NOT touch the
    # global `ALLM.Keys.Store` here — async tests share that Agent and a
    # `delete/1` in one test would race with `get/1` in another. Instead the
    # wire tests pass `api_key:` explicitly via the `call/3` helper.
    stub = String.to_atom("openai_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub, ctx: ctx}
  end

  defp req(opts \\ []) do
    Request.new(
      [%Message{role: :user, content: "hi"}],
      Keyword.merge([model: "gpt-4o-mini"], opts)
    )
  end

  defp call(stub, request, opts \\ []) do
    OpenAI.generate(
      request,
      Keyword.merge(
        [api_key: "sk-wire-test"],
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

  # Telemetry handler — module function (NOT an anonymous fun) to avoid
  # `:telemetry`'s perf warning about local-function attaches. Filter by
  # `request_id` so concurrent tests' events don't bleed into each other,
  # then forward `{:retry, attempt}` to the parent pid carried in `config`.
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
    body = Fx.chat_completion(:happy_text)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.output_text == "hello"
    assert response.finish_reason == :stop
    assert response.id == "chatcmpl-synth-happy"
    assert response.usage.input_tokens == 9
    assert response.usage.output_tokens == 1
    assert response.usage.total_tokens == 10
  end

  # ---------------------------------------------------------------------------
  # Row 2 — single tool call
  # ---------------------------------------------------------------------------

  test "200 single tool call → finish_reason: :tool_calls, tool_calls populated", %{stub: stub} do
    body = Fx.chat_completion(:single_tool_call)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.finish_reason == :tool_calls
    assert [tc] = response.tool_calls
    assert tc.id == "call_abc123"
    assert tc.name == "get_weather"
    assert tc.arguments == %{"city" => "Boston"}
  end

  # ---------------------------------------------------------------------------
  # Row 3 — parallel tool calls
  # ---------------------------------------------------------------------------

  test "200 parallel tool calls → both ids preserved", %{stub: stub} do
    body = Fx.chat_completion(:parallel_tool_calls)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req())
    assert response.finish_reason == :tool_calls
    assert [a, b] = response.tool_calls
    assert a.id == "call_a1"
    assert a.arguments == %{"city" => "Boston"}
    assert b.id == "call_b2"
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
    assert err.provider == :openai
  end

  # ---------------------------------------------------------------------------
  # Row 5 — 400 invalid_request
  # ---------------------------------------------------------------------------

  test "400 → {:error, :invalid_request}", %{stub: stub} do
    body = Fx.synthesized(:invalid_request)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

    assert {:error, %AdapterError{reason: :invalid_request, status: 400}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 6 — 400 with code: context_length_exceeded
  # ---------------------------------------------------------------------------

  test "400 with code: context_length_exceeded → {:error, :context_length_exceeded}", %{stub: stub} do
    body = Fx.synthesized(:context_length_exceeded)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

    assert {:error, %AdapterError{reason: :context_length_exceeded}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 7 — 400 with content_filter type
  # ---------------------------------------------------------------------------

  test "400 with type: content_filter → {:error, :content_filter}", %{stub: stub} do
    body = Fx.synthesized(:content_filter)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

    assert {:error, %AdapterError{reason: :content_filter}} = call(stub, req())
  end

  # ---------------------------------------------------------------------------
  # Row 8 — 429 with Retry-After: 1, retried successfully on attempt 2
  # ---------------------------------------------------------------------------

  test "429 with Retry-After: 1 → retries; emits one [:allm, :adapter, :retry] event", %{stub: stub} do
    body_429 = Fx.synthesized(:rate_limited)
    headers_429 = Fx.synthesized_headers(:rate_limited)
    body_ok = Fx.chat_completion(:happy_text)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)

      if n == 0 do
        respond_with(
          conn,
          429,
          body_429,
          [{"retry-after", Map.get(headers_429, "Retry-After", "1")}]
        )
      else
        respond_json(conn, 200, body_ok)
      end
    end)

    handler_id = "openai-wire-test-retry-#{System.unique_integer([:positive])}"
    request_id = "wt-retry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:allm, :adapter, :retry],
      &__MODULE__.handle_retry_event/4,
      %{parent: parent, request_id: request_id}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Tight retry policy so the test is fast: jitter 0, base 1ms.
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

    handler_id = "openai-wire-test-rl-exhaust-#{System.unique_integer([:positive])}"
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

    # max_attempts: 3 → 2 retry events (first two attempts trigger retries; the
    # third's :retry result is collapsed to :error without a fourth attempt).
    assert_received {:retry, 1}
    assert_received {:retry, 2}
    refute_received {:retry, 3}
  end

  # ---------------------------------------------------------------------------
  # Row 10 — 500 retried successfully on attempt 2
  # ---------------------------------------------------------------------------

  test "500 → retries; second attempt 200 → {:ok, _}", %{stub: stub} do
    body_500 = Fx.synthesized(:server_error)
    body_ok = Fx.chat_completion(:happy_text)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(agent, fn i -> {i, i + 1} end)
      if n == 0, do: respond_json(conn, 500, body_500), else: respond_json(conn, 200, body_ok)
    end)

    assert {:ok, response} =
             call(stub, req(), retry: [base_delay_ms: 1, jitter_ms: 0])

    assert response.finish_reason == :stop
  end

  # ---------------------------------------------------------------------------
  # Row 11 — 500 exhausting retries → :provider_unavailable
  # ---------------------------------------------------------------------------

  test "500 exhausting → {:error, :provider_unavailable}", %{stub: stub} do
    body = Fx.synthesized(:server_error)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 500, body) end)

    assert {:error, %AdapterError{reason: :provider_unavailable, status: 500}} =
             call(stub, req(), retry: [base_delay_ms: 1, jitter_ms: 0])
  end

  # ---------------------------------------------------------------------------
  # Row 12 — 200 with malformed JSON body → :malformed_response
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
  # Row 13 — TCP/connection failure (Mint.TransportError) → :network_error
  # ---------------------------------------------------------------------------

  test "transport failure (Mint.TransportError) → {:error, :network_error}", %{stub: stub} do
    # Req.Test.transport_error/2 is the canonical way to simulate a transport
    # failure; it makes the request return `{:error, %Mint.TransportError{}}`
    # which Req surfaces as a plain error tuple.
    Req.Test.stub(stub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    # Disable retry so the closure's {:error, _} path runs once and surfaces.
    assert {:error, %AdapterError{reason: :network_error} = err} = call(stub, req(), retry: false)
    assert err.provider == :openai
  end

  # ---------------------------------------------------------------------------
  # Row 14 — key threading: api_key opt overrides env-var key
  # ---------------------------------------------------------------------------

  test "opts[:api_key] overrides; stub asserts the Authorization header", %{stub: stub} do
    body = Fx.chat_completion(:happy_text)
    parent = self()

    Req.Test.stub(stub, fn conn ->
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      send(parent, {:auth, auth})
      respond_json(conn, 200, body)
    end)

    assert {:ok, _} = call(stub, req(), api_key: "sk-override-1234")
    assert_received {:auth, "Bearer sk-override-1234"}
  end

  # ---------------------------------------------------------------------------
  # Phase 10.6 — Responses API non-streaming wire tests
  # ---------------------------------------------------------------------------

  test "Phase 10.6: Responses-API happy text (gpt-5.5)", %{stub: stub} do
    body = Fx.responses(:happy_text)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req(model: "gpt-5.5"))
    assert response.output_text == "hello"
    assert response.finish_reason == :stop
    assert response.id == "resp_synth_happy"
    assert response.usage.input_tokens == 9
    assert response.usage.output_tokens == 1
    assert response.usage.reasoning_tokens == 0
  end

  test "Phase 10.6: Responses-API reasoning response populates Usage.reasoning_tokens and metadata.reasoning",
       %{stub: stub} do
    body = Fx.responses(:reasoning_response)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req(model: "gpt-5.5"))
    assert response.usage.reasoning_tokens > 0
    assert response.metadata.reasoning.effort == "medium"
  end

  test "Phase 10.6: Responses-API incomplete (max_output_tokens) → :length finish_reason",
       %{stub: stub} do
    body = Fx.synthesized(:incomplete_response)
    Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

    assert {:ok, response} = call(stub, req(model: "gpt-5.5"))
    assert response.finish_reason == :length
    assert response.metadata.incomplete_details.reason == "max_output_tokens"
  end

  # ---------------------------------------------------------------------------
  # Phase 14.4 — wire-shape regression for stringify_content/1 extension
  # ---------------------------------------------------------------------------

  describe "Phase 14.4: stringify_content/1 multimodal materialization (Chat Completions)" do
    test "string content emits content as a binary on the wire", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: "hello"}],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "hello"}] = body["messages"]
    end

    test "single [%TextPart{}] content materializes to its text", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: [%TextPart{text: "hello"}]}],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "hello"}] = body["messages"]
    end

    test "multi-TextPart content joins with newline", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "a"}, %TextPart{text: "b"}]
            }
          ],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "a\nb"}] = body["messages"]
    end

    # Phase 17.1: ImagePart in user-role content now translates to a
    # Chat Completions content-block list — the Phase 14.4 reject guard
    # is replaced by a real translator. Detail field is nested in the
    # `image_url` map (Chat Completions wire shape).
    test "[%TextPart{}, %ImagePart{}] mixed content emits Chat Completions content-block list",
         %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "x"}, %ImagePart{image: img, detail: :high}]
            }
          ],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}

      assert [%{"role" => "user", "content" => content}] = body["messages"]

      assert content == [
               %{"type" => "text", "text" => "x"},
               %{
                 "type" => "image_url",
                 "image_url" => %{
                   "url" => "https://example.com/cat.png",
                   "detail" => "high"
                 }
               }
             ]
    end
  end

  describe "Phase 14.4: stringify_content/1 multimodal materialization (Responses)" do
    test "string content emits input as a string on the Responses wire", %{stub: stub} do
      body_ok = Fx.responses(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: "hello"}],
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "hello"}] = body["input"]
    end

    test "single [%TextPart{}] content materializes to its text on Responses",
         %{stub: stub} do
      body_ok = Fx.responses(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: [%TextPart{text: "hello"}]}],
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "hello"}] = body["input"]
    end

    test "multi-TextPart content joins with newline on Responses", %{stub: stub} do
      body_ok = Fx.responses(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "a"}, %TextPart{text: "b"}]
            }
          ],
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "a\nb"}] = body["input"]
    end

    # Phase 17.1: ImagePart on the Responses wire now translates to an
    # `input_image` content-block list with `detail` at sibling level
    # (NOT nested inside `image_url`).
    test "[%TextPart{}, %ImagePart{}] mixed content emits Responses content-block list",
         %{stub: stub} do
      body_ok = Fx.responses(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "x"}, %ImagePart{image: img, detail: :low}]
            }
          ],
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}

      assert [%{"role" => "user", "content" => content}] = body["input"]

      assert content == [
               %{"type" => "input_text", "text" => "x"},
               %{
                 "type" => "input_image",
                 "image_url" => "https://example.com/cat.png",
                 "detail" => "low"
               }
             ]
    end
  end
end
