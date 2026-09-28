defmodule ALLM.ALLMClassifyTest do
  @moduledoc """
  Layer-C `ALLM.classify/3` and `ALLM.classification_request/2` over
  `ALLM.Providers.FakeClassification`.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which filters by
  owner PID; a bare global handler attach in an `async: true` module would
  capture other tests' `[:allm, :classify, :*]` events.

  **Script arithmetic matters here.** A non-empty `:classification_script`
  that runs off the end returns `:classification_script_exhausted` rather
  than defaulting, so every scripted test below scripts exactly as many
  entries as it drives calls.

  **Retry is asserted at the façade's result only.** The façade's
  `Retry.run/3` collapses the adapter's per-call error sequence; the
  per-call sequencing is pinned against the Fake directly in
  `test/allm/providers/fake_classification_test.exs`.
  """

  use ExUnit.Case, async: true

  doctest ALLM, only: [classify: 3, classification_request: 2]

  alias ALLM.{ClassificationQuestion, ClassificationRequest, ClassificationResponse, Engine}
  alias ALLM.Error.{ClassificationAdapterError, EngineError, ValidationError}
  alias ALLM.Providers.FakeClassification
  alias ALLM.Test.{FakeClassificationFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Inline non-conforming stubs — scope is this file only.
  # ---------------------------------------------------------------------------

  defmodule BareMapAdapter do
    @moduledoc false
    @behaviour ALLM.ClassificationAdapter

    # Deliberately non-conforming: the response struct bare rather than in an
    # `{:ok, _}` tuple — `ALLM.ClassificationAdapter` invariant 1.
    @impl ALLM.ClassificationAdapter
    def classify(%ALLM.ClassificationRequest{}, _opts), do: %ALLM.ClassificationResponse{}
  end

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour ALLM.ClassificationAdapter

    @impl ALLM.ClassificationAdapter
    def classify(%ALLM.ClassificationRequest{}, _opts), do: raise("boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Default 3-attempt budget with the backoff collapsed, so retry tests do not
  # sleep 500 ms per attempt.
  @fast_retry [base_delay_ms: 1, max_delay_ms: 1, jitter_ms: 0]

  defp fake_engine(opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [
          classification_adapter: FakeClassification,
          adapter_opts: [capture_pid: self()] ++ adapter_opts
        ],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  defp captured_calls(acc \\ []) do
    receive do
      {FakeClassification, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp questions, do: FakeClassificationFixtures.questions()

  defp rate_limited, do: ClassificationAdapterError.new(:rate_limited, retry_after_ms: 0)

  # ---------------------------------------------------------------------------
  # classification_request/2
  # ---------------------------------------------------------------------------

  describe "classification_request/2" do
    test "wraps the state and lifts request-field opts onto the struct" do
      req =
        ALLM.classification_request("ticket",
          questions: questions(),
          model: "jev-1.13.0",
          options: %{a: 1},
          metadata: %{t: 1}
        )

      assert %ClassificationRequest{state: "ticket", model: "jev-1.13.0"} = req
      assert req.questions == questions()
      assert req.options == %{a: 1}
      assert req.metadata == %{t: 1}
    end

    test "stringifies atom question ids and leaves string ids untouched" do
      q = ClassificationQuestion.yes_no("Refund?")
      req = ALLM.classification_request("x", questions: %{"team" => q, refund: q})

      assert Map.keys(req.questions) |> Enum.sort() == ["refund", "team"]
      assert req.questions["refund"] == q
    end

    test "ignores call-control opts that are not ClassificationRequest fields" do
      req =
        ALLM.classification_request("x",
          request_id: "rid",
          request_timeout: 5_000,
          retry: false,
          adapter_opts: [foo: 1],
          api_key: "sk-nope",
          stream: true,
          state: "overridden?",
          totally_unknown: :whatever
        )

      assert req == ClassificationRequest.new(state: "x")
    end

    test "the allow-list equals the ClassificationRequest fields minus :state" do
      # Symmetry invariant, computed from `Map.keys/1` — a field added to the
      # struct without an allow-list entry, or a typo'd entry, goes red here.
      struct_fields = Map.keys(%ClassificationRequest{}) -- [:__struct__, :state]

      assert Enum.sort(struct_fields) == [:metadata, :model, :options, :questions]

      for field <- struct_fields do
        req = ALLM.classification_request("x", [{field, :__sentinel__}])

        assert Map.fetch!(req, field) == :__sentinel__,
               "#{inspect(field)} is a ClassificationRequest field but is not reachable " <>
                 "through ALLM.classification_request/2's opts allow-list"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — input shapes
  # ---------------------------------------------------------------------------

  describe "classify/3 input shapes" do
    test "a binary state plus questions: returns an answer per id" do
      engine = fake_engine()

      assert {:ok, %ClassificationResponse{} = resp} =
               ALLM.classify(engine, "My payouts failed.", questions: questions())

      assert resp.answers |> Map.keys() |> Enum.sort() == ["d", "s", "y"]
      assert [%{request: %ClassificationRequest{state: "My payouts failed."}}] = captured_calls()
    end

    test "map state and list state are accepted" do
      engine = fake_engine()

      assert {:ok, %ClassificationResponse{}} =
               ALLM.classify(engine, %{"ticket" => "refund please"}, questions: questions())

      assert {:ok, %ClassificationResponse{}} =
               ALLM.classify(engine, ["first message", "second message"], questions: questions())

      assert [
               %{request: %ClassificationRequest{state: %{"ticket" => "refund please"}}},
               %{request: %ClassificationRequest{state: ["first message", "second message"]}}
             ] = captured_calls()
    end

    test "a pre-built request dispatches verbatim and is NOT merged with opts" do
      engine = fake_engine()
      request = FakeClassificationFixtures.request(metadata: %{from: :req})

      assert {:ok, _} =
               ALLM.classify(engine, request,
                 questions: %{"other" => ClassificationQuestion.yes_no("?")},
                 metadata: %{from: :opts}
               )

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched == request
    end

    test "atom question ids are stringified and the response is keyed by strings" do
      engine = fake_engine()
      q = ClassificationQuestion.choice("Team?", ["billing", "technical"])

      assert {:ok, resp} = ALLM.classify(engine, "x", questions: %{team: q})
      assert Map.keys(resp.answers) == ["team"]
      assert ClassificationResponse.answer(resp, :team).choice == "billing"
      assert [%{request: %ClassificationRequest{questions: %{"team" => ^q}}}] = captured_calls()
    end

    test "a keyword list in the state position is a validation error, not a raise" do
      engine = fake_engine()

      assert {:error, %ValidationError{reason: :invalid_classification_request} = err} =
               ALLM.classify(engine, questions: questions())

      assert {:state, :invalid_shape} in err.errors
      assert captured_calls() == []
    end

    test "another struct in the state position is a validation error, not a raise" do
      engine = fake_engine()

      assert {:error, %ValidationError{} = err} =
               ALLM.classify(engine, ALLM.ModerationRequest.new(input: ["x"]),
                 questions: questions()
               )

      assert {:state, :invalid_shape} in err.errors
      assert captured_calls() == []
    end

    test "a non-binary, non-map, non-list state raises FunctionClauseError" do
      engine = fake_engine()

      assert_raise FunctionClauseError, fn -> ALLM.classify(engine, 42, questions: questions()) end
      assert_raise FunctionClauseError, fn -> ALLM.classify(engine, nil) end
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — gates
  # ---------------------------------------------------------------------------

  describe "classify/3 gates" do
    test "an engine with no classification_adapter returns :no_classification_adapter" do
      assert {:error, %EngineError{reason: :no_classification_adapter}} =
               ALLM.classify(Engine.new(), "x", questions: questions())
    end

    test ":no_classification_adapter fires ahead of an invalid request" do
      # Both conditions at once: empty state AND empty questions.
      assert {:error, %EngineError{reason: :no_classification_adapter}} =
               ALLM.classify(Engine.new(), "", questions: %{})
    end

    test "an invalid request returns :invalid_classification_request and the script is not consumed" do
      engine =
        fake_engine(adapter_opts: FakeClassificationFixtures.answers(%{"d" => "technical"}))

      assert {:error, %ValidationError{reason: :invalid_classification_request} = err} =
               ALLM.classify(engine, "", questions: questions())

      assert {:state, :empty} in err.errors
      assert captured_calls() == []

      # The one scripted entry is still there for the next (valid) call.
      assert {:ok, resp} = ALLM.classify(engine, "x", questions: questions())
      assert ClassificationResponse.answer(resp, "d").choice == "technical"
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — model resolution (per-slot, never engine.model)
  # ---------------------------------------------------------------------------

  describe "classify/3 model resolution" do
    test "engine.model (the chat model) never reaches the classification adapter" do
      engine = fake_engine(model: "gpt-x")

      assert {:ok, _} = ALLM.classify(engine, "x", questions: questions())
      assert [%{request: %ClassificationRequest{model: nil}}] = captured_calls()
    end

    test "engine.classification_model fills a nil request.model" do
      engine = fake_engine(classification_model: "jev-1.13.0")

      assert {:ok, %ClassificationResponse{model: "jev-1.13.0"}} =
               ALLM.classify(engine, "x", questions: questions())

      assert [%{request: %ClassificationRequest{model: "jev-1.13.0"}}] = captured_calls()
    end

    test "opts[:model] on the state path beats engine.classification_model" do
      engine = fake_engine(classification_model: "jev-slot")

      assert {:ok, _} = ALLM.classify(engine, "x", questions: questions(), model: "jev-opt")
      assert [%{request: %ClassificationRequest{model: "jev-opt"}}] = captured_calls()
    end

    test "a pre-built request's own model beats engine.classification_model" do
      engine = fake_engine(classification_model: "jev-slot")

      assert {:ok, _} =
               ALLM.classify(engine, FakeClassificationFixtures.request(model: "jev-req"))

      assert [%{request: %ClassificationRequest{model: "jev-req"}}] = captured_calls()
    end

    test "a pre-built request is authoritative: a call-site model: is not merged onto it" do
      engine = fake_engine(classification_model: "jev-slot")

      assert {:ok, _} =
               ALLM.classify(engine, FakeClassificationFixtures.request(model: "jev-req"),
                 model: "jev-opt"
               )

      assert {:ok, _} =
               ALLM.classify(engine, FakeClassificationFixtures.request(), model: "jev-opt")

      assert [
               %{request: %ClassificationRequest{model: "jev-req"}},
               %{request: %ClassificationRequest{model: "jev-slot"}}
             ] = captured_calls()
    end

    test "a non-binary model on the state path is a validation error before dispatch" do
      engine = fake_engine()

      assert {:error, %ValidationError{} = err} =
               ALLM.classify(engine, "x", questions: questions(), model: {:bad})

      assert {:model, :invalid_shape} in err.errors
      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — opts plumbing
  # ---------------------------------------------------------------------------

  describe "classify/3 opts" do
    test "request-field opts are not forwarded as dispatch opts; unknown opts are" do
      engine = fake_engine()

      assert {:ok, _} =
               ALLM.classify(engine, "x",
                 questions: questions(),
                 model: "jev-1.13.0",
                 metadata: %{t: 1},
                 options: %{o: 1},
                 request_timeout: 1234,
                 provider_knob: :on
               )

      assert [%{request: request, opts: opts}] = captured_calls()
      assert request.metadata == %{t: 1}
      assert request.options == %{o: 1}

      for key <- [:questions, :model, :options, :metadata] do
        refute Keyword.has_key?(opts, key), "#{inspect(key)} leaked into dispatch opts"
      end

      assert Keyword.get(opts, :request_timeout) == 1234
      assert Keyword.get(opts, :provider_knob) == :on
      refute Keyword.has_key?(opts, :retry_policy)
    end

    test "stream: true is silently dropped" do
      engine = fake_engine()

      assert {:ok, _} = ALLM.classify(engine, "x", questions: questions(), stream: true)

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
    end

    test "opts[:request_id] reaches the adapter and the response" do
      engine = fake_engine()

      assert {:ok, %ClassificationResponse{request_id: "rid-explicit"}} =
               ALLM.classify(engine, "x", questions: questions(), request_id: "rid-explicit")

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_id) == "rid-explicit"
    end

    test "a generated request_id lands on the response when none is given" do
      assert {:ok, %ClassificationResponse{request_id: rid}} =
               ALLM.classify(fake_engine(), "x", questions: questions())

      assert is_binary(rid) and rid != ""
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — cursor isolation (the shared dispatch-opts builder)
  # ---------------------------------------------------------------------------

  describe "classify/3 cursor" do
    test "two content-equal engines with distinct ids read independent cursors" do
      script = [
        classification_script: [
          {:answers, %{"d" => "technical"}},
          {:answers, %{"d" => "sales"}}
        ]
      ]

      a = Engine.new(classification_adapter: FakeClassification, adapter_opts: script, id: 1)
      b = Engine.new(classification_adapter: FakeClassification, adapter_opts: script, id: 2)

      choice = fn engine ->
        {:ok, resp} = ALLM.classify(engine, "x", questions: questions())
        ClassificationResponse.answer(resp, "d").choice
      end

      # Interleaved, exactly two calls per two-entry script. Falsifier: a
      # shared cursor hands engine B entry 2 on its first call.
      assert choice.(a) == "technical"
      assert choice.(b) == "technical"
      assert choice.(a) == "sales"
      assert choice.(b) == "sales"
    end
  end

  # ---------------------------------------------------------------------------
  # classify/3 — retry and invariant enforcement
  # ---------------------------------------------------------------------------

  describe "classify/3 retry" do
    test "a retryable scripted error is retried and then succeeds" do
      engine =
        fake_engine(
          retry: @fast_retry,
          adapter_opts: [
            classification_script: [{:error, rate_limited()}, {:answers, %{"d" => "sales"}}]
          ]
        )

      assert {:ok, resp} = ALLM.classify(engine, "x", questions: questions())
      assert ClassificationResponse.answer(resp, "d").choice == "sales"
    end

    test "retry: false surfaces the first error" do
      engine =
        fake_engine(retry: false, adapter_opts: [classification_script: [{:error, rate_limited()}]])

      assert {:error, %ClassificationAdapterError{reason: :rate_limited}} =
               ALLM.classify(engine, "x", questions: questions())
    end

    test ":invalid_request is not retried" do
      err = ClassificationAdapterError.new(:invalid_request, message: "nope")

      engine =
        fake_engine(retry: @fast_retry, adapter_opts: [classification_script: [{:error, err}]])

      assert {:error, %ClassificationAdapterError{reason: :invalid_request}} =
               ALLM.classify(engine, "x", questions: questions())

      assert length(captured_calls()) == 1
    end

    test "an adapter returning a bare struct raises ArgumentError naming the adapter and invariant 1" do
      engine = Engine.new(classification_adapter: BareMapAdapter)

      assert_raise ArgumentError, ~r/BareMapAdapter.*invariant 1/s, fn ->
        ALLM.classify(engine, "x", questions: questions())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "classify/3 telemetry" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :classify, :start],
          [:allm, :classify, :stop],
          [:allm, :classify, :exception]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":start carries question_count; :stop ok carries answer_count and usage" do
      engine = fake_engine(classification_model: "jev-slot", model: "gpt-x")

      assert {:ok, resp} = ALLM.classify(engine, "x", questions: questions(), request_id: "rid-t")

      assert [
               {[:allm, :classify, :start], _start_m, start_md},
               {[:allm, :classify, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.request_id == "rid-t"
      assert start_md.engine == engine
      assert start_md.model == "jev-slot"
      assert start_md.question_count == 3

      assert is_integer(stop_m.duration)
      assert stop_m.answer_count == 3
      assert stop_md.question_count == 3
      assert stop_md.usage == resp.usage
      assert stop_md.response == resp
      assert stop_md.error == nil
    end

    test ":start model is nil when neither the request nor the slot names one" do
      assert {:ok, _} = ALLM.classify(fake_engine(model: "gpt-x"), "x", questions: questions())

      assert [{[:allm, :classify, :start], _, start_md} | _] = TelemetryCapture.events()
      assert start_md.model == nil
    end

    test ":stop on error carries answer_count 0 and usage nil" do
      assert {:error, %EngineError{} = err} =
               ALLM.classify(Engine.new(), "x", questions: questions())

      assert [
               {[:allm, :classify, :start], _, _},
               {[:allm, :classify, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert stop_m.answer_count == 0
      assert Map.has_key?(stop_md, :usage) and stop_md.usage == nil
      assert stop_md.response == nil
      assert stop_md.error == err
      assert stop_md.question_count == 3
    end

    test "question_count is 0 for a non-map :questions and does not raise" do
      request = %ClassificationRequest{ClassificationRequest.new(state: "x") | questions: [:q]}

      assert {:error, %ValidationError{} = err} = ALLM.classify(fake_engine(), request)
      assert err.errors == [{:questions, :invalid_shape}]

      assert [
               {[:allm, :classify, :start], _, start_md},
               {[:allm, :classify, :stop], %{answer_count: 0}, _}
             ] = TelemetryCapture.events()

      assert start_md.question_count == 0
    end

    test "question_count is 0 for a struct :questions, as stringify_question_ids/1 treats it" do
      request = %ClassificationRequest{
        ClassificationRequest.new(state: "x")
        | questions: URI.parse("https://example.com")
      }

      assert {:error, %ValidationError{}} = ALLM.classify(fake_engine(), request)

      assert [{[:allm, :classify, :start], _, start_md}, {[:allm, :classify, :stop], _, _}] =
               TelemetryCapture.events()

      assert start_md.question_count == 0
    end

    test ":exception fires when the adapter raises" do
      engine = Engine.new(classification_adapter: RaisingAdapter)

      assert_raise RuntimeError, "boom", fn ->
        ALLM.classify(engine, "x", questions: questions())
      end

      assert [
               {[:allm, :classify, :start], _, _},
               {[:allm, :classify, :exception], _, md}
             ] = TelemetryCapture.events()

      assert %RuntimeError{message: "boom"} = md.reason
    end
  end
end
