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
end
