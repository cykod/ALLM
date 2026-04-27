defmodule ALLM.Validate do
  @moduledoc """
  Pure validators for Layer A input shapes. See spec §16 and Phase 1 design
  sub-phase 1.4.

  Every validator returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`
  with a machine-readable `:errors` list of `{field, reason}` tuples. The
  `field` is either a single atom (top-level) or a path of atoms/indices
  (e.g. `[:messages, 2, :role]`) when the failure is nested.

  Multimodal content parts use the `%ALLM.TextPart{}` and `%ALLM.ImagePart{}`
  Layer A structs (spec §35.6, Phase 14.4). A content list whose elements are
  not one of those two structs is rejected with
  `{:content, :invalid_part_type}` — raw maps in content lists are no longer
  accepted (Phase 14.4 Decision #11; previously the v0.2 validator accepted
  any list of maps and short-circuited image-typed maps with the now-removed
  `:vision_not_in_v0_2` reason).

  Validators are opt-in: constructors like `ALLM.Request.new/2` do not call
  these functions (see Phase 1 design non-obvious decision #7). Users invoke
  `request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`, or
  `image_request/1` (Phase 13.3, spec §35.2.2) explicitly when they need a
  check before dispatch.
  """

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImagePart, ImageRequest, Message, Request, Session, TextPart, Thread, Tool}

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

  # ---------------------------------------------------------------------------
  # message/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.Message{}`.

  Returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`. A content list
  whose elements are not `%ALLM.TextPart{}` or `%ALLM.ImagePart{}` is
  rejected with `{:content, :invalid_part_type}` (Phase 14.4 Decision #11);
  raw maps are no longer accepted in content lists.

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
    errors =
      []
      |> validate_role(msg.role)
      |> validate_content(msg.content)
      |> validate_tool_call_id(msg.role, msg.tool_call_id)
      |> Enum.reverse()

    finalize(:invalid_message, errors)
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
    errors = collect_message_errors(t.messages, fn idx -> [:messages, idx] end)
    finalize(:invalid_thread, errors)
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
    status_errors =
      []
      |> validate_status(s.status)
      |> validate_status_invariants(s)
      |> Enum.reverse()

    errors = status_errors ++ thread_errors(s.thread)

    finalize(:invalid_session, errors)
  end

  # ---------------------------------------------------------------------------
  # image_request/1
  # ---------------------------------------------------------------------------

  @doc """
  Validate an `%ALLM.ImageRequest{}` (spec §35.2.2).

  Returns `:ok` when every rule passes, or
  `{:error, %ALLM.Error.ValidationError{reason: :invalid_image_request, errors: [...]}}`
  accumulating ALL failed rules — no hard-reject (matches `request/1`'s
  accumulator pattern).

  Operation-arity rules:

    * `:generate` requires non-empty `:prompt` AND `:input_images == []`.
    * `:edit` requires non-empty `:prompt` AND `length(:input_images) in 1..2`.
    * `:variation` requires `:prompt in [nil, ""]` AND `length(:input_images) == 1`.

  Field rules: `:n` integer ≥ 1; `:response_format in [:binary, :base64, :url]`;
  `:size in {pos_integer, pos_integer} | String.t() | :auto | nil`;
  `:input_images` a list of `%ALLM.Image{}`; `:mask` `%ALLM.Image{}` or `nil`.

  ## Examples

      iex> ALLM.Validate.image_request(ALLM.ImageRequest.new(prompt: "a kestrel"))
      :ok

      iex> req = ALLM.ImageRequest.new(prompt: nil, operation: :generate)
      iex> {:error, err} = ALLM.Validate.image_request(req)
      iex> err.reason
      :invalid_image_request
      iex> {:prompt, :required_for_operation} in err.errors
      true
  """
  @spec image_request(ImageRequest.t()) :: :ok | {:error, ValidationError.t()}
  def image_request(%ImageRequest{} = req) do
    errors =
      []
      |> validate_image_operation(req.operation)
      |> validate_image_n(req.n)
      |> validate_image_response_format(req.response_format)
      |> validate_image_size(req.size)
      |> validate_image_input_images_shape(req.input_images)
      |> validate_image_input_images_elements(req.input_images)
      |> validate_image_mask(req.mask)
      |> validate_image_operation_arity(req)
      |> Enum.reverse()

    finalize(:invalid_image_request, errors)
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
    if Enum.all?(content, &valid_content_part?/1) do
      errs
    else
      [{:content, :invalid_part_type} | errs]
    end
  end

  defp validate_content(errs, _), do: [{:content, :invalid_type} | errs]

  defp valid_content_part?(%TextPart{}), do: true
  defp valid_content_part?(%ImagePart{}), do: true
  defp valid_content_part?(_), do: false

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

  # ---------------------------------------------------------------------------
  # Internal: image_request rules
  # ---------------------------------------------------------------------------

  @image_operations [:generate, :edit, :variation]
  @image_response_formats [:binary, :base64, :url]

  defp validate_image_operation(errs, op) when op in @image_operations, do: errs
  defp validate_image_operation(errs, _), do: [{:operation, :unknown} | errs]

  defp validate_image_n(errs, n) when is_integer(n) and n >= 1, do: errs
  defp validate_image_n(errs, _), do: [{:n, :must_be_positive} | errs]

  defp validate_image_response_format(errs, fmt) when fmt in @image_response_formats, do: errs
  defp validate_image_response_format(errs, _), do: [{:response_format, :unknown} | errs]

  defp validate_image_size(errs, nil), do: errs
  defp validate_image_size(errs, :auto), do: errs
  defp validate_image_size(errs, s) when is_binary(s), do: errs

  defp validate_image_size(errs, {w, h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: errs

  defp validate_image_size(errs, _), do: [{:size, :invalid_shape} | errs]

  defp validate_image_input_images_shape(errs, list) when is_list(list), do: errs
  defp validate_image_input_images_shape(errs, _), do: [{:input_images, :not_a_list} | errs]

  defp validate_image_input_images_elements(errs, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(errs, fn
      {%Image{}, _idx}, acc -> acc
      {_, idx}, acc -> [{[:input_images, idx], :invalid_image} | acc]
    end)
  end

  defp validate_image_input_images_elements(errs, _), do: errs

  defp validate_image_mask(errs, nil), do: errs
  defp validate_image_mask(errs, %Image{}), do: errs
  defp validate_image_mask(errs, _), do: [{:mask, :invalid_image} | errs]

  defp validate_image_operation_arity(errs, %ImageRequest{operation: :generate} = req) do
    errs
    |> require_prompt_for_op(req.prompt)
    |> require_empty_input_images_for_generate(req.input_images)
  end

  defp validate_image_operation_arity(errs, %ImageRequest{operation: :edit} = req) do
    errs
    |> require_prompt_for_op(req.prompt)
    |> require_input_images_count_in_edit(req.input_images)
  end

  defp validate_image_operation_arity(errs, %ImageRequest{operation: :variation} = req) do
    errs
    |> reject_prompt_for_variation(req.prompt)
    |> require_input_images_count_in_variation(req.input_images)
  end

  defp validate_image_operation_arity(errs, _), do: errs

  defp require_prompt_for_op(errs, prompt) when is_binary(prompt) and prompt != "", do: errs
  defp require_prompt_for_op(errs, _), do: [{:prompt, :required_for_operation} | errs]

  defp require_empty_input_images_for_generate(errs, []), do: errs

  defp require_empty_input_images_for_generate(errs, list) when is_list(list),
    do: [{:input_images, :must_be_empty} | errs]

  defp require_empty_input_images_for_generate(errs, _), do: errs

  defp require_input_images_count_in_edit(errs, list) when is_list(list) do
    if length(list) in 1..2, do: errs, else: [{:input_images, :invalid_count} | errs]
  end

  defp require_input_images_count_in_edit(errs, _), do: errs

  defp reject_prompt_for_variation(errs, prompt) when is_binary(prompt) and prompt != "",
    do: [{:prompt, :not_allowed_for_operation} | errs]

  defp reject_prompt_for_variation(errs, _), do: errs

  defp require_input_images_count_in_variation(errs, list) when is_list(list) do
    if length(list) == 1, do: errs, else: [{:input_images, :invalid_count} | errs]
  end

  defp require_input_images_count_in_variation(errs, _), do: errs
end
