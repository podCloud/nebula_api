defmodule NebulaAPI.APIServer.Worker do
  use GenServer
  require Logger

  def start_link(module) do
    GenServer.start_link(__MODULE__, module, name: module)
  end

  def init(module) do
    module
    |> NebulaAPI.APIServer.registered_local_methods()
    |> Enum.each(fn method ->
      NebulaAPI.APIServer.register_local_method_worker(
        module,
        method,
        self()
      )
    end)

    {:ok, [module: module]}
  end

  defp guard_undefined_local_api_calls(module, fn_call) do
    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)
    args_count = tuple_size(fn_args)

    method_exists =
      module
      |> NebulaAPI.APIServer.registered_local_methods()
      |> Enum.member?({fn_name, args_count})

    unless method_exists do
      raise "calling an undefined local Nebula API method #{module}.#{fn_name}/#{args_count}"
    end

    module
  end

  def handle_call(fn_call, _from, state) do
    guard_undefined_local_api_calls(state[:module], fn_call)

    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)

    Logger.debug(
      "Handling remote call for " <>
        "#{state[:module]}.#{fn_name}/#{fn_args |> tuple_size()} " <>
        "with args : #{inspect(fn_args)}"
    )

    {:reply, apply(state[:module], fn_name, fn_args |> Tuple.to_list()), state}
  end
end
