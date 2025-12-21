defmodule NebulaAPI.AST do
  @moduledoc """
  AST macros for NebulaAPI.

  Provides:
  - `defapi` - Define an API method with node targeting
  - `on_nebula_nodes` - Conditional compilation based on node
  - `call_on_node` - Unicast call with node selector
  - `call_on_nodes` - Multicast call with node selector
  - `call_on_all_nodes` - Multicast call on all nodes
  """

  defmacro __using__(opts) do
    quote do
      require NebulaAPI.AST

      import NebulaAPI.AST,
             unquote(
               opts
               |> Keyword.validate!(
                 only: [
                   defapi: 3,
                   on_nebula_nodes: 2,
                   call_on_node: 2,
                   call_on_node: 3,
                   call_on_nodes: 2,
                   call_on_nodes: 3,
                   call_on_all_nodes: 1,
                   call_on_all_nodes: 2,
                   __wrap_nebula_api_result: 1
                 ]
               )
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

  @doc """
  Defines an API method with node targeting.

  The method is compiled either as a local implementation or a remote stub
  depending on whether the current node matches the target nodes.

  ## Examples

      defapi [@api], get_user(id) do
        Repo.get(User, id)
      end

      defapi [&db, !@worker], find_podcast(slug) do
        MyApp.Repo.find_one(:db, "records", %{identifier: slug})
      end
  """
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

    # Register method as local or remote
    __CALLER__.module
    |> Module.put_attribute(
      if is_current_node do
        :nebula_local_api_methods
      else
        :nebula_remote_api_methods
      end,
      {fundef.name, fundef.args_count}
    )

    # Generate all 3 functions
    quote do
      unquote(NebulaAPI.AST.Builder.build_local_function(fundef, do_fn, is_current_node))
      unquote(NebulaAPI.AST.Builder.build_remote_function(fundef))
      unquote(NebulaAPI.AST.Builder.build_public_function(fundef, is_current_node))
    end
  rescue
    e in CompileError ->
      raise %{e | line: __CALLER__.line, file: __CALLER__.file}
  end

  @doc """
  Conditional compilation based on node.

  Just like `if` but for NebulaAPI. Only compiles the `do` block on matching nodes,
  otherwise compiles the `else` block (if provided).

  ## Examples

      on_nebula_nodes &db do
        # This code only exists on &db nodes
        use MyApp.Repo, otp_app: :my_app
      end

      on_nebula_nodes @api do
        # Code for @api nodes
      else
        # Code for other nodes
      end
  """
  defmacro on_nebula_nodes(nebula_ast, opts) do
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

  @doc """
  Unicast call - execute API calls on a specific node.

  The selector can be either:
  - A Nebula AST expression (like `@api`, `&db`)
  - A function that receives nodes_info map and returns a single node atom

  ## Examples

      # With Nebula expression
      call_on_node @api do
        MyModule.api_method()
      end

      # With selector function
      call_on_node fn nodes_info ->
        nodes_info
        |> Enum.filter(fn {_node, info} -> :worker in info.tags end)
        |> Enum.map(fn {node, _} -> node end)
        |> Enum.random()
      end, timeout: 5000 do
        MyModule.api_method()
      end
  """
  defmacro call_on_node(selector_or_nebula_ast, opts_or_block)

  defmacro call_on_node(selector_or_nebula_ast, do: block) do
    do_call_on_node(selector_or_nebula_ast, [], block, __CALLER__)
  end

  defmacro call_on_node(selector_or_nebula_ast, opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_node(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defmacro call_on_node(selector_or_nebula_ast, opts, do: block) do
    do_call_on_node(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defp do_call_on_node(selector_or_nebula_ast, opts, block, caller) do
    selector = build_selector(selector_or_nebula_ast, :unicast, caller)

    quote do
      old_selector = Process.get(:nebula_node_selector)
      old_mode = Process.get(:nebula_call_mode)
      old_opts = Process.get(:nebula_call_opts)

      try do
        Process.put(:nebula_node_selector, unquote(selector))
        Process.put(:nebula_call_mode, :unicast)
        Process.put(:nebula_call_opts, unquote(opts))
        unquote(block)
      after
        Process.put(:nebula_node_selector, old_selector)
        Process.put(:nebula_call_mode, old_mode)
        Process.put(:nebula_call_opts, old_opts)
      end
    end
  end

  @doc """
  Multicast call - execute API calls on multiple nodes.

  The selector can be either:
  - A Nebula AST expression (like `@api`, `&db`) - all matching nodes
  - A function that receives nodes_info map and returns a list of node atoms

  ## Examples

      # With Nebula expression (calls all &db nodes)
      call_on_nodes &db do
        MyModule.api_method()
      end

      # With selector function
      call_on_nodes fn nodes_info ->
        nodes_info
        |> Enum.filter(fn {_node, info} -> :storage in info.tags end)
        |> Enum.map(fn {node, _} -> node end)
      end, timeout: 5000, strategy: :all do
        MyModule.api_method()
      end
  """
  defmacro call_on_nodes(selector_or_nebula_ast, opts_or_block)

  defmacro call_on_nodes(selector_or_nebula_ast, do: block) do
    do_call_on_nodes(selector_or_nebula_ast, [], block, __CALLER__)
  end

  defmacro call_on_nodes(selector_or_nebula_ast, opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_nodes(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defmacro call_on_nodes(selector_or_nebula_ast, opts, do: block) do
    do_call_on_nodes(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defp do_call_on_nodes(selector_or_nebula_ast, opts, block, caller) do
    selector = build_selector(selector_or_nebula_ast, :multicast, caller)

    quote do
      old_selector = Process.get(:nebula_node_selector)
      old_mode = Process.get(:nebula_call_mode)
      old_opts = Process.get(:nebula_call_opts)

      try do
        Process.put(:nebula_node_selector, unquote(selector))
        Process.put(:nebula_call_mode, :multicast)
        Process.put(:nebula_call_opts, unquote(opts))
        unquote(block)
      after
        Process.put(:nebula_node_selector, old_selector)
        Process.put(:nebula_call_mode, old_mode)
        Process.put(:nebula_call_opts, old_opts)
      end
    end
  end

  @doc """
  Multicast call on all available nodes.

  Convenience wrapper around `call_on_nodes` that selects all nodes.

  ## Examples

      call_on_all_nodes do
        MyModule.api_method()
      end

      call_on_all_nodes timeout: 5000, strategy: :first do
        MyModule.api_method()
      end
  """
  defmacro call_on_all_nodes(opts_or_block)

  defmacro call_on_all_nodes(do: block) do
    quote do
      call_on_nodes(fn nodes_info -> Map.keys(nodes_info) end, do: unquote(block))
    end
  end

  defmacro call_on_all_nodes(opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)

    quote do
      call_on_nodes(fn nodes_info -> Map.keys(nodes_info) end, unquote(opts), do: unquote(block))
    end
  end

  # Build a selector function from either a Nebula AST expression or a function
  defp build_selector(selector_or_nebula_ast, mode, caller) do
    # Check if it looks like a Nebula AST (starts with @, &, !, or is a list)
    if is_nebula_ast?(selector_or_nebula_ast) do
      # Parse the Nebula AST at compile time to get the target nodes
      target_nodes =
        try do
          get_execution_nodes_from_nebula_ast!(selector_or_nebula_ast)
        rescue
          _ -> nil
        end

      if target_nodes do
        target_node_names = Keyword.keys(target_nodes)

        case mode do
          :unicast ->
            # For unicast, pick the first matching node
            quote do
              fn nodes_info ->
                target_nodes = unquote(target_node_names)

                nodes_info
                |> Map.keys()
                |> Enum.find(fn node -> node in target_nodes end)
              end
            end

          :multicast ->
            # For multicast, return all matching nodes
            quote do
              fn nodes_info ->
                target_nodes = unquote(target_node_names)

                nodes_info
                |> Map.keys()
                |> Enum.filter(fn node -> node in target_nodes end)
              end
            end
        end
      else
        # If parsing fails, treat as a function
        selector_or_nebula_ast
      end
    else
      # It's a function, use it directly
      selector_or_nebula_ast
    end
  end

  defp is_nebula_ast?({:@, _, _}), do: true
  defp is_nebula_ast?({:&, _, _}), do: true
  defp is_nebula_ast?({:!, _, _}), do: true
  defp is_nebula_ast?(list) when is_list(list), do: true
  defp is_nebula_ast?(_), do: false

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
