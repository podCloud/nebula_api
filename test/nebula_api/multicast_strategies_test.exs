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
      # With no workers registered there is no success to return — :first never
      # yields a bare list anymore: it fails on the :nebula_error channel.
      opts = [multicast: true, strategy: :first, timeout: 100]
      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert result == {:nebula_error, :no_success, []}
    end

    test "call_remote_method accepts :quorum strategy" do
      # With no workers registered, at_least: 2 is unreachable (0 workers < 2
      # required) — the contract returns :quorum_unreachable instead of [].
      opts = [multicast: true, strategy: :quorum, at_least: 2, timeout: 100]
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
    test "without at_least: nor quorum: the default is a strict majority of the configured set" do
      # No quorum: key → the default mode is :configured. With the method's set
      # (3 nodes) injected and none present, required = div(3, 2) + 1 = 2. The
      # fail-fast :quorum_unreachable exposes the resolved requirement, so this
      # exercises the actual default through the public API.
      opts = [
        multicast: true,
        strategy: :quorum,
        __method_configured_nodes: [:a@h, :b@h, :c@h],
        timeout: 100
      ]

      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} = result
    end

    test "quorum: :configured counts the method's configured serving set, not the present workers" do
      # The method is configured to be served by 3 nodes, but none is connected.
      # The default quorum is a majority of those 3 (= 2), not of the 0 present —
      # so the call refuses up front (a single live node could not be a quorum).
      opts = [
        multicast: true,
        strategy: :quorum,
        quorum: :configured,
        __method_configured_nodes: [:a@h, :b@h, :c@h],
        timeout: 100
      ]

      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} = result
    end

    test "quorum: :available counts the present workers even when the configured set is known" do
      opts = [
        multicast: true,
        strategy: :quorum,
        quorum: :available,
        __method_configured_nodes: [:a@h, :b@h, :c@h],
        timeout: 100
      ]

      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 1}} = result
    end

    test "an explicit at_least: overrides the configured-set default" do
      opts = [
        multicast: true,
        strategy: :quorum,
        __method_configured_nodes: [:a@h, :b@h, :c@h, :d@h, :e@h],
        at_least: 4,
        timeout: 100
      ]

      result = APIServer.call_remote_method(NonExistentModule, {:test_fn}, opts)
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 4}} = result
    end
  end
end
