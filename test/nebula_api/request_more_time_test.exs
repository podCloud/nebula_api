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
end
