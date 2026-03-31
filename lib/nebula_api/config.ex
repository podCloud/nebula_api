defmodule NebulaAPI.Config do
  @defaults [
    nodes: [],
    default_opts: []
  ]

  @app_keys [:registered_modules]

  def config() do
    app_config =
      Application.get_all_env(:nebula_api)
      |> Keyword.drop(@app_keys)

    @defaults
    |> Keyword.merge(app_config)
  end

  def nodes() do
    config()[:nodes]
  end

  def default_opts() do
    config()[:default_opts]
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
            "\t- @\"#{name}\""
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
        # keep node if ALL requested tags are present in node_tags
        (tags -- node_tags) |> Enum.empty?()

      {_node_name, node_tag} when is_atom(node_tag) ->
        Enum.member?(tags, node_tag)
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
        (tags -- node_tags) == tags

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
          |> Enum.member?(name |> String.split("@", limit: 2) |> hd)
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
               |> Enum.member?(name |> String.split("@", limit: 2) |> hd))
    end)
  end
end
