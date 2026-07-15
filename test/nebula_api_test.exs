defmodule NebulaAPITest do
  use ExUnit.Case

  alias NebulaAPI.APIServer

  describe "collect_runtime_info/0" do
    test "returns runtime info with all expected keys" do
      info = APIServer.collect_runtime_info()

      assert is_map(info)
      assert Map.has_key?(info, :memory_used_mb)
      assert Map.has_key?(info, :memory_total_mb)
      assert Map.has_key?(info, :memory_percent)
      assert Map.has_key?(info, :process_count)
      assert Map.has_key?(info, :schedulers)
      assert Map.has_key?(info, :otp_release)
      assert Map.has_key?(info, :uptime_seconds)
    end

    test "memory values are non-negative" do
      info = APIServer.collect_runtime_info()

      assert info.memory_used_mb >= 0
      assert info.memory_total_mb > 0
      assert info.memory_percent >= 0
      assert info.memory_percent <= 100
    end

    test "process count and schedulers are positive" do
      info = APIServer.collect_runtime_info()

      assert info.process_count > 0
      assert info.schedulers > 0
    end
  end

  describe "collect_node_health_data_local/0" do
    test "returns node health data with all expected keys" do
      data = APIServer.collect_node_health_data_local()

      assert is_map(data)
      assert Map.has_key?(data, :short_name)
      assert Map.has_key?(data, :long_name)
      assert Map.has_key?(data, :host)
      assert Map.has_key?(data, :tags)
      assert Map.has_key?(data, :connected)
      assert Map.has_key?(data, :runtime)
    end

    test "long_name matches current node" do
      data = APIServer.collect_node_health_data_local()
      assert data.long_name == node()
    end

    test "connected is always true for local node" do
      data = APIServer.collect_node_health_data_local()
      assert data.connected == true
    end

    test "runtime contains valid info" do
      data = APIServer.collect_node_health_data_local()
      assert is_map(data.runtime)
      assert data.runtime.memory_total_mb > 0
    end
  end

  describe "ETS cache operations" do
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

    test "cache_node_info/2 from a non-owner process is a silent no-op" do
      # The table is :protected, owned by NodesInfoCache: the write path is
      # effective only inside the owner (exercised by the refresh test in
      # resilience_test). From anywhere else it must neither raise nor write.
      node_name = :"protected_probe_#{:rand.uniform(10000)}@localhost"
      info = %{short_name: :protected_probe, host: "localhost", tags: [:test]}

      assert APIServer.cache_node_info(node_name, info) == :ok
      assert APIServer.get_cached_node_info(node_name) == %{}
    end

    test "get_cached_node_info/1 returns empty map for unknown node" do
      unknown_node = :"unknown_node_#{:rand.uniform(10000)}@localhost"
      cached = APIServer.get_cached_node_info(unknown_node)

      assert cached == %{}
    end
  end

  describe "get_all_workers/2" do
    test "returns empty list when no workers registered" do
      workers = APIServer.get_all_workers(NonExistentModule, {:non_existent_fn, []})
      assert workers == []
    end
  end
end
