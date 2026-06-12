defmodule NebulaAPI.AST.Parser do
  def parse_nebula_ast(ast) do
    ast
    |> nebula_ast()
    |> extract_nebula_config()
  end

  defp nebula_ast(ast) do
    %{tags: [], not_tags: [], nodes: [], not_nodes: [], all_nodes: false, __unparsed: ast}
  end

  defp extract_nebula_config(config = %{__unparsed: asts})
       when is_list(asts) do
    asts
    |> Enum.reduce(config, fn
      ast, config ->
        ast
        |> nebula_ast()
        |> extract_nebula_config()
        |> Map.merge(config, fn
          # Handle boolean fields (all_nodes) - use OR
          _k, v1, v2 when is_boolean(v1) and is_boolean(v2) -> v1 or v2
          # Handle list fields - concatenate
          _k, v1, v2 -> v1 ++ v2
        end)
    end)
    |> Map.delete(:__unparsed)
  end

  defp extract_nebula_config(config = %{__unparsed: {:!, _, [{:@, _, [{node, _, [rest]}]}]}}) do
    %{config | not_nodes: config.not_nodes ++ [node], __unparsed: rest} |> extract_nebula_config
  end

  defp extract_nebula_config(config = %{__unparsed: {:@, _, [{node, _, [rest]}]}}) do
    %{config | nodes: config.nodes ++ [node], __unparsed: rest} |> extract_nebula_config
  end

  defp extract_nebula_config(config = %{__unparsed: {:!, _, [{:&, _, [{node, _, [rest]}]}]}}) do
    %{config | not_tags: config.not_tags ++ [node], __unparsed: rest} |> extract_nebula_config
  end

  defp extract_nebula_config(config = %{__unparsed: {:&, _, [{tag, _, [rest]}]}}) do
    %{config | tags: config.tags ++ [tag], __unparsed: rest} |> extract_nebula_config
  end

  defp extract_nebula_config(config = %{__unparsed: {:!, _, [{:@, _, [{node, _, nil}]}]}}) do
    %{config | not_nodes: config.not_nodes ++ [node]} |> Map.delete(:__unparsed)
  end

  defp extract_nebula_config(config = %{__unparsed: {:@, _, [{node, _, nil}]}}) do
    %{config | nodes: config.nodes ++ [node]} |> Map.delete(:__unparsed)
  end

  defp extract_nebula_config(config = %{__unparsed: {:!, _, [{:&, _, [{node, _, nil}]}]}}) do
    %{config | not_tags: config.not_tags ++ [node]} |> Map.delete(:__unparsed)
  end

  defp extract_nebula_config(config = %{__unparsed: {:&, _, [{tag, _, nil}]}}) do
    %{config | tags: config.tags ++ [tag]} |> Map.delete(:__unparsed)
  end

  # Full node name as an atom literal: @:"node@host". The @identifier clauses above
  # only match bare identifiers; a full name contains `@`/`.`, so it's written as an
  # atom — the same atom Config.nodes_for_nodes_names / validate_with_nodes accept.
  defp extract_nebula_config(config = %{__unparsed: {:!, _, [{:@, _, [node]}]}})
       when is_atom(node) do
    %{config | not_nodes: config.not_nodes ++ [node]} |> Map.delete(:__unparsed)
  end

  defp extract_nebula_config(config = %{__unparsed: {:@, _, [node]}}) when is_atom(node) do
    %{config | nodes: config.nodes ++ [node]} |> Map.delete(:__unparsed)
  end

  # Handle :* marker for "all nodes"
  defp extract_nebula_config(config = %{__unparsed: :*}) do
    %{config | all_nodes: true} |> Map.delete(:__unparsed)
  end

  # Anything else is not a valid selector: fail with a clear compile-time message
  # instead of an opaque FunctionClauseError from this module.
  defp extract_nebula_config(%{__unparsed: other}) do
    raise CompileError,
      description: """
      Invalid nebula selector: #{Macro.to_string(other)}

      Accepted forms:
        - @node / !@node          (node short or full name)
        - &tag / !&tag            (capability tag)
        - @:"node@host"           (full node name as an atom)
        - [..]                    (a list combining the above)
        - :*                      (all nodes)
      """
  end

  def parse_fundef_ast({fn_name, _, fn_args}) do
    (fn_args || [])
    |> Enum.reduce(
      %{
        name: fn_name,
        args: [],
        args_count: 0
      },
      fn
        {arg, _, nil}, fundef ->
          %{fundef | args: fundef.args ++ [arg], args_count: fundef.args_count + 1}

        {:\\, _, [{arg, _, nil}, default]}, fundef ->
          %{fundef | args: fundef.args ++ [{arg, default}], args_count: fundef.args_count + 1}

        # Everything else — atoms and other literals included — is a pattern
        # match, and an argument needs a NAME to travel: the router forwards it
        # to the helpers and the remote stub ships it in the fn_call tuple. A
        # literal in the signature would compile into a single-clause pattern
        # whose misses crash the caller with a FunctionClauseError on the
        # public router, outside every confinement.
        arg, _fundef ->
          raise CompileError,
            description: """
            Unsupported defapi argument: #{Macro.to_string(arg)}

            defapi signatures accept simple variables and defaults only
            (e.g. get(id), list(filters \\\\ [])), not pattern-matched
            arguments like atoms, maps, lists or tuples.
            """
      end
    )
  end
end
