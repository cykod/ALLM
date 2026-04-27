defmodule ALLM.Validate.ImageRequestTest do
  @moduledoc """
  Exhaustive field-error matrix for `ALLM.Validate.image_request/1` (Phase
  13.3, design §13.3.1). Every row in the §Error Contract field-error
  vocabulary table has at least one assertion here.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImageRequest, Validate}

  defp img, do: Image.from_url("https://example.com/x.png")

  # ---------------------------------------------------------------------------
  # Happy paths
  # ---------------------------------------------------------------------------

  describe "happy paths" do
    test ":generate with prompt only returns :ok" do
      assert :ok = Validate.image_request(ImageRequest.new(prompt: "a kestrel"))
    end

    test ":edit with prompt + 1 input_image returns :ok" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "make it red",
          input_images: [img()]
        )

      assert :ok = Validate.image_request(req)
    end

    test ":edit with prompt + 2 input_images (mask-as-second-image form) returns :ok" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "merge them",
          input_images: [img(), img()]
        )

      assert :ok = Validate.image_request(req)
    end

    test ":variation with 1 input_image, prompt nil returns :ok" do
      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          input_images: [img()]
        )

      assert :ok = Validate.image_request(req)
    end

    test "all response_format values are accepted" do
      for fmt <- [:binary, :base64, :url] do
        assert :ok =
                 Validate.image_request(ImageRequest.new(prompt: "x", response_format: fmt))
      end
    end

    test "all size shapes are accepted" do
      for size <- [{1024, 1024}, "1024x1024", :auto, nil] do
        assert :ok = Validate.image_request(ImageRequest.new(prompt: "x", size: size))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Operation rules (§35.2.2)
  # ---------------------------------------------------------------------------

  describe "operation rules" do
    test ":generate with prompt nil → {:prompt, :required_for_operation}" do
      req = ImageRequest.new(prompt: nil, operation: :generate)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:prompt, :required_for_operation} in errors
    end

    test ":generate with prompt \"\" → {:prompt, :required_for_operation}" do
      req = ImageRequest.new(prompt: "", operation: :generate)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:prompt, :required_for_operation} in errors
    end

    test ":generate with input_images != [] → {:input_images, :must_be_empty}" do
      req = ImageRequest.new(prompt: "x", operation: :generate, input_images: [img()])
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :must_be_empty} in errors
    end

    test ":edit with prompt nil → {:prompt, :required_for_operation}" do
      req = ImageRequest.new(prompt: nil, operation: :edit, input_images: [img()])
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:prompt, :required_for_operation} in errors
    end

    test ":edit with input_images == [] → {:input_images, :invalid_count}" do
      req = ImageRequest.new(prompt: "x", operation: :edit, input_images: [])
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :invalid_count} in errors
    end

    test ":edit with input_images of length 3 → {:input_images, :invalid_count}" do
      req =
        ImageRequest.new(
          prompt: "x",
          operation: :edit,
          input_images: [img(), img(), img()]
        )

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :invalid_count} in errors
    end

    test ":variation with prompt \"non-empty\" → {:prompt, :not_allowed_for_operation}" do
      req =
        ImageRequest.new(
          prompt: "non-empty",
          operation: :variation,
          input_images: [img()]
        )

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:prompt, :not_allowed_for_operation} in errors
    end

    test ":variation with input_images == [] → {:input_images, :invalid_count}" do
      req = ImageRequest.new(operation: :variation, prompt: nil, input_images: [])
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :invalid_count} in errors
    end

    test ":variation with input_images of length 2 → {:input_images, :invalid_count}" do
      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          input_images: [img(), img()]
        )

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :invalid_count} in errors
    end

    test ":variation with empty-string prompt + 1 valid input_image returns :ok" do
      # Empty string is treated as absent for `:not_allowed_for_operation`.
      req =
        ImageRequest.new(
          operation: :variation,
          prompt: "",
          input_images: [img()]
        )

      assert :ok = Validate.image_request(req)
    end
  end

  # ---------------------------------------------------------------------------
  # Field rules
  # ---------------------------------------------------------------------------

  describe "field rules" do
    test ":operation not in [:generate, :edit, :variation] → {:operation, :unknown}" do
      req = %ImageRequest{operation: :bogus, prompt: "x"}
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:operation, :unknown} in errors
    end

    test ":n zero → {:n, :must_be_positive}" do
      req = ImageRequest.new(prompt: "x", n: 0)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:n, :must_be_positive} in errors
    end

    test ":n negative → {:n, :must_be_positive}" do
      req = ImageRequest.new(prompt: "x", n: -1)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:n, :must_be_positive} in errors
    end

    test ":n non-integer → {:n, :must_be_positive}" do
      req = ImageRequest.new(prompt: "x", n: 1.5)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:n, :must_be_positive} in errors
    end

    test ":response_format not in [:binary, :base64, :url] → {:response_format, :unknown}" do
      req = %ImageRequest{operation: :generate, prompt: "x", response_format: :bogus, n: 1}

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:response_format, :unknown} in errors
    end

    test ":size of shape {0, 1024} → {:size, :invalid_shape}" do
      req = ImageRequest.new(prompt: "x", size: {0, 1024})
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:size, :invalid_shape} in errors
    end

    test ":size of shape {:not, :a, :tuple_of_integers} → {:size, :invalid_shape}" do
      req = ImageRequest.new(prompt: "x", size: {:not, :a, :tuple_of_integers})
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:size, :invalid_shape} in errors
    end

    test ":size shape :not_an_atom (non-:auto, non-binary, non-tuple, non-nil) → {:size, :invalid_shape}" do
      req = ImageRequest.new(prompt: "x", size: :not_an_atom)
      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:size, :invalid_shape} in errors
    end

    test ":input_images non-list → {:input_images, :not_a_list}" do
      req = %ImageRequest{operation: :generate, prompt: "x", input_images: "not a list", n: 1}

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:input_images, :not_a_list} in errors
    end

    test ":input_images containing a non-%Image{} element → {[:input_images, 0], :invalid_image}" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          input_images: [%{not: :an_image}]
        )

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {[:input_images, 0], :invalid_image} in errors
    end

    test ":mask non-%Image{} value → {:mask, :invalid_image}" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          input_images: [img()],
          mask: %{not: :an_image}
        )

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:mask, :invalid_image} in errors
    end

    test ":mask nil is accepted" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          input_images: [img()],
          mask: nil
        )

      assert :ok = Validate.image_request(req)
    end

    test ":mask is a valid %Image{} is accepted" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          input_images: [img()],
          mask: img()
        )

      assert :ok = Validate.image_request(req)
    end
  end

  # ---------------------------------------------------------------------------
  # Accumulator (no hard-reject)
  # ---------------------------------------------------------------------------

  describe "accumulator semantics (no hard-reject)" do
    test ":generate with prompt nil AND n: 0 AND response_format: :unknown returns all three errors" do
      req = %ImageRequest{
        operation: :generate,
        prompt: nil,
        n: 0,
        response_format: :unknown,
        input_images: []
      }

      assert {:error, %ValidationError{errors: errors}} = Validate.image_request(req)
      assert {:prompt, :required_for_operation} in errors
      assert {:n, :must_be_positive} in errors
      assert {:response_format, :unknown} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Return shape
  # ---------------------------------------------------------------------------

  describe "return shape" do
    test "on any error err.reason == :invalid_image_request and message default" do
      req = ImageRequest.new(prompt: nil, operation: :generate)
      assert {:error, %ValidationError{} = err} = Validate.image_request(req)
      assert err.reason == :invalid_image_request

      assert err.message ==
               "validation failed: invalid_image_request (#{length(err.errors)} error(s))"

      assert is_list(err.errors)
      Enum.each(err.errors, fn e -> assert match?({_, _}, e) end)
    end
  end
end
