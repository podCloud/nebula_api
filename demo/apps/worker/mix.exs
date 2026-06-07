defmodule Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :worker,
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

  def application, do: [mod: {Worker.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:nebula_api, path: "../../.."},
      {:libcluster, "~> 3.3"},
      {:db, in_umbrella: true}
    ]
  end
end
