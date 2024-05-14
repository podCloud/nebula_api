defmodule NebulaAPI.AST do
  defmacro __using__(opts) do
    quote do
      require NebulaAPI.AST

      import NebulaAPI.AST,
             unquote(
               opts
               |> Keyword.validate!(only: [defapi: 3, on_nebula: 2, __wrap_nebula_api_result: 1])
             )
    end
  end

  def __wrap_nebula_api_result(result) do
    case result do
      {:error, result} -> {:error, result}
      {:ok, result} -> {:ok, result}
      result -> {:ok, result}
    end
  end

  defmacro defapi(nebula_ast, fn_ast, do: do_fn) do
    execution_nodes = nebula_ast |> get_execution_nodes_from_nebula_ast!()
    fundef = fn_ast |> NebulaAPI.AST.Parser.parse_fundef_ast()

    self_node =
      __CALLER__.module
      |> Module.get_attribute(:nebula_api)
      |> Keyword.fetch!(:self_node)

    is_current_node =
      execution_nodes
      |> Keyword.keys()
      |> Enum.member?(self_node)

    __CALLER__.module
    |> Module.put_attribute(
      if is_current_node do
        :nebula_local_api_methods
      else
        :nebula_remote_api_methods
      end,
      {fundef.name, fundef.args_count}
    )

    if is_current_node do
      NebulaAPI.AST.Builder.build_function_for_local_node(fundef, do_fn)
    else
      NebulaAPI.AST.Builder.build_function_for_remote_node(fundef)
    end
  rescue
    e in CompileError ->
      raise %{e | line: __CALLER__.line, file: __CALLER__.file}
  end

  @doc """
    Just like if but for NebulaAPI. 
    You use it with nebula api query language :
    
    ```elixir
      on_nebula &nebula @node1 !@node2 do
        # some code
      end
    ```
  """
  defmacro on_nebula(nebula_ast, opts) do
    execution_nodes = nebula_ast |> get_execution_nodes_from_nebula_ast!()

    self_node =
      case __CALLER__.module do
        nil -> node()
        mod -> Module.get_attribute(mod, :nebula_api, []) |> Keyword.get(:self_node, node())
      end

    is_current_node =
      execution_nodes
      |> Keyword.keys()
      |> Enum.member?(self_node)

    if(is_current_node, do: opts |> Keyword.get(:do), else: opts |> Keyword.get(:else))
  rescue
    e in CompileError ->
      raise %{e | line: __CALLER__.line, file: __CALLER__.file}
  end

  defp get_execution_nodes_from_nebula_ast!(ast) do
    parsed = ast |> NebulaAPI.AST.Parser.parse_nebula_ast()

    import NebulaAPI.Config
    require NebulaAPI.Config

    parsed |> validate_with_nodes(nodes())

    execution_nodes =
      nodes()
      |> nodes_for_nodes_names(parsed.nodes)
      |> nodes_for_not_nodes_names(parsed.not_nodes)
      |> nodes_for_not_tags(parsed.not_tags)
      |> nodes_for_tags(parsed.tags)

    if Enum.empty?(execution_nodes) do
      raise CompileError,
        description: """
        No nodes found for execution of nebula macro

        Parsed Nebula AST :
          #{inspect(parsed)}
        """
    end

    execution_nodes
  end
end
