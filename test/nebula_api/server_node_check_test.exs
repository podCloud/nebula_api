defmodule NebulaAPI.ServerNodeCheckTest do
  use ExUnit.Case, async: true

  # The test VM runs distributed (started with --name), so node() is a real name.
  # NebulaAPI.Server.init/1 crashes at boot when the release was compiled for a different
  # real node — the compile-time --name and the runtime RELEASE_NODE must match.

  test "init crashes when compiled for a different (real) node" do
    assert_raise RuntimeError, ~r/node mismatch/i, fn ->
      NebulaAPI.Server.init(app_module: __MODULE__, compiled_node: :someone_else@host)
    end
  end

  test "init is happy when the running node matches the compiled node" do
    assert {:ok, _} = NebulaAPI.Server.init(app_module: __MODULE__, compiled_node: node())
  end

  test "no check when the release was compiled without a name (:nonode@nohost)" do
    assert {:ok, _} = NebulaAPI.Server.init(app_module: __MODULE__, compiled_node: :nonode@nohost)
  end

  test "no check when compiled_node is absent (older wiring)" do
    assert {:ok, _} = NebulaAPI.Server.init(app_module: __MODULE__)
  end

  describe "generic nonode@nohost node" do
    import ExUnit.CaptureLog

    test "allow_nonode_nohost: true injects an empty nonode@nohost node" do
      prev = Application.get_env(:nebula_api, :allow_nonode_nohost)
      on_exit(fn -> Application.put_env(:nebula_api, :allow_nonode_nohost, prev) end)

      Application.put_env(:nebula_api, :nodes, [{:"db@db.example", [:db]}])

      Application.put_env(:nebula_api, :allow_nonode_nohost, false)
      refute Keyword.has_key?(NebulaAPI.Config.nodes(), :nonode@nohost)

      Application.put_env(:nebula_api, :allow_nonode_nohost, true)
      assert NebulaAPI.Config.nodes()[:nonode@nohost] == []

      Application.delete_env(:nebula_api, :nodes)
    end

    test "the generic server child is a no-op that warns and starts nothing" do
      log =
        capture_log(fn ->
          assert NebulaAPI.Server.start_generic_noop() == :ignore
        end)

      assert log =~ "no API server started"
      assert log =~ "nonode@nohost"
      assert log =~ "remote"
    end
  end
end
