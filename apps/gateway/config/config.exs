import Config

config :gateway, Gateway.Endpoint,
  http: [port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64),
  pubsub_server: Gateway.PubSub

config :gateway, Gateway.Auth,
  jwt_secret: "dev_secret"

config :gateway, Gateway.RateLimiter,
  default_rate: 100,
  default_burst: 150
