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

    # NebulaAPI.Server for the :db app — starts a worker for Db.Store only on the
    # node where it's local (@db). On every other node it discovers no local method
    # and starts nothing.
    children = cluster ++ cache ++ [nebula_api_server()]

    Supervisor.start_link(children, strategy: :one_for_one, name: Db.Supervisor)
  end
end
