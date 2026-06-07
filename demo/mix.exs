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
      # Keyed by RELEASE_NAME so the 5 containers don't collide in _build, and
      # each gets its own per-node bytecode.
      build_path: "_build/#{release_name()}"
    ]
  end

  def release_name, do: System.get_env("RELEASE_NAME") || "#{Mix.env()}"

  # demo_app needs worker+db compiled (to call them as stubs); workers need db
  # (they call @db); db needs only itself. db is in EVERY list → it owns the
  # single per-node libcluster supervisor (see Task 3). The db node no longer
  # carries the worker app: discovery is per-app now, so a node only serves what
  # its own apps' modules compile as local.
  defp apps("demo_app"), do: [:demo_app, :worker, :db]
  defp apps("worker1"), do: [:worker, :db]
  defp apps("worker2"), do: [:worker, :db]
  defp apps("worker3"), do: [:worker, :db]
  defp apps("db"), do: [:db]
  defp apps(_), do: [:demo_app, :worker, :db]

  defp deps, do: []
end
