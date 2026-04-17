defmodule ALLM do
  @moduledoc """
  Top-level facade for the ALLM library.

  See `steering/allm_engine_session_streaming_spec_v0_2.md` §4 for the full public API.
  Execution functions (`generate/3`, `stream_generate/3`, `step/3`, `stream_step/3`,
  `chat/3`, `stream/3`) are not yet implemented — this module currently provides
  builders for messages, tools, and requests.
  """

  alias ALLM.{Message, Request, Tool}

  @spec system(String.t()) :: Message.t()
  def system(text), do: %Message{role: :system, content: text}

  @spec user(String.t()) :: Message.t()
  def user(text), do: %Message{role: :user, content: text}

  @spec assistant(String.t()) :: Message.t()
  def assistant(text), do: %Message{role: :assistant, content: text}

  @spec tool_result(String.t(), String.t() | map()) :: Message.t()
  def tool_result(tool_call_id, content) do
    %Message{role: :tool, tool_call_id: tool_call_id, content: content}
  end

  @spec tool(keyword()) :: Tool.t()
  def tool(opts), do: Tool.new(opts)

  @spec json_schema(String.t(), map(), keyword()) :: map()
  def json_schema(name, schema, opts \\ []) do
    %{
      type: :json_schema,
      name: name,
      schema: schema,
      strict: Keyword.get(opts, :strict, true)
    }
  end

  @spec request([Message.t()], keyword()) :: Request.t()
  def request(messages, opts \\ []) do
    struct!(Request, [{:messages, messages} | opts])
  end
end
