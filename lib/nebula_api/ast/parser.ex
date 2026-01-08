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
        |> Map.merge(config, fn _k, v1, v2 -> v1 ++ v2 end)
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

  # Handle :* marker for "all nodes"
  defp extract_nebula_config(config = %{__unparsed: :*}) do
    %{config | all_nodes: true} |> Map.delete(:__unparsed)
  end

  def parse_fundef_ast({fn_name, _, fn_args}) do
    fn_args
    |> Enum.reduce(
      %{
        name: fn_name,
        args: [],
        args_count: 0
      },
      fn
        arg, fundef when is_atom(arg) ->
          %{fundef | args: fundef.args ++ [{:__inline, arg}], args_count: fundef.args_count + 1}

        {arg, _, nil}, fundef ->
          %{fundef | args: fundef.args ++ [arg], args_count: fundef.args_count + 1}

        {:\\, _, [{arg, _, nil}, default]}, fundef ->
          %{fundef | args: fundef.args ++ [{arg, default}], args_count: fundef.args_count + 1}
      end
    )
  end
end
