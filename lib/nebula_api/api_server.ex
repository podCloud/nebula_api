defmodule NebulaAPI.APIServer do
  @moduledoc """
  Supervisor that manages API workers and handles remote method calls.

  Supports:
  - Default unicast (first available worker)
  - Unicast with node selector
  - Multicast to multiple nodes

  ## Multicast strategies

  Every per-node response is a `{node, value}` pair, where `value` is the body's
  return value, verbatim. A node whose call failed at the transport level yields
  `{node, {:nebula_error, reason}}`.

  - `:all` - Wait for every targeted node (or the timeout). Returns one `{node, value}`
    per targeted node — nodes that did not answer in time are reported as
    `{node, {:nebula_error, :timeout}}`, never silently dropped.
  - `:first` - Return the first response that counts as a success (see the
    `:success`/`:failure` options) as a single `{node, value}`. If no response
    qualifies: `{:nebula_error, :no_success, results}` (never a bare list).
  - `:quorum` - Wait for N successes (`:quorum_count` or `:quorum_proportion`). Reached:
    the list of collected `{node, value}` responses. Not reached:
    `{:nebula_error, :quorum_not_reached, results}` or `{:nebula_error, :quorum_timeout, results}`.
    Impossible quorum (required > available workers): `{:nebula_error, :quorum_unreachable,
    %{workers: n, required: m}}` — returned before any call is made.

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
  - `:timeout` - Timeout in milliseconds. Default: the module's `default_timeout`,
    then `config :nebula_api, default_timeout:`, then 5000.
  - `:node_selector` - Function that takes the nodes_info map and returns node(s) to call
  - `:multicast` - If true, calls multiple nodes and returns a list of results
  - `:strategy` - Multicast strategy: `:all`, `:first`, `:quorum` (default: `:all`)
  - `:quorum_count` - Positive integer: number of successes needed for the `:quorum`
    strategy. Mutually exclusive with `:quorum_proportion`.
  - `:quorum_proportion` - Number in `(0.5, 1]`: fraction of targeted workers that must
    succeed — resolved as `ceil(p × workers)`. Mutually exclusive with `:quorum_count`.
    Default (when neither is given): `div(workers, 2) + 1`.
  - `:success` - (`:first`/`:quorum` only) predicate `fn value -> boolean` defining
    what counts as a business success. Default: any worker that replied counts
    (a `{:nebula_error, _}` never does). Mutually exclusive with `:failure`.
  - `:failure` - mirror of `:success`: `fn value -> boolean` returning true for
    values that must NOT count as successes. Mutually exclusive with `:success`.

  ## Returns
  - For unicast: the body's return value, verbatim. A library/transport failure
    (timeout, no worker available, worker crash) yields `{:nebula_error, reason}`.
  - For multicast: per-node `{node, value}` pairs — see "Multicast strategies"
    in the moduledoc for the exact shape per strategy.
  """
  def call_remote_method(module, fn_call, opts \\ []) do
    # Bad call opts are a programming error: validate them up front, OUTSIDE the
    # transport rescue below, so they crash loud instead of melting into
    # {:nebula_error, _} like genuine transport failures do.
    multicast = Keyword.get(opts, :multicast, false)
    strategy = Keyword.get(opts, :strategy, :all)
    validate_predicate_opts!(opts, multicast, strategy)
    validate_quorum_opts!(opts, multicast, strategy)

    timeout = resolve_timeout(module, opts)
    validate_timeout!(timeout)
    node_selector = Keyword.get(opts, :node_selector)

    Logger.debug("""
      Will do remote execution on #{inspect(module)}
      with fn_call : #{inspect(fn_call)}
      opts: #{inspect(opts)}
    """)

    try do
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

        {:nebula_error, err}
    end
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
      |> Enum.reject(&(&1 == :dropped))

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
  # any {:exit, reason} (timeout OR crash — e.g. a raise in
  # collect_node_health_data_local) means that node's info is unavailable this
  # round: mark it :dropped so build_nodes_info filters it out instead of raising.
  @doc false
  def normalize_stream_result({:ok, result}), do: result
  def normalize_stream_result({:exit, _reason}), do: :dropped

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
  Returns the latest cluster node-info snapshot — a pure ETS read.

  The snapshot is written exclusively by `NebulaAPI.APIServer.NodesInfoCache`
  on its background interval; readers NEVER build it themselves, so there is
  no fan-out on the read path, ever. Before the first refresh completes (boot
  window) this returns `%{}` — selectors still see every node with a
  registered worker through synthesized entries (`runtime: nil`, see
  `get_available_nodes_info/2`).
  """
  def get_nodes_info do
    case :ets.lookup(@nodes_cache_table, @nodes_info_cache_key) do
      [{_, %{data: data}}] -> data
      _ -> %{}
    end
  rescue
    # Table not created yet (APIServer not booted, bare test contexts).
    ArgumentError -> %{}
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

    %{
      short_name: short_name,
      long_name: node_name,
      host: host,
      tags: tags_for_node(node_name),
      connected: true,
      runtime: collect_runtime_info()
    }
  end

  # A node's tags from the static config, normalized to a list.
  defp tags_for_node(node_name) do
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

  pg is the source of truth for WHO serves the method; the snapshot only
  enriches HOW they're doing. A node whose worker just registered but is not
  in the background snapshot yet gets a synthesized entry (`runtime: nil`,
  `last_seen_at: nil` until the next refresh).
  """
  def get_available_nodes_info(module, fn_call) do
    workers = get_all_workers(module, fn_call)
    snapshot = get_nodes_info()

    worker_nodes =
      workers
      |> Enum.map(&node/1)
      |> Enum.uniq()

    Map.new(worker_nodes, fn node_name ->
      {node_name, Map.get(snapshot, node_name) || synthesize_node_info(node_name)}
    end)
  end

  # Timeout precedence: the call's timeout: option, then the module's
  # default_timeout (persisted by `use NebulaAPI`), then the global
  # config :nebula_api, default_timeout (5000 by default).
  @doc false
  def resolve_timeout(module, opts) do
    opts[:timeout] || module_default_timeout(module) || NebulaAPI.Config.default_timeout()
  end

  defp module_default_timeout(module) do
    module.__info__(:attributes)
    |> Keyword.get(:nebula_api, [])
    |> Keyword.get(:default_timeout)
  rescue
    # Bare atoms used as module names in tests (or unloaded modules) have no
    # __info__/1 — treat them as carrying no module-level default.
    _ -> nil
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
  #
  # This always runs inside a throwaway process (confined_call, the multicast
  # fan-out tasks) whose death marks the end of interest in the result — the
  # worker monitors it to purge queued entries (see Worker.handle_call/3).
  defp safe_call(worker, fn_call, timeout) do
    {:replied, GenServer.call(worker, {:nebula_call, fn_call}, timeout)}
  catch
    :exit, {:timeout, _} -> {:exit, :timeout}
    :exit, reason -> {:exit, reason}
  end

  # Confined unicast: the GenServer.call runs in a throwaway task, so that a late
  # reply {ref, reply} (left behind by a call that timed out) lands in the task's
  # mailbox — which dies — and never in the caller's. async_nolink (monitor only,
  # no link) so a trap_exit caller never receives an {:EXIT, _, :normal} either.
  # The task always returns quickly (safe_call has an internal timeout) and cannot
  # crash (safe_call catches every exit), so Task.await/:infinity is safe.
  #
  # The body's return value is passed through untouched; only a transport failure
  # turns into {:nebula_error, reason}.
  defp confined_call(worker, fn_call, timeout) do
    task =
      Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
        case safe_call(worker, fn_call, timeout) do
          {:replied, reply} -> reply
          {:exit, :timeout} -> {:nebula_error, :timeout}
          {:exit, reason} -> {:nebula_error, reason}
        end
      end)

    Task.await(task, :infinity)
  end

  # Node-tagged multicast call, built on safe_call/3. Returns {node, value} when the
  # worker replied (value passed through as-is), or {node, {:nebula_error, reason}}
  # on a transport failure.
  defp tagged_call(worker, fn_call, timeout, target_node) do
    case safe_call(worker, fn_call, timeout) do
      {:replied, reply} -> {target_node, reply}
      {:exit, :timeout} -> {target_node, {:nebula_error, :timeout}}
      {:exit, reason} -> {target_node, {:nebula_error, reason}}
    end
  end

  defp call_first_worker(module, fn_call, timeout) do
    case get_remote_method_worker(module, fn_call) do
      worker when is_pid(worker) ->
        confined_call(worker, fn_call, timeout)

      _ ->
        {:nebula_error, {:no_worker, fn_call}}
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
          {:nebula_error, {:no_worker_on_node, selected_node}}
        end

      {:error, reason} ->
        {:nebula_error, reason}
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
        {:nebula_error, reason}
    end
  end

  # pg is the source of truth for WHO serves the method; the snapshot only
  # enriches HOW they're doing. A node whose worker just registered must be
  # visible to selectors immediately, not after the next background refresh.
  defp filter_nodes_info_for_workers(workers_by_node) do
    snapshot = get_nodes_info()

    Map.new(Map.keys(workers_by_node), fn node_name ->
      {node_name, Map.get(snapshot, node_name) || synthesize_node_info(node_name)}
    end)
  end

  # Entry for a pg-registered node not (yet) in the snapshot: everything
  # derivable locally is filled in; only runtime/last_seen_at need the next
  # background refresh. Selectors must therefore treat info.runtime as nilable
  # (the documented examples already filter on it).
  defp synthesize_node_info(node_name) do
    node_str = to_string(node_name)

    {short_name, host} =
      case String.split(node_str, "@", parts: 2) do
        [s, h] -> {String.to_atom(s), h}
        _ -> {node_name, "unknown"}
      end

    %{
      short_name: short_name,
      long_name: node_name,
      host: host,
      tags: tags_for_node(node_name),
      connected: node_name in [node() | Node.list()],
      last_seen_at: nil,
      runtime: nil
    }
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

  defp do_multicast_call(target_workers, fn_call, timeout, :quorum, opts) do
    worker_count = length(target_workers)
    required = resolve_quorum_required(opts, worker_count)

    # Fail fast: an arithmetically impossible quorum makes zero calls — for a
    # write quorum, no partial non-quorate write is even attempted. No silent
    # clamping: asking for 3 confirmations and "reaching quorum" with 2 would
    # be a durability guarantee lowered behind the caller's back.
    if required > worker_count do
      {:nebula_error, :quorum_unreachable, %{workers: worker_count, required: required}}
    else
      do_multicast_quorum(target_workers, fn_call, timeout, required, opts)
    end
  end

  # :first never returns a bare list: with nobody to ask there is no success.
  defp do_multicast_call([], _fn_call, _timeout, :first, _opts) do
    {:nebula_error, :no_success, []}
  end

  defp do_multicast_call([], _fn_call, _timeout, _strategy, _opts) do
    []
  end

  defp do_multicast_call(target_workers, fn_call, timeout, strategy, opts) do
    case strategy do
      :first -> do_multicast_first(target_workers, fn_call, timeout, opts)
      _all -> do_multicast_all(target_workers, fn_call, timeout)
    end
  end

  # quorum_count > quorum_proportion > majority of the targeted workers.
  defp resolve_quorum_required(opts, worker_count) do
    cond do
      count = Keyword.get(opts, :quorum_count) -> count
      p = Keyword.get(opts, :quorum_proportion) -> max(1, ceil(p * worker_count))
      true -> div(worker_count, 2) + 1
    end
  end

  # Validating the RESOLVED value covers both the per-call timeout: option and
  # the global config :nebula_api, default_timeout: (the module-level default is
  # already validated at compile time by `use NebulaAPI`). :infinity is rejected
  # on purpose, unicast included: distribution monitors catch dead workers and
  # partitions, but a live worker whose body never finishes would hang the
  # caller forever (confined_call awaits with :infinity) — an unbounded wait has
  # no place in a transport whose whole 0.4.0 contract is "the caller never
  # crashes, never hangs".
  defp validate_timeout!(timeout) do
    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError,
            "timeout: must be a positive integer in milliseconds, got: #{inspect(timeout)}" <>
              if(timeout == :infinity,
                do: " — :infinity is not supported; use a large finite budget instead",
                else: ""
              )
    end
  end

  # Bad call opts are a programming error: validate them up front, OUTSIDE the
  # transport rescue in call_remote_method/3, so they crash loud instead of melting
  # into {:nebula_error, _} like genuine transport failures do.
  defp validate_quorum_opts!(opts, multicast, strategy) do
    count = Keyword.get(opts, :quorum_count)
    proportion = Keyword.get(opts, :quorum_proportion)

    if (count || proportion) && not (multicast and strategy == :quorum) do
      raise ArgumentError,
            "quorum_count:/quorum_proportion: only apply to the :quorum strategy"
    end

    case {count, proportion} do
      {nil, nil} ->
        :ok

      {count, nil} when is_integer(count) and count > 0 ->
        :ok

      {nil, p} when is_number(p) and p > 0.5 and p <= 1 ->
        :ok

      {nil, bad_p} ->
        raise ArgumentError,
              "quorum_proportion: must be a number in (0.5, 1] — a quorum is majoritarian " <>
                "by definition — got: #{inspect(bad_p)}"

      {bad_count, nil} ->
        raise ArgumentError,
              "quorum_count: must be a positive integer, got: #{inspect(bad_count)}"

      {_count, _proportion} ->
        raise ArgumentError,
              "quorum_count: and quorum_proportion: are mutually exclusive — " <>
                "pass one or the other, not both"
    end
  end

  defp validate_predicate_opts!(opts, multicast, strategy) do
    has_predicate? =
      Keyword.has_key?(opts, :success) or Keyword.has_key?(opts, :failure)

    if has_predicate? and not (multicast and strategy in [:first, :quorum]) do
      raise ArgumentError,
            "success:/failure: only apply to multicast strategies :first and :quorum " <>
              "(got multicast: #{inspect(multicast)}, strategy: #{inspect(strategy)}) — " <>
              "they would be silently ignored here"
    end

    case {Keyword.get(opts, :success), Keyword.get(opts, :failure)} do
      {nil, nil} ->
        :ok

      {success, nil} when is_function(success, 1) ->
        :ok

      {nil, failure} when is_function(failure, 1) ->
        :ok

      {nil, bad} ->
        raise ArgumentError, "failure: must be a 1-arity function, got: #{inspect(bad)}"

      {bad, nil} ->
        raise ArgumentError, "success: must be a 1-arity function, got: #{inspect(bad)}"

      {_success, _failure} ->
        raise ArgumentError,
              "success: and failure: are mutually exclusive — pass one or the other, not both"
    end
  end

  # Success predicate for :first/:quorum, derived from the call opts (validated up
  # front by validate_predicate_opts!/3). By default any worker that replied (no
  # transport error) is a success. `success: fn value -> bool` narrows that to a
  # business success; `failure:` is its mirror.
  defp success_predicate(opts) do
    cond do
      f = Keyword.get(opts, :success) -> f
      f = Keyword.get(opts, :failure) -> fn value -> not f.(value) end
      true -> fn _value -> true end
    end
  end

  # A multicast response is {node, value} (replied) or {node, {:nebula_error, reason}}
  # (transport failed). A transport failure is never a success; otherwise the
  # predicate decides.
  defp response_success?({_node, {:nebula_error, _reason}}, _predicate), do: false
  defp response_success?({_node, value}, predicate), do: predicate.(value)

  defp do_multicast_all(target_workers, fn_call, timeout) do
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    received = wait_for_all(ref, length(target_workers), deadline, [])

    Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)
    flush_ref(ref)

    # Guarantee one entry per targeted node: nodes that did not answer before the
    # deadline are reported as {node, {:nebula_error, :timeout}} instead of being
    # silently dropped (one result per node, without exiting the caller on timeout).
    answered = MapSet.new(received, &result_node/1)

    timeouts =
      for {target_node, _worker} <- target_workers,
          not MapSet.member?(answered, target_node),
          do: {target_node, {:nebula_error, :timeout}}

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

  defp result_node({target_node, _value}), do: target_node

  defp do_multicast_first(target_workers, fn_call, timeout, opts) do
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    predicate = success_predicate(opts)

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    # Return the first response that counts as a success (replied + predicate).
    # try/after: the user predicate runs inside wait_for_first — if it raises,
    # the tasks must still be killed and the {ref, _} replies flushed, or the
    # stray messages would pollute the caller's mailbox forever.
    try do
      wait_for_first(ref, length(target_workers), deadline, predicate, [])
    after
      Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)
      flush_ref(ref)
    end
  end

  defp wait_for_first(_ref, 0, _deadline, _predicate, results) do
    # No success among the responses: lib-level failure, on the lib channel.
    {:nebula_error, :no_success, Enum.reverse(results)}
  end

  defp wait_for_first(ref, remaining, deadline, predicate, results) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, response} ->
        if response_success?(response, predicate) do
          response
        else
          wait_for_first(ref, remaining - 1, deadline, predicate, [response | results])
        end
    after
      remaining_ms ->
        {:nebula_error, :no_success, Enum.reverse(results)}
    end
  end

  defp do_multicast_quorum(target_workers, fn_call, timeout, required, opts) do
    worker_count = length(target_workers)
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    predicate = success_predicate(opts)

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 100)
          send(parent, {ref, tagged_call(worker, fn_call, remaining, target_node)})
        end)
      end)

    # Same try/after rationale as do_multicast_first.
    try do
      wait_for_quorum(ref, worker_count, deadline, required, predicate, [], [])
    after
      Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)
      flush_ref(ref)
    end
  end

  # Quorum reached → the list of {node, value} responses.
  # Quorum not reached → {:nebula_error, :quorum_not_reached | :quorum_timeout, results}.
  defp wait_for_quorum(_ref, 0, _deadline, needed, _predicate, successes, failures) do
    results = Enum.reverse(successes) ++ Enum.reverse(failures)

    if needed > 0 do
      Logger.warning("Quorum not reached: needed #{needed} more successes")
      {:nebula_error, :quorum_not_reached, results}
    else
      results
    end
  end

  defp wait_for_quorum(_ref, _remaining, _deadline, 0, _predicate, successes, failures) do
    Enum.reverse(successes) ++ Enum.reverse(failures)
  end

  defp wait_for_quorum(ref, remaining, deadline, needed, predicate, successes, failures) do
    # Check if quorum is still achievable (remaining workers >= needed successes)
    if remaining < needed do
      Logger.warning("Quorum unreachable: #{remaining} workers remaining but need #{needed}")

      {:nebula_error, :quorum_not_reached, Enum.reverse(successes) ++ Enum.reverse(failures)}
    else
      remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, response} ->
          if response_success?(response, predicate) do
            wait_for_quorum(
              ref,
              remaining - 1,
              deadline,
              needed - 1,
              predicate,
              [response | successes],
              failures
            )
          else
            wait_for_quorum(
              ref,
              remaining - 1,
              deadline,
              needed,
              predicate,
              successes,
              [response | failures]
            )
          end
      after
        remaining_ms ->
          results = Enum.reverse(successes) ++ Enum.reverse(failures)

          if needed > 0 do
            Logger.warning("Quorum timeout: still needed #{needed} more successes")
            {:nebula_error, :quorum_timeout, results}
          else
            results
          end
      end
    end
  end

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
