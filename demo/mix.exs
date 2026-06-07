defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # Per-node app set (like nebula's apps(release_name())): each node starts
      # only its apps. Crucially, DemoApp (the tour) runs ONLY on demo_app.
      apps: apps(release_name()),
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Keyed by RELEASE_NODE: NebulaAPI compiles per node, so each node gets its own
      # bytecode (e.g. the flaky worker raises only on worker@worker3.test).
      build_path: "_build/#{release_node()}"
    ]
  end

  def release_name, do: System.get_env("RELEASE_NAME") || "#{Mix.env()}"
  def release_node, do: System.get_env("RELEASE_NODE") || "#{Mix.env()}"

  # demo_app needs worker+db compiled (to call them as stubs); workers need db
  # (they call @db); db needs only itself. db is in EVERY list → it owns the
  # single per-node libcluster supervisor. The three worker nodes share one
  # release (RELEASE_NAME=worker), hence a single apps("worker") clause.
  defp apps("demo_app"), do: [:demo_app, :worker, :db]
  defp apps("worker"), do: [:worker, :db]
  defp apps("db"), do: [:db]
  defp apps(_), do: [:demo_app, :worker, :db]

  defp deps, do: []
end
