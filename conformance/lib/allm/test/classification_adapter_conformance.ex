defmodule ALLM.Test.ClassificationAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.ClassificationAdapter`
  implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyClassificationAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.ClassificationAdapterConformance,
          classification_adapter: MyClassificationAdapter
      end

  Injects a
  `describe "ALLM.ClassificationAdapter conformance (MyClassificationAdapter)"`
  block with 9 deterministic cases. Every case sends one request carrying one
  question of each type (`:choice`, `:score`, `:yes_no`).

  ## Script contract

  Cases 1–5 and 7–9 each pass an explicit
  `adapter_opts: [classification_script: [{:answers, %{}}]]` — one entry that
  yields the default answers. See `ALLM.Providers.FakeClassification`'s
  `script/1` for the grammar. Case 6 passes **no** script.

  An adapter under test therefore either answers the scripted call itself,
  or short-circuits any non-nil `:classification_script` value to a Fake.
  Without that, the scripted cases would reach credential resolution and the
  network.

  ## Cases

    1. answer keys equal question keys (behaviour invariant 2)
    2. each answer's type equals its question's type (invariant 3)
    3. `:choice` answer fields (invariant 4 and the field table)
    4. `:score` answer fields (invariant 5 and the field table)
    5. `:yes_no` answer fields, `confidence == nil` (the field table)
    6. `questions: %{}` with no script and no `:api_key` is rejected with
       `:invalid_request` (invariant 6). A harness cannot unset environment
       variables from an async case, so this case binds the *outcome* only;
       the "before I/O and before the key" ordering is each adapter's own
       test to write.
    7. `request.metadata` round-trips unchanged (invariant 7)
    8. `opts[:request_id]` is preserved (invariant 7)
    9. `response.usage` is a `%ALLM.Usage{}`

  ## What this suite does NOT bind

    * **Invariant 1** (exactly two return shapes) is checked where the
      adapter is dispatched, outside every adapter, so no conformance run can
      observe it. Convert every failure shape; the suite will not tell you if
      you did not.
    * **Invariant 8** (`opts[:request_timeout]`).
    * For an adapter that short-circuits to a script —
      `ALLM.Providers.FakeClassification` itself, and any provider adapter
      that hands a scripted call to it — cases 1–5 and 7–9 exercise the
      **Fake**, not that adapter's response decoder. Invariants 2–5 for a
      real provider are the job of its own decoder tests over recorded wire
      fixtures. **Do not read a green run of this suite as evidence that a
      provider's decoder is correct.**

  Every case asserts unconditionally: none is gated on a fixture that lives
  inside `allm_conformance`'s own test tree, because a case body wrapped in
  `if fixture = optional() do ... end` compiles to an assertion-free test that
  ExUnit reports green.

  ## Why the helpers below take and return plain data

  This package is compiled *before* `allm` in a consuming project's build, so
  the harness module body must not reference `ALLM.*` functions directly —
  every such call happens inside the `using/1` `quote`, which expands at the
  consumer's compile time when `allm` is loaded.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  @case_count 9

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  @doc false
  @spec unit_float?(term()) :: boolean()
  def unit_float?(x), do: is_float(x) and x >= 0.0 and x <= 1.0

  # The per-type field assertions live outside the `quote` (Credo's long-quote
  # limit) and touch answers by field access only, never by struct pattern, so
  # this module body names no `ALLM.*` module.

  @doc false
  @spec assert_choice_fields(map(), [String.t()]) :: true
  def assert_choice_fields(answer, options) do
    assert answer.choice in options
    assert answer.probabilities |> Map.keys() |> Enum.sort() == Enum.sort(options)
    assert Enum.all?(Map.values(answer.probabilities), &unit_float?/1)
    assert unit_float?(answer.confidence)
    assert {answer.score, answer.yes_probability, answer.legend} == {nil, nil, nil}
  end

  @doc false
  @spec assert_score_fields(map(), list()) :: true
  def assert_score_fields(answer, levels) do
    assert is_float(answer.score)
    assert answer.score >= 0.0 and answer.score <= length(levels) - 1
    assert is_list(answer.probabilities)
    assert length(answer.probabilities) == length(levels)
    assert Enum.all?(answer.probabilities, &unit_float?/1)
    assert is_list(answer.legend)
    assert length(answer.legend) == length(levels)
    assert unit_float?(answer.confidence)
    assert {answer.choice, answer.yes_probability} == {nil, nil}
  end

  @doc false
  @spec assert_yes_no_fields(map()) :: true
  def assert_yes_no_fields(answer) do
    assert unit_float?(answer.yes_probability)
    assert answer.confidence == nil

    assert {answer.choice, answer.score, answer.probabilities, answer.legend} ==
             {nil, nil, nil, nil}
  end

  using opts do
    quote location: :keep do
      @__allm_cls_adapter__ Keyword.fetch!(unquote(opts), :classification_adapter)

      # One question of each type, sent by every case except 6.
      @__allm_cls_request__ ALLM.ClassificationRequest.new(
                              state: "My payouts failed twice this week.",
                              questions: %{
                                "team" =>
                                  ALLM.ClassificationQuestion.choice(
                                    "Which team should handle this?",
                                    ["billing", "technical", "sales"]
                                  ),
                                "frustration" =>
                                  ALLM.ClassificationQuestion.score(
                                    "How frustrated is the customer?",
                                    ["Calm", "Annoyed", "Angry"]
                                  ),
                                "refund" =>
                                  ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
                              }
                            )

      # The script contract: one entry that yields the default answers.
      @__allm_cls_opts__ [adapter_opts: [classification_script: [{:answers, %{}}]]]

      describe "ALLM.ClassificationAdapter conformance (#{inspect(@__allm_cls_adapter__)})" do
        alias ALLM.{ClassificationAnswer, ClassificationRequest, ClassificationResponse}
        alias ALLM.Error.ClassificationAdapterError
        alias ALLM.Test.ClassificationAdapterConformance, as: Harness

        test "1. answer keys equal question keys" do
          req = @__allm_cls_request__

          assert {:ok, %ClassificationResponse{answers: answers}} =
                   @__allm_cls_adapter__.classify(req, @__allm_cls_opts__)

          assert MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(req.questions))
        end

        test "2. each answer's type equals its question's type" do
          req = @__allm_cls_request__

          assert {:ok, %ClassificationResponse{answers: answers}} =
                   @__allm_cls_adapter__.classify(req, @__allm_cls_opts__)

          for {id, question} <- req.questions do
            assert %ClassificationAnswer{type: type} = Map.fetch!(answers, id)
            assert type == question.type
          end
        end

        test "3. a :choice answer picks an option and carries one probability per option" do
          req = @__allm_cls_request__
          assert {:ok, resp} = @__allm_cls_adapter__.classify(req, @__allm_cls_opts__)

          Harness.assert_choice_fields(
            ClassificationResponse.answer(resp, "team"),
            Map.keys(req.questions["team"].criteria)
          )
        end

        test "4. a :score answer carries one probability and one legend entry per level" do
          req = @__allm_cls_request__
          assert {:ok, resp} = @__allm_cls_adapter__.classify(req, @__allm_cls_opts__)

          Harness.assert_score_fields(
            ClassificationResponse.answer(resp, "frustration"),
            req.questions["frustration"].criteria
          )
        end

        test "5. a :yes_no answer carries yes_probability and no confidence" do
          assert {:ok, resp} =
                   @__allm_cls_adapter__.classify(@__allm_cls_request__, @__allm_cls_opts__)

          Harness.assert_yes_no_fields(ClassificationResponse.answer(resp, "refund"))
        end

        test "6. questions: %{} is rejected with :invalid_request" do
          # No script (a scripted adapter short-circuits ahead of its gates) and
          # no :api_key (the gate must not need a credential).
          req = ClassificationRequest.new(state: "x", questions: %{})

          assert {:error, %ClassificationAdapterError{reason: :invalid_request}} =
                   @__allm_cls_adapter__.classify(req, [])
        end

        test "7. round-trips request.metadata onto response.metadata unchanged" do
          metadata = %{trace_id: "abc", user: "alice"}
          req = %{@__allm_cls_request__ | metadata: metadata}

          assert {:ok, %ClassificationResponse{metadata: ^metadata}} =
                   @__allm_cls_adapter__.classify(req, @__allm_cls_opts__)
        end

        test "8. preserves opts[:request_id] onto ClassificationResponse.request_id" do
          opts = [{:request_id, "test-id-123"} | @__allm_cls_opts__]

          assert {:ok, %ClassificationResponse{request_id: "test-id-123"}} =
                   @__allm_cls_adapter__.classify(@__allm_cls_request__, opts)
        end

        test "9. response.usage is an %ALLM.Usage{}" do
          assert {:ok, %ClassificationResponse{usage: %ALLM.Usage{}}} =
                   @__allm_cls_adapter__.classify(@__allm_cls_request__, @__allm_cls_opts__)
        end
      end
    end
  end
end
