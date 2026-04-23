defmodule ALLM.Validate do
  @moduledoc """
  Pure validators for Layer A input shapes. See spec §16 and Phase 1 design
  sub-phase 1.4.

  Every validator returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`
  with a machine-readable `:errors` list of `{field, reason}` tuples. The
  `field` is either a single atom (top-level) or a path of atoms/indices
  (e.g. `[:messages, 2, :role]`) when the failure is nested.

  Vision content parts (`%{type: "image", ...}`, `%{type: "image_url", ...}`)
  are a hard reject with `reason: :vision_not_in_v0_2` per spec §33 non-goals.

  Validators are opt-in: constructors like `ALLM.Request.new/2` do not call
  these functions (see Phase 1 design non-obvious decision #7). Users invoke
  `request/1`, `message/1`, `tool/1`, `thread/1`, or `session/1` explicitly
  when they need a check before dispatch.
  """

  alias ALLM.Error.ValidationError
  alias ALLM.{Message, Request, Session, Thread, Tool}

  @legal_roles [:system, :user, :assistant, :tool]
  @legal_statuses [:idle, :awaiting_user, :awaiting_tools, :completed, :error]
  @tool_name_regex ~r/^[A-Za-z0-9_-]{1,64}$/
  # Names that collide with `Request.tool_choice` atom restoration in
  # `ALLM.Request.__from_tagged__/1` — a tool named `"auto"` would round-trip
  # to `:auto` and break Layer A JSON equality. See sub-phase 1.5 Finding 3.
  @reserved_tool_names ~w[auto none required]

  # ---------------------------------------------------------------------------
  # request/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Request{}`.

  Returns `:ok` when every field is well-formed, or
  `{:error, %ALLM.Error.ValidationError{reason: :invalid_request, errors: [...]}}`.

  A vision content part in any message short-circuits with
  `reason: :vision_not_in_v0_2`.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}])
      iex> ALLM.Validate.request(req)
      :ok

      iex> req = ALLM.Request.new([])
      iex> {:error, err} = ALLM.Validate.request(req)
      iex> err.reason
      :invalid_request
      iex> {:messages, :empty} in err.errors
      true
  """
  @spec request(Request.t()) :: :ok | {:error, ValidationError.t()}
  def request(%Request{} = req) do
    with :ok <- check_vision_in_messages(req.messages, &[:messages, &1, :content]) do
      errors =
        []
        |> validate_messages_non_empty(req.messages)
        |> validate_messages_each(req.messages)
        |> validate_tools_each(req.tools)
        |> validate_tool_names_unique(req.tools)
        |> validate_temperature(req.temperature)
        |> validate_max_tokens(req.max_tokens)
        |> validate_response_format(req.response_format)
        |> validate_structured_finalize(req.structured_finalize, req.response_format)
        |> Enum.reverse()

      finalize(:invalid_request, errors)
    end
  end

  # ---------------------------------------------------------------------------
  # message/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Message{}`.

  Returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`. A content list
  containing a vision part short-circuits with `reason: :vision_not_in_v0_2`
  (see spec §33).

  ## Examples

      iex> ALLM.Validate.message(%ALLM.Message{role: :user, content: "hi"})
      :ok

      iex> {:error, err} = ALLM.Validate.message(%ALLM.Message{role: :tool, content: "ok"})
      iex> err.reason
      :invalid_message
      iex> {:tool_call_id, :required} in err.errors
      true
  """
  @spec message(Message.t()) :: :ok | {:error, ValidationError.t()}
  def message(%Message{} = msg) do
    case vision_error(msg.content) do
      :no_vision ->
        errors =
          []
          |> validate_role(msg.role)
          |> validate_content(msg.content)
          |> validate_tool_call_id(msg.role, msg.tool_call_id)
          |> Enum.reverse()

        finalize(:invalid_message, errors)

      :vision ->
        {:error,
         ValidationError.new(:vision_not_in_v0_2, [{:content, :image_part}],
           message: "vision content parts are not supported in v0.2 (spec §33)"
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # tool/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Tool{}`.

  Returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`. The top-level
  shape of `:schema` is intentionally not checked — providers differ on
  whether `"type" => "object"` is required — but non-map schemas are rejected.

  ## Examples

      iex> tool = %ALLM.Tool{name: "weather", description: "d", schema: %{}}
      iex> ALLM.Validate.tool(tool)
      :ok

      iex> {:error, err} = ALLM.Validate.tool(%ALLM.Tool{name: "", description: "d", schema: %{}})
      iex> err.reason
      :invalid_tool
      iex> {:name, :empty} in err.errors
      true
  """
  @spec tool(Tool.t()) :: :ok | {:error, ValidationError.t()}
  def tool(%Tool{} = t) do
    errors =
      []
      |> validate_tool_name(t.name)
      |> validate_tool_description(t.description)
      |> validate_tool_schema(t.schema)
      |> Enum.reverse()

    finalize(:invalid_tool, errors)
  end

  # ---------------------------------------------------------------------------
  # thread/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Thread{}`.

  Every message must pass `message/1`. Errors from nested messages carry a
  `[:messages, idx, :field]` path prefix so callers can locate the offender.

  A vision part in any message short-circuits with `:vision_not_in_v0_2`.

  ## Examples

      iex> t = ALLM.Thread.from_messages([%ALLM.Message{role: :user, content: "hi"}])
      iex> ALLM.Validate.thread(t)
      :ok

      iex> t = ALLM.Thread.from_messages([%ALLM.Message{role: :bogus, content: "x"}])
      iex> {:error, err} = ALLM.Validate.thread(t)
      iex> err.reason
      :invalid_thread
      iex> {[:messages, 0, :role], :unknown} in err.errors
      true
  """
  @spec thread(Thread.t()) :: :ok | {:error, ValidationError.t()}
  def thread(%Thread{} = t) do
    with :ok <- check_vision_in_messages(t.messages, &[:messages, &1, :content]) do
      errors =
        t.messages
        |> collect_message_errors(fn idx -> [:messages, idx] end)

      finalize(:invalid_thread, errors)
    end
  end

  # ---------------------------------------------------------------------------
  # session/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Session{}`.

  Enforces status/`pending_*` invariants (spec §5.7) and recursively validates
  the embedded thread. Thread errors carry a `[:thread, :messages, idx, :field]`
  path prefix.

  ## Examples

      iex> ALLM.Validate.session(%ALLM.Session{})
      :ok

      iex> {:error, err} = ALLM.Validate.session(%ALLM.Session{status: :awaiting_user, pending_question: nil})
      iex> err.reason
      :invalid_session
      iex> {:pending_question, :required_for_status} in err.errors
      true
  """
  @spec session(Session.t()) :: :ok | {:error, ValidationError.t()}
  def session(%Session{} = s) do
    with :ok <-
           check_vision_in_messages(s.thread.messages, &[:thread, :messages, &1, :content]) do
      status_errors =
        []
        |> validate_status(s.status)
        |> validate_status_invariants(s)
        |> Enum.reverse()

      errors = status_errors ++ thread_errors(s.thread)

      finalize(:invalid_session, errors)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: request rules
  # ---------------------------------------------------------------------------

  defp validate_messages_non_empty(errs, []), do: [{:messages, :empty} | errs]
  defp validate_messages_non_empty(errs, _list), do: errs

  defp validate_messages_each(errs, messages) do
    nested = collect_message_errors(messages, fn idx -> [:messages, idx] end)
    Enum.reduce(nested, errs, fn e, acc -> [e | acc] end)
  end

  defp validate_tools_each(errs, tools) do
    nested = collect_tool_errors(tools, fn idx -> [:tools, idx] end)
    Enum.reduce(nested, errs, fn e, acc -> [e | acc] end)
  end

  defp validate_tool_names_unique(errs, tools) do
    names = for t <- tools, is_binary(t.name), do: t.name

    if length(names) == length(Enum.uniq(names)) do
      errs
    else
      [{:tools, :duplicate_name} | errs]
    end
  end

  defp validate_temperature(errs, nil), do: errs

  defp validate_temperature(errs, t) when is_number(t) do
    if t >= 0.0 and t <= 2.0 do
      errs
    else
      [{:temperature, :out_of_range} | errs]
    end
  end

  defp validate_temperature(errs, _), do: [{:temperature, :out_of_range} | errs]

  defp validate_max_tokens(errs, nil), do: errs

  defp validate_max_tokens(errs, n) when is_integer(n) and n > 0, do: errs

  defp validate_max_tokens(errs, _), do: [{:max_tokens, :must_be_positive} | errs]

  defp validate_response_format(errs, nil), do: errs
  defp validate_response_format(errs, :text), do: errs
  defp validate_response_format(errs, fmt) when is_map(fmt), do: errs

  defp validate_response_format(errs, _),
    do: [{:response_format, :invalid_shape} | errs]

  defp validate_structured_finalize(errs, true, %{type: :json_schema}), do: errs

  defp validate_structured_finalize(errs, true, _),
    do: [{:structured_finalize, :requires_json_schema} | errs]

  defp validate_structured_finalize(errs, _, _), do: errs

  # ---------------------------------------------------------------------------
  # Internal: message rules
  # ---------------------------------------------------------------------------

  defp validate_role(errs, role) when role in @legal_roles, do: errs
  defp validate_role(errs, _), do: [{:role, :unknown} | errs]

  defp validate_content(errs, content) when is_binary(content), do: errs

  defp validate_content(errs, content) when is_list(content) do
    if Enum.all?(content, &is_map/1) do
      errs
    else
      [{:content, :invalid_type} | errs]
    end
  end

  defp validate_content(errs, _), do: [{:content, :invalid_type} | errs]

  defp validate_tool_call_id(errs, :tool, nil), do: [{:tool_call_id, :required} | errs]
  defp validate_tool_call_id(errs, _role, _id), do: errs

  # ---------------------------------------------------------------------------
  # Internal: tool rules
  # ---------------------------------------------------------------------------

  defp validate_tool_name(errs, ""), do: [{:name, :empty} | errs]

  defp validate_tool_name(errs, name) when is_binary(name) do
    cond do
      name in @reserved_tool_names ->
        [{:name, :reserved_tool_name} | errs]

      Regex.match?(@tool_name_regex, name) ->
        errs

      true ->
        [{:name, :invalid_format} | errs]
    end
  end

  defp validate_tool_name(errs, _), do: [{:name, :invalid_format} | errs]

  defp validate_tool_description(errs, d) when is_binary(d), do: errs
  defp validate_tool_description(errs, _), do: [{:description, :not_a_string} | errs]

  defp validate_tool_schema(errs, s) when is_map(s), do: errs
  defp validate_tool_schema(errs, _), do: [{:schema, :not_a_map} | errs]

  # ---------------------------------------------------------------------------
  # Internal: session rules
  # ---------------------------------------------------------------------------

  defp validate_status(errs, status) when status in @legal_statuses, do: errs
  defp validate_status(errs, _), do: [{:status, :unknown} | errs]

  defp validate_status_invariants(errs, %Session{
         status: :awaiting_user,
         pending_question: nil
       }),
       do: [{:pending_question, :required_for_status} | errs]

  defp validate_status_invariants(errs, %Session{
         status: :awaiting_tools,
         pending_tool_calls: []
       }),
       do: [{:pending_tool_calls, :required_for_status} | errs]

  defp validate_status_invariants(errs, %Session{status: :error, metadata: md}) do
    case Map.get(md || %{}, :error) do
      nil -> [{:metadata, :error_required_for_status} | errs]
      _ -> errs
    end
  end

  defp validate_status_invariants(errs, _), do: errs

  defp thread_errors(%Thread{messages: messages}) do
    collect_message_errors(messages, fn idx -> [:thread, :messages, idx] end)
  end

  # ---------------------------------------------------------------------------
  # Internal: shared helpers
  # ---------------------------------------------------------------------------

  # Returns :ok | {:error, %ValidationError{reason: :vision_not_in_v0_2}}.
  # `path_fun` is `(index -> path_prefix_list)` used on hit.
  defp check_vision_in_messages(messages, path_fun) do
    Enum.reduce_while(Enum.with_index(messages || []), :ok, fn {m, idx}, :ok ->
      case vision_error(m.content) do
        :vision ->
          path = path_fun.(idx)

          {:halt,
           {:error,
            ValidationError.new(:vision_not_in_v0_2, [{path, :image_part}],
              message: "vision content parts are not supported in v0.2 (spec §33)"
            )}}

        :no_vision ->
          {:cont, :ok}
      end
    end)
  end

  # Detects image / image_url parts in a message content list. String or
  # non-list content has no vision parts.
  defp vision_error(content) when is_list(content) do
    if Enum.any?(content, &image_part?/1), do: :vision, else: :no_vision
  end

  defp vision_error(_), do: :no_vision

  defp image_part?(%{type: "image"}), do: true
  defp image_part?(%{type: "image_url"}), do: true
  defp image_part?(%{"type" => "image"}), do: true
  defp image_part?(%{"type" => "image_url"}), do: true
  defp image_part?(_), do: false

  # Validates each message; returns a list of {path ++ [field], reason} tuples.
  defp collect_message_errors(messages, path_prefix_fun) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {m, idx} ->
      case message(m) do
        :ok ->
          []

        {:error, %ValidationError{errors: errs}} ->
          Enum.map(errs, &prepend_path(path_prefix_fun.(idx), &1))
      end
    end)
  end

  defp collect_tool_errors(tools, path_prefix_fun) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn {t, idx} ->
      case tool(t) do
        :ok ->
          []

        {:error, %ValidationError{errors: errs}} ->
          Enum.map(errs, &prepend_path(path_prefix_fun.(idx), &1))
      end
    end)
  end

  defp prepend_path(prefix, {field, reason}) when is_atom(field),
    do: {prefix ++ [field], reason}

  # Reserved for validators that emit pre-pathed list-shaped field keys (none in v0.2).
  defp prepend_path(prefix, {field, reason}) when is_list(field),
    do: {prefix ++ field, reason}

  defp finalize(_reason, []), do: :ok

  defp finalize(reason, errors) do
    {:error, ValidationError.new(reason, errors)}
  end
end
