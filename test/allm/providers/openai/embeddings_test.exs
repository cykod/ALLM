defmodule ALLM.Providers.OpenAI.EmbeddingsTest do
  @moduledoc """
  Request-shape, gate, and error-mapping tests for
  `ALLM.Providers.OpenAI.Embeddings`, driven through the module's
  `@doc false` + `@spec` test seams and through `Req.Test` stubs.

  The wire-fixture decode assertions live in `embeddings_wire_test.exs`; the
  10-case behaviour suite lives in `embeddings_conformance_test.exs`.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.OpenAI.Embeddings
  alias ALLM.Providers.OpenAITestFixtures

  # All four `iex>` examples on the module are hermetic — the two `embed/2`
  # ones drive `adapter_opts[:embedding_script]` and the empty-input gate, and
  # `prepare_request/2` passes a literal `api_key:` — so no network, key, or
  # stub is needed. Binding on 20.5 / 20.6: wire the `doctest` or the examples
  # rot silently.
  doctest Embeddings

  setup do
    {:ok, stub: String.to_atom("openai_embeddings_stub_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []) do
    EmbeddingRequest.new(
      Keyword.merge([input: ["a kestrel"], model: "text-embedding-3-small"], opts)
    )
  end

  defp call(stub, request, opts \\ []) do
    adapter_opts = opts |> Keyword.get(:adapter_opts, []) |> Keyword.put(:plug, {Req.Test, stub})

    Embeddings.embed(
      request,
      opts
      |> Keyword.merge(api_key: "sk-embeddings-test", retry: false)
      |> Keyword.put(:adapter_opts, adapter_opts)
    )
  end

  # ---------------------------------------------------------------------------
  # max_batch_size/0
  # ---------------------------------------------------------------------------

  describe "max_batch_size/0" do
    test "returns 2048" do
      assert Embeddings.max_batch_size() == 2048
    end
  end

  # ---------------------------------------------------------------------------
  # to_json_body/2
  # ---------------------------------------------------------------------------

  describe "to_json_body/2" do
    test "emits input as an array even for a single input" do
      body = Embeddings.to_json_body(req(input: ["only one"]), [])

      assert body["input"] == ["only one"]
      assert body["model"] == "text-embedding-3-small"
    end

    test "emits input as an array for a batch, order preserved" do
      body = Embeddings.to_json_body(req(input: ["a", "b", "c"]), [])
      assert body["input"] == ["a", "b", "c"]
    end

    test "includes :dimensions when set" do
      assert Embeddings.to_json_body(req(dimensions: 512), [])["dimensions"] == 512
    end

    test "omits :dimensions when nil" do
      refute Map.has_key?(Embeddings.to_json_body(req(), []), "dimensions")
    end

    test "omits :model when nil rather than injecting an adapter-side default" do
      refute Map.has_key?(Embeddings.to_json_body(req(model: nil), []), "model")
    end

    test "omits :task_type entirely" do
      body = Embeddings.to_json_body(req(task_type: :search_query), [])

      refute Map.has_key?(body, "task_type")
      refute Map.has_key?(body, "taskType")
      refute Map.has_key?(body, "input_type")
    end

    test "logs the dropped :task_type at :debug" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          Embeddings.to_json_body(req(task_type: :search_document), [])
        end)

      assert log =~ "task_type"
    end

    test "omits :truncate entirely, in both the default and the explicit-false shape" do
      refute Map.has_key?(Embeddings.to_json_body(req(truncate: true), []), "truncate")
      refute Map.has_key?(Embeddings.to_json_body(req(truncate: false), []), "truncate")
    end

    test "forwards options[:user] as the request-level `user` identifier" do
      body = Embeddings.to_json_body(req(options: %{user: "user-42"}), [])
      assert body["user"] == "user-42"
    end

    test "omits `user` when options carries no :user" do
      refute Map.has_key?(Embeddings.to_json_body(req(), []), "user")
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-flight gates — all fire before key resolution AND before HTTP I/O
  # ---------------------------------------------------------------------------

  describe "embed/2 pre-flight gates" do
    test "input: [] returns :invalid_request before any HTTP I/O", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               call(stub, req(input: []))

      assert err.provider == :openai
      refute_received :should_not_be_called
    end

    test "2049 inputs returns :batch_too_large before any HTTP I/O", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      inputs = for i <- 1..2049, do: "input #{i}"

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large} = err} =
               call(stub, req(input: inputs))

      assert err.metadata.count == 2049
      assert err.metadata.max == 2048
      refute_received :should_not_be_called
    end

    test "dimensions on text-embedding-ada-002 returns :unsupported_feature before I/O", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      assert {:error, %EmbeddingAdapterError{reason: :unsupported_feature} = err} =
               call(stub, req(model: "text-embedding-ada-002", dimensions: 512))

      assert err.metadata.feature == :dimensions
      assert err.metadata.model == "text-embedding-ada-002"
      refute_received :should_not_be_called
    end

    test "ada-002 WITHOUT :dimensions passes the feature gate", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_json(conn, 200, OpenAITestFixtures.embeddings_recorded(:single_input))
      end)

      assert {:ok, %EmbeddingResponse{}} = call(stub, req(model: "text-embedding-ada-002"))
    end

    test "a text-embedding-3 model WITH :dimensions passes the feature gate", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_json(conn, 200, OpenAITestFixtures.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, %EmbeddingResponse{}} = call(stub, req(dimensions: 4))
    end

    test "every gate fires ahead of ALLM.Keys.fetch!/2 — no key needed" do
      # No `api_key:` in opts and no stub: reaching key resolution would raise
      # %EngineError{reason: :missing_key}. Each gate must return its tuple
      # first, which is what keeps conformance cases 3 and 4 green in a
      # keyless CI environment.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(input: []), [])

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large}} =
               Embeddings.embed(req(input: for(i <- 1..2049, do: "i#{i}")), [])

      assert {:error, %EmbeddingAdapterError{reason: :unsupported_feature}} =
               Embeddings.embed(req(model: "text-embedding-ada-002", dimensions: 512), [])
    end

    test "gate errors carry opts[:request_id] on metadata" do
      assert {:error, %EmbeddingAdapterError{metadata: %{request_id: "rid-9"}}} =
               Embeddings.embed(req(input: []), request_id: "rid-9")
    end

    test "a non-list :input converts to :invalid_request instead of raising" do
      # OpenAI's wire accepts a bare string for `input`, so this is the
      # likeliest direct-adapter mistake. It must return the union — 20.3's
      # `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on any
      # other return shape, so a `FunctionClauseError` here would surface as a
      # crash two layers up.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               Embeddings.embed(%EmbeddingRequest{input: "a kestrel"}, api_key: "sk-x")

      assert err.metadata.field == :input
      assert err.message =~ "list"

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(%EmbeddingRequest{input: %{"text" => "x"}}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Test-injection short-circuit
  # ---------------------------------------------------------------------------

  describe "adapter_opts[:embedding_script] short-circuit" do
    test "delegates to FakeEmbeddings BEFORE any gate runs" do
      # `input: []` would trip the :invalid_request gate on the real path; the
      # short-circuit runs first, so FakeEmbeddings' own gate is what answers.
      script = [{:ok, [Embedding.new(vector: [1.0, 2.0])]}]

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: [1.0, 2.0]}]}} =
               Embeddings.embed(req(), adapter_opts: [embedding_script: script])
    end

    test "keys on the per-call opt only — no ambient switch" do
      # Nothing in the application env, process dictionary, or environment can
      # turn the short-circuit on; only an explicit adapter_opts entry does.
      # Without the key the call takes the real path, reaches key resolution,
      # and raises — which is the observable proof no ambient switch exists.
      assert_raise ALLM.Error.EngineError, fn ->
        Embeddings.embed(req(), adapter_opts: [])
      end
    end

    test "prepare_request/2 returns a stub error rather than delegating" do
      script = [{:ok, [Embedding.new(vector: [1.0])]}]

      assert {:error, %EmbeddingAdapterError{reason: :unknown}} =
               Embeddings.prepare_request(req(), adapter_opts: [embedding_script: script])
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "returns an unfired Req.Request pointed at /v1/embeddings" do
      assert {:ok, %Req.Request{} = http} =
               Embeddings.prepare_request(req(), api_key: "sk-prep-test")

      assert URI.to_string(http.url) == "https://api.openai.com/v1/embeddings"
      assert http.method == :post
    end

    test "applies opts[:request_timeout] as :receive_timeout" do
      assert {:ok, http} =
               Embeddings.prepare_request(req(), api_key: "sk-prep-test", request_timeout: 1234)

      assert http.options[:receive_timeout] == 1234
    end

    test "carries the Bearer authorization header" do
      assert {:ok, http} = Embeddings.prepare_request(req(), api_key: "sk-prep-test")
      assert http.headers["authorization"] == ["Bearer sk-prep-test"]
    end

    test "runs the gates and surfaces their errors" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(req(input: []), [])
    end
  end

  # ---------------------------------------------------------------------------
  # to_embedding_adapter_error/4 — closed status → reason mapping
  # ---------------------------------------------------------------------------

  describe "to_embedding_adapter_error/4" do
    @status_rows [
      {401, :authentication_failed},
      {403, :authentication_failed},
      {400, :invalid_request},
      {500, :provider_unavailable},
      {502, :provider_unavailable},
      {503, :provider_unavailable},
      {504, :provider_unavailable},
      {418, :unknown}
    ]

    for {status, reason} <- @status_rows do
      test "#{status} maps to #{reason}" do
        err = Embeddings.to_embedding_adapter_error(unquote(status), %{}, [], [])
        assert err.reason == unquote(reason)
        assert err.status == unquote(status)
        assert err.provider == :openai
      end
    end

    test "429 maps to :rate_limited and reads retry_after_ms from the header" do
      err =
        Embeddings.to_embedding_adapter_error(429, %{}, [{"retry-after", "7"}], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == 7_000
    end

    test "429 without a Retry-After header leaves retry_after_ms nil" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, [], [])
      assert err.reason == :rate_limited
      assert err.retry_after_ms == nil
    end

    test "400 with code max_tokens_per_request maps to :context_length_exceeded" do
      body = %{"error" => %{"message" => "too many", "code" => "max_tokens_per_request"}}

      assert Embeddings.to_embedding_adapter_error(400, body, [], []).reason ==
               :context_length_exceeded
    end

    test "400 with type max_tokens_per_request maps to :context_length_exceeded" do
      # OpenAI carries the token-budget discriminator on `type`, leaving
      # `code` null — see synthesized/error_400_too_many_tokens.json.
      body = %{"error" => %{"message" => "too many", "type" => "max_tokens_per_request"}}

      assert Embeddings.to_embedding_adapter_error(400, body, [], []).reason ==
               :context_length_exceeded
    end

    test "400 with code context_length_exceeded maps to :context_length_exceeded" do
      body = %{"error" => %{"message" => "too long", "code" => "context_length_exceeded"}}

      assert Embeddings.to_embedding_adapter_error(400, body, [], []).reason ==
               :context_length_exceeded
    end

    test "carries the provider message, code, and type on the struct" do
      body = %{"error" => %{"message" => "boom", "code" => "c1", "type" => "t1"}}
      err = Embeddings.to_embedding_adapter_error(400, body, [], request_id: "rid-1")

      assert err.message == "boom"
      assert err.metadata.openai_code == "c1"
      assert err.metadata.openai_type == "t1"
      assert err.metadata.status == 400
      assert err.metadata.request_id == "rid-1"
    end

    test "never captures the raw response body into :cause or :metadata" do
      body = OpenAITestFixtures.embeddings_synthesized(:error_401)
      err = Embeddings.to_embedding_adapter_error(401, body, [], [])

      assert err.cause == nil
      refute Map.has_key?(err.metadata, :body_preview)
      assert Map.keys(err.metadata) |> Enum.sort() == [:openai_code, :openai_type, :status]
    end

    test "redacts key-shaped strings out of the provider message" do
      body = OpenAITestFixtures.embeddings_synthesized(:error_401)
      err = Embeddings.to_embedding_adapter_error(401, body, [], [])

      key = "sk-proj-FAKEKEY000111222333444555"
      assert body["error"]["message"] =~ key, "fixture must carry a key-shaped string"

      # The struct derives Jason.Encoder and is commonly persisted, so no
      # field of it may carry the key material the provider echoed back.
      refute inspect(err) =~ key
      refute Jason.encode!(err) =~ key
      assert err.message =~ "[REDACTED]"
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive branches — off-shape provider payloads must not raise
  # ---------------------------------------------------------------------------

  describe "defensive branches" do
    test "a non-binary provider message is replaced, not interpolated" do
      err = Embeddings.to_embedding_adapter_error(400, %{"error" => %{"message" => 123}}, [], [])

      assert err.reason == :invalid_request
      assert is_binary(err.message)
      refute err.message =~ "123"
    end

    test "reads Retry-After from map-shaped headers" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, %{"retry-after" => ["3"]}, [])
      assert err.retry_after_ms == 3_000
    end

    test "an HTTP-date Retry-After yields nil rather than raising" do
      headers = [{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]
      assert Embeddings.to_embedding_adapter_error(429, %{}, headers, []).retry_after_ms == nil
    end

    test "a non-map usage object yields an empty %ALLM.Usage{}" do
      body = %{"data" => [%{"index" => 0, "embedding" => [1.0]}], "usage" => "unexpected"}

      assert {:ok, %EmbeddingResponse{usage: %ALLM.Usage{input_tokens: nil, total_tokens: nil}}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "a non-integer usage counter is dropped rather than passed through" do
      body = %{
        "data" => [%{"index" => 0, "embedding" => [1.0]}],
        "usage" => %{"prompt_tokens" => "3", "total_tokens" => 4}
      }

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.input_tokens == nil
      assert usage.total_tokens == 4
    end

    test "off-shape :model / :dimensions / :options values are omitted from the body" do
      body =
        Embeddings.to_json_body(
          %EmbeddingRequest{input: ["x"], model: :not_a_string, dimensions: :big, options: "nope"},
          []
        )

      assert body == %{"input" => ["x"]}
    end

    test "a non-binary options[:user] is omitted" do
      refute Map.has_key?(Embeddings.to_json_body(req(options: %{user: 7}), []), "user")
    end
  end

  # ---------------------------------------------------------------------------
  # decode_response/4
  # ---------------------------------------------------------------------------

  describe "decode_response/4" do
    test "sorts data by :index" do
      body = OpenAITestFixtures.embeddings_synthesized(:shuffled_index_order)

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(body, [], req(input: ["a", "b", "c"]), [])

      assert Enum.map(embeddings, & &1.index) == [0, 1, 2]
      assert Enum.map(embeddings, &hd(&1.vector)) == [0.0, 0.1, 0.2]
    end

    test "maps usage.prompt_tokens to Usage.input_tokens and leaves output_tokens nil" do
      body = OpenAITestFixtures.embeddings_recorded(:batch_input)

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.input_tokens == body["usage"]["prompt_tokens"]
      assert usage.total_tokens == body["usage"]["total_tokens"]
      assert usage.output_tokens == nil
    end

    test "usage is a %ALLM.Usage{} even when the body carries no usage object" do
      body = %{"object" => "list", "data" => [%{"index" => 0, "embedding" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{usage: %ALLM.Usage{} = usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.input_tokens == nil
      assert usage.total_tokens == nil
    end

    test "a body missing \"data\" returns :malformed_response" do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(%{"object" => "list"}, [], req(), [])
    end

    test "a non-map body returns :malformed_response" do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response("<html>502</html>", [], req(), [])
    end

    test ~s(an entry with "embedding": [] returns :malformed_response) do
      body = %{"data" => [%{"index" => 0, "embedding" => []}]}

      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "an entry with a non-numeric vector element returns :malformed_response" do
      body = %{"data" => [%{"index" => 0, "embedding" => [1.0, "nope"]}]}

      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "an entry with no :index returns :malformed_response" do
      body = %{"data" => [%{"embedding" => [1.0]}]}

      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "coerces integer vector components to floats" do
      body = %{"data" => [%{"index" => 0, "embedding" => [0, 1]}]}

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: vector}]}} =
               Embeddings.decode_response(body, [], req(), [])

      assert vector == [0.0, 1.0]
      assert Enum.all?(vector, &is_float/1)
    end

    test "malformed errors never carry a raw body preview" do
      assert {:error, err} =
               Embeddings.decode_response(%{"secret" => "hunter2"}, [], req(), [])

      refute inspect(err) =~ "hunter2"
    end

    # -------------------------------------------------------------------------
    # REQUIRED: binds ALLM.EmbeddingAdapter invariant 8.
    #
    # The conformance suite drives this adapter through the
    # `adapter_opts[:embedding_script]` short-circuit, so its success path
    # never reaches `decode_response/4` — a decoder that drops entries or
    # mis-indexes them passes all 10 cases. This is the assertion that
    # actually binds the invariant for this adapter.
    # -------------------------------------------------------------------------
    test "invariant 8: cardinality and 0..n-1 indices over the live recorded batch" do
      body = OpenAITestFixtures.embeddings_recorded(:batch_input)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(body, [], req(input: input), [])

      # These two bind the DECODER: a decoder that drops entries, broadcasts
      # one vector, or falls back to list position fails them.
      assert length(embeddings) == length(input)
      assert Enum.map(embeddings, & &1.index) == Enum.to_list(0..(length(input) - 1))

      # Rules out a decoder that broadcasts one vector across every slot — a
      # failure the cardinality and index clauses alone would miss.
      assert embeddings |> Enum.map(& &1.vector) |> Enum.uniq() |> length() == length(input)

      # Non-zero vector length IS an adapter guarantee — `decode_embedding_entry/2`
      # rejects `embedding: []` as :malformed_response (pinned separately above).
      refute Enum.any?(embeddings, &(&1.vector == []))

      # Uniform length across entries is NOT. `decode_data_list/2` folds
      # entries independently and the adapter performs no cross-entry length
      # comparison, so the assertion below is a property of THIS fixture (a
      # real 3 × 1536 OpenAI response), not of the decoder. A ragged body
      # decodes cleanly today and `ALLM.EmbeddingResponse.dimensions/1` reads
      # the head vector only. Tracked in ASKS.md; do not re-word this as an
      # adapter guarantee in 20.5 / 20.6 without adding the gate and a
      # deliberately-ragged fixture to drive it.
      assert embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() |> length() == 1
    end

    test "round-trips request.metadata onto response.metadata UNCHANGED (invariant 7)" do
      metadata = %{trace: "t-1", tenant: 7}
      body = OpenAITestFixtures.embeddings_recorded(:single_input)

      assert {:ok, %EmbeddingResponse{metadata: ^metadata}} =
               Embeddings.decode_response(body, [], req(metadata: metadata), [])
    end

    test "preserves opts[:request_id] onto response.request_id (invariant 6)" do
      body = OpenAITestFixtures.embeddings_recorded(:single_input)

      assert {:ok, %EmbeddingResponse{request_id: "rid-42"}} =
               Embeddings.decode_response(body, [], req(), request_id: "rid-42")
    end

    test "falls back to the provider x-request-id when opts[:request_id] is absent" do
      body = OpenAITestFixtures.embeddings_recorded(:single_input)
      headers = [{"x-request-id", "req_openai_abc"}]

      assert {:ok, %EmbeddingResponse{request_id: "req_openai_abc"}} =
               Embeddings.decode_response(body, headers, req(), [])
    end

    test "prefers the body's model over the request's" do
      body = OpenAITestFixtures.embeddings_recorded(:single_input)

      assert {:ok, %EmbeddingResponse{model: "text-embedding-3-small"}} =
               Embeddings.decode_response(body, [], req(model: "stale"), [])
    end

    test "falls back to the request model when the body carries none" do
      body = %{"data" => [%{"index" => 0, "embedding" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{model: "text-embedding-3-small"}} =
               Embeddings.decode_response(body, [], req(), [])
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP transport failures — invariant 2 for NON-gate shapes
  # ---------------------------------------------------------------------------

  describe "transport failures convert to %EmbeddingAdapterError{}" do
    # Invariant 3, half A — the CONVERSION. `Req.Test` dispatches through
    # `Req.Steps.run_plug`, which runs the plug in-process: no socket is
    # opened and `:receive_timeout` is never consulted, so a stub that sleeps
    # cannot produce a real timeout and passing `request_timeout:` here would
    # be inert. `Req.Test.transport_error/2` is the only mechanism that
    # produces the exception this clause converts. Half B — that
    # `opts[:request_timeout]` actually lands as `:receive_timeout` — is
    # pinned by "prepare_request/2 applies opts[:request_timeout] as
    # :receive_timeout" above, which binds `embed/2` too because both share
    # `build_request/2`. Binding on 20.5 / 20.6 as a TWO-test split; do not
    # collapse it into one test that passes a timeout it never observes.
    test "a transport timeout converts to %EmbeddingAdapterError{reason: :timeout}", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %EmbeddingAdapterError{reason: :timeout} = err} = call(stub, req())

      assert err.provider == :openai
      assert err.message =~ "timed out"
    end

    test "a non-timeout transport failure returns :network_error", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %EmbeddingAdapterError{reason: :network_error} = err} = call(stub, req())
      assert err.message =~ "transport failure"
    end

    test "an unparseable 200 body returns :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "not json at all")
      end)

      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} = call(stub, req())
    end

    test "a non-map error body on a 4xx still classifies by status", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(503, "upstream connect error")
      end)

      assert {:error, %EmbeddingAdapterError{reason: :provider_unavailable}} =
               call(stub, req())
    end

    test "a 429 is retried and surfaces :rate_limited on exhaustion", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, OpenAITestFixtures.embeddings_synthesized(:error_429), [
          {"retry-after", "0"}
        ])
      end)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               call(stub, req(),
                 retry: [retry_on: [:rate_limited], max_attempts: 2, base_delay_ms: 0, jitter_ms: 0]
               )
    end
  end
end
