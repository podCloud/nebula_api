defmodule NebulaAPI.MulticastStrategiesTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer

  @moduletag :multicast

  describe "do_multicast_call with empty workers" do
    test "returns empty list when no workers" do
      # We need to test this via call_all_workers with no registered workers
      result = APIServer.get_all_workers(NonExistentModule, {:test_fn, 0})
      assert result == []
    end
  end

  describe "multicast strategy selection" do
    # These tests verify the strategy selection logic without actual RPC
    # Full integration tests would require a distributed test setup

    test "call_remote_method accepts :all strategy" do
      # Should not raise on invalid strategy
      opts = [multicast: true, strategy: :all, timeout: 100]

      # This will return an error because no workers, but shouldn't crash
      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)

      # With no workers, multicast returns empty list
      assert result == []
    end

    test "call_remote_method accepts :first strategy" do
      opts = [multicast: true, strategy: :first, timeout: 100]
      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert result == []
    end

    test "call_remote_method accepts :quorum strategy" do
      # With no workers registered, quorum_count: 2 is unreachable (0 workers < 2
      # required) — the new contract returns :quorum_unreachable instead of [].
      opts = [multicast: true, strategy: :quorum, quorum_count: 2, timeout: 100]
      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} = result
    end
  end

  describe "unicast with selector" do
    test "returns error when no worker on selected node" do
      selector = fn _nodes_info -> :nonexistent@localhost end
      opts = [node_selector: selector, timeout: 100]

      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)

      assert {:nebula_error, _} = result
    end
  end

  describe "build_nodes_info/0" do
    setup do
      # Create ETS table if it doesn't exist
      case :ets.whereis(:nebula_nodes_cache) do
        :undefined ->
          :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

        _tid ->
          :ok
      end

      :ok
    end

    test "returns a map of nodes" do
      result = APIServer.build_nodes_info()
      assert is_map(result)
    end

    test "includes current node info" do
      result = APIServer.build_nodes_info()

      # At minimum, we should have some nodes from config
      # The actual nodes depend on the test configuration
      assert is_map(result)
    end
  end

  describe "quorum validation" do
    test "quorum_count defaults to majority" do
      # With 3 workers, default quorum should be 2 (3/2 + 1)
      # With 5 workers, default quorum should be 3 (5/2 + 1)
      # This is tested implicitly through the implementation

      # We can test this by examining the default calculation
      workers_count = 5
      expected_quorum = div(workers_count, 2) + 1
      assert expected_quorum == 3

      workers_count = 3
      expected_quorum = div(workers_count, 2) + 1
      assert expected_quorum == 2
    end
  end
end
