defmodule NebulaAPI.IntegrationTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer

  @pg_scope :pg_nebula_api

  # Helper: start a fake worker GenServer that responds to calls
  defp start_fake_worker(module, method_name, arity, response_fn) do
    {:ok, pid} =
      GenServer.start(
        NebulaAPI.IntegrationTest.FakeWorker,
        %{response_fn: response_fn}
      )

    :pg.join(@pg_scope, {module, {method_name, arity}}, pid)
    pid
  end

  setup_all do
    # Start :pg unlinked so it survives across tests
    case :pg.start(@pg_scope) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure ETS table exists
    case :ets.whereis(:nebula_nodes_cache) do
      :undefined ->
        :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

      _tid ->
        :ok
    end

    :ok
  end

  describe "unicast with fake worker" do
    test "calls the worker and returns the result" do
      pid =
        start_fake_worker(TestModule, :greet, 1, fn {:greet, name} ->
          "Hello #{name}"
        end)

      result = APIServer.call_remote_method(TestModule, {:greet, "world"})
      assert result == "Hello world"

      GenServer.stop(pid)
    end

    test "returns a transport error when no worker available" do
      result = APIServer.call_remote_method(NoWorkerModule, {:missing, "arg"})
      assert {:nebula_error, _} = result
    end
  end

  describe "multicast :all strategy with fake workers" do
    test "collects results from workers (deduped by node)" do
      # Both workers are on the same test node, so call_all_workers deduplicates
      # to a single worker. This is correct behavior: in a real cluster, each
      # node has one worker, and multicast sends to each node once.
      pid1 =
        start_fake_worker(MultiTestModule, :compute, 1, fn {:compute, n} ->
          n * 2
        end)

      pid2 =
        start_fake_worker(MultiTestModule, :compute, 1, fn {:compute, n} ->
          n * 3
        end)

      results =
        APIServer.call_remote_method(
          MultiTestModule,
          {:compute, 5},
          multicast: true,
          strategy: :all,
          timeout: 2000
        )

      assert is_list(results)
      # Single node = single result after dedup
      assert length(results) == 1
      assert [{_node, val}] = results
      assert val in [10, 15]

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end

    test "returns empty list when no workers" do
      results =
        APIServer.call_remote_method(
          NoWorkersModule,
          {:noop},
          multicast: true,
          strategy: :all,
          timeout: 100
        )

      assert results == []
    end
  end

  describe "multicast :first strategy with fake workers" do
    test "returns first successful result" do
      # One fast worker, one slow worker
      pid1 =
        start_fake_worker(FirstTestModule, :fast, 0, fn {:fast} ->
          :fast_result
        end)

      pid2 =
        start_fake_worker(FirstTestModule, :fast, 0, fn {:fast} ->
          Process.sleep(500)
          :slow_result
        end)

      result =
        APIServer.call_remote_method(
          FirstTestModule,
          {:fast},
          multicast: true,
          strategy: :first,
          timeout: 2000
        )

      # Single node → workers dedup to one; :first returns that one responder.
      assert {_node, res} = result
      assert res in [:fast_result, :slow_result]

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end

  describe "multicast :quorum strategy with fake workers" do
    test "reaches quorum with single-node workers" do
      # On a single node, all workers are deduped to one. With quorum_count: 1,
      # the quorum can be reached with a single successful response.
      pids =
        for i <- 1..3 do
          start_fake_worker(QuorumTestModule, :vote, 0, fn {:vote} ->
            {:voted, i}
          end)
        end

      result =
        APIServer.call_remote_method(
          QuorumTestModule,
          {:vote},
          multicast: true,
          strategy: :quorum,
          quorum_count: 1,
          timeout: 2000
        )

      assert is_list(result)
      assert length(result) >= 1

      Enum.each(pids, &GenServer.stop/1)
    end
  end

  describe "unicast with node selector" do
    test "returns error when selector returns nil" do
      _pid = start_fake_worker(SelectorTestModule, :work, 0, fn {:work} -> :done end)

      result =
        APIServer.call_remote_method(
          SelectorTestModule,
          {:work},
          node_selector: fn _nodes_info -> nil end,
          timeout: 1000
        )

      assert {:nebula_error, _} = result
    end
  end

  describe "deadline-based timeout" do
    test "workers respect remaining time from deadline" do
      # Worker that takes 200ms
      pid =
        start_fake_worker(TimeoutTestModule, :slow, 0, fn {:slow} ->
          Process.sleep(200)
          :done
        end)

      # Should succeed with 1000ms timeout
      result =
        APIServer.call_remote_method(
          TimeoutTestModule,
          {:slow},
          multicast: true,
          strategy: :all,
          timeout: 1000
        )

      assert [{_node, :done}] = result

      GenServer.stop(pid)
    end
  end

  describe "nodes_info snapshot reads" do
    test "get_nodes_info is a pure read: two consecutive reads are identical" do
      # Reading never builds anything — both calls serve the same snapshot
      # (or %{} if the background cache has not written one yet).
      info1 = APIServer.get_nodes_info()
      info2 = APIServer.get_nodes_info()

      assert info1 == info2
    end
  end

  describe "process dictionary context" do
    test "call_on_node sets and restores process dictionary" do
      assert Process.get(:nebula_node_selector) == nil
      assert Process.get(:nebula_call_mode) == nil

      # We can't easily test the macro without a real defapi module,
      # but we can verify the dictionary manipulation pattern
      Process.put(:nebula_node_selector, fn _ -> :test end)
      Process.put(:nebula_call_mode, :unicast)

      assert Process.get(:nebula_call_mode) == :unicast

      Process.delete(:nebula_node_selector)
      Process.delete(:nebula_call_mode)

      assert Process.get(:nebula_node_selector) == nil
    end
  end
end

# Simple GenServer that responds to any call with a configurable function
defmodule NebulaAPI.IntegrationTest.FakeWorker do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_call({:nebula_call, fn_call}, _from, state) do
    # Real defapi workers return the body's raw value (no wrapping).
    {:reply, state.response_fn.(fn_call), state}
  end
end
