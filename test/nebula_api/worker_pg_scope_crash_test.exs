defmodule NebulaAPI.WorkerPgScopeCrashTest do
  # async: false — kills and restarts the shared, named :pg_nebula_api scope.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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

  defmodule Mod2 do
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

  test "a worker re-joins its methods after the pg scope crashes and restarts" do
    {:ok, worker} = Worker.start_link(Mod)

    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end)

    # Kill the real scope: its supervisor restarts it empty (#13). Don't call
    # :pg.start/1 here too: racing that restart took the whole app down.
    scope_pid = Process.whereis(:pg_nebula_api)
    ref = Process.monitor(scope_pid)
    Process.exit(scope_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^scope_pid, :killed}, 1_000

    assert wait_until(fn ->
             case Process.whereis(:pg_nebula_api) do
               nil -> false
               ^scope_pid -> false
               _new_pid -> true
             end
           end),
           "the supervisor never restarted :pg_nebula_api"

    # The worker is still alive (its own tree wasn't touched)...
    assert Process.alive?(worker)

    # ...and has rejoined on its own (before the fix, it never learned of the crash).
    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end,
             tries: 100
           )

    # And the worker is still fully functional through the rejoined scope.
    assert nebula_call(worker, {:ping, self()}, 1_000) == :pong
    assert_receive :executed, 1_000

    GenServer.stop(worker)
  end

  test "a scope crash landing mid-rejoin does not crash the Worker itself" do
    {:ok, worker} = Worker.start_link(Mod)
    Process.unlink(worker)

    # If an assertion fails before GenServer.stop below, stop the worker anyway:
    # left registered, it would break the other test's start_link.
    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end)

    # A fake scope that dies on the first join call without replying: a crash
    # landing inside the rejoin, between Process.whereis/1 and :pg.join/3.
    # gen_server:call turns that death into an exit, which the fix must survive.
    real_scope = Process.whereis(:pg_nebula_api)
    true = Process.unregister(:pg_nebula_api)

    # Restore the real scope in on_exit too: if an assertion fails, the name
    # would stay bound to a dead pid and break every later test.
    on_exit(fn ->
      case Process.whereis(:pg_nebula_api) do
        nil -> Process.register(real_scope, :pg_nebula_api)
        _already_registered -> :ok
      end
    end)

    fake_scope =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _request} -> Process.exit(self(), :kill)
        end
      end)

    Process.register(fake_scope, :pg_nebula_api)

    worker_ref = Process.monitor(worker)

    # A refactor once dropped the log of the scope's exit reason: prove it's back.
    log =
      capture_log(fn ->
        send(worker, :rejoin_scope)

        # Before the fix, this uncaught exit crashed the Worker.
        refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 300
      end)

    assert log =~ "died again mid-join"
    assert Process.alive?(worker)

    # Restore the real scope (on_exit covers a failure above). The dead fake
    # scope's name is already unregistered.
    Process.exit(fake_scope, :kill)
    true = Process.register(real_scope, :pg_nebula_api)

    # Prove the retry converges, not just that the worker lives: a real call
    # through the re-registered method.
    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end,
             tries: 100
           )

    assert nebula_call(worker, {:ping, self()}, 1_000) == :pong
    assert_receive :executed, 1_000

    GenServer.stop(worker)
  end

  test "a scope crash landing during the worker's own startup does not permanently orphan it" do
    real_scope = Process.whereis(:pg_nebula_api)
    true = Process.unregister(:pg_nebula_api)

    on_exit(fn ->
      case Process.whereis(:pg_nebula_api) do
        nil -> Process.register(real_scope, :pg_nebula_api)
        _already_registered -> :ok
      end
    end)

    # Same fake scope, in place before the worker starts: a crash inside
    # init/1's own join. Before the fix, start_link itself crashed.
    fake_scope =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _request} -> Process.exit(self(), :kill)
        end
      end)

    Process.register(fake_scope, :pg_nebula_api)

    {:ok, worker} = Worker.start_link(Mod2)
    Process.unlink(worker)

    # Same safety net as the mid-rejoin test above.
    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    worker_ref = Process.monitor(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 300
    assert Process.alive?(worker)

    # Restore the real scope for the retry to succeed against.
    Process.exit(fake_scope, :kill)
    true = Process.register(real_scope, :pg_nebula_api)

    # Before the fix, a scope caught mid-restart in init/1 left scope_ref nil
    # forever: the worker never rejoined. Prove it does.
    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod2, {:ping, 1}}) == [worker] end,
             tries: 100
           )

    assert nebula_call(worker, {:ping, self()}, 1_000) == :pong
    assert_receive :executed, 1_000

    GenServer.stop(worker)
  end

  defp nebula_call(worker, fn_call, timeout) do
    ref = make_ref()
    send(worker, {:nebula_call, {self(), ref}, fn_call})
    await_nebula_reply(ref, timeout)
  end

  defp await_nebula_reply(ref, timeout) do
    receive do
      {^ref, {:reply, result}} -> result
      {^ref, :request_more_time} -> await_nebula_reply(ref, timeout)
    after
      timeout -> exit(:timeout)
    end
  end

  defp wait_until(fun, opts \\ []) do
    tries = Keyword.get(opts, :tries, 50)
    do_wait_until(fun, tries)
  end

  defp do_wait_until(fun, tries) do
    cond do
      fun.() ->
        true

      tries <= 0 ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, tries - 1)
    end
  end
end
