defmodule ALLM.ValidateEmbeddingRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.EmbeddingRequest
  alias ALLM.Validate

  defp errors_for(opts) do
    {:error, err} = Validate.embedding_request(struct!(EmbeddingRequest, opts))
    assert err.reason == :invalid_embedding_request
    err.errors
  end

  describe "embedding_request/1 — happy path" do
    test "on a valid request returns :ok" do
      req = EmbeddingRequest.new(input: ["a chunk"], model: "m", dimensions: 512)
      assert Validate.embedding_request(req) == :ok
    end

    test "accepts every member of the closed task_type enum" do
      for tt <- [:search_document, :search_query, :classification, :clustering, :similarity] do
        req = EmbeddingRequest.new(input: ["x"], task_type: tt)
        assert Validate.embedding_request(req) == :ok, "expected #{inspect(tt)} to validate"
      end
    end

    test "accepts truncate: false" do
      assert Validate.embedding_request(EmbeddingRequest.new(input: ["x"], truncate: false)) == :ok
    end
  end

  # One test per row of the field-error vocabulary table.
  describe "embedding_request/1 — field-error vocabulary" do
    test "{:input, :invalid_shape} when :input is not a list" do
      assert errors_for(input: "not a list") == [{:input, :invalid_shape}]
    end

    test "{:input, :empty} when :input == []" do
      assert {:input, :empty} in errors_for(input: [])
    end

    test "{[:input, idx], :not_a_string} when an element is not a binary" do
      assert {[:input, 1], :not_a_string} in errors_for(input: ["ok", 42])
    end

    test ~s({[:input, idx], :empty} when an element is "") do
      assert {[:input, 2], :empty} in errors_for(input: ["a", "b", ""])
    end

    test "{:dimensions, :must_be_positive} when :dimensions is an integer <= 0" do
      assert {:dimensions, :must_be_positive} in errors_for(input: ["a"], dimensions: 0)
      assert {:dimensions, :must_be_positive} in errors_for(input: ["a"], dimensions: -1)
    end

    test "{:dimensions, :invalid_shape} when :dimensions is set and not an integer" do
      assert {:dimensions, :invalid_shape} in errors_for(input: ["a"], dimensions: "512")
    end

    test "{:task_type, :unknown} when :task_type is outside the closed enum" do
      assert {:task_type, :unknown} in errors_for(input: ["a"], task_type: :nonsense)
    end

    test "{:truncate, :invalid_shape} when :truncate is not a boolean" do
      assert {:truncate, :invalid_shape} in errors_for(input: ["a"], truncate: nil)
      assert {:truncate, :invalid_shape} in errors_for(input: ["a"], truncate: "yes")
    end

    test "{:model, :invalid_shape} when :model is set and not a binary" do
      assert {:model, :invalid_shape} in errors_for(input: ["a"], model: :atom_model)
    end
  end

  describe "embedding_request/1 — non-firing rules" do
    test "a nil :dimensions does not fire" do
      assert Validate.embedding_request(EmbeddingRequest.new(input: ["a"])) == :ok
    end

    test "a nil :model does not fire" do
      assert Validate.embedding_request(EmbeddingRequest.new(input: ["a"], model: nil)) == :ok
    end

    test "a nil :task_type does not fire" do
      assert Validate.embedding_request(EmbeddingRequest.new(input: ["a"], task_type: nil)) == :ok
    end

    test "a per-model dimension cap is NOT validated here" do
      # Deliberate hole: `Capability.preflight_embedding/2`'s check_dimensions_max/3
      # owns per-model caps; the validator lacks the model metadata.
      req = EmbeddingRequest.new(input: ["a"], model: "text-embedding-3-small", dimensions: 99_999)
      assert Validate.embedding_request(req) == :ok
    end
  end

  describe "embedding_request/1 — accumulation and hard-reject" do
    test "accumulates multiple field errors in one ValidationError" do
      errors =
        errors_for(
          input: ["", 7],
          dimensions: -3,
          task_type: :nope,
          truncate: "maybe",
          model: 1
        )

      assert {[:input, 0], :empty} in errors
      assert {[:input, 1], :not_a_string} in errors
      assert {:dimensions, :must_be_positive} in errors
      assert {:task_type, :unknown} in errors
      assert {:truncate, :invalid_shape} in errors
      assert {:model, :invalid_shape} in errors
      assert length(errors) == 6
    end

    test "hard-rejects a non-list :input without evaluating element or sibling rules" do
      # Only `{:input, :invalid_shape}` short-circuits: the sibling rules that
      # WOULD have fired (bad dimensions, bad task_type) must not appear.
      errors = errors_for(input: %{a: 1}, dimensions: -1, task_type: :nope)
      assert errors == [{:input, :invalid_shape}]
    end

    test "errors are returned in field order, not reversed" do
      assert errors_for(input: ["", "x"], dimensions: 0) == [
               {[:input, 0], :empty},
               {:dimensions, :must_be_positive}
             ]
    end

    test "the ValidationError carries reason :invalid_embedding_request" do
      {:error, err} = Validate.embedding_request(EmbeddingRequest.new(input: []))
      assert err.reason == :invalid_embedding_request
      assert Exception.message(err) =~ "invalid_embedding_request"
    end
  end
end
