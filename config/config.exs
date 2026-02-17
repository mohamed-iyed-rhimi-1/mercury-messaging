import Config

config :gateway, Gateway.Endpoint, http: [port: 4000]

config :gateway, Gateway.Auth, jwt_secret: "dev_secret"

config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "gateway-headless",
        application_name: "mercury",
        namespace: "mercury"
      ]
    ]
  ]

config :gateway, Gateway.RateLimiter,
  default_rate: 100,
  default_burst: 150

# Persistence
config :persistence, Persistence.Repo,
  username: "mercury",
  password: "mercury_dev",
  hostname: "localhost",
  database: "mercury_dev",
  pool_size: 10

config :persistence, Persistence.Scylla,
  enabled: true,
  opts: [nodes: ["localhost:9042"], keyspace: "mercury"]

config :persistence, Persistence.Cache,
  enabled: true,
  opts: [host: "localhost", port: 6380, password: "mercury"]

config :persistence, Persistence.Events,
  enabled: true,
  opts: %{host: "127.0.0.1", port: 4222}

config :persistence, Persistence.Audit,
  enabled: true,
  partitions: 1

config :persistence, ecto_repos: [Persistence.Repo]

# OpenTelemetry
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"

# PromEx
config :gateway, Gateway.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled
