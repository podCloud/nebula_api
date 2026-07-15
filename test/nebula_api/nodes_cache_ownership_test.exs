defmodule NebulaAPI.NodesCacheOwnershipTest do
  # async: false — asserts on the app-global cache table and bounces children
  # of the APIServer supervisor.
  use ExUnit.Case, async: false

  alias NebulaAPI.APIServer
  alias NebulaAPI.APIServer.NodesCacheOwner
  alias NebulaAPI.APIServer.NodesInfoCache

  test "the nodes cache table is :protected and owned by the dedicated owner process" do
    # :public would let ANY local process overwrite the snapshot — and thereby
    # steer every function node-selector (a min_by(memory_percent) routing
    # decision). Writes go through NodesCacheOwner, a process whose ONLY job
    # is owning the table: the refresh logic (NodesInfoCache) can crash and
    # restart without destroying the cached data.
    assert :ets.info(:nebula_nodes_cache, :protection) == :protected
    assert :ets.info(:nebula_nodes_cache, :owner) == Process.whereis(NodesCacheOwner)
  end

  test "seed_snapshot/wipe_snapshot write through the owner" do
    marker = %{:seeded@host => %{long_name: :seeded@host, connected: false}}

    :ok = NodesInfoCache.seed_snapshot(marker)
    assert APIServer.get_nodes_info() == marker

    :ok = NodesInfoCache.wipe_snapshot()
    assert APIServer.get_nodes_info() == %{}
  end

  test "the cached data survives a NodesInfoCache crash/restart" do
    # A per-node entry, not the snapshot: the restarted refresher immediately
    # rebuilds the snapshot (that's its job), but a cached entry for a node
    # outside the configured topology is exactly the kind of data that is NOT
    # reconstructible — it must survive the crash, which proves the table
    # itself did.
    node_name = :"survivor_#{System.unique_integer([:positive])}@host"
    info = %{long_name: node_name, tags: [:precious], last_seen_at: :history}
    :ok = APIServer.cache_node_info(node_name, info)

    # Kill the refresher outright (not a graceful stop) and let its supervisor
    # bring it back — the table and its contents must not go down with it.
    pid = Process.whereis(NodesInfoCache)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    wait_until(fn -> is_pid(Process.whereis(NodesInfoCache)) end)

    assert APIServer.get_cached_node_info(node_name) == info
  end

  test "refresh_nodes_cache/0 works from any process (per-node entries included)" do
    # The documented force-refresh use case: a consumer calls it right after a
    # topology change so selectors see fresh data immediately — it must
    # actually write, not silently no-op because the caller isn't the owner.
    # The configured node is the test node itself (connected), so its health
    # data — tags included — is genuinely collected, not cache-fallback.
    Application.put_env(:nebula_api, :nodes, [{node(), [:refreshtag]}])

    on_exit(fn ->
      Application.delete_env(:nebula_api, :nodes)
      NodesInfoCache.wipe_snapshot()
    end)

    :ok = NodesInfoCache.wipe_snapshot()
    data = APIServer.refresh_nodes_cache()

    # The snapshot was actually written by this (non-owner) caller...
    assert APIServer.get_nodes_info() == data
    assert Map.has_key?(data, node())

    # ...and so was the per-node entry (the fallback source for nodes that
    # later stop responding — host/tags survive an outage).
    cached = APIServer.get_cached_node_info(node())
    assert cached.tags == [:refreshtag]
    assert cached.long_name == node()
  end

  defp wait_until(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries == 0, do: flunk("condition never became true")
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end
end
