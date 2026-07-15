defmodule NebulaAPI.NodesCacheOwnershipTest do
  # async: false — asserts on the app-global cache table.
  use ExUnit.Case, async: false

  alias NebulaAPI.APIServer.NodesInfoCache

  test "the nodes cache table is :protected and owned by the NodesInfoCache singleton" do
    # :public would let ANY local process overwrite the snapshot — and thereby
    # steer every function node-selector (a min_by(memory_percent) routing
    # decision). The only legitimate writer is the background refresher, so it
    # owns the table; everyone else reads.
    assert :ets.info(:nebula_nodes_cache, :protection) == :protected
    assert :ets.info(:nebula_nodes_cache, :owner) == Process.whereis(NodesInfoCache)
  end

  test "seed_snapshot/wipe_snapshot write through the owner" do
    marker = %{:seeded@host => %{long_name: :seeded@host, connected: false}}

    :ok = NodesInfoCache.seed_snapshot(marker)
    assert NebulaAPI.APIServer.get_nodes_info() == marker

    :ok = NodesInfoCache.wipe_snapshot()
    assert NebulaAPI.APIServer.get_nodes_info() == %{}
  end
end
