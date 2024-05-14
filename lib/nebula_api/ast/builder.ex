defmodule NebulaAPI.AST.Builder do
  def build_function_for_local_node(%{name: fn_name, args: fn_args}, fn_do) do
    quote do
      def unquote(build_function_signature(fn_name, fn_args)) do
        unquote(fn_do) |> __wrap_nebula_api_result()
      rescue
        e -> {:error, e}
      end
    end
  end

  def build_function_for_remote_node(%{name: fn_name, args: fn_args}) do
    quote do
      def unquote(build_function_signature(fn_name, fn_args)) do
        NebulaAPI.APIServer.call_remote_method(
          __MODULE__,
          unquote(build_remote_function_call(fn_name, fn_args))
        )
        |> __wrap_nebula_api_result()
      rescue
        e -> {:error, e}
      end
    end
  end

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
