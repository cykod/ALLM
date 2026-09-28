defmodule ALLM.Providers.FakeClassificationTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationRequest}
  alias ALLM.{ClassificationResponse, Engine, Usage}
  alias ALLM.Error.ClassificationAdapterError
  alias ALLM.Providers.FakeClassification
  alias ALLM.Test.FakeClassificationFixtures, as: Fixtures

  doctest FakeClassification

  # Every sequence test drives classify/2 directly with an explicit cursor
  # key, so no two tests (or content-equal scripts) share a cursor slot.
  defp opts(script, extra \\ []) do
    [adapter_opts: [classification_script: script, cursor_key: make_ref()] ++ extra]
  end

  defp answer!(resp, id), do: ClassificationResponse.answer(resp, id)

  describe "classify/2 defaults (no script)" do
    test "choice picks the lexicographically first option with all probability on it" do
      q = ClassificationQuestion.choice("Pick one", ["zeta", "alpha"])
      req = ClassificationRequest.new(state: "x", questions: %{"c" => q})

      assert {:ok, resp} = FakeClassification.classify(req, [])

      assert answer!(resp, "c") ==
               ClassificationAnswer.new(
                 type: :choice,
                 choice: "alpha",
                 probabilities: %{"alpha" => 1.0, "zeta" => 0.0},
                 confidence: 1.0
               )
    end

    test "score sits at level 0 with the criteria as legend" do
      assert {:ok, resp} = FakeClassification.classify(Fixtures.request(), [])

      assert answer!(resp, "s") ==
               ClassificationAnswer.new(
                 type: :score,
                 score: 0.0,
                 probabilities: [1.0, 0.0, 0.0],
                 legend: ["Calm", "Annoyed", "Angry"],
                 confidence: 1.0
               )
    end

    test "yes_no reports yes_probability 0.0 and no confidence" do
      assert {:ok, resp} = FakeClassification.classify(Fixtures.request(), [])

      assert answer!(resp, "y") ==
               ClassificationAnswer.new(type: :yes_no, yes_probability: 0.0, confidence: nil)
    end

    test "an explicit empty script is the same as no script" do
      assert {:ok, a} = FakeClassification.classify(Fixtures.request(), [])
      assert {:ok, b} = FakeClassification.classify(Fixtures.request(), opts([]))
      assert a.answers == b.answers
    end

    test "answers every question, keyed exactly like the request" do
      assert {:ok, resp} = FakeClassification.classify(Fixtures.request(), [])
      assert Map.keys(resp.answers) |> Enum.sort() == ["d", "s", "y"]
    end

    test "a 1-level score question sent directly still gets the ordinary default" do
      q = ClassificationQuestion.score("One level", ["only"])
      req = ClassificationRequest.new(state: "x", questions: %{"s" => q})

      assert {:ok, resp} = FakeClassification.classify(req, [])
      a = answer!(resp, "s")
      assert {a.score, a.probabilities, a.legend, a.confidence} == {0.0, [1.0], ["only"], 1.0}
    end
  end

  describe "classify/2 response fields" do
    test "stamps model, provider, usage, request_id, metadata, id and raw" do
      req = Fixtures.request(model: "jev-1.13.0", metadata: %{trace: "t"})

      assert {:ok, %ClassificationResponse{} = resp} =
               FakeClassification.classify(req, request_id: "rid-1")

      assert resp.model == "jev-1.13.0"
      assert resp.provider == :fake
      assert resp.usage == %Usage{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      assert resp.request_id == "rid-1"
      assert resp.metadata == %{trace: "t"}
      assert resp.id == nil
      assert resp.raw == nil
    end

    test "model falls back to \"fake-classification\" when the request has none" do
      assert {:ok, resp} = FakeClassification.classify(Fixtures.request(), [])
      assert resp.model == "fake-classification"
      assert resp.request_id == nil
    end
  end

  describe "{:answers, map} entries" do
    test "a binary sets a choice answer and other ids keep their defaults" do
      assert {:ok, resp} =
               FakeClassification.classify(
                 Fixtures.request(),
                 opts([{:answers, %{"d" => "technical"}}])
               )

      d = answer!(resp, "d")
      assert d.choice == "technical"
      assert d.probabilities == %{"billing" => 0.0, "technical" => 1.0, "sales" => 0.0}
      assert d.confidence == 1.0

      assert answer!(resp, "s").score == 0.0
      assert answer!(resp, "y").yes_probability == 0.0
    end

    test "a fractional score splits probability between the two adjacent levels" do
      assert {:ok, resp} =
               FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"s" => 1.25}}]))

      s = answer!(resp, "s")
      assert s.score == 1.25
      assert s.probabilities == [0.0, 0.75, 0.25]
      assert s.confidence == 0.75
      assert s.legend == ["Calm", "Annoyed", "Angry"]
    end

    test "an integer score becomes a float with all probability on that level" do
      assert {:ok, resp} =
               FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"s" => 1}}]))

      s = answer!(resp, "s")
      assert s.score === 1.0
      assert s.probabilities == [0.0, 1.0, 0.0]
      assert s.confidence == 1.0
    end

    test "a number sets yes_probability and leaves confidence nil" do
      assert {:ok, resp} =
               FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"y" => 0.9}}]))

      y = answer!(resp, "y")
      assert y.yes_probability == 0.9
      assert y.confidence == nil
    end

    test "an integer yes_no value is coerced to a float" do
      assert {:ok, resp} =
               FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"y" => 1}}]))

      assert answer!(resp, "y").yes_probability === 1.0
    end

    test "a %ClassificationAnswer{} is returned verbatim" do
      custom = ClassificationAnswer.new(type: :yes_no, yes_probability: 0.42, metadata: %{k: 1})

      assert {:ok, resp} =
               FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"y" => custom}}]))

      assert answer!(resp, "y") == custom
    end

    test "a choice value that is not an option raises ArgumentError naming the options" do
      assert_raise ArgumentError, ~r/"d".*billing.*sales.*technical/s, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"d" => "legal"}}]))
      end
    end

    test "a score at or past the level count raises" do
      assert_raise ArgumentError, ~r/"s"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"s" => 3}}]))
      end
    end

    test "a negative score raises" do
      assert_raise ArgumentError, ~r/"s"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"s" => -0.5}}]))
      end
    end

    test "a yes_no value above 1 raises" do
      assert_raise ArgumentError, ~r/"y"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"y" => 1.5}}]))
      end
    end

    test "a number for a choice question raises" do
      assert_raise ArgumentError, ~r/"d"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"d" => 1}}]))
      end
    end

    test "a binary for a score question raises" do
      assert_raise ArgumentError, ~r/"s"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"s" => "Angry"}}]))
      end
    end

    test "a binary for a yes_no question raises" do
      assert_raise ArgumentError, ~r/"y"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"y" => "yes"}}]))
      end
    end

    test "an id that is not a question raises" do
      assert_raise ArgumentError, ~r/"nope"/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:answers, %{"nope" => 0.5}}]))
      end
    end
  end

  describe "{:error, err} entries" do
    test "are returned verbatim" do
      assert {:error, %ClassificationAdapterError{} = err} =
               FakeClassification.classify(Fixtures.request(),
                 adapter_opts: Fixtures.rate_limited()
               )

      assert err.reason == :rate_limited
      assert err.provider == :fake
      assert err.retry_after_ms == 250
    end
  end

  describe "script sequencing" do
    test "successive calls advance through the script" do
      cursor = FakeClassification.start_script_cursor()
      script = [{:answers, %{"y" => 0.1}}, {:answers, %{"y" => 0.2}}]
      opts = [adapter_opts: [classification_script: script, script_cursor: cursor]]

      assert {:ok, first} = FakeClassification.classify(Fixtures.request(), opts)
      assert {:ok, second} = FakeClassification.classify(Fixtures.request(), opts)

      assert answer!(first, "y").yes_probability == 0.1
      assert answer!(second, "y").yes_probability == 0.2
      assert FakeClassification.cursor_index(cursor) == 2
    end

    test "an exhausted NON-EMPTY script errors rather than defaulting" do
      opts = opts([{:answers, %{}}])

      assert {:ok, _} = FakeClassification.classify(Fixtures.request(), opts)

      assert {:error, %ClassificationAdapterError{reason: :unknown, metadata: meta}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert meta.cause == :classification_script_exhausted
    end

    test "a scripted sequence of N entries answers exactly N calls" do
      opts = opts([{:answers, %{}}, {:answers, %{}}, {:answers, %{}}])

      for _ <- 1..3, do: assert({:ok, _} = FakeClassification.classify(Fixtures.request(), opts))

      assert {:error,
              %ClassificationAdapterError{metadata: %{cause: :classification_script_exhausted}}} =
               FakeClassification.classify(Fixtures.request(), opts)
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns :rate_limited until the budget is spent, then succeeds from the next entry" do
      # The leading entry is load-bearing: it forces `advance` to WRITE the
      # slot `peek` later READS. Without it an unwritten slot reads 0 on both
      # sides, so a `peek_cursor/2` keyed on a different slot than `advance`
      # stays green (mutation-checked in the Phase 24 retro, F3).
      opts = opts([{:answers, %{}}, {:retry_until_call, 3}, {:answers, %{"y" => 0.7}}])

      assert {:ok, first} = FakeClassification.classify(Fixtures.request(), opts)
      assert answer!(first, "y").yes_probability == 0.0

      assert {:error, %ClassificationAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert {:error, %ClassificationAdapterError{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert {:ok, fourth} = FakeClassification.classify(Fixtures.request(), opts)
      assert answer!(fourth, "y").yes_probability == 0.7
    end

    test "without a trailing entry the call that spends the budget is exhausted" do
      opts = opts([{:answers, %{}}, {:retry_until_call, 2}])

      assert {:ok, _} = FakeClassification.classify(Fixtures.request(), opts)

      assert {:error, %{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert {:error,
              %ClassificationAdapterError{metadata: %{cause: :classification_script_exhausted}}} =
               FakeClassification.classify(Fixtures.request(), opts)
    end

    test "consecutive retry entries chain into a layered budget" do
      script = [{:retry_until_call, 2}, {:retry_until_call, 2}, {:answers, %{"y" => 0.5}}]
      assert :ok = FakeClassification.script(script)
      opts = opts(script)

      assert {:error, %{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert {:error, %{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts)

      assert {:ok, resp} = FakeClassification.classify(Fixtures.request(), opts)
      assert answer!(resp, "y").yes_probability == 0.5
    end

    test "two content-equal-script engines with distinct :id values do not share a retry budget" do
      script = [{:retry_until_call, 2}, {:answers, %{"d" => "sales"}}]

      e1 = Fixtures.engine(classification_script: script)
      e2 = Fixtures.engine(classification_script: script)

      assert e1.adapter_opts == e2.adapter_opts
      refute e1.id == e2.id

      opts1 = [adapter_opts: Engine.put_cursor_key(e1.adapter_opts, e1)]
      opts2 = [adapter_opts: Engine.put_cursor_key(e2.adapter_opts, e2)]

      # Engine A burns its whole budget.
      assert {:error, %ClassificationAdapterError{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts1)

      assert {:ok, r1} = FakeClassification.classify(Fixtures.request(), opts1)
      assert answer!(r1, "d").choice == "sales"

      # Engine B must start from a fresh budget in the same process — a retry
      # counter keyed on :erlang.phash2(script) alone would let it skip
      # straight to the success entry.
      assert {:error, %ClassificationAdapterError{reason: :rate_limited}} =
               FakeClassification.classify(Fixtures.request(), opts2)

      assert {:ok, r2} = FakeClassification.classify(Fixtures.request(), opts2)
      assert answer!(r2, "d").choice == "sales"
    end
  end

  describe "cursor precedence" do
    test "two content-equal engines with distinct :id values do not share a cursor" do
      a = Fixtures.engine(Fixtures.answers(%{"d" => "sales"}))
      b = Fixtures.engine(Fixtures.answers(%{"d" => "sales"}))

      opts_a = [adapter_opts: Engine.put_cursor_key(a.adapter_opts, a)]
      opts_b = [adapter_opts: Engine.put_cursor_key(b.adapter_opts, b)]

      assert {:ok, r1} = FakeClassification.classify(Fixtures.request(), opts_a)
      assert {:ok, r2} = FakeClassification.classify(Fixtures.request(), opts_b)
      assert answer!(r1, "d").choice == "sales"
      assert answer!(r2, "d").choice == "sales"
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      opts = [adapter_opts: Fixtures.answers(%{"d" => "sales"})]

      assert {:ok, _} = FakeClassification.classify(Fixtures.request(), opts)

      assert {:error,
              %ClassificationAdapterError{metadata: %{cause: :classification_script_exhausted}}} =
               FakeClassification.classify(Fixtures.request(), opts)
    end

    test "an explicit :script_cursor Agent pid outranks :cursor_key" do
      cursor = FakeClassification.start_script_cursor()

      opts = [
        adapter_opts: [
          classification_script: [{:answers, %{}}, {:answers, %{}}],
          cursor_key: 7,
          script_cursor: cursor
        ]
      ]

      assert {:ok, _} = FakeClassification.classify(Fixtures.request(), opts)
      assert {:ok, _} = FakeClassification.classify(Fixtures.request(), opts)
      assert FakeClassification.cursor_index(cursor) == 2
    end
  end

  describe "empty-questions gate" do
    test "questions: %{} is :invalid_request before any script entry is consumed" do
      cursor = FakeClassification.start_script_cursor()
      opts = [adapter_opts: [classification_script: [{:answers, %{}}], script_cursor: cursor]]
      req = ClassificationRequest.new(state: "x", questions: %{})

      assert {:error, %ClassificationAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeClassification.classify(req, opts)

      assert meta.field == :questions
      assert FakeClassification.cursor_index(cursor) == 0
    end
  end

  describe "capture_pid seam" do
    test "receives the request, including for a gate-rejected call" do
      req = ClassificationRequest.new(state: "x", questions: %{})
      opts = [adapter_opts: [capture_pid: self()]]

      assert {:error, %ClassificationAdapterError{reason: :invalid_request}} =
               FakeClassification.classify(req, opts)

      assert_receive {FakeClassification, :call, %{request: ^req, opts: ^opts}}
    end

    test "fires once per call on the happy path" do
      assert {:ok, _} =
               FakeClassification.classify(Fixtures.request(), adapter_opts: [capture_pid: self()])

      assert_receive {FakeClassification, :call, _}
      refute_receive {FakeClassification, :call, _}, 20
    end
  end

  describe "script/1" do
    test "accepts every documented entry shape" do
      assert :ok =
               FakeClassification.script([
                 {:answers, %{"d" => "billing"}},
                 {:error, ClassificationAdapterError.new(:timeout)},
                 {:retry_until_call, 2}
               ])
    end

    test "classify/2 raises ArgumentError on an unrecognized entry it reaches" do
      assert_raise ArgumentError, ~r/invalid FakeClassification script entry/, fn ->
        FakeClassification.classify(Fixtures.request(), opts([{:ok, []}]))
      end
    end

    test "classify/2 raises ArgumentError on a malformed {:retry_until_call, n} it reaches" do
      for bad <- [:x, 2.5, 0, -1], position <- [:leading, :chained] do
        script =
          case position do
            :leading -> [{:retry_until_call, bad}, {:answers, %{}}]
            :chained -> [{:retry_until_call, 1}, {:retry_until_call, bad}, {:answers, %{}}]
          end

        assert_raise ArgumentError, ~r/invalid FakeClassification script entry/, fn ->
          FakeClassification.classify(Fixtures.request(), opts(script))
        end
      end
    end

    test "raises ArgumentError on an unrecognized entry" do
      assert_raise ArgumentError, ~r/invalid FakeClassification script entry/, fn ->
        FakeClassification.script([{:ok, []}])
      end
    end
  end
end
