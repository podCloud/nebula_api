defmodule NebulaAPI.Routes do
  @moduledoc """
  The per-node routing map — where each `defapi` runs (local) vs forwards over RPC (remote).

  Built entirely from compile-time data (`:nebula_configured_nodes`, the single source of truth
  also behind `NebulaAPI.APIServer.configured_nodes/2`): a method is *local* on the nodes in its
  configured serving set, *remote* everywhere else. Nothing is recomputed; no cluster needed.

  Rendered "git lola"-style — one vertical rail per node, then a `●`/`-` row per method —
  by `mix nebula.routes` and `NebulaAPI.Server.print_routes/0`.

  ## Scope

  It lists only the `defapi` modules **compiled into this build/release**. A node whose release
  includes a subset of an umbrella's apps (for smaller binaries) does not carry the other apps'
  modules, so their methods aren't present and aren't shown — the view is per-build, not a
  guaranteed cluster-wide map. Run it from a node/release that carries every app for the full
  picture.
  """

  @doc """
  The routing rows for the given modules and topology.

  `module_methods` is `[{module, [{{fun, arity}, configured_nodes}, ...]}, ...]`; `node_names`
  the topology's node names. Returns one row per method (sorted by module), shaped:

      %{module: M, fun: f, arity: a, nodes: %{node => :local | :remote}}
  """
  def build(module_methods, node_names) do
    for {module, methods} <- module_methods,
        {{fun, arity}, configured} <- methods do
      %{
        module: module,
        fun: fun,
        arity: arity,
        nodes:
          Map.new(node_names, fn n -> {n, if(n in configured, do: :local, else: :remote)} end)
      }
    end
    |> sort_rows(:module)
  end

  @doc """
  Render the routing map as a "git lola"-style graph string.

  `nodes` is the topology as `[{name, tags}]` (the `config :nebula_api, :nodes` shape). Each node
  gets a vertical rail, introduced top-down with its name and selectors (`@short &tag …`); then
  one row per method, a glyph per rail (`●` local / `-` remote) followed by the method. The
  `current_node`'s rail label is bold. Options: `:color` (default true).
  """
  def render(rows, nodes, current_node, opts \\ []) do
    color? = Keyword.get(opts, :color, true)
    node_names = Keyword.keys(nodes)
    title = "NebulaAPI routes — current node: #{current_node}"
    scope = faint_if("(lists only the defapi compiled into this build / release)", true, color?)

    if rows == [] do
      Enum.join([title, scope, "(no defapi methods found)"], "\n")
    else
      # Spaced, continuous rails (no blank lines, or the vertical lines break). A node that
      # serves nothing locally (no ● in its column) is kept but greyed out whole.
      grey = MapSet.new(for name <- node_names, not active_in_column?(rows, name), do: name)

      header =
        nodes
        |> Enum.with_index()
        |> Enum.map(fn {{name, tags}, i} ->
          rails = node_names |> Enum.take(i) |> Enum.map(&rail(&1, grey, color?))

          intro =
            "/~~ " <>
              node_label(name, tags, name == current_node, MapSet.member?(grey, name), color?)

          Enum.join(rails ++ [intro], " ")
        end)

      cont = Enum.map_join(node_names, " ", &rail(&1, grey, color?))

      body =
        Enum.map(rows, fn row ->
          cells = Enum.map_join(node_names, " ", &glyph(Map.fetch!(row.nodes, &1), color?))
          cells <> " " <> method_label(row)
        end)

      legend = legend(rows, color?)

      Enum.join([title, scope] ++ header ++ [cont] ++ body ++ ["", legend], "\n")
    end
  end

  @doc """
  Discover, build, sort, and print the routing map for the current node. Options: `:nodes`
  (`[{name, tags}]`), `:current_node`, `:modules`, `:sort` (`:module` default, or `:name`),
  `:color`.
  """
  def print(opts \\ []) do
    if Keyword.get(opts, :follow, false) do
      follow_loop(Keyword.put(opts, :available, true))
    else
      print_once(opts)
    end
  end

  defp print_once(opts) do
    nodes = Keyword.get(opts, :nodes) || NebulaAPI.Config.nodes()
    current = Keyword.get(opts, :current_node) || current_node()
    modules = Keyword.get(opts, :modules) || discover()

    modules
    |> build(Keyword.keys(nodes))
    |> sort_rows(Keyword.get(opts, :sort, :module))
    |> maybe_available(opts, current)
    |> render(nodes, current, opts)
    |> IO.puts()
  end

  defp maybe_available(rows, opts, current) do
    if Keyword.get(opts, :available, false) do
      connected = Keyword.get(opts, :connected) || [node() | Node.list()]
      workers = Keyword.get(opts, :available_by_method) || collect_workers(rows)
      build_available(rows, connected, workers, current)
    else
      rows
    end
  end

  defp collect_workers(rows) do
    Map.new(rows, fn r ->
      {{r.module, {r.fun, r.arity}},
       NebulaAPI.APIServer.available_nodes(r.module, {r.fun, r.arity})}
    end)
  end

  # --follow implies --available: the live cluster state is what changes between ticks.
  defp follow_loop(opts) do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    print_once(opts)
    IO.puts("\n(refreshing every 5s — Ctrl-C to stop)")
    Process.sleep(5000)
    follow_loop(opts)
  end

  @doc """
  Overlay live cluster state onto static rows (the `--available` view). Per serving node, the
  static `:local` becomes — relative to `current_node` and the runtime facts — `:local` (this
  node), `:remote_available` (connected + a live worker), `:worker_unavailable` (connected, no
  worker), or `:node_unavailable` (disconnected). A `:remote` cell (the node doesn't serve the
  method) becomes `:not_served`.

  `connected` is the list of reachable node names; `available_by_method` maps
  `{module, {fun, arity}}` to the nodes with a live worker (from `NebulaAPI.APIServer.available_nodes/2`).
  """
  def build_available(rows, connected, available_by_method, current_node) do
    connected = MapSet.new(connected)

    Enum.map(rows, fn row ->
      workers = MapSet.new(Map.get(available_by_method, {row.module, {row.fun, row.arity}}, []))

      nodes =
        Map.new(row.nodes, fn {node, status} ->
          {node, available_status(status, node, current_node, connected, workers)}
        end)

      %{row | nodes: nodes}
    end)
  end

  defp available_status(:remote, _node, _current, _connected, _workers), do: :not_served

  defp available_status(:local, node, current, connected, workers) do
    cond do
      node == current -> :local
      not MapSet.member?(connected, node) -> :node_unavailable
      MapSet.member?(workers, node) -> :remote_available
      true -> :worker_unavailable
    end
  end

  @doc """
  `[{module, [{{fun, arity}, configured_nodes}, ...]}]` for every loaded module that persisted a
  NebulaAPI configured set (i.e. has `defapi` endpoints).
  """
  def discover do
    for {app, _desc, _vsn} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        Code.ensure_loaded?(module),
        methods = configured_methods(module),
        methods != [],
        do: {module, methods}
  end

  # --- internals -------------------------------------------------------------

  defp sort_rows(rows, :name), do: Enum.sort_by(rows, &{&1.fun, &1.arity, &1.module})

  # Most-local first (●●●● > ●●● > ●●), then by module/fun/arity.
  defp sort_rows(rows, :locality) do
    Enum.sort_by(rows, fn r ->
      locals = Enum.count(r.nodes, fn {_node, status} -> status == :local end)
      {-locals, r.module, r.fun, r.arity}
    end)
  end

  defp sort_rows(rows, _module), do: Enum.sort_by(rows, &{&1.module, &1.fun, &1.arity})

  defp configured_methods(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:nebula_configured_nodes)
    |> List.flatten()
  rescue
    # Scanning every loaded module hits some with a custom __info__/1 that rejects
    # :attributes (e.g. :elixir_bootstrap) — those simply have no NebulaAPI methods.
    _ -> []
  end

  # On a real node, node() is authoritative; in dev/test (nonode@nohost) fall back to the
  # configured self_node so the view still highlights the right rail.
  defp current_node do
    case node() do
      :nonode@nohost -> NebulaAPI.Config.default_opts()[:self_node] || :nonode@nohost
      n -> n
    end
  end

  defp method_label(%{module: m, fun: f, arity: a}), do: "#{inspect(m)}.#{f}/#{a}"

  defp available_view?(rows) do
    statuses = [:remote_available, :worker_unavailable, :node_unavailable, :not_served]
    Enum.any?(rows, fn r -> Enum.any?(Map.values(r.nodes), &(&1 in statuses)) end)
  end

  defp legend(rows, color?) do
    if available_view?(rows) do
      "#{glyph(:local, color?)} local   #{glyph(:remote_available, color?)} remote-ok   " <>
        "#{glyph(:worker_unavailable, color?)} worker down   " <>
        "#{glyph(:node_unavailable, color?)} node down   #{glyph(:not_served, color?)} not served"
    else
      "#{glyph(:local, color?)} local   #{glyph(:remote, color?)} remote   " <>
        "current bold · full-remote node greyed"
    end
  end

  # A column is "active" if it has any reachable/serving cell. Inactive columns (full-remote in
  # the static view, or a down node in --available) are greyed whole.
  defp active_in_column?(rows, node) do
    Enum.any?(
      rows,
      &(Map.get(&1.nodes, node) in [:local, :remote_available, :worker_unavailable])
    )
  end

  defp rail(node, grey, color?), do: faint_if("|", MapSet.member?(grey, node), color?)

  defp faint_if(s, true, true), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
  defp faint_if(s, _faint?, _color?), do: s

  defp node_label(name, tags, current?, grey?, color?) do
    selectors = "@#{name |> to_string() |> String.split("@") |> hd()}" <> tags_suffix(tags)
    base = "#{name} #{selectors}"

    cond do
      current? and color? -> IO.ANSI.bright() <> base <> IO.ANSI.reset()
      grey? and color? -> IO.ANSI.faint() <> base <> IO.ANSI.reset()
      true -> base
    end
  end

  defp tags_suffix(tags) do
    case List.wrap(tags) do
      [] -> ""
      list -> " " <> Enum.map_join(list, " ", &"&#{&1}")
    end
  end

  defp glyph(:local, true), do: IO.ANSI.green() <> "●" <> IO.ANSI.reset()
  defp glyph(:remote, true), do: IO.ANSI.faint() <> "-" <> IO.ANSI.reset()
  defp glyph(:remote_available, true), do: IO.ANSI.cyan() <> "∆" <> IO.ANSI.reset()
  defp glyph(:worker_unavailable, true), do: IO.ANSI.yellow() <> "x" <> IO.ANSI.reset()
  defp glyph(:node_unavailable, true), do: IO.ANSI.red() <> "X" <> IO.ANSI.reset()
  defp glyph(:local, false), do: "●"
  defp glyph(:remote, false), do: "-"
  defp glyph(:remote_available, false), do: "∆"
  defp glyph(:worker_unavailable, false), do: "x"
  defp glyph(:node_unavailable, false), do: "X"
  defp glyph(:not_served, color?), do: glyph(:remote, color?)
end
