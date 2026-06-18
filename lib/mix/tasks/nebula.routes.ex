defmodule Mix.Tasks.Nebula.Routes do
  @shortdoc "Print the NebulaAPI per-node routing map (local vs remote)"

  @moduledoc """
  Prints where each `defapi` runs (local) vs forwards over RPC (remote), "git lola"-style: one
  vertical rail per node (name + `@short`/`&tag` selectors), then a `●` (local) / `-` (remote)
  row per `Module.fun/arity`, current node in bold.

      mix nebula.routes
      mix nebula.routes --no-color

  Built from compile-time data (`:nebula_configured_nodes`) — no running cluster needed. Works
  in a single app or at an umbrella root (it loads the project's apps without starting them, so
  the boot-time node policy doesn't fire). For the same view from a running node, use
  `NebulaAPI.Server.print_routes/0` in iex.

  **Scope:** lists only the `defapi` compiled into this build/release — a node whose release
  carries a subset of an umbrella's apps won't show the other apps' methods. See
  `NebulaAPI.Routes`.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {parsed, _, _} =
      OptionParser.parse(argv,
        strict: [color: :boolean, available: :boolean, follow: :boolean, sort: :string]
      )

    Mix.Task.run("compile")
    load_project_apps()

    NebulaAPI.Routes.print(
      color: Keyword.get(parsed, :color, true),
      available: parsed[:available] || parsed[:follow] || false,
      follow: parsed[:follow] || false,
      sort: parse_sort(parsed[:sort])
    )
  end

  defp parse_sort("name"), do: :name
  defp parse_sort("locality"), do: :locality
  defp parse_sort(_), do: :module

  # Load (do NOT start) each app of the project so its modules are discoverable. Loading is
  # side-effect-free; starting would trip the boot-time node policy on a 0.5 build.
  defp load_project_apps do
    apps =
      case Mix.Project.apps_paths() do
        nil -> [Mix.Project.config()[:app]]
        map -> Map.keys(map)
      end

    Enum.each(apps, fn
      nil -> :ok
      app -> Application.load(app)
    end)
  end
end
