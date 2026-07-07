defmodule NebulaAPI.WorkerCallerDeathTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer
  alias NebulaAPI.APIServer.Worker

  # Same shape as the other worker tests: the persisted markers the worker reads
  # to register itself and validate calls. [node()] = local on this test node.
  defmodule Mod do
    Module.register_attribute(__MODULE__, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [self_node: node()]
    @nebula_configured_nodes {{:gated, 1}, [node()]}
    @nebula_configured_nodes {{:ping, 1}, [node()]}

    # Announces its own pid, then blocks until released.
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

    # call_remote_method reads the node-info cache table on the unicast path.
    case :ets.whereis(:nebula_nodes_cache) do
      :undefined ->
        :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  # Mirrors safe_call/3's request/reply/heartbeat protocol: send the message,
  # await the tagged reply, and treat a :request_more_time heartbeat as "keep
  # waiting" (like the real caller loop). Exits on timeout.
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

  test "a running call whose caller dies has its body killed and its slot freed" do
    {:ok, worker} = Worker.start_link(Mod)
    parent = self()

    # A caller that starts a gated (blocking) call, then waits forever to be killed.
    caller =
      spawn(fn ->
        ref = make_ref()
        send(worker, {:nebula_call, {self(), ref}, {:gated, parent}})

        receive do
          :never -> :ok
        end
      end)

    # The body is running, blocked on its latch, and told us its own pid.
    assert_receive {:started, body}, 1_000
    body_ref = Process.monitor(body)

    # The caller dies mid-execution → the worker must kill the running body.
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^body_ref, :process, ^body, :killed}, 1_000

    # The slot was freed: a fresh call runs to completion.
    assert nebula_call(worker, {:ping, parent}, 1_000) == :pong
    assert_receive :executed, 1_000

    GenServer.stop(worker)
  end

  test "a call that times out kills the running body (end-to-end #10 scenario)" do
    {:ok, worker} = Worker.start_link(Mod)
    parent = self()

    # A real unicast call whose body blocks past the timeout. call_remote_method
    # runs it through the throwaway confined_call task — exactly the caller the
    # worker monitors. When it gives up, its death kills the orphaned body.
    spawn(fn -> APIServer.call_remote_method(Mod, {:gated, parent}, timeout: 100) end)

    assert_receive {:started, body}, 1_000
    body_ref = Process.monitor(body)

    # The 100ms timeout elapses, the caller gives up and dies → the body is killed.
    assert_receive {:DOWN, ^body_ref, :process, ^body, :killed}, 2_000

    GenServer.stop(worker)
  end
end
