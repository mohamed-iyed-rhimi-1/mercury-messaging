defmodule Gateway.Endpoint do
  @moduledoc "HTTP endpoint: binary WebSocket, health checks, metrics."
  use Plug.Router

  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:match)
  plug(:dispatch)

  # Binary WebSocket — the only transport
  match "/ws" do
    Gateway.BinaryUpgrade.call(conn, [])
  end

  # Health checks — forward strips /health prefix, so HealthPlug sees /live, /ready, /startup
  forward("/health", to: Gateway.HealthPlug)

  # Prometheus metrics
  get "/metrics" do
    PromEx.Plug.call(conn, PromEx.Plug.init(prom_ex_module: Gateway.PromEx, path: "/metrics"))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc false
  def child_spec(_opts) do
    config = Application.get_env(:gateway, __MODULE__, [])
    port = get_in(config, [:http, :port]) || 4000

    Bandit.child_spec(plug: __MODULE__, port: port, scheme: :http)
  end
end
