defmodule Worker.Application do
  @moduledoc false
  use Application
  # `use NebulaAPI.Server` brings the nebula_api_server/0 macro into scope (+ the
  # NebulaAPI.AST macros), without the defapi bookkeeping — this module has no defapi.
  use NebulaAPI.Server

  def start(_type, _args) do
    # NebulaAPI.Server for the :worker app — starts a worker for Worker.Job on every
    # &worker node, and nothing on nodes where Worker.Job has no local method.
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: Worker.Supervisor)
  end
end
