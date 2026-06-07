defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """
  defmacro __using__(opts \\ []) do
    :ok = __register__(__CALLER__, opts)

    quote do
      import NebulaAPI, only: [nebula_api_server: 0]
      use NebulaAPI.AST
    end
  end

  @doc """
  Expands to a child spec for `NebulaAPI.Server`, to be placed in the supervision
  tree of an OTP application that owns modules using `NebulaAPI`.

  The trick: this macro expands at the call site, so `__MODULE__` is the *consumer's*
  module (typically its `Application`), which belongs to the consumer's OTP app. That
  module is all `NebulaAPI.Server` needs — at runtime it resolves the owning app, lists
  *its* modules (then all compiled and loaded), keeps only those that `use NebulaAPI`
  with local methods on this node, and starts a worker for each.

  Because the server lives inside the app's own tree, the worker lifecycle is correct
  for free: if the app stops or crashes, its server and workers die with it and `:pg`
  drops them. No central discovery, no `registered_modules`.

      defmodule MyApp.Application do
        use Application
        use NebulaAPI

        def start(_type, _args) do
          Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
        end
      end
  """
  defmacro nebula_api_server do
    # Mark the calling module so the `:nebula` Mix compiler can verify, after the whole
    # app is compiled, that an app with local methods actually wired a server somewhere.
    # The attribute is registered by `use NebulaAPI` (which is what brings this macro
    # into scope), so it persists into the .beam.
    Module.put_attribute(__CALLER__.module, :nebula_api_server_wired, true)

    quote do
      NebulaAPI.Server.child_spec(app_module: __MODULE__)
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

    # persist: true so the marker is readable at runtime via __info__(:attributes),
    # which is how NebulaAPI.Server discovers the modules that `use NebulaAPI`.
    Module.register_attribute(env.module, :nebula_api, persist: true)
    Module.put_attribute(env.module, :nebula_api, opts)

    # persist: true so the `:nebula` Mix compiler can read it from the .beam: it marks
    # a module in which `nebula_api_server/0` was used. The compiler errors out when an
    # app has local methods but no module carrying this marker (server not wired).
    Module.register_attribute(env.module, :nebula_api_server_wired, persist: true)

    :ok
  end
end
