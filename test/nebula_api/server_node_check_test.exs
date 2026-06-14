defmodule NebulaAPI.ServerNodeCheckTest do
  # async: false — some tests mutate the global :nebula_api config (nodes, env vars).
  use ExUnit.Case, async: false

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

  test "no check when compiled_node is absent (older wiring)" do
    assert {:ok, _} = NebulaAPI.Server.init(app_module: __MODULE__)
  end

  describe "generic nonode@nohost node" do
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

    test "generic_noop_action: run AS nonode → warn + start nothing" do
      assert {:warn, msg} = NebulaAPI.Server.generic_noop_action(:nonode@nohost)
      assert msg =~ "no API server started"
      assert msg =~ "remote"
    end

    test "generic_noop_action: a nameless build given a real name → crash" do
      assert {:crash, msg} = NebulaAPI.Server.generic_noop_action(:api@host)
      assert msg =~ "nameless"
    end

    test "start_generic_noop crashes in this (named) VM — a nameless build mustn't be named" do
      # The test VM runs as probe@127.0.0.1 (a real name), so the no-op refuses to start.
      assert_raise RuntimeError, ~r/nameless/i, fn -> NebulaAPI.Server.start_generic_noop() end
    end
  end

  describe "node_check/3 — boot-time mismatch policy" do
    alias NebulaAPI.Server

    test "running as exactly the compiled node → ok" do
      assert Server.node_check(:worker@w1, :worker@w1, false) == :ok
    end

    test "a nameless build running as nonode@nohost → ok" do
      assert Server.node_check(:nonode@nohost, :nonode@nohost, false) == :ok
    end

    test "a nameless build given a real name → refused (you're not 'someone' on the net)" do
      assert {:error, :nonode@nohost, :api@host} =
               Server.node_check(:nonode@nohost, :api@host, false)
    end

    test "real build run as nonode@nohost → refused by default" do
      assert {:error, :worker@w1, :nonode@nohost} =
               Server.node_check(:worker@w1, :nonode@nohost, false)
    end

    test "real build run as nonode@nohost → allowed with the escape hatch (quick console)" do
      assert Server.node_check(:worker@w1, :nonode@nohost, true) == :ok
    end

    test "real build run as ANOTHER real node → always refused, even with the escape hatch" do
      assert {:error, :worker@w1, :api@host} =
               Server.node_check(:worker@w1, :api@host, true)
    end
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
end
