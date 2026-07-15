defmodule NebulaAPI.WorkerStartFailureTest do
  # async: false — the test disables the library-wide TaskSupervisor.
  use ExUnit.Case, async: false

  alias NebulaAPI.APIServer.Worker

  defmodule Mod do
    Module.register_attribute(__MODULE__, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [self_node: node()]
    @nebula_configured_nodes {{:ping, 1}, [node()]}

    def ping(pid) do
      send(pid, :executed)
      :pong
    end
  end

  # Serialized variant (max_concurrent_calls: 1) with a latch body, to build a
  # real queue behind one running call.
  defmodule SerialMod do
    Module.register_attribute(__MODULE__, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [self_node: node()]
    @nebula_configured_nodes {{:gated, 1}, [node()]}

    def __nebula_api__(:max_concurrent_calls), do: 1

    def gated(notify) do
      send(notify, {:started, self()})

      receive do
        :go -> :gated_done
      end
    end
  end

  setup_all do
    case :pg.start(:pg_nebula_api) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "a TaskSupervisor failure replies :worker_start_failed instead of killing the worker" do
    # The worker is linked to the test process: trap exits so a worker crash
    # shows up as a failed assertion, not a crashed test process.
    Process.flag(:trap_exit, true)
    {:ok, worker} = Worker.start_link(Mod)

    # Simulate the TaskSupervisor being unavailable (app shutdown in progress,
    # or a max_children cap someday): terminate it, restore it afterwards.
    on_exit(fn -> Supervisor.restart_child(NebulaAPI.Supervisor, NebulaAPI.TaskSupervisor) end)
    :ok = Supervisor.terminate_child(NebulaAPI.Supervisor, NebulaAPI.TaskSupervisor)

    ref = make_ref()
    send(worker, {:nebula_call, {self(), ref}, {:ping, self()}})

    # The caller gets a fast, tagged failure — not a timeout while the worker
    # (and its whole pending queue) dies of a MatchError/noproc.
    assert_receive {^ref, {:reply, {:nebula_error, {:worker_start_failed, _reason}}}}, 1_000
    assert Process.alive?(worker)

    # And the worker still works once the supervisor is back.
    {:ok, _} = Supervisor.restart_child(NebulaAPI.Supervisor, NebulaAPI.TaskSupervisor)
    ref2 = make_ref()
    send(worker, {:nebula_call, {self(), ref2}, {:ping, self()}})
    assert_receive {^ref2, {:reply, :pong}}, 1_000
  end

  test "a start failure drains the whole pending queue with fast failures" do
    # max_concurrent_calls: 1 — A runs (latched), B and C wait in line. When the
    # TaskSupervisor dies, A's body dies with it (DOWN frees the slot) and the
    # dequeued B fails to start. The failure branch must keep draining: C must
    # get the same fast tagged failure, not sit stranded in the queue while its
    # caller waits out its full timeout (and later arrivals jump ahead of it).
    Process.flag(:trap_exit, true)
    {:ok, worker} = Worker.start_link(SerialMod)

    ref_a = make_ref()
    send(worker, {:nebula_call, {self(), ref_a}, {:gated, self()}})
    assert_receive {:started, _body}, 1_000

    ref_b = make_ref()
    ref_c = make_ref()
    send(worker, {:nebula_call, {self(), ref_b}, {:gated, self()}})
    send(worker, {:nebula_call, {self(), ref_c}, {:gated, self()}})

    on_exit(fn -> Supervisor.restart_child(NebulaAPI.Supervisor, NebulaAPI.TaskSupervisor) end)
    :ok = Supervisor.terminate_child(NebulaAPI.Supervisor, NebulaAPI.TaskSupervisor)

    assert_receive {^ref_b, {:reply, {:nebula_error, {:worker_start_failed, _}}}}, 1_000
    assert_receive {^ref_c, {:reply, {:nebula_error, {:worker_start_failed, _}}}}, 1_000
    assert Process.alive?(worker)
  end
end
