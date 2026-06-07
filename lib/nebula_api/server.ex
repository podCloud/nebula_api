defmodule NebulaAPI.Server do
  @moduledoc """
  Per-application supervisor for NebulaAPI workers.

  One `NebulaAPI.Server` lives in the supervision tree of each OTP application that
  owns modules using `NebulaAPI` (wire it in via the `nebula_api_server/0` macro —
  see `NebulaAPI`). It is given `app_module:` — a module belonging to that app — from
  which it resolves the owning app, lists *its* modules, and keeps only those that:

    1. carry the persisted `:nebula_api` marker (i.e. they `use NebulaAPI`), and
    2. have at least one method compiled as **local** on this node,

  and starts one `NebulaAPI.APIServer.Worker` per retained module. Each worker joins
  the cluster-wide `:pg` group so remote nodes can route to it.

  Living inside the app's own tree is what makes the lifecycle correct: when the app
  stops or crashes, this supervisor (and its workers) go down with it and `:pg` drops
  the entries. There is no central discovery and no static module registry.
  """

  use Supervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children =
      opts
      |> Keyword.fetch!(:app_module)
      |> app_modules()
      |> servable_modules()
      |> Enum.map(&worker_child_spec/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # All modules of the OTP app that `app_module` belongs to. `get_application/1`
  # returns nil only if the module isn't part of a loaded app — can't happen when
  # this runs inside the app's own start/1, but we stay defensive.
  defp app_modules(app_module) do
    case Application.get_application(app_module) do
      nil -> []
      app -> Application.spec(app, :modules) || []
    end
  end

  # Keep only modules that `use NebulaAPI` and have local methods on this node.
  defp servable_modules(modules) do
    modules
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.filter(&uses_nebula_api?/1)
    |> Enum.filter(fn module ->
      NebulaAPI.APIServer.registered_local_methods(module) != []
    end)
  end

  defp uses_nebula_api?(module) do
    function_exported?(module, :__info__, 1) and
      Keyword.has_key?(module.__info__(:attributes), :nebula_api)
  end

  defp worker_child_spec(module) do
    %{
      id: module,
      start: {NebulaAPI.APIServer.Worker, :start_link, [module]}
    }
  end
end
