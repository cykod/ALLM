defmodule ALLM.Providers.Voyage.EmbeddingsTest do
  @moduledoc """
  Request-shape, gate, and error-mapping tests for
  `ALLM.Providers.Voyage.Embeddings`, driven through the module's
  `@doc false` + `@spec` test seams and through `Req.Test` stubs.

  The wire-fixture decode assertions live in `embeddings_wire_test.exs`; the
  10-case behaviour suite lives in `embeddings_conformance_test.exs`.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.Voyage.Embeddings
  alias ALLM.Providers.VoyageTestFixtures, as: Fx

  # All four `iex>` examples on the module are hermetic — two drive
  # `adapter_opts[:embedding_script]` and the empty-input gate, and
  # `prepare_request/2` passes a literal `api_key:`. Wiring the doctest is what
  # stops them rotting; they shipped decorative on the OpenAI adapter until its
  # fix step caught it, and the same omission recurred one directory over.
  doctest Embeddings

  # Same class of omission in `test/support/`: the loader's `iex>` examples read
  # as tests and run as comments unless a file declares the doctest. Wiring it
  # here is not free-riding — `length(body["data"]) == 3` is exactly the "MUST
  # record exactly THREE inputs" property that
  # `scripts/record_voyage_embeddings_fixtures.exs` declares load-bearing for
  # behaviour invariant 8, so this is a second guard on fixture cardinality in a
  # different file from the one that already asserts it.
  doctest Fx

  @model "voyage-3.5-lite"

  setup do
    {:ok, stub: String.to_atom("voyage_embeddings_stub_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []) do
    EmbeddingRequest.new(Keyword.merge([input: ["a kestrel"], model: @model], opts))
  end

  defp call(stub, request, opts \\ []) do
    adapter_opts = opts |> Keyword.get(:adapter_opts, []) |> Keyword.put(:plug, {Req.Test, stub})

    Embeddings.embed(
      request,
      opts
      |> Keyword.merge(api_key: "pa-embeddings-test", retry: false)
      |> Keyword.put(:adapter_opts, adapter_opts)
    )
  end

  defp body(request, opts \\ []), do: Embeddings.to_json_body(request, opts)

  # ---------------------------------------------------------------------------
  # max_batch_size/0
  # ---------------------------------------------------------------------------

  describe "max_batch_size/0" do
    test "returns 1000" do
      assert Embeddings.max_batch_size() == 1000
    end
  end

  # ---------------------------------------------------------------------------
  # to_json_body/2
  # ---------------------------------------------------------------------------

  describe "to_json_body/2" do
    # The return shape is the adjudicated one: a bare `map()`, matching the
    # OpenAI sibling rather than the Gemini sibling's `{:ok, map()}` tuple.
    # Gemini's tuple is forced by a per-provider invariant (its model is
    # required in the URL path AND on every sub-request); Voyage has no such
    # constraint, so the embeddings CAPABILITY family wins.
    test "returns a bare map, not an {:ok, map} tuple" do
      assert %{"input" => _} = body(req())
    end

    test "emits input as an array even for a single input" do
      assert body(req(input: ["only one"]))["input"] == ["only one"]
      assert body(req())["model"] == @model
    end

    test "emits input as an array for a batch, order preserved" do
      assert body(req(input: ["a", "b", "c"]))["input"] == ["a", "b", "c"]
    end

    test "omits :model when nil rather than injecting an adapter-side default" do
      refute Map.has_key?(body(req(model: nil)), "model")
    end

    test "emits output_dimension (snake_case) when :dimensions is set" do
      emitted = body(req(dimensions: 512))

      assert emitted["output_dimension"] == 512
      # The other two providers' spellings must NOT appear — a copy-paste from
      # either sibling is a silently-ignored field, and Voyage 400s on unknown
      # arguments (established by the recorder's CONTROL arm).
      refute Map.has_key?(emitted, "dimensions")
      refute Map.has_key?(emitted, "outputDimensionality")
    end

    test "omits output_dimension when :dimensions is nil" do
      refute Map.has_key?(body(req()), "output_dimension")
    end

    @task_type_rows [
      {:search_query, "query"},
      {:search_document, "document"}
    ]

    for {atom, wire} <- @task_type_rows do
      test "maps task_type #{atom} to input_type #{wire}" do
        assert body(req(task_type: unquote(atom)))["input_type"] == unquote(wire)
      end
    end

    # The lossy half. `:classification`, `:clustering`, and `:similarity` are
    # symmetric tasks; Voyage documents an ABSENT `input_type` as "no retrieval
    # prompt is prepended", which is the correct semantic for them rather than a
    # degradation.
    for atom <- [:classification, :clustering, :similarity] do
      test "omits input_type for the symmetric task_type #{atom}" do
        refute Map.has_key?(body(req(task_type: unquote(atom))), "input_type")
      end
    end

    test "omits input_type when :task_type is nil" do
      refute Map.has_key?(body(req()), "input_type")
    end

    test "logs the dropped :task_type at :debug" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          body(req(task_type: :clustering))
        end)

      assert log =~ "task_type"
      assert log =~ "clustering"
    end

    test "omits truncation when truncate: true (the provider default)" do
      refute Map.has_key?(body(req(truncate: true)), "truncation")
    end

    test "emits truncation: false when truncate: false" do
      assert body(req(truncate: false))["truncation"] == false
    end

    # Voyage's schema has no request-level end-user identifier and rejects
    # unknown arguments with a 400, so the OpenAI sibling's `options[:user]`
    # forwarding must NOT be carried over.
    test "does not forward options[:user] — Voyage has no such argument" do
      refute Map.has_key?(body(req(options: %{user: "user-42"})), "user")
    end

    test "the body carries only the keys this adapter sets" do
      emitted = body(req(input: ["a"], dimensions: 512, task_type: :search_query, truncate: false))

      assert emitted |> Map.keys() |> Enum.sort() ==
               ["input", "input_type", "model", "output_dimension", "truncation"]
    end
  end

  # ---------------------------------------------------------------------------
  # to_voyage_task_type/1
  # ---------------------------------------------------------------------------

  describe "to_voyage_task_type/1" do
    for {atom, wire} <- @task_type_rows do
      test "#{atom} -> #{wire}" do
        assert Embeddings.to_voyage_task_type(unquote(atom)) == unquote(wire)
      end
    end

    for atom <- [:classification, :clustering, :similarity, nil] do
      test "#{inspect(atom)} omits" do
        assert Embeddings.to_voyage_task_type(unquote(atom)) == nil
      end
    end

    # `ALLM.Serializer.to_atom_field/1` is `String.to_existing_atom/1`, so a
    # decoded `:task_type` is NOT guaranteed enum-legal — `"erlang"` decodes to
    # `:erlang`. An exhaustive mapper falling through to omit is the contract;
    # `Atom.to_string/1` would put arbitrary atoms on the wire, and Voyage 400s
    # on an `input_type` outside its two-member enum.
    test "an atom outside the closed enum omits rather than reaching the wire" do
      assert Embeddings.to_voyage_task_type(:erlang) == nil
      refute Map.has_key?(body(req(task_type: :erlang)), "input_type")
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

      assert err.provider == :voyage
      refute_received :should_not_be_called
    end

    test "1001 inputs returns :batch_too_large before any HTTP I/O", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      inputs = for i <- 1..1001, do: "input #{i}"

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large} = err} =
               call(stub, req(input: inputs))

      assert err.metadata.count == 1001
      assert err.metadata.max == 1000
      refute_received :should_not_be_called
    end

    test "exactly 1000 inputs passes the batch gate", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        data = for i <- 0..999, do: %{"index" => i, "embedding" => [1.0, 2.0]}
        respond_json(conn, 200, %{"object" => "list", "data" => data})
      end)

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               call(stub, req(input: for(i <- 1..1000, do: "i#{i}")))

      assert length(embeddings) == 1000
    end

    # The POSITIVE CONTROL for the gate-ordering claim below. Without it, "every
    # gate fires ahead of `ALLM.Keys.fetch!/2`" could pass vacuously if key
    # resolution had been removed or defaulted — the assertions there would
    # still hold with no key anywhere in the picture. This proves the key
    # lookup is genuinely downstream of the gates: a request that PASSES every
    # gate reaches it and raises.
    test "positive control: a request that passes every gate DOES reach key resolution" do
      assert_raise ALLM.Error.EngineError, fn ->
        Embeddings.embed(req(), [])
      end
    end

    test "every gate fires ahead of ALLM.Keys.fetch!/2 — no key needed" do
      # No `api_key:` in opts and no stub: reaching key resolution would raise
      # %EngineError{reason: :missing_key} (proven by the positive control
      # above). Each gate must return its tuple first, which is what keeps
      # conformance cases 3 and 4 green in a keyless CI environment.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(input: []), [])

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large}} =
               Embeddings.embed(req(input: for(i <- 1..1001, do: "i#{i}")), [])

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(input: [%{"a" => 1}]), [])
    end

    test "gate errors carry opts[:request_id] on metadata" do
      assert {:error, %EmbeddingAdapterError{metadata: %{request_id: "rid-9"}}} =
               Embeddings.embed(req(input: []), request_id: "rid-9")
    end

    # Binding across the whole embeddings family under the same `gate_*/2`
    # prefix: `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on
    # any return outside `{:ok, _} | {:error, _}`, so a `FunctionClauseError`
    # here would surface as a batcher bug two layers up.
    test "a non-list :input converts to :invalid_request instead of raising" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               Embeddings.embed(%EmbeddingRequest{input: "a kestrel", model: @model},
                 api_key: "pa-x"
               )

      assert err.metadata.field == :input
      assert err.message =~ "list"

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(%EmbeddingRequest{input: %{"text" => "x"}}, [])
    end

    # One level down: the CONTAINER is a list but an ELEMENT is not a string.
    # The body builder hands `:input` to the encoder verbatim, so a map or an
    # integer would merely earn a provider 400 — but a TUPLE is unencodable and
    # `Jason` raises `Protocol.UndefinedError` from inside `Req.request/1`,
    # past every gate. That is the invariant-2 breach `gate_input/2` closes, and
    # the reason this adapter adopts the gate even though its body builder does
    # not reach inside elements the way the Gemini sibling's does.
    test "a non-string :input ELEMENT converts to :invalid_request instead of raising" do
      for element <- [%{"a" => 1}, {:a, 1}, 42, nil, ["nested"]] do
        assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
                 Embeddings.embed(req(input: ["ok", element]), api_key: "pa-x"),
               "input element #{inspect(element)} did not convert"

        assert err.metadata.field == :input
        assert err.provider == :voyage
      end
    end

    # The falsifier for the clause above: without the gate, THIS input raises
    # rather than returning a tuple, because a tuple has no `Jason.Encoder`.
    # A map element alone would not have caught the hole (it encodes fine and
    # the provider 400s), which is why the loop above spans both shapes.
    test "a tuple element specifically — the shape that would raise out of Jason", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               call(stub, req(input: [{:a, 1}]))

      refute_received :should_not_be_called
    end

    test "invariant 10: prepare_request/2 rejects the same requests embed/2 does" do
      for request <- [
            req(input: []),
            req(input: for(i <- 1..1001, do: "i#{i}")),
            req(input: [{:a, 1}])
          ] do
        assert {:error, %EmbeddingAdapterError{}} = Embeddings.embed(request, [])
        assert {:error, %EmbeddingAdapterError{}} = Embeddings.prepare_request(request, [])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test-injection short-circuit
  # ---------------------------------------------------------------------------

  describe "adapter_opts[:embedding_script] short-circuit" do
    test "delegates to FakeEmbeddings BEFORE any gate runs" do
      # `input: []` would trip the :invalid_request gate on the real path; the
      # short-circuit runs first, so FakeEmbeddings is what answers.
      script = [{:ok, [Embedding.new(vector: [1.0, 2.0])]}]

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: [1.0, 2.0]}]}} =
               Embeddings.embed(req(), adapter_opts: [embedding_script: script])
    end

    # NOTE — shared hazard. This assertion (and the positive control at the top
    # of this file) depends on NO `:voyage` key being resolvable, and
    # `ALLM.Keys.Store` is a process-GLOBAL Agent: any `async: true` test
    # calling `ALLM.Keys.put/2` for `:voyage` makes both flake at a subset of
    # seeds.
    # `setup` + `on_exit` (or `try/after`) narrows that window rather than
    # closing it, which is what made the identical Gemini failure intermittent:
    # `test/allm/providers/gemini/embeddings_test.exs` failed at `--seed 3333`
    # because `gemini_vision_test.exs` and `gemini_stream_wire_test.exs` both
    # put a `:gemini` key from `async: true` `setup` blocks. Those two sites now
    # scope the key to `opts[:api_key]` instead; the repo-wide invariant is that
    # `grep -rn 'Keys\.put(' test/` returns only `async: false` modules.
    #
    # PRE-EMPTIVE, for 20.7's `examples/16*.exs` and any examples-adjacent test:
    # do NOT install a `:voyage` key in the global store from an `async: true`
    # module. Pass `api_key:` in the call's opts (highest-precedence level of
    # `ALLM.Keys`' chain), or declare the module `async: false`.
    test "keys on the per-call opt only — no ambient switch" do
      # Nothing in the application env, process dictionary, or environment can
      # turn the short-circuit on. Without the key the call takes the real
      # path, reaches key resolution, and raises — the observable proof.
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
               Embeddings.prepare_request(req(), api_key: "pa-prep-test")

      assert URI.to_string(http.url) == "https://api.voyageai.com/v1/embeddings"
      assert http.method == :post
    end

    # The base URL is a module attribute and is NOT overridable, matching the
    # OpenAI adapters. Only the Gemini adapters honour `adapter_opts[:endpoint]`.
    test "ignores adapter_opts[:endpoint] — the base URL is not overridable" do
      assert {:ok, http} =
               Embeddings.prepare_request(req(),
                 api_key: "pa-prep-test",
                 adapter_opts: [endpoint: "http://localhost:4000/v1"]
               )

      assert URI.to_string(http.url) == "https://api.voyageai.com/v1/embeddings"
    end

    # Invariant 3, half B. `Req.Test` runs plugs in-process via
    # `Req.Steps.run_plug`, so `:receive_timeout` is never consulted there and a
    # "stub that sleeps past the timeout" would be inert. This assertion is what
    # binds the plumbing; the conversion half lives in the transport describe
    # block below. `embed/2` is bound too, because both share `build_request/2`.
    test "applies opts[:request_timeout] as :receive_timeout" do
      assert {:ok, http} =
               Embeddings.prepare_request(req(), api_key: "pa-prep", request_timeout: 1234)

      assert http.options[:receive_timeout] == 1234
    end

    test "carries the Bearer authorization header" do
      assert {:ok, http} = Embeddings.prepare_request(req(), api_key: "pa-prep-test")

      assert http.headers["authorization"] == ["Bearer pa-prep-test"]
      assert http.headers["content-type"] == ["application/json"]
    end

    # Inline headers, deliberately not a shared `VoyageHeaders` module at n = 1.
    # The OpenAI header builder prefixes `openai-organization` when
    # `adapter_opts[:organization]` is set; Voyage rejects unknown arguments, so
    # inheriting that behaviour would be a latent 400.
    test "carries no OpenAI organization header even when adapter_opts sets one" do
      assert {:ok, http} =
               Embeddings.prepare_request(req(),
                 api_key: "pa-prep-test",
                 adapter_opts: [organization: "org-abc"]
               )

      refute Map.has_key?(http.headers, "openai-organization")
    end

    test "runs the gates and surfaces their errors" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(req(input: []), [])
    end
  end

  # ---------------------------------------------------------------------------
  # Key resolution
  # ---------------------------------------------------------------------------

  describe "key resolution" do
    # `:voyage` is not in `ALLM.Keys`' known-provider table; it takes the
    # unknown-provider fallback. The design asserted that behaviour rather than
    # editing the table, so it is pinned here rather than assumed.
    test "the :voyage key atom resolves to VOYAGE_API_KEY" do
      assert ALLM.Keys.env_var_for(:voyage) == "VOYAGE_API_KEY"
    end
  end

  # ---------------------------------------------------------------------------
  # to_embedding_adapter_error/4 — closed status -> reason mapping
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
        assert err.provider == :voyage
      end
    end

    test "429 maps to :rate_limited and reads retry_after_ms from the header" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, [{"retry-after", "7"}], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == 7_000
    end

    test "429 without a Retry-After header leaves retry_after_ms nil" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, [], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == nil
    end

    # Voyage's envelope is a single top-level `detail` STRING — FastAPI-shaped,
    # not OpenAI's `{"error": {message, type, code}}` nor Google's
    # `{"error": {code, message, status}}`. Reading `body["error"]["message"]`
    # here would silently produce a generic message on every real error.
    test ~s(reads the message off the top-level "detail" string) do
      err = Embeddings.to_embedding_adapter_error(400, %{"detail" => "boom"}, [], [])

      assert err.message == "boom"
    end

    test ~s(falls back to a generic message when "detail" is absent) do
      err = Embeddings.to_embedding_adapter_error(400, %{}, [], [])

      assert err.message == "Voyage HTTP 400"
    end

    test "carries the status and opts[:request_id] on metadata, and nothing else" do
      err =
        Embeddings.to_embedding_adapter_error(400, %{"detail" => "boom"}, [], request_id: "rid-1")

      assert err.metadata.status == 400
      assert err.metadata.request_id == "rid-1"
      assert err.metadata |> Map.keys() |> Enum.sort() == [:request_id, :status]
    end

    test "never captures the raw response body into :cause or :metadata" do
      err =
        Embeddings.to_embedding_adapter_error(
          401,
          Fx.embeddings_synthesized(:error_401),
          [],
          []
        )

      assert err.cause == nil
      refute Map.has_key?(err.metadata, :body_preview)
      assert err.metadata |> Map.keys() |> Enum.sort() == [:status]
    end

    # The OpenAI redactor matches `sk-`/`rk-`/`org-` and the Gemini one matches
    # `AIza…`/`ya29.…`; NEITHER catches anything on Voyage. Inheriting either
    # verbatim would be a redactor that redacts nothing.
    test "redacts Voyage-shaped key material out of the provider message" do
      fixture = Fx.embeddings_synthesized(:error_401)
      err = Embeddings.to_embedding_adapter_error(401, fixture, [], [])

      key = "pa-FAKEKEY000111222333444555666777888999aaabb"
      assert fixture["detail"] =~ key, "fixture must carry a key-shaped string"

      # The struct derives Jason.Encoder and is commonly persisted, so no field
      # of it may carry the key material.
      refute inspect(err) =~ key
      refute Jason.encode!(err) =~ key
      assert err.message =~ "[REDACTED]"
    end

    test "the OpenAI and Gemini key patterns would NOT have caught it" do
      # Makes the widening above falsifiable rather than decorative: an
      # inherited pattern is a redactor that silently redacts nothing.
      key = "pa-FAKEKEY000111222333444555666777888999aaabb"

      refute key =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
      refute key =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
    end

    test "a non-binary detail is replaced, not interpolated" do
      err = Embeddings.to_embedding_adapter_error(400, %{"detail" => 123}, [], [])

      assert err.reason == :invalid_request
      assert is_binary(err.message)
      refute err.message =~ "123"
    end
  end

  # ---------------------------------------------------------------------------
  # :context_length_exceeded — the one reason with a prose discriminator
  # ---------------------------------------------------------------------------

  describe "context-length classification" do
    # Voyage carries no structured error code, so the context-window rejection
    # can only be recognised from the `detail` prose. The live envelope is at
    # `recorded/error_400_context_length.json`; the wire test drives it
    # end-to-end. These pin the classifier's edges.
    test "a 400 naming the context window maps to :context_length_exceeded" do
      detail = Fx.embeddings_recorded(:error_400_context_length)["detail"]

      assert Embeddings.to_embedding_adapter_error(400, %{"detail" => detail}, [], []).reason ==
               :context_length_exceeded
    end

    test "matching is case-insensitive" do
      body = %{"detail" => "Too Many Tokens for this model"}

      assert Embeddings.to_embedding_adapter_error(400, body, [], []).reason ==
               :context_length_exceeded
    end

    # The safe-degradation property: an unrecognised 400 lands on
    # `:invalid_request`, which is exactly where it would land with no marker
    # list at all. A prose change therefore costs specificity, never
    # correctness.
    test "an unrelated 400 still maps to :invalid_request" do
      body = Fx.embeddings_recorded(:error_400_unknown_field)

      assert Embeddings.to_embedding_adapter_error(400, body, [], []).reason == :invalid_request
    end

    test "the marker is not applied to non-400 statuses" do
      body = %{"detail" => "too many tokens"}

      assert Embeddings.to_embedding_adapter_error(500, body, [], []).reason ==
               :provider_unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive branches — off-shape provider payloads must not raise
  # ---------------------------------------------------------------------------

  describe "defensive branches" do
    test "reads Retry-After from map-shaped headers" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, %{"retry-after" => ["3"]}, [])

      assert err.retry_after_ms == 3_000
    end

    test "an HTTP-date Retry-After yields nil rather than raising" do
      headers = [{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]

      assert Embeddings.to_embedding_adapter_error(429, %{}, headers, []).retry_after_ms == nil
    end

    test "a non-map usage object yields an all-nil %ALLM.Usage{}" do
      body = %{"data" => [%{"index" => 0, "embedding" => [1.0]}], "usage" => "unexpected"}

      assert {:ok, %EmbeddingResponse{usage: %ALLM.Usage{total_tokens: nil}}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "a non-integer usage counter is dropped rather than passed through" do
      body = %{
        "data" => [%{"index" => 0, "embedding" => [1.0]}],
        "usage" => %{"total_tokens" => "4"}
      }

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.total_tokens == nil
    end

    test "off-shape :model / :dimensions values are omitted from the body" do
      emitted =
        body(%EmbeddingRequest{input: ["x"], model: :not_a_string, dimensions: :big})

      assert emitted == %{"input" => ["x"]}
    end
  end

  # ---------------------------------------------------------------------------
  # decode_response/4
  # ---------------------------------------------------------------------------

  describe "decode_response/4" do
    # Voyage publishes `index` for the same reason OpenAI does — array order is
    # not contractual — so the decoder sorts rather than trusting position.
    test "sorts data by :index" do
      body = %{
        "data" => [
          %{"index" => 2, "embedding" => [0.2]},
          %{"index" => 0, "embedding" => [0.0]},
          %{"index" => 1, "embedding" => [0.1]}
        ]
      }

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(body, [], req(input: ["a", "b", "c"]), [])

      assert Enum.map(embeddings, & &1.index) == [0, 1, 2]
      assert Enum.map(embeddings, &hd(&1.vector)) == [0.0, 0.1, 0.2]
    end

    # THE Voyage asymmetry, and the phase's success criterion.
    test "maps usage.total_tokens to Usage.total_tokens and leaves input_tokens nil" do
      fixture = Fx.embeddings_recorded(:single_input)

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(fixture, [], req(), [])

      assert usage.total_tokens == fixture["usage"]["total_tokens"]
      assert usage.total_tokens > 0
      assert usage.input_tokens == nil
      assert usage.output_tokens == nil
    end

    # Falsifier for the assertion above: Voyage genuinely reports no
    # `prompt_tokens`, so `input_tokens: nil` reflects the wire rather than a
    # decoder that forgot to read it. If Voyage ever starts reporting one, this
    # fails and the mapping should be revisited.
    test "the recorded usage object carries total_tokens and nothing else" do
      usage = Fx.embeddings_recorded(:single_input)["usage"]

      assert Map.keys(usage) == ["total_tokens"]
    end

    test "usage is a %ALLM.Usage{} even when the body carries no usage object" do
      body = %{"object" => "list", "data" => [%{"index" => 0, "embedding" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{usage: %ALLM.Usage{} = usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.total_tokens == nil
    end

    test ~s(a body missing "data" returns :malformed_response) do
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

    # Gemini's key name must NOT be accepted — it would silently decode a
    # foreign envelope with positional indices.
    test ~s(reads data[].embedding, not embeddings[].values) do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(
                 %{"embeddings" => [%{"values" => [1.0]}]},
                 [],
                 req(),
                 []
               )
    end

    test "coerces integer vector components to floats" do
      body = %{"data" => [%{"index" => 0, "embedding" => [0, 1]}]}

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: vector}]}} =
               Embeddings.decode_response(body, [], req(), [])

      assert vector == [0.0, 1.0]
      assert Enum.all?(vector, &is_float/1)
    end

    test "malformed errors never carry a raw body preview" do
      assert {:error, err} = Embeddings.decode_response(%{"secret" => "hunter2"}, [], req(), [])

      refute inspect(err) =~ "hunter2"
      assert err.metadata.body_keys == ["secret"]
    end

    test "round-trips request.metadata onto response.metadata UNCHANGED (invariant 7)" do
      metadata = %{trace: "t-1", tenant: 7}

      assert {:ok, %EmbeddingResponse{metadata: ^metadata}} =
               Embeddings.decode_response(
                 Fx.embeddings_recorded(:single_input),
                 [],
                 req(metadata: metadata),
                 []
               )
    end

    test "preserves opts[:request_id] onto response.request_id (invariant 6)" do
      assert {:ok, %EmbeddingResponse{request_id: "rid-42"}} =
               Embeddings.decode_response(
                 Fx.embeddings_recorded(:single_input),
                 [{"x-request-id", "ignored"}],
                 req(),
                 request_id: "rid-42"
               )
    end

    # Unlike the Gemini sibling — which had nothing to fall back to — Voyage
    # DOES emit an `x-request-id` response header. Verified against the live
    # header list (`alt-svc`, `content-type`, `date`, `server`, `via`,
    # `x-api-warning`, `x-request-id`) rather than ported on faith.
    test "falls back to the provider x-request-id when opts[:request_id] is absent" do
      assert {:ok, %EmbeddingResponse{request_id: "42cc843fb303e1ec"}} =
               Embeddings.decode_response(
                 Fx.embeddings_recorded(:single_input),
                 [{"x-request-id", "42cc843fb303e1ec"}],
                 req(),
                 []
               )
    end

    test "leaves request_id nil when neither opts nor the headers supply one" do
      assert {:ok, %EmbeddingResponse{request_id: nil}} =
               Embeddings.decode_response(Fx.embeddings_recorded(:single_input), [], req(), [])
    end

    test "prefers the body's model over the request's" do
      assert {:ok, %EmbeddingResponse{model: @model}} =
               Embeddings.decode_response(
                 Fx.embeddings_recorded(:single_input),
                 [],
                 req(model: "stale"),
                 []
               )
    end

    test "falls back to the request model when the body carries none" do
      body = %{"data" => [%{"index" => 0, "embedding" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{model: @model}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    # -------------------------------------------------------------------------
    # REQUIRED: binds ALLM.EmbeddingAdapter invariant 8.
    #
    # The conformance suite drives this adapter through the
    # `adapter_opts[:embedding_script]` short-circuit, so its success path never
    # reaches `decode_response/4` — a decoder that drops entries, mis-indexes
    # them, or broadcasts one vector passes all 10 cases. This is the assertion
    # that actually binds the invariant for this adapter.
    # -------------------------------------------------------------------------
    test "invariant 8: cardinality and 0..n-1 indices over the live recorded batch" do
      fixture = Fx.embeddings_recorded(:batch_input)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(fixture, [], req(input: input), [])

      # These two bind the DECODER: a decoder that drops entries or falls back
      # to list position fails them.
      assert length(embeddings) == length(input)
      assert Enum.map(embeddings, & &1.index) == Enum.to_list(0..(length(input) - 1))

      # Rules out a decoder that broadcasts one vector across every slot — a
      # failure the cardinality and index clauses alone would miss.
      assert embeddings |> Enum.map(& &1.vector) |> Enum.uniq() |> length() == length(input)

      # Non-zero vector length IS an adapter guarantee — `decode_embedding_entry/2`
      # rejects `embedding: []` as :malformed_response (pinned separately above).
      refute Enum.any?(embeddings, &(&1.vector == []))

      # Uniform length across entries is NOT. `decode_data_list/2` folds entries
      # independently and the adapter performs no cross-entry length comparison,
      # so the assertion below is a property of THIS fixture (a real 3 × 1024
      # Voyage response), not of the decoder. Kept deliberately separate from
      # the clauses above.
      assert embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP transport failures — invariant 2 for NON-gate shapes
  # ---------------------------------------------------------------------------

  describe "transport failures convert to %EmbeddingAdapterError{}" do
    # Invariant 3, half A — the CONVERSION. `Req.Test` dispatches through
    # `Req.Steps.run_plug`, which runs the plug in-process: no socket is opened
    # and `:receive_timeout` is never consulted, so a stub that sleeps cannot
    # produce a real timeout and passing `request_timeout:` here would be inert.
    # `Req.Test.transport_error/2` is the only mechanism that produces the
    # exception this clause converts. Half B — that `opts[:request_timeout]`
    # actually lands as `:receive_timeout` — is pinned by the
    # `prepare_request/2` test above, which binds `embed/2` too because both
    # share `build_request/2`.
    test "a transport timeout converts to %EmbeddingAdapterError{reason: :timeout}", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %EmbeddingAdapterError{reason: :timeout} = err} = call(stub, req())

      assert err.provider == :voyage
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

    test "a non-map error body on a 5xx still classifies by status", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(503, "upstream connect error")
      end)

      assert {:error, %EmbeddingAdapterError{reason: :provider_unavailable}} = call(stub, req())
    end

    test "a 429 is retried and surfaces :rate_limited on exhaustion", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, Fx.embeddings_synthesized(:error_429), [{"retry-after", "0"}])
      end)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               call(stub, req(),
                 retry: [retry_on: [:rate_limited], max_attempts: 2, base_delay_ms: 0, jitter_ms: 0]
               )
    end
  end
end
