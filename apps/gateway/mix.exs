defmodule Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :gateway,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: Mix.compilers(),
    ]
  end

  def application do
    [
      extra_applications: [:logger, :opentelemetry_exporter, :opentelemetry],
      mod: {Gateway.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.2"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.10"},
      {:websock_adapter, "~> 0.5"},
      {:joken, "~> 2.6"},
      {:rustler, "~> 0.37.3"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:opentelemetry_api, "~> 1.3"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:prom_ex, "~> 1.9"},
      {:libcluster, "~> 3.4"},
      {:mercury_core, in_umbrella: true},
      {:presence, in_umbrella: true},
      {:persistence, in_umbrella: true},
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end
