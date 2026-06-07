defmodule NebulaAPI.Server do
  @moduledoc """
  Per-application supervisor for NebulaAPI workers.

  One `NebulaAPI.Server` lives in the supervision tree of each OTP application that
  owns modules using `NebulaAPI` (wire it in with `use NebulaAPI.Server` +
  `nebula_api_server/0`). It is given `app_module:` — a module belonging to that app — from
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

  @doc """
  Brings the `nebula_api_server/0` macro into scope, plus the `NebulaAPI.AST` macros
  (`on_nebula_nodes`, `call_on_*`). For the host module — typically the app's
  `Application` — that wires the per-app server into its supervision tree.

  Unlike `use NebulaAPI`, this does **not** register the `defapi` bookkeeping
  (`:nebula_local_api_methods`, `:nebula_remote_api_methods`, the `:nebula_api` marker)
  nor validate `self_node` — the host module has no `defapi` of its own, so none of that
  applies. Use `use NebulaAPI` only on modules that actually define `defapi` endpoints.
  """
  defmacro __using__(_opts) do
    # Persist the marker so the `:nebula` Mix compiler can read it from the .beam.
    Module.register_attribute(__CALLER__.module, :nebula_api_server_wired, persist: true)

    quote do
      import NebulaAPI.Server, only: [nebula_api_server: 0]
      use NebulaAPI.AST
    end
  end

  @doc """
  Expands to a child spec for `NebulaAPI.Server`, to be placed in the supervision tree of
  an OTP application that owns modules using `NebulaAPI`.

  Brought into scope by `use NebulaAPI.Server`. It expands at the call site, so
  `__MODULE__` is the host module (typically the app's `Application`), which belongs to
  the consumer's OTP app — all the server needs to resolve the app and, at runtime,
  discover its modules, keep the ones with local methods on this node, and start a worker
  for each. Because the server lives inside the app's own tree, the worker lifecycle is
  correct for free: app stops or crashes → server and workers die with it, `:pg` drops
  the entries.

      defmodule MyApp.Application do
        use Application
        use NebulaAPI.Server

        def start(_type, _args) do
          Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
        end
      end
  """
  defmacro nebula_api_server do
    # Mark the calling module so the `:nebula` Mix compiler can verify, after the whole
    # app is compiled, that an app with local methods actually wired a server somewhere.
    Module.put_attribute(__CALLER__.module, :nebula_api_server_wired, true)

    quote do
      NebulaAPI.Server.child_spec(app_module: __MODULE__)
    end
  end

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
