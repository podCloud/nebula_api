defmodule NebulaAPI.WorkerPgScopeCrashTest do
  # async: false — kills and restarts the shared, named :pg_nebula_api scope.
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

  test "a worker re-joins its methods after the pg scope crashes and restarts" do
    {:ok, worker} = Worker.start_link(Mod)

    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end)

    # Kill the scope process outright. It's a real supervised child of the
    # live NebulaAPI.APIServer supervisor (started by the application, not by
    # this test) -- its OWN :one_for_one supervisor restarts it automatically,
    # with EMPTY state, exactly the real crash this issue is about. Do NOT
    # also call :pg.start/1 by hand here: racing the supervisor's own restart
    # for the same registered name is what actually caused this test to take
    # the whole application down the first time this was written.
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

    # ...and must have re-joined on its own -- nothing else in this test does
    # it. Before the fix, this never becomes true (the worker doesn't monitor
    # the scope, so it never even learns it crashed).
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

    assert wait_until(fn -> :pg.get_members(:pg_nebula_api, {Mod, {:ping, 1}}) == [worker] end)

    # Steal the :pg_nebula_api name for a fake scope that dies the instant it
    # receives a join call, WITHOUT replying -- deterministically reproducing
    # a second crash landing exactly inside handle_info(:rejoin_scope, ...)'s
    # join loop (the TOCTOU window between this handler's own
    # Process.whereis/1 and :pg.join/3's internal, independent resolution of
    # the same name), without needing to win a real microsecond-scale race.
    # gen_server:call/3 (what :pg.join/3 uses internally) monitors its
    # target for the duration of the call specifically so a mid-call death
    # doesn't hang the caller forever -- it raises an uncaught exit instead,
    # which is exactly the crash this test proves the fix survives.
    real_scope = Process.whereis(:pg_nebula_api)
    true = Process.unregister(:pg_nebula_api)

    fake_scope =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _request} -> Process.exit(self(), :kill)
        end
      end)

    Process.register(fake_scope, :pg_nebula_api)

    worker_ref = Process.monitor(worker)
    send(worker, :rejoin_scope)

    # Before the fix: handle_info(:rejoin_scope, ...) has no rescue/catch
    # around the join loop, so the uncaught exit from the dead fake scope
    # crashes the Worker GenServer itself.
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 300
    assert Process.alive?(worker)

    # Restore the real scope's registration so later tests aren't affected.
    Process.exit(fake_scope, :kill)
    true = Process.register(real_scope, :pg_nebula_api)

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
