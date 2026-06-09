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

  # A module carrying the persisted :nebula_local_api_methods marker the worker
  # reads to register itself and validate incoming calls.
  defmodule LocalMethodsMod do
    Module.register_attribute(__MODULE__, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    @nebula_local_api_methods {:slow, 0}
    @nebula_local_api_methods {:fast, 0}

    def slow do
      Process.sleep(300)
      {:ok, :slow}
    end

    def fast, do: {:ok, :fast}
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

    test "a late worker reply does not land in the caller's mailbox" do
      # Replies 200ms AFTER the 50ms timeout.
      pid = start_fake(GarbageMod, :slow, 0, 250, {:ok, :too_late})

      assert {:error, :timeout} =
               APIServer.call_remote_method(GarbageMod, {:slow}, timeout: 50)

      # Let the worker emit its late reply.
      Process.sleep(400)

      # No {reference, _} 2-tuple (the gen_server:call garbage shape) may be left
      # in our mailbox: it was confined to the dead Task.
      {:messages, msgs} = Process.info(self(), :messages)

      refute Enum.any?(msgs, fn
               {ref, _} when is_reference(ref) -> true
               _ -> false
             end)

      GenServer.stop(pid)
    end
  end

  describe "multicast :all — timeout resilience (H2)" do
    test "a worker slower than the timeout returns a partial list without crashing" do
      pid = start_fake(AllTimeoutMod, :slow, 0, 400, {:ok, :too_late})

      result =
        APIServer.call_remote_method(
          AllTimeoutMod,
          {:slow},
          multicast: true,
          strategy: :all,
          timeout: 80
        )

      assert is_list(result)
      assert [{:timeout, _node}] = result
      # No crash: we're still here.
      assert Process.alive?(self())

      GenServer.stop(pid)
    end
  end

  describe "worker — non-blocking execution (H3)" do
    test "a slow call does not block a concurrent fast call" do
      {:ok, worker} = NebulaAPI.APIServer.Worker.start_link(LocalMethodsMod)
      parent = self()

      spawn(fn -> send(parent, {:slow_done, GenServer.call(worker, {:slow}, 5_000)}) end)
      # Let the slow call reach the worker.
      Process.sleep(30)

      t0 = System.monotonic_time(:millisecond)
      fast = GenServer.call(worker, {:fast}, 5_000)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert fast == {:ok, :fast}
      # The fast call must NOT have waited out the slow call's 300ms.
      assert elapsed < 150
      assert_receive {:slow_done, {:ok, :slow}}, 1_000

      GenServer.stop(worker)
    end

    test "an unknown-method call returns an error without killing the worker" do
      {:ok, worker} = NebulaAPI.APIServer.Worker.start_link(LocalMethodsMod)

      assert {:error, {:undefined_local_method, LocalMethodsMod, :nope, 0}} =
               GenServer.call(worker, {:nope}, 1_000)

      # The worker survives and keeps serving its real methods.
      assert Process.alive?(worker)
      assert GenServer.call(worker, {:fast}, 1_000) == {:ok, :fast}

      GenServer.stop(worker)
    end
  end
end
