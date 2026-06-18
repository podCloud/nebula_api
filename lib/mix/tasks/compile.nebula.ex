defmodule Mix.Tasks.Compile.Nebula do
  @moduledoc """
  Mix compiler that guards against forgetting `nebula_api_server/0`.

  Opt in from **each** consuming app's `mix.exs` (per-app — see the umbrella note):

      def project do
        [
          # ...
          compilers: Mix.compilers() ++ [:nebula]
        ]
      end

  It runs after `:app`, reads the persisted NebulaAPI attributes from the beams, and:

    * **fails** when the app has local methods on this build but no `nebula_api_server()`
      is wired (workers that would never start);
    * **warns** when a server is wired but the app defines no `defapi` methods at all
      (a server with nothing to serve — likely a leftover `nebula_api_server()`).

  ## Umbrella note

  Per-app: it must be in the `compilers:` of each child app. `mix compile` in an umbrella
  recurses into the child apps and runs *their* `compilers:`; adding `:nebula` to the umbrella
  **root** `mix.exs` does **nothing** (the root's custom compilers are not invoked for an
  `apps_path` project). There is no single root-level switch — opt each app in.
  """

  use Mix.Task.Compiler

  # Per child app: `mix compile` recurses into each app and runs its own compilers, so this runs
  # once per app that lists `:nebula` (with `:app` set). NOT invoked at the umbrella root
  # (apps_path, no `:app`) — a root-only placement does nothing; opt each app in.
  @recursive true

  @impl true
  def run(_argv) do
    case Mix.Project.config()[:app] do
      nil ->
        {:noop, []}

      app ->
        case NebulaAPI.CompilerCheck.verify(modules_attrs()) do
          :ok ->
            {:noop, []}

          {:warn, :server_without_methods} ->
            # A wired server with nothing to serve is a smell, not a build-breaker.
            Mix.shell().info(warning_message(app))
            {:noop, []}

          {:error, local_modules} ->
            message = error_message(app, local_modules)
            Mix.shell().error(message)
            {:error, [diagnostic(message)]}
        end
    end
  end

  defp error_message(app, modules) do
    app_module = application_module(app)
    app_label = "   Application: "

    app_line =
      if app_module do
        caret_indent = String.duplicate(" ", String.length(app_label))

        app_label <>
          inspect(app_module) <>
          "\n" <>
          caret_indent <> "^------ hint: add nebula_api_server() to its supervisor's children"
      else
        app_label <> "(unknown)"
      end

    """
    Found #{length(modules)} module(s) using NebulaAPI with local methods in app #{inspect(app)}, \
    but no nebula_api_server() has been found in #{inspect(app)}'s supervisor — their RPC workers \
    will never start.

       App:         #{inspect(app)}
    #{app_line}
       Modules using NebulaAPI (with local methods on this node):
    #{Enum.map_join(modules, "\n", &"         - #{inspect(&1)}")}
    """
  end

  defp warning_message(app) do
    """
    warning: app #{inspect(app)} wired nebula_api_server() but defines no defapi methods — \
    the server will start no workers (nothing to serve). Add defapi endpoints, or drop \
    nebula_api_server() from #{inspect(app)}'s supervisor.
    """
  end

  defp application_module(app) do
    app_file = Path.join(Mix.Project.compile_path(), "#{app}.app")

    with {:ok, [{:application, ^app, props}]} <- :file.consult(String.to_charlist(app_file)),
         {module, _args} <- Keyword.get(props, :mod) do
      module
    else
      _ -> nil
    end
  end

  defp modules_attrs do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam ->
      case :beam_lib.chunks(String.to_charlist(beam), [:attributes]) do
        {:ok, {module, [attributes: attrs]}} -> [{module, attrs}]
        _ -> []
      end
    end)
  end

  defp diagnostic(message) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "nebula",
      file: Path.relative_to_cwd(Mix.Project.project_file()),
      severity: :error,
      message: message,
      position: 0,
      details: nil
    }
  end
end
