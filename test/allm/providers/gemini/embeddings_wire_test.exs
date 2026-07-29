defmodule ALLM.Providers.Gemini.EmbeddingsWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.Gemini.Embeddings` — five fixtures
  driven end-to-end through `embed/2` behind a `Req.Test` stub.

  Three live under `test/fixtures/gemini/embeddings/recorded/` and two under
  `.../synthesized/`.

  **Provenance.** The two `synthesized/` fixtures are hand-written and each
  carries a leading `_comment` marker naming the originating phase, stripped by
  the loader before the body reaches the adapter. The three `recorded/`
  fixtures are **genuine live `batchEmbedContents` responses** — two 200 bodies
  (`gemini-embedding-001`, 768 / 256 components) and one 400 error envelope
  captured by the placement probe's CONTROL arm — and carry no marker, which is
  precisely what `scripts/record_gemini_embeddings_fixtures.exs` keys its
  refuse-to-overwrite check on. Both halves are gated below by tests that read
  the raw file bytes, because `embeddings_recorded/1` and
  `embeddings_synthesized/1` both strip the marker and an assertion made
  through the loader cannot bind provenance.

  **Which fixture asserts what.** Claims about the *provider's* envelope — the
  status→reason mapping, `google_status` forwarding, the `details[]` shape —
  are asserted against the recorded 400, because only a recorded response can
  falsify them. The synthesized 400 exists solely so the key redactor has a
  key-shaped target; that string is planted by hand and therefore cannot come
  from a recording.

  Assertions are written against each fixture's OWN dimensionality rather than
  a hard-coded literal, so a re-record at a different width costs zero test
  edits.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.Gemini.Embeddings
  alias ALLM.Providers.GeminiTestFixtures, as: Fx

  @fixtures_root "test/fixtures/gemini/embeddings"
  @model "gemini-embedding-001"

  setup do
    {:ok, stub: String.to_atom("gemini_embeddings_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(input, opts \\ []) do
    EmbeddingRequest.new(Keyword.merge([input: input, model: @model], opts))
  end

  defp call(stub, request, opts \\ []) do
    Embeddings.embed(
      request,
      Keyword.merge(
        [api_key: "AIza-wire-test", retry: false, adapter_opts: [plug: {Req.Test, stub}]],
        opts
      )
    )
  end

  defp stub_body(stub, status, body) do
    Req.Test.stub(stub, fn conn -> respond_json(conn, status, body) end)
  end

  defp dimension_of(fixture) do
    fixture["embeddings"] |> hd() |> Map.get("values") |> length()
  end

  defp magnitude(values) do
    values |> Enum.reduce(0.0, fn v, acc -> v * v + acc end) |> :math.sqrt()
  end

  # ---------------------------------------------------------------------------
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @synthesized ~w(error_400 error_429)
    @recorded ~w(batch_embed_contents reduced_dimensions error_400_unknown_field)

    defp raw_fixture(kind, name) do
      [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw_fixture("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 20.5)"
      end
    end

    # The falsifier. Everything else in this file reads through
    # `embeddings_recorded/1`, which strips `_comment` — so a `refute` made
    # there passes whether the file on disk is a live recording or a
    # hand-written placeholder. Reading the raw bytes is the only way the
    # suite can tell the difference.
    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw_fixture("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`set -a; . ./.env; set +a; mix run scripts/record_gemini_embeddings_fixtures.exs`"
      end
    end

    test "the loader strips the marker before the body reaches the adapter" do
      assert Map.has_key?(raw_fixture("synthesized", "error_400"), "_comment")
      refute Map.has_key?(Fx.embeddings_synthesized(:error_400), "_comment")
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/batch_embed_contents.json
  # ---------------------------------------------------------------------------

  describe "recorded/batch_embed_contents.json" do
    test "decodes to N embeddings indexed by list position", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:batch_embed_contents)
      stub_body(stub, 200, fixture)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{} = resp} = call(stub, req(input))

      assert length(resp.embeddings) == length(input)
      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]

      assert resp.embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() ==
               [dimension_of(fixture)]

      assert EmbeddingResponse.dimensions(resp) == dimension_of(fixture)
      assert Enum.all?(hd(resp.embeddings).vector, &is_float/1)
      assert resp.model == @model
    end

    test "posts one sub-request per input to :batchEmbedContents with the API-key header", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          self(),
          {:wire, conn.request_path, Plug.Conn.get_req_header(conn, "x-goog-api-key"),
           Jason.decode!(raw)}
        )

        respond_json(conn, 200, Fx.embeddings_recorded(:batch_embed_contents))
      end)

      assert {:ok, _} = call(stub, req(["chunk one", "chunk two", "chunk three"]))

      assert_received {:wire, path, ["AIza-wire-test"], body}
      assert path == "/v1beta/models/#{@model}:batchEmbedContents"
      assert length(body["requests"]) == 3
      assert Enum.map(body["requests"], & &1["model"]) == List.duplicate("models/#{@model}", 3)

      assert Enum.map(body["requests"], &get_in(&1, ["content", "parts"])) == [
               [%{"text" => "chunk one"}],
               [%{"text" => "chunk two"}],
               [%{"text" => "chunk three"}]
             ]
    end

    # Decision #7, driven off the live fixture. `gemini-embedding-001` does NOT
    # normalize at truncated dimensionalities — measured L2 norms on the
    # recorded 768-wide batch are ~0.585, not 1.0 — which is what makes both
    # halves of this pair falsifiable rather than vacuously true.
    test "the recorded 768-wide vectors are NOT provider-normalized", %{stub: _stub} do
      fixture = Fx.embeddings_recorded(:batch_embed_contents)

      for entry <- fixture["embeddings"] do
        assert abs(magnitude(entry["values"]) - 1.0) > 0.01,
               "fixture is pre-normalized — the normalization tests below would pass vacuously"
      end
    end

    test "dimensions: nil leaves vectors exactly as the fixture recorded them", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:batch_embed_contents)
      stub_body(stub, 200, fixture)

      assert {:ok, resp} = call(stub, req(["a", "b", "c"], dimensions: nil))

      expected = Enum.map(fixture["embeddings"], &Enum.map(&1["values"], fn v -> v * 1.0 end))
      assert EmbeddingResponse.vectors(resp) == expected
    end

    test "dimensions: 3072 leaves vectors untouched", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:batch_embed_contents)
      stub_body(stub, 200, fixture)

      assert {:ok, resp} = call(stub, req(["a", "b", "c"], dimensions: 3072))

      expected = Enum.map(fixture["embeddings"], &Enum.map(&1["values"], fn v -> v * 1.0 end))
      assert EmbeddingResponse.vectors(resp) == expected
    end

    test "dimensions: 768 yields unit-magnitude vectors within 1.0e-9", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:batch_embed_contents)
      stub_body(stub, 200, fixture)

      assert {:ok, resp} = call(stub, req(["a", "b", "c"], dimensions: dimension_of(fixture)))

      for %Embedding{} = embedding <- resp.embeddings do
        assert abs(Embedding.magnitude(embedding) - 1.0) < 1.0e-9
      end

      # Direction is preserved — normalization is a scale, not a reshuffle.
      assert Enum.map(resp.embeddings, &(hd(&1.vector) > 0)) ==
               Enum.map(fixture["embeddings"], &(hd(&1["values"]) > 0))
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/reduced_dimensions.json
  # ---------------------------------------------------------------------------

  describe "recorded/reduced_dimensions.json" do
    test "decodes to vectors of the reduced length", %{stub: stub} do
      reduced = Fx.embeddings_recorded(:reduced_dimensions)
      batch = Fx.embeddings_recorded(:batch_embed_contents)
      stub_body(stub, 200, reduced)

      assert {:ok, resp} = call(stub, req(["a kestrel"], dimensions: dimension_of(reduced)))

      assert EmbeddingResponse.dimensions(resp) == dimension_of(reduced)
      assert dimension_of(reduced) < dimension_of(batch)
    end

    test "sends outputDimensionality on the wire, camelCased", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], dimensions: 256))

      assert_received {:body, %{"requests" => [sub]}}
      assert sub["outputDimensionality"] == 256
      refute Map.has_key?(sub, "output_dimensionality")
    end

    test "sends taskType on the wire when :task_type is set", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], task_type: :search_query))

      assert_received {:body, %{"requests" => [%{"taskType" => "RETRIEVAL_QUERY"}]}}
    end

    # Placement resolved live on 2026-07-29 — see the probe in
    # `scripts/record_gemini_embeddings_fixtures.exs`.
    test "sends embedContentConfig.autoTruncate only when truncate: false", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], truncate: false))
      assert_received {:body, %{"requests" => [sub]}}
      assert sub["embedContentConfig"] == %{"autoTruncate" => false}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/error_400_unknown_field.json — the tree's only GENUINE Gemini
  # error envelope. Written by the CONTROL arm of the placement probe in
  # `scripts/record_gemini_embeddings_fixtures.exs`, which sends an invented
  # `totallyNotAField` key and keeps the 400 body it already paid for.
  #
  # The status→reason mapping and `google_status` forwarding are asserted HERE
  # rather than against `synthesized/error_400.json`, because those are claims
  # about the PROVIDER'S envelope and only a recorded response can falsify them.
  # The synthesized 400 keeps the redaction assertion below: its key-shaped
  # message is deliberately planted, so it cannot be recorded.
  # ---------------------------------------------------------------------------

  describe "recorded/error_400_unknown_field.json" do
    test "carries a real google.rpc error envelope" do
      body = Fx.embeddings_recorded(:error_400_unknown_field)

      assert %{"error" => %{"code" => 400, "status" => "INVALID_ARGUMENT"} = error} = body
      assert is_binary(error["message"])

      # `details[]` is Google-specific structure a future adapter or a
      # `classify_error/3` change could silently start or stop reading. Pinning
      # its presence and `@type` here means the fixture is the witness, not a
      # sentence in a comment.
      assert [%{"@type" => "type.googleapis.com/google.rpc." <> _} | _] = error["details"]
    end

    test "maps to :invalid_request and forwards google_status", %{stub: stub} do
      stub_body(stub, 400, Fx.embeddings_recorded(:error_400_unknown_field))

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               call(stub, req(["a"]))

      assert err.status == 400
      assert err.provider == :gemini
      assert err.metadata.google_status == "INVALID_ARGUMENT"

      # The provider's own text survives classification (redaction is a no-op
      # on it — there is no credential material in a real unknown-field 400).
      assert err.message =~ "Unknown name"
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized error fixtures
  # ---------------------------------------------------------------------------

  describe "synthesized error fixtures" do
    test "error_400.json's key-shaped message never reaches the error struct", %{stub: stub} do
      stub_body(stub, 400, Fx.embeddings_synthesized(:error_400))

      assert {:error, err} = call(stub, req(["a"]))
      refute Jason.encode!(err) =~ "AIzaSyFAKEKEY000111222333444555666777"
    end

    test "error_429.json maps to :rate_limited with retry_after_ms", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, Fx.embeddings_synthesized(:error_429), [{"retry-after", "7"}])
      end)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited} = err} = call(stub, req(["a"]))

      assert err.status == 429
      assert err.retry_after_ms == 7_000
      assert err.metadata.google_status == "RESOURCE_EXHAUSTED"
    end
  end
end
