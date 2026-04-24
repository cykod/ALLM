defmodule ALLM.Test.ToolResultEncoderConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.ToolResultEncoder`
  implementations.

  ## Installation

      {:allm_conformance, "~> 0.2", only: :test}

  ## Usage

      defmodule MyEncoderTest do
        use ExUnit.Case, async: true
        use ALLM.Test.ToolResultEncoderConformance, encoder: MyEncoder
      end

  Injects a `describe "ALLM.ToolResultEncoder conformance (MyEncoder)"`
  block with 9 deterministic cases:

    1. binary passthrough (non-empty)
    2. binary passthrough (empty string)
    3. map round-trips through `Jason.decode!/1`
    4. list round-trips through `Jason.decode!/1`
    5. nil / integer / boolean encode to their JSON scalar forms
    6. float encodes to a JSON numeric scalar
    7. `{:ok, _}` unwrap produces `%{"ok" => _}` shape
    8. `{:error, atom}` unwrap produces `%{"error" => inspected_atom}`
    9. determinism: `encode(x) == encode(x)` byte-equal

  The harness asserts *structural* invariants every encoder must satisfy
  (binaries pass through, tagged tuples unwrap, encoding is
  deterministic). An encoder with a different serialization format
  (MessagePack, XML) should adapt the round-trip assertions to its own
  decoder — this harness targets JSON-shaped encoders specifically per
  spec §18's default.
  """

  use ExUnit.CaseTemplate

  @case_count 9

  @doc """
  Return the number of cases injected by `using/1`.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  using opts do
    quote location: :keep do
      @__allm_conformance_encoder__ Keyword.fetch!(unquote(opts), :encoder)

      describe "ALLM.ToolResultEncoder conformance (#{inspect(@__allm_conformance_encoder__)})" do
        test "binary passthrough (non-empty)" do
          assert @__allm_conformance_encoder__.encode("already a string") == "already a string"
        end

        test "binary passthrough (empty string)" do
          assert @__allm_conformance_encoder__.encode("") == ""
        end

        test "map round-trips through Jason.decode!/1" do
          encoded = @__allm_conformance_encoder__.encode(%{a: 1, b: 2})
          assert Jason.decode!(encoded) == %{"a" => 1, "b" => 2}
        end

        test "list round-trips through Jason.decode!/1" do
          encoded = @__allm_conformance_encoder__.encode([1, 2, 3])
          assert Jason.decode!(encoded) == [1, 2, 3]
        end

        test "nil, integer, and boolean encode to their JSON scalar forms" do
          assert @__allm_conformance_encoder__.encode(nil) == "null"
          assert @__allm_conformance_encoder__.encode(42) == "42"
          assert @__allm_conformance_encoder__.encode(true) == "true"
          assert @__allm_conformance_encoder__.encode(false) == "false"
        end

        test "float encodes to a JSON numeric scalar that round-trips to the same float" do
          # Jason may render 3.14 as "3.14" or "3.14e0" depending on
          # version; either is valid JSON, so assert on the round-trip
          # rather than the textual form.
          encoded = @__allm_conformance_encoder__.encode(3.14)
          assert is_binary(encoded)
          assert Jason.decode!(encoded) == 3.14
        end

        test "{:ok, _} unwrap produces %{\"ok\" => _} shape" do
          encoded = @__allm_conformance_encoder__.encode({:ok, %{a: 1}})
          assert Jason.decode!(encoded) == %{"ok" => %{"a" => 1}}
        end

        test "{:error, atom} unwrap produces %{\"error\" => inspected_atom} shape" do
          encoded = @__allm_conformance_encoder__.encode({:error, :not_found})
          assert Jason.decode!(encoded) == %{"error" => ":not_found"}
        end

        test "determinism: encode(x) == encode(x) byte-equal" do
          input = %{a: 1, b: [1, 2, 3], c: "hi"}

          assert @__allm_conformance_encoder__.encode(input) ==
                   @__allm_conformance_encoder__.encode(input)
        end
      end
    end
  end
end
