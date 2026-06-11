defmodule NebulaAPI.WorkerConcurrencyTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer.Worker

  # Mirrors a real `use NebulaAPI, max_concurrent_calls: 1` module: the persisted
  # :nebula_api opts plus the local-methods markers the worker registers/validates.
  defmodule SerialMod do
    Module.register_attribute(__MODULE__, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [max_concurrent_calls: 1]
    @nebula_local_api_methods {:slow, 0}
    @nebula_local_api_methods {:ping, 1}

    def slow do
      Process.sleep(200)
      :slow_done
    end

    def ping(pid) do
      send(pid, :executed)
      :pong
    end
  end

  setup_all do
    case :pg.start(:pg_nebula_api) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "max_concurrent_calls: 1 serializes calls" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    t0 = System.monotonic_time(:millisecond)

    for _ <- 1..2 do
      spawn(fn ->
        send(parent, {:done, GenServer.call(worker, {:nebula_call, {:slow}}, 5_000)})
      end)
    end

    assert_receive {:done, :slow_done}, 1_000
    assert_receive {:done, :slow_done}, 1_000

    # Two 200ms bodies through a single slot: the second waited for the first.
    assert System.monotonic_time(:millisecond) - t0 >= 380

    GenServer.stop(worker)
  end

  test "a queued call whose caller timed out is purged, not executed" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    # Occupy the single slot for 200ms.
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:slow}}, 5_000) end)
    Process.sleep(30)

    # Mimic how the library actually calls workers: through a throwaway process
    # (confined_call / multicast task) that dies right after its timeout. Its
    # death is the purge signal — the worker monitors queued callers.
    proxy =
      spawn(fn ->
        try do
          GenServer.call(worker, {:nebula_call, {:ping, parent}}, 50)
        catch
          :exit, _ -> :ok
        end
      end)

    ref = Process.monitor(proxy)
    assert_receive {:DOWN, ^ref, :process, ^proxy, _}, 1_000

    # Once the slot frees, the purged entry must never execute.
    refute_receive :executed, 500

    GenServer.stop(worker)
  end

  test "a call that errors frees its slot (queue keeps draining)" do
    {:ok, worker} = Worker.start_link(SerialMod)

    # :nope is unknown -> replies {:nebula_error, _} but must release the slot.
    assert {:nebula_error, _} = GenServer.call(worker, {:nebula_call, {:nope}}, 1_000)
    assert GenServer.call(worker, {:nebula_call, {:ping, self()}}, 1_000) == :pong
    assert_receive :executed

    GenServer.stop(worker)
  end

  test "a queued call whose caller dies is purged, not executed" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    # Occupy the single slot for 200ms.
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:slow}}, 5_000) end)
    Process.sleep(30)

    # Queue a call behind it, then kill its caller while it waits in line. In real
    # usage the caller is the throwaway confined_call / multicast task, whose death
    # is exactly how loss of interest manifests (timeout, early :first resolution).
    victim =
      spawn(fn ->
        GenServer.call(worker, {:nebula_call, {:ping, parent}}, 5_000)
      end)

    Process.sleep(30)
    Process.exit(victim, :kill)

    # Once the slot frees, the dead caller's entry must never execute.
    refute_receive :executed, 500

    GenServer.stop(worker)
  end

  test "an unexpected call message gets {:nebula_error, _} and the worker survives" do
    {:ok, worker} = Worker.start_link(SerialMod)

    assert {:nebula_error, {:unexpected_message, :ping}} =
             GenServer.call(worker, :ping, 1_000)

    # The worker (and its queue bookkeeping) survived: real calls still work.
    assert Process.alive?(worker)
    assert GenServer.call(worker, {:nebula_call, {:ping, self()}}, 1_000) == :pong
    assert_receive :executed

    GenServer.stop(worker)
  end
end
