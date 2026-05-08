defmodule ALLM.Error.SessionError do
  @moduledoc """
  Session-state error. Returned (or raised) by `ALLM.Session` operations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Every
  Layer-D public function can return `{:error, %ALLM.Error.SessionError{}}`
  uniformly.

  ## Reasons

  | Reason | Fires when | Caller recovery |
  |--------|------------|------------------|
  | `:session_in_error_state` | Caller invokes a Layer-D operation on a `%Session{status: :error}`. | Construct a fresh session; do not retry. |
  | `:invalid_status_for_operation` | Reserved for future use. | n/a |
  | `:no_pending_tool_call` | Reserved for future use; the Layer-D status guard catches this case via `ArgumentError`. | n/a |
  | `:unknown_tool_call_id` | `submit_tool_result/3` or `submit_tool_results/2` received a `tool_call_id` that does not match any pending `%ToolCall{}` on the session. Data validation, NOT a programmer-flow error. | Read `metadata.tool_call_id`; verify the caller is submitting against the right pending call. |
  """

  @typedoc "Closed set of session-level error reasons."
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
