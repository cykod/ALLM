defmodule ALLM.EmbeddingTest do
  use ExUnit.Case, async: true
  doctest ALLM.Embedding

  alias ALLM.Embedding

  describe "new/1" do
    test "with vector and index builds the struct" do
      e = Embedding.new(vector: [1.0, 2.0], index: 3, metadata: %{"k" => "v"})
      assert e.vector == [1.0, 2.0]
      assert e.index == 3
      assert e.metadata == %{"k" => "v"}
    end

    test "without :vector raises ArgumentError" do
      # `@enforce_keys [:vector]` — `struct!/2` raises ArgumentError on an
      # ABSENT enforced key, NOT KeyError.
      assert_raise ArgumentError, fn -> Embedding.new([]) end
    end

    test "with an unknown key raises KeyError" do
      # `struct!/2`'s behaviour for keys not in the defstruct.
      assert_raise KeyError, fn -> Embedding.new(vector: [1.0], bogus: 1) end
    end

    test "defaults :index to 0 and :metadata to %{}" do
      e = Embedding.new(vector: [1.0])
      assert e.index == 0
      assert e.metadata == %{}
    end

    test "an explicit nil :vector is accepted — @enforce_keys guards absence, not value" do
      # Deliberate: CLAUDE.md's "Layer-A constructors are struct!/2
      # pass-throughs by default"; no is_list/1 guard on :vector.
      assert %Embedding{vector: nil} = Embedding.new(vector: nil)
    end
  end

  describe "magnitude/1" do
    test "returns the Euclidean norm" do
      assert Embedding.magnitude(Embedding.new(vector: [3.0, 4.0])) == 5.0
    end

    test "of a single-element vector is its absolute value" do
      assert Embedding.magnitude(Embedding.new(vector: [-2.0])) == 2.0
    end

    test "of an empty vector is 0.0" do
      assert Embedding.magnitude(Embedding.new(vector: [])) == 0.0
    end

    test "of an all-zero vector is 0.0" do
      assert Embedding.magnitude(Embedding.new(vector: [0.0, 0.0, 0.0])) == 0.0
    end

    test "of a vector whose components underflow when squared is 0.0" do
      # 1.0e-200 * 1.0e-200 underflows to 0.0 — documented contract, no NaN.
      assert Embedding.magnitude(Embedding.new(vector: [1.0e-200, 1.0e-200])) == 0.0
    end

    test "raises ArithmeticError on float overflow" do
      # Documented, not defended against: Erlang's `*` raises badarith rather
      # than producing infinity. No real provider returns components near 1.0e150.
      assert_raise ArithmeticError, fn ->
        Embedding.magnitude(Embedding.new(vector: [1.0e200, 1.0e200]))
      end
    end
  end

  describe "normalize/1" do
    test "produces a unit vector (magnitude within 1.0e-9 of 1.0)" do
      normalized = Embedding.normalize(Embedding.new(vector: [3.0, 4.0]))
      assert_in_delta Embedding.magnitude(normalized), 1.0, 1.0e-9
    end

    test "preserves :index and :metadata" do
      e = Embedding.new(vector: [3.0, 4.0], index: 7, metadata: %{"m" => 1})
      normalized = Embedding.normalize(e)
      assert normalized.index == 7
      assert normalized.metadata == %{"m" => 1}
    end

    test "on an all-zero vector returns the input unchanged" do
      e = Embedding.new(vector: [0.0, 0.0])
      assert Embedding.normalize(e) == e
    end

    test "on an empty vector returns the input unchanged" do
      e = Embedding.new(vector: [])
      assert Embedding.normalize(e) == e
    end

    test "on a vector whose components underflow returns the input unchanged" do
      e = Embedding.new(vector: [1.0e-200, 1.0e-200])
      assert Embedding.normalize(e) == e
    end

    test "is idempotent within 1.0e-9" do
      once = Embedding.normalize(Embedding.new(vector: [1.0, 2.0, 3.0, 4.0]))
      twice = Embedding.normalize(once)

      Enum.zip(once.vector, twice.vector)
      |> Enum.each(fn {a, b} -> assert_in_delta a, b, 1.0e-9 end)
    end
  end

  describe "__from_tagged__/1 defensive arms" do
    test "coerces integer vector elements to floats" do
      decoded = Embedding.__from_tagged__(%{"vector" => [0, 1], "index" => 2})
      assert decoded.vector == [0.0, 1.0]
      assert decoded.index == 2
    end

    test "leaves float vector elements untouched" do
      decoded = Embedding.__from_tagged__(%{"vector" => [0.5, 1.5]})
      assert decoded.vector == [0.5, 1.5]
    end

    test "a missing :index defaults to 0 and missing :metadata to %{}" do
      decoded = Embedding.__from_tagged__(%{"vector" => [1.0]})
      assert decoded.index == 0
      assert decoded.metadata == %{}
    end

    test "a non-list :vector passes through verbatim" do
      # Defensive arm: malformed payloads are not silently repaired into a list.
      assert Embedding.__from_tagged__(%{"vector" => "nope"}).vector == "nope"
    end

    test "a non-numeric vector element passes through verbatim" do
      assert Embedding.__from_tagged__(%{"vector" => [1, "x"]}).vector == [1.0, "x"]
    end

    test "an out-of-float-range integer passes through instead of raising" do
      # A JSON integer literal wider than a float decodes to a bignum, and
      # `bignum * 1.0` raises ArithmeticError. Serializer.hydrate_with/2 does
      # not rescue that class, so an unguarded raise would escape
      # Serializer.from_json/2's {:ok, _} | {:error, _} contract.
      bignum = 10 ** 400
      assert Embedding.__from_tagged__(%{"vector" => [bignum]}).vector == [bignum]
    end
  end
end
