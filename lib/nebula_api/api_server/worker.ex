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

  def handle_call({:nebula_call, fn_call, _timeout_ms}, from, state) do
    module = state[:module]

    Task.Supervisor.start_child(NebulaAPI.TaskSupervisor, fn ->
      GenServer.reply(from, execute_local_call(module, fn_call))
    end)

    {:noreply, state}
  end

  # Runs the local call and ALWAYS returns a term (never raises). The body's return
  # value is passed through untouched; only lib-level problems become {:nebula_error, _}:
  # - unknown method -> {:nebula_error, {:undefined_local_method, ...}} (instead of crashing the worker)
  # - exception/exit in the body -> {:nebula_error, reason}
  #
  # Running this in a supervised Task and replying via GenServer.reply/2 keeps the
  # worker free to serve other calls (no serialization, no re-entrant deadlock).
  defp execute_local_call(module, fn_call) do
    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)
    args_count = tuple_size(fn_args)

    known? =
      module
      |> NebulaAPI.APIServer.registered_local_methods()
      |> Enum.member?({fn_name, args_count})

    if known? do
      Logger.debug(
        "Handling remote call for #{module}.#{fn_name}/#{args_count} " <>
          "with args : #{inspect(fn_args)}"
      )

      apply(module, fn_name, Tuple.to_list(fn_args))
    else
      {:nebula_error, {:undefined_local_method, module, fn_name, args_count}}
    end
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:nebula_error, e}
  catch
    kind, reason ->
      {:nebula_error, {kind, reason}}
  end
end
