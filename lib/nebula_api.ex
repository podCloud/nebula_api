defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """
  defmacro __using__(opts \\ []) do
    :ok = __register__(__CALLER__, opts)

    quote do
      use NebulaAPI.AST

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
end
