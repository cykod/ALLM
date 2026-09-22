defmodule ALLM.ToolHelp do
  @moduledoc """
  Compact tool disclosure: stub projection, on-demand help, and the built-in
  `tool_help` meta-tool.

  A pure runtime helper (no engine, no adapter, no process state). The chat
  loop uses it to send tools marked `compact: true` (see `ALLM.Tool`) to the
  model as one-line stubs, and to answer the model's requests for the full
  definitions.

  ## How a compact tool reaches the model

  `project/2` replaces every compact tool with a stub that keeps the tool's
  real name, a one-line description ending in an argument hint, and the bare
  schema `{"type": "object"}`. It then appends one `tool_help` tool (see
  `meta_tool/0`) whenever at least one compact tool is present:

      iex> tool =
      ...>   ALLM.Tool.new(
      ...>     name: "create_issue",
      ...>     description: "Create a new issue in a repository. Returns its URL.",
      ...>     schema: %{
      ...>       "type" => "object",
      ...>       "properties" => %{"repo" => %{"type" => "string"}, "title" => %{"type" => "string"}, "body" => %{"type" => "string"}},
      ...>       "required" => ["repo", "title"]
      ...>     },
      ...>     compact: true
      ...>   )
      iex> [stub, meta] = ALLM.ToolHelp.project([tool], nil)
      iex> stub.description
      "Create a new issue in a repository. Args: repo, title [body] [compact]"
      iex> stub.schema
      %{"type" => "object"}
      iex> meta.name
      "tool_help"

  Execution always uses the full tool. Only the list sent to the model is
  projected.

  ## Stubs stay directly callable

  A stub keeps its real name, so the model can call it straight away
  whenever the argument hint is enough. `tool_help` is only needed when the
  model wants the full description or parameter schema, so the common case
  costs no extra round trip. When a compact tool is called without one of
  its required top-level arguments, the call returns a usage error carrying
  the tool's full help instead of running the handler (see `check_args/2`).

  ## The tool list sent to the model is stable

  `project/2` is a pure, deterministic function of the tool list and the
  `tool_choice`: equal inputs give equal outputs. Across the steps of one
  run the list sent to the model therefore never changes, so provider
  prompt caches keyed on the tool definitions keep hitting. Learning about a
  tool through `tool_help` adds a tool result to the conversation; it never
  changes the tool list.

  ## Forcing a compact tool

  When `tool_choice` forces one specific tool and that tool is compact, it
  is sent in full, because a model forced to call a bare stub would have to
  guess its arguments with no chance to ask first. See `project/2` for the
  recognised shapes. One case to watch: a Gemini-native
  `%{"mode" => "ANY", "allowedFunctionNames" => [...]}` naming more than one
  function leaves every stub compact, and if the list omits `"tool_help"`
  the model cannot call `tool_help` at all.

  ## Recognising the meta-tool

  The meta-tool is identified by a string-keyed marker in its `:metadata`
  (`%{"allm_builtin" => "tool_help"}`), not by its name, so the marker
  survives a JSON round trip. When no compact tool is present, a tool of
  your own named `tool_help` is an ordinary tool. When at least one compact
  tool is present, your tool and the injected one share a name, and the
  request is rejected before it is sent with
  `{:tools, :duplicate_name}`. Rename your tool in that case.

  ## Manual mode

  Under whole-loop `mode: :manual` the caller runs every tool call,
  including `tool_help`: the call surfaces like any other, and
  `answer/2` builds the content string to submit for it. Under per-tool
  manual (`manual: true` on individual tools) the meta-tool itself is not
  manual, so the loop runs it automatically.

  Compact tools that the caller executes never pass through the tool
  runner, so they get no usage-error check. Call `check_args/2` yourself
  if you want it.

  ## Calling the tool runner directly

  `ALLM.ToolRunner.run_tool_calls/3` and `ALLM.ToolRunner.stream_tool_calls/3`
  apply the required-argument check to compact tools as well. They answer a
  `tool_help` call only when the tool list you pass contains `meta_tool/0`
  (use `with_meta_tool/1` to add it).
  """

  alias ALLM.{Tool, ToolCall}

  @meta_tool_name "tool_help"
  @marker_key "allm_builtin"
  @meta_description "Tools whose description ends in [compact] are summarised. " <>
                      "Call tool_help with their names to get each one's full description " <>
                      "and JSON parameter schema before calling it, unless the Args hint is enough."
  @stub_schema %{"type" => "object"}
  @summary_max 160

  # ---------------------------------------------------------------------------
  # Public, documented
  # ---------------------------------------------------------------------------

  @doc """
  The built-in `tool_help` meta-tool.

  Plain data with no handler, so it serializes like any other tool. It
  takes `{"names": ["tool_name", ...]}` and is answered by `render/2`.

  ## Examples

      iex> meta = ALLM.ToolHelp.meta_tool()
      iex> {meta.name, meta.handler, meta.metadata}
      {"tool_help", nil, %{"allm_builtin" => "tool_help"}}
      iex> meta.schema["required"]
      ["names"]
  """
  @spec meta_tool() :: Tool.t()
  def meta_tool do
    %Tool{
      name: @meta_tool_name,
      description: @meta_description,
      schema: %{
        "type" => "object",
        "properties" => %{"names" => %{"type" => "array", "items" => %{"type" => "string"}}},
        "required" => ["names"]
      },
      handler: nil,
      manual: false,
      compact: false,
      metadata: %{@marker_key => @meta_tool_name}
    }
  end

  @doc """
  Whether `tool` is the built-in meta-tool, judged by its metadata marker,
  not its name. Never raises.

  ## Examples

      iex> ALLM.ToolHelp.meta_tool?(ALLM.ToolHelp.meta_tool())
      true
      iex> ALLM.ToolHelp.meta_tool?(ALLM.Tool.new(name: "tool_help", description: "mine", schema: %{}))
      false
  """
  @spec meta_tool?(Tool.t()) :: boolean()
  def meta_tool?(tool), do: match?(%Tool{metadata: %{@marker_key => @meta_tool_name}}, tool)

  @doc """
  Whether `tool` is compact. Only `compact: true` counts: any other value
  (including a badly-typed one from a hand-built struct or decoded JSON)
  means the tool is sent in full.

  ## Examples

      iex> ALLM.ToolHelp.compact?(ALLM.Tool.new(name: "t", description: "d", schema: %{}, compact: true))
      true
      iex> ALLM.ToolHelp.compact?(%ALLM.Tool{name: "t", description: "d", schema: %{}, compact: :yes})
      false
  """
  @spec compact?(Tool.t()) :: boolean()
  def compact?(%Tool{compact: compact}), do: compact == true

  @doc """
  Project a resolved tool list into the list sent to the model.

  Every compact tool is replaced by its stub, in place, and `meta_tool/0` is
  appended when at least one compact tool is present. Non-compact tools are
  returned unchanged, so a list with no compact tool comes back `==` to the
  input. The result is deterministic: equal inputs give equal outputs.

  When `tool_choice` forces a single tool by name, that tool is sent in
  full even if it is compact. The forced name is read from:

    * a binary tool name, or `{:tool, name}`;
    * `%{"type" => "tool", "name" => name}` (string or atom keys);
    * `%{"type" => "function", "function" => %{"name" => name}}` and the flat
      `%{"type" => "function", "name" => name}` (string or atom keys);
    * `%{"mode" => "ANY", "allowedFunctionNames" => [name]}` with exactly one
      name (string or atom keys).

  `:auto`, `:none`, `:required`, `nil` and any other shape leave every
  compact tool stubbed.

  ## Examples

      iex> full = ALLM.Tool.new(name: "search", description: "Search the web.", schema: %{})
      iex> compact = ALLM.Tool.new(name: "lookup", description: "Look up a record. Slow.", schema: %{}, compact: true)
      iex> ALLM.ToolHelp.project([full, compact], :auto) |> Enum.map(& &1.description)
      ["Search the web.", "Look up a record. [compact]", ALLM.ToolHelp.meta_tool().description]
      iex> ALLM.ToolHelp.project([full, compact], {:tool, "lookup"}) |> Enum.map(& &1.description) |> Enum.at(1)
      "Look up a record. Slow."
      iex> ALLM.ToolHelp.project([full], :auto) == [full]
      true
  """
  @spec project([Tool.t()], ALLM.Request.tool_choice() | {:tool, String.t()}) :: [Tool.t()]
  def project(tools, tool_choice) do
    forced = forced_name(tool_choice)

    tools
    |> with_meta_tool()
    |> Enum.map(fn tool ->
      if compact?(tool) and tool.name != forced, do: stub(tool), else: tool
    end)
  end

  @doc """
  Render the full help for the tools named in a `tool_help` call's
  arguments.

  `args` is `%{"names" => [name, ...]}`, `%{"names" => name}`, or the
  atom-keyed equivalent. Each requested name gets one section, in request
  order and deduplicated, and sections are separated by a blank line. A
  known tool, compact or not, renders as its name, full description and
  compact JSON schema. An unknown name renders a note listing the compact
  tools (`(none)` when there are none). Any other `args` shape returns a
  short usage string ending in the same list. Never raises:
  a schema that cannot be encoded as JSON is shown with `inspect/1`.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "lookup", description: "Look up a record.", schema: %{"type" => "object"}, compact: true)
      iex> ALLM.ToolHelp.render([tool], %{"names" => ["lookup"]})
      "## lookup\\nLook up a record.\\nParameters (JSON Schema): {\\"type\\":\\"object\\"}"
      iex> ALLM.ToolHelp.render([tool], %{"names" => ["nope"]})
      "## nope\\nUnknown tool. Compact tools: lookup"
      iex> ALLM.ToolHelp.render([tool], %{})
      "tool_help expects {\\"names\\": [\\"tool_name\\", ...]}. Compact tools: lookup"
  """
  @spec render([Tool.t()], map()) :: String.t()
  def render(tools, args) do
    case requested_names(args) do
      {:ok, names} ->
        names
        |> Enum.uniq()
        |> Enum.map_join("\n\n", &render_section(tools, &1))

      :error ->
        ~s(tool_help expects {"names": ["tool_name", ...]}. Compact tools: ) <>
          compact_names(tools)
    end
  end

  @doc """
  Build the content string answering a `tool_help` call, for callers that
  run tool calls themselves (for example under `mode: :manual`). Equal to
  `render/2` on the call's arguments, with `nil` arguments treated as `%{}`.

  Pass the full tool list, including `meta_tool/0`.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "lookup", description: "Look up a record.", schema: %{}, compact: true)
      iex> call = ALLM.ToolCall.new(id: "call_1", name: "tool_help", arguments: %{"names" => ["lookup"]})
      iex> ALLM.ToolHelp.answer([tool, ALLM.ToolHelp.meta_tool()], call)
      "## lookup\\nLook up a record.\\nParameters (JSON Schema): {}"
  """
  @spec answer([Tool.t()], ToolCall.t()) :: String.t()
  def answer(tools, %ToolCall{} = tool_call), do: render(tools, tool_call.arguments || %{})

  @doc """
  Check that a compact tool's call supplies every required top-level
  argument.

  Returns `:ok` for any tool that is not compact, so full tools behave
  exactly as they would without this check. For a compact tool, returns
  `{:error, usage}` when a name in the schema's `"required"` list is absent
  from `args`. `usage` names the missing arguments in `"required"` order and
  ends with the tool's full help (see `render/2`), so the model can correct
  its call in one round trip even if it never called `tool_help`. The chat
  loop routes this error through your `on_tool_error` policy like any
  handler error.

  An argument counts as present under its string key or an existing atom
  of the same name. Only presence is checked: no types, no nesting, no
  unknown-key rejection. Never raises: non-map `args` count as no arguments,
  and a schema without a `"required"` list has no required arguments.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "lookup", description: "Look up a record.", schema: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}, "required" => ["id"]}, compact: true)
      iex> ALLM.ToolHelp.check_args(tool, %{"id" => "42"})
      :ok
      iex> {:error, usage} = ALLM.ToolHelp.check_args(tool, %{})
      iex> String.split(usage, "\\n") |> Enum.take(3)
      ["missing required argument(s): id", "", "## lookup"]
  """
  @spec check_args(Tool.t(), map()) :: :ok | {:error, String.t()}
  def check_args(%Tool{} = tool, args) do
    args = if is_map(args), do: args, else: %{}

    missing =
      if compact?(tool),
        do: tool.schema |> required_names() |> Enum.reject(&present?(args, &1)),
        else: []

    case missing do
      [] ->
        :ok

      names ->
        {:error,
         "missing required argument(s): " <>
           Enum.join(names, ", ") <>
           "\n\n" <> render([tool], %{"names" => [tool.name]})}
    end
  end

  # ---------------------------------------------------------------------------
  # Test seams
  # ---------------------------------------------------------------------------

  @doc false
  @spec summary(Tool.t()) :: String.t()
  def summary(%Tool{summary: summary}) when is_binary(summary) and summary != "", do: summary

  def summary(%Tool{description: description}) when is_binary(description) do
    first_line =
      description
      |> String.trim()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.trim_trailing()

    sentence =
      case Regex.run(~r/^.*?[.!?](?=\s|\z)/u, first_line) do
        [match] -> match
        nil -> first_line
      end

    if String.length(sentence) > @summary_max,
      do: String.slice(sentence, 0, @summary_max - 3) <> "...",
      else: sentence
  end

  def summary(%Tool{}), do: ""

  @doc false
  @spec signature(Tool.t()) :: String.t() | nil
  def signature(%Tool{schema: %{"properties" => props} = schema}) when is_map(props) do
    if map_size(props) == 0 do
      "Args: none"
    else
      required = schema |> required_names() |> Enum.filter(&Map.has_key?(props, &1))
      optional = props |> Map.keys() |> Enum.reject(&(&1 in required)) |> Enum.sort()

      required_part = Enum.join(required, ", ")
      optional_part = if optional == [], do: "", else: "[" <> Enum.join(optional, ", ") <> "]"

      "Args: " <> Enum.join(Enum.reject([required_part, optional_part], &(&1 == "")), " ")
    end
  end

  def signature(%Tool{}), do: nil

  @doc false
  @spec stub(Tool.t()) :: Tool.t()
  def stub(%Tool{} = tool) do
    description =
      [summary(tool), signature(tool), "[compact]"]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    %{tool | description: description, schema: @stub_schema, handler: nil}
  end

  @doc false
  @spec with_meta_tool([Tool.t()]) :: [Tool.t()]
  def with_meta_tool(tools) do
    if Enum.any?(tools, &compact?/1) and not Enum.any?(tools, &meta_tool?/1),
      do: tools ++ [meta_tool()],
      else: tools
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp forced_name(name) when is_binary(name), do: name
  defp forced_name({:tool, name}) when is_binary(name), do: name
  defp forced_name(%{} = choice), do: forced_name_from_map(stringify_keys(choice))
  defp forced_name(_), do: nil

  defp forced_name_from_map(%{"type" => "tool", "name" => name}) when is_binary(name), do: name

  defp forced_name_from_map(%{"type" => "function", "function" => %{} = function}) do
    case stringify_keys(function) do
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp forced_name_from_map(%{"type" => "function", "name" => name}) when is_binary(name),
    do: name

  defp forced_name_from_map(%{"mode" => "ANY", "allowedFunctionNames" => [name]})
       when is_binary(name),
       do: name

  defp forced_name_from_map(_), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp requested_names(args) when is_map(args) do
    case Map.get(args, "names", Map.get(args, :names)) do
      name when is_binary(name) ->
        {:ok, [name]}

      [_ | _] = names ->
        if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: :error

      _ ->
        :error
    end
  end

  defp requested_names(_), do: :error

  defp render_section(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      %Tool{} = tool ->
        "## #{name}\n#{tool.description}\nParameters (JSON Schema): #{encode_schema(tool.schema)}"

      nil ->
        "## #{name}\nUnknown tool. Compact tools: " <> compact_names(tools)
    end
  end

  defp encode_schema(schema) do
    Jason.encode!(schema)
  rescue
    _ in [Jason.EncodeError, Protocol.UndefinedError] -> inspect(schema)
  end

  defp compact_names(tools) do
    case Enum.filter(tools, &(compact?(&1) and not meta_tool?(&1))) do
      [] -> "(none)"
      compact -> Enum.map_join(compact, ", ", & &1.name)
    end
  end

  defp required_names(%{"required" => required}) when is_list(required),
    do: Enum.filter(required, &is_binary/1)

  defp required_names(_), do: []

  defp present?(args, name) do
    Map.has_key?(args, name) or
      try do
        Map.has_key?(args, String.to_existing_atom(name))
      rescue
        ArgumentError -> false
      end
  end
end
