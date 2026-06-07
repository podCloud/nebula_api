defmodule Db.Application do
  @moduledoc false
  use Application
  use NebulaAPI

  def start(_type, _args) do
    cluster = [
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies), [name: Db.ClusterSupervisor]]}
    ]

    cache =
      on_nebula_nodes @db do
        [{Cachex, name: :demo_cache}]
      else
        []
      end

    Supervisor.start_link(cluster ++ cache, strategy: :one_for_one, name: Db.Supervisor)
  end
end
