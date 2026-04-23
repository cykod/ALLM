defmodule ALLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [ALLM.Keys.Store]
    Supervisor.start_link(children, strategy: :one_for_one, name: ALLM.Supervisor)
  end
end
