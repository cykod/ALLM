defmodule ALLM.Tool do
  @moduledoc "See spec §5.2 and §15."

  @type schema :: map()

  @type handler_result ::
          {:ok, term()}
          | {:error, term()}
          | {:ask_user, String.t()}
          | {:ask_user, String.t(), keyword()}
          | {:halt, atom(), term()}

  @type handler ::
          (map() -> handler_result())
          | (map(), keyword() -> handler_result())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: schema(),
          handler: handler() | nil,
          metadata: map()
        }

  defstruct [:name, :description, :schema, :handler, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)
end
