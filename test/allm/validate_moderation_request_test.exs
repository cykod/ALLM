defmodule ALLM.ValidateModerationRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{Image, ImagePart, ModerationRequest, Validate}

  @image_part ImagePart.new(Image.from_url("https://example.com/cat.png"))

  defp errors_for(opts) do
    {:error, err} = Validate.moderation_request(struct!(ModerationRequest, opts))
    assert err.reason == :invalid_moderation_request
    err.errors
  end

  describe "moderation_request/1 — happy path" do
    test ":ok for a valid all-strings request" do
      req = ModerationRequest.new(input: ["is this ok?", "and this?"], model: "m")
      assert Validate.moderation_request(req) == :ok
    end

    test ":ok for a valid request containing an %ImagePart{}" do
      # The union arm is live from the moment the struct ships — the adapter
      # that can send it lands later, but the validator never changes.
      req = ModerationRequest.new(input: ["describe this", @image_part])
      assert Validate.moderation_request(req) == :ok
    end

    test ":ok for an image-only input" do
      assert Validate.moderation_request(ModerationRequest.new(input: [@image_part])) == :ok
    end

    test ":ok for a nil :model" do
      assert Validate.moderation_request(ModerationRequest.new(input: ["x"], model: nil)) == :ok
    end
  end

  # One test per row of the field-error vocabulary table.
  describe "moderation_request/1 — field-error vocabulary" do
    test "input: %{} hard-rejects with exactly [{:input, :invalid_shape}] and no other errors" do
      assert errors_for(input: %{}, model: 42) == [{:input, :invalid_shape}]
    end

    test "{:input, :invalid_shape} for any non-list :input" do
      assert errors_for(input: "raw string") == [{:input, :invalid_shape}]
      assert errors_for(input: 42) == [{:input, :invalid_shape}]
    end

    test "input: [] yields {:input, :empty}" do
      assert {:input, :empty} in errors_for(input: [])
    end

    test ~s(input: ["", "ok"] yields {[:input, 0], :empty}) do
      assert {[:input, 0], :empty} in errors_for(input: ["", "ok"])
    end

    test "input: [42] yields {[:input, 0], :invalid_item}" do
      assert {[:input, 0], :invalid_item} in errors_for(input: [42])
    end

    test "a map element yields :invalid_item — raw maps are not accepted" do
      assert {[:input, 1], :invalid_item} in errors_for(input: ["ok", %{"type" => "text"}])
    end

    test "model: 42 yields {:model, :invalid_shape}" do
      assert {:model, :invalid_shape} in errors_for(input: ["x"], model: 42)
    end
  end

  describe "moderation_request/1 — rules deliberately NOT here" do
    test "per-item MIME and byte-size rules are the adapter's job, not the validator's" do
      # `ALLM.Providers.Support.ImageMime` owns MIME and the 20 MB cap; the
      # validator has no provider context to check them against.
      part = ImagePart.new(Image.from_base64(Base.encode64("not an image"), "image/tiff"))
      assert Validate.moderation_request(ModerationRequest.new(input: [part])) == :ok
    end

    test "a batch larger than any provider cap still validates" do
      # `:batch_too_large` is an adapter-side rejection measured against that
      # adapter's own `max_batch_size()`.
      req = ModerationRequest.new(input: Enum.map(1..500, &"item #{&1}"))
      assert Validate.moderation_request(req) == :ok
    end
  end

  describe "moderation_request/1 — accumulation and hard-reject" do
    test "two independent violations accumulate into one error list" do
      errors = errors_for(input: ["", 7, @image_part], model: :atom_model)

      assert {[:input, 0], :empty} in errors
      assert {[:input, 1], :invalid_item} in errors
      assert {:model, :invalid_shape} in errors
      assert length(errors) == 3
    end

    test "hard-rejects a non-list :input without evaluating sibling rules" do
      assert errors_for(input: %{a: 1}, model: 42) == [{:input, :invalid_shape}]
    end

    test "errors are returned in field order, not reversed" do
      assert errors_for(input: ["", "x"], model: 1) == [
               {[:input, 0], :empty},
               {:model, :invalid_shape}
             ]
    end

    test "the ValidationError carries reason :invalid_moderation_request" do
      {:error, err} = Validate.moderation_request(ModerationRequest.new(input: []))
      assert err.reason == :invalid_moderation_request
      assert Exception.message(err) =~ "invalid_moderation_request"
    end
  end
end
