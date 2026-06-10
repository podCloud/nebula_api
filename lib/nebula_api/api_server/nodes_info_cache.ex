defmodule NebulaAPI.APIServer.NodesInfoCache do
  @moduledoc """
  Per-node background refresher for the cluster node-info snapshot.

  One instance runs per node, as a child of `NebulaAPI.APIServer` (which owns the
  ETS cache). It rebuilds the node-info snapshot on a fixed interval and writes it
  to ETS, so readers (`get_nodes_info/0`, hence every function-selector route)
  never trigger an RPC fan-out themselves — they just read the latest snapshot.

  This is what kills the thundering herd: refreshing is a single, periodic,
  per-node job rather than something each concurrent caller does on cache miss.

  The flip side is a fixed background cost: every node refreshes on every interval,
  whether or not anything reads the snapshot — i.e. one RPC fan-out per node per
  interval, cluster-wide. With the 5s default this is negligible for the small
  clusters NebulaAPI targets; raise `nodes_info_refresh_interval` if your cluster
  is large or node selectors can tolerate staler info.

  The interval is `config :nebula_api, nodes_info_refresh_interval: <ms>`
  (default 5000), overridable per-instance with the `:interval` option (used in
  tests).
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, NebulaAPI.Config.nodes_info_refresh_interval())

    # Refresh immediately (async, so we never block the supervisor's boot), then
    # reschedule from handle_info/2.
    send(self(), :refresh)

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:refresh, %{interval: interval} = state) do
    protected_refresh(&NebulaAPI.APIServer.refresh_nodes_cache/0)

    Process.send_after(self(), :refresh, interval)

    {:noreply, state}
  end

  # Runs one refresh, containing ANY failure (exception, throw, exit): a failing
  # refresh must never kill the cache — a crash loop here would exhaust the
  # APIServer supervisor's restart intensity and take the whole app down with it.
  @doc false
  def protected_refresh(fun) do
    fun.()
    :ok
  rescue
    e ->
      Logger.error("NodesInfoCache refresh failed: #{Exception.format(:error, e, __STACKTRACE__)}")
      :error
  catch
    kind, reason ->
      Logger.error("NodesInfoCache refresh failed: #{inspect(kind)} #{inspect(reason)}")
      :error
  end
end
