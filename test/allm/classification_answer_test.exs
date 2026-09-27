defmodule ALLM.ClassificationAnswerTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationAnswer, Serializer}

  doctest ALLM.ClassificationAnswer

  describe "new/1" do
    test "without :type raises ArgumentError" do
      assert_raise ArgumentError, fn -> ClassificationAnswer.new(choice: "billing") end
    end

    test "defaults metadata to %{} and every other field to nil" do
      a = ClassificationAnswer.new(type: :yes_no)
      assert a.metadata == %{}
      assert a.choice == nil
      assert a.confidence == nil
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ClassificationAnswer.new(type: :choice, bogus: 1) end
    end
  end

  describe "value/1" do
    test "a :choice answer returns the option name" do
      assert ClassificationAnswer.value(ClassificationAnswer.new(type: :choice, choice: "billing")) ==
               "billing"
    end

    test "a :score answer returns the position" do
      assert ClassificationAnswer.value(ClassificationAnswer.new(type: :score, score: 1.05)) ==
               1.05
    end

    test "a :yes_no answer returns P(yes)" do
      assert ClassificationAnswer.value(
               ClassificationAnswer.new(type: :yes_no, yes_probability: 0.91)
             ) == 0.91
    end
  end

  describe "serializability" do
    for {label, a} <- [
          {"choice",
           Macro.escape(
             ClassificationAnswer.new(
               type: :choice,
               choice: "billing",
               probabilities: %{"billing" => 0.6229826361043894, "sales" => 0.3770173638956106},
               confidence: 0.81
             )
           )},
          {"score",
           Macro.escape(
             ClassificationAnswer.new(
               type: :score,
               score: 1.05,
               probabilities: [0.0, 0.95, 0.05],
               legend: ["Calm", %{"label" => "Frustrated"}, "Very angry"],
               confidence: 0.3770173638956106
             )
           )},
          {"yes_no",
           Macro.escape(
             ClassificationAnswer.new(
               type: :yes_no,
               yes_probability: 0.3770173638956106,
               metadata: %{"k" => "v"}
             )
           )}
        ] do
      test "a #{label} answer round-trips through term_to_binary and JSON as identity" do
        a = unquote(a)
        assert a == a |> :erlang.term_to_binary() |> :erlang.binary_to_term()
        assert {:ok, ^a} = a |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    test "__from_tagged__/1 does not coerce integer probabilities" do
      decoded =
        ClassificationAnswer.__from_tagged__(%{"type" => "score", "probabilities" => [0, 1]})

      assert decoded.type == :score
      assert decoded.probabilities == [0, 1]
      assert decoded.metadata == %{}
    end
  end
end
