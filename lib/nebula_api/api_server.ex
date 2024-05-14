defmodule NebulaAPI.APIServer do
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(
      [
        pg_spec()
      ] ++
        (registered_modules()
         |> Enum.map(&worker_spec/1)),
      strategy: :one_for_one
    )
  end

  def register_module(module) do
    Application.put_env(
      :nebula_api,
      :registered_modules,
      Enum.uniq(registered_modules() ++ [module])
    )
  end

  def registered_modules() do
    Application.get_env(:nebula_api, :registered_modules, [])
  end

  def registered_remote_methods(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:nebula_remote_api_methods)
    |> List.flatten()
  end

  def registered_local_methods(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:nebula_local_api_methods)
    |> List.flatten()
  end

  def register_local_method_worker(module, method, worker_pid) do
    Logger.debug("[#{node()}] registering local method #{inspect({module, method, worker_pid})}")
    :ok = :pg.join(:pg_nebula_api, {module, method}, worker_pid)
  end

  def get_remote_method_worker(module, fn_call) do
    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)
    args_count = tuple_size(fn_args)

    :pg.get_members(:pg_nebula_api, {module, {fn_name, args_count}})
    |> List.first()
  end

  def call_remote_method(module, fn_call) do
    Logger.debug("""
      Will do remote execution on #{inspect(module)} 
      with fn_call : #{inspect(fn_call)}
    """)

    with worker <- module |> get_remote_method_worker(fn_call),
         {:is_pid, true} <- {:is_pid, is_pid(worker)} do
      worker |> GenServer.call(fn_call, 500)
    else
      {:is_pid, false} -> {:error, "No worker found for remote method #{inspect(fn_call)}"}
    end
  rescue
    err -> {:error, err}
  end

  defp pg_spec(),
    do: %{
      id: :pg_nebula_api,
      start: {:pg, :start_link, [:pg_nebula_api]}
    }

  defp worker_spec(module),
    do: %{
      id: unique_worker_id(module),
      start: {NebulaAPI.APIServer.Worker, :start_link, [module]}
    }

  defp unique_worker_id(module), do: Macro.underscore(module) |> String.replace("/", "_")
end
