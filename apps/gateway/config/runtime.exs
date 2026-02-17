import Config

config :gateway, Gateway.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")],
  server: true,
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64)

config :gateway, Gateway.Auth,
  jwt_secret: System.get_env("JWT_SECRET") || "dev_secret"

config :gateway, Gateway.RateLimiter,
  default_rate: String.to_integer(System.get_env("RATE_LIMIT") || "100"),
  default_burst: String.to_integer(System.get_env("RATE_BURST") || "150")
