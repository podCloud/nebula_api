defmodule Db.MixProject do
  use Mix.Project

  def project do
    [
      app: :db,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      # :nebula guards against forgetting nebula_api_server() in the supervisor.
      compilers: Mix.compilers() ++ [:nebula],
      deps: deps()
    ]
  end

  def application, do: [mod: {Db.Application, []}, extra_applications: [:logger]]

  # Conditional dep (pattern from nebula's podcast/mix.exs): Cachex only on the db build.
  defp deps do
    [{:nebula_api, path: "../../.."}, {:libcluster, "~> 3.3"}] ++
      cachex_dep(System.get_env("RELEASE_NAME"))
  end

  defp cachex_dep("db"), do: [{:cachex, "~> 3.6"}]
  defp cachex_dep(_), do: []
end
