defmodule Mix.Tasks.Compile.Nebula do
  @moduledoc """
  Mix compiler that guards against forgetting `nebula_api_server/0`.

  Opt in from a consuming app's `mix.exs`:

      def project do
        [
          # ...
          compilers: Mix.compilers() ++ [:nebula]
        ]
      end

  It runs after `:app` (so every module is compiled and its `.beam` written), reads the
  persisted NebulaAPI attributes straight from the beams, and fails compilation when the
  app has modules with local methods on this node but no `nebula_api_server()` wired into
  its supervision tree — i.e. workers that would never start. This mirrors the compile
  errors NebulaAPI already raises (e.g. a `defapi` for an unknown node).
  """

  use Mix.Task.Compiler

  # In umbrella projects, run once per child app (in each app's own context), like the
  # built-in :elixir compiler — so `mix compile` from the umbrella root checks each app.
  @recursive true

  @impl true
  def run(_argv) do
    # No app in the current project (e.g. the umbrella root) → nothing of ours to check;
    # the verification runs in each child app's own context, where `:app` is set.
    case Mix.Project.config()[:app] do
      nil ->
        {:noop, []}

      app ->
        case NebulaAPI.CompilerCheck.verify(modules_attrs()) do
          :ok ->
            {:noop, []}

          {:error, local_modules} ->
            message = error_message(app, local_modules)
            # Print for humans (Mix doesn't render compiler diagnostics on its own) and
            # return the structured diagnostic for editors; :error status fails the build.
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

  # The app's `mod:` from its `.app` file → the Application module where the supervisor
  # (and thus nebula_api_server()) lives. The supervisor's registered name is a runtime
  # arg, so it isn't knowable here; the Application module is, and it's the actionable spot.
  defp application_module(app) do
    app_file = Path.join(Mix.Project.compile_path(), "#{app}.app")

    with {:ok, [{:application, ^app, props}]} <- :file.consult(String.to_charlist(app_file)),
         {module, _args} <- Keyword.get(props, :mod) do
      module
    else
      _ -> nil
    end
  end

  # {module, persisted_attributes} for every compiled module of the current app,
  # read from disk without loading the modules.
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
