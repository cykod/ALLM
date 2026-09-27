defmodule ALLM.ClassificationRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationQuestion, ClassificationRequest, Serializer}

  doctest ALLM.ClassificationRequest

  describe "new/1" do
    test "defaults state and model to nil, questions/options/metadata to %{}" do
      req = ClassificationRequest.new()
      assert req.state == nil
      assert req.model == nil
      assert req.questions == %{}
      assert req.options == %{}
      assert req.metadata == %{}
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ClassificationRequest.new(bogus: 1) end
    end

    test "questions: %{} is constructible — the validator, not the constructor, rejects it" do
      assert %ClassificationRequest{questions: %{}} = ClassificationRequest.new(questions: %{})
    end
  end

  describe "__from_tagged__/1" do
    test "missing fields fall back to their defaults" do
      decoded = ClassificationRequest.__from_tagged__(%{})
      assert decoded.state == nil
      assert decoded.questions == %{}
      assert decoded.options == %{}
      assert decoded.metadata == %{}
    end

    test "a non-map :questions passes through verbatim" do
      assert ClassificationRequest.__from_tagged__(%{"questions" => [1]}).questions == [1]
    end
  end

  describe "serializability" do
    setup do
      req =
        ClassificationRequest.new(
          # String-keyed map state: an atom-keyed map would come back with
          # string keys after a JSON round trip, as every `metadata` map does.
          state: %{"ticket" => "My payouts failed.", "tier" => "gold"},
          model: "jev-1.13.0",
          questions: %{
            "department" =>
              ClassificationQuestion.choice(%{"task" => "route the ticket"}, ["billing", "sales"]),
            "anger" => ClassificationQuestion.score("How angry?", ["Calm", "Angry"]),
            "refund" => ClassificationQuestion.yes_no("Refund?", false: "No money asked")
          },
          options: %{"x" => 1},
          metadata: %{"source" => "inbox"}
        )

      %{req: req}
    end

    test "round-trips through :erlang.term_to_binary/1", %{req: req} do
      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON with questions still structs", %{req: req} do
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()

      {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()

      for {_id, q} <- decoded.questions do
        assert %ClassificationQuestion{} = q
      end
    end

    test "a string state round-trips" do
      req = ClassificationRequest.new(state: "hello", questions: %{})
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end
  end
end
