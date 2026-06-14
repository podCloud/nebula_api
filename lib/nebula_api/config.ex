defmodule NebulaAPI.Config do
  @defaults [
    nodes: [],
    default_opts: [],
    nodes_info_refresh_interval: 5_000,
    default_timeout: 5_000,
    allow_nonode_nohost: false
  ]

  def config() do
    @defaults
    |> Keyword.merge(Application.get_all_env(:nebula_api))
  end

  def nodes() do
    base = config()[:nodes]
    forbid_manual_nonode!(base)

    # `allow_nonode_nohost: true` makes a NAMELESS build (`node()` is `:nonode@nohost`,
    # built without `--name`) a valid, EMPTY node — never with custom tags. It's a generic
    # node that matches no selector, serves nothing, and routes every `defapi` call remotely.
    if config()[:allow_nonode_nohost] do
      base ++ [{:nonode@nohost, []}]
    else
      base
    end
  end

  # nonode@nohost is special — it's the generic/out-of-cluster identity, it must never carry
  # tags or be addressable. You don't list it yourself; flip `allow_nonode_nohost: true` and
  # it's added empty. A manual entry (with or without tags) is a configuration error.
  defp forbid_manual_nonode!(nodes) do
    if Keyword.has_key?(nodes, :nonode@nohost) do
      raise ArgumentError, """
      NebulaAPI: don't put `nonode@nohost` in `config :nebula_api, :nodes` — it's the
      reserved generic/out-of-cluster identity and can't carry tags or be a target. To allow
      a nameless build, set `config :nebula_api, allow_nonode_nohost: true` instead.
      """
    end
  end

  def default_opts() do
    config()[:default_opts]
  end

  # How often (ms) NodesInfoCache refreshes the cluster node-info snapshot.
  def nodes_info_refresh_interval() do
    config()[:nodes_info_refresh_interval]
  end

  # Global default timeout (ms) for remote calls, overridable per module
  # (`use NebulaAPI, default_timeout: ...`) and per call (`timeout:` option).
  def default_timeout() do
    config()[:default_timeout]
  end

  def validate_with_nodes(config, nodes) do
    import Enum, only: [reduce: 3, uniq: 1, sort: 1]

    {
      all_nodes_names,
      all_nodes_tags
    } =
      nodes
      |> reduce(
        %{names: [], tags: []},
        fn {name, tags}, all ->
          %{
            names:
              all.names ++
                [
                  name |> to_string,
                  name |> to_string |> String.split("@", parts: 2) |> hd
                ],
            tags:
              all.tags ++
                cond do
                  is_list(tags) ->
                    tags

                  is_atom(tags) ->
                    [tags]

                  true ->
                    raise CompileError,
                      description: """
                      Invalid tags for node #{inspect(name)}: #{inspect(tags)}

                      Each node's tags must be an atom or a list of atoms, e.g.
                        "node@host": :db
                        "node@host": [:db, :api]
                      """
                end
          }
        end
      )
      |> then(&{&1.names |> uniq |> sort, &1.tags |> uniq |> sort})

    unknown_tags = config.tags -- all_nodes_tags
    unknown_not_tags = config.not_tags -- all_nodes_tags

    if (unknown_tags ++ unknown_not_tags) |> Enum.any?() do
      raise CompileError,
        description: """
        Unknown tags in defapi call : 
        #{((unknown_tags |> Enum.map(&"\t- &#{&1}")) ++ (unknown_not_tags |> Enum.map(&"\t- !&#{&1}"))) |> Enum.join("\n")}

        Available tags :
        #{all_nodes_tags |> Enum.map(&"\t- &#{&1}") |> Enum.join("\n")}
        """
    end

    unknown_nodes = Enum.map(config.nodes, &to_string/1) -- all_nodes_names
    unknown_not_nodes = Enum.map(config.not_nodes, &to_string/1) -- all_nodes_names

    if (unknown_nodes ++ unknown_not_nodes) |> Enum.any?() do
      raise CompileError,
        description: """
        Unknown nodes in defapi call : 
        #{((unknown_nodes |> Enum.map(&"\t- @#{&1}")) ++ (unknown_not_nodes |> Enum.map(&"\t- !@#{&1}"))) |> Enum.join("\n")}

        Available nodes :
        #{all_nodes_names |> Enum.map(fn name -> if name |> String.contains?("@") do
            "\t- @:\"#{name}\""
          else
            "\t- @#{name}"
          end end) |> Enum.join("\n")}
        """
    end

    :ok
  end

  def nodes_for_tags(nodes, tag)
      when is_atom(tag),
      do: nodes_for_tags(nodes, [tag])

  def nodes_for_tags(nodes, []), do: nodes

  def nodes_for_tags(nodes, tags) do
    nodes
    |> Enum.filter(fn
      {_node_name, node_tags} when is_list(node_tags) ->
        # Keep the node only if it carries ALL requested tags (intersection):
        # `&a &b` means "a AND b". Union is expressed by giving both groups a
        # shared tag in config, so the selector combinator is the narrowing one
        # — consistent with `@n &t`, `&t !&u` and `!&a !&b`, which all narrow.
        Enum.all?(tags, &(&1 in node_tags))

      {_node_name, node_tag} when is_atom(node_tag) ->
        # A node with a single (atom) tag satisfies "all requested" only when
        # the request is exactly that one tag.
        Enum.all?(tags, &(&1 == node_tag))
    end)
  end

  def nodes_for_not_tags(nodes, tag)
      when is_atom(tag),
      do: nodes_for_not_tags(nodes, [tag])

  def nodes_for_not_tags(nodes, []), do: nodes

  def nodes_for_not_tags(nodes, tags) do
    nodes
    |> Enum.filter(fn
      {_node_name, node_tags} when is_list(node_tags) ->
        # keep node if NONE of the excluded tags are present
        tags -- node_tags == tags

      {_node_name, node_tag} when is_atom(node_tag) ->
        not Enum.member?(tags, node_tag)
    end)
  end

  def nodes_for_nodes_names(nodes, node_name)
      when not is_list(node_name),
      do: nodes_for_nodes_names(nodes, [node_name])

  def nodes_for_nodes_names(nodes, []), do: nodes

  def nodes_for_nodes_names(nodes, nodes_names) do
    nodes_names = nodes_names |> Enum.map(&to_string/1)

    nodes
    |> Enum.filter(fn
      {name, _} ->
        name = to_string(name)

        nodes_names
        |> Enum.member?(name) ||
          nodes_names
          |> Enum.member?(name |> String.split("@", parts: 2) |> hd)
    end)
  end

  def nodes_for_not_nodes_names(nodes, node_name)
      when not is_list(node_name),
      do: nodes_for_not_nodes_names(nodes, [node_name])

  def nodes_for_not_nodes_names(nodes, []), do: nodes

  def nodes_for_not_nodes_names(nodes, nodes_names) do
    nodes_names = nodes_names |> Enum.map(&to_string/1)

    nodes
    |> Enum.filter(fn
      {name, _} ->
        name = to_string(name)

        not (nodes_names
             |> Enum.member?(name)) &&
          not (nodes_names
               |> Enum.member?(name |> String.split("@", parts: 2) |> hd))
    end)
  end
end
