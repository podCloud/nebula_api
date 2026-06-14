defmodule NebulaAPI.AST.Builder do
  @moduledoc """
  AST builder for NebulaAPI functions.

  For each `defapi`, generates:
  - `__nbapi_local_<name>` - Private function with the actual implementation —
    only on nodes where the method is local (no stub on the others: the router
    never references it there)
  - `__nbapi_remote_<name>` - Private function that calls the remote method (every node)
  - `<name>` - Public router function that delegates to local or remote based on context
  """

  @doc """
  Builds the local implementation function.
  Only generated when `is_local` is true — on remote nodes the router's default
  branch goes remote (see `build_public_function/2`), nothing references a local
  implementation, so none is emitted.
  """
  def build_local_function(%{name: fn_name, args: fn_args}, fn_do, is_local) do
    local_fn_name = :"__nbapi_local_#{fn_name}"

    if is_local do
      quote do
        defp unquote(build_private_function_signature(local_fn_name, fn_args)) do
          # Transparent: the body's return value is passed through as-is (no wrapping).
          # Anything that ESCAPES the body, though, is the lib's to report: an
          # exception, a throw or an exit all become {:nebula_error, _} — the same
          # shape the worker produces remotely (execute_local_call), so a body
          # behaves identically wherever it runs.
          unquote(fn_do)
        rescue
          e ->
            require Logger
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            {:nebula_error, e}
        catch
          kind, reason ->
            require Logger
            Logger.error("defapi body #{inspect(kind)}: #{inspect(reason)}")
            {:nebula_error, {kind, reason}}
        end
      end
    else
      # Nothing: emitting a raising stub here would only exist to satisfy a
      # router branch we KNOW is dead at codegen time — the router simply
      # doesn't emit that branch on remote nodes.
      quote do
      end
    end
  end

  @doc """
  Builds the remote call function.
  This is always generated and calls the remote method via APIServer.
  """
  def build_remote_function(%{name: fn_name, args: fn_args}, serving_nodes) do
    remote_fn_name = :"__nbapi_remote_#{fn_name}"
    # Use a hygienic variable bound to this module's context — cannot clash with any
    # user-defined parameter, even one named `nebula_routing_opts`
    routing_opts_var = Macro.var(:nebula_routing_opts, __MODULE__)
    routing_opts_param = {:__inline, routing_opts_var}
    fn_args_with_routing_opts = fn_args ++ [routing_opts_param]

    quote do
      defp unquote(build_private_function_signature(remote_fn_name, fn_args_with_routing_opts)) do
        # Pass the result through untouched: the worker already returned the body's
        # raw value (unicast) or the transport layer tagged it (multicast / errors).
        # The method's CONFIGURED serving set (resolved from the defapi selector at
        # compile time, identical on every build) rides along as a hidden opt so a
        # quorum: :configured call knows its denominator without any runtime lookup.
        NebulaAPI.APIServer.call_remote_method(
          __MODULE__,
          unquote(build_remote_function_call(fn_name, fn_args)),
          Keyword.put_new(
            unquote(routing_opts_var),
            :__method_configured_nodes,
            unquote(serving_nodes)
          )
        )
      rescue
        # Programming errors (bad call opts, validated up front by
        # call_remote_method) must crash loud at the call site — only genuine
        # runtime failures melt into {:nebula_error, _}.
        e in ArgumentError -> reraise(e, __STACKTRACE__)
        e -> {:nebula_error, e}
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

    # Default behavior (no routing context, no routing opts): local if compiled
    # local, remote otherwise. is_local is known at codegen time, so the router
    # emits ONE default branch instead of a `cond` whose outcome is predetermined
    # — no dead branch, and no raising __nbapi_local_* stub to keep a dead
    # reference compilable on remote nodes.
    default_call =
      if is_local do
        quote do
          # A locally-resolved call consumes no routing opts, but it validates
          # them all the same when some were passed: invalid opts (bad timeout,
          # strategy/predicates without multicast) raise identically on every
          # node, instead of being silently ignored wherever the call happens
          # to resolve local. Valid-but-inapplicable opts (a timeout) stay a
          # silent no-op — same source compiles on every node. The empty-list
          # guard keeps the opt-less hot path free of any validation cost.
          if unquote(routing_opts_var) != [] do
            NebulaAPI.APIServer.validate_call_opts!(__MODULE__, unquote(routing_opts_var))
          end

          # A generic node (running as nonode@nohost, or a mismatched build booted with the
          # escape hatch) serves nothing, so even a locally-compiled body routes remotely.
          # force_remote?/0 is a node()/persistent_term check, both set once at boot.
          if NebulaAPI.APIServer.force_remote?() do
            unquote(remote_fn_name)(unquote_splicing(fn_arg_vars), unquote(routing_opts_var))
          else
            unquote(local_fn_name)(unquote_splicing(fn_arg_vars))
          end
        end
      else
        quote do
          unquote(remote_fn_name)(unquote_splicing(fn_arg_vars), unquote(routing_opts_var))
        end
      end

    quote do
      def unquote(build_function_signature(fn_name, fn_args_with_routing_opts)) do
        # Check for call context from process dictionary (set by call_on_node/call_on_nodes)
        context_selector = Process.get(:nebula_node_selector)
        context_mode = Process.get(:nebula_call_mode)
        context_opts = Process.get(:nebula_call_opts, [])

        # Merge context opts with routing opts
        merged_opts = Keyword.merge(context_opts, unquote(routing_opts_var))

        cond do
          # Explicit routing on the call itself: the INNERMOST explicit routing
          # wins. Like an inner block replaces the outer one, a call carrying
          # its own truthy node_selector:/multicast: routes itself — even
          # inside a call_on_* block, whose routing AND opts are ignored for
          # this call (merging the block's opts into the escape would poison
          # it: a block strategy: inherited by a now-unicast call would raise).
          unquote(routing_opts_var)[:node_selector] || unquote(routing_opts_var)[:multicast] ->
            unquote(remote_fn_name)(unquote_splicing(fn_arg_vars), unquote(routing_opts_var))

          # Inside a call_on_node/call_on_nodes block, and the call carries no
          # routing key of its own. The MODE is the context signal, not the
          # selector: a dynamic selector expression may evaluate to nil at
          # runtime, and that means "no restriction" (unicast: first available
          # worker; multicast: every node serving the method) — the block's
          # opts must still apply. A routing key PRESENT but nil/false on the
          # call is the opposite: it opts this call out of the block, down to
          # the default branch — inside a block, an explicit nil opts out of
          # the block's default back to the lib's default.
          not is_nil(context_mode) and
            not Keyword.has_key?(unquote(routing_opts_var), :node_selector) and
              not Keyword.has_key?(unquote(routing_opts_var), :multicast) ->
            unquote(remote_fn_name)(
              unquote_splicing(fn_arg_vars),
              Keyword.merge(merged_opts,
                node_selector: context_selector,
                multicast: context_mode == :multicast
              )
            )

          true ->
            unquote(default_call)
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

  # Private helpers (__nbapi_local_* / __nbapi_remote_*) are only ever called by
  # the public router, which always passes every argument. A default on a defp
  # would never be exercised — and the compiler warns about it in every consumer
  # module ("default values for the optional arguments ... are never used"),
  # breaking builds that use warnings_as_errors. Defaults live on the public
  # function only.
  defp build_private_function_signature(fn_name, fn_args) do
    Macro.var(fn_name, nil) |> put_elem(2, fn_args_to_vars(fn_args))
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
