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
end
