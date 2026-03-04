defmodule Persistence.MixProject do
  use Mix.Project

  def project do
    [
      app: :persistence,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Persistence.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:xandra, "~> 0.19"},
      {:redix, "~> 1.5"},
      {:gnat, "~> 1.8"},
      {:jason, "~> 1.4"},
      {:brod, "~> 4.0"},
      {:mercury_core, in_umbrella: true}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
