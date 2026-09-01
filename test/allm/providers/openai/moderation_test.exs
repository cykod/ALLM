defmodule ALLM.Providers.OpenAI.ModerationTest do
  @moduledoc """
  Seam units for `ALLM.Providers.OpenAI.Moderation` — no HTTP.

  Every test here drives one of the adapter's `@doc false` public seams
  (`to_json_body/2`, `decode_response/4`, `to_moderation_adapter_error/4`) or a
  pre-flight gate directly. The end-to-end path behind a `Req.Test` stub lives
  in `moderation_wire_test.exs`; the `ALLM.ModerationAdapter` contract cases
  live in `moderation_conformance_test.exs`.
  """

  use ExUnit.Case, async: true

  alias ALLM.Error.ModerationAdapterError
  alias ALLM.{ModerationRequest, ModerationResponse, ModerationResult}
  alias ALLM.Providers.OpenAI.Moderation
  alias ALLM.Providers.OpenAITestFixtures

  # All four `iex>` examples on the module are hermetic — the two `moderate/2`
  # ones drive `adapter_opts[:moderation_script]` and the empty-input gate,
  # `max_batch_size/0` is a constant, and `prepare_request/2` passes a literal
  # `api_key:` — so no network, key, or stub is needed. Binding on 22.5: wire
  # the `doctest` or the examples rot silently.
  doctest Moderation

  defp req(input, opts \\ []) do
    ModerationRequest.new(Keyword.merge([input: input], opts))
  end

  # ---------------------------------------------------------------------------
  # to_json_body/2
  # ---------------------------------------------------------------------------

  describe "to_json_body/2" do
    test "emits input as an array of strings" do
      assert Moderation.to_json_body(req(["a", "b"]), []) == %{"input" => ["a", "b"]}
    end

    test ~s(omits "model" entirely when request.model is nil) do
      body = Moderation.to_json_body(req(["a"]), [])

      refute Map.has_key?(body, "model")
    end

    test ~s(includes "model" when set) do
      body = Moderation.to_json_body(req(["a"], model: "omni-moderation-latest"), [])

      assert body["model"] == "omni-moderation-latest"
    end

    test "merges request.options onto the body, stringifying atom keys" do
      body = Moderation.to_json_body(req(["a"], options: %{some_future_knob: 3}), [])

      assert body["some_future_knob"] == 3
      assert body["input"] == ["a"]
    end

    test "structural fields win over a colliding :options key" do
      request = req(["a"], model: "omni-moderation-latest", options: %{"input" => ["evil"]})

      assert Moderation.to_json_body(request, []) ==
               %{"input" => ["a"], "model" => "omni-moderation-latest"}
    end

    test "an off-shape :options is ignored rather than raising" do
      assert Moderation.to_json_body(%ModerationRequest{input: ["a"], options: nil}, []) ==
               %{"input" => ["a"]}
    end
  end

  # ---------------------------------------------------------------------------
  # decode_response/4
  # ---------------------------------------------------------------------------

  describe "decode_response/4" do
    test "builds one %ModerationResult{} per results entry with sequential indices" do
      body = OpenAITestFixtures.moderation_recorded(:batch_mixed)

      assert {:ok, %ModerationResponse{} = resp} =
               Moderation.decode_response(body, [], req(["a", "b", "c"]), [])

      assert length(resp.results) == length(body["results"])
      assert Enum.map(resp.results, & &1.index) == [0, 1, 2]
      assert Enum.all?(resp.results, &is_boolean(&1.flagged))
    end

    # The wire's `results` array carries NO `index` field — verified against the
    # live 2026-08-31 recordings. `:index` is assigned from array position,
    # which is what makes `ALLM.ModerationAdapter` invariant 4 the adapter's
    # responsibility rather than the provider's.
    test "assigns :index from array position because the wire carries none" do
      body = OpenAITestFixtures.moderation_recorded(:batch_mixed)

      refute body["results"] |> hd() |> Map.has_key?("index")

      assert {:ok, resp} = Moderation.decode_response(body, [], req(["a", "b", "c"]), [])
      assert Enum.map(resp.results, & &1.index) == [0, 1, 2]
    end

    test "coerces an integral score to a float" do
      body = %{
        "id" => "modr-x",
        "results" => [
          %{"flagged" => false, "categories" => %{}, "category_scores" => %{"violence" => 0}}
        ]
      }

      assert {:ok, %ModerationResponse{results: [result]}} =
               Moderation.decode_response(body, [], req(["a"]), [])

      assert result.category_scores == %{"violence" => +0.0}
      assert is_float(result.category_scores["violence"])
    end

    test "drops null-valued category keys" do
      body = OpenAITestFixtures.moderation_synthesized(:null_illicit_categories)

      # Premise guard: the fixture must actually carry the nulls, or the
      # assertion below is vacuous.
      assert body["results"] |> hd() |> get_in(["categories", "illicit"]) == nil

      assert {:ok, %ModerationResponse{results: [result]}} =
               Moderation.decode_response(body, [], req(["a"]), [])

      refute Map.has_key?(result.categories, "illicit")
      refute Map.has_key?(result.categories, "illicit/violent")
      assert Map.has_key?(result.categories, "violence")
      assert Enum.all?(Map.values(result.categories), &is_boolean/1)
    end

    test "yields applied_input_types: %{} when the key is absent" do
      body = OpenAITestFixtures.moderation_synthesized(:missing_applied_input_types)

      refute body["results"] |> hd() |> Map.has_key?("category_applied_input_types")

      assert {:ok, %ModerationResponse{results: [result]}} =
               Moderation.decode_response(body, [], req(["a"]), [])

      assert result.applied_input_types == %{}
      assert result.flagged == true
    end

    test "carries applied_input_types through when present" do
      body = OpenAITestFixtures.moderation_recorded(:single_clean)

      assert {:ok, %ModerationResponse{results: [result]}} =
               Moderation.decode_response(body, [], req(["a"]), [])

      assert result.applied_input_types["violence"] == ["text"]
    end

    test "populates provider: :openai" do
      body = OpenAITestFixtures.moderation_recorded(:single_clean)

      assert {:ok, %ModerationResponse{provider: :openai}} =
               Moderation.decode_response(body, [], req(["a"]), [])
    end

    test "carries the provider id, model and raw body, and round-trips request.metadata" do
      body = OpenAITestFixtures.moderation_recorded(:single_clean)
      request = req(["a"], metadata: %{trace: "t1"})

      assert {:ok, %ModerationResponse{} = resp} =
               Moderation.decode_response(body, [], request, [])

      assert resp.id == body["id"]
      assert resp.model == body["model"]
      assert resp.raw == body
      assert resp.metadata == %{trace: "t1"}
    end

    test "falls back to the x-request-id header when opts[:request_id] is absent" do
      body = OpenAITestFixtures.moderation_recorded(:single_clean)
      headers = %{"x-request-id" => ["req_abc123"]}

      assert {:ok, %ModerationResponse{request_id: "req_abc123"}} =
               Moderation.decode_response(body, headers, req(["a"]), [])
    end

    test "opts[:request_id] wins over the x-request-id header" do
      body = OpenAITestFixtures.moderation_recorded(:single_clean)
      headers = %{"x-request-id" => ["req_abc123"]}

      assert {:ok, %ModerationResponse{request_id: "mine"}} =
               Moderation.decode_response(body, headers, req(["a"]), request_id: "mine")
    end

    test "falls back to request.model when the body omits one" do
      body = %{"results" => [%{"flagged" => false}]}
      request = req(["a"], model: "omni-moderation-2024-09-26")

      assert {:ok, %ModerationResponse{model: "omni-moderation-2024-09-26"}} =
               Moderation.decode_response(body, [], request, [])
    end

    test "a body with no results list is :malformed_response" do
      assert {:error, %ModerationAdapterError{reason: :malformed_response} = err} =
               Moderation.decode_response(%{"id" => "modr-x"}, [], req(["a"]), [])

      assert err.provider == :openai
      assert err.metadata.body_keys == ["id"]
    end

    test "a non-JSON body is :malformed_response" do
      assert {:error, %ModerationAdapterError{reason: :malformed_response}} =
               Moderation.decode_response("<html>", [], req(["a"]), [])
    end

    test "a results entry missing flagged is :malformed_response naming the index" do
      body = %{"results" => [%{"flagged" => false}, %{"categories" => %{}}]}

      assert {:error, %ModerationAdapterError{reason: :malformed_response} = err} =
               Moderation.decode_response(body, [], req(["a", "b"]), [])

      assert err.metadata.index == 1
    end

    test "a non-boolean flagged is :malformed_response — the verdict is never coerced" do
      body = %{"results" => [%{"flagged" => "true"}]}

      assert {:error, %ModerationAdapterError{reason: :malformed_response}} =
               Moderation.decode_response(body, [], req(["a"]), [])
    end

    test "every error carries opts[:request_id] on its metadata" do
      assert {:error, err} =
               Moderation.decode_response(%{}, [], req(["a"]), request_id: "rid-9")

      assert err.metadata.request_id == "rid-9"
    end
  end

  # ---------------------------------------------------------------------------
  # to_moderation_adapter_error/4
  # ---------------------------------------------------------------------------

  describe "to_moderation_adapter_error/4" do
    test "401 maps to :authentication_failed" do
      body = OpenAITestFixtures.moderation_synthesized(:error_401)
      err = Moderation.to_moderation_adapter_error(401, body, [], [])

      assert err.reason == :authentication_failed
      assert err.provider == :openai
      assert err.status == 401
    end

    test "403 maps to :authentication_failed" do
      assert Moderation.to_moderation_adapter_error(403, %{}, [], []).reason ==
               :authentication_failed
    end

    test "429 maps to :rate_limited and reads Retry-After" do
      body = OpenAITestFixtures.moderation_synthesized(:error_429)
      err = Moderation.to_moderation_adapter_error(429, body, [{"retry-after", "7"}], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == 7_000
    end

    test "an unparseable Retry-After yields nil rather than raising" do
      err = Moderation.to_moderation_adapter_error(429, %{}, [{"retry-after", "Wed, 21 Oct"}], [])

      assert err.reason == :rate_limited
      assert err.retry_after_ms == nil
    end

    test "400 maps to :invalid_request against the recorded bad-model envelope" do
      body = OpenAITestFixtures.moderation_recorded(:error_400_bad_model)
      err = Moderation.to_moderation_adapter_error(400, body, [], [])

      assert err.reason == :invalid_request
      assert err.message == body["error"]["message"]
      assert err.metadata.openai_type == "invalid_request_error"
    end

    test "a 400 marked context_length_exceeded maps to :context_length_exceeded" do
      body = %{"error" => %{"code" => "context_length_exceeded", "message" => "too long"}}

      assert Moderation.to_moderation_adapter_error(400, body, [], []).reason ==
               :context_length_exceeded
    end

    test "500 maps to :provider_unavailable" do
      assert Moderation.to_moderation_adapter_error(500, %{}, [], []).reason ==
               :provider_unavailable
    end

    test "an unclassifiable status maps to :unknown" do
      assert Moderation.to_moderation_adapter_error(418, %{}, [], []).reason == :unknown
    end

    test "a non-binary provider message is replaced, not interpolated" do
      err = Moderation.to_moderation_adapter_error(400, %{"error" => %{"message" => 123}}, [], [])

      assert err.reason == :invalid_request
      assert is_binary(err.message)
      refute err.message =~ "123"
    end

    test "no :body_preview and no raw body reaches the persisted struct" do
      body = OpenAITestFixtures.moderation_synthesized(:error_401)
      err = Moderation.to_moderation_adapter_error(401, body, [], [])

      assert err.cause == nil
      refute Map.has_key?(err.metadata, :body_preview)
      assert err.metadata |> Map.keys() |> Enum.sort() == [:openai_code, :openai_type, :status]
    end
  end

  # ---------------------------------------------------------------------------
  # max_batch_size/0 and the pre-flight gates
  # ---------------------------------------------------------------------------

  describe "max_batch_size/0" do
    test "returns a pos_integer" do
      assert is_integer(Moderation.max_batch_size())
      assert Moderation.max_batch_size() > 0
    end
  end

  describe "pre-flight gates" do
    # The POSITIVE CONTROL for every gate-ordering assertion below. Those
    # assertions are an ordering proof ONLY while key resolution genuinely
    # fails: with OPENAI_API_KEY exported — the state the design's own 22.4.4
    # Verification block puts the shell into via `set -a; . ./.env; set +a` —
    # an adapter that resolved the key AHEAD of the gates would pass all of
    # them, silently. Measured: hoisting `Keys.fetch!/2` ahead of `run_gates/2`
    # produces 6 failures keyless and 0 failures keyed. This control turns that
    # state loud. Mirrors `test/allm/providers/voyage/embeddings_test.exs:249`.
    test "positive control: a request that passes every gate DOES reach key resolution" do
      assert_raise ALLM.Error.EngineError, fn ->
        Moderation.moderate(req(["hi"]), [])
      end
    end

    # Both gates are asserted with NO :api_key in opts. `Keys.fetch!/2` would
    # raise %EngineError{reason: :missing_key} if it ran first, so a passing
    # assertion here IS the ordering proof (invariants 5 and 6).
    test "rejects input: [] with :invalid_request before resolving a key" do
      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.moderate(req([]), [])

      assert err.metadata.field == :input
    end

    test "rejects oversized input with :batch_too_large before resolving a key" do
      max = Moderation.max_batch_size()
      oversized = List.duplicate("x", max + 1)

      assert {:error, %ModerationAdapterError{reason: :batch_too_large} = err} =
               Moderation.moderate(req(oversized), [])

      assert err.metadata.count == max + 1
      assert err.metadata.max == max
    end

    test "an input that is not a list converts rather than raising" do
      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.moderate(%ModerationRequest{input: "hi"}, [])

      assert err.metadata.field == :input
    end

    test "prepare_request/2 runs the gates too" do
      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               Moderation.prepare_request(req([]), [])
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2 — invariant 10
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "returns an unfired request pointed at /v1/moderations" do
      assert {:ok, %Req.Request{} = http} =
               Moderation.prepare_request(req(["hi"], model: "omni-moderation-latest"),
                 api_key: "sk-x"
               )

      assert URI.to_string(http.url) == "https://api.openai.com/v1/moderations"
      assert http.method == :post
    end

    test "applies opts[:request_timeout] as a receive timeout" do
      assert {:ok, http} =
               Moderation.prepare_request(req(["hi"]), api_key: "sk-x", request_timeout: 250)

      assert http.options.receive_timeout == 250
    end

    test "returns a stub error under the moderation_script short-circuit" do
      opts = [adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]]

      assert {:error, %ModerationAdapterError{reason: :unknown} = err} =
               Moderation.prepare_request(req(["hi"]), opts)

      assert err.message =~ "prepare_request/2"
    end
  end

  # ---------------------------------------------------------------------------
  # Test-injection short-circuit
  # ---------------------------------------------------------------------------

  describe "moderation_script short-circuit" do
    test "delegates to FakeModeration when a script is present" do
      opts = [adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]]

      assert {:ok, %ModerationResponse{} = resp} = Moderation.moderate(req(["hi"]), opts)
      assert ModerationResponse.flagged_categories(resp) == ["violence"]
      assert resp.provider == :fake
    end

    test "the short-circuit fires ahead of this adapter's own gates" do
      # FakeModeration's cap is 32; OpenAI's is far larger. A list between the
      # two would be rejected by the Fake and accepted here — proof that the
      # script is consulted before this adapter's gate, and the reason
      # conformance cases 3 and 4 must pass no script.
      script = [{:ok, [ModerationResult.new(flagged: false, index: 0)]}]
      opts = [adapter_opts: [moderation_script: script]]

      assert {:error, %ModerationAdapterError{reason: :batch_too_large}} =
               Moderation.moderate(req(List.duplicate("x", 33)), opts)
    end
  end
end
