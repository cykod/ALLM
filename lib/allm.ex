defmodule ALLM do
  @moduledoc """
  Top-level facade for the ALLM library — provider-neutral LLM execution with
  first-class streaming and serializable conversation state.

  ALLM is organized into four conceptual layers (see
  `steering/allm_engine_session_streaming_spec_v0_2.md` §2):

    * **Layer A — Serializable data.** Plain structs (`ALLM.Message`,
      `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, …) that
      round-trip through `:erlang.term_to_binary/1` and JSON via
      `ALLM.Serializer`. No PIDs, refs, funs, or API keys.
    * **Layer B — Runtime.** `ALLM.Engine` plus the `ALLM.Adapter`,
      `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, and `ALLM.ToolResultEncoder`
      behaviours. Holds the non-serializable dependencies (modules, funs,
      Finch names, keys resolved at call time).
    * **Layer C — Stateless execution.** `generate/3`, `stream_generate/3`,
      `step/3`, `stream_step/3`, `chat/3`, `stream/3` on this module. Each
      call takes an engine explicitly.
    * **Layer D — Stateful continuation.** `ALLM.Session` operations over a
      persisted `%ALLM.Session{}`.

  Phase 1 (this release) ships Layer A: the data structs, `ALLM.Validate`,
  `ALLM.Serializer`, and the constructors on this facade. Layers B/C/D
  (engines, adapters, streaming, sessions) land in later phases.

  ## Example

      iex> messages = [ALLM.system("Be helpful."), ALLM.user("Name three primes.")]
      iex> req = ALLM.request(messages, model: "fake:gpt-test")
      iex> :ok = ALLM.Validate.request(req)
      iex> json = ALLM.Serializer.to_json!(req)
      iex> {:ok, ^req} = ALLM.Serializer.from_json(json)

  See `steering/allm_engine_session_streaming_spec_v0_2.md` §4 for the full
  public API surface.
  """

  alias ALLM.{Message, Request, Tool}

  @doc """
  Build a system-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.system("be helpful")
      %ALLM.Message{role: :system, content: "be helpful", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec system(String.t()) :: Message.t()
  def system(text), do: %Message{role: :system, content: text}

  @doc """
  Build a user-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.user("hi")
      %ALLM.Message{role: :user, content: "hi", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec user(String.t()) :: Message.t()
  def user(text), do: %Message{role: :user, content: text}

  @doc """
  Build an assistant-role `%ALLM.Message{}` from a text string.

  ## Examples

      iex> ALLM.assistant("hello")
      %ALLM.Message{role: :assistant, content: "hello", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec assistant(String.t()) :: Message.t()
  def assistant(text), do: %Message{role: :assistant, content: text}

  @doc """
  Build a tool-role `%ALLM.Message{}` carrying a tool-call result.

  `tool_call_id` must match the `:id` of the `ALLM.ToolCall` that produced
  this result so the provider can match results to calls. `content` is either
  a binary or a JSON-serializable map.

  ## Examples

      iex> msg = ALLM.tool_result("call_abc", %{ok: true})
      iex> {msg.role, msg.tool_call_id, msg.content}
      {:tool, "call_abc", %{ok: true}}
  """
  @spec tool_result(String.t(), String.t() | map()) :: Message.t()
  def tool_result(tool_call_id, content) do
    %Message{role: :tool, tool_call_id: tool_call_id, content: content}
  end

  @doc """
  Build an `%ALLM.Tool{}` from keyword opts. Delegates to `ALLM.Tool.new/1`.

  `:name`, `:description`, and `:schema` are required; omitting any raises
  `ArgumentError`. `:handler` is optional.

  ## Examples

      iex> tool = ALLM.tool(name: "weather", description: "weather by city", schema: %{"type" => "object"})
      iex> {tool.name, tool.description}
      {"weather", "weather by city"}
  """
  @spec tool(keyword()) :: Tool.t()
  def tool(opts), do: Tool.new(opts)

  @doc """
  Build the canonical tagged map for a JSON-schema response format (spec §5.4).

  Returns `%{type: :json_schema, name: name, schema: schema, strict: boolean}`.
  `:strict` defaults to `true`; pass `strict: false` to relax provider-side
  schema enforcement.

  ## Examples

      iex> ALLM.json_schema("person", %{"type" => "object"})
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: true}

      iex> ALLM.json_schema("person", %{"type" => "object"}, strict: false)
      %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: false}
  """
  @spec json_schema(String.t(), map(), keyword()) :: map()
  def json_schema(name, schema, opts \\ []) do
    %{
      type: :json_schema,
      name: name,
      schema: schema,
      strict: Keyword.get(opts, :strict, true)
    }
  end

  @doc """
  Build an `%ALLM.Request{}` from a list of messages and keyword opts.
  Delegates to `ALLM.Request.new/2`.

  Does **not** validate — validation runs at the adapter boundary (Phase 5)
  or via an explicit `ALLM.Validate.request/1` call. Keeping construction
  composable matches the Non-obvious Decision #7 of the Phase 1 design:
  `request/2` returns a `%Request{}` directly, not `{:ok | :error}`.

  ## Examples

      iex> req = ALLM.request([ALLM.user("hi")])
      iex> {length(req.messages), req.stream, req.tools}
      {1, false, []}

      iex> req = ALLM.request([ALLM.user("hi")], model: "gpt-4.1-mini", response_format: %{type: :json_object})
      iex> {req.model, req.response_format}
      {"gpt-4.1-mini", %{type: :json_object}}
  """
  @spec request([Message.t()], keyword()) :: Request.t()
  def request(messages, opts \\ []), do: Request.new(messages, opts)
end
