defmodule NebulaAPI.ServingNodesTest do
  @moduledoc """
  Public introspection of a method's serving nodes (issue #6):
  - configured_nodes/2 — the compile-time serving set (selector over the topology).
  - available_nodes/2  — the live workers (from :pg).
  """
  use ExUnit.Case

  alias NebulaAPI.APIServer

  setup do
    prev = Application.get_env(:nebula_api, :nodes)

    Application.put_env(:nebula_api, :nodes, [
      {:"probe@127.0.0.1", [:db, :cache]},
      {:db2@somewhere, [:db]},
      {:db3@somewhere, [:db]}
    ])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:nebula_api, :nodes, prev),
        else: Application.delete_env(:nebula_api, :nodes)
    end)

    :ok
  end

  defp compile!(name, body) do
    src = """
    defmodule #{name} do
      use NebulaAPI, self_node: :"probe@127.0.0.1"
      #{body}
    end
    """

    [{mod, _bin}] = Code.compile_string(src)
    mod
  end

  test "configured_nodes/2 returns the compile-time serving set for a &tag selector" do
    mod = compile!("SN_Configured", "defapi &db, read(x), do: x")

    assert APIServer.configured_nodes(mod, {:read, 1}) |> Enum.sort() ==
             [:db2@somewhere, :db3@somewhere, :"probe@127.0.0.1"]
  end

  test "configured_nodes/2 for a no-selector method = every configured node" do
    mod = compile!("SN_All", "defapi everywhere(), do: :ok")

    assert APIServer.configured_nodes(mod, {:everywhere, 0}) |> Enum.sort() ==
             [:db2@somewhere, :db3@somewhere, :"probe@127.0.0.1"]
  end

  test "configured_nodes/2 returns [] for an unknown method" do
    mod = compile!("SN_Unknown", "defapi &db, read(x), do: x")
    assert APIServer.configured_nodes(mod, {:nope, 9}) == []
  end

  test "available_nodes/2 is empty with no worker, then includes this node once a worker registers" do
    mod = compile!("SN_Available", "defapi &db, read(x), do: x")

    assert APIServer.available_nodes(mod, {:read, 1}) == []

    {:ok, _pid} = NebulaAPI.APIServer.Worker.start_link(mod)

    assert APIServer.available_nodes(mod, {:read, 1}) == [node()]
  end
end
