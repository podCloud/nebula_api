defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """
  require Logger

  defmacro __using__(opts \\ []) do
    :ok = __register__(__CALLER__, opts)

    quote do
      require NebulaAPI
      import NebulaAPI, only: [defapi: 3, on_nebula: 2]

      NebulaAPI.APIServer.register_module(__MODULE__)
    end
  end

  defp __register__(env, opts) do
    defaults =
      NebulaAPI.Config.default_opts()
      |> Keyword.validate!(
        self_node: node(),
        allow_unknown_self_node: false
      )

    opts =
      opts
      |> Enum.map(fn {k, v} ->
        {k, Code.eval_quoted(v, [], env) |> elem(0)}
      end)
      |> Keyword.validate!(defaults)

    nodes_names =
      NebulaAPI.Config.nodes()
      |> Keyword.keys()

    allow_unknown_self_node =
      opts
      |> Keyword.fetch!(:allow_unknown_self_node)

    unless allow_unknown_self_node do
      self_node = opts |> Keyword.fetch!(:self_node)

      unknown_self_node =
        not (nodes_names
             |> Enum.member?(self_node))

      if unknown_self_node do
        raise CompileError,
          line: env.line,
          file: env.file,
          description: """
          Error using NebulaAPI inside #{inspect(env.module)} !

          self_node is an unknown node, please check you're compiling for a known node :
            -> self_node = #{inspect(self_node)}
            -> node() = #{inspect(node())}

          Configured nodes :
          #{nodes_names |> Enum.map(&"\t- :\"#{&1}\"") |> Enum.join("\n")}
          """
      end
    end

    Module.register_attribute(env.module, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(env.module, :nebula_remote_api_methods,
      accumulate: true,
      persist: true
    )

    Module.put_attribute(env.module, :nebula_api, opts)

    :ok
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
      Module.get_attribute(__CALLER__.module, :nebula_api, [])
      |> Keyword.get(:self_node, node())

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
