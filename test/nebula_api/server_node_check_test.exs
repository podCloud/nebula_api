defmodule NebulaAPI.ServerNodeCheckTest do
  # async: false — these mutate global state (the generic_mode persistent_term, the
  # :nebula_api config, an env var), so they must not run alongside other tests.
  use ExUnit.Case, async: false

  alias NebulaAPI.Server

  # ── init/1 end to end (the test VM runs as a real node, probe@127.0.0.1) ──────────

  test "init serves when running as exactly the compiled node" do
    on_exit(fn -> NebulaAPI.APIServer.set_generic_mode(false) end)
    assert {:ok, _} = Server.init(app_module: __MODULE__, compiled_node: node())
  end

  test "init crashes when compiled for a different real node (no escape hatch)" do
    assert_raise RuntimeError, ~r/node mismatch/i, fn ->
      Server.init(app_module: __MODULE__, compiled_node: :someone_else@host)
    end
  end

  test "init refuses to start with no recorded compiled node" do
    assert_raise RuntimeError, ~r/no recorded compiled node/i, fn ->
      Server.init(app_module: __MODULE__)
    end
  end

  # ── server_mode/3 — the full boot policy, pure and exhaustive ─────────────────────

  describe "server_mode/3 — compiled as a real node (worker@w1)" do
    test "run as worker@w1 → serve" do
      assert Server.server_mode(:worker@w1, :worker@w1, false) == :serve
      assert Server.server_mode(:worker@w1, :worker@w1, true) == :serve
    end

    test "run as another real node, no env var → exit (mismatch)" do
      assert {:exit, msg} = Server.server_mode(:worker@w1, :api@host, false)
      assert msg =~ "node mismatch"
    end

    test "run as another real node, env var → noop, serves nothing, calls remote" do
      assert {:noop, msg} = Server.server_mode(:worker@w1, :api@host, true)
      assert msg =~ "serves nothing"
      assert msg =~ "remotely"
    end

    test "run as nonode@nohost, no env var → exit" do
      assert {:exit, msg} = Server.server_mode(:worker@w1, :nonode@nohost, false)
      assert msg =~ "nonode@nohost"
      assert msg =~ "ALLOW_RUNTIME_NEBULA_NODE_MISMATCH"
    end

    test "run as nonode@nohost, env var → noop, inert" do
      assert {:noop, msg} = Server.server_mode(:worker@w1, :nonode@nohost, true)
      assert msg =~ "inert"
    end
  end

  describe "server_mode/3 — compiled nameless (nonode@nohost, forgot --name)" do
    test "run as a real node, no env var → exit, explains the nameless compile" do
      assert {:exit, msg} = Server.server_mode(:nonode@nohost, :api@host, false)
      assert msg =~ "WITHOUT a node name"
      assert msg =~ "--name"
    end

    test "run as a real node, env var → noop (serves nothing, remote)" do
      assert {:noop, msg} = Server.server_mode(:nonode@nohost, :api@host, true)
      assert msg =~ "serves nothing"
    end

    test "run as nonode@nohost, no env var → exit, must opt in" do
      assert {:exit, msg} = Server.server_mode(:nonode@nohost, :nonode@nohost, false)
      assert msg =~ "ALLOW_RUNTIME_NEBULA_NODE_MISMATCH"
    end

    test "run as nonode@nohost, env var → noop, inert" do
      assert {:noop, msg} = Server.server_mode(:nonode@nohost, :nonode@nohost, true)
      assert msg =~ "inert"
    end
  end

  test "server_mode/3 — no compiled node recorded → refuse to start" do
    assert {:exit, msg} = Server.server_mode(nil, :anything@host, false)
    assert msg =~ "no recorded compiled node"
  end

  # ── runtime flags ─────────────────────────────────────────────────────────────────

  test "force_remote? follows the generic_mode flag (node() is real here)" do
    on_exit(fn -> NebulaAPI.APIServer.set_generic_mode(false) end)

    NebulaAPI.APIServer.set_generic_mode(false)
    refute NebulaAPI.APIServer.force_remote?()

    NebulaAPI.APIServer.set_generic_mode(true)
    assert NebulaAPI.APIServer.force_remote?()
  end

  test "runtime_mismatch_allowed? reads ALLOW_RUNTIME_NEBULA_NODE_MISMATCH" do
    prev = System.get_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH")

    on_exit(fn ->
      if prev,
        do: System.put_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH", prev),
        else: System.delete_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH")
    end)

    System.put_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH", "1")
    assert NebulaAPI.APIServer.runtime_mismatch_allowed?()

    System.delete_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH")
    refute NebulaAPI.APIServer.runtime_mismatch_allowed?()
  end

  # ── config ──────────────────────────────────────────────────────────────────────

  describe "nonode@nohost in config" do
    setup do
      prev = Application.get_env(:nebula_api, :nodes)
      prev_flag = Application.get_env(:nebula_api, :allow_nonode_nohost)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:nebula_api, :nodes, prev),
          else: Application.delete_env(:nebula_api, :nodes)

        Application.put_env(:nebula_api, :allow_nonode_nohost, prev_flag)
      end)

      :ok
    end

    test "a manual nonode@nohost entry is rejected" do
      Application.put_env(:nebula_api, :nodes, [{:nonode@nohost, [:db]}])

      assert_raise ArgumentError, ~r/don't put `nonode@nohost`/, fn ->
        NebulaAPI.Config.nodes()
      end
    end

    test "allow_nonode_nohost: true injects an empty nonode@nohost node" do
      Application.put_env(:nebula_api, :nodes, [{:"db@db.example", [:db]}])

      Application.put_env(:nebula_api, :allow_nonode_nohost, false)
      refute Keyword.has_key?(NebulaAPI.Config.nodes(), :nonode@nohost)

      Application.put_env(:nebula_api, :allow_nonode_nohost, true)
      assert NebulaAPI.Config.nodes()[:nonode@nohost] == []
    end
  end
end
