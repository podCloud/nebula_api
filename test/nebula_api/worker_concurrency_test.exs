defmodule NebulaAPI.WorkerConcurrencyTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer.Worker

  # Mirrors a real `use NebulaAPI, max_concurrent_calls: 1` module: the generated
  # __nebula_api__/1 accessor plus the local-methods markers the worker
  # registers/validates.
  defmodule SerialMod do
    Module.register_attribute(__MODULE__, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    @nebula_local_api_methods {:gated, 1}
    @nebula_local_api_methods {:ping, 1}

    def __nebula_api__(:max_concurrent_calls), do: 1

    # Latch body: announces itself (with its own pid), then blocks until released.
    # Concurrency tests assert on the ORDER of these messages, never on clocks.
    def gated(notify) do
      send(notify, {:started, self()})

      receive do
        :go -> :gated_done
      end
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

  test "max_concurrent_calls: 1 serializes calls (proven by order, not by clock)" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    for i <- 1..2 do
      spawn(fn ->
        send(parent, {:done, i, GenServer.call(worker, {:nebula_call, {:gated, parent}}, 5_000)})
      end)
    end

    # Single slot: exactly one body may start while it is held. The negative
    # window can only under-detect under load, never flake-fail.
    assert_receive {:started, first}, 1_000
    refute_receive {:started, _second}, 100

    # Releasing the first lets the second through — that's the serialization.
    send(first, :go)
    assert_receive {:started, second}, 1_000
    send(second, :go)

    assert_receive {:done, _, :gated_done}, 1_000
    assert_receive {:done, _, :gated_done}, 1_000

    GenServer.stop(worker)
  end

  test "a queued call whose caller timed out is purged, not executed" do
    {:ok, worker} = Worker.start_link(SerialMod)
    parent = self()

    # Occupy the single slot with a gated call.
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:gated, parent}}, 5_000) end)
    assert_receive {:started, gate}, 1_000

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

    # The proxy died before we release the gate, so its DOWN is already in the
    # worker's mailbox and the purge happens before the slot frees. Then prove
    # the purged entry never runs: the queue is FIFO, so a fresh call enqueued
    # after it would execute after it — one :executed, not two.
    send(gate, :go)
    assert GenServer.call(worker, {:nebula_call, {:ping, parent}}, 1_000) == :pong
    assert_receive :executed
    refute_receive :executed, 100

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

    # Occupy the single slot with a gated call.
    spawn(fn -> GenServer.call(worker, {:nebula_call, {:gated, parent}}, 5_000) end)
    assert_receive {:started, gate}, 1_000

    # Queue a call behind it, then kill its caller while it waits in line. In real
    # usage the caller is the throwaway confined_call / multicast task, whose death
    # is exactly how loss of interest manifests (timeout, early :first resolution).
    victim =
      spawn(fn ->
        GenServer.call(worker, {:nebula_call, {:ping, parent}}, 5_000)
      end)

    # The victim must be IN the queue before we kill it: poll the worker's
    # queue length through :sys instead of sleeping blind (the worker state is
    # the %{queue: ...} map from init/1).
    wait_until(fn -> :queue.len(:sys.get_state(worker).queue) == 1 end)

    Process.exit(victim, :kill)

    ref = Process.monitor(victim)
    assert_receive {:DOWN, ^ref, :process, ^victim, _}, 1_000

    # Same FIFO argument as above: free the slot, run a fresh call, and the
    # purged entry must never have produced its own :executed.
    send(gate, :go)
    assert GenServer.call(worker, {:nebula_call, {:ping, parent}}, 1_000) == :pong
    assert_receive :executed
    refute_receive :executed, 100

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

  test "a stray info message does not kill the worker" do
    {:ok, worker} = Worker.start_link(SerialMod)

    send(worker, :garbage_info)

    # The worker (and its queue bookkeeping) survived: real calls still work.
    assert GenServer.call(worker, {:nebula_call, {:ping, self()}}, 1_000) == :pong
    assert_receive :executed

    GenServer.stop(worker)
  end

  test "a stray cast does not kill the worker" do
    {:ok, worker} = Worker.start_link(SerialMod)

    GenServer.cast(worker, :garbage_cast)

    assert GenServer.call(worker, {:nebula_call, {:ping, self()}}, 1_000) == :pong
    assert_receive :executed

    GenServer.stop(worker)
  end

  # Bounded poll: turns "sleep and hope" into "wait for the actual condition".
  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within the allotted time")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
