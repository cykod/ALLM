defmodule ALLM.Providers.OpenAI.EmbeddingsWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.OpenAI.Embeddings` — seven fixtures
  driven end-to-end through `embed/2` behind a `Req.Test` stub.

  Three live under `test/fixtures/openai/embeddings/recorded/` and four under
  `.../synthesized/`.

  **Provenance.** The four `synthesized/` fixtures are hand-written and each
  carries a leading `_comment` marker naming the originating phase, stripped by
  `ALLM.Providers.OpenAITestFixtures.drop_comment/1` before the body reaches
  the adapter. The three `recorded/` fixtures are **genuine live OpenAI
  responses** (`text-embedding-3-small`, 1536 / 1536 / 512 components, real
  token counts) and carry no marker — which is precisely what
  `scripts/record_openai_embeddings_fixtures.exs` keys its refuse-to-overwrite
  check on. Both halves are gated below by tests that read the raw file bytes,
  because `embeddings_recorded/1` and `embeddings_synthesized/1` both call
  `drop_comment/1` and an assertion made through the loader cannot bind
  provenance.

  Assertions are written against each fixture's OWN dimensionality rather
  than a hard-coded literal, which is why swapping the original placeholders
  for the live recordings cost zero test edits.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.OpenAI.Embeddings
  alias ALLM.Providers.OpenAITestFixtures

  @fixtures_root "test/fixtures/openai/embeddings"

  setup do
    {:ok, stub: String.to_atom("openai_embeddings_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(input, opts \\ []) do
    EmbeddingRequest.new(Keyword.merge([input: input, model: "text-embedding-3-small"], opts))
  end

  defp call(stub, request, opts \\ []) do
    Embeddings.embed(
      request,
      Keyword.merge(
        [api_key: "sk-wire-test", retry: false, adapter_opts: [plug: {Req.Test, stub}]],
        opts
      )
    )
  end

  defp stub_body(stub, status, body) do
    Req.Test.stub(stub, fn conn -> respond_json(conn, status, body) end)
  end

  defp dimension_of(fixture) do
    fixture["data"] |> hd() |> Map.get("embedding") |> length()
  end

  # ---------------------------------------------------------------------------
  # Provenance — every synthesized fixture carries its marker
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @synthesized ~w(error_401 error_429 error_400_too_many_tokens shuffled_index_order)
    @recorded ~w(single_input batch_input reduced_dimensions)

    defp raw_fixture(kind, name) do
      [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw_fixture("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 20.4)"
      end
    end

    # The falsifier. Everything else in this file reads through
    # `embeddings_recorded/1`, which calls `drop_comment/1` — so a `refute`
    # made there passes whether the file on disk is a live recording or a
    # hand-written placeholder. Reading the raw bytes is the only way the
    # suite can tell the difference, and without it a directory of
    # placeholders labelled `recorded/` ships fully green.
    #
    # Binding on 20.5 and 20.6: every phase shipping a `recorded/` directory
    # ships one of these per file.
    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw_fixture("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`set -a; . ./.env; set +a; mix run scripts/record_openai_embeddings_fixtures.exs`"
      end
    end

    test "drop_comment/1 strips the marker before the body reaches the adapter" do
      assert Map.has_key?(raw_fixture("synthesized", "error_401"), "_comment")
      refute Map.has_key?(OpenAITestFixtures.embeddings_synthesized(:error_401), "_comment")
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/single_input.json
  # ---------------------------------------------------------------------------

  describe "recorded/single_input.json" do
    test "decodes to one embedding of the fixture's dimensionality", %{stub: stub} do
      fixture = OpenAITestFixtures.embeddings_recorded(:single_input)
      stub_body(stub, 200, fixture)

      assert {:ok, %EmbeddingResponse{} = resp} = call(stub, req(["a kestrel"]))

      assert [%Embedding{index: 0, vector: vector}] = resp.embeddings
      assert length(vector) == dimension_of(fixture)
      assert EmbeddingResponse.dimensions(resp) == dimension_of(fixture)
      assert Enum.all?(vector, &is_float/1)
      assert resp.model == "text-embedding-3-small"
      assert resp.usage.input_tokens == fixture["usage"]["prompt_tokens"]
      assert resp.usage.output_tokens == nil
    end

    test "sends `input` as an array even for a single string", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, OpenAITestFixtures.embeddings_recorded(:single_input))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"]))
      assert_received {:body, %{"input" => ["a kestrel"], "model" => "text-embedding-3-small"}}
    end

    test "posts to /v1/embeddings with a Bearer authorization header", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), {:conn, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
        respond_json(conn, 200, OpenAITestFixtures.embeddings_recorded(:single_input))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"]))
      assert_received {:conn, "/v1/embeddings", ["Bearer sk-wire-test"]}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/batch_input.json
  # ---------------------------------------------------------------------------

  describe "recorded/batch_input.json" do
    test "decodes to N embeddings in index order", %{stub: stub} do
      fixture = OpenAITestFixtures.embeddings_recorded(:batch_input)
      stub_body(stub, 200, fixture)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{} = resp} = call(stub, req(input))

      assert length(resp.embeddings) == length(input)
      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]

      assert resp.embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() ==
               [dimension_of(fixture)]

      assert length(EmbeddingResponse.vectors(resp)) == length(input)
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/reduced_dimensions.json
  # ---------------------------------------------------------------------------

  describe "recorded/reduced_dimensions.json" do
    test "decodes to vectors of the reduced length", %{stub: stub} do
      reduced = OpenAITestFixtures.embeddings_recorded(:reduced_dimensions)
      full = OpenAITestFixtures.embeddings_recorded(:single_input)
      stub_body(stub, 200, reduced)

      assert {:ok, resp} = call(stub, req(["a kestrel"], dimensions: dimension_of(reduced)))

      assert EmbeddingResponse.dimensions(resp) == dimension_of(reduced)
      assert dimension_of(reduced) < dimension_of(full)
    end

    test "sends the `dimensions` field on the wire", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, OpenAITestFixtures.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], dimensions: 4))
      assert_received {:body, %{"dimensions" => 4}}
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/shuffled_index_order.json
  # ---------------------------------------------------------------------------

  describe "synthesized/shuffled_index_order.json" do
    test "a data array out of order decodes to index-sorted embeddings", %{stub: stub} do
      fixture = OpenAITestFixtures.embeddings_synthesized(:shuffled_index_order)
      stub_body(stub, 200, fixture)

      # The fixture's array order is 2, 0, 1 — list position is NOT index.
      assert Enum.map(fixture["data"], & &1["index"]) == [2, 0, 1]

      assert {:ok, resp} = call(stub, req(["a", "b", "c"]))

      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]
      assert Enum.map(EmbeddingResponse.vectors(resp), &hd/1) == [0.0, 0.1, 0.2]
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized error fixtures
  # ---------------------------------------------------------------------------

  describe "synthesized error fixtures" do
    test "error_401.json maps to :authentication_failed", %{stub: stub} do
      stub_body(stub, 401, OpenAITestFixtures.embeddings_synthesized(:error_401))

      assert {:error, %EmbeddingAdapterError{reason: :authentication_failed} = err} =
               call(stub, req(["a"]))

      assert err.status == 401
      assert err.provider == :openai
      assert err.metadata.openai_code == "invalid_api_key"
    end

    test "error_401.json's key-shaped message never reaches the error struct", %{stub: stub} do
      stub_body(stub, 401, OpenAITestFixtures.embeddings_synthesized(:error_401))

      assert {:error, err} = call(stub, req(["a"]))
      refute Jason.encode!(err) =~ "sk-proj-FAKEKEY000111222333444555"
    end

    test "error_429.json maps to :rate_limited with retry_after_ms", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, OpenAITestFixtures.embeddings_synthesized(:error_429), [
          {"retry-after", "7"}
        ])
      end)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited} = err} = call(stub, req(["a"]))

      assert err.status == 429
      assert err.retry_after_ms == 7_000
    end

    test "error_400_too_many_tokens.json maps to :context_length_exceeded", %{stub: stub} do
      fixture = OpenAITestFixtures.embeddings_synthesized(:error_400_too_many_tokens)
      stub_body(stub, 400, fixture)

      # The discriminator lives on `type`; `code` is null.
      assert fixture["error"]["code"] == nil
      assert fixture["error"]["type"] == "max_tokens_per_request"

      assert {:error, %EmbeddingAdapterError{reason: :context_length_exceeded} = err} =
               call(stub, req(["a"]))

      assert err.status == 400
    end
  end
end
