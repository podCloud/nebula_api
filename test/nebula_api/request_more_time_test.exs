defmodule NebulaAPI.RequestMoreTimeTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer
  alias NebulaAPI.APIServer.Worker

  defmodule Mod do
    Module.register_attribute(__MODULE__, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__MODULE__, :nebula_api, persist: true)

    @nebula_api [self_node: node()]
    @nebula_configured_nodes {{:slow_but_alive, 0}, [node()]}
    @nebula_configured_nodes {{:greedy, 1}, [node()]}

    # Runs for ~400ms in 100ms steps, heartbeating between each. Any single
    # window (100ms) is well under the 300ms call timeout, but the total exceeds
    # it — so the call only survives if each heartbeat resets the deadline.
    def slow_but_alive do
      Enum.each(1..4, fn _ ->
        Process.sleep(100)
        NebulaAPI.request_more_time()
      end)

      :done
    end

    # Announces itself, then heartbeats forever. It should be killed once its
    # extension budget is spent — the beats past the limit must not extend it.
    def greedy(parent) do
      send(parent, {:started, self()})

      Enum.each(1..100, fn _ ->
        Process.sleep(50)
        NebulaAPI.request_more_time()
      end)

      :never_returns
    end
  end

  setup_all do
    case :pg.start(:pg_nebula_api) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case :ets.whereis(:nebula_nodes_cache) do
      :undefined ->
        :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  test "a body that heartbeats survives past the call timeout" do
    {:ok, worker} = Worker.start_link(Mod)

    # 300ms timeout, ~400ms body: without the heartbeats this returns
    # {:nebula_error, :timeout}. With them, it returns the body's value.
    result = APIServer.call_remote_method(Mod, {:slow_but_alive}, timeout: 300)

    assert result == :done

    GenServer.stop(worker)
  end

  test "request_more_time/0 is a harmless no-op outside a nebula call" do
    # No :nebula_api_call stashed in this process → nothing to extend, no crash.
    assert NebulaAPI.request_more_time() == :ok
  end

  test "a body that heartbeats within its explicit limit still survives" do
    {:ok, worker} = Worker.start_link(Mod)

    # 4 beats, limit 5 → all honored, survives.
    result =
      APIServer.call_remote_method(Mod, {:slow_but_alive}, timeout: 200, max_time_extensions: 5)

    assert result == :done

    GenServer.stop(worker)
  end

  test "a body that heartbeats past its extension limit is killed" do
    {:ok, worker} = Worker.start_link(Mod)
    parent = self()

    # limit 2, 150ms window: only 2 beats extend; the greedy body wants far more,
    # so ~2 windows after the last honored beat the caller times out and kills it.
    spawn(fn ->
      r =
        APIServer.call_remote_method(Mod, {:greedy, parent},
          timeout: 150,
          max_time_extensions: 2
        )

      send(parent, {:call_result, r})
    end)

    assert_receive {:started, body}, 1_000
    body_ref = Process.monitor(body)

    assert_receive {:DOWN, ^body_ref, :process, ^body, :killed}, 3_000
    assert_receive {:call_result, {:nebula_error, :timeout}}, 1_000

    GenServer.stop(worker)
  end

  test "a multicast body cannot outlive the fan-out deadline by heartbeating" do
    {:ok, worker} = Worker.start_link(Mod)
    parent = self()

    # On the multicast path the fan-out has its own hard deadline (brutal-kills the
    # straggler tasks), so a greedy heartbeating body is bounded there too — and the
    # extension budget is threaded down this path as well (defense in depth).
    spawn(fn ->
      APIServer.call_remote_method(Mod, {:greedy, parent},
        multicast: true,
        strategy: :all,
        timeout: 150,
        max_time_extensions: 2
      )
    end)

    assert_receive {:started, body}, 1_000
    body_ref = Process.monitor(body)

    assert_receive {:DOWN, ^body_ref, :process, ^body, :killed}, 3_000

    GenServer.stop(worker)
  end
end
