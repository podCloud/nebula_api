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
        send(parent, {:done, GenServer.call(worker, {:nebula_call, {:slow}, 5_000}, 5_000)})
      end)
    end

    assert_receive {:done, :slow_done}, 1_000
    assert_receive {:done, :slow_done}, 1_000

    # Two 200ms bodies through a single slot: the second waited for the first.
    assert System.monotonic_time(:millisecond) - t0 >= 380

    GenServer.stop(worker)
  end

  test "a queued call whose caller timed out is dropped, not executed" do
    {:ok, worker} = Worker.start_link(SerialMod)

    # Occupy the single slot for 200ms.
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:slow}, 5_000}, 5_000) end)
    Process.sleep(30)

    # Queues behind :slow and times out before a slot frees up.
    assert catch_exit(GenServer.call(worker, {:nebula_call, {:ping, self()}, 50}, 50))

    # Once the slot frees, the expired entry must be dropped: no side effect.
    refute_receive :executed, 500

    GenServer.stop(worker)
  end

  test "a call that errors frees its slot (queue keeps draining)" do
    {:ok, worker} = Worker.start_link(SerialMod)

    # :nope is unknown -> replies {:nebula_error, _} but must release the slot.
    assert {:nebula_error, _} = GenServer.call(worker, {:nebula_call, {:nope}, 1_000}, 1_000)
    assert GenServer.call(worker, {:nebula_call, {:ping, self()}, 1_000}, 1_000) == :pong
    assert_receive :executed

    GenServer.stop(worker)
  end

  test "timeout: :infinity queues without crashing the worker and never expires" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    # Occupy the single slot for 200ms, then queue an :infinity-budget call behind
    # it — the deadline arithmetic must not choke on the atom, and the entry must
    # be executed (an :infinity deadline never expires).
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:slow}, 5_000}, 5_000) end)
    Process.sleep(30)

    spawn(fn ->
      send(
        parent,
        {:pong_done,
         GenServer.call(worker, {:nebula_call, {:ping, parent}, :infinity}, :infinity)}
      )
    end)

    assert_receive {:pong_done, :pong}, 2_000
    assert_receive :executed
    assert Process.alive?(worker)

    GenServer.stop(worker)
  end
end
