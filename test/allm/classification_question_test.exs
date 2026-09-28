defmodule ALLM.ClassificationQuestionTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationQuestion, Serializer}

  doctest ALLM.ClassificationQuestion

  describe "new/1" do
    test "defaults every field to nil" do
      q = ClassificationQuestion.new()
      assert q.type == nil
      assert q.instructions == nil
      assert q.criteria == nil
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ClassificationQuestion.new(bogus: 1) end
    end
  end

  describe "choice/2" do
    test "a list of names builds a string-keyed map with nil descriptions" do
      q = ClassificationQuestion.choice("Which team?", ["billing", :technical])

      assert q.type == :choice
      assert q.instructions == "Which team?"
      assert q.criteria == %{"billing" => nil, "technical" => nil}
    end

    test "an atom-keyed map stringifies the keys and keeps the descriptions" do
      q = ClassificationQuestion.choice("Which team?", %{"sales" => nil, billing: "Payments"})
      assert q.criteria == %{"billing" => "Payments", "sales" => nil}
    end

    test "names that collide once stringified raise ArgumentError instead of merging" do
      assert_raise ArgumentError, ~r/collide/, fn ->
        ClassificationQuestion.choice("q", [:billing, "billing"])
      end

      assert_raise ArgumentError, ~r/collide/, fn ->
        ClassificationQuestion.choice("q", %{"billing" => "b", billing: "a"})
      end
    end

    test "repeating the identical name in a list is harmless" do
      assert ClassificationQuestion.choice("q", ["billing", "billing"]).criteria ==
               %{"billing" => nil}
    end

    test "a binary options argument raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        ClassificationQuestion.choice("Which team?", "billing")
      end
    end
  end

  describe "score/2" do
    test "keeps the level order verbatim" do
      q = ClassificationQuestion.score("How angry?", ["Calm", "Frustrated", "Very angry"])
      assert q.type == :score
      assert q.criteria == ["Calm", "Frustrated", "Very angry"]
    end

    test "a map raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        ClassificationQuestion.score("How angry?", %{"0" => "Calm"})
      end
    end
  end

  describe "yes_no/2" do
    test "with no opts has criteria: nil" do
      q = ClassificationQuestion.yes_no("Is a refund requested?")
      assert q.type == :yes_no
      assert q.criteria == nil
    end

    test "true:/false: build a string-keyed subset" do
      assert ClassificationQuestion.yes_no("Refund?", true: "Asks for money back").criteria ==
               %{"true" => "Asks for money back"}

      assert ClassificationQuestion.yes_no("Refund?", true: "yes", false: "no").criteria ==
               %{"true" => "yes", "false" => "no"}
    end

    test "an unknown opt raises ArgumentError naming the offending key" do
      err =
        assert_raise ArgumentError, fn ->
          ClassificationQuestion.yes_no("Refund?", maybe: "x")
        end

      assert Exception.message(err) =~ "maybe"
    end
  end

  describe "serializability" do
    for {label, q} <- [
          {"choice", Macro.escape(ClassificationQuestion.choice("Team?", ["a", "b"]))},
          {"score", Macro.escape(ClassificationQuestion.score("Level?", ["low", "high"]))},
          {"yes_no", Macro.escape(ClassificationQuestion.yes_no("Refund?", true: "t"))},
          {"structured instructions",
           Macro.escape(
             ClassificationQuestion.choice(%{"task" => "route", "rules" => ["x"]}, %{
               "a" => %{"when" => "billing"}
             })
           )}
        ] do
      test "a #{label} question round-trips through term_to_binary and JSON" do
        q = unquote(q)
        assert q == q |> :erlang.term_to_binary() |> :erlang.binary_to_term()
        assert {:ok, ^q} = q |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    test "the :type survives as an atom" do
      q = ClassificationQuestion.yes_no("Refund?")
      {:ok, decoded} = q |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.type == :yes_no
    end
  end
end
