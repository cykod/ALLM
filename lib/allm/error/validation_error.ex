defmodule ALLM.Error.ValidationError do
  @moduledoc """
  Errors returned by `ALLM.Validate` functions.

  Layer A — serializable. Carries a list of `t:field_error/0` tuples so
  callers can machine-read which fields failed validation and why. Refines
  spec §16's "list of error terms" shape into a first-class struct.

  See Phase 1 design §Sub-phase 1.1 for the closed reason enum. Phase 8
  (sub-phase 8.2) extended the enum with `:invalid_session_input` for the
  `ALLM.Session.start/3` / `stream_start/3` input-coercion failure.
  """

  @typedoc """
  A single field-level validation failure.

  The first element is either a single atom (for top-level fields like
  `:messages`) or a path of atoms/indices (e.g. `[:messages, 0, :role]`) when
  the failure is nested.
  """
  @type field_error :: {field :: atom() | [term()], reason :: atom()}

  @typedoc "Closed set of validation error reasons (spec §16, §33)."
  @type reason ::
          :invalid_request
          | :invalid_message
          | :invalid_tool
          | :invalid_thread
          | :invalid_session
          | :invalid_session_input
          | :unsupported_capability
          | :vision_not_in_v0_2

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          errors: [field_error()],
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    invalid_request
    invalid_message
    invalid_tool
    invalid_thread
    invalid_session
    invalid_session_input
    unsupported_capability
    vision_not_in_v0_2
  )a

  defexception [:reason, :message, :cause, errors: [], metadata: %{}]

  @doc """
  Build a `%ValidationError{}` from a `reason` atom, a list of `errors`, and
  optional keyword fields.

  `opts` may include `:message`, `:cause`, and `:metadata`. When `:message` is
  omitted, the default is
  `"validation failed: \#{reason} (\#{length(errors)} error(s))"`.

  Raises `ArgumentError` if `reason` is not in `t:reason/0` or if `errors` is
  not a list.

  ## Examples

      iex> err = ALLM.Error.ValidationError.new(:invalid_request, [{:messages, :empty}])
      iex> err.reason
      :invalid_request
      iex> err.errors
      [{:messages, :empty}]
      iex> Exception.message(err)
      "validation failed: invalid_request (1 error(s))"

      iex> err = ALLM.Error.ValidationError.new(:invalid_tool, [], message: "nothing wrong")
      iex> Exception.message(err)
      "nothing wrong"
  """
  @spec new(reason(), [field_error()], keyword()) :: t()
  def new(reason, errors, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.ValidationError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    unless is_list(errors) do
      raise ArgumentError,
            "errors must be a list of field_error tuples; got #{inspect(errors)}"
    end

    message = Keyword.get(opts, :message) || default_message(reason, errors)

    %__MODULE__{
      reason: reason,
      message: message,
      errors: errors,
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m

  def message(%__MODULE__{reason: r, errors: errs})
      when is_atom(r) and not is_nil(r) and is_list(errs),
      do: default_message(r, errs)

  def message(%__MODULE__{reason: r}) when is_atom(r) and not is_nil(r),
    do: default_message(r, [])

  def message(%__MODULE__{}), do: "validation failed"

  defp default_message(reason, errors) when is_list(errors),
    do: "validation failed: #{reason} (#{length(errors)} error(s))"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      errors: data["errors"] || [],
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.ValidationError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
