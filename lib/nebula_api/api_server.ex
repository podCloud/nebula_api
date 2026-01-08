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

  ## Node Info Cache

  Node information is cached in an ETS table (`:nebula_nodes_cache`) to avoid
  expensive RPC calls on every request. Each node entry includes a `last_seen_at`
  timestamp that indicates when the node was last successfully contacted.

  This allows detection of stale nodes - a node may still be marked as `connected: true`
  but if `last_seen_at` is old, it might be unresponsive.

  ## Intelligent Node Selection Examples

  ```elixir
  # Select the node with lowest memory usage
  call_on_node fn nodes_info ->
    nodes_info
    |> Enum.filter(fn {_, info} -> info.connected && info.runtime end)
    |> Enum.min_by(fn {_, info} -> info.runtime.memory_percent end)
    |> elem(0)
  end do
    MyAPI.heavy_task()
  end

  # Select nodes seen in the last 30 seconds
  call_on_nodes fn nodes_info ->
    thirty_seconds_ago = DateTime.add(DateTime.utc_now(), -30, :second)
    nodes_info
    |> Enum.filter(fn {_, info} ->
      info.last_seen_at && DateTime.compare(info.last_seen_at, thirty_seconds_ago) == :gt
    end)
    |> Enum.map(fn {node, _} -> node end)
  end do
    MyAPI.broadcast_update()
  end
  ```
  """

  use Supervisor
  use NebulaAPI, self_node: Application.compile_env(:nebula_api, :default_opts)[:self_node]

  require Logger

  @default_timeout 5000
  @nodes_cache_table :nebula_nodes_cache

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Create ETS table for nodes cache (check if exists to handle supervisor restarts)
    case :ets.whereis(@nodes_cache_table) do
      :undefined ->
        :ets.new(@nodes_cache_table, [:set, :public, :named_table, read_concurrency: true])

      _tid ->
        # Table already exists from previous run
        :ok
    end

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
  Results are cached in ETS and updated with `last_seen_at` timestamps.

  Returns a map like:
  ```
  %{
    :"worker@host.example" => %{
      short_name: :worker,
      long_name: :"worker@host.example",
      host: "host.example",
      tags: [:worker, :video],
      connected: true,
      last_seen_at: ~U[2024-01-15 10:30:00Z],
      runtime: %{
        memory_used_mb: 256,
        memory_total_mb: 1024,
        memory_percent: 25.0,
        process_count: 1234,
        schedulers: 8,
        otp_release: "26",
        uptime_seconds: 3600
      }
    }
  }
  ```

  Runtime info and `last_seen_at` are only updated for connected/reachable nodes.
  If a node becomes unreachable, `last_seen_at` keeps its last value, allowing
  detection of stale nodes.
  """
  def build_nodes_info do
    now = DateTime.utc_now()
    connected_nodes = [node() | Node.list()]

    # Use direct RPC calls to avoid circular dependency (build_nodes_info -> call_on_all_nodes -> build_nodes_info)
    # Parallel execution via Task.async_stream for better performance
    health_results =
      connected_nodes
      |> Task.async_stream(
        fn target_node ->
          if target_node == node() do
            # Local call
            {:ok, collect_node_health_data_local(), target_node}
          else
            # Remote RPC call
            case :rpc.call(target_node, __MODULE__, :collect_node_health_data_local, [], 5000) do
              {:badrpc, reason} -> {:error, reason, target_node}
              result -> {:ok, result, target_node}
            end
          end
        end,
        timeout: 6000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:timeout, :unknown}
      end)
      |> Enum.filter(fn
        {:timeout, :unknown} -> false
        _ -> true
      end)

    # Build a map of successful responses by node
    health_by_node =
      health_results
      |> Enum.filter(fn
        {:ok, _data, _node} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, data, node} -> {node, data} end)
      |> Map.new()

    # Build full nodes_info including nodes that didn't respond
    NebulaAPI.Config.nodes()
    |> Enum.map(fn {node_name, _tags} ->
      is_connected = node_name in connected_nodes
      cached = get_cached_node_info(node_name)

      info =
        case Map.get(health_by_node, node_name) do
          nil ->
            # Node didn't respond, use cached data
            %{
              short_name: cached[:short_name] || node_name,
              long_name: node_name,
              host: cached[:host] || "unknown",
              tags: cached[:tags] || [],
              connected: is_connected,
              last_seen_at: cached[:last_seen_at],
              runtime: cached[:runtime]
            }

          health_data ->
            # Node responded successfully
            Map.put(health_data, :last_seen_at, now)
        end

      # Update cache
      cache_node_info(node_name, info)

      {node_name, info}
    end)
    |> Map.new()
  end

  @doc """
  Gets cached node info from ETS.
  Returns empty map if not found.
  """
  def get_cached_node_info(node_name) do
    case :ets.lookup(@nodes_cache_table, node_name) do
      [{^node_name, info}] -> info
      [] -> %{}
    end
  rescue
    # Table doesn't exist yet
    ArgumentError -> %{}
  end

  @doc """
  Caches node info in ETS.
  """
  def cache_node_info(node_name, info) do
    :ets.insert(@nodes_cache_table, {node_name, info})
  rescue
    # Table doesn't exist yet
    ArgumentError -> :ok
  end

  @doc """
  Refreshes the nodes cache by fetching fresh runtime info from all nodes.
  Call this periodically (e.g., every 30 seconds) to keep the cache fresh.
  """
  def refresh_nodes_cache do
    build_nodes_info()
  end

  @doc """
  Collects complete health data for the current node.
  This is used by build_nodes_info/0 via direct RPC calls to avoid circular dependencies.
  """
  def collect_node_health_data_local do
    node_name = node()
    node_str = to_string(node_name)

    # Parse node name safely
    {short_name, host} =
      case String.split(node_str, "@", parts: 2) do
        [short_name_str, host_str] ->
          {String.to_atom(short_name_str), host_str}

        _ ->
          # Malformed node name, use defaults
          Logger.warning("Malformed node name: #{node_str}")
          {node_name, "unknown"}
      end

    # Find this node's tags from config
    tags =
      NebulaAPI.Config.nodes()
      |> Enum.find_value(fn {n, t} ->
        if n == node_name do
          case t do
            t when is_list(t) -> t
            t when is_atom(t) -> [t]
          end
        end
      end) || []

    %{
      short_name: short_name,
      long_name: node_name,
      host: host,
      tags: tags,
      connected: true,
      runtime: collect_runtime_info()
    }
  end

  @doc """
  Collects runtime info for the current node.
  This is a private helper function used by node_health_data/0.
  """
  def collect_runtime_info do
    memory = :erlang.memory()
    memory_total = memory[:total]
    # Calculate used memory from actual Erlang memory components
    memory_used = memory[:processes] + memory[:binary] + memory[:ets]

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
  NebulaAPI endpoint for collecting node health data.
  Returns runtime info and metadata for the current node.

  This API is available on ALL nodes (using :* marker) so each node
  can report its own health data.
  """
  import NebulaAPI.Config
  require NebulaAPI.Config

  defapi :*, node_health_data() do
    node_name = node()
    node_str = to_string(node_name)

    # Parse node name safely
    {short_name, host} =
      case String.split(node_str, "@", parts: 2) do
        [short_name_str, host_str] ->
          {String.to_atom(short_name_str), host_str}

        _ ->
          # Malformed node name, use defaults
          Logger.warning("Malformed node name: #{node_str}")
          {node_name, "unknown"}
      end

    # Find this node's tags from config
    tags =
      NebulaAPI.Config.nodes()
      |> Enum.find_value(fn {n, t} ->
        if n == node_name do
          case t do
            t when is_list(t) -> t
            t when is_atom(t) -> [t]
          end
        end
      end) || []

    %{
      short_name: short_name,
      long_name: node_name,
      host: host,
      tags: tags,
      connected: true,
      runtime: collect_runtime_info()
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

    # Spawn tasks for each worker using Task.async
    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.async(fn ->
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

    # Shutdown remaining tasks gracefully
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
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

    # Spawn tasks for each worker using Task.async
    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.async(fn ->
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

    # Shutdown remaining tasks gracefully
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
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
