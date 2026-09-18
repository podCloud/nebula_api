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

    # Safety net: if any assertion below fails before the explicit
    # Process.exit(worker, :kill) a few lines down, the unlink just removed
    # the only thing that would otherwise have taken the worker down with a
    # crashing test process. Left alive and still registered under `Mod`,
    # it leaks into the next test in this file, whose own
    # Worker.start_link(Mod) then fails with {:error, {:already_started,
    # _}} -- a confusing failure with no relation to whatever this test
    # actually caught.
    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

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

    # Identify the watchdog directly instead of a VM-wide process count: the
    # body is monitored by exactly two processes -- the Worker itself
    # (task_ref = Process.monitor(pid) in start_call/2) and the watchdog
    # (Process.monitor(task_pid) in watch_for_orphan/2). Subtracting the
    # known worker pid leaves the watchdog.
    #
    # start_body_task/4 spawns the watchdog with a plain spawn/1 (fire and
    # forget, no ordering guarantee) and then immediately proceeds -- for
    # `gated/1` that means {:started, body} above can already have been sent
    # before watch_for_orphan/2 has run its own Process.monitor/1. Poll
    # instead of a single snapshot, or this flakes under scheduler pressure
    # (empirically ~1 run in 6-13 with a single Process.info/2 call).
    watchdog =
      wait_until_present(fn ->
        {:monitored_by, monitors} = Process.info(body, :monitored_by)

        case monitors -- [worker] do
          [pid] -> pid
          [] -> nil
        end
      end)

    watchdog_ref = Process.monitor(watchdog)

    # Monitor the body BEFORE releasing its latch: send(body, :go) can let it
    # exit before a monitor placed afterward, in which case Erlang delivers a
    # synthetic :noproc DOWN instead of the real :normal one, and the
    # assert_receive below times out on a run that actually succeeded.
    body_ref = Process.monitor(body)
    send(body, :go)
    assert_receive {:DOWN, ^body_ref, :process, ^body, :normal}, 1_000

    # Before the fix, this observes the actual leak directly: a coarse
    # :erlang.system_info(:process_count) comparison still passes even with a
    # real watchdog leak, because the body's own (much larger) exit already
    # drops the net count -- this instead monitors the specific watchdog pid
    # and proves IT dies too.
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, _reason}, 1_000

    Process.exit(caller, :kill)
    GenServer.stop(worker)
  end

  defp wait_until_present(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_until_present(fun, tries - 1)

      result ->
        result
    end
  end
end
