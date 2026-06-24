defmodule NebulaAPI.Routes do
  @moduledoc """
  The per-node routing map — where each `defapi` is served locally vs reached over RPC.

  Built entirely from compile-time data (`:nebula_configured_nodes`, the single source of truth
  also behind `NebulaAPI.APIServer.configured_nodes/2`): a method is *local* on the nodes in its
  configured serving set. Nothing is recomputed; no cluster needed.

  Rendered "git lola"-style — one continuous vertical rail per node, with a `●` marking each node
  that serves a method; the rail simply continues (`|`) where it isn't local. The static view
  asserts only locality (config-known) — it does **not** claim a method actually runs elsewhere;
  pass `available: true` for the live picture (`∆`/`x`/`X` from `:pg` + `Node.list`). Printed by
  `mix nebula.routes` and `NebulaAPI.Server.print_routes/0`.

  ## Scope

  It lists only the modules — and their `defapi` — **present in this build** (the one compiled for
  `compiled_node()`). A node whose release carries a subset of an umbrella's apps does not carry
  the other apps' modules, so those modules and their methods are simply absent from the map;
  modules not imported/used by this build are not shown either. Run it from a node/release that
  carries every app for the full picture.
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
  gets a continuous vertical rail, introduced top-down with its name and selectors (`@short &tag …`);
  then one row per method: `●` where the method is local, the rail (`|`) where it isn't. The
  `current_node`'s rail label is bold. With `available: true` the per-cell glyphs reflect live
  state (`∆`/`x`/`X`, `|` when this node can't observe the cluster). Options: `:color` (default
  true), `:available`.
  """
  def render(rows, nodes, current_node, opts \\ []) do
    color? = Keyword.get(opts, :color, true)
    available? = Keyword.get(opts, :available, false)
    node_names = Keyword.keys(nodes)
    title = "NebulaAPI routes — current node: #{current_node}"

    scope =
      faint_if(
        "only modules & defapi methods present/visible in this build: #{current_node}",
        true,
        color?
      )

    topo_note =
      if current_node in node_names,
        do: [],
        else: [
          bold_if("(current node #{current_node} is not in the configured topology)", color?)
        ]

    if rows == [] do
      Enum.join([title, scope] ++ topo_note ++ ["", "(no defapi methods found)"], "\n")
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

      legend = legend(color?, available?)

      Enum.join(
        [title, scope] ++ topo_note ++ [""] ++ header ++ [cont] ++ body ++ ["", legend],
        "\n"
      )
    end
  end

  @doc """
  Discover, build, sort, and print the routing map for the current node.

  Options:
    * `:available` — overlay live `:pg` + `Node.list` state (`∆`/`x`/`X`; `|` when this node
      can't observe the cluster). Default `false`.
    * `:follow` — refresh every 5s (implies `:available`). Default `false`.
    * `:sort` — `:module` (default), `:name`, or `:locality` (most-local-first).
    * `:color` — ANSI color (default `true`).
    * `:nodes` (`[{name, tags}]`), `:current_node`, `:modules` — override the discovered
      topology / current node / module set (mainly for tests).
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

  When `current_node` is not in `connected` we can't observe the cluster at all (e.g. the task
  runs as `nonode@nohost` and `current_node` is only the config `self_node` fallback): every cell
  becomes `:unknown` rather than asserting a (false) `:node_unavailable`.

  `connected` is the list of reachable node names; `available_by_method` maps
  `{module, {fun, arity}}` to the nodes with a live worker (from `NebulaAPI.APIServer.available_nodes/2`).
  """
  def build_available(rows, connected, available_by_method, current_node) do
    connected = MapSet.new(connected)
    observable? = MapSet.member?(connected, current_node)

    Enum.map(rows, fn row ->
      workers = MapSet.new(Map.get(available_by_method, {row.module, {row.fun, row.arity}}, []))

      nodes =
        Map.new(row.nodes, fn {node, status} ->
          {node, available_status(status, node, current_node, connected, workers, observable?)}
        end)

      %{row | nodes: nodes}
    end)
  end

  # Not observable (this node isn't connected — offline / nonode fallback): we can't tell live
  # state for anything, so assert nothing — every cell is :unknown.
  defp available_status(_status, _node, _current, _connected, _workers, false), do: :unknown

  # Configured-remote (the node doesn't serve the method).
  defp available_status(:remote, _node, _current, _connected, _workers, true), do: :not_served

  # Configured-local, graded against live state. We are observable here, so the current node is
  # genuinely serving locally; peers are graded by connection + worker liveness.
  defp available_status(:local, node, current, connected, workers, true) do
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

  defp legend(color?, true) do
    "#{glyph(:local, color?)} local   #{glyph(:remote_available, color?)} remote-ok   " <>
      "#{glyph(:worker_unavailable, color?)} worker down   #{glyph(:node_unavailable, color?)} node down   " <>
      "#{glyph(:not_served, color?)} unavailable   #{glyph(:unknown, color?)} unknown"
  end

  defp legend(color?, false) do
    "#{glyph(:local, color?)} local  · run --available for live status"
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

  defp bold_if(s, true), do: IO.ANSI.bright() <> IO.ANSI.yellow() <> s <> IO.ANSI.reset()
  defp bold_if(s, false), do: s

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
  defp glyph(:remote_available, true), do: IO.ANSI.cyan() <> "∆" <> IO.ANSI.reset()
  defp glyph(:worker_unavailable, true), do: IO.ANSI.yellow() <> "x" <> IO.ANSI.reset()
  defp glyph(:node_unavailable, true), do: IO.ANSI.red() <> "X" <> IO.ANSI.reset()
  defp glyph(:local, false), do: "●"
  defp glyph(:remote_available, false), do: "∆"
  defp glyph(:worker_unavailable, false), do: "x"
  defp glyph(:node_unavailable, false), do: "X"

  # "not local here" (static view): the rail just continues — a faint `|`, asserting nothing
  # about whether the method actually runs remotely (that's the --available view's job).
  defp glyph(:remote, color?), do: faint_if("|", true, color?)
  # config-remote, observed with no live worker (--available view): a faint dash.
  defp glyph(:not_served, color?), do: faint_if("-", true, color?)
  # can't observe the cluster (--available, offline): a faint rail — asserts nothing.
  defp glyph(:unknown, color?), do: faint_if("|", true, color?)
end
