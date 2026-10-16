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
    # Unlink, or killing the worker below kills this test too.
    Process.unlink(worker)

    # If an assertion fails before the kill below, stop the worker anyway:
    # left registered, it would break the next test's start_link.
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

    # The Worker dies (#14): its own monitors on the body and caller go with it.
    worker_ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000

    # The body is still running, unmanaged by anything but its own watchdog.
    assert Process.alive?(body)

    # Now the caller dies: before the fix, nothing would ever kill the body.
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

    # The body is monitored by the Worker and the watchdog: drop the worker's
    # pid to find the watchdog. It is spawned without ordering, so poll for it
    # (a single snapshot flaked about 1 run in 10).
    watchdog =
      wait_until_present(fn ->
        {:monitored_by, monitors} = Process.info(body, :monitored_by)

        case monitors -- [worker] do
          [pid] -> pid
          [] -> nil
        end
      end)

    watchdog_ref = Process.monitor(watchdog)

    # Monitor before releasing the latch, or a quick exit yields :noproc.
    body_ref = Process.monitor(body)
    send(body, :go)
    assert_receive {:DOWN, ^body_ref, :process, ^body, :normal}, 1_000

    # Watch the watchdog pid itself: a process count would hide its leak.
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
