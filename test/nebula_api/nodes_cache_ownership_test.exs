defmodule NebulaAPI.NodesCacheOwnershipTest do
  # async: false — asserts on the app-global cache table and bounces children
  # of the APIServer supervisor.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "insert/1 with a malformed (non-tuple) entry does not crash the owner or destroy the table" do
    marker = %{:guard_survivor@host => %{long_name: :guard_survivor@host, tags: [:x]}}
    :ok = NodesInfoCache.seed_snapshot(marker)

    owner_before = Process.whereis(NodesCacheOwner)

    assert {:error, _reason} = NodesCacheOwner.insert(:oops)

    # Same process, still alive: :ets.insert/2 raising ArgumentError for a
    # non-tuple value must be caught inside the owner's own handle_call, not
    # let the GenServer crash (an owner-less :protected table with no :heir
    # is destroyed the instant its process dies).
    assert Process.whereis(NodesCacheOwner) == owner_before
    assert Process.alive?(owner_before)
    assert APIServer.get_nodes_info() == marker
  end

  test "a rejected malformed write is logged, not silently swallowed" do
    # Before the crash-hardening fix, a malformed write crashed the owner
    # loudly (a supervisor restart log). After it, {:error, _} on its own is
    # invisible unless something logs it -- every caller (refresh_nodes_cache,
    # the insert_async cast) discards the return value.
    log =
      capture_log(fn ->
        NodesCacheOwner.insert(:oops)
      end)

    assert log =~ "NodesCacheOwner"
    assert log =~ "insert"
  end

  test "insert_async/1 (the cast path build_nodes_info/0 actually uses in production) with a malformed entry does not crash the owner" do
    marker = %{:cast_guard_survivor@host => %{long_name: :cast_guard_survivor@host, tags: [:x]}}
    :ok = NodesInfoCache.seed_snapshot(marker)

    owner_before = Process.whereis(NodesCacheOwner)

    :ok = NodesCacheOwner.insert_async(:oops)

    # insert_async/1 is a cast -- it doesn't wait for a reply, so a
    # synchronous follow-up call to the SAME process is the synchronization
    # point: GenServer mailboxes are FIFO, so this only returns once the bad
    # cast has actually been handled (or fails outright if it took the
    # owner down with it).
    assert :ok = NodesCacheOwner.insert({:cast_guard_sync, :ok})

    assert Process.whereis(NodesCacheOwner) == owner_before
    assert Process.alive?(owner_before)
    assert APIServer.get_nodes_info() == marker
  end

  test "build_nodes_info/0 does not block on a slow or unresponsive cache owner" do
    # build_nodes_info/0 writes one cache entry per configured node via a
    # plain Enum.map. If that write is a synchronous GenServer.call, a single
    # slow/stuck owner turns what should be an instant, best-effort update
    # into a call that can stall the whole refresh by up to
    # (configured node count) * (the call's timeout) -- one hung node was
    # enough to demonstrate it here since the write, not the count, is what
    # must not block.
    Application.put_env(:nebula_api, :nodes, [{node(), [:slowtest]}])

    owner_pid = Process.whereis(NodesCacheOwner)
    :ok = Supervisor.terminate_child(APIServer, NodesCacheOwner)

    {:ok, fake_owner} =
      GenServer.start_link(
        NebulaAPI.NodesCacheOwnershipTest.NeverReplies,
        [],
        name: NodesCacheOwner
      )

    on_exit(fn ->
      Application.delete_env(:nebula_api, :nodes)
      if Process.alive?(fake_owner), do: GenServer.stop(fake_owner)
      {:ok, _} = Supervisor.restart_child(APIServer, NodesCacheOwner)
    end)

    {elapsed_us, _result} = :timer.tc(fn -> APIServer.build_nodes_info() end)

    refute is_nil(owner_pid)
    # The default GenServer.call timeout is 5_000ms; a write that actually
    # waited on the fake owner's (never-sent) reply would take at least that
    # long. Comfortably below it proves the write isn't blocking the caller.
    assert elapsed_us < 1_000_000
  end

  defmodule NeverReplies do
    @moduledoc false
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call(_msg, _from, state), do: {:noreply, state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
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
