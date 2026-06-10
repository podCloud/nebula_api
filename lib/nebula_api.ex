defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """
  defmacro __using__(opts \\ []) do
    :ok = __register__(__CALLER__, opts)

    quote do
      use NebulaAPI.AST
    end
  end

  defp __register__(env, opts) do
    defaults =
      NebulaAPI.Config.default_opts()
      |> Keyword.validate!(
        self_node: node(),
        allow_unknown_self_node: false,
        max_concurrent_calls: :infinity,
        default_timeout: nil
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

    max_concurrent_calls = Keyword.fetch!(opts, :max_concurrent_calls)

    unless max_concurrent_calls == :infinity or
             (is_integer(max_concurrent_calls) and max_concurrent_calls > 0) do
      raise CompileError,
        line: env.line,
        file: env.file,
        description: """
        Invalid max_concurrent_calls in `use NebulaAPI` inside #{inspect(env.module)}:
        #{inspect(max_concurrent_calls)}

        Expected a positive integer or :infinity (the default).
        `max_concurrent_calls: 1` gives strict serialization.
        """
    end

    default_timeout = Keyword.fetch!(opts, :default_timeout)

    unless is_nil(default_timeout) or (is_integer(default_timeout) and default_timeout > 0) do
      raise CompileError,
        line: env.line,
        file: env.file,
        description: """
        Invalid default_timeout in `use NebulaAPI` inside #{inspect(env.module)}:
        #{inspect(default_timeout)}

        Expected a positive integer (milliseconds), e.g. default_timeout: 15_000.
        """
    end

    Module.register_attribute(env.module, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(env.module, :nebula_remote_api_methods,
      accumulate: true,
      persist: true
    )

    # persist: true so the marker is readable at runtime via __info__(:attributes),
    # which is how NebulaAPI.Server discovers the modules that `use NebulaAPI`.
    Module.register_attribute(env.module, :nebula_api, persist: true)
    Module.put_attribute(env.module, :nebula_api, opts)

    :ok
  end
end
