defmodule ALLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ALLM.Keys.Store,
      # Default Finch pool for streaming adapters. The :http1 pin is
      # load-bearing per spec §7.2 — HTTP/2 flow control breaks for request
      # bodies > 64 KB on the streaming path. Engines that want a custom
      # Finch may inject one via `adapter_opts: [finch_name: MyApp.Finch]`.
      # `protocols: [:http1]` (plural) required since Finch 0.20 — keeps HTTP/2 out per spec §7.2.
      {Finch, name: ALLM.Finch, pools: %{default: [protocols: [:http1]]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ALLM.Supervisor)
  end
end
