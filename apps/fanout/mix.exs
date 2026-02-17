defmodule Fanout.MixProject do
  use Mix.Project

  def project do
    [
      app: :fanout,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fanout.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.2"},
      {:gateway, in_umbrella: true}
    ]
  end
end
