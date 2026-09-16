defmodule NebulaAPI.WorkerDeathOrphanGuaranteeTest do
  # async: false — kills a Worker outright and asserts on process-level cleanup.
  use ExUnit.Case, async: false

  alias NebulaAPI.APIServer.Worker

  defmodule Mod do
    Module.register_attribute(__MODULE__, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [self_node: node()]
    @nebula_configured_nodes {{:gated, 1}, [node()]}

    # Announces its own pid, then blocks until released.
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

  test "the running body is still killed when its caller dies, even if the Worker itself already died" do
    {:ok, worker} = Worker.start_link(Mod)
    # start_link links the test process to the worker -- unlink before
    # killing it below, or the :kill exit signal takes this test process
    # down with it too.
    Process.unlink(worker)
    parent = self()

    caller =
      spawn(fn ->
        ref = make_ref()
        send(worker, {:nebula_call, {self(), ref}, {:gated, parent}})

        receive do
          :never -> :ok
        end
      end)

    # The body is running, blocked on its latch.
    assert_receive {:started, body}, 1_000
    body_ref = Process.monitor(body)

    # The Worker itself dies -- a pathological message despite the
    # catch-alls, an external kill, supervisor churn (#14's scenario). Its
    # own monitors on the body and the caller vanish with it.
    worker_ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000

    # The body is still running, unmanaged by anything but its own watchdog.
    assert Process.alive?(body)

    # Now the caller dies too. Before the fix, nothing left in the system
    # would ever kill this body -- it would run forever, its slot leaked.
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^body_ref, :process, ^body, :killed}, 1_000
  end

  test "the watchdog does not leak a process once the body finishes normally" do
    {:ok, worker} = Worker.start_link(Mod)
    parent = self()

    caller =
      spawn(fn ->
        ref = make_ref()
        send(worker, {:nebula_call, {self(), ref}, {:gated, parent}})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:started, body}, 1_000

    before = process_count()

    # Let the body finish normally (release the latch).
    send(body, :go)
    body_ref = Process.monitor(body)
    assert_receive {:DOWN, ^body_ref, :process, ^body, :normal}, 1_000

    # Give the watchdog a moment to notice the task's own DOWN and exit too.
    Process.sleep(50)

    assert process_count() <= before,
           "a process was left behind after the body finished normally (watchdog leak)"

    Process.exit(caller, :kill)
    GenServer.stop(worker)
  end

  defp process_count, do: :erlang.system_info(:process_count)
end
