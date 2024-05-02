defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """

  require Logger

  defmacro __using__(opts) do
    api_node = :"#{opts[:node]}"

    module = __CALLER__.module
    api_id = {api_node, module}

    is_current_node = api_node == node()

    Module.put_attribute(module, :nebula_api,
      is_current_node: is_current_node,
      api_id: api_id
    )

    {
      :__block__,
      [],
      [
        quote do
          require NebulaAPI

          import NebulaAPI, only: [defapi: 2, on_node: 2]

          use GenServer

          def api_node(), do: unquote(api_node)

          def api_node_id(), do: unquote(api_id)

          def api_node_pid() do
            :global.sync()
            :global.whereis_name(api_node_id())
          end

          def init([]) do

            if node() !== unquote(node()) do
              raise """
                The Module #{inspect(unquote(__CALLER__.module))} has been compiled
                for the node #{inspect(unquote(node()))} and is now running on node #{inspect(node())}.
                This is not supported. Please recompile the module for the correct node.
                """
            end

            {:ok, []}
          end
        end,
        if is_current_node do
          quote do
            def start_link([]) do
              Logger.debug("Starting local API server.")
              GenServer.start_link(__MODULE__, [], name: {:global, api_node_id()})
            end
          end
        else
          quote do
            def start_link([]) do
              Logger.debug("Calling init locally, but not starting server.")
              {:ok, _} = init([])

              :ignore
            end
          end
        end
      ]
    }
  end

  defmacro on_node(node_name, do: block) when is_atom(node_name) do
    if node_name == node() do
      block
    end
  end

  defmacro on_nodes(do: nodes) do
    nodes_blocks = nodes |> Enum.map(fn
      {:->, _meta, [[{node,_,_}] | [block]]} -> {node, block}
      {:->, _meta, [[node] | [block]]} -> {node, block}
    end)
      |> Enum.into(%{})

    nodes_blocks
    |> Map.get(node(), nodes_blocks[:_])
  end

  defmacro defapi({api_method_name, _meta, args}, do: block) do
    # if not a block
    if block == nil do
      raise """
        The `do` keyword is required for the API method definition.
        """
    end

    nebula_api = Module.get_attribute(__CALLER__.module, :nebula_api, [])
    is_current_node = nebula_api[:is_current_node]

    {
      :__block__,
      [],
      [
        quote do
          require Logger
        end,
        if is_current_node do
          quote do
            def unquote(api_method_name)(unquote_splicing(args)) do
              Logger.debug(
                """
                Local #{inspect(api_node())} API method:
                #{inspect(unquote(api_method_name))}
                with args: #{inspect(unquote(args))}

                doin func
                """
              )

              unquote(block)
            end

            def handle_call({unquote(api_method_name), args = [unquote_splicing(args)]}, from, state) do
              Logger.debug(
                """
                Handling call from #{inspect(from)}
                #{inspect(unquote(api_method_name))}
                with args: #{inspect(unquote(args))}

                Calling local api method
                """
              )
              {:reply, apply(__MODULE__, unquote(api_method_name), args), state}
            end
          end
        else
          quote do
            def unquote(api_method_name)(unquote_splicing(args)) do
              Logger.debug(
                """
                Remote because #{inspect(api_node())} != #{inspect(node())}
                Calling #{inspect(api_node())} API method:
                {:global, #{inspect(api_node_id())}},
                {#{inspect(unquote(api_method_name))}, #{inspect([unquote_splicing(args)])}}
                """
              )

              case api_node_pid() do
                :undefined ->
                  Logger.error("Remote API call failed: node not found")
                  {:error, :node_not_found}
                node ->
                  Logger.debug("Remote API call: node found : #{inspect(node)}")
                  GenServer.call(
                    {:global, api_node_id()},
                    {unquote(api_method_name), [unquote_splicing(args)]}
                  )
              end
            end
          end
        end
      ]
    }
  end
end
