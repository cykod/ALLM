defmodule ALLM.Providers.Gemini.EmbeddingsTest do
  @moduledoc """
  Request-shape, gate, normalization, and error-mapping tests for
  `ALLM.Providers.Gemini.Embeddings`, driven through the module's
  `@doc false` + `@spec` test seams and through `Req.Test` stubs.

  The wire-fixture decode assertions live in `embeddings_wire_test.exs`; the
  10-case behaviour suite lives in `embeddings_conformance_test.exs`.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.{AdapterError, EmbeddingAdapterError}
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.Gemini.Embeddings
  alias ALLM.Providers.GeminiTestFixtures, as: Fx

  # All four `iex>` examples on the module are hermetic — two drive
  # `adapter_opts[:embedding_script]` and the empty-input gate, and
  # `prepare_request/2` passes a literal `api_key:`. Wiring the doctest is what
  # stops them rotting (they shipped decorative on the OpenAI adapter until the
  # 20.4 fix step).
  doctest Embeddings

  # Same defect one directory over: 20.5 added `embeddings_recorded/1` and
  # `embeddings_synthesized/1` to the loader with `iex>` examples that no test
  # file declared a doctest for, so they read as tests and ran as comments.
  # Wiring it here is not free-riding — `length(body["embeddings"]) == 3` is
  # exactly the "MUST record exactly THREE inputs" property that
  # `scripts/record_gemini_embeddings_fixtures.exs` declares load-bearing for
  # behaviour invariant 8, so this is a second guard on fixture cardinality in a
  # different file from the one that already asserts it.
  doctest Fx

  @model "gemini-embedding-001"

  setup do
    {:ok, stub: String.to_atom("gemini_embeddings_stub_#{System.unique_integer([:positive])}")}
  end

  defp req(opts \\ []) do
    EmbeddingRequest.new(Keyword.merge([input: ["a kestrel"], model: @model], opts))
  end

  defp call(stub, request, opts \\ []) do
    adapter_opts = opts |> Keyword.get(:adapter_opts, []) |> Keyword.put(:plug, {Req.Test, stub})

    Embeddings.embed(
      request,
      opts
      |> Keyword.merge(api_key: "AIza-embeddings-test", retry: false)
      |> Keyword.put(:adapter_opts, adapter_opts)
    )
  end

  defp body!(request, opts \\ []) do
    assert {:ok, body} = Embeddings.to_batch_body(request, opts)
    body
  end

  defp sub_requests(request, opts \\ []), do: body!(request, opts)["requests"]

  # ---------------------------------------------------------------------------
  # max_batch_size/0
  # ---------------------------------------------------------------------------

  describe "max_batch_size/0" do
    test "returns 100" do
      assert Embeddings.max_batch_size() == 100
    end
  end

  # ---------------------------------------------------------------------------
  # to_batch_body/2
  # ---------------------------------------------------------------------------

  describe "to_batch_body/2" do
    test "emits one sub-request per input, in input order" do
      subs = sub_requests(req(input: ["one", "two", "three"]))

      assert length(subs) == 3

      assert Enum.map(subs, &get_in(&1, ["content", "parts"])) == [
               [%{"text" => "one"}],
               [%{"text" => "two"}],
               [%{"text" => "three"}]
             ]
    end

    # The highest-risk wire divergence in the phase: a sub-request without
    # `model` is a 400 ("BatchEmbedContentsRequest.requests[0].model: model is
    # not specified", observed live 2026-07-29).
    test ~s(sets "model" on EVERY sub-request, prefixed "models/") do
      subs = sub_requests(req(input: ["a", "b", "c"]))

      assert Enum.map(subs, & &1["model"]) == List.duplicate("models/#{@model}", 3)
    end

    test ~s(does not double-prefix a model already carrying "models/") do
      subs = sub_requests(req(model: "models/#{@model}"))

      assert Enum.map(subs, & &1["model"]) == ["models/#{@model}"]
    end

    @task_type_rows [
      {:search_document, "RETRIEVAL_DOCUMENT"},
      {:search_query, "RETRIEVAL_QUERY"},
      {:classification, "CLASSIFICATION"},
      {:clustering, "CLUSTERING"},
      {:similarity, "SEMANTIC_SIMILARITY"}
    ]

    for {atom, wire} <- @task_type_rows do
      test "maps task_type #{atom} to #{wire}" do
        subs = sub_requests(req(task_type: unquote(atom)))
        assert Enum.map(subs, & &1["taskType"]) == [unquote(wire)]
      end
    end

    test "omits taskType when nil" do
      refute Map.has_key?(hd(sub_requests(req())), "taskType")
    end

    test "emits outputDimensionality (camelCase) on every sub-request when :dimensions is set" do
      subs = sub_requests(req(input: ["a", "b"], dimensions: 768))

      assert Enum.map(subs, & &1["outputDimensionality"]) == [768, 768]
      refute Enum.any?(subs, &Map.has_key?(&1, "output_dimensionality"))
      refute Enum.any?(subs, &Map.has_key?(&1, "dimensions"))
    end

    test "omits outputDimensionality when :dimensions is nil" do
      refute Map.has_key?(hd(sub_requests(req())), "outputDimensionality")
    end

    # Placement resolved by the live probe in
    # `scripts/record_gemini_embeddings_fixtures.exs` on 2026-07-29: the
    # nested form is accepted (200) while both flat forms AND an unknown-field
    # control are rejected (400). The control is what makes the 200 evidence of
    # schema membership rather than of unknown-field tolerance.
    test "omits autoTruncate entirely when truncate: true (the provider default)" do
      sub = hd(sub_requests(req(truncate: true)))

      refute Map.has_key?(sub, "embedContentConfig")
      refute Map.has_key?(sub, "autoTruncate")
    end

    test "emits embedContentConfig.autoTruncate == false per sub-request when truncate: false" do
      subs = sub_requests(req(input: ["a", "b"], truncate: false))

      assert Enum.map(subs, & &1["embedContentConfig"]) == [
               %{"autoTruncate" => false},
               %{"autoTruncate" => false}
             ]

      # Both rejected placements, pinned negatively so a future edit that
      # "simplifies" the nesting fails here rather than in production.
      refute Enum.any?(subs, &Map.has_key?(&1, "autoTruncate"))
      refute Map.has_key?(body!(req(truncate: false)), "autoTruncate")
    end

    test "the body carries only the `requests` key" do
      assert Map.keys(body!(req())) == ["requests"]
    end

    test "with request.model == nil returns :invalid_request" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               Embeddings.to_batch_body(req(model: nil), [])

      assert err.metadata.field == :model
      assert err.provider == :gemini
    end

    test "with a non-binary request.model returns :invalid_request" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.to_batch_body(%EmbeddingRequest{input: ["x"], model: :nope}, [])
    end

    # `gate_batch_size/2` catches this ahead of `to_batch_body/2` on both the
    # `embed/2` and `prepare_request/2` paths, so the clause is reachable only
    # by a direct seam call — which is exactly what this test makes. Without it
    # the clause was dead in production AND uncovered in test, which is how a
    # defensive clause silently stops defending.
    test "with a non-list :input returns :invalid_request on a direct seam call" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               Embeddings.to_batch_body(%EmbeddingRequest{input: "x", model: @model}, [])

      assert err.metadata.field == :input
    end

    # The gate and the seam clause construct the same rejection from a shared
    # `@input_shape_message`, so this pins that they cannot drift into two
    # different texts for one condition.
    test "the seam clause and the pre-flight gate report the identical rejection" do
      {:error, seam} = Embeddings.to_batch_body(%EmbeddingRequest{input: "x", model: @model}, [])
      {:error, gate} = Embeddings.embed(%EmbeddingRequest{input: "x", model: @model}, [])

      assert seam.message == gate.message
      assert seam.metadata == gate.metadata
      assert seam.reason == gate.reason
    end
  end

  # ---------------------------------------------------------------------------
  # to_gemini_task_type/1
  # ---------------------------------------------------------------------------

  describe "to_gemini_task_type/1" do
    for {atom, wire} <- @task_type_rows do
      test "#{atom} -> #{wire}" do
        assert Embeddings.to_gemini_task_type(unquote(atom)) == unquote(wire)
      end
    end

    test "nil omits" do
      assert Embeddings.to_gemini_task_type(nil) == nil
    end

    # `ALLM.Serializer.to_atom_field/1` is `String.to_existing_atom/1`, so a
    # decoded `:task_type` is NOT guaranteed enum-legal — `"erlang"` decodes to
    # `:erlang`. An exhaustive mapper falling through to omit is the contract;
    # `Atom.to_string/1` would put arbitrary atoms on the wire.
    test "an atom outside the closed enum omits rather than reaching the wire" do
      assert Embeddings.to_gemini_task_type(:erlang) == nil
      refute Map.has_key?(hd(sub_requests(req(task_type: :erlang))), "taskType")
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

      assert err.provider == :gemini
      refute_received :should_not_be_called
    end

    test "101 inputs returns :batch_too_large before any HTTP I/O", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      inputs = for i <- 1..101, do: "input #{i}"

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large} = err} =
               call(stub, req(input: inputs))

      assert err.metadata.count == 101
      assert err.metadata.max == 100
      refute_received :should_not_be_called
    end

    test "exactly 100 inputs passes the batch gate", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_json(conn, 200, %{
          "embeddings" => for(_ <- 1..100, do: %{"values" => [1.0, 2.0]})
        })
      end)

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               call(stub, req(input: for(i <- 1..100, do: "i#{i}")))

      assert length(embeddings) == 100
    end

    # The nil-model policy: both the URL and every sub-request's required
    # `model` derive from `request.model`, so a direct Layer-B call with
    # `model: nil` cannot build a legal request. Deliberately diverges from
    # `Gemini.Images`' hardcoded-default fallback — a silently-wrong embedding
    # model produces vectors in the wrong space, unrecoverable once written.
    test "model: nil returns :invalid_request before any HTTP I/O", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), :should_not_be_called)
        respond_json(conn, 200, %{})
      end)

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               call(stub, req(model: nil))

      assert err.metadata.field == :model
      refute_received :should_not_be_called
    end

    test "every gate fires ahead of ALLM.Keys.fetch!/2 — no key needed" do
      # No `api_key:` in opts and no stub: reaching key resolution would raise
      # %EngineError{reason: :missing_key}. Each gate must return its tuple
      # first, which is what keeps conformance cases 3 and 4 green in a
      # keyless CI environment.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(input: []), [])

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large}} =
               Embeddings.embed(req(input: for(i <- 1..101, do: "i#{i}")), [])

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(model: nil), [])
    end

    test "gate errors carry opts[:request_id] on metadata" do
      assert {:error, %EmbeddingAdapterError{metadata: %{request_id: "rid-9"}}} =
               Embeddings.embed(req(input: []), request_id: "rid-9")
    end

    # Binding on the whole embeddings family under the same `gate_*/2` prefix:
    # 20.3's `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on
    # any return outside `{:ok, _} | {:error, _}`, so a `FunctionClauseError`
    # here would surface as a batcher bug two layers up.
    test "a non-list :input converts to :invalid_request instead of raising" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               Embeddings.embed(%EmbeddingRequest{input: "a kestrel", model: @model},
                 api_key: "AIza-x"
               )

      assert err.metadata.field == :input
      assert err.message =~ "list"

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(%EmbeddingRequest{input: %{"text" => "x"}}, [])
    end

    # Same invariant as the clause above, one level down: the CONTAINER is a
    # list but an ELEMENT is not a string. Gemini's body builder reaches inside
    # each element (`sub_request/3` puts it under `content.parts[].text`), so
    # before `gate_input/2` existed this raised `Protocol.UndefinedError` out of
    # `to_string/1` — a raise from the one adapter whose comments claim the
    # container shape is explicitly defended for exactly this reason. Maps and
    # tuples are what a JSON-sourced `:input` list actually produces.
    test "a non-string :input ELEMENT converts to :invalid_request instead of raising" do
      for element <- [%{"a" => 1}, {:a, 1}, 42, nil, ["nested"]] do
        assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
                 Embeddings.embed(req(input: ["ok", element]), api_key: "AIza-x"),
               "input element #{inspect(element)} did not convert"

        assert err.metadata.field == :input
        assert err.provider == :gemini
      end
    end

    test "the element gate fires before key resolution, like every other gate" do
      # No `api_key:` and no key in the environment for this call — reaching
      # `Keys.fetch!/2` would raise `%EngineError{reason: :missing_key}`.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.embed(req(input: [%{"a" => 1}]), [])

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(req(input: [%{"a" => 1}]), [])
    end

    test "invariant 10: prepare_request/2 rejects the same requests embed/2 does" do
      for request <- [
            req(input: []),
            req(input: for(i <- 1..101, do: "i#{i}")),
            req(model: nil)
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
      # `model: nil` would trip the model gate on the real path; the
      # short-circuit runs first, so FakeEmbeddings is what answers.
      script = [{:ok, [Embedding.new(vector: [1.0, 2.0])]}]

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: [1.0, 2.0]}]}} =
               Embeddings.embed(req(model: nil), adapter_opts: [embedding_script: script])
    end

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
  # endpoint_url/2 — the one place this adapter diverges from its OpenAI sibling
  # ---------------------------------------------------------------------------

  describe "endpoint_url/2" do
    test "defaults to the v1beta generativelanguage base" do
      assert Embeddings.endpoint_url(req(), []) ==
               "https://generativelanguage.googleapis.com/v1beta/models/#{@model}:batchEmbedContents"
    end

    test "honors adapter_opts[:endpoint]" do
      assert Embeddings.endpoint_url(req(), adapter_opts: [endpoint: "http://localhost:4000/v1"]) ==
               "http://localhost:4000/v1/models/#{@model}:batchEmbedContents"
    end

    test "does not carry the models/ prefix twice when the model already has it" do
      assert Embeddings.endpoint_url(req(model: "models/#{@model}"), []) ==
               "https://generativelanguage.googleapis.com/v1beta/models/#{@model}:batchEmbedContents"
    end

    test "a non-binary adapter_opts[:endpoint] falls back to the default base" do
      assert Embeddings.endpoint_url(req(), adapter_opts: [endpoint: :nope]) =~
               "https://generativelanguage.googleapis.com/v1beta"
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "returns an unfired Req.Request pointed at :batchEmbedContents" do
      assert {:ok, %Req.Request{} = http} =
               Embeddings.prepare_request(req(), api_key: "AIza-prep-test")

      assert URI.to_string(http.url) ==
               "https://generativelanguage.googleapis.com/v1beta/models/#{@model}:batchEmbedContents"

      assert http.method == :post
    end

    # Invariant 3, half B. `Req.Test` runs plugs in-process via
    # `Req.Steps.run_plug`, so `:receive_timeout` is never consulted there and
    # a "stub that sleeps past the timeout" would be inert. This assertion is
    # what binds the plumbing; the conversion half lives in the transport
    # describe block below. `embed/2` is bound too, because both share
    # `build_request/3`.
    test "applies opts[:request_timeout] as :receive_timeout" do
      assert {:ok, http} =
               Embeddings.prepare_request(req(), api_key: "AIza-prep", request_timeout: 1234)

      assert http.options[:receive_timeout] == 1234
    end

    test "carries the x-goog-api-key header, not a ?key= query parameter" do
      assert {:ok, http} = Embeddings.prepare_request(req(), api_key: "AIza-prep-test")

      assert http.headers["x-goog-api-key"] == ["AIza-prep-test"]
      assert URI.to_string(http.url) =~ "batchEmbedContents"
      refute URI.to_string(http.url) =~ "key="
    end

    test "runs the gates and surfaces their errors" do
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               Embeddings.prepare_request(req(input: []), [])
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_normalize/2 — Decision #7
  # ---------------------------------------------------------------------------

  describe "maybe_normalize/2" do
    defp mag(%Embedding{} = e), do: Embedding.magnitude(e)

    setup do
      {:ok, embeddings: [Embedding.new(vector: [3.0, 4.0]), Embedding.new(vector: [0.0, 2.0])]}
    end

    test "nil leaves vectors untouched", %{embeddings: embeddings} do
      assert Embeddings.maybe_normalize(embeddings, nil) == embeddings
    end

    test "3072 leaves vectors untouched", %{embeddings: embeddings} do
      assert Embeddings.maybe_normalize(embeddings, 3072) == embeddings
    end

    test "any other dimensionality normalizes every vector", %{embeddings: embeddings} do
      for dimensions <- [256, 768, 1536, 3071, 3073] do
        assert embeddings
               |> Embeddings.maybe_normalize(dimensions)
               |> Enum.all?(&(abs(mag(&1) - 1.0) < 1.0e-9))
      end
    end

    test "preserves :index while normalizing" do
      embeddings = [Embedding.new(vector: [3.0, 4.0], index: 7)]
      assert [%Embedding{index: 7}] = Embeddings.maybe_normalize(embeddings, 768)
    end

    test "a zero vector is left unchanged rather than producing NaN" do
      embeddings = [Embedding.new(vector: [0.0, 0.0])]
      assert Embeddings.maybe_normalize(embeddings, 768) == embeddings
    end

    # The rule is deliberately model-blind: re-normalizing an already-unit
    # vector is a no-op to within 1.0e-9, so it is safe on the models that
    # self-normalize and correct on the ones that do not, and it does not go
    # stale when Google ships a new model.
    test "is idempotent on an already-unit vector" do
      unit = [Embedding.new(vector: [0.6, 0.8])]
      [normalized] = Embeddings.maybe_normalize(unit, 768)

      assert abs(mag(normalized) - 1.0) < 1.0e-9
    end
  end

  # ---------------------------------------------------------------------------
  # decode_response/4
  # ---------------------------------------------------------------------------

  describe "decode_response/4" do
    test ~s(reads embeddings[].values, not [].embedding) do
      body = %{"embeddings" => [%{"values" => [1.0, 2.0]}]}

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: [1.0, 2.0]}]}} =
               Embeddings.decode_response(body, [], req(), [])

      # OpenAI's key name must NOT be accepted — it would silently decode a
      # foreign envelope.
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(
                 %{"embeddings" => [%{"embedding" => [1.0]}]},
                 [],
                 req(),
                 []
               )
    end

    test "assigns :index by list position" do
      body = %{
        "embeddings" => [%{"values" => [1.0]}, %{"values" => [2.0]}, %{"values" => [3.0]}]
      }

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(body, [], req(input: ["a", "b", "c"]), [])

      assert Enum.map(embeddings, & &1.index) == [0, 1, 2]
      assert Enum.map(embeddings, &hd(&1.vector)) == [1.0, 2.0, 3.0]
    end

    test "maps usageMetadata.promptTokenCount to both input_tokens and total_tokens" do
      body = %{
        "embeddings" => [%{"values" => [1.0]}],
        "usageMetadata" => %{"promptTokenCount" => 11}
      }

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.input_tokens == 11
      assert usage.total_tokens == 11
      assert usage.output_tokens == nil
    end

    # The live `batchEmbedContents` 200 body carries NO `usageMetadata` at all
    # (top-level keys are exactly `["embeddings"]`, verified 2026-07-29), so
    # this is the shape callers actually see today.
    test "usage is an all-nil %ALLM.Usage{} when usageMetadata is absent" do
      body = Fx.embeddings_recorded(:batch_embed_contents)

      assert {:ok, %EmbeddingResponse{usage: %ALLM.Usage{} = usage}} =
               Embeddings.decode_response(body, [], req(input: ["a", "b", "c"]), [])

      refute Map.has_key?(body, "usageMetadata")
      assert usage.input_tokens == nil
      assert usage.total_tokens == nil
      assert usage.output_tokens == nil
    end

    test "a non-integer promptTokenCount is dropped rather than passed through" do
      body = %{
        "embeddings" => [%{"values" => [1.0]}],
        "usageMetadata" => %{"promptTokenCount" => "11"}
      }

      assert {:ok, %EmbeddingResponse{usage: usage}} =
               Embeddings.decode_response(body, [], req(), [])

      assert usage.input_tokens == nil
    end

    test "coerces integer vector components to floats" do
      body = %{"embeddings" => [%{"values" => [0, 1]}]}

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{vector: vector}]}} =
               Embeddings.decode_response(body, [], req(), [])

      assert vector == [0.0, 1.0]
      assert Enum.all?(vector, &is_float/1)
    end

    test ~s(a body missing "embeddings" returns :malformed_response) do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(%{"candidates" => []}, [], req(), [])
    end

    test "a non-map body returns :malformed_response" do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response("<html>502</html>", [], req(), [])
    end

    test ~s(an entry with "values": [] returns :malformed_response) do
      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(%{"embeddings" => [%{"values" => []}]}, [], req(), [])
    end

    test "an entry with a non-numeric component returns :malformed_response" do
      body = %{"embeddings" => [%{"values" => [1.0, "nope"]}]}

      assert {:error, %EmbeddingAdapterError{reason: :malformed_response}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    test "malformed errors never carry a raw body preview" do
      assert {:error, err} =
               Embeddings.decode_response(%{"secret" => "hunter2"}, [], req(), [])

      refute inspect(err) =~ "hunter2"
      assert err.metadata.body_keys == ["secret"]
    end

    test "round-trips request.metadata onto response.metadata UNCHANGED (invariant 7)" do
      metadata = %{trace: "t-1", tenant: 7}
      body = %{"embeddings" => [%{"values" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{metadata: ^metadata}} =
               Embeddings.decode_response(body, [], req(metadata: metadata), [])
    end

    test "preserves opts[:request_id] onto response.request_id (invariant 6)" do
      body = %{"embeddings" => [%{"values" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{request_id: "rid-42"}} =
               Embeddings.decode_response(body, [], req(), request_id: "rid-42")
    end

    # Divergence from the OpenAI sibling, verified rather than assumed:
    # `batchEmbedContents` returns no correlation-id header of any kind
    # (full header list dumped live on 2026-07-29 — `alt-svc`, `content-type`,
    # `date`, `server`, `server-timing`, `transfer-encoding`, `vary`,
    # `x-content-type-options`, `x-frame-options`, `x-xss-protection`).
    # There is therefore nothing to fall back to.
    test "leaves request_id nil when opts[:request_id] is absent" do
      body = %{"embeddings" => [%{"values" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{request_id: nil}} =
               Embeddings.decode_response(body, [{"x-request-id", "ignored"}], req(), [])
    end

    test "takes :model from the request — the body carries none" do
      body = %{"embeddings" => [%{"values" => [1.0]}]}

      assert {:ok, %EmbeddingResponse{model: @model}} =
               Embeddings.decode_response(body, [], req(), [])
    end

    # -------------------------------------------------------------------------
    # REQUIRED: binds ALLM.EmbeddingAdapter invariant 8.
    #
    # The conformance suite drives this adapter through the
    # `adapter_opts[:embedding_script]` short-circuit, so its success path
    # never reaches `decode_response/4` — a decoder that drops entries or
    # mis-indexes them passes all 10 cases. This matters MORE here than on the
    # OpenAI adapter: Gemini carries no index field, so `:index` comes from
    # list position and a dropped sub-response shifts every subsequent index
    # silently rather than producing a gap.
    # -------------------------------------------------------------------------
    test "invariant 8: cardinality and 0..n-1 indices over the live recorded batch" do
      body = Fx.embeddings_recorded(:batch_embed_contents)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} =
               Embeddings.decode_response(body, [], req(input: input), [])

      # These two bind the DECODER: a decoder that drops entries, broadcasts
      # one vector, or mis-orders positions fails them.
      assert length(embeddings) == length(input)
      assert Enum.map(embeddings, & &1.index) == Enum.to_list(0..(length(input) - 1))

      # Positional correspondence is the whole index contract here, so pin the
      # values against the fixture rather than just the count.
      assert Enum.map(embeddings, &hd(&1.vector)) ==
               Enum.map(body["embeddings"], &(&1["values"] |> hd()))

      # Rules out a decoder that broadcasts one vector across every slot.
      assert embeddings |> Enum.map(& &1.vector) |> Enum.uniq() |> length() == length(input)

      # Non-zero vector length IS an adapter guarantee — the decoder rejects
      # `values: []` as :malformed_response (pinned separately above).
      refute Enum.any?(embeddings, &(&1.vector == []))

      # Uniform length across entries is NOT an adapter guarantee: entries are
      # folded independently and there is no cross-entry length comparison, so
      # this asserts a property of THIS fixture. Kept deliberately separate
      # from the clauses above, per the 20.4 correction.
      assert embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # translate_reason/1 — the guard behind behaviour invariant 2
  #
  # This is the block that justifies `translate_reason/1` being a public
  # `@doc false` seam instead of a `defp`. The function narrows the WIDER
  # `ALLM.Error.AdapterError` enum (which `ALLM.Providers.Gemini.classify_error/3`
  # emits, because the chat adapter owns it) down to the embeddings enum. Today's
  # classifier cannot emit a reason outside the narrow set, so the `:unknown`
  # fallback is unreachable through the real classifier — which is precisely why
  # the seam exists, and why a seam with no test collects none of the benefit
  # that paid for the widened surface.
  # ---------------------------------------------------------------------------

  describe "translate_reason/1" do
    @translatable ~w(
      authentication_failed rate_limited invalid_request context_length_exceeded
      provider_unavailable timeout network_error malformed_response unsupported_feature
    )a

    for reason <- @translatable do
      test "#{reason} passes through unchanged" do
        assert Embeddings.translate_reason(unquote(reason)) == unquote(reason)
      end
    end

    # Both are real `AdapterError` reasons with no embeddings meaning. Without
    # the narrowing these reach `EmbeddingAdapterError.new/2` and raise, which
    # is an invariant-2 violation from inside the error constructor itself.
    test "a legal AdapterError reason outside the embeddings enum collapses to :unknown" do
      assert :content_filter in AdapterError.legal_reasons()
      assert :no_scripted_response in AdapterError.legal_reasons()

      assert Embeddings.translate_reason(:content_filter) == :unknown
      assert Embeddings.translate_reason(:no_scripted_response) == :unknown
    end

    test "an unrecognised atom collapses to :unknown rather than raising" do
      assert Embeddings.translate_reason(:some_future_reason) == :unknown
    end

    # The narrowing is load-bearing, not decorative: show that the unnarrowed
    # reason genuinely raises out of the constructor this function feeds.
    test "the narrowing is what prevents an ArgumentError out of the constructor" do
      assert_raise ArgumentError, fn ->
        EmbeddingAdapterError.new(:content_filter, provider: :gemini)
      end

      assert %EmbeddingAdapterError{reason: :unknown} =
               EmbeddingAdapterError.new(Embeddings.translate_reason(:content_filter),
                 provider: :gemini
               )
    end

    # THE load-bearing assertion. The property that actually prevents the
    # `ArgumentError` is `@translatable_reasons ⊆ EmbeddingAdapterError.legal_reasons/0`.
    # Adding `:content_filter` to `@translatable_reasons` is a plausible future
    # edit — it IS a legal `AdapterError` reason — and would break invariant 2
    # with an otherwise-green suite. This pins the subset across every future
    # edit to EITHER enum, which no per-reason table test can do.
    test "every AdapterError reason translates into a legal EmbeddingAdapterError reason" do
      legal = EmbeddingAdapterError.legal_reasons()

      for reason <- AdapterError.legal_reasons() do
        translated = Embeddings.translate_reason(reason)

        assert translated in legal,
               "translate_reason(#{inspect(reason)}) returned #{inspect(translated)}, " <>
                 "which is not a legal EmbeddingAdapterError reason — " <>
                 "EmbeddingAdapterError.new/2 will raise ArgumentError on it, " <>
                 "violating ALLM.EmbeddingAdapter invariant 2"
      end
    end

    # The subset property above is only meaningful if the two enums genuinely
    # differ; if `AdapterError`'s enum were a subset of the embeddings one, the
    # narrowing would be a no-op and the test above would pass vacuously.
    test "the two enums genuinely differ, so the narrowing is not a no-op" do
      wider = AdapterError.legal_reasons()
      narrower = EmbeddingAdapterError.legal_reasons()

      refute Enum.all?(wider, &(&1 in narrower)),
             "AdapterError's enum no longer exceeds EmbeddingAdapterError's — " <>
               "translate_reason/1 would be dead code and this block vacuous"
    end
  end

  # ---------------------------------------------------------------------------
  # to_embedding_adapter_error/4 — delegates to Gemini.classify_error/3
  # ---------------------------------------------------------------------------

  describe "to_embedding_adapter_error/4" do
    @status_rows [
      {401, :authentication_failed},
      {403, :authentication_failed},
      {400, :invalid_request},
      {404, :invalid_request},
      {500, :provider_unavailable},
      {503, :provider_unavailable},
      {418, :unknown}
    ]

    for {status, reason} <- @status_rows do
      test "#{status} maps to #{reason}" do
        err = Embeddings.to_embedding_adapter_error(unquote(status), %{}, [], [])

        assert err.reason == unquote(reason)
        assert err.status == unquote(status)
        assert err.provider == :gemini
      end
    end

    test "429 maps to :rate_limited and reads retry_after_ms from the header" do
      err = Embeddings.to_embedding_adapter_error(429, %{}, [{"retry-after", "7"}], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == 7_000
    end

    test "delegates the reason table to ALLM.Providers.Gemini.classify_error/3" do
      # Same status, same body, same headers — the two classifiers must agree
      # on `reason`. This is what keeps the table from being duplicated: if
      # someone forks it, this test fails.
      body = %{"error" => %{"message" => "nope", "status" => "PERMISSION_DENIED"}}

      for status <- [400, 401, 403, 404, 429, 500, 503] do
        chat = Gemini.classify_error(status, body, [])
        embedding = Embeddings.to_embedding_adapter_error(status, body, [], [])

        assert embedding.reason == chat.reason
        assert embedding.status == chat.status
      end
    end

    test "carries google_status and the status onto metadata" do
      body = %{"error" => %{"message" => "boom", "status" => "INVALID_ARGUMENT"}}
      err = Embeddings.to_embedding_adapter_error(400, body, [], request_id: "rid-1")

      assert err.metadata.google_status == "INVALID_ARGUMENT"
      assert err.metadata.status == 400
      assert err.metadata.request_id == "rid-1"
      assert err.message == "boom"
    end

    test "never captures the raw response body into :cause or :metadata" do
      body = Fx.embeddings_synthesized(:error_400)
      err = Embeddings.to_embedding_adapter_error(400, body, [], [])

      assert err.cause == nil
      refute Map.has_key?(err.metadata, :body_preview)
      assert err.metadata |> Map.keys() |> Enum.sort() == [:google_status, :status]
    end

    # The 20.4 redactor matches `sk-`/`rk-`/`org-` and catches NOTHING for
    # Gemini. Inheriting it verbatim would be a redactor that redacts nothing.
    test "redacts Gemini-shaped key material out of the provider message" do
      body = Fx.embeddings_synthesized(:error_400)
      err = Embeddings.to_embedding_adapter_error(400, body, [], [])

      key = "AIzaSyFAKEKEY000111222333444555666777"
      assert body["error"]["message"] =~ key, "fixture must carry a key-shaped string"

      refute inspect(err) =~ key
      refute Jason.encode!(err) =~ key
      assert err.message =~ "[REDACTED]"
    end

    test "redacts an OAuth-shaped bearer token too" do
      body = %{"error" => %{"message" => "bad credential ya29.a0AfB_byABCDEF123456"}}
      err = Embeddings.to_embedding_adapter_error(401, body, [], [])

      refute err.message =~ "ya29.a0AfB_byABCDEF123456"
      assert err.message =~ "[REDACTED]"
    end

    test "a non-binary provider message is replaced, not interpolated" do
      err = Embeddings.to_embedding_adapter_error(400, %{"error" => %{"message" => 123}}, [], [])

      assert err.reason == :invalid_request
      assert is_binary(err.message)
      refute err.message =~ "123"
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
    # be inert. Half B — that `opts[:request_timeout]` lands as
    # `:receive_timeout` — is pinned by the `prepare_request/2` test above,
    # which binds `embed/2` too because both share `build_request/3`.
    test "a transport timeout converts to %EmbeddingAdapterError{reason: :timeout}", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %EmbeddingAdapterError{reason: :timeout} = err} = call(stub, req())

      assert err.provider == :gemini
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
