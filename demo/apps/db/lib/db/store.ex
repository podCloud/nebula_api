defmodule Db.Store do
  @moduledoc "Cluster-wide key/value store: a Cachex cache wrapped with defapi @db."
  use NebulaAPI
  require Logger

  defapi @db, get(key) do
    Logger.info("🗄️  [#{node()}] Db.Store.get(#{inspect(key)})")
    {:ok, value} = Cachex.get(:demo_cache, key)
    value
  end

  defapi @db, put(key, value) do
    Logger.info("🗄️  [#{node()}] Db.Store.put(#{inspect(key)}, #{inspect(value)})")
    {:ok, true} = Cachex.put(:demo_cache, key, value)
    value
  end

  defapi @db, incr(key) do
    Logger.info("🗄️  [#{node()}] Db.Store.incr(#{inspect(key)})")
    {:ok, n} = Cachex.incr(:demo_cache, key)
    n
  end

  defapi @db, keys() do
    {:ok, ks} = Cachex.keys(:demo_cache)
    ks
  end

  # Readiness probe used by DemoApp.Tour (dogfooding the lib to detect cluster up).
  defapi @db, ready?(), do: true
end
