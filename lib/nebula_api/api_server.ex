defmodule NebulaAPI.APIServer do
  @moduledoc """
  Supervisor that manages API workers and handles remote method calls.

  Supports:
  - Default unicast (first available worker)
  - Unicast with node selector
  - Multicast to multiple nodes

  ## Multicast strategies
  - `:all` - Wait for all responses (or timeout)
  - `:first` - Return as soon as one response is received
  - `:quorum` - Wait for N responses (configurable)
  """

  use Supervisor

  require Logger

  @default_timeout 5000

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

  @doc """
  Calls a remote method with optional routing options.

  ## Options
  - `:timeout` - Timeout in milliseconds (default: #{@default_timeout})
  - `:node_selector` - Function that takes nodes_info map and returns node(s) to call
  - `:multicast` - If true, calls multiple nodes and returns list of results
  - `:strategy` - Multicast strategy: `:all`, `:first`, `:quorum` (default: `:all`)
  - `:quorum_count` - Number of responses needed for `:quorum` strategy

  ## Returns
  - For unicast: The result from the remote call
  - For multicast: List of `{:ok, result, node}`, `{:error, reason, node}`, or `{:timeout, node}`
  """
  def call_remote_method(module, fn_call, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    node_selector = Keyword.get(opts, :node_selector)
    multicast = Keyword.get(opts, :multicast, false)
    strategy = Keyword.get(opts, :strategy, :all)

    Logger.debug("""
      Will do remote execution on #{inspect(module)}
      with fn_call : #{inspect(fn_call)}
      opts: #{inspect(opts)}
    """)

    cond do
      multicast && node_selector ->
        # Multicast with selector
        call_selected_workers(module, fn_call, node_selector, timeout, strategy, opts)

      multicast ->
        # Multicast to all workers
        call_all_workers(module, fn_call, timeout, strategy, opts)

      node_selector ->
        # Unicast with selector
        call_selected_worker(module, fn_call, node_selector, timeout)

      true ->
        # Default unicast (first available worker)
        call_first_worker(module, fn_call, timeout)
    end
  rescue
    err -> {:error, err}
  end

  @doc """
  Gets all available workers for a method across all nodes.
  """
  def get_all_workers(module, fn_call) do
    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)
    args_count = tuple_size(fn_args)

    :pg.get_members(:pg_nebula_api, {module, {fn_name, args_count}})
  end

  @doc """
  Builds the nodes_info map with metadata about each node.

  Returns a map like:
  ```
  %{
    :"worker@host.example" => %{
      short_name: :worker,
      long_name: :"worker@host.example",
      host: "host.example",
      tags: [:worker, :video],
      connected: true,
      runtime: %{
        memory_used_mb: 256,
        memory_total_mb: 1024,
        memory_percent: 25.0,
        process_count: 1234,
        schedulers: 8,
        otp_release: "26"
      }
    }
  }
  ```

  Runtime info is only available for connected nodes.
  """
  def build_nodes_info do
    connected_nodes = [node() | Node.list()]

    NebulaAPI.Config.nodes()
    |> Enum.map(fn {node_name, tags} ->
      tags_list =
        case tags do
          t when is_list(t) -> t
          t when is_atom(t) -> [t]
        end

      node_str = to_string(node_name)
      [short_name_str, host] = String.split(node_str, "@", parts: 2)
      short_name = String.to_atom(short_name_str)
      is_connected = node_name in connected_nodes

      info = %{
        short_name: short_name,
        long_name: node_name,
        host: host,
        tags: tags_list,
        connected: is_connected,
        runtime: if(is_connected, do: get_node_runtime_info(node_name), else: nil)
      }

      {node_name, info}
    end)
    |> Map.new()
  end

  @doc """
  Gets runtime information for a specific node.
  Returns nil if the node is not reachable.
  """
  def get_node_runtime_info(target_node) when target_node == node() do
    # Local node - get info directly
    collect_runtime_info()
  end

  def get_node_runtime_info(target_node) do
    # Remote node - use RPC
    case :rpc.call(target_node, __MODULE__, :collect_runtime_info, [], 5000) do
      {:badrpc, _reason} -> nil
      info -> info
    end
  end

  @doc """
  Collects runtime info for the current node.
  This function is called locally or via RPC.
  """
  def collect_runtime_info do
    memory = :erlang.memory()
    memory_total = memory[:total]
    memory_used = memory_total - memory[:free]

    %{
      memory_used_mb: div(memory_used, 1_048_576),
      memory_total_mb: div(memory_total, 1_048_576),
      memory_percent: Float.round(memory_used / memory_total * 100, 1),
      process_count: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }
  end

  @doc """
  Gets nodes_info for workers that are actually available for a method.
  Only includes nodes that have registered workers.
  """
  def get_available_nodes_info(module, fn_call) do
    workers = get_all_workers(module, fn_call)
    all_nodes_info = build_nodes_info()

    # Get the nodes that have workers
    worker_nodes =
      workers
      |> Enum.map(&node/1)
      |> Enum.uniq()

    # Filter nodes_info to only include nodes with workers
    all_nodes_info
    |> Enum.filter(fn {node_name, _info} -> node_name in worker_nodes end)
    |> Map.new()
  end

  # Private functions

  defp get_remote_method_worker(module, fn_call) do
    fn_name = elem(fn_call, 0)
    fn_args = Tuple.delete_at(fn_call, 0)
    args_count = tuple_size(fn_args)

    :pg.get_members(:pg_nebula_api, {module, {fn_name, args_count}})
    |> List.first()
  end

  defp call_first_worker(module, fn_call, timeout) do
    with worker <- module |> get_remote_method_worker(fn_call),
         {:is_pid, true} <- {:is_pid, is_pid(worker)} do
      GenServer.call(worker, fn_call, timeout)
    else
      {:is_pid, false} -> {:error, "No worker found for remote method #{inspect(fn_call)}"}
    end
  end

  defp call_selected_worker(module, fn_call, selector_fn, timeout) do
    nodes_info = get_available_nodes_info(module, fn_call)
    workers = get_all_workers(module, fn_call)

    # Map workers to their nodes
    workers_by_node =
      workers
      |> Enum.group_by(&node/1)
      |> Enum.map(fn {n, pids} -> {n, List.first(pids)} end)
      |> Map.new()

    # Call selector to get target node
    selected_node = selector_fn.(nodes_info)

    if selected_node && Map.has_key?(workers_by_node, selected_node) do
      worker = workers_by_node[selected_node]
      GenServer.call(worker, fn_call, timeout)
    else
      {:error, "No worker found on selected node #{inspect(selected_node)}"}
    end
  end

  defp call_selected_workers(module, fn_call, selector_fn, timeout, strategy, opts) do
    nodes_info = get_available_nodes_info(module, fn_call)
    workers = get_all_workers(module, fn_call)

    # Map workers to their nodes
    workers_by_node =
      workers
      |> Enum.group_by(&node/1)
      |> Enum.map(fn {n, pids} -> {n, List.first(pids)} end)
      |> Map.new()

    # Call selector to get target nodes
    selected_nodes = selector_fn.(nodes_info)
    selected_nodes = if is_list(selected_nodes), do: selected_nodes, else: [selected_nodes]

    # Filter to only nodes with workers
    target_workers =
      selected_nodes
      |> Enum.filter(&Map.has_key?(workers_by_node, &1))
      |> Enum.map(fn node -> {node, workers_by_node[node]} end)

    do_multicast_call(target_workers, fn_call, timeout, strategy, opts)
  end

  defp call_all_workers(module, fn_call, timeout, strategy, opts) do
    workers = get_all_workers(module, fn_call)

    target_workers =
      workers
      |> Enum.map(fn worker -> {node(worker), worker} end)
      |> Enum.uniq_by(fn {n, _} -> n end)

    do_multicast_call(target_workers, fn_call, timeout, strategy, opts)
  end

  defp do_multicast_call([], _fn_call, _timeout, _strategy, _opts) do
    []
  end

  defp do_multicast_call(target_workers, fn_call, timeout, strategy, opts) do
    case strategy do
      :first ->
        do_multicast_first(target_workers, fn_call, timeout)

      :quorum ->
        quorum_count = Keyword.get(opts, :quorum_count, div(length(target_workers), 2) + 1)
        do_multicast_quorum(target_workers, fn_call, timeout, quorum_count)

      _all ->
        do_multicast_all(target_workers, fn_call, timeout)
    end
  end

  defp do_multicast_all(target_workers, fn_call, timeout) do
    target_workers
    |> Enum.map(fn {target_node, worker} ->
      Task.async(fn ->
        try do
          result = GenServer.call(worker, fn_call, timeout)
          {:ok, result, target_node}
        catch
          :exit, {:timeout, _} -> {:timeout, target_node}
          :exit, reason -> {:error, reason, target_node}
        end
      end)
    end)
    |> Task.await_many(timeout + 100)
  end

  defp do_multicast_first(target_workers, fn_call, timeout) do
    parent = self()
    ref = make_ref()

    # Spawn tasks for each worker
    pids =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        spawn_link(fn ->
          try do
            result = GenServer.call(worker, fn_call, timeout)
            send(parent, {ref, {:ok, result, target_node}})
          catch
            :exit, {:timeout, _} -> send(parent, {ref, {:timeout, target_node}})
            :exit, reason -> send(parent, {ref, {:error, reason, target_node}})
          end
        end)
      end)

    # Wait for first successful response
    result = wait_for_first(ref, length(target_workers), timeout, [])

    # Kill remaining tasks
    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    result
  end

  defp wait_for_first(_ref, 0, _timeout, results) do
    # All failed, return all results
    results
  end

  defp wait_for_first(ref, remaining, timeout, results) do
    receive do
      {^ref, {:ok, _, _} = success} ->
        # Got a success, return immediately
        success

      {^ref, failure} ->
        # Got a failure, continue waiting
        wait_for_first(ref, remaining - 1, timeout, [failure | results])
    after
      timeout ->
        # Timeout, return what we have
        results
    end
  end

  defp do_multicast_quorum(target_workers, fn_call, timeout, quorum_count) do
    parent = self()
    ref = make_ref()

    # Spawn tasks for each worker
    pids =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        spawn_link(fn ->
          try do
            result = GenServer.call(worker, fn_call, timeout)
            send(parent, {ref, {:ok, result, target_node}})
          catch
            :exit, {:timeout, _} -> send(parent, {ref, {:timeout, target_node}})
            :exit, reason -> send(parent, {ref, {:error, reason, target_node}})
          end
        end)
      end)

    # Wait for quorum
    result = wait_for_quorum(ref, length(target_workers), timeout, quorum_count, [], [])

    # Kill remaining tasks
    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    result
  end

  defp wait_for_quorum(_ref, 0, _timeout, _needed, successes, failures) do
    # All responses received
    successes ++ failures
  end

  defp wait_for_quorum(_ref, _remaining, _timeout, 0, successes, failures) do
    # Quorum reached
    successes ++ failures
  end

  defp wait_for_quorum(ref, remaining, timeout, needed, successes, failures) do
    receive do
      {^ref, {:ok, _, _} = success} ->
        wait_for_quorum(ref, remaining - 1, timeout, needed - 1, [success | successes], failures)

      {^ref, failure} ->
        wait_for_quorum(ref, remaining - 1, timeout, needed, successes, [failure | failures])
    after
      timeout ->
        # Timeout, return what we have
        successes ++ failures
    end
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
