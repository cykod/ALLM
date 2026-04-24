defmodule ALLM.ToolResultEncoder.JSONTest do
  @moduledoc """
  Unit tests for `ALLM.ToolResultEncoder.JSON`.

  Covers the binary-passthrough / `{:ok, _}` wrap / `{:error, _}` wrap /
  Jason-encode passthrough paths (Non-obvious Decision #4). Non-JSON-
  encodable values (PIDs, bare tuples) are documented as raising
  `Protocol.UndefinedError` — the orchestrator wraps the call in
  `try/rescue` and surfaces `%ToolError{reason: :encoding_failed}`
  (Phase 6).

  The conformance-suite plug-in is wired up in Sub-phase 3.5 (Batch 3):

      use ALLM.Test.ToolResultEncoderConformance, encoder: ALLM.ToolResultEncoder.JSON
  """

  use ExUnit.Case, async: true

  alias ALLM.ToolResultEncoder.JSON, as: Encoder

  doctest Encoder

  # ---------------------------------------------------------------------------
  # Binary passthrough
  # ---------------------------------------------------------------------------

  describe "binary passthrough" do
    test "already-a-string passes through unchanged" do
      assert Encoder.encode("already a string") == "already a string"
    end

    test "empty string passes through unchanged" do
      assert Encoder.encode("") == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Jason encoding for non-binary, non-tagged values
  # ---------------------------------------------------------------------------

  describe "Jason-encoded values" do
    test "map round-trips through Jason" do
      encoded = Encoder.encode(%{a: 1, b: 2})
      assert Jason.decode!(encoded) == %{"a" => 1, "b" => 2}
    end

    test "list encodes as JSON array" do
      assert Encoder.encode([1, 2, 3]) == "[1,2,3]"
    end

    test "nil encodes as JSON null" do
      assert Encoder.encode(nil) == "null"
    end

    test "integer encodes as JSON number" do
      assert Encoder.encode(42) == "42"
    end

    test "true encodes as JSON true" do
      assert Encoder.encode(true) == "true"
    end

    test "false encodes as JSON false" do
      assert Encoder.encode(false) == "false"
    end
  end

  # ---------------------------------------------------------------------------
  # Tuple unwrap — {:ok, _} and {:error, _}
  # ---------------------------------------------------------------------------

  describe "tuple unwrapping" do
    test "{:ok, map} wraps inner as %{ok: inner}" do
      encoded = Encoder.encode({:ok, %{a: 1}})
      assert Jason.decode!(encoded) == %{"ok" => %{"a" => 1}}
    end

    test "{:ok, string} wraps inner as %{ok: inner}" do
      encoded = Encoder.encode({:ok, "inner"})
      assert Jason.decode!(encoded) == %{"ok" => "inner"}
    end

    test "{:error, atom} wraps inspected reason as %{error: inspected}" do
      encoded = Encoder.encode({:error, :not_found})
      assert Jason.decode!(encoded) == %{"error" => ":not_found"}
    end

    test "{:error, struct} wraps inspected reason" do
      encoded = Encoder.encode({:error, %RuntimeError{message: "boom"}})
      decoded = Jason.decode!(encoded)
      assert decoded == %{"error" => inspect(%RuntimeError{message: "boom"})}
    end

    test "{:error, binary} wraps reason verbatim (no inspect)" do
      encoded = Encoder.encode({:error, "plain reason"})
      assert Jason.decode!(encoded) == %{"error" => "plain reason"}
    end
  end

  # ---------------------------------------------------------------------------
  # Raises for non-JSON-encodable values
  # ---------------------------------------------------------------------------

  describe "non-encodable values raise Protocol.UndefinedError" do
    test "PID raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn -> Encoder.encode(self()) end
    end

    test "bare tuple raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn -> Encoder.encode({1, 2, 3}) end
    end

    test "{:ok, bare_tuple} raises Protocol.UndefinedError (nested tuple unencodable)" do
      assert_raise Protocol.UndefinedError, fn -> Encoder.encode({:ok, {1, 2, 3}}) end
    end
  end

  # Conformance suite plug-in (Sub-phase 3.5): certify the default
  # encoder against every case in the shipped conformance harness.
  use ALLM.Test.ToolResultEncoderConformance, encoder: ALLM.ToolResultEncoder.JSON
end
