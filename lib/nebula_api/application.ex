defmodule NebulaAPI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the PubSub system
      # {Phoenix.PubSub, name: Social.PubSub},
      # Start Finch
      # {Finch, name: Social.Finch}
      # Start a worker by calling: Social.Worker.start_link(arg)
      # {Social.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NebulaAPI.Supervisor)
  end
end
