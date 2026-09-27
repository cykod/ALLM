defmodule ALLM.ValidateClassificationRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationQuestion, ClassificationRequest, Validate}

  @choice ClassificationQuestion.choice("Which team?", ["billing", "technical"])
  @score ClassificationQuestion.score("How angry?", ["Calm", "Frustrated", "Very angry"])
  @yes_no ClassificationQuestion.yes_no("Refund requested?", true: "asks for money back")

  defp valid_opts, do: [state: "My payouts failed.", questions: %{"department" => @choice}]

  defp errors_for(opts) do
    opts = Keyword.merge(valid_opts(), opts)
    {:error, err} = Validate.classification_request(struct!(ClassificationRequest, opts))
    assert err.reason == :invalid_classification_request
    err.errors
  end

  defp question_errors(question, id \\ "q") do
    errors_for(questions: %{id => question})
  end

  describe "classification_request/1 — happy path" do
    test ":ok for one question of each type" do
      req =
        ClassificationRequest.new(
          state: "My payouts failed.",
          model: "jev-1.13.0",
          questions: %{"department" => @choice, "anger" => @score, "refund" => @yes_no}
        )

      assert Validate.classification_request(req) == :ok
    end

    test ":ok for a map state and a list state" do
      for state <- [%{"ticket" => "hi"}, ["first message", "second message"]] do
        req = ClassificationRequest.new(state: state, questions: %{"q" => @yes_no})
        assert Validate.classification_request(req) == :ok
      end
    end

    test ":ok for structured-object instructions and described options" do
      q =
        ClassificationQuestion.choice(%{"task" => "route"}, %{"a" => %{"when" => "x"}, "b" => nil})

      assert Validate.classification_request(
               ClassificationRequest.new(state: "s", questions: %{"q" => q})
             ) == :ok
    end

    test ":ok for a yes_no question with an empty criteria map" do
      q = %ClassificationQuestion{type: :yes_no, instructions: "x", criteria: %{}}

      assert Validate.classification_request(
               ClassificationRequest.new(state: "s", questions: %{"q" => q})
             ) == :ok
    end

    test "a choice with 300 options passes — provider caps live in the adapter" do
      q = ClassificationQuestion.choice("Pick one", Enum.map(1..300, &"opt#{&1}"))

      assert Validate.classification_request(
               ClassificationRequest.new(state: "s", questions: %{"q" => q})
             ) == :ok
    end

    test "state: [1, %{}] passes — list-element text checks live in the adapter" do
      req = ClassificationRequest.new(state: [1, %{}], questions: %{"q" => @yes_no})
      assert Validate.classification_request(req) == :ok
    end
  end

  # One test per row of the field-error vocabulary table.
  describe "classification_request/1 — field-error vocabulary" do
    test "questions: [] hard-rejects with exactly [{:questions, :invalid_shape}]" do
      assert errors_for(questions: [], state: nil, model: 42) == [{:questions, :invalid_shape}]
    end

    test "questions: %{} yields {:questions, :empty}" do
      assert errors_for(questions: %{}) == [{:questions, :empty}]
    end

    for bad <- [42, :atom, {1, 2}] do
      test "state: #{inspect(bad)} yields {:state, :invalid_shape}" do
        assert errors_for(state: unquote(Macro.escape(bad))) == [{:state, :invalid_shape}]
      end
    end

    test "a struct state yields {:state, :invalid_shape}" do
      assert errors_for(state: %ALLM.ModerationRequest{}) == [{:state, :invalid_shape}]
    end

    test "a non-empty keyword-list state yields {:state, :invalid_shape}" do
      assert errors_for(state: [questions: %{}]) == [{:state, :invalid_shape}]
    end

    for empty <- [nil, "", %{}, []] do
      test "state: #{inspect(empty)} yields {:state, :empty}, not :invalid_shape" do
        assert errors_for(state: unquote(Macro.escape(empty))) == [{:state, :empty}]
      end
    end

    test "state with a tuple value yields {:state, :not_json_encodable}" do
      assert errors_for(state: %{"a" => {1, 2}}) == [{:state, :not_json_encodable}]
    end

    test "state with a tuple key yields {:state, :not_json_encodable} without raising" do
      # Jason raises Protocol.UndefinedError on a non-stringable key rather
      # than returning an error tuple; the validator must still return.
      assert errors_for(state: %{{1, 2} => "x"}) == [{:state, :not_json_encodable}]
    end

    test "model: 42 yields {:model, :invalid_shape}" do
      assert errors_for(model: 42) == [{:model, :invalid_shape}]
    end

    test "an atom question id yields {[:questions, id], :invalid_id}" do
      assert errors_for(questions: %{department: @choice}) ==
               [{[:questions, :department], :invalid_id}]
    end

    test "an empty-string question id yields {[:questions, \"\"], :invalid_id}" do
      assert errors_for(questions: %{"" => @choice}) == [{[:questions, ""], :invalid_id}]
    end

    test "a non-question value yields {[:questions, id], :invalid_question}" do
      assert question_errors(%{"type" => "choice"}) == [{[:questions, "q"], :invalid_question}]
    end

    test "an unknown type yields :invalid_type and no criteria errors" do
      q = %ClassificationQuestion{type: :rank, instructions: "x", criteria: 42}
      assert question_errors(q) == [{[:questions, "q", :type], :invalid_type}]
    end

    test "a nil type yields :invalid_type" do
      q = %ClassificationQuestion{type: nil, instructions: "x"}
      assert question_errors(q) == [{[:questions, "q", :type], :invalid_type}]
    end

    for empty <- [nil, "", %{}, []] do
      test "instructions: #{inspect(empty)} yields {[:questions, id, :instructions], :empty}" do
        q = %ClassificationQuestion{type: :yes_no, instructions: unquote(Macro.escape(empty))}
        assert question_errors(q) == [{[:questions, "q", :instructions], :empty}]
      end
    end

    test "instructions: 42 yields {[:questions, id, :instructions], :invalid_shape}" do
      q = %ClassificationQuestion{type: :yes_no, instructions: 42}
      assert question_errors(q) == [{[:questions, "q", :instructions], :invalid_shape}]
    end

    test "struct or keyword-list instructions yield :invalid_shape, as for :state" do
      for bad <- [%ALLM.Message{role: :user, content: "x"}, [text: "x"]] do
        q = %ClassificationQuestion{type: :yes_no, instructions: bad}
        assert question_errors(q) == [{[:questions, "q", :instructions], :invalid_shape}]
      end
    end

    test "choice criteria that is not a map yields :invalid_shape" do
      q = %ClassificationQuestion{type: :choice, instructions: "x", criteria: ["a", "b"]}
      assert question_errors(q) == [{[:questions, "q", :criteria], :invalid_shape}]
    end

    test "score criteria that is not a list yields :invalid_shape" do
      q = %ClassificationQuestion{type: :score, instructions: "x", criteria: %{"0" => "low"}}
      assert question_errors(q) == [{[:questions, "q", :criteria], :invalid_shape}]
    end

    test ~s(yes_no criteria with a key outside ["true", "false"] yields :invalid_shape) do
      q = %ClassificationQuestion{type: :yes_no, instructions: "x", criteria: %{"maybe" => "?"}}
      assert question_errors(q) == [{[:questions, "q", :criteria], :invalid_shape}]
    end

    test "yes_no criteria that is neither nil nor a map yields :invalid_shape" do
      q = %ClassificationQuestion{type: :yes_no, instructions: "x", criteria: "yes means yes"}
      assert question_errors(q) == [{[:questions, "q", :criteria], :invalid_shape}]
    end

    test "choice criteria %{} yields :empty" do
      q = %ClassificationQuestion{type: :choice, instructions: "x", criteria: %{}}
      assert question_errors(q) == [{[:questions, "q", :criteria], :empty}]
    end

    test "score criteria [] yields :empty" do
      q = %ClassificationQuestion{type: :score, instructions: "x", criteria: []}
      assert question_errors(q) == [{[:questions, "q", :criteria], :empty}]
    end

    test "score with exactly one level yields :too_few_levels" do
      q = ClassificationQuestion.score("x", ["only"])
      assert question_errors(q) == [{[:questions, "q", :criteria], :too_few_levels}]
    end

    test "a non-binary or empty choice key yields {[..., :criteria, option], :invalid_option}" do
      q = %ClassificationQuestion{
        type: :choice,
        instructions: "x",
        criteria: %{"ok" => nil, :atom => nil, "" => nil}
      }

      errors = question_errors(q)
      assert length(errors) == 2
      assert {[:questions, "q", :criteria, :atom], :invalid_option} in errors
      assert {[:questions, "q", :criteria, ""], :invalid_option} in errors
    end

    test "instructions with a tuple yield {[..., :instructions], :not_json_encodable}" do
      q = %ClassificationQuestion{type: :yes_no, instructions: %{"a" => {1, 2}}}
      assert question_errors(q) == [{[:questions, "q", :instructions], :not_json_encodable}]
    end

    test "an improper list yields :not_json_encodable rather than raising" do
      improper = ["a" | "b"]

      assert errors_for(state: %{"k" => improper}) == [{:state, :not_json_encodable}]

      q = %ClassificationQuestion{type: :yes_no, instructions: improper}
      assert question_errors(q) == [{[:questions, "q", :instructions], :not_json_encodable}]

      q = %ClassificationQuestion{type: :score, instructions: "x", criteria: improper}
      assert question_errors(q) == [{[:questions, "q", :criteria], :not_json_encodable}]
    end

    test "criteria with a tuple yield {[..., :criteria], :not_json_encodable}" do
      q = %ClassificationQuestion{type: :score, instructions: "x", criteria: ["low", {1, 2}]}
      assert question_errors(q) == [{[:questions, "q", :criteria], :not_json_encodable}]
    end
  end

  describe "classification_request/1 — accumulation" do
    test "two independent violations are both reported" do
      errors = errors_for(state: nil, model: 42)
      assert {:state, :empty} in errors
      assert {:model, :invalid_shape} in errors
      assert length(errors) == 2
    end

    test "violations across questions accumulate" do
      bad_type = %ClassificationQuestion{type: :rank, instructions: "x"}
      bad_instr = %ClassificationQuestion{type: :yes_no, instructions: ""}
      errors = errors_for(questions: %{"a" => bad_type, "b" => bad_instr})

      assert {[:questions, "a", :type], :invalid_type} in errors
      assert {[:questions, "b", :instructions], :empty} in errors
    end
  end
end
