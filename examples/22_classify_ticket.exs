# examples/22_classify_ticket.exs
#
# Provider: typesafe
#
# Typed classification is a single-provider capability: TypeSafe's Jev is the
# only bundled classification adapter, and it has no chat adapter. The marker
# makes `run_all.exs` run this script on the `typesafe` arm only and SKIP it
# on every other arm instead of halting on `classification_engine/1`'s
# ArgumentError.
#
# Demonstrates: `ALLM.classify/3` with one question of each type in ONE call
#               against one support ticket — a `choice/2` (which team), a
#               `score/2` (how frustrated, three levels) and a `yes_no/2` (is
#               a refund requested). Asserts a typed answer per question type
#               (the field-population table in `ALLM.ClassificationAnswer`),
#               that the response carries the provider's request id and the
#               versioned model that answered, and that usage is populated.
#               Prints each answer with its confidence.
# Spec section: §41.5 (public API), §41.2.3 (answer shape), §41.7 (TypeSafe).
# Steering strategy: tight on shape, loose on the classifier. Every field of
#                    every answer is checked for type and range. Two verdicts
#                    are asserted because a classifier that misses them is
#                    broken rather than differently tuned: a ticket about a
#                    double charge that asks for the money back routes to
#                    "billing" and scores a refund probability above 0.5.
#                    The frustration level and every probability value are the
#                    model's to change and are only printed.
# Cost: well under $0.0001 USD. About 400 input tokens at $0.042 per million;
#       output tokens are free.
# Run with:    TYPESAFE_API_KEY=... ALLM_PROVIDER=typesafe mix run examples/22_classify_ticket.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationResponse}

engine = ExamplesHelpers.classification_engine()

ticket = """
Hi, I was charged twice for my March subscription — two identical payments
went out on the 3rd. I've emailed about this already and nobody replied.
Please refund the duplicate charge.
"""

teams = ["billing", "technical", "sales"]
levels = ["calm", "annoyed", "furious"]

questions = %{
  "department" => ClassificationQuestion.choice("Which team should handle this ticket?", teams),
  "frustration" => ClassificationQuestion.score("How frustrated is the customer?", levels),
  "refund" =>
    ClassificationQuestion.yes_no("Is the customer asking for a refund?",
      true: "the customer asks for money back"
    )
}

unit? = fn x -> is_float(x) and x >= 0.0 and x <= 1.0 end

check_choice = fn %ClassificationAnswer{} = a ->
  cond do
    a.type != :choice -> "department: type #{inspect(a.type)}, want :choice"
    a.choice not in teams -> "department: choice #{inspect(a.choice)} is not an option"
    not is_map(a.probabilities) -> "department: probabilities #{inspect(a.probabilities)}"
    Enum.sort(Map.keys(a.probabilities)) != Enum.sort(teams) -> "department: probability keys"
    not Enum.all?(Map.values(a.probabilities), unit?) -> "department: a probability is off [0, 1]"
    not unit?.(a.confidence) -> "department: confidence #{inspect(a.confidence)}"
    not is_nil(a.score) or not is_nil(a.yes_probability) -> "department: foreign fields set"
    true -> :ok
  end
end

check_score = fn %ClassificationAnswer{} = a ->
  cond do
    a.type != :score ->
      "frustration: type #{inspect(a.type)}, want :score"

    not (is_float(a.score) and a.score >= 0.0 and a.score <= 2.0) ->
      "frustration: score #{inspect(a.score)}"

    not is_list(a.probabilities) or length(a.probabilities) != 3 ->
      "frustration: probabilities #{inspect(a.probabilities)}"

    not Enum.all?(a.probabilities, unit?) ->
      "frustration: a probability is off [0, 1]"

    a.legend != levels ->
      "frustration: legend #{inspect(a.legend)}, want the levels echoed"

    not unit?.(a.confidence) ->
      "frustration: confidence #{inspect(a.confidence)}"

    not is_nil(a.choice) or not is_nil(a.yes_probability) ->
      "frustration: foreign fields set"

    true ->
      :ok
  end
end

check_yes_no = fn %ClassificationAnswer{} = a ->
  cond do
    a.type != :yes_no ->
      "refund: type #{inspect(a.type)}, want :yes_no"

    not unit?.(a.yes_probability) ->
      "refund: yes_probability #{inspect(a.yes_probability)}"

    not is_nil(a.confidence) ->
      "refund: confidence must be nil, got #{inspect(a.confidence)}"

    not is_nil(a.choice) or not is_nil(a.score) or not is_nil(a.probabilities) ->
      "refund: foreign fields set"

    true ->
      :ok
  end
end

case ALLM.classify(engine, ticket, questions: questions) do
  {:ok, %ClassificationResponse{} = resp} ->
    department = ClassificationResponse.answer(resp, "department")
    frustration = ClassificationResponse.answer(resp, "frustration")
    refund = ClassificationResponse.answer(resp, "refund")

    if Enum.sort(Map.keys(resp.answers)) != ["department", "frustration", "refund"] do
      ExamplesHelpers.fail!(
        "expected one answer per question, got #{inspect(Map.keys(resp.answers))}"
      )
    end

    Enum.each([check_choice.(department), check_score.(frustration), check_yes_no.(refund)], fn
      :ok -> :ok
      msg -> ExamplesHelpers.fail!(msg)
    end)

    cond do
      department.choice != "billing" ->
        ExamplesHelpers.fail!(
          "a double-charge refund ticket should route to billing, got #{inspect(department.choice)} " <>
            "(probabilities #{inspect(department.probabilities)})"
        )

      refund.yes_probability <= 0.5 ->
        ExamplesHelpers.fail!(
          "an explicit refund request scored P(yes) = #{refund.yes_probability}"
        )

      not (is_binary(resp.id) and resp.id != "") ->
        ExamplesHelpers.fail!(
          "expected the x-typesafe-request-id on response.id, got #{inspect(resp.id)}"
        )

      not (is_binary(resp.model) and String.starts_with?(resp.model, "jev-")) ->
        ExamplesHelpers.fail!("expected a jev- model id, got #{inspect(resp.model)}")

      not (is_integer(resp.usage.input_tokens) and resp.usage.input_tokens > 0) ->
        ExamplesHelpers.fail!("expected usage.input_tokens > 0, got #{inspect(resp.usage)}")

      true ->
        level = Enum.at(levels, round(frustration.score))

        IO.puts(
          "OK: classify ticket — department=#{department.choice} " <>
            "(confidence #{Float.round(department.confidence, 3)}) " <>
            "frustration=#{Float.round(frustration.score, 3)} ~#{level} " <>
            "(confidence #{Float.round(frustration.confidence, 3)}) " <>
            "refund P(yes)=#{Float.round(refund.yes_probability, 3)} " <>
            "model=#{inspect(resp.model)} id=#{inspect(resp.id)} " <>
            "input_tokens=#{resp.usage.input_tokens}"
        )
    end

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.classify/3 returned error #{inspect(error)}")
end
