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

  test "registered_local/remote_methods are derived from the single configured source" do
    # read(x) is &db → local on probe (probe carries :db); elsewhere(x) is @db2 → remote on probe.
    mod =
      compile!("SN_Derived", """
      defapi &db, read(x), do: x
      defapi @:"db2@somewhere", elsewhere(x), do: x
      """)

    assert APIServer.registered_local_methods(mod) == [{:read, 1}]
    assert APIServer.registered_remote_methods(mod) == [{:elsewhere, 1}]
  end

  test "a no-selector defapi compiled off-topology (allow_unknown_self_node) emits no local body" do
    # self_node is NOT in the configured topology — only possible via the escape hatch. Such a
    # node serves nothing, so the no-selector form must compile to a remote stub, not a (dead)
    # local body.
    src = """
    defmodule SN_OffTopo do
      use NebulaAPI, allow_unknown_self_node: true, self_node: :"ghost@nowhere"
      defapi everywhere(), do: :ok
    end
    """

    [{mod, _bin}] = Code.compile_string(src)
    funs = mod.module_info(:functions) |> Keyword.keys()

    # remote stub present (proves module_info lists private helpers), local body suppressed
    assert :__nbapi_remote_everywhere in funs
    refute :__nbapi_local_everywhere in funs

    # and it derives as remote (consistent with codegen)
    assert APIServer.registered_local_methods(mod) == []
    assert APIServer.registered_remote_methods(mod) == [{:everywhere, 0}]
  end

  test "the redundant local/remote method attributes are gone (single source of truth)" do
    mod = compile!("SN_NoDupAttrs", "defapi &db, read(x), do: x")
    keys = mod.__info__(:attributes) |> Keyword.keys()

    refute :nebula_local_api_methods in keys
    refute :nebula_remote_api_methods in keys
    assert :nebula_configured_nodes in keys
  end

  test "available_nodes/2 is empty with no worker, then includes this node once a worker registers" do
    mod = compile!("SN_Available", "defapi &db, read(x), do: x")

    assert APIServer.available_nodes(mod, {:read, 1}) == []

    {:ok, _pid} = NebulaAPI.APIServer.Worker.start_link(mod)

    assert APIServer.available_nodes(mod, {:read, 1}) == [node()]
  end
end
