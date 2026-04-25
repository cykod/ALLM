defmodule ALLM.Error.SessionError do
  @moduledoc """
  Session-state error. Returned (or raised) by Phase 8's `ALLM.Session`
  operations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Refines
  spec §20's atom taxonomy into a first-class struct so every Layer D
  public function can return `{:error, %ALLM.Error.SessionError{}}`
  uniformly.

  See `steering/PHASE_8_DESIGN.md` §"Atom vocabulary additions" for the
  closed reason enum and the §"Error Contract" table for the recovery
  guidance per reason.

  ## Reasons

  | Reason | Fires when |
  |--------|------------|
  | `:session_in_error_state` | Caller invokes a Phase-8 operation on a `%Session{status: :error}`. |
  | `:invalid_status_for_operation` | Reserved for future use (currently unused — Decision #7 routes status mismatches to `ArgumentError`). |
  | `:no_pending_tool_call` | Reserved for future use; the Phase-8 status guard catches this case via `ArgumentError`. |
  | `:unknown_tool_call_id` | `submit_tool_result/3` or `submit_tool_results/2` received a `tool_call_id` that does not match any pending `%ToolCall{}` on the session. Data validation, NOT a programmer-flow error. |
  """

  @typedoc "Closed set of session-level error reasons (spec §20)."
  @type reason ::
          :session_in_error_state
          | :invalid_status_for_operation
          | :no_pending_tool_call
          | :unknown_tool_call_id

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    session_in_error_state
    invalid_status_for_operation
    no_pending_tool_call
    unknown_tool_call_id
  )a

  defexception [:reason, :message, :provider, :cause, metadata: %{}]

  @doc """
  Build a `%SessionError{}` from a `reason` atom and optional keyword
  fields.

  `opts` may include `:message`, `:cause`, and `:metadata`. `:provider` is
  always `nil` for session errors (session is a Layer D concept; no
  provider context is meaningful). When `:message` is omitted, it
  defaults to `"session error: \#{reason}"`.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.SessionError.new(:session_in_error_state)
      iex> err.reason
      :session_in_error_state
      iex> Exception.message(err)
      "session error: session_in_error_state"

      iex> err = ALLM.Error.SessionError.new(:unknown_tool_call_id, metadata: %{tool_call_id: "c0"})
      iex> err.metadata
      %{tool_call_id: "c0"}
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    validate_reason!(reason)

    message = Keyword.get(opts, :message) || default_message(reason)

    %__MODULE__{
      reason: reason,
      message: message,
      provider: nil,
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m
  def message(%__MODULE__{reason: r}) when is_atom(r) and not is_nil(r), do: default_message(r)
  def message(%__MODULE__{}), do: "session error"

  defp default_message(reason), do: "session error: #{reason}"

  defp validate_reason!(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.SessionError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    :ok
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      provider: nil,
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.SessionError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
