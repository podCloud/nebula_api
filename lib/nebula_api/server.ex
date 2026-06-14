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
  the entries. The serving set is discovered from the app's compiled modules.
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

    # The node this release is being COMPILED as (the `--name` on `mix compile`). NebulaAPI
    # bakes routing per node, so the running node must match — enforced at boot (server_mode/3,
    # which also handles the generic-node and mismatch-escape-hatch cases).
    compiled_node = node()

    quote do
      NebulaAPI.Server.child_spec(app_module: __MODULE__, compiled_node: unquote(compiled_node))
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
    require Logger

    compiled = Keyword.get(opts, :compiled_node)
    current = node()

    case server_mode(compiled, current, NebulaAPI.APIServer.runtime_mismatch_allowed?()) do
      :serve ->
        NebulaAPI.APIServer.set_generic_mode(false)

        children =
          opts
          |> Keyword.fetch!(:app_module)
          |> app_modules()
          |> servable_modules()
          |> Enum.map(&worker_child_spec/1)

        Supervisor.init(children, strategy: :one_for_one)

      {:noop, warning} ->
        # Generic node: no workers, serves nothing. force_remote?/0 reads this so every
        # locally-compiled body routes remote too.
        NebulaAPI.APIServer.set_generic_mode(true)
        Logger.warning(warning)
        Supervisor.init([], strategy: :one_for_one)

      {:exit, message} ->
        raise message
    end
  end

  @doc false
  # The whole boot-time node policy, as a pure function (testable without a second VM).
  #
  #   compiled = the node this release was compiled as (nonode@nohost if built without --name)
  #   current  = node() at boot
  #   mismatch = ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1
  #
  # SERVE only when running as exactly the (real) node we were compiled for. Anything else is
  # either a deliberate generic node (mismatch set → noop: serves nothing, every call remote)
  # or a misconfiguration (no mismatch → refuse to boot, with an explanation).
  def server_mode(compiled, current, _mismatch) when is_nil(compiled) do
    # No recorded compiled node → we can't tell what this release was built for, so we can't
    # verify the running node. Refuse rather than serve blindly (and possibly misroute).
    {:exit,
     """
     NebulaAPI: this server has no recorded compiled node, so it can't verify which node it
     is running as. Wire it with `nebula_api_server()` (which records the compile-time node)
     and recompile — don't construct the child spec without `compiled_node:`.
     """}
  end

  def server_mode(compiled, current, mismatch) do
    cond do
      current == compiled and current != :nonode@nohost -> :serve
      mismatch -> {:noop, noop_warning(compiled, current)}
      true -> {:exit, exit_message(compiled, current)}
    end
  end

  defp noop_warning(_compiled, :nonode@nohost) do
    "NebulaAPI: running as nonode@nohost — generic node, no API server started. It serves " <>
      "nothing and is disconnected from the cluster, so it makes no calls at all (inert)."
  end

  defp noop_warning(compiled, current) do
    "NebulaAPI: running as #{inspect(current)}, which is not the node this release was " <>
      "compiled for (#{inspect(compiled)}). Generic mode (ALLOW_RUNTIME_NEBULA_NODE_MISMATCH " <>
      "is set): no API server started, this node serves nothing — every defapi call goes out " <>
      "remotely to whoever does serve it."
  end

  defp exit_message(:nonode@nohost, :nonode@nohost) do
    """
    NebulaAPI: running as nonode@nohost.

    This is a generic, out-of-cluster node — it serves nothing and can't make calls. If that
    is what you want, start with ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1; otherwise give the
    release a real node name (RELEASE_NODE=...).
    """
  end

  defp exit_message(:nonode@nohost, current) do
    """
    NebulaAPI: this release was compiled WITHOUT a node name — node() was nonode@nohost at
    compile time (did you forget --name on `mix compile`?) — but it is running as
    #{inspect(current)}.

    A nameless build has no routing baked in for #{inspect(current)} and refuses to boot.
    Recompile with `--name #{current}` to run as that node, or set
    ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1 to run it as a generic node that serves nothing.
    """
  end

  defp exit_message(compiled, :nonode@nohost) do
    """
    NebulaAPI: this release was compiled for #{inspect(compiled)} but is running as
    nonode@nohost (out of cluster).

    Set ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1 to run it as a generic, inert node (serves
    nothing, makes no calls), or give it its real name with RELEASE_NODE=#{compiled}.
    """
  end

  defp exit_message(compiled, current) do
    """
    NebulaAPI node mismatch — this release was compiled for #{inspect(compiled)} but is
    running as #{inspect(current)}.

    NebulaAPI bakes routing in per node at compile time, so a release must run as the node it
    was compiled for. Fix RELEASE_NODE (and RELEASE_DISTRIBUTION=name for fully-qualified
    names), or set ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1 to run as a generic node that serves
    nothing and routes every call remotely.
    """
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
