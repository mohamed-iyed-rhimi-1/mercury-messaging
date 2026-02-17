defmodule Gateway.PromEx do
  @moduledoc "Prometheus metrics via PromEx — exposes /metrics endpoint."
  use PromEx, otp_app: :gateway

  @impl true
  def plugins do
    [PromEx.Plugins.Beam]
  end

  @impl true
  def dashboards do
    [{:prom_ex, "beam.json"}]
  end
end
