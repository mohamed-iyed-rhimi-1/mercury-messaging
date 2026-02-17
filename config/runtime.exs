import Config

config :gateway, Gateway.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")]

config :gateway, Gateway.Auth, jwt_secret: System.get_env("JWT_SECRET") || "dev_secret"

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4318"

config :opentelemetry,
  traces_exporter:
    if(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"), do: :otlp, else: :none)

# ── Persistence: read from env in prod, use defaults in dev ──
if config_env() == :prod do
  config :persistence, Persistence.Repo,
    url:
      System.get_env("DATABASE_URL") || "ecto://mercury:mercury_dev@localhost:5432/mercury_dev",
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  scylla_nodes =
    (System.get_env("SCYLLA_NODES") || "localhost:9042")
    |> String.split(",")
    |> Enum.map(&String.trim/1)

  config :persistence, Persistence.Scylla,
    enabled: true,
    opts: [nodes: scylla_nodes, keyspace: "mercury"]

  nats_url = URI.parse(System.get_env("NATS_URL") || "nats://localhost:4222")

  config :persistence, Persistence.Events,
    enabled: true,
    opts: %{host: nats_url.host || "localhost", port: nats_url.port || 4222}

  dragonfly_url = System.get_env("DRAGONFLY_URL") || "redis://:mercury@localhost:6379"
  uri = URI.parse(dragonfly_url)
  dragon_pass = if uri.userinfo, do: String.replace(uri.userinfo, ~r/^.*:/, ""), else: "mercury"

  config :persistence, Persistence.Cache,
    enabled: true,
    opts: [host: uri.host || "localhost", port: uri.port || 6379, password: dragon_pass]

  redpanda_host = System.get_env("REDPANDA_HOST") || "redpanda.mercury.svc"
  redpanda_port = String.to_integer(System.get_env("REDPANDA_PORT") || "9092")

  config :persistence, Persistence.Audit,
    enabled: true,
    partitions: 1,
    endpoints: [{redpanda_host, redpanda_port}]
end

if config_env() == :test do
  config :persistence, Persistence.Repo, pool: Ecto.Adapters.SQL.Sandbox
  config :persistence, Persistence.Scylla, enabled: false
  config :persistence, Persistence.Cache, enabled: false
  config :persistence, Persistence.Events, enabled: false
  config :persistence, Persistence.Audit, enabled: false
end
