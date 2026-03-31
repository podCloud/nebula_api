defmodule NebulaAPI.AST.Builder do
  @moduledoc """
  AST builder for NebulaAPI functions.

  For each `defapi`, generates 3 functions:
  - `__nbapi_local_<name>` - Private function with the actual implementation (or stub if remote)
  - `__nbapi_remote_<name>` - Private function that calls the remote method
  - `<name>` - Public router function that delegates to local or remote based on context
  """

  @doc """
  Builds the local implementation function.
  If `is_local` is true, generates the actual implementation.
  If `is_local` is false, generates a stub that raises an error.
  """
  def build_local_function(%{name: fn_name, args: fn_args}, fn_do, is_local) do
    local_fn_name = :"__nbapi_local_#{fn_name}"

    if is_local do
      quote do
        defp unquote(build_function_signature(local_fn_name, fn_args)) do
          unquote(fn_do) |> __wrap_nebula_api_result()
        rescue
          e ->
            require Logger
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            {:error, e}
        end
      end
    else
      quote do
        defp unquote(build_function_signature(local_fn_name, fn_args)) do
          raise "Method #{unquote(fn_name)} is not available locally on node #{node()}"
        end
      end
    end
  end

  @doc """
  Builds the remote call function.
  This is always generated and calls the remote method via APIServer.
  """
  def build_remote_function(%{name: fn_name, args: fn_args}) do
    remote_fn_name = :"__nbapi_remote_#{fn_name}"
    # Use a hygienic variable bound to this module's context — cannot clash with any
    # user-defined parameter, even one named `nebula_routing_opts`
    routing_opts_var = Macro.var(:nebula_routing_opts, __MODULE__)
    routing_opts_param = {:__inline, {:\\, [], [routing_opts_var, []]}}
    fn_args_with_routing_opts = fn_args ++ [routing_opts_param]

    quote do
      defp unquote(build_function_signature(remote_fn_name, fn_args_with_routing_opts)) do
        case NebulaAPI.APIServer.call_remote_method(
               __MODULE__,
               unquote(build_remote_function_call(fn_name, fn_args)),
               unquote(routing_opts_var)
             ) do
          # Multicast :all returns a list — pass through as-is
          result when is_list(result) -> result
          # All other results: unicast, :first, :quorum
          result -> __wrap_nebula_api_result(result)
        end
      rescue
        e -> {:error, e}
      end
    end
  end

  @doc """
  Builds the public router function.
  This function decides whether to call the local or remote implementation
  based on the call context (unicast/multicast selector or default behavior).
  """
  def build_public_function(%{name: fn_name, args: fn_args}, is_local) do
    local_fn_name = :"__nbapi_local_#{fn_name}"
    remote_fn_name = :"__nbapi_remote_#{fn_name}"
    fn_arg_vars = fn_args_to_vars(fn_args)
    # Use a hygienic variable bound to this module's context — cannot clash with any
    # user-defined parameter, even one named `nebula_routing_opts`
    routing_opts_var = Macro.var(:nebula_routing_opts, __MODULE__)
    routing_opts_param = {:__inline, {:\\, [], [routing_opts_var, []]}}
    fn_args_with_routing_opts = fn_args ++ [routing_opts_param]

    quote do
      def unquote(build_function_signature(fn_name, fn_args_with_routing_opts)) do
        # Check for call context from process dictionary (set by call_on_node/call_on_nodes)
        context_selector = Process.get(:nebula_node_selector)
        context_mode = Process.get(:nebula_call_mode)
        context_opts = Process.get(:nebula_call_opts, [])

        # Merge context opts with routing opts
        merged_opts = Keyword.merge(context_opts, unquote(routing_opts_var))

        cond do
          # If we have a context selector (from call_on_node or call_on_nodes)
          not is_nil(context_selector) ->
            unquote(remote_fn_name)(
              unquote_splicing(fn_arg_vars),
              Keyword.merge(merged_opts,
                node_selector: context_selector,
                multicast: context_mode == :multicast
              )
            )

          # If routing opts explicitly contain node_selector or multicast
          unquote(routing_opts_var)[:node_selector] || unquote(routing_opts_var)[:multicast] ->
            unquote(remote_fn_name)(unquote_splicing(fn_arg_vars), unquote(routing_opts_var))

          # Default behavior: local if compiled local, remote otherwise
          unquote(is_local) ->
            unquote(local_fn_name)(unquote_splicing(fn_arg_vars))

          true ->
            unquote(remote_fn_name)(unquote_splicing(fn_arg_vars), unquote(routing_opts_var))
        end
      end
    end
  end

  # Private helper functions

  defp build_remote_function_call(fn_name, fn_args) do
    quote do
      {unquote(fn_name), unquote_splicing(fn_args |> fn_args_to_vars)}
    end
  end

  defp build_function_signature(fn_name, fn_args) do
    Macro.var(fn_name, nil) |> put_elem(2, fn_args_to_defaulted_vars(fn_args))
  end

  defp fn_args_to_defaulted_vars(fn_args) do
    fn_args
    |> Enum.map(fn
      {:__inline, arg} ->
        quote do
          unquote(arg)
        end

      {arg, default} ->
        quote do
          unquote(Macro.var(arg, nil)) \\ unquote(default)
        end

      arg ->
        Macro.var(arg, nil)
    end)
  end

  defp fn_args_to_vars(fn_args),
    do:
      fn_args
      |> Enum.map(fn
        {:__inline, arg} ->
          quote do
            unquote(arg)
          end

        {arg, _default} ->
          Macro.var(arg, nil)

        arg ->
          Macro.var(arg, nil)
      end)
end
