defmodule Worker.Application do
  @moduledoc false
  use Application
  # `use NebulaAPI` brings the nebula_api_server/0 macro into scope (and marks this
  # module — harmless: it has no defapi, so NebulaAPI.Server discovers no local
  # method for it).
  use NebulaAPI

  def start(_type, _args) do
    # NebulaAPI.Server for the :worker app — starts a worker for Worker.Job on every
    # &worker node, and nothing on nodes where Worker.Job has no local method.
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: Worker.Supervisor)
  end
end
