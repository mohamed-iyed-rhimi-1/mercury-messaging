defmodule Mercury.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :underspecs, :unmatched_returns]
      ]
    ]
  end

  defp releases do
    [
      mercury: [
        applications: [
          opentelemetry_exporter: :permanent,
          opentelemetry: :temporary,
          mercury_core: :permanent,
          gateway: :permanent,
          persistence: :permanent,
          presence: :permanent,
          fanout: :permanent
        ]
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
