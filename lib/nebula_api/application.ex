defmodule NebulaAPI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  def start(_type, _args) do
    Logger.debug("Starting NebulaAPI Application.")

    children = [
      {Task.Supervisor, name: NebulaAPI.TaskSupervisor},
      NebulaAPI.APIServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NebulaAPI.Supervisor)
  end
end
