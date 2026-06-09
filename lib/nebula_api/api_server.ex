defmodule NebulaAPI.APIServer do
  @moduledoc """
  Supervisor that manages API workers and handles remote method calls.

  Supports:
  - Default unicast (first available worker)
  - Unicast with node selector
  - Multicast to multiple nodes

  ## Multicast strategies
  - `:all` - Wait for all responses (or timeout), returns list of results
  - `:first` - Return as soon as one response is received
  - `:quorum` - Wait for N responses (configurable), returns tagged result:
    - `{:ok, results}` when quorum is reached
    - `{:error, :quorum_not_reached, results}` when not enough successful responses
    - `{:error, :quorum_timeout, results}` when timeout occurs before quorum

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

  require Logger

  @default_timeout 5000
  @nodes_cache_table :nebula_nodes_cache
  @nodes_info_cache_key :__nodes_info_snapshot__

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Create ETS table for nodes cache
    # Use try/rescue to handle race condition where multiple processes
    # might try to create the table simultaneously
    try do
      :ets.new(@nodes_cache_table, [:set, :public, :named_table, read_concurrency: true])
    rescue
      ArgumentError ->
        # Table already exists (created by another process or previous run)
        :ok
    end

    # Only the cluster-wide bits live here: the :pg scope used for routing, the ETS
    # nodes cache created above, and the per-node NodesInfoCache that refreshes the
    # node-info snapshot in the background. Per-module workers are NOT started here —
    # each consumer app owns a NebulaAPI.Server in its own tree (see the
    # nebula_api_server/0 macro), which discovers and supervises its modules' workers.
    Supervisor.init(
      [pg_spec(), NebulaAPI.APIServer.NodesInfoCache],
      strategy: :one_for_one
    )
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
  - For multicast with `:all` strategy: List of `{:ok, result, node}`, `{:error, reason, node}`, or `{:timeout, node}`
  - For multicast with `:first` strategy: `{:ok, result, node}` on first success, or list of failures
  - For multicast with `:quorum` strategy: `{:ok, results}` when quorum reached,
    `{:error, :quorum_not_reached, results}` or `{:error, :quorum_timeout, results}` otherwise
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
    err ->
      Logger.error("""
      Remote method call failed:
        module: #{inspect(module)}
        fn_call: #{inspect(fn_call)}
        opts: #{inspect(opts)}
        error: #{Exception.message(err)}
        stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      {:error, err}
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
      |> Enum.map(&normalize_stream_result/1)
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

  # Normalize one Task.async_stream result. A successful task yields {:ok, value};
  # a timed-out task yields {:exit, :timeout}; any OTHER exit (the task crashed —
  # e.g. a raise in collect_node_health_data_local) must not be fatal to the whole
  # build, so it is mapped to a drop marker too instead of raising FunctionClauseError.
  @doc false
  def normalize_stream_result({:ok, result}), do: result
  def normalize_stream_result({:exit, :timeout}), do: {:timeout, :unknown}
  def normalize_stream_result({:exit, _reason}), do: {:timeout, :unknown}

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
  Returns the latest cluster node-info snapshot.

  Reads the snapshot written by `NebulaAPI.APIServer.NodesInfoCache` (which keeps
  it fresh in the background) — it does NOT rebuild on read, so concurrent callers
  never trigger an RPC fan-out. Only on a cold cache (no snapshot yet, before the
  first refresh) does it build once as a fallback, so it never returns an empty map.
  """
  def get_nodes_info do
    case :ets.lookup(@nodes_cache_table, @nodes_info_cache_key) do
      [{_, %{data: data}}] ->
        data

      _ ->
        refresh_nodes_cache()
    end
  rescue
    ArgumentError -> build_nodes_info()
  end

  @doc """
  Refreshes the nodes cache by fetching fresh runtime info from all nodes.
  """
  def refresh_nodes_cache do
    data = build_nodes_info()

    try do
      :ets.insert(@nodes_cache_table, {
        @nodes_info_cache_key,
        %{data: data, updated_at: System.monotonic_time(:millisecond)}
      })
    rescue
      ArgumentError -> :ok
    end

    data
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
            _ -> []
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
  This is a helper function used by collect_node_health_data_local/0.

  - `memory_used`: Total memory allocated by the Erlang VM (`:erlang.memory(:total)`)
  - `memory_total`: Total system RAM (from `/proc/meminfo` on Linux, falls back to VM total)
  - `memory_percent`: VM memory usage as percentage of system RAM
  """
  def collect_runtime_info do
    memory_used = :erlang.memory(:total)
    memory_total = get_system_memory_total() || memory_used

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

  defp get_system_memory_total do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
          [_, kb_str] -> String.to_integer(kb_str) * 1024
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Note: We previously had a `defapi :*, node_health_data()` here, but it was removed
  # because build_nodes_info/0 uses direct RPC calls to collect_node_health_data_local/0
  # to avoid circular dependencies. The defapi version would cause:
  # build_nodes_info -> call_on_all_nodes -> call_remote_method -> build_nodes_info
  #
  # If you need a public API endpoint for node health, use collect_node_health_data_local/0
  # directly via RPC, or create a separate module that doesn't depend on build_nodes_info.

  require NebulaAPI.Config

  @doc """
  Gets nodes_info for workers that are actually available for a method.
  Only includes nodes that have registered workers.
  """
  def get_available_nodes_info(module, fn_call) do
    workers = get_all_workers(module, fn_call)
    all_nodes_info = get_nodes_info()

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

  # Wraps a GenServer.call: tells a received reply apart from an exit (timeout / other).
  # `{:replied, term}` = the worker replied (term may be a business-level error).
  # `{:exit, :timeout}` / `{:exit, reason}` = the call exited without a reply.
  defp safe_call(worker, fn_call, timeout) do
    {:replied, GenServer.call(worker, fn_call, timeout)}
  catch
    :exit, {:timeout, _} -> {:exit, :timeout}
    :exit, reason -> {:exit, reason}
  end

  # Confined unicast: the GenServer.call runs in a throwaway Task, so that a late
  # reply {ref, reply} (left behind by a call that timed out) lands in the Task's
  # mailbox — which dies — and never in the caller's. The Task always returns
  # quickly (safe_call has an internal timeout), so Task.await/:infinity can neither
  # block nor exit.
  defp confined_call(worker, fn_call, timeout) do
    task =
      Task.async(fn ->
        case safe_call(worker, fn_call, timeout) do
          {:replied, reply} -> reply
          {:exit, :timeout} -> {:error, :timeout}
          {:exit, reason} -> {:error, reason}
        end
      end)

    Task.await(task, :infinity)
  end

  # Node-tagged multicast call, built on safe_call/3. Same return shape as the
  # previous inline code: {status, value, node} on a reply, {:timeout, node} /
  # {:error, reason, node} on an exit.
  defp tagged_call(worker, fn_call, timeout, target_node) do
    case safe_call(worker, fn_call, timeout) do
      {:replied, reply} ->
        {status, value} = unwrap_worker_result(reply)
        {status, value, target_node}

      {:exit, :timeout} ->
        {:timeout, target_node}

      {:exit, reason} ->
        {:error, reason, target_node}
    end
  end

  defp call_first_worker(module, fn_call, timeout) do
    case get_remote_method_worker(module, fn_call) do
      worker when is_pid(worker) ->
        confined_call(worker, fn_call, timeout)

      _ ->
        {:error, "No worker found for remote method #{inspect(fn_call)}"}
    end
  end

  defp call_selected_worker(module, fn_call, selector_fn, timeout) do
    workers = get_all_workers(module, fn_call)

    # Map workers to their nodes
    workers_by_node =
      workers
      |> Enum.group_by(&node/1)
      |> Enum.map(fn {n, pids} -> {n, List.first(pids)} end)
      |> Map.new()

    # Filter nodes_info to only nodes with workers
    nodes_info = filter_nodes_info_for_workers(workers_by_node)

    # Call selector to get target node (with error handling)
    case safe_call_selector(selector_fn, nodes_info) do
      {:ok, selected_node} ->
        if selected_node && Map.has_key?(workers_by_node, selected_node) do
          worker = workers_by_node[selected_node]
          confined_call(worker, fn_call, timeout)
        else
          {:error, "No worker found on selected node #{inspect(selected_node)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_selected_workers(module, fn_call, selector_fn, timeout, strategy, opts) do
    workers = get_all_workers(module, fn_call)

    # Map workers to their nodes
    workers_by_node =
      workers
      |> Enum.group_by(&node/1)
      |> Enum.map(fn {n, pids} -> {n, List.first(pids)} end)
      |> Map.new()

    # Filter nodes_info to only nodes with workers
    nodes_info = filter_nodes_info_for_workers(workers_by_node)

    # Call selector to get target nodes (with error handling)
    case safe_call_selector(selector_fn, nodes_info) do
      {:ok, selected_nodes} ->
        selected_nodes = if is_list(selected_nodes), do: selected_nodes, else: [selected_nodes]

        # Filter to only nodes with workers
        target_workers =
          selected_nodes
          |> Enum.filter(&Map.has_key?(workers_by_node, &1))
          |> Enum.map(fn node -> {node, workers_by_node[node]} end)

        do_multicast_call(target_workers, fn_call, timeout, strategy, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_nodes_info_for_workers(workers_by_node) do
    worker_nodes = Map.keys(workers_by_node)

    get_nodes_info()
    |> Enum.filter(fn {node_name, _info} -> node_name in worker_nodes end)
    |> Map.new()
  end

  defp safe_call_selector(selector_fn, nodes_info) do
    {:ok, selector_fn.(nodes_info)}
  catch
    kind, reason ->
      Logger.error("Node selector function failed: #{inspect(kind)} - #{inspect(reason)}")
      {:error, {:selector_failed, reason}}
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
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.async(fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    received = wait_for_all(ref, length(target_workers), deadline, [])

    Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)
    flush_ref(ref)

    # Guarantee one entry per targeted node: nodes that did not answer before the
    # deadline are reported as {:timeout, node} instead of being silently dropped.
    # This preserves the previous Task.await_many contract (one result per node)
    # without exiting the caller on timeout.
    answered = MapSet.new(received, &result_node/1)

    timeouts =
      for {target_node, _worker} <- target_workers,
          not MapSet.member?(answered, target_node),
          do: {:timeout, target_node}

    received ++ timeouts
  end

  defp wait_for_all(_ref, 0, _deadline, results) do
    Enum.reverse(results)
  end

  defp wait_for_all(ref, remaining, deadline, results) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, response} ->
        wait_for_all(ref, remaining - 1, deadline, [response | results])
    after
      remaining_ms ->
        Enum.reverse(results)
    end
  end

  defp result_node({:timeout, target_node}), do: target_node
  defp result_node({_status, _value, target_node}), do: target_node

  defp do_multicast_first(target_workers, fn_call, timeout) do
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    # Spawn tasks for each worker using Task.async
    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.async(fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    # Wait for first successful response
    result = wait_for_first(ref, length(target_workers), deadline, [])

    # Shutdown remaining tasks gracefully
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    # Flush stray messages from tasks that sent before being killed
    flush_ref(ref)

    result
  end

  defp wait_for_first(_ref, 0, _deadline, results) do
    # All failed, return all results
    results
  end

  defp wait_for_first(ref, remaining, deadline, results) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:ok, _, _} = success} ->
        # Got a success, return immediately
        success

      {^ref, failure} ->
        # Got a failure, continue waiting
        wait_for_first(ref, remaining - 1, deadline, [failure | results])
    after
      remaining_ms ->
        # Timeout, return what we have
        results
    end
  end

  defp do_multicast_quorum(target_workers, fn_call, timeout, quorum_count) do
    worker_count = length(target_workers)

    # Validate that quorum is achievable
    if quorum_count > worker_count do
      Logger.warning(
        "Quorum count #{quorum_count} is greater than available workers #{worker_count}"
      )
    end

    # Ensure quorum_count is at least 1 and at most worker_count
    effective_quorum = max(1, min(quorum_count, worker_count))

    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    # Spawn tasks for each worker using Task.async
    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.async(fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    # Wait for quorum with validation
    result = wait_for_quorum(ref, worker_count, deadline, effective_quorum, [], [])

    # Shutdown remaining tasks gracefully
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    # Flush stray messages from tasks that sent before being killed
    flush_ref(ref)

    result
  end

  defp wait_for_quorum(_ref, 0, _deadline, needed, successes, failures) do
    # All responses received - check if we actually got enough successes
    results = successes ++ failures

    if needed > 0 do
      Logger.warning("Quorum not reached: needed #{needed} more successes")
      {:error, :quorum_not_reached, results}
    else
      {:ok, results}
    end
  end

  defp wait_for_quorum(_ref, _remaining, _deadline, 0, successes, failures) do
    # Quorum reached with enough successes
    {:ok, successes ++ failures}
  end

  defp wait_for_quorum(ref, remaining, deadline, needed, successes, failures) do
    # Check if quorum is still achievable (remaining workers >= needed successes)
    if remaining < needed do
      # Not enough workers left to reach quorum, return early
      Logger.warning("Quorum unreachable: #{remaining} workers remaining but need #{needed}")
      {:error, :quorum_not_reached, successes ++ failures}
    else
      remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, {:ok, _, _} = success} ->
          wait_for_quorum(
            ref,
            remaining - 1,
            deadline,
            needed - 1,
            [success | successes],
            failures
          )

        {^ref, failure} ->
          wait_for_quorum(ref, remaining - 1, deadline, needed, successes, [failure | failures])
      after
        remaining_ms ->
          # Timeout, return what we have with warning if quorum not reached
          results = successes ++ failures

          if needed > 0 do
            Logger.warning("Quorum timeout: still needed #{needed} more successes")
            {:error, :quorum_timeout, results}
          else
            {:ok, results}
          end
      end
    end
  end

  # Unwrap worker results to avoid double-wrapping.
  # Real defapi workers return {:ok, val} from __nbapi_local_* via __wrap_nebula_api_result.
  # Test doubles may return raw values — those fall through to {:ok, other}.
  defp unwrap_worker_result({:ok, val}), do: {:ok, val}
  defp unwrap_worker_result({:error, reason}), do: {:error, reason}
  defp unwrap_worker_result(other), do: {:ok, other}

  defp flush_ref(ref) do
    receive do
      {^ref, _} -> flush_ref(ref)
    after
      0 -> :ok
    end
  end

  defp pg_spec(),
    do: %{
      id: :pg_nebula_api,
      start: {:pg, :start_link, [:pg_nebula_api]}
    }
end
