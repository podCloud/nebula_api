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

  # Same name as NebulaAPI.APIServer's @nodes_info_cache_key.
  @snapshot_key :__nodes_info_snapshot__

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc false
  # Test seam: write a snapshot through the table owner (the table is
  # :protected, owned by NodesCacheOwner). `updated_at` is injectable so tests
  # can prove age-independence; nil means "now".
  def seed_snapshot(data, updated_at \\ nil) do
    NebulaAPI.APIServer.NodesCacheOwner.insert(
      {@snapshot_key,
       %{data: data, updated_at: updated_at || System.monotonic_time(:millisecond)}}
    )
  end

  @doc false
  # Test seam: drop the snapshot through the table owner.
  def wipe_snapshot do
    NebulaAPI.APIServer.NodesCacheOwner.delete(@snapshot_key)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, NebulaAPI.Config.nodes_info_refresh_interval())

    # Refresh immediately (async, so we never block the supervisor's boot), then
    # reschedule from handle_info/2. The cache TABLE is not ours: it belongs to
    # NodesCacheOwner, so a crash/restart of this refresher never destroys the
    # cached data. All writes go through the owner.
    send(self(), :refresh)

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:refresh, %{interval: interval} = state) do
    protected_refresh(&NebulaAPI.APIServer.refresh_nodes_cache/0)

    Process.send_after(self(), :refresh, interval)

    {:noreply, state}
  end

  # The cache runs under a public, predictable name: stray messages happen.
  # Our handle_info(:refresh) clause above REPLACED the permissive default that
  # `use GenServer` injects, and the default handle_call/handle_cast RAISE —
  # so any stray message would crash the cache, and a repeated one would chew
  # through the APIServer supervisor's restart intensity: the exact blast
  # radius protected_refresh/1 exists to prevent. Same hardening as Worker.
  @impl true
  def handle_info(other, state) do
    Logger.warning("NodesInfoCache ignored unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(other, _from, state) do
    {:reply, {:nebula_error, {:unexpected_message, other}}, state}
  end

  @impl true
  def handle_cast(other, state) do
    Logger.warning("NodesInfoCache ignored unexpected cast: #{inspect(other)}")
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
      Logger.error(
        "NodesInfoCache refresh failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :error
  catch
    kind, reason ->
      Logger.error("NodesInfoCache refresh failed: #{inspect(kind)} #{inspect(reason)}")
      :error
  end
end
