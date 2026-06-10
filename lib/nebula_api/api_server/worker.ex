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

    {:ok,
     %{
       module: module,
       max: max_concurrent_calls(module),
       in_flight: 0,
       queue: :queue.new()
     }}
  end

  # The `use NebulaAPI` opts are persisted in the :nebula_api attribute (see
  # NebulaAPI.__register__/2). Modules without it (test doubles) get the default.
  defp max_concurrent_calls(module) do
    module.__info__(:attributes)
    |> Keyword.get(:nebula_api, [])
    |> Keyword.get(:max_concurrent_calls, :infinity)
  end

  # A call ships the caller's timeout BUDGET (a duration — monotonic clocks are
  # not comparable across nodes), from which a LOCAL deadline is computed. If a
  # slot is free the call runs now; otherwise it waits in line, and an entry whose
  # deadline passed by dequeue time is dropped unexecuted: its caller already gave
  # up, running the body would only waste work and fire side effects nobody awaits.
  def handle_call({:nebula_call, fn_call, timeout_ms}, from, state) do
    if slot_free?(state) do
      start_call(state, {from, fn_call})
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      {:noreply, %{state | queue: :queue.in({from, fn_call, deadline}, state.queue)}}
    end
  end

  # Each running call is a monitored task: its DOWN frees the slot whether the
  # task replied normally or crashed.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    dequeue_next(%{state | in_flight: state.in_flight - 1})
  end

  defp slot_free?(%{max: :infinity}), do: true
  defp slot_free?(%{max: max, in_flight: in_flight}), do: in_flight < max

  defp start_call(state, {from, fn_call}) do
    module = state.module

    {:ok, pid} =
      Task.Supervisor.start_child(NebulaAPI.TaskSupervisor, fn ->
        GenServer.reply(from, execute_local_call(module, fn_call))
      end)

    Process.monitor(pid)

    {:noreply, %{state | in_flight: state.in_flight + 1}}
  end

  defp dequeue_next(state) do
    case :queue.out(state.queue) do
      {{:value, {from, fn_call, deadline}}, rest} ->
        if System.monotonic_time(:millisecond) > deadline do
          # Expired while queued: the caller's GenServer.call already exited
          # with :timeout — drop without executing.
          dequeue_next(%{state | queue: rest})
        else
          start_call(%{state | queue: rest}, {from, fn_call})
        end

      {:empty, _} ->
        {:noreply, state}
    end
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
