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
  - `:quorum` - Wait for N successes. N is `at_least:` when given, otherwise a strict majority
    of the quorum set chosen by `quorum:`: `:configured` (the default) = the configured nodes
    serving the method that match the selector (connected or not); `:available` = the connected
    workers. Reached: the list of collected `{node, value}` responses. Not reached:
    `{:nebula_error, :quorum_not_reached, results}` or `{:nebula_error, :quorum_timeout, results}`.
    Impossible quorum (required > available workers — including a `:configured` majority no live
    set can reach): `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` — returned
    before any call is made.

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

  # All {{fn_name, arity}, configured_nodes} a module persisted via defapi — the single
  # compile-time source that registered_local/remote_methods and configured_nodes/2 read.
  defp configured_methods(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:nebula_configured_nodes)
    |> List.flatten()
  end

  # The node this module was COMPILED as (the `use NebulaAPI` self_node), baked into the
  # :nebula_api opts. local/remote is a compile-time fact, so it is derived against this —
  # not runtime node() (which only equals it on a correctly-booted serving node).
  #
  # This makes "local" == self_node ∈ configured, matching defapi's own is_current_node — with
  # one escape-hatch edge: a NO-selector defapi compiled with `allow_unknown_self_node: true`
  # and a self_node absent from the topology generates a local body but derives as remote here
  # (it isn't in the configured set). That combo is for throwaway compiles off a node that's
  # not part of the cluster, not for a real serving node, so the divergence is harmless.
  defp compiled_self_node(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:nebula_api)
    |> List.flatten()
    |> Keyword.get(:self_node)
  end

  @doc """
  The `{fn_name, arity}` methods served REMOTELY from this build — derived from the configured
  set (the compiled `self_node` is NOT in a method's configured nodes).
  """
  def registered_remote_methods(module) do
    self_node = compiled_self_node(module)

    module
    |> configured_methods()
    |> Enum.reject(fn {_method, nodes} -> self_node in nodes end)
    |> Enum.map(fn {method, _nodes} -> method end)
  end

  @doc """
  The `{fn_name, arity}` methods whose body is LOCAL on this build — derived from the configured
  set (the compiled `self_node` is in a method's configured nodes). This is what
  `nebula_api_server()` starts a worker for.
  """
  def registered_local_methods(module) do
    self_node = compiled_self_node(module)

    module
    |> configured_methods()
    |> Enum.filter(fn {_method, nodes} -> self_node in nodes end)
    |> Enum.map(fn {method, _nodes} -> method end)
  end

  @doc """
  The CONFIGURED nodes that serve `module`'s `{fn_name, arity}` — the method's selector
  resolved over the topology at compile time (connected or not), `[]` for an unknown method.

  Compile-time and config-derived, so identical on every node: the value is read from the
  module's persisted metadata, which the stub carries on every build. Use it to introspect
  routing without reaching into `:pg`. See also `available_nodes/2`.
  """
  def configured_nodes(module, {fn_name, arity}) do
    module
    |> configured_methods()
    |> Enum.find_value([], fn
      {{^fn_name, ^arity}, nodes} -> nodes
      _ -> nil
    end)
  end

  @doc """
  The nodes that currently have a live worker for `module`'s `{fn_name, arity}` — the runtime
  serving set, read from `:pg`. `[]` when nobody serves it. On correctly-booted nodes (each
  running as the node it was compiled for) this is a subset of `configured_nodes/2` — the
  connected ones whose app wired `nebula_api_server()`.
  """
  def available_nodes(module, {fn_name, arity}) do
    :pg.get_members(:pg_nebula_api, {module, {fn_name, arity}})
    |> Enum.map(&node/1)
    |> Enum.uniq()
  end

  @doc false
  # Escape hatch (env var `ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1`): lets a release boot under
  # a node name that doesn't match the one it was compiled for, as a generic node that serves
  # nothing (no workers) and routes every call remotely. Without it, a node mismatch — or
  # running as `nonode@nohost` — is a hard boot error. See NebulaAPI.Server.server_mode/3.
  def runtime_mismatch_allowed? do
    System.get_env("ALLOW_RUNTIME_NEBULA_NODE_MISMATCH") == "1"
  end

  @generic_mode_key {NebulaAPI, :generic_mode}

  @doc false
  # Set once at boot by NebulaAPI.Server: true when this node is in generic mode (serves
  # nothing). The generated routers read it to force every call remote.
  def set_generic_mode(bool) when is_boolean(bool) do
    :persistent_term.put(@generic_mode_key, bool)
  end

  @doc false
  # Consulted by every locally-resolved defapi call: a generic node (or any node running as
  # nonode@nohost) routes the call remotely instead of running the local body.
  def force_remote? do
    node() == :nonode@nohost or :persistent_term.get(@generic_mode_key, false)
  end

  def register_local_method_worker(module, method, worker_pid) do
    Logger.debug("[#{node()}] registering local method #{inspect({module, method, worker_pid})}")
    :ok = :pg.join(:pg_nebula_api, {module, method}, worker_pid)
  end

  @doc """
  Calls a remote method with optional routing options.

  ## Options

  For every option, `nil` means "not set": the call behaves as if the option
  were absent (a computed `strategy: maybe_strategy` holding `nil` resolves to
  the default). Any other malformed value raises `ArgumentError` up front, and
  so does any unknown option key — the option set below is closed, a typo'd
  key must not be silently dropped.
  - `:timeout` - Timeout in milliseconds. Default: the module's `default_timeout`,
    then `config :nebula_api, default_timeout:`, then 5000. `nil` means "not set"
    (the default resolution applies); any other non-integer raises.
  - `:node_selector` - 1-arity function that takes the nodes_info map and returns
    node(s) to call. Anything else (besides `nil`, "not set") raises `ArgumentError`
    up front, like every other malformed call opt.
  - `:multicast` - If true, calls multiple nodes and returns a list of results
  - `:strategy` - Multicast strategy: `:all`, `:first`, `:quorum` (default: `:all`)
  - `:quorum` - (`:quorum` strategy only) which set the default majority is taken over:
    `:configured` (the default) = the configured nodes serving the method that match the
    selector, `div(set, 2) + 1`, connected or not; `:available` = the connected workers,
    `div(present, 2) + 1`. A function selector has no static configured set, so with
    `strategy: :quorum` it must declare `quorum: :available` or `at_least:` — the
    `:configured` default is a compile error there, never silently downgraded. Mutually
    exclusive with `:at_least`.
  - `:at_least` - Positive integer: an exact number of successes required by the `:quorum`
    strategy, overriding the `quorum:` majority. Mutually exclusive with `:quorum`.
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
    {timeout, max_extensions} = validate_call_opts!(module, opts)
    # Call-scoped context (same convention as :nebula_call / :nebula_node_selector):
    # the deep unicast/multicast dispatch reads it back here, in this process, to
    # thread into the transport — it never has to cross a spawn boundary.
    Process.put(:nebula_api_max_extensions, max_extensions)
    multicast = Keyword.get(opts, :multicast, false)
    strategy = Keyword.get(opts, :strategy) || :all
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
    catch
      # User code on the routing path (a success:/failure: predicate runs in
      # the calling process) may throw or exit, not just raise — all three
      # escape kinds land on the :nebula_error channel, the same shapes a
      # body produces, instead of crashing the caller with a nocatch.
      kind, reason ->
        Logger.error("""
        Remote method call failed:
          module: #{inspect(module)}
          fn_call: #{inspect(fn_call)}
          opts: #{inspect(opts)}
          #{inspect(kind)}: #{inspect(reason)}
        """)

        {:nebula_error, {kind, reason}}
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

  # Node health is collected via direct RPC to collect_node_health_data_local/0, never
  # through a defapi endpoint: routing one would recurse
  # (build_nodes_info -> call_on_all_nodes -> call_remote_method -> build_nodes_info).
  # For a public node-health endpoint, call collect_node_health_data_local/0 over RPC from
  # a module that does not depend on build_nodes_info.

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

    workers
    |> Enum.map(&node/1)
    |> Enum.uniq()
    |> nodes_info_for()
  end

  # Validates every call opt up front and returns the resolved timeout. Bad
  # call opts are a programming error: this runs OUTSIDE the transport rescue
  # of call_remote_method/3, so they crash loud instead of melting into
  # {:nebula_error, _} like genuine transport failures do. The generated
  # routers also call this on LOCALLY-resolved calls carrying routing opts:
  # the opts are validated everywhere, consumed only where the call actually
  # goes remote — invalid opts raise identically on every node.
  # Every opt follows the same nil convention as timeout:/node_selector: —
  # nil means "not set", so a computed `strategy: maybe_strategy` holding nil
  # resolves to the default instead of raising or half-applying.
  @doc false
  def validate_call_opts!(module, opts) do
    validate_known_opts!(opts)
    multicast = Keyword.get(opts, :multicast) || false
    strategy = Keyword.get(opts, :strategy) || :all
    validate_strategy_opts!(opts, multicast)
    validate_predicate_opts!(opts, multicast, strategy)
    validate_quorum_opts!(opts, multicast, strategy)
    validate_quorum_mode_opts!(opts, multicast, strategy)
    validate_configured_set!(opts, multicast, strategy)
    validate_selector_opt!(opts)

    timeout = resolve_timeout(module, opts)
    validate_timeout!(timeout)

    max_extensions = resolve_max_time_extensions(module, opts)
    validate_max_time_extensions!(max_extensions)

    {timeout, max_extensions}
  end

  @valid_call_opts [
    :timeout,
    :max_time_extensions,
    :node_selector,
    :multicast,
    :strategy,
    :at_least,
    :success,
    :failure,
    :quorum
  ]

  # The set of call opts is closed, so an unknown KEY is as much a programming
  # error as a malformed value: a typo'd key (timout:) or a stale one
  # (quorum_count:, removed in 0.4.0) would otherwise be silently dropped and
  # the call would run with defaults the caller never chose — for a quorum,
  # that's a durability requirement quietly replaced by the majority default.
  defp validate_known_opts!(opts) do
    user_keys =
      opts |> Keyword.keys() |> Enum.reject(&internal_opt?/1) |> Enum.uniq()

    case user_keys -- @valid_call_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown call option(s): #{inspect(unknown)} — " <>
                "valid options are #{inspect(@valid_call_opts)}"
    end
  end

  # Opts injected by generated code (e.g. __method_configured_nodes:, the method's
  # configured serving set baked into its remote stub for the :configured quorum).
  # Never typed by users, so they bypass the closed-set check on user keys.
  defp internal_opt?(key), do: key |> Atom.to_string() |> String.starts_with?("__")

  @valid_quorum_modes [:configured, :available]

  # The quorum: mode picks the quorum's denominator (see do_multicast_call/6):
  # :configured (default) = majority of the configured nodes serving the method
  # that match the selector; :available = majority of the connected workers.
  # nil means "not set" (the default applies), same convention as every other opt.
  defp validate_quorum_mode_opts!(opts, multicast, strategy) do
    case Keyword.get(opts, :quorum) do
      nil ->
        :ok

      mode when mode not in @valid_quorum_modes ->
        raise ArgumentError,
              "quorum: must be one of #{inspect(@valid_quorum_modes)}, got: #{inspect(mode)}"

      _mode ->
        unless multicast and strategy == :quorum do
          raise ArgumentError,
                "quorum: only applies to the :quorum strategy " <>
                  "(multicast: true, strategy: :quorum) — it would be ignored here"
        end

        if Keyword.get(opts, :at_least) != nil do
          raise ArgumentError,
                "at_least: and quorum: are mutually exclusive — at_least: asks for a " <>
                  "precise count, quorum: for a majority of a set"
        end

        :ok
    end
  end

  # quorum: :configured (the default, when neither at_least: nor quorum: :available is
  # given) needs the method's configured serving set. The generated remote stub injects
  # it on every call, so a real defapi call always carries it; reaching this without it
  # means a hand-rolled call_remote_method/3 — refuse loud, up front, instead of silently
  # falling back to the present workers and weakening the quorum behind the caller's back.
  defp validate_configured_set!(opts, multicast, strategy) do
    needs_configured_set? =
      multicast and strategy == :quorum and
        Keyword.get(opts, :at_least) == nil and
        (Keyword.get(opts, :quorum) || :configured) == :configured

    if needs_configured_set? and Keyword.get(opts, :__method_configured_nodes) == nil do
      raise ArgumentError,
            "quorum: :configured needs the method's configured node set — normally injected " <>
              "by the generated stub. Call the defapi function (or wrap it in call_on_*), not " <>
              "APIServer.call_remote_method/3 directly; or pass quorum: :available / at_least:."
    end

    :ok
  end

  # Like every other call opt, the selector's FORM is a programming error when
  # wrong: only a 1-arity function can ever be applied to the nodes_info map,
  # so anything else raises up front instead of melting into
  # {:nebula_error, {:selector_failed, {:badfun, _}}} at selection time. What
  # the function DOES remains a runtime concern — its bugs are contained by
  # safe_call_selector/2. nil means "not set", same convention as timeout: nil.
  defp validate_selector_opt!(opts) do
    case Keyword.get(opts, :node_selector) do
      nil ->
        :ok

      selector when is_function(selector, 1) ->
        :ok

      bad ->
        raise ArgumentError,
              "node_selector: must be a 1-arity function taking the nodes_info map, " <>
                "got: #{inspect(bad)}"
    end
  end

  # Timeout precedence: the call's timeout: option, then the module's
  # default_timeout (the __nebula_api__/1 accessor generated by
  # `use NebulaAPI` — a function head on a literal, no attribute scan on this
  # hot path), then the global config :nebula_api, default_timeout (5000 by
  # default).
  #
  # nil means "not set" — a computed `timeout: maybe_timeout` holding nil
  # falls back to the defaults, exactly as if the option were absent. Any
  # other non-integer (false included) flows into validate_timeout! and
  # raises: only nil is the documented "inherit" value.
  @doc false
  def resolve_timeout(module, opts) do
    case Keyword.get(opts, :timeout) do
      nil -> module_default_timeout(module) || NebulaAPI.Config.default_timeout()
      timeout -> timeout
    end
  end

  defp module_default_timeout(module) do
    module.__nebula_api__(:default_timeout)
  rescue
    # Modules without `use NebulaAPI` (bare atoms used as module names in
    # tests, plain GenServer doubles) have no __nebula_api__/1 — treat them
    # as carrying no module-level default.
    _ -> nil
  end

  # Same precedence as resolve_timeout/2: per-call opt > per-module accessor >
  # global config > lib default (10). nil means "not set". 0 is a real value
  # (no extensions) and, being truthy in Elixir, is NOT swallowed by the `||`.
  @doc false
  def resolve_max_time_extensions(module, opts) do
    case Keyword.get(opts, :max_time_extensions) do
      nil -> module_max_time_extensions(module) || NebulaAPI.Config.max_time_extensions()
      n -> n
    end
  end

  defp module_max_time_extensions(module) do
    module.__nebula_api__(:max_time_extensions)
  rescue
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

  # The transport. A hand-rolled send + receive loop instead of GenServer.call:
  # the caller owns its receive, which (1) lets the worker monitor it and kill
  # the running body when it dies, and (2) accepts `:request_more_time`
  # heartbeats that reset the deadline — GenServer.call's internal receive is
  # closed, you cannot add either. Return contract is unchanged so
  # confined_call/tagged_call keep working:
  #   `{:replied, term}` = the worker replied (term may be a business-level error).
  #   `{:exit, :timeout}` / `{:exit, reason}` = gave up without a reply.
  #
  # This always runs inside a throwaway process (confined_call, the multicast
  # fan-out tasks) whose death marks the end of interest in the result — the
  # worker monitors it and, on death, KILLS the running body (see
  # Worker.handle_info/2). We monitor the worker too, to fast-fail if the node or
  # the worker dies instead of waiting out the whole timeout.
  defp safe_call(worker, fn_call, timeout, max_extensions) do
    ref = make_ref()
    wmon = Process.monitor(worker)
    send(worker, {:nebula_call, {self(), ref}, fn_call})
    result = await_reply(ref, wmon, timeout, max_extensions)
    Process.demonitor(wmon, [:flush])
    result
  end

  # `extensions_left` bounds how many heartbeats reset the deadline. When it hits
  # 0 the heartbeat clause's guard fails, so a further `:request_more_time` matches
  # NO clause: it stays in the mailbox WITHOUT waking the receive, and — crucial —
  # a non-matching message does NOT restart the `after` timer. So the last window
  # runs out and the body is timed out (then killed). Total ≤ (max+1) × timeout,
  # no clocks. A body cannot heartbeat its way past the limit.
  defp await_reply(ref, wmon, timeout, extensions_left) do
    receive do
      {^ref, {:reply, result}} ->
        {:replied, result}

      {^ref, :request_more_time} when extensions_left > 0 ->
        await_reply(ref, wmon, timeout, extensions_left - 1)

      {:DOWN, ^wmon, :process, _pid, reason} ->
        {:exit, reason}
    after
      timeout -> {:exit, :timeout}
    end
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
    # Read here, in the caller process (which holds the call-scoped context), and
    # close over it: the throwaway task doesn't inherit the process dictionary.
    max_extensions = current_max_extensions()

    task =
      Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
        case safe_call(worker, fn_call, timeout, max_extensions) do
          {:replied, reply} -> reply
          {:exit, :timeout} -> {:nebula_error, :timeout}
          {:exit, reason} -> {:nebula_error, reason}
        end
      end)

    Task.await(task, :infinity)
  end

  # The call's resolved extension budget, stashed by call_remote_method. The
  # fallback keeps a direct/edge caller (no context set) bounded by the global
  # default rather than treated as unlimited. 0 is truthy in Elixir, so an
  # explicit "no extensions" survives the `||`.
  defp current_max_extensions do
    Process.get(:nebula_api_max_extensions) || NebulaAPI.Config.max_time_extensions()
  end

  # Node-tagged multicast call, built on safe_call/3. Returns {node, value} when the
  # worker replied (value passed through as-is), or {node, {:nebula_error, reason}}
  # on a transport failure.
  defp tagged_call(worker, fn_call, timeout, target_node, max_extensions) do
    case safe_call(worker, fn_call, timeout, max_extensions) do
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

        # Filter to only nodes with workers. A selector may return duplicates:
        # a node must count ONCE — toward the quorum especially, where two
        # replies from the same node are one confirmation, not two.
        selected_nodes = Enum.uniq(selected_nodes)

        target_workers =
          selected_nodes
          |> Enum.filter(&Map.has_key?(workers_by_node, &1))
          |> Enum.map(fn node -> {node, workers_by_node[node]} end)

        configured_denom = configured_denominator(opts, selected_nodes)
        do_multicast_call(target_workers, fn_call, timeout, strategy, configured_denom, opts)

      {:error, reason} ->
        {:nebula_error, reason}
    end
  end

  defp filter_nodes_info_for_workers(workers_by_node) do
    nodes_info_for(Map.keys(workers_by_node))
  end

  # One entry per worker node: the background snapshot's entry when present,
  # a synthesized one otherwise. pg is the source of truth for WHO serves a
  # method; the snapshot only enriches HOW they're doing — a node whose worker
  # just registered must be visible to selectors immediately, not after the
  # next background refresh (see get_available_nodes_info/2 and
  # filter_nodes_info_for_workers/1, which both delegate here).
  defp nodes_info_for(worker_nodes) do
    snapshot = get_nodes_info()

    Map.new(worker_nodes, fn node_name ->
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

    configured_denom = configured_denominator(opts, nil)
    do_multicast_call(target_workers, fn_call, timeout, strategy, configured_denom, opts)
  end

  defp do_multicast_call(target_workers, fn_call, timeout, :quorum, configured_denom, opts) do
    present = length(target_workers)
    required = resolve_quorum_required(opts, present, configured_denom)

    # Fail fast: an arithmetically impossible quorum makes zero calls — for a
    # write quorum, no partial non-quorate write is even attempted. No silent
    # clamping: asking for 3 confirmations and "reaching quorum" with 2 would
    # be a durability guarantee lowered behind the caller's back. With
    # quorum: :configured this is also what refuses a single live node when the
    # configured set needs a majority it cannot reach.
    if required > present do
      {:nebula_error, :quorum_unreachable, %{workers: present, required: required}}
    else
      do_multicast_quorum(target_workers, fn_call, timeout, required, opts)
    end
  end

  # :first never returns a bare list: with nobody to ask there is no success.
  defp do_multicast_call([], _fn_call, _timeout, :first, _denom, _opts) do
    {:nebula_error, :no_success, []}
  end

  defp do_multicast_call([], _fn_call, _timeout, _strategy, _denom, _opts) do
    []
  end

  defp do_multicast_call(target_workers, fn_call, timeout, strategy, _denom, opts) do
    case strategy do
      :first -> do_multicast_first(target_workers, fn_call, timeout, opts)
      _all -> do_multicast_all(target_workers, fn_call, timeout)
    end
  end

  # The quorum requirement. An explicit at_least: wins (a precise count). Otherwise
  # a strict majority of the ADDRESSED set, chosen by quorum::
  #   :available             -> the connected workers (present),
  #   :configured (default)  -> the configured nodes serving the method that match
  #                             the selector (configured_denom).
  # For :configured, configured_denom is guaranteed non-nil here: validate_configured_set!
  # refuses the call up front (loud) when the set is missing, rather than silently
  # falling back to the present workers and weakening the quorum.
  defp resolve_quorum_required(opts, present, configured_denom) do
    case Keyword.get(opts, :at_least) do
      n when is_integer(n) ->
        n

      _ ->
        denom =
          case Keyword.get(opts, :quorum) || :configured do
            :available -> present
            :configured -> configured_denom
          end

        div(denom, 2) + 1
    end
  end

  # The size of the configured set the call addresses, for quorum: :configured.
  # __method_configured_nodes is the method's configured serving set, injected by
  # its generated remote stub. With a selector we intersect (nodes that serve the
  # method AND match the selector); without one it is the whole serving set. nil
  # when the stub didn't inject it (direct calls / test doubles).
  defp configured_denominator(opts, selected_nodes) do
    case Keyword.get(opts, :__method_configured_nodes) do
      nil ->
        nil

      configured ->
        configured = MapSet.new(configured)

        case selected_nodes do
          nil -> MapSet.size(configured)
          list -> MapSet.intersection(MapSet.new(list), configured) |> MapSet.size()
        end
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

  # Non-negative integer: 0 = no extensions allowed. :infinity is rejected on
  # purpose — an unbounded number of heartbeats would let a body defeat its own
  # timeout forever, exactly the hang the timeout exists to prevent.
  defp validate_max_time_extensions!(max_extensions) do
    unless is_integer(max_extensions) and max_extensions >= 0 do
      raise ArgumentError,
            "max_time_extensions: must be a non-negative integer, got: " <>
              inspect(max_extensions) <>
              if(max_extensions == :infinity,
                do: " — :infinity is not supported; a call must stay bounded",
                else: ""
              )
    end
  end

  @valid_strategies [:all, :first, :quorum]

  # Same up-front philosophy as the other call opts: a typo'd strategy must not
  # silently fall into the :all catch-all — a :quorum write degrading into a
  # plain broadcast is a durability guarantee lost behind the caller's back
  # (and both return lists, so the caller would never notice).
  defp validate_strategy_opts!(opts, multicast) do
    case Keyword.fetch(opts, :strategy) do
      :error ->
        :ok

      # nil means "not set" (the :all default applies) — same convention as
      # every other call opt.
      {:ok, nil} ->
        :ok

      {:ok, strategy} when strategy not in @valid_strategies ->
        raise ArgumentError,
              "strategy: must be one of #{inspect(@valid_strategies)}, " <>
                "got: #{inspect(strategy)}"

      {:ok, strategy} ->
        unless multicast do
          raise ArgumentError,
                "strategy: #{inspect(strategy)} only applies to multicast calls " <>
                  "(multicast: true) — it would be silently ignored here"
        end

        :ok
    end
  end

  # Bad call opts are a programming error: validate them up front, OUTSIDE the
  # transport rescue in call_remote_method/3, so they crash loud instead of melting
  # into {:nebula_error, _} like genuine transport failures do.
  defp validate_quorum_opts!(opts, multicast, strategy) do
    at_least = Keyword.get(opts, :at_least)

    if at_least && not (multicast and strategy == :quorum) do
      raise ArgumentError, "at_least: only applies to the :quorum strategy"
    end

    case at_least do
      nil ->
        :ok

      n when is_integer(n) and n > 0 ->
        :ok

      bad ->
        raise ArgumentError,
              "at_least: must be a positive integer (a number of workers), " <>
                "got: #{inspect(bad)} — without it, the default is a strict majority " <>
                "of the targeted workers"
    end
  end

  defp validate_predicate_opts!(opts, multicast, strategy) do
    # A nil predicate is "not set" everywhere: it neither counts as present
    # for the applicability check below, nor reaches the form validation.
    has_predicate? =
      Keyword.get(opts, :success) != nil or Keyword.get(opts, :failure) != nil

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
      # Kernel.! (not `not`): success: predicates are consumed by `if`, which
      # accepts any truthy/falsy value — the mirror must accept the same range,
      # not crash on a non-boolean truthy return only when spelled failure:.
      f = Keyword.get(opts, :failure) -> fn value -> !f.(value) end
      true -> fn _value -> true end
    end
  end

  # A multicast response is {node, value} (replied) or {node, {:nebula_error, reason}}
  # (transport failed). A transport failure is never a success; otherwise the
  # predicate decides.
  defp response_success?({_node, {:nebula_error, _reason}}, _predicate), do: false
  defp response_success?({_node, value}, predicate), do: predicate.(value)

  # One fan-out call, bounded by what remains of the caller's timeout when the
  # task actually starts. If the deadline is already gone, don't call at all:
  # the collector (wait_for_*) stops at the deadline, so a reply earned during
  # any grace window could only be flushed — calling would just make the worker
  # run a body nobody collects. Report the node as a timeout directly.
  defp tagged_call_within(worker, fn_call, deadline, target_node, max_extensions) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      tagged_call(worker, fn_call, remaining, target_node, max_extensions)
    else
      {target_node, {:nebula_error, :timeout}}
    end
  end

  defp do_multicast_all(target_workers, fn_call, timeout) do
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    max_extensions = current_max_extensions()

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          send(
            parent,
            {ref, tagged_call_within(worker, fn_call, deadline, target_node, max_extensions)}
          )
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
    max_extensions = current_max_extensions()
    predicate = success_predicate(opts)

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          send(
            parent,
            {ref, tagged_call_within(worker, fn_call, deadline, target_node, max_extensions)}
          )
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
    max_extensions = current_max_extensions()
    predicate = success_predicate(opts)

    tasks =
      target_workers
      |> Enum.map(fn {target_node, worker} ->
        Task.Supervisor.async_nolink(NebulaAPI.TaskSupervisor, fn ->
          send(
            parent,
            {ref, tagged_call_within(worker, fn_call, deadline, target_node, max_extensions)}
          )
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
