defmodule Db.StoreTest do
  use ExUnit.Case

  # defapi always wraps the body's return value in {:ok, value}.

  setup do
    # Db.Application already started Cachex (:demo_cache) on this @db node.
    Cachex.clear(:demo_cache)
    :ok
  end

  test "put then get round-trips through the cluster-wide wrapper" do
    assert Db.Store.put("k", "v") == {:ok, "v"}
    assert Db.Store.get("k") == {:ok, "v"}
  end

  test "incr increments a counter" do
    assert Db.Store.incr("n") == {:ok, 1}
    assert Db.Store.incr("n") == {:ok, 2}
    assert Db.Store.get("n") == {:ok, 2}
  end

  test "keys lists stored keys" do
    Db.Store.put("a", 1)
    Db.Store.put("b", 2)
    assert {:ok, keys} = Db.Store.keys()
    assert Enum.sort(keys) == ["a", "b"]
  end

  test "ready? returns true" do
    assert Db.Store.ready?() == {:ok, true}
  end
end
