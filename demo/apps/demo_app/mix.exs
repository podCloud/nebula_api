defmodule DemoApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_app,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [mod: {DemoApp.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:nebula_api, path: "../../.."},
      {:libcluster, "~> 3.3"},
      {:worker, in_umbrella: true},
      {:db, in_umbrella: true}
    ]
  end
end
