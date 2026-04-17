defmodule ALLM.Engine do
  @moduledoc """
  See spec §6.

  `middleware` must stay `[]` in v0.2 (§29) — reserved for a later version.
  """

  alias ALLM.Tool

  @type retry :: :default | false | keyword()

  @type t :: %__MODULE__{
          adapter: module() | nil,
          adapter_opts: keyword(),
          model: String.t() | nil,
          tools: [Tool.t()],
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          image_adapter: module() | nil,
          params: map(),
          context: map(),
          retry: retry(),
          middleware: [module()],
          metadata: map()
        }

  defstruct [
    :adapter,
    :model,
    :tool_executor,
    :tool_result_encoder,
    :image_adapter,
    adapter_opts: [],
    tools: [],
    params: %{},
    context: %{},
    retry: :default,
    middleware: [],
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec put_tool(t(), Tool.t()) :: t()
  def put_tool(%__MODULE__{tools: tools} = e, %Tool{} = tool),
    do: %{e | tools: tools ++ [tool]}

  @spec put_tools(t(), [Tool.t()]) :: t()
  def put_tools(%__MODULE__{tools: existing} = e, more),
    do: %{e | tools: existing ++ more}

  @spec put_param(t(), atom() | String.t(), term()) :: t()
  def put_param(%__MODULE__{params: p} = e, key, value),
    do: %{e | params: Map.put(p, key, value)}

  @spec put_context(t(), atom() | String.t(), term()) :: t()
  def put_context(%__MODULE__{context: c} = e, key, value),
    do: %{e | context: Map.put(c, key, value)}

  @spec with_model(t(), String.t()) :: t()
  def with_model(%__MODULE__{} = e, model), do: %{e | model: model}
end
