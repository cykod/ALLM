defmodule ALLM.Providers.Voyage.EmbeddingsWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.Voyage.Embeddings` — seven fixtures
  driven end-to-end through `embed/2` behind a `Req.Test` stub.

  Five live under `test/fixtures/voyage/embeddings/recorded/` and two under
  `.../synthesized/`.

  **Provenance.** The two `synthesized/` fixtures are hand-written and each
  carries a leading `_comment` marker naming the originating phase, stripped by
  the loader before the body reaches the adapter. The five `recorded/` fixtures
  are **genuine live Voyage responses** — three 200 bodies (`voyage-3.5-lite`,
  1024 / 1024 / 512 components, real token counts) and two 400 error envelopes
  captured by the wire probe's CONTROL and context-length arms — and carry no
  marker, which is precisely what
  `scripts/record_voyage_embeddings_fixtures.exs` keys its refuse-to-overwrite
  check on. Both halves are gated below by tests that read the raw file bytes,
  because `embeddings_recorded/1` and `embeddings_synthesized/1` both strip the
  marker and an assertion made through the loader cannot bind provenance.

  **Which fixture asserts what.** Claims about the *provider's* envelope — the
  `{"detail": "..."}` shape, the status→reason mapping, the context-window
  discriminator — are asserted against the recorded 400s, because only a
  recorded response can falsify them. The synthesized 401 exists solely so the
  key redactor has a `pa-`-shaped target; that string is planted by hand
  (Voyage's real 401 text does not echo the key back) and therefore cannot come
  from a recording.

  Assertions are written against each fixture's OWN dimensionality rather than a
  hard-coded literal, so a re-record at a different width costs zero test edits.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.Voyage.Embeddings
  alias ALLM.Providers.VoyageTestFixtures, as: Fx

  @fixtures_root "test/fixtures/voyage/embeddings"
  @model "voyage-3.5-lite"

  setup do
    {:ok, stub: String.to_atom("voyage_embeddings_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(input, opts \\ []) do
    EmbeddingRequest.new(Keyword.merge([input: input, model: @model], opts))
  end

  defp call(stub, request, opts \\ []) do
    Embeddings.embed(
      request,
      Keyword.merge(
        [api_key: "pa-wire-test", retry: false, adapter_opts: [plug: {Req.Test, stub}]],
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
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @synthesized ~w(error_401 error_429)
    @recorded ~w(
      single_input batch_input reduced_dimensions
      error_400_unknown_field error_400_context_length
    )

    defp raw_fixture(kind, name) do
      [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw_fixture("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 20.6)"
      end
    end

    # The falsifier. Everything else in this file reads through
    # `embeddings_recorded/1`, which strips `_comment` — so a `refute` made
    # there passes whether the file on disk is a live recording or a
    # hand-written placeholder. Reading the raw bytes is the only way the suite
    # can tell the difference, and without it a directory of placeholders
    # labelled `recorded/` ships fully green.
    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw_fixture("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`set -a; . ./.env; set +a; mix run scripts/record_voyage_embeddings_fixtures.exs`"
      end
    end

    test "the loader strips the marker before the body reaches the adapter" do
      assert Map.has_key?(raw_fixture("synthesized", "error_401"), "_comment")
      refute Map.has_key?(Fx.embeddings_synthesized(:error_401), "_comment")
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/single_input.json
  # ---------------------------------------------------------------------------

  describe "recorded/single_input.json" do
    test "decodes to one embedding of the fixture's dimensionality", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:single_input)
      stub_body(stub, 200, fixture)

      assert {:ok, %EmbeddingResponse{} = resp} = call(stub, req(["a kestrel"]))

      assert [%Embedding{index: 0, vector: vector}] = resp.embeddings
      assert length(vector) == dimension_of(fixture)
      assert EmbeddingResponse.dimensions(resp) == dimension_of(fixture)
      assert Enum.all?(vector, &is_float/1)
      assert resp.model == @model
    end

    # PREMISE GUARD for the test below, and for the whole `Usage` mapping of
    # this adapter. `build_usage/1` (`embeddings.ex`) hardcodes
    # `input_tokens: nil` and reads exactly one wire key, so the assertion
    # `usage.input_tokens == nil` goes VACUOUS the moment Voyage starts
    # reporting a second counter: the new field is silently dropped and the
    # suite stays green. This guard asserts the property of the INPUT that
    # makes the assertion below non-trivial — the recorded 200 bodies carry
    # exactly `["total_tokens"]` — so a re-record after a provider schema
    # change fails here, loudly, naming what to do.
    test "premise: every recorded 200 body's usage object carries exactly total_tokens" do
      for name <- [:single_input, :batch_input, :reduced_dimensions] do
        keys = name |> Fx.embeddings_recorded() |> Map.fetch!("usage") |> Map.keys() |> Enum.sort()

        assert keys == ["total_tokens"],
               "recorded/#{name}.json now reports usage keys #{inspect(keys)}. " <>
                 "build_usage/1 maps total_tokens only and hardcodes " <>
                 "input_tokens: nil, so the new counter is silently dropped — " <>
                 "extend the mapping, the moduledoc wire-field map, and the " <>
                 "`usage.input_tokens == nil` assertion below."
      end
    end

    # The phase's success criterion, driven end-to-end rather than through the
    # decoder seam: Voyage reports `usage.total_tokens` and nothing else.
    # Non-vacuous only while the premise guard above holds.
    test "usage carries total_tokens with input_tokens nil", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:single_input)
      stub_body(stub, 200, fixture)

      assert {:ok, %EmbeddingResponse{usage: usage}} = call(stub, req(["a kestrel"]))

      assert usage.total_tokens == fixture["usage"]["total_tokens"]
      assert usage.input_tokens == nil
      assert usage.output_tokens == nil
    end

    test "sends `input` as an array even for a single string", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:single_input))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"]))
      assert_received {:body, %{"input" => ["a kestrel"], "model" => @model}}
    end

    test "posts to /v1/embeddings with a Bearer authorization header", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), {:conn, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
        respond_json(conn, 200, Fx.embeddings_recorded(:single_input))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"]))
      assert_received {:conn, "/v1/embeddings", ["Bearer pa-wire-test"]}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/batch_input.json
  # ---------------------------------------------------------------------------

  describe "recorded/batch_input.json" do
    test "decodes to N embeddings in index order", %{stub: stub} do
      fixture = Fx.embeddings_recorded(:batch_input)
      stub_body(stub, 200, fixture)
      input = ["chunk one", "chunk two", "chunk three"]

      assert {:ok, %EmbeddingResponse{} = resp} = call(stub, req(input))

      assert length(resp.embeddings) == length(input)
      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]

      assert resp.embeddings |> Enum.map(&length(&1.vector)) |> Enum.uniq() ==
               [dimension_of(fixture)]

      assert length(EmbeddingResponse.vectors(resp)) == length(input)
    end

    # Voyage's live `data[]` entries carry `object` and a `text` field (always
    # null on the responses observed) alongside `embedding` and `index`. Pinned
    # so the decoder's indifference to extra entry keys is a recorded property
    # rather than an assumption.
    test "the recorded entries carry keys the decoder deliberately ignores" do
      entry = Fx.embeddings_recorded(:batch_input)["data"] |> hd()

      assert entry |> Map.keys() |> Enum.sort() == ["embedding", "index", "object", "text"]
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/reduced_dimensions.json — the wire probe's `output_dimension` arm.
  # Its 200 body was already paid for by the probe that established the field is
  # a recognised schema member, so it is recorded rather than discarded.
  # ---------------------------------------------------------------------------

  describe "recorded/reduced_dimensions.json" do
    test "decodes to vectors of the reduced length", %{stub: stub} do
      reduced = Fx.embeddings_recorded(:reduced_dimensions)
      full = Fx.embeddings_recorded(:single_input)
      stub_body(stub, 200, reduced)

      assert {:ok, resp} = call(stub, req(["a kestrel"], dimensions: dimension_of(reduced)))

      assert EmbeddingResponse.dimensions(resp) == dimension_of(reduced)
      # A relation, never a literal — a re-record at a different width costs
      # zero test edits.
      assert dimension_of(reduced) < dimension_of(full)
    end

    test "sends output_dimension on the wire, snake_cased", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], dimensions: 512))

      assert_received {:body, body}
      assert body["output_dimension"] == 512
      refute Map.has_key?(body, "dimensions")
      refute Map.has_key?(body, "outputDimensionality")
    end

    test "sends input_type on the wire when :task_type is set", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], task_type: :search_query))
      assert_received {:body, %{"input_type" => "query"}}
    end

    test "sends truncation only when truncate: false", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, Fx.embeddings_recorded(:reduced_dimensions))
      end)

      assert {:ok, _} = call(stub, req(["a kestrel"], truncate: false))
      assert_received {:body, %{"truncation" => false}}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/error_400_unknown_field.json — one of the tree's two GENUINE Voyage
  # error envelopes. Written by the CONTROL arm of the wire probe in
  # `scripts/record_voyage_embeddings_fixtures.exs`, which sends an invented
  # `totallyNotAField` key and keeps the 400 body it already paid for.
  #
  # The envelope SHAPE and the status→reason mapping are asserted here rather
  # than against a synthesized fixture, because those are claims about the
  # PROVIDER'S wire and only a recorded response can falsify them.
  # ---------------------------------------------------------------------------

  describe "recorded/error_400_unknown_field.json" do
    # The whole basis for the probe's conclusions: Voyage rejects unknown
    # arguments, which is what turns the accepting arms' 200s into evidence of
    # schema membership rather than of unknown-field tolerance.
    test "is a real rejection of an invented argument" do
      body = Fx.embeddings_recorded(:error_400_unknown_field)

      # FastAPI-shaped: one top-level string, no nested `error` object. Copying
      # either sibling's `body["error"]["message"]` read would silently produce
      # a generic message on every real Voyage error.
      assert Map.keys(body) == ["detail"]
      assert is_binary(body["detail"])
      assert body["detail"] =~ "totallyNotAField"
      assert body["detail"] =~ "not supported"
    end

    test "maps to :invalid_request and carries the provider's own text", %{stub: stub} do
      stub_body(stub, 400, Fx.embeddings_recorded(:error_400_unknown_field))

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request} = err} =
               call(stub, req(["a"]))

      assert err.status == 400
      assert err.provider == :voyage
      # Redaction is a no-op on it — there is no credential material in a real
      # unknown-argument 400.
      assert err.message =~ "totallyNotAField"
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/error_400_context_length.json — the other genuine envelope, from
  # the probe's over-length arm (an input past the model's context window sent
  # with `truncation: false`, which Voyage rejects rather than truncating).
  # ---------------------------------------------------------------------------

  describe "recorded/error_400_context_length.json" do
    test "names the context window, which is the only discriminator available" do
      detail = Fx.embeddings_recorded(:error_400_context_length)["detail"]

      # Voyage carries no structured error code, so this prose IS the
      # classifier's input. Pinning it here means a wording change shows up as
      # a failing test against a recorded artifact rather than as a silent
      # downgrade to :invalid_request in production.
      assert detail =~ "context window"
      assert detail =~ "too many tokens"
    end

    test "maps to :context_length_exceeded", %{stub: stub} do
      stub_body(stub, 400, Fx.embeddings_recorded(:error_400_context_length))

      assert {:error, %EmbeddingAdapterError{reason: :context_length_exceeded} = err} =
               call(stub, req(["a very long chunk"], truncate: false))

      assert err.status == 400
      assert err.provider == :voyage
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized error fixtures
  # ---------------------------------------------------------------------------

  describe "synthesized error fixtures" do
    test "error_401.json maps to :authentication_failed", %{stub: stub} do
      stub_body(stub, 401, Fx.embeddings_synthesized(:error_401))

      assert {:error, %EmbeddingAdapterError{reason: :authentication_failed} = err} =
               call(stub, req(["a"]))

      assert err.status == 401
      assert err.provider == :voyage
    end

    test "error_401.json's planted key-shaped string never reaches the error struct", %{
      stub: stub
    } do
      stub_body(stub, 401, Fx.embeddings_synthesized(:error_401))

      assert {:error, err} = call(stub, req(["a"]))

      refute inspect(err) =~ "pa-FAKEKEY000111222333444555666777888999aaabb"
      refute Jason.encode!(err) =~ "pa-FAKEKEY000111222333444555666777888999aaabb"
    end

    test "error_429.json maps to :rate_limited with retry_after_ms", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, Fx.embeddings_synthesized(:error_429), [{"retry-after", "7"}])
      end)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited} = err} = call(stub, req(["a"]))

      assert err.status == 429
      assert err.retry_after_ms == 7_000
    end
  end
end
