defmodule Gateway.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Cluster.Supervisor, [topologies, [name: Gateway.ClusterSupervisor]]},
      Gateway.PromEx,
      Gateway.Telemetry,
      Gateway.ConnectionRegistry,
      Gateway.SyncConsumer,
      Gateway.GcWorker,
      {Task.Supervisor, name: Gateway.TaskSupervisor},
      Gateway.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Gateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
