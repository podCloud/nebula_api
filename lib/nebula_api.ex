defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """

  require Logger

  defmacro __using__(opts) do
    api_node = opts[:node]
    force_current_node = opts[:force_current_node]

    module = __CALLER__.module
    api_id = {api_node, module}

    self_node = Node.self()

    is_current_node = force_current_node || api_node == self_node

    Module.put_attribute(module, :nebula_api,
      is_current_node: is_current_node,
      api_id: {api_node, module}
    )

    result =
      if is_current_node do
        Logger.debug("Will join API register with name : #{inspect(api_id)}")

        quote do
          require NebulaAPI

          import NebulaAPI, only: [defapi: 2]

          def start_link(opts) do
            GenServer.start_link(__MODULE__, opts, name: unquote(api_id))
          end

          def init(opts) do
            # TODO: Save pid inside pg
            #
            # Something like this 
            # :pg.join(
            #  unquote(api_id),
            #  __MODULE__
            # )

            {:ok, opts}
          end
        end
      else
        quote do
          require NebulaAPI

          import NebulaAPI, only: [defapi: 2]
        end
      end

    Logger.debug("Defed API : #{inspect(result)}")
    Logger.debug("Defed API to source : \n#{Macro.to_string(result)}")
    result
  end

  defmacro defapi({api_method_name, meta, args}, do: do_fn) do
    Logger.debug("Defining API method: #{inspect(api_method_name)}")
    Logger.debug("Meta: #{inspect(meta)}")
    Logger.debug("Args: #{inspect(args)}")

    if do_fn == nil do
      raise """
      The `do` keyword is required for the API method definition.
      """
    end

    nebula_api = Module.get_attribute(__CALLER__.module, :nebula_api, [])
    is_current_node = nebula_api[:is_current_node]
    api_id = nebula_api[:api_id]

    defed_api =
      if is_current_node do
        # Define API method locally and handle calls for other nodes
        Logger.debug("Defining API method locally: #{inspect(api_method_name)}")

        quote do
          def unquote(api_method_name)(unquote_splicing(args)) do
            unquote(do_fn)
          end

          def handle_call({unquote(api_method_name), args}, state) do
            {:reply, apply(__MODULE__, unquote(api_method_name), args), state}
          end
        end
      else
        Logger.debug(
          "Defining API method to be called remotely: #{inspect(api_method_name)} #{inspect(api_id)}"
        )

        quote do
          def unquote(api_method_name)(unquote_splicing(args)) do
            # TODO: Get pid from pg
            #
            # Something like this 
            # :pg.get_members({unquote(api_node), unquote(api_app), __MODULE__}),
            #

            GenServer.call(
              unquote(api_id),
              {unquote(api_method_name), unquote_splicing(args)}
            )
          end
        end
      end

    Logger.debug("Defed API : #{inspect(defed_api)}")
    Logger.debug("Defed API to source : \n#{Macro.to_string(defed_api)}")

    defed_api
  end

  def extract_keyword_list(args) do
    args
    # Reverse the list to check the last element first
    |> Enum.reverse()
    # Split list into keyword list vs tuples
    |> Enum.split_while(&is_list/1)
    |> case do
      {[keywords], args} -> {keywords, args}
      {[], args} -> {[], args}
    end
  end
end
