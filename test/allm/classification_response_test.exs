defmodule ALLM.ClassificationResponseTest do
  use ExUnit.Case, async: true

  alias ALLM.{ClassificationAnswer, ClassificationResponse, Serializer, Usage}

  doctest ALLM.ClassificationResponse

  @choice ClassificationAnswer.new(
            type: :choice,
            choice: "billing",
            probabilities: %{"billing" => 0.6229826361043894, "sales" => 0.3770173638956106},
            confidence: 0.3770173638956106
          )
  @score ClassificationAnswer.new(
           type: :score,
           score: 1.05,
           probabilities: [0.0, 0.95, 0.05],
           legend: ["Calm", "Frustrated", "Very angry"],
           confidence: 0.9
         )
  @yes_no ClassificationAnswer.new(type: :yes_no, yes_probability: 0.3770173638956106)

  defp full_response do
    ClassificationResponse.new(
      id: "req_abc",
      request_id: "allm-1",
      model: "jev-1.13.0",
      provider: :typesafe,
      answers: %{"department" => @choice, "anger" => @score, "refund" => @yes_no},
      usage: %Usage{input_tokens: 120, output_tokens: 3, total_tokens: 123},
      raw: %{"model" => "jev-1.13.0"},
      metadata: %{"trace" => "t1"}
    )
  end

  describe "new/1" do
    test "defaults answers to %{}, usage to %ALLM.Usage{}, metadata to %{}" do
      resp = ClassificationResponse.new()
      assert resp.answers == %{}
      assert resp.usage == %Usage{}
      assert resp.metadata == %{}
      assert resp.id == nil
      assert resp.provider == nil
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ClassificationResponse.new(bogus: 1) end
    end
  end

  describe "answer/2" do
    test "by string id" do
      assert ClassificationResponse.answer(full_response(), "department") == @choice
    end

    test "by atom id" do
      assert ClassificationResponse.answer(full_response(), :refund) == @yes_no
    end

    test "a missing id returns nil" do
      assert ClassificationResponse.answer(full_response(), "nope") == nil
    end
  end

  describe "__from_tagged__/1 usage" do
    test "a payload with no \"usage\" key decodes to %ALLM.Usage{}" do
      assert ClassificationResponse.__from_tagged__(%{}).usage == %Usage{}
    end

    test "a payload with \"usage\": null decodes to %ALLM.Usage{}" do
      assert ClassificationResponse.__from_tagged__(%{"usage" => nil}).usage == %Usage{}
    end

    test "a tagged usage of another type falls back to %ALLM.Usage{}" do
      tagged = %{"__type__" => "ALLM.ClassificationAnswer", "data" => %{"type" => "yes_no"}}
      assert ClassificationResponse.__from_tagged__(%{"usage" => tagged}).usage == %Usage{}
    end

    test "an untagged usage value passes through verbatim" do
      assert ClassificationResponse.__from_tagged__(%{"usage" => %{"x" => 1}}).usage ==
               %{"x" => 1}
    end

    test "a non-map answers value passes through verbatim" do
      assert ClassificationResponse.__from_tagged__(%{"answers" => [1]}).answers == [1]
    end

    test "a JSON document with no usage key decodes to %ALLM.Usage{}" do
      json = ~s({"__type__":"ALLM.ClassificationResponse","data":{"answers":{}}})
      assert {:ok, %ClassificationResponse{usage: %Usage{}}} = Serializer.from_json(json)
    end
  end

  describe "serializability" do
    test "round-trips through :erlang.term_to_binary/1" do
      resp = full_response()
      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON as identity, all three answer types included" do
      resp = full_response()
      assert {:ok, ^resp} = resp |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "provider survives as an atom and answers stay structs" do
      {:ok, decoded} = full_response() |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.provider == :typesafe

      for {_id, a} <- decoded.answers do
        assert %ClassificationAnswer{} = a
        assert is_atom(a.type)
      end
    end
  end
end
