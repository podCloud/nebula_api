defmodule NebulaAPI.ResilienceTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer

  @pg_scope :pg_nebula_api

  setup_all do
    case :pg.start(@pg_scope) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case :ets.whereis(:nebula_nodes_cache) do
      :undefined ->
        :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  # Test worker that replies through a function, with an optional delay before replying.
  defmodule SlowFake do
    use GenServer
    def init(state), do: {:ok, state}

    def handle_call(fn_call, _from, %{delay: delay, reply: reply} = state) do
      if delay > 0, do: Process.sleep(delay)
      _ = fn_call
      {:reply, reply, state}
    end
  end

  defp start_fake(module, method, arity, delay, reply) do
    {:ok, pid} = GenServer.start(SlowFake, %{delay: delay, reply: reply})
    :pg.join(@pg_scope, {module, {method, arity}}, pid)
    pid
  end

  describe "unicast — timeout resilience (H1)" do
    test "a worker slower than the timeout returns {:error, :timeout} without crashing the caller" do
      pid = start_fake(UnicastTimeoutMod, :slow, 0, 300, {:ok, :too_late})

      result = APIServer.call_remote_method(UnicastTimeoutMod, {:slow}, timeout: 50)

      assert {:error, :timeout} = result
      # The caller (this test process) is still alive: the next line runs.
      assert Process.alive?(self())

      GenServer.stop(pid)
    end

    test "through a node selector, a too-slow worker returns {:error, :timeout} without crashing" do
      pid = start_fake(UnicastSelectorMod, :slow, 0, 300, {:ok, :too_late})
      target = node()

      result =
        APIServer.call_remote_method(
          UnicastSelectorMod,
          {:slow},
          node_selector: fn _nodes_info -> target end,
          timeout: 50
        )

      assert {:error, :timeout} = result
      assert Process.alive?(self())

      GenServer.stop(pid)
    end
  end
end
