defmodule ALLM.Providers.TypeSafe.ClassificationTest do
  @moduledoc """
  Seam tests for `ALLM.Providers.TypeSafe.Classification`: the body builder,
  the pre-flight gates and their ordering against key resolution, the
  decoder against every recorded 200 fixture, and the error funnel.

  `async: false` because the gate-ordering tests delete `TYPESAFE_API_KEY`
  from the process-global environment (restored `on_exit`), so a gate that
  moved behind `ALLM.Keys.fetch!/2` raises `:missing_key` here instead of
  passing.
  """

  use ExUnit.Case, async: false

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationRequest}
  alias ALLM.{ClassificationResponse, Usage}
  alias ALLM.Error.{ClassificationAdapterError, EngineError}
  alias ALLM.Providers.Support.Redact
  alias ALLM.Providers.TypeSafe.Classification
  alias ALLM.Providers.TypeSafeTestFixtures, as: Fixtures

  doctest Classification

  @key_var "TYPESAFE_API_KEY"
  @planted_literal "PLANTEDLITERALKEY0123456789abcdefXYZ"

  setup do
    saved = System.get_env(@key_var)
    System.delete_env(@key_var)

    on_exit(fn ->
      if saved, do: System.put_env(@key_var, saved), else: System.delete_env(@key_var)
    end)

    stub = String.to_atom("typesafe_gate_#{System.unique_integer([:positive])}")
    parent = self()

    Req.Test.stub(stub, fn conn ->
      send(parent, :plug_reached)
      Plug.Conn.send_resp(conn, 500, "the plug must not be reached")
    end)

    {:ok, plug_opts: [adapter_opts: [plug: {Req.Test, stub}]]}
  end

  defp req(questions, opts \\ []),
    do: ClassificationRequest.new(Keyword.merge([state: "hi", questions: questions], opts))

  defp yes_no, do: ClassificationQuestion.yes_no("Is this a greeting?")

  defp choice_q(n),
    do: ClassificationQuestion.choice("Pick", Enum.map(1..n, &"option_#{&1}"))

  defp score_q(n), do: ClassificationQuestion.score("Rate", Enum.map(0..(n - 1), &"level #{&1}"))

  # The questions `scripts/record_typesafe_classification_fixtures.exs` sent
  # for arm 1, as ALLM questions.
  defp mixed_request do
    req(
      %{
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
      },
      metadata: %{"trace" => "t-1"}
    )
  end

  defp decode(env, request, opts \\ []),
    do: Classification.decode_response(env["body"], env["headers"], request, opts)

  defp err_for(env, key \\ nil),
    do:
      Classification.to_classification_adapter_error(
        env["status"],
        env["body"],
        env["headers"],
        key,
        []
      )

  defp unit?(x), do: is_float(x) and x >= 0.0 and x <= 1.0

  # ---------------------------------------------------------------------------
  # to_json_body/2
  # ---------------------------------------------------------------------------

  describe "to_json_body/2" do
    test "maps :yes_no to \"noul\" and omits nil yes_no criteria" do
      body = Classification.to_json_body(req(%{"y" => yes_no()}), [])
      assert body["questions"]["y"] == %{"type" => "noul", "instructions" => "Is this a greeting?"}
    end

    test "keeps yes_no criteria when given" do
      q = ClassificationQuestion.yes_no("Refund?", true: "asks for money back")
      body = Classification.to_json_body(req(%{"y" => q}), [])
      assert body["questions"]["y"]["criteria"] == %{"true" => "asks for money back"}
    end

    test "injects jev-latest when the model is nil and keeps an explicit model" do
      assert Classification.to_json_body(req(%{"y" => yes_no()}), [])["model"] == "jev-latest"

      assert Classification.to_json_body(req(%{"y" => yes_no()}, model: "jev-1.13.0"), [])[
               "model"
             ] == "jev-1.13.0"
    end

    test "sends choice and score criteria verbatim and the state unchanged" do
      body =
        Classification.to_json_body(
          req(%{"c" => choice_q(2), "s" => score_q(3)}, state: %{"a" => [1]}),
          []
        )

      assert body["state"] == %{"a" => [1]}
      assert body["questions"]["c"]["type"] == "choice"
      assert body["questions"]["c"]["criteria"] == %{"option_1" => nil, "option_2" => nil}
      assert body["questions"]["s"]["criteria"] == ["level 0", "level 1", "level 2"]
      assert Map.keys(body) |> Enum.sort() == ["model", "questions", "state"]
    end

    test "never puts :options on the wire, even a non-map" do
      for options <- [%{"temperature" => 1}, [1]] do
        body = Classification.to_json_body(req(%{"y" => yes_no()}, options: options), [])
        assert Map.keys(body) |> Enum.sort() == ["model", "questions", "state"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Gates, all driven through classify/2 with no key anywhere, so a gate that
  # ran after key resolution would raise :missing_key instead.
  # ---------------------------------------------------------------------------

  describe "gate ordering (no key in the environment, a plug that must not be reached)" do
    test "empty questions returns :invalid_request", %{plug_opts: opts} do
      assert {:error, %ClassificationAdapterError{reason: :invalid_request} = err} =
               Classification.classify(req(%{}), opts)

      assert err.metadata.field == :questions
      refute_received :plug_reached
    end

    test "a non-map questions value returns :invalid_request rather than raising",
         %{plug_opts: opts} do
      assert {:error, %ClassificationAdapterError{reason: :invalid_request}} =
               Classification.classify(req([]), opts)
    end

    test "over-limit questions return :invalid_request", %{plug_opts: opts} do
      for q <- [choice_q(256), score_q(11)] do
        assert {:error, %ClassificationAdapterError{reason: :invalid_request}} =
                 Classification.classify(req(%{"q" => q}), opts)
      end

      refute_received :plug_reached
    end

    test "a list state with a non-string element returns :invalid_request",
         %{plug_opts: opts} do
      assert {:error, %ClassificationAdapterError{reason: :invalid_request} = err} =
               Classification.classify(req(%{"y" => yes_no()}, state: ["a", 1]), opts)

      assert err.metadata == %{field: :state}
      refute_received :plug_reached
    end

    test "an unencodable body returns :invalid_request with nothing in :cause",
         %{plug_opts: opts} do
      bad = [
        [state: %{"a" => {1, 2}}],
        [state: %{{1, 2} => "x"}],
        [state: %{"a" => [1 | 2]}]
      ]

      for extra <- bad do
        assert {:error, %ClassificationAdapterError{reason: :invalid_request} = err} =
                 Classification.classify(req(%{"y" => yes_no()}, extra), opts)

        assert err.metadata.cause == :unencodable_body
        assert err.cause == nil
        assert Jason.encode!(err)
      end

      q = %ClassificationQuestion{type: :yes_no, instructions: %{"k" => self()}}

      assert {:error, %ClassificationAdapterError{metadata: %{cause: :unencodable_body}}} =
               Classification.classify(req(%{"y" => q}), opts)

      refute_received :plug_reached
    end

    test "control: a valid request reaches key resolution and raises :missing_key",
         %{plug_opts: opts} do
      assert_raise EngineError, fn ->
        Classification.classify(req(%{"y" => yes_no()}), opts)
      end

      refute_received :plug_reached
    end
  end

  describe "gate_limits/2" do
    test "255 options and 10 levels pass; 256 and 11 are rejected naming the question" do
      assert :ok = Classification.gate_limits(req(%{"c" => choice_q(255)}), [])
      assert :ok = Classification.gate_limits(req(%{"s" => score_q(10)}), [])

      assert {:error, %ClassificationAdapterError{reason: :invalid_request} = e1} =
               Classification.gate_limits(req(%{"c" => choice_q(256)}), request_id: "r1")

      assert e1.metadata == %{question: "c", limit: 255, request_id: "r1"}

      assert {:error, %ClassificationAdapterError{} = e2} =
               Classification.gate_limits(req(%{"s" => score_q(11)}), [])

      assert e2.metadata == %{question: "s", limit: 10}
    end
  end

  describe "gate_state/1" do
    test "a list of strings passes; any other element is rejected" do
      assert :ok = Classification.gate_state(req(%{}, state: ["a", "b"]))
      assert :ok = Classification.gate_state(req(%{}, state: %{"a" => 1}))

      assert {:error, %ClassificationAdapterError{reason: :invalid_request, metadata: m}} =
               Classification.gate_state(req(%{}, state: ["a", 1]))

      assert m == %{field: :state}
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "sets :receive_timeout from request_timeout and disables Req's retry" do
      {:ok, prepared} =
        Classification.prepare_request(req(%{"y" => yes_no()}),
          api_key: "apikey_x",
          request_timeout: 1234
        )

      assert prepared.options[:receive_timeout] == 1234
      assert prepared.options[:retry] == false
      assert prepared.method == :post
      assert URI.to_string(prepared.url) == "https://api.typesafe.ai/v1/systemone"
    end

    test "returns the :scripted_adapter stub error under a script" do
      assert {:error, %ClassificationAdapterError{reason: :unknown} = err} =
               Classification.prepare_request(req(%{"y" => yes_no()}),
                 adapter_opts: [classification_script: []]
               )

      assert err.metadata.cause == :scripted_adapter
    end
  end

  # ---------------------------------------------------------------------------
  # decode_response/4 against recorded fixtures
  # ---------------------------------------------------------------------------

  describe "decode_response/4 on recorded fixtures" do
    test "mixed_questions follows the field-population table" do
      env = Fixtures.recorded(:mixed_questions)
      request = mixed_request()

      assert {:ok, %ClassificationResponse{} = resp} =
               decode(env, request, request_id: "rid-1")

      assert resp.provider == :typesafe
      assert resp.model == "jev-1.13.0"
      assert resp.id == env["headers"]["x-typesafe-request-id"]
      assert resp.id =~ ~r/^req_/
      assert resp.request_id == "rid-1"
      assert resp.metadata == %{"trace" => "t-1"}
      assert resp.raw == env["body"]

      assert %Usage{input_tokens: i, output_tokens: o, total_tokens: t} = resp.usage
      assert is_integer(i) and is_integer(o) and t == i + o
      assert resp.usage.total_cost == nil

      c = ClassificationResponse.answer(resp, "department")
      assert %ClassificationAnswer{type: :choice} = c
      assert c.choice in ["billing", "technical", "sales"]
      assert Map.keys(c.probabilities) |> Enum.sort() == ["billing", "sales", "technical"]
      assert Enum.all?(Map.values(c.probabilities), &unit?/1)
      assert unit?(c.confidence)
      assert {c.score, c.yes_probability, c.legend} == {nil, nil, nil}

      s = ClassificationResponse.answer(resp, "frustration")
      assert %ClassificationAnswer{type: :score} = s
      assert is_float(s.score) and s.score >= 0.0 and s.score <= 2.0
      assert length(s.probabilities) == 3 and Enum.all?(s.probabilities, &unit?/1)
      assert s.legend == ["Calm", "Frustrated", "Very angry"]
      assert unit?(s.confidence)
      assert {s.choice, s.yes_probability} == {nil, nil}

      y = ClassificationResponse.answer(resp, "refund")
      assert %ClassificationAnswer{type: :yes_no} = y
      assert unit?(y.yes_probability)

      assert {y.confidence, y.choice, y.score, y.probabilities, y.legend} ==
               {nil, nil, nil, nil, nil}
    end

    test "structured_state: object score levels come back as object legend entries" do
      levels = [
        %{"label" => "Minor", "meaning" => "cosmetic"},
        %{"label" => "Major", "meaning" => "a feature is broken"},
        %{"label" => "Critical", "meaning" => "data loss or outage"}
      ]

      request =
        req(%{"severity" => ClassificationQuestion.score(%{"task" => "Rate"}, levels)},
          state: %{"customer" => "Ada"}
        )

      assert {:ok, resp} = decode(Fixtures.recorded(:structured_state), request)
      s = ClassificationResponse.answer(resp, "severity")
      assert s.legend == levels
      assert length(s.probabilities) == 3
    end

    test "choice_255_options decodes all 255 options" do
      assert {:ok, resp} =
               decode(Fixtures.recorded(:choice_255_options), req(%{"q" => choice_q(255)}))

      assert map_size(ClassificationResponse.answer(resp, "q").probabilities) == 255
    end

    test "score_10_levels decodes into 10-element lists in level order" do
      assert {:ok, resp} = decode(Fixtures.recorded(:score_10_levels), req(%{"q" => score_q(10)}))
      s = ClassificationResponse.answer(resp, "q")
      assert length(s.probabilities) == 10
      assert s.legend == Enum.map(0..9, &"level #{&1}")
    end

    test "negative_control and probe_state_list_any decode as ordinary yes/no answers" do
      for name <- [:negative_control, :probe_state_list_any] do
        assert {:ok, resp} = decode(Fixtures.recorded(name), req(%{"q" => yes_no()}))
        assert unit?(ClassificationResponse.answer(resp, "q").yes_probability)
      end
    end
  end

  describe "decode_response/4 contract breaches are :malformed_response" do
    test "a requested id with no answer (answer_id_missing.json)" do
      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               decode(Fixtures.synthesized(:answer_id_missing), mixed_request())
    end

    test "an answer for an id that was not asked" do
      env = Fixtures.recorded(:mixed_questions)
      request = %{mixed_request() | questions: Map.delete(mixed_request().questions, "refund")}

      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               decode(env, request)
    end

    test "an answer whose type differs from its question's" do
      env = Fixtures.recorded(:mixed_questions)

      request = %{
        mixed_request()
        | questions: Map.put(mixed_request().questions, "refund", choice_q(2))
      }

      assert {:error, %ClassificationAdapterError{reason: :malformed_response} = err} =
               decode(env, request)

      assert err.metadata.question == "refund"
    end

    test "a choice outside the options, and a score with the wrong level count" do
      env = Fixtures.recorded(:mixed_questions)
      q = mixed_request().questions

      bad_choice = %{mixed_request() | questions: %{q | "department" => choice_q(3)}}

      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               decode(env, bad_choice)

      bad_score = %{mixed_request() | questions: %{q | "frustration" => score_q(4)}}

      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               decode(env, bad_score)
    end

    test "a score map with a level gap" do
      env = Fixtures.recorded(:mixed_questions)
      body = update_in(env["body"]["answers"]["frustration"]["probabilities"], &Map.delete(&1, "1"))

      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               decode(%{env | "body" => body}, mixed_request())
    end

    test "a body with no answers, and a non-map body" do
      assert {:error, %ClassificationAdapterError{reason: :malformed_response} = err} =
               Classification.decode_response(%{"model" => "x"}, %{}, mixed_request(), [])

      assert err.metadata.body_keys == ["model"]

      assert {:error, %ClassificationAdapterError{reason: :malformed_response}} =
               Classification.decode_response("<html>", %{}, mixed_request(), [])
    end
  end

  describe "decode_response/4 answer-shape breaches (table-driven over mixed_questions)" do
    test "each malformed answer is :malformed_response naming the question" do
      env = Fixtures.recorded(:mixed_questions)

      rows = [
        {"refund", fn _ -> %{"type" => "ranking"} end},
        {"refund", fn _ -> "not an object" end},
        {"refund", &Map.put(&1, "noul", 1.5)},
        {"refund", &Map.put(&1, "noul", "high")},
        {"department", &Map.put(&1, "choice", 7)},
        {"department", &Map.put(&1, "probabilities", [1.0])},
        {"department", &Map.put(&1, "probabilities", %{"billing" => "x"})},
        {"department", &Map.put(&1, "confidence", nil)},
        {"frustration", &Map.put(&1, "score", 2.5)},
        {"frustration", &Map.put(&1, "score", nil)},
        {"frustration", &Map.put(&1, "legend", %{})},
        # The score sibling of the choice "x" row above: it raised
        # FunctionClauseError before float_list/2 (adapter invariant 1).
        {"frustration", &put_in(&1, ["probabilities", "0"], "x")},
        {"frustration", &put_in(&1, ["probabilities", "2"], nil)},
        # Every probability and confidence is range-checked, as `noul` is.
        {"department", &put_in(&1, ["probabilities", "billing"], 7.0)},
        {"department", &Map.put(&1, "confidence", -3.0)},
        {"frustration", &put_in(&1, ["probabilities", "0"], -0.5)},
        {"frustration", &Map.put(&1, "confidence", 1.5)}
      ]

      for {id, mutate} <- rows do
        body = update_in(env["body"], ["answers", id], mutate)

        assert {:error, %ClassificationAdapterError{reason: :malformed_response} = err} =
                 decode(%{env | "body" => body}, mixed_request()),
               "#{id}: #{inspect(mutate.(env["body"]["answers"][id]))}"

        assert err.metadata.question == id
      end
    end

    test "a level-map error names the range only when the level count is known" do
      env = Fixtures.recorded(:mixed_questions)
      body = put_in(env["body"], ["answers", "frustration", "legend"], %{})

      assert {:error, err} = decode(%{env | "body" => body}, mixed_request())
      assert err.message =~ ~s("legend" is not keyed by level "0".."2")

      # A hand-built score question whose criteria is not a list: the level
      # count comes from the body, so an empty map cannot name a range.
      q = %{mixed_request().questions["frustration"] | criteria: nil}
      request = put_in(mixed_request().questions["frustration"], q)
      body = put_in(env["body"], ["answers", "frustration", "probabilities"], %{})

      assert {:error, err} = decode(%{env | "body" => body}, request)
      assert err.message =~ ~s("probabilities" is not an object keyed by level)
      refute err.message =~ ~s("0".."0")
    end

    test "a body without model or usable usage falls back to the request model and nil counts" do
      env = Fixtures.recorded(:mixed_questions)

      body =
        env["body"]
        |> Map.delete("model")
        |> Map.put("usage", %{"input_tokens" => -1, "output_tokens" => "x"})

      assert {:ok, resp} = decode(%{env | "body" => body}, mixed_request())
      assert resp.model == "jev-latest"
      assert resp.usage == %Usage{}

      request = %{mixed_request() | model: "jev-1.13.0"}
      assert {:ok, %{model: "jev-1.13.0"}} = decode(%{env | "body" => body}, request)
    end
  end

  test "integer_probabilities.json decodes every number as a float" do
    assert {:ok, resp} = decode(Fixtures.synthesized(:integer_probabilities), mixed_request())

    c = ClassificationResponse.answer(resp, "department")
    assert c.probabilities == %{"billing" => 1.0, "sales" => 0.0, "technical" => 0.0}
    assert c.confidence === 1.0

    s = ClassificationResponse.answer(resp, "frustration")
    assert s.score === 2.0
    assert s.probabilities == [0.0, 0.0, 1.0] and Enum.all?(s.probabilities, &is_float/1)

    assert ClassificationResponse.answer(resp, "refund").yes_probability === 1.0
  end

  # ---------------------------------------------------------------------------
  # The error funnel
  # ---------------------------------------------------------------------------

  describe "classify_classification_reason/3" do
    test "maps every status row" do
      rows = [
        {401, :authentication_failed},
        {403, :authentication_failed},
        {400, :invalid_request},
        {404, :invalid_request},
        {422, :invalid_request},
        {500, :provider_unavailable},
        {502, :provider_unavailable},
        {503, :provider_unavailable},
        {504, :provider_unavailable},
        {529, :provider_unavailable},
        {418, :unknown}
      ]

      for {status, reason} <- rows do
        assert {^reason, _} = Classification.classify_classification_reason(status, nil, nil),
               "status #{status}"
      end

      assert {:rate_limited, 7000} = Classification.classify_classification_reason(429, nil, 7000)

      assert {:context_length_exceeded, nil} =
               Classification.classify_classification_reason(400, "max_tokens_exceeded", nil)

      assert {:invalid_request, nil} =
               Classification.classify_classification_reason(400, "api_usage_error", nil)
    end
  end

  describe "to_classification_adapter_error/5 on recorded error envelopes" do
    test "each recorded error maps to its reason and message" do
      rows = [
        {:error_400_bad_type, :invalid_request, "Invalid request."},
        {:error_400_too_many_options, :invalid_request,
         "Too many choices. Must have at most 255 choices."},
        {:error_400_too_many_levels, :invalid_request,
         "Too many score levels. Must have at most 10 levels."},
        {:error_bad_model, :invalid_request, "Unknown model: jev-allm-probe-nonexistent"},
        {:error_401_live, :authentication_failed,
         "Cannot authenticate with the server. Please check your API key and try again."},
        {:error_context_length, :context_length_exceeded, "TypeSafe HTTP 400"}
      ]

      for {name, reason, message} <- rows do
        env = Fixtures.recorded(name)
        err = err_for(env)
        assert err.reason == reason, "#{name}"
        assert err.message == message, "#{name}"
        assert err.status == env["status"]
        assert err.metadata.typesafe_request_id == env["headers"]["x-typesafe-request-id"]
        assert Jason.encode!(err)
      end
    end

    test "the 422 FastAPI list becomes loc: msg, without echoing the input" do
      err = err_for(Fixtures.recorded(:error_422_empty_questions))
      assert err.reason == :invalid_request
      assert err.message =~ ~r/^body\.questions: Dictionary should have at least 1 item/
      refute err.message =~ "input"
    end

    test "error_type goes to metadata; the context-length envelope names it" do
      assert err_for(Fixtures.recorded(:error_context_length)).metadata.typesafe_error_type ==
               "max_tokens_exceeded"

      assert err_for(Fixtures.recorded(:error_400_too_many_options)).metadata.typesafe_error_type ==
               nil
    end

    test "a 529 is :provider_unavailable and a 429 carries retry_after_ms" do
      assert err_for(Fixtures.synthesized(:error_529)).reason == :provider_unavailable

      err = err_for(Fixtures.synthesized(:error_429))
      assert err.reason == :rate_limited
      assert err.retry_after_ms == 7000
    end

    test "a 422 list entry without a loc is its msg; entries without a msg are skipped" do
      body = %{"detail" => [%{"msg" => "bad"}, %{"type" => "x"}]}

      assert Classification.to_classification_adapter_error(422, body, %{}, nil, []).message ==
               "bad"

      only_junk = %{"detail" => [%{"type" => "x"}]}

      assert Classification.to_classification_adapter_error(422, only_junk, %{}, nil, []).message ==
               "TypeSafe HTTP 422"
    end

    test "a 422 loc holding anything but strings and integers is dropped, never raised on" do
      # An object segment raised Protocol.UndefinedError and a nested
      # non-codepoint list UnicodeConversionError from to_string/1.
      for loc <- [[%{"a" => 1}], ["body", ["x"]], ["body", [-1]], ["body", nil]] do
        body = %{"detail" => [%{"loc" => loc, "msg" => "bad"}]}

        assert Classification.to_classification_adapter_error(422, body, %{}, nil, []).message ==
                 "bad",
               inspect(loc)
      end

      body = %{"detail" => [%{"loc" => ["body", "questions", 0], "msg" => "bad"}]}

      assert Classification.to_classification_adapter_error(422, body, %{}, nil, []).message ==
               "body.questions.0: bad"
    end

    test "a non-JSON error body falls back to the status message" do
      err =
        Classification.to_classification_adapter_error(
          502,
          "<html>bad gateway</html>",
          %{},
          nil,
          []
        )

      assert err.reason == :provider_unavailable
      assert err.message == "TypeSafe HTTP 502"
    end
  end

  describe "redaction (planted key material in synthesized/error_401.json)" do
    setup do
      {:ok, env: Fixtures.synthesized(:error_401)}
    end

    test "the literal resolved key and the apikey_ token are both removed", %{env: env} do
      err = err_for(env, @planted_literal)
      refute err.message =~ @planted_literal
      refute err.message =~ "apikey_PLANTED"
      assert err.message =~ "[REDACTED]"
      refute err.metadata.typesafe_error_type =~ "apikey_PLANTED"
      assert err.metadata.typesafe_error_type =~ "authentication_error"
      refute Jason.encode!(err) =~ "PLANTED"
      refute inspect(err) =~ "PLANTED"
    end

    test "the pattern pass alone leaves the literal key: the literal pass is load-bearing",
         %{env: env} do
      message = env["body"]["detail"]["message"]
      assert Redact.typesafe(message) =~ @planted_literal
      refute Classification.redact_key_material(message, @planted_literal) =~ @planted_literal
    end

    test "a key shorter than 8 bytes is not removed literally" do
      assert Classification.redact_key_material("the word short stays", "short") ==
               "the word short stays"
    end

    test "every sibling provider's pattern leaves the fixture unchanged", %{env: env} do
      message = env["body"]["detail"]["message"]
      error_type = env["body"]["detail"]["error_type"]

      for redact <- [
            &Redact.openai/1,
            &Redact.anthropic/1,
            &Redact.gemini/1,
            &Redact.voyage/1,
            &Redact.elevenlabs/1
          ] do
        assert redact.(message) == message
        assert redact.(error_type) == error_type
      end
    end
  end
end
