defmodule ALLM.Providers.OpenAI.ModerationWireTest do
  @moduledoc """
  Wire-fixture tests for `ALLM.Providers.OpenAI.Moderation` — nine fixtures
  driven end-to-end through `moderate/2` behind a `Req.Test` stub.

  Five live under `test/fixtures/openai/moderations/recorded/` and four under
  `.../synthesized/`.

  **Provenance.** The four `synthesized/` fixtures are hand-written and each
  carries a leading `_comment` marker naming the originating phase, stripped by
  `ALLM.Providers.OpenAITestFixtures.drop_comment/1` before the body reaches the
  adapter. The five `recorded/` fixtures are **genuine live OpenAI
  `/v1/moderations` responses** (`omni-moderation-latest`) and carry no marker —
  four recorded 2026-08-31 with the text adapter (Phase 22.4) and
  `multimodal_text_image` recorded 2026-09-01 with the image path (Phase 22.5).
  Carrying no marker is precisely what
  `scripts/record_openai_moderation_fixtures.exs` keys its refuse-to-overwrite
  check on. Both halves are gated below by tests that read the raw file bytes,
  because `moderation_recorded/1` and `moderation_synthesized/1` both call
  `drop_comment/1` and an assertion made through the loader cannot bind
  provenance.

  Assertions are written against each fixture's OWN shape (result count, the
  categories it actually reports) rather than hard-coded literals, so a
  re-record costs zero test edits.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3, respond_with: 4]

  alias ALLM.Error.ModerationAdapterError
  alias ALLM.{ModerationRequest, ModerationResponse, ModerationResult}
  alias ALLM.Providers.OpenAI.Moderation
  alias ALLM.Providers.OpenAITestFixtures

  @fixtures_root "test/fixtures/openai/moderations"

  setup do
    {:ok, stub: String.to_atom("openai_moderation_wire_#{System.unique_integer([:positive])}")}
  end

  defp req(input, opts \\ []) do
    ModerationRequest.new(Keyword.merge([input: input, model: "omni-moderation-latest"], opts))
  end

  defp call(stub, request, opts \\ []) do
    Moderation.moderate(
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

  # ---------------------------------------------------------------------------
  # Provenance
  # ---------------------------------------------------------------------------

  describe "fixture provenance" do
    @synthesized ~w(null_illicit_categories missing_applied_input_types error_401 error_429)
    @recorded ~w(single_clean batch_mixed flagged_violence error_400_bad_model multimodal_text_image)

    defp raw_fixture(kind, name) do
      [@fixtures_root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert raw_fixture("synthesized", unquote(name))["_comment"] =~ "Synthesized (Phase 22.4)"
      end
    end

    # The falsifier. Everything else in this file reads through
    # `moderation_recorded/1`, which calls `drop_comment/1` — so a `refute` made
    # there passes whether the file on disk is a live recording or a hand-written
    # placeholder. Reading the raw bytes is the only way the suite can tell the
    # difference, and without it a directory of placeholders labelled `recorded/`
    # ships fully green.
    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(raw_fixture("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run " <>
                 "`set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs`"
      end
    end

    test "drop_comment/1 strips the marker before the body reaches the adapter" do
      assert Map.has_key?(raw_fixture("synthesized", "error_401"), "_comment")
      refute Map.has_key?(OpenAITestFixtures.moderation_synthesized(:error_401), "_comment")
    end

    # `@recorded` and `@synthesized` are hand-maintained literals driving the
    # `for name <- @… do test … end` loops above, so a fixture added to the
    # directory and NOT to the literal gets no provenance test at all — silence,
    # not a failure. Per CLAUDE.md ("A repo-wide audit gate whose subject set is
    # a hand-maintained literal MUST assert that literal against a discovered
    # set"), these two tests make the omission red. Binding on 22.5, which adds
    # `recorded/multimodal_text_image.json`.
    defp on_disk(kind) do
      [@fixtures_root, kind, "*.json"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))
      |> Enum.sort()
    end

    test "@recorded enumerates every file under recorded/" do
      assert on_disk("recorded") == Enum.sort(@recorded),
             "add the new fixture to @recorded, or it ships with no provenance test"
    end

    test "@synthesized enumerates every file under synthesized/" do
      assert on_disk("synthesized") == Enum.sort(@synthesized),
             "add the new fixture to @synthesized, or it ships with no provenance test"
    end
  end

  # ---------------------------------------------------------------------------
  # Request shape
  # ---------------------------------------------------------------------------

  describe "request shape" do
    test "posts to https://api.openai.com/v1/moderations", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), {:conn, conn.host, conn.request_path})
        respond_json(conn, 200, OpenAITestFixtures.moderation_recorded(:single_clean))
      end)

      assert {:ok, _} = call(stub, req(["hi"]))
      assert_received {:conn, "api.openai.com", "/v1/moderations"}
    end

    test "sends Authorization: Bearer <key>", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        send(self(), {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        respond_json(conn, 200, OpenAITestFixtures.moderation_recorded(:single_clean))
      end)

      assert {:ok, _} = call(stub, req(["hi"]))
      assert_received {:auth, ["Bearer sk-wire-test"]}
    end

    test "sends input as an array and model when set", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, OpenAITestFixtures.moderation_recorded(:single_clean))
      end)

      assert {:ok, _} = call(stub, req(["hi"]))
      assert_received {:body, %{"input" => ["hi"], "model" => "omni-moderation-latest"}}
    end
  end

  # ---------------------------------------------------------------------------
  # recorded/
  # ---------------------------------------------------------------------------

  describe "recorded/single_clean.json" do
    test "decodes to flagged: false", %{stub: stub} do
      fixture = OpenAITestFixtures.moderation_recorded(:single_clean)
      stub_body(stub, 200, fixture)

      assert {:ok, %ModerationResponse{} = resp} = call(stub, req(["a kestrel"]))

      assert [%ModerationResult{flagged: false, index: 0} = result] = resp.results
      refute ModerationResponse.flagged?(resp)
      assert ModerationResponse.flagged_categories(resp) == []
      assert map_size(result.categories) == map_size(hd(fixture["results"])["categories"])
      assert Enum.all?(Map.values(result.category_scores), &is_float/1)
      assert resp.provider == :openai
      assert resp.id == fixture["id"]
    end

    # Assumption 6, pinned against a live body: the endpoint returns no usage
    # object, which is why `%ModerationResponse{}` has no `:usage` field. Fires
    # at re-record time; the recorder's own arm fires live.
    test "the recorded body carries no usage object" do
      fixture = OpenAITestFixtures.moderation_recorded(:single_clean)

      refute Map.has_key?(fixture, "usage")
      refute fixture["results"] |> hd() |> Map.has_key?("usage")
    end
  end

  describe "recorded/flagged_violence.json" do
    test ~s(decodes with "violence" in flagged_categories/1), %{stub: stub} do
      fixture = OpenAITestFixtures.moderation_recorded(:flagged_violence)
      stub_body(stub, 200, fixture)

      assert {:ok, %ModerationResponse{} = resp} = call(stub, req(["…"]))

      assert ModerationResponse.flagged?(resp)
      assert "violence" in ModerationResponse.flagged_categories(resp)
      assert [%ModerationResult{flagged: true} = result] = resp.results
      assert result.applied_input_types["violence"] == ["text"]
      assert is_float(ModerationResult.score(result, "violence"))
    end
  end

  describe "recorded/batch_mixed.json" do
    test "decodes to N results in index order", %{stub: stub} do
      fixture = OpenAITestFixtures.moderation_recorded(:batch_mixed)
      n = length(fixture["results"])
      stub_body(stub, 200, fixture)

      assert {:ok, %ModerationResponse{results: results}} =
               call(stub, req(Enum.map(1..n, &"input #{&1}")))

      assert length(results) == n
      assert Enum.map(results, & &1.index) == Enum.to_list(0..(n - 1))

      assert Enum.map(results, & &1.flagged) ==
               Enum.map(fixture["results"], & &1["flagged"])
    end
  end

  describe "recorded/error_400_bad_model.json" do
    test "a recorded 400 decodes to :invalid_request", %{stub: stub} do
      fixture = OpenAITestFixtures.moderation_recorded(:error_400_bad_model)
      stub_body(stub, 400, fixture)

      assert {:error, %ModerationAdapterError{} = err} =
               call(stub, req(["hi"], model: "text-moderation-latest"))

      assert err.reason == :invalid_request
      assert err.status == 400
      assert err.provider == :openai
      assert err.message == fixture["error"]["message"]
    end
  end

  # ---------------------------------------------------------------------------
  # synthesized/
  # ---------------------------------------------------------------------------

  describe "synthesized/null_illicit_categories.json" do
    test "null-valued categories are dropped end-to-end", %{stub: stub} do
      stub_body(stub, 200, OpenAITestFixtures.moderation_synthesized(:null_illicit_categories))

      assert {:ok, %ModerationResponse{results: [result]}} = call(stub, req(["hi"]))

      refute Map.has_key?(result.categories, "illicit")
      assert Enum.all?(Map.values(result.categories), &is_boolean/1)
    end
  end

  describe "synthesized/missing_applied_input_types.json" do
    test "a missing category_applied_input_types decodes to %{}", %{stub: stub} do
      stub_body(stub, 200, OpenAITestFixtures.moderation_synthesized(:missing_applied_input_types))

      assert {:ok, %ModerationResponse{results: [result]}} = call(stub, req(["hi"]))

      assert result.applied_input_types == %{}
      assert result.flagged == true
    end
  end

  describe "synthesized/error_429.json" do
    test "a 429 with Retry-After maps to :rate_limited with retry_after_ms", %{stub: stub} do
      body = OpenAITestFixtures.moderation_synthesized(:error_429)

      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 429, body, [{"retry-after", "7"}])
      end)

      assert {:error, %ModerationAdapterError{reason: :rate_limited} = err} =
               call(stub, req(["hi"]))

      assert err.retry_after_ms == 7_000
    end
  end

  # ---------------------------------------------------------------------------
  # Key-material redaction — synthesized/error_401.json
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @planted_key "sk-proj-FAKEKEY000111222333444555"

    test "redact_key_material/1 replaces an sk- token in a 401 message", %{stub: stub} do
      body = OpenAITestFixtures.moderation_synthesized(:error_401)
      assert body["error"]["message"] =~ @planted_key, "fixture must carry a key-shaped string"

      stub_body(stub, 401, body)

      assert {:error, %ModerationAdapterError{reason: :authentication_failed} = err} =
               call(stub, req(["hi"]))

      # The struct derives Jason.Encoder and downstream apps persist it, so no
      # field of it may carry the key material the provider echoed back.
      refute inspect(err) =~ @planted_key
      refute Jason.encode!(err) =~ @planted_key
      assert err.message =~ "[REDACTED]"
      assert err.cause == nil
      refute Map.has_key?(err.metadata, :body_preview)
    end

    # CLAUDE.md's companion-test rule. Inheriting the OpenAI pattern verbatim is
    # correct HERE — same provider — but "inherited verbatim" is exactly the
    # shape that silently redacts nothing when carried across providers, so the
    # sibling patterns are asserted to miss and the OpenAI one to hit.
    #
    # Note also what the 2026-08-31 live probe found: OpenAI's REAL moderation
    # 401 masks the key (`sk-proj-*****************************9900`), so no
    # provider-authored moderation text in this tree reaches the redactor with
    # key material in it. The planted token is defence in depth, and this
    # fixture is the redactor's only target.
    test "the Gemini and Voyage key patterns match nothing in the same 401 fixture" do
      message = OpenAITestFixtures.moderation_synthesized(:error_401)["error"]["message"]

      refute message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
    end
  end

  # ---------------------------------------------------------------------------
  # Transport failures — invariant 9 and the retry contract
  # ---------------------------------------------------------------------------

  describe "transport failures" do
    test "a timeout converts to :timeout rather than raising", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %ModerationAdapterError{reason: :timeout} = err} =
               call(stub, req(["hi"]), request_timeout: 50)

      assert err.provider == :openai
    end

    test "a connection refusal converts to :network_error", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %ModerationAdapterError{reason: :network_error}} = call(stub, req(["hi"]))
    end

    test "a 200 with an undecodable body is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{not json")
      end)

      assert {:error, %ModerationAdapterError{reason: :malformed_response} = err} =
               call(stub, req(["hi"]))

      # `Jason.DecodeError` carries the whole undecodable payload on `:data`;
      # `sanitize_cause/1` blanks it so the persisted struct cannot smuggle a
      # response body out through `:cause`.
      refute inspect(err) =~ "not json"
    end
  end

  # ---------------------------------------------------------------------------
  # Retry integration
  # ---------------------------------------------------------------------------

  describe "retry integration" do
    defp counting_stub(stub, status, body) do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        respond_json(conn, status, body)
      end)
    end

    test "a 500 is retried under the adapter's own loop and then surfaces", %{stub: stub} do
      counting_stub(stub, 500, %{"error" => %{"message" => "boom"}})

      assert {:error, %ModerationAdapterError{reason: :provider_unavailable}} =
               call(stub, req(["hi"]),
                 retry: [
                   max_attempts: 2,
                   base_delay_ms: 0,
                   jitter_ms: 0,
                   retry_on: [:provider_unavailable]
                 ]
               )

      assert_received :attempt
      assert_received :attempt
      refute_received :attempt
    end

    # Pins the moduledoc's `## Retry integration` arithmetic. `ALLM.Retry`
    # matches the CLOSURE'S error struct by `:reason`, and the default policy's
    # `retry_on` is `[429, 500, 502, 503, 504, :timeout]` — HTTP codes plus one
    # atom. So the adapter's own default loop retries `:timeout` and NOTHING
    # else, which is exactly why `:timeout` is the one reason whose budget
    # multiplies with the façade's (3 x 3 = 9) while every other retryable
    # reason costs 3.
    test "under the DEFAULT policy a 500 is not retried by the adapter's own loop", %{stub: stub} do
      counting_stub(stub, 500, %{"error" => %{"message" => "boom"}})

      assert {:error, %ModerationAdapterError{reason: :provider_unavailable}} =
               call(stub, req(["hi"]), retry: :default)

      assert_received :attempt
      refute_received :attempt
    end

    test "a 400 is not retried", %{stub: stub} do
      counting_stub(stub, 400, OpenAITestFixtures.moderation_recorded(:error_400_bad_model))

      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               call(stub, req(["hi"]), retry: [max_attempts: 3, base_delay_ms: 0, jitter_ms: 0])

      assert_received :attempt
      refute_received :attempt
    end
  end
end
