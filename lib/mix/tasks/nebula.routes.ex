defmodule Mix.Tasks.Nebula.Routes do
  @shortdoc "Print the NebulaAPI per-node routing map (local vs remote)"

  @moduledoc """
  Prints where each `defapi` is served, "git lola"-style: one continuous vertical rail per node
  (name + `@short`/`&tag` selectors), with a `●` marking each node that serves a method and the
  rail (`|`) continuing where it isn't local; current node in bold, serves-nothing nodes greyed.

      mix nebula.routes                  # static map (config-known locality)
      mix nebula.routes --available      # live overlay from :pg + Node.list
      mix nebula.routes --follow         # refresh every 5s (implies --available)
      mix nebula.routes --sort locality  # most-local first (also: module [default], name)
      mix nebula.routes --no-color

  ## Glyphs

  Static view: `●` local · `|` not local here (the rail just continues — it makes no claim about
  whether the method runs remotely; use `--available` for that).

  `--available` view (live, from `:pg` + `Node.list`): `●` local · `∆` remote, reachable, live
  worker · `x` configured-local but no worker · `X` node down · `-` not served here · `|` unknown
  (this node can't observe the cluster, e.g. run offline).

  Built from compile-time data (`:nebula_configured_nodes`) — the static view needs no running
  cluster. Works in a single app or at an umbrella root (it loads the project's apps without
  starting them, so the boot-time node policy doesn't fire). For the same map from a running node,
  use `NebulaAPI.Server.print_routes/0` in iex (accepts `available:`, `follow:`, `sort:`, `color:`).

  **Scope:** lists only the modules — and their `defapi` — present in this build (compiled for
  `compiled_node()`); modules from apps not in this release, or not imported/used, are absent.
  See `NebulaAPI.Routes`.
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
