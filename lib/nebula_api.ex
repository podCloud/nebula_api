defmodule NebulaAPI do
  @moduledoc """
   Documentation for `NebulaAPI`.
  """
  defmacro __using__(opts \\ []) do
    resolved = __register__(__CALLER__, opts)

    quote do
      use NebulaAPI.AST

      # Runtime accessor for the `use NebulaAPI` options — a function head on a
      # literal, so hot paths (APIServer.resolve_timeout/2, on every remote
      # call) read it without scanning module attributes. The persisted
      # :nebula_api attribute remains as the discovery marker NebulaAPI.Server
      # relies on, and as the compile-time source for defapi (self_node).
      @doc false
      def __nebula_api__(:default_timeout),
        do: unquote(Keyword.fetch!(resolved, :default_timeout))

      def __nebula_api__(:max_concurrent_calls),
        do: unquote(Keyword.fetch!(resolved, :max_concurrent_calls))
    end
  end

  @doc """
  Extends the deadline of the in-flight NebulaAPI call this process is serving.

  Call it from inside a `defapi` body that legitimately runs long: it resets the
  caller's timeout window (a heartbeat, like a long task pinging its scheduler),
  so a slow-but-alive body is not mistaken for a hung one and killed.

  Outside a remote call — the same body invoked locally, or any other process —
  it is a no-op: the local path has no caller deadline to extend.
  """
  def request_more_time do
    case Process.get(:nebula_api_call) do
      {caller, ref} -> send(caller, {ref, :request_more_time})
      nil -> :ok
    end

    :ok
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

    self_node = Keyword.fetch!(opts, :self_node)

    # No node name at compile time (node() is :nonode@nohost) means the name isn't SET — a
    # different problem from an UNKNOWN name, so `allow_unknown_self_node` deliberately does
    # NOT cover it (it's almost always a forgotten `--name`). Only an explicit nameless build
    # is allowed, via `allow_nonode_nohost: true`.
    if self_node == :nonode@nohost and not NebulaAPI.Config.config()[:allow_nonode_nohost] do
      raise CompileError,
        line: env.line,
        file: env.file,
        description: """
        Error using NebulaAPI inside #{inspect(env.module)} — no node name set at compile time.

        node() is :nonode@nohost: you compiled without `--name`. NebulaAPI bakes routing per
        node, so it must know which node this is. Either:
          - compile with `elixir --name node@host -S mix compile`
            (or set `config :nebula_api, default_opts: [self_node: :"node@host"]` for dev/test), or
          - set `config :nebula_api, allow_nonode_nohost: true` for a deliberate nameless,
            generic build that serves nothing.

        (allow_unknown_self_node does NOT apply here — the name isn't unknown, it's unset.)
        """
    end

    allow_unknown_self_node =
      opts
      |> Keyword.fetch!(:allow_unknown_self_node)

    unless allow_unknown_self_node do
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

    # Single compile-time source of truth, persisted per defapi as
    # {{fn_name, arity}, configured_nodes}. local/remote on a node are DERIVED from it
    # (node ∈ configured ⇒ local) — there are no separate local/remote method lists.
    # Exposed at runtime via NebulaAPI.APIServer.{configured_nodes,registered_local_methods}.
    Module.register_attribute(env.module, :nebula_configured_nodes,
      accumulate: true,
      persist: true
    )

    # persist: true so the marker is readable at runtime via __info__(:attributes),
    # which is how NebulaAPI.Server discovers the modules that `use NebulaAPI`.
    Module.register_attribute(env.module, :nebula_api, persist: true)
    Module.put_attribute(env.module, :nebula_api, opts)

    opts
  end
end
