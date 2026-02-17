defmodule Gateway.Telemetry do
  @moduledoc "OpenTelemetry and Prometheus metrics setup."
  use Supervisor
  import Telemetry.Metrics

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    OpentelemetryEcto.setup([:persistence, :repo])

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 15_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Metrics definitions for dashboards."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Gateway custom
      last_value("gateway.connections.count"),
      counter("gateway.connection.opened.count"),
      counter("gateway.connection.closed.count"),
      counter("gateway.messages.sent.count"),
      counter("gateway.messages.received.count"),
      counter("gateway.rate_limited.count"),
      summary("gateway.sync.duration", unit: {:native, :millisecond}),

      # Ecto
      summary("persistence.repo.query.total_time", unit: {:native, :millisecond}),

      # VM
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    [{__MODULE__, :emit_connection_count, []}]
  end

  @doc false
  @spec emit_connection_count() :: :ok
  def emit_connection_count do
    count = Gateway.ConnectionRegistry.count()
    :telemetry.execute([:gateway, :connections], %{count: count}, %{})
  end
end
