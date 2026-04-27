defmodule ALLM.AllmImageRequestTest do
  @moduledoc """
  Facade-level tests for `ALLM.image_request/2` (Phase 13.3, design §13.3.1).

  Tests the constructor surface only — validation lives in
  `ALLM.Validate.image_request/1` and is covered separately. Per Decision #7
  the facade does NOT call the validator; this property is asserted here.
  """
  use ExUnit.Case, async: true

  alias ALLM.ImageRequest

  describe "image_request/2" do
    test "with \"a kestrel\" returns generate-shaped %ImageRequest{}" do
      req = ALLM.image_request("a kestrel")
      assert %ImageRequest{} = req
      assert req.operation == :generate
      assert req.prompt == "a kestrel"
      assert req.n == 1
      assert req.response_format == :binary
      assert req.input_images == []
    end

    test "with opts model: \"gpt-image-1\", size: {1024, 1024}, n: 2 sets the fields" do
      req = ALLM.image_request("a cat", model: "gpt-image-1", size: {1024, 1024}, n: 2)
      assert req.model == "gpt-image-1"
      assert req.size == {1024, 1024}
      assert req.n == 2
      assert req.prompt == "a cat"
      assert req.operation == :generate
    end

    test "with unknown key in opts raises KeyError" do
      assert_raise KeyError, fn ->
        ALLM.image_request("hi", bogus: true)
      end
    end

    test "does NOT call ALLM.Validate.image_request/1 — validator-rejecting opts return a struct" do
      # `:variation` with a non-empty prompt would be rejected by the
      # validator (prompt: :not_allowed_for_operation). The facade returns
      # the struct anyway, mirroring `request/2`'s no-validate precedent.
      req = ALLM.image_request("would-be-rejected", operation: :variation)
      assert %ImageRequest{operation: :variation, prompt: "would-be-rejected"} = req
    end

    test "opts may override :operation" do
      req = ALLM.image_request("edit me", operation: :edit)
      assert req.operation == :edit
      assert req.prompt == "edit me"
    end

    test "opts may override :prompt — but the positional arg wins by virtue of being put last" do
      # `Keyword.put/3` puts the positional `:prompt` last, overriding any
      # `:prompt` key supplied in opts. Documents the construction
      # invariant: the positional argument is authoritative.
      req = ALLM.image_request("positional-wins", prompt: "opts-loses")
      assert req.prompt == "positional-wins"
    end
  end
end
