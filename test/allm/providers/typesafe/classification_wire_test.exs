defmodule ALLM.Providers.TypeSafe.ClassificationWireTest do
  @moduledoc """
  Wire tests for `ALLM.Providers.TypeSafe.Classification`, driven through
  `classify/2` behind a `Req.Test` stub, plus fixture provenance.

  **Provenance.** `recorded/` holds live responses written by
  `scripts/record_typesafe_classification_fixtures.exs` on 2026-09-27; none
  carries a `_comment` marker. Every `synthesized/` file carries one. Both
  halves are gated below by raw-byte reads, over the files discovered on
  disk, and the recorded set is pinned to the recorder's arm list so an
  unrecorded arm is a failure rather than silence.
  """

  use ExUnit.Case, async: true

  alias ALLM.{ClassificationQuestion, ClassificationRequest, ClassificationResponse}
  alias ALLM.Error.ClassificationAdapterError
  alias ALLM.Providers.TypeSafe.Classification
  alias ALLM.Providers.TypeSafeTestFixtures, as: Fixtures

  @recorder "( set -a; . ./.env; set +a; mix run scripts/record_typesafe_classification_fixtures.exs )"

  # One file per recorder arm (arms 1–5b, 7–13).
  @recorded ~w(
    mixed_questions structured_state error_400_bad_type error_400_too_many_options
    choice_255_options error_400_too_many_levels score_10_levels error_bad_model
    error_401_live error_context_length probe_question_ladder negative_control
    probe_state_list_any error_422_empty_questions
  )
  @synthesized ~w(answer_id_missing error_401 error_429 error_529 integer_probabilities)

  setup do
    {:ok, stub: String.to_atom("typesafe_wire_#{System.unique_integer([:positive])}")}
  end

  defp request do
    ClassificationRequest.new(
      state: "I was charged twice for my subscription and I am furious. Refund me.",
      questions: %{
        "department" =>
          ClassificationQuestion.choice("Which option fits best?", %{
            "billing" => nil,
            "technical" => "Bugs and outages",
            "sales" => nil
          }),
        "frustration" =>
          ClassificationQuestion.score("How strongly does this apply?", [
            "Calm",
            "Frustrated",
            "Very angry"
          ]),
        "refund" => ClassificationQuestion.yes_no("Is the customer asking for a refund?")
      }
    )
  end

  defp call(stub, req, opts \\ []) do
    Classification.classify(
      req,
      Keyword.merge([api_key: "apikey_wiretest", adapter_opts: [plug: {Req.Test, stub}]], opts)
    )
  end

  describe "request shape" do
    test "POSTs the wire-field-map body with a Bearer header", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:req, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "content-type"), Jason.decode!(raw)}
        )

        Fixtures.replay(conn, Fixtures.recorded(:mixed_questions))
      end)

      assert {:ok, _} = call(stub, request())

      assert_received {:req, "POST", "api.typesafe.ai", "/v1/systemone", ["Bearer apikey_wiretest"],
                       ["application/json"], body}

      assert body["model"] == "jev-latest"
      assert body["state"] == request().state

      assert body["questions"]["refund"] == %{
               "type" => "noul",
               "instructions" => "Is the customer asking for a refund?"
             }

      assert body["questions"]["department"]["type"] == "choice"
      assert body["questions"]["frustration"]["criteria"] == ["Calm", "Frustrated", "Very angry"]
    end
  end

  describe "responses" do
    test "a replayed recorded 200 decodes, with the provider request id in :id", %{stub: stub} do
      env = Fixtures.recorded(:mixed_questions)
      Req.Test.stub(stub, &Fixtures.replay(&1, env))

      assert {:ok, %ClassificationResponse{} = resp} = call(stub, request(), request_id: "r-9")
      assert resp.id == env["headers"]["x-typesafe-request-id"]
      assert resp.request_id == "r-9"
      assert map_size(resp.answers) == 3
    end

    test "exactly one HTTP attempt on a 503 (no inner retry)", %{stub: stub} do
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :attempt)
        Plug.Conn.send_resp(conn, 503, ~s({"detail": "unavailable"}))
      end)

      assert {:error, %ClassificationAdapterError{reason: :provider_unavailable}} =
               call(stub, request())

      assert_received :attempt
      refute_received :attempt
    end

    test "a 529 and a 429 map through classify/2", %{stub: stub} do
      Req.Test.stub(stub, &Fixtures.replay(&1, Fixtures.synthesized(:error_529)))
      assert {:error, %{reason: :provider_unavailable, status: 529}} = call(stub, request())

      Req.Test.stub(stub, &Fixtures.replay(&1, Fixtures.synthesized(:error_429)))
      assert {:error, %{reason: :rate_limited, retry_after_ms: 7000}} = call(stub, request())
    end

    test "the resolved key is redacted from a provider message that echoes it", %{stub: stub} do
      key = "apikey_wiretestliteral0123456789"

      Req.Test.stub(stub, fn conn ->
        Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"detail" => %{"message" => "bad " <> key}}))
      end)

      assert {:error, err} = call(stub, request(), api_key: key)
      assert err.message == "bad [REDACTED]"
    end

    test "a 200 whose body is not valid JSON is :malformed_response", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "not json")
      end)

      assert {:error, %ClassificationAdapterError{reason: :malformed_response} = err} =
               call(stub, request())

      assert err.cause == nil
      assert Jason.encode!(err)
    end
  end

  describe "transport errors" do
    test ":timeout and :econnrefused map to :timeout and :network_error, encodably",
         %{stub: stub} do
      for {transport, reason} <- [timeout: :timeout, econnrefused: :network_error] do
        Req.Test.stub(stub, &Req.Test.transport_error(&1, transport))

        assert {:error, %ClassificationAdapterError{reason: ^reason} = err} =
                 call(stub, request())

        assert err.cause == nil
        assert err.metadata.transport_reason == transport
        assert Jason.encode!(err)
      end
    end
  end

  describe "fixture provenance" do
    for name <- @recorded do
      test "recorded/#{name}.json is a live recording, not a placeholder" do
        refute Map.has_key?(Fixtures.raw("recorded", unquote(name)), "_comment"),
               "placeholder still in recorded/ — run `#{@recorder}`"
      end
    end

    for name <- @synthesized do
      test "synthesized/#{name}.json carries the _comment marker" do
        assert Fixtures.raw("synthesized", unquote(name))["_comment"] =~
                 "Synthesized — Phase 24.4"
      end
    end

    test "the recorded files on disk are exactly the recorder's arm list" do
      assert Fixtures.names_on_disk("recorded") == Enum.sort(@recorded),
             "recorded/ differs from the arm list — run `#{@recorder}`"
    end

    test "the synthesized files on disk are exactly the listed ones" do
      assert Fixtures.names_on_disk("synthesized") == Enum.sort(@synthesized)
    end

    test "the question ladder recorded no cap up to 512 questions" do
      ladder = Fixtures.raw("recorded", "probe_question_ladder")
      assert ladder["max_ok"] == 512
      assert ladder["first_failure"] == nil
    end
  end
end
