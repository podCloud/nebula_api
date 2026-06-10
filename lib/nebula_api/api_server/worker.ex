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
       queue: :queue.new(),
       tasks: MapSet.new()
     }}
  end

  # The `use NebulaAPI` opts are persisted in the :nebula_api attribute (see
  # NebulaAPI.__register__/2). Modules without it (test doubles) get the default.
  defp max_concurrent_calls(module) do
    module.__info__(:attributes)
    |> Keyword.get(:nebula_api, [])
    |> Keyword.get(:max_concurrent_calls, :infinity)
  end

  # If a slot is free the call runs now; otherwise it waits in line, MONITORED
  # through its caller. The library only ever calls workers from throwaway
  # processes (confined_call, the multicast fan-out tasks), so the caller's death
  # is exactly how loss of interest manifests — timeout, early :first resolution,
  # caller crash, network partition. The entry is purged on DOWN: event-driven,
  # no clocks to compare across nodes.
  def handle_call({:nebula_call, fn_call}, {caller, _tag} = from, state) do
    if slot_free?(state) do
      start_call(state, {from, fn_call})
    else
      ref = Process.monitor(caller)
      {:noreply, %{state | queue: :queue.in({from, fn_call, ref}, state.queue)}}
    end
  end

  # Two monitor families: a ref in state.tasks is a running call (its DOWN frees
  # a slot, reply or crash); any other ref is a queued caller that died — purge
  # its entry without executing, nobody awaits it anymore.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if MapSet.member?(state.tasks, ref) do
      dequeue_next(%{
        state
        | tasks: MapSet.delete(state.tasks, ref),
          in_flight: state.in_flight - 1
      })
    else
      queue = :queue.filter(fn {_from, _fn_call, r} -> r != ref end, state.queue)
      {:noreply, %{state | queue: queue}}
    end
  end

  defp slot_free?(%{max: :infinity}), do: true
  defp slot_free?(%{max: max, in_flight: in_flight}), do: in_flight < max

  defp start_call(state, {from, fn_call}) do
    module = state.module

    {:ok, pid} =
      Task.Supervisor.start_child(NebulaAPI.TaskSupervisor, fn ->
        GenServer.reply(from, execute_local_call(module, fn_call))
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | tasks: MapSet.put(state.tasks, ref), in_flight: state.in_flight + 1}}
  end

  defp dequeue_next(state) do
    case :queue.out(state.queue) do
      {{:value, {from, fn_call, ref}}, rest} ->
        # :flush — the caller may have died with its DOWN still in our mailbox;
        # drop it so it cannot be mistaken for a task DOWN later. The residual
        # race (caller dies in the same instant we start its call) is the
        # irreducible RPC ambiguity: the reply is a no-op, the body just runs.
        Process.demonitor(ref, [:flush])
        start_call(%{state | queue: rest}, {from, fn_call})

      {:empty, _} ->
        {:noreply, state}
    end
  end

  # Runs the local call and ALWAYS returns a term (never raises). The body's return
  # value is passed through untouched; only lib-level problems become {:nebula_error, _}:
  # - unknown method -> {:nebula_error, {:undefined_local_method, ...}} (instead of crashing the worker)
  # - exception/exit in the body -> {:nebula_error, reason}
  #
  # Runs inside the supervised task spawned by start_call/2, replying via
  # GenServer.reply/2 — the worker itself only does slot/queue bookkeeping (see
  # handle_call), so a slow body never blocks the module's other calls.
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
