defmodule ALLM.ToolResultEncoder do
  @moduledoc """
  Serialize a tool's return value into a string the model can consume. See
  spec §7.4 and §18.

  The encoder is called with the raw value from
  `ALLM.ToolExecutor.execute/3` (after the orchestrator has pattern-matched
  any wrapper it cares about — see `ALLM.ToolResultEncoder.JSON` for the
  default implementation's exact unwrapping rules).

  ## Invariants

    1. `encode/1` is **total** over the types the encoder documents in its
       `@moduledoc`. A value outside the documented shapes may raise —
       the caller guards with `try/rescue` and surfaces
       `%ALLM.Error.ToolError{reason: :encoding_failed}` to the model.
    2. `encode/1` is **pure**: no IO, no state, no side effects. The
       conformance suite asserts determinism (same input, same output,
       byte-for-byte).
    3. `encode/1` never emits a bare Elixir term (tuple, pid, ref) in its
       output — the return is always a `String.t()`.

  No `@optional_callbacks`: `encode/1` is the only callback and it is
  required.
  """

  @doc """
  Serialize a tool's return value into a `String.t()` the model can
  consume.

  Implementations pick their own serialization strategy (JSON via `Jason`
  is the default — see `ALLM.ToolResultEncoder.JSON`). The return must be
  a `String.t()`; callers rely on this to splice the value into a
  `:tool`-role message.

  Values the encoder cannot serialize may raise. Callers wrap the call in
  `try/rescue` and convert the raise to
  `{:error, %ALLM.Error.ToolError{reason: :encoding_failed}}`.
  """
  @callback encode(term()) :: String.t()
end
