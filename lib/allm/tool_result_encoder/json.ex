defmodule ALLM.ToolResultEncoder.JSON do
  @moduledoc """
  Default `ALLM.ToolResultEncoder` — JSON-encodes the tool return value
  via `Jason.encode!/1`, with targeted passthrough / unwrap shortcuts so
  handlers that pre-format a string for the model aren't double-encoded.

  ## Input-shape → output-shape

  | Input | Output |
  |-----------------------------|---------------------------------------|
  | `"already a string"` | `"already a string"` (unchanged) |
  | `""` | `""` (unchanged) |
  | `%{a: 1}` | `~s({"a":1})` |
  | `[1, 2, 3]` | `"[1,2,3]"` |
  | `{:ok, %{a: 1}}` | `~s({"ok":{"a":1}})` |
  | `{:ok, "inner"}` | `~s({"ok":"inner"})` |
  | `{:error, :not_found}` | `~s({"error":":not_found"})` |
  | `{:error, "reason"}` | `~s({"error":"reason"})` (verbatim) |
  | `{:error, %RuntimeError{}}` | `~s({"error":"%RuntimeError{…}"})` |
  | `nil` | `"null"` |
  | `42` | `"42"` |
  | `true` / `false` | `"true"` / `"false"` |

  Non-JSON-encodable values (PIDs, refs, bare tuples, funs) raise
  `Protocol.UndefinedError` — Jason dispatches through the
  `Jason.Encoder` protocol and a missing impl surfaces at dispatch time,
  not as a `Jason.EncodeError`. The orchestrator wraps the call in
  `try/rescue` and converts the raise to
  `{:error, %ALLM.Error.ToolError{reason: :encoding_failed}}`.

  Used automatically when `engine.tool_result_encoder` is `nil`; the
  call site resolves to this module via
  `engine.tool_result_encoder || ALLM.ToolResultEncoder.JSON`.

  Users who want a different encoding (MessagePack, XML, Protobuf) plug
  in their own module implementing `ALLM.ToolResultEncoder`.
  """

  @behaviour ALLM.ToolResultEncoder

  @doc """
  Serialize a tool's return value into a JSON string.

  See the module doc for the full input-shape → output-shape table.

  ## Examples

      iex> ALLM.ToolResultEncoder.JSON.encode("pre-formatted")
      "pre-formatted"

      iex> ALLM.ToolResultEncoder.JSON.encode({:ok, %{a: 1}}) |> Jason.decode!()
      %{"ok" => %{"a" => 1}}

      iex> ALLM.ToolResultEncoder.JSON.encode({:error, :not_found}) |> Jason.decode!()
      %{"error" => ":not_found"}
  """
  @impl true
  @spec encode(term()) :: String.t()
  def encode(value) when is_binary(value), do: value
  def encode({:ok, inner}), do: Jason.encode!(%{ok: inner})
  def encode({:error, reason}) when is_binary(reason), do: Jason.encode!(%{error: reason})
  def encode({:error, reason}), do: Jason.encode!(%{error: inspect(reason)})
  def encode(value), do: Jason.encode!(value)
end
