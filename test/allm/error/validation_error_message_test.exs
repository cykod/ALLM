defmodule ALLM.Error.ValidationErrorMessageTest do
  @moduledoc """
  Phase 21.1: `Exception.message/1` on a `%ValidationError{}` produced by
  `ALLM.Validate.message/1` for an invalid content part includes the
  expected module names and the offending module so the integrator can
  read the help directly from test failure output.
  """

  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError
  alias ALLM.{Message, Validate}

  describe "Exception.message/1 on invalid_part_type errors" do
    test "is human-readable when the offender is a plain map" do
      {:error, %ValidationError{} = err} =
        Validate.message(%Message{
          role: :user,
          content: [%{type: "text", text: "x"}]
        })

      msg = Exception.message(err)
      assert is_binary(msg)
      assert msg =~ "ALLM.TextPart"
      assert msg =~ "ALLM.ImagePart"
      assert msg =~ "Map"
    end

    test "is human-readable when the offender is a struct module" do
      {:error, err} =
        Validate.message(%Message{role: :user, content: [%URI{}]})

      msg = Exception.message(err)
      assert msg =~ "ALLM.TextPart"
      assert msg =~ "ALLM.ImagePart"
      assert msg =~ "URI"
    end

    test "round-trips through Exception.message/1 multiple times" do
      {:error, err} =
        Validate.message(%Message{role: :user, content: [42]})

      a = Exception.message(err)
      b = Exception.message(err)
      assert a == b
      assert a =~ "ALLM.TextPart"
    end
  end
end
