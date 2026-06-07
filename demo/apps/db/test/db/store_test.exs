defmodule Db.StoreTest do
  use ExUnit.Case

  setup do
    # Db.Application already started Cachex (:demo_cache) on this @db node.
    Cachex.clear(:demo_cache)
    :ok
  end

  test "put then get round-trips through the cluster-wide wrapper" do
    assert Db.Store.put("k", "v") == "v"
    assert Db.Store.get("k") == "v"
  end

  test "incr increments a counter" do
    assert Db.Store.incr("n") == 1
    assert Db.Store.incr("n") == 2
    assert Db.Store.get("n") == 2
  end

  test "keys lists stored keys" do
    Db.Store.put("a", 1)
    Db.Store.put("b", 2)
    assert Enum.sort(Db.Store.keys()) == ["a", "b"]
  end

  test "ready? returns true" do
    assert Db.Store.ready?() == true
  end
end
