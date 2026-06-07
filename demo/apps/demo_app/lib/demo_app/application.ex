defmodule DemoApp.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    result = Supervisor.start_link([], strategy: :one_for_one, name: DemoApp.Supervisor)
    Task.start(fn -> DemoApp.Tour.run() end)
    result
  end
end
