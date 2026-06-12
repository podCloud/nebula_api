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
                   call_on_node: 1,
                   call_on_node: 2,
                   call_on_node: 3,
                   call_on_nodes: 1,
                   call_on_nodes: 2,
                   call_on_nodes: 3,
                   call_on_all_nodes: 1,
                   call_on_all_nodes: 2
                 ]
               )
             )
    end
  end

  @doc """
  Defines an API method with node targeting.

  The method is compiled either as a local implementation or a remote stub
  depending on whether the current node matches the target nodes.

  ## Node Selectors

  - `@node_name` - Specific node
  - `&tag` - Nodes with tag
  - `!@node_name` or `!&tag` - Negation
  - `[...]` - List of selectors
  - `:*` - ALL nodes (local implementation on every node)

  ## Examples

      defapi [@api], get_user(id) do
        Repo.get(User, id)
      end

      defapi [&db, !@worker], find_podcast(slug) do
        MyApp.Repo.find_one(:db, "records", %{identifier: slug})
      end

      defapi :*, node_health_data() do
        # Available on ALL nodes, each returns its own data
        collect_runtime_info()
      end
  """
  defmacro defapi(nebula_ast, fn_ast, do: do_fn) do
    parsed = nebula_ast |> NebulaAPI.AST.Parser.parse_nebula_ast()

    # If all_nodes is true, skip execution node filtering
    is_current_node =
      if parsed.all_nodes do
        true
      else
        execution_nodes = nebula_ast |> get_execution_nodes_from_nebula_ast!()

        self_node =
          case Module.get_attribute(__CALLER__.module, :nebula_api) do
            nil ->
              raise CompileError,
                description: """
                defapi used in #{inspect(__CALLER__.module)} without `use NebulaAPI`.

                Only `use NebulaAPI` registers the bookkeeping defapi needs. Use it on
                modules that define defapi endpoints — `use NebulaAPI.AST` is for
                on_nebula_nodes / call_on_* only.
                """

            opts ->
              Keyword.fetch!(opts, :self_node)
          end

        execution_nodes
        |> Keyword.keys()
        |> Enum.member?(self_node)
      end

    fundef = fn_ast |> NebulaAPI.AST.Parser.parse_fundef_ast()

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

    # Generate the defapi functions: remote + router everywhere, the local
    # implementation only on matching nodes (build_local_function emits
    # nothing elsewhere).
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

  The selector may also be a runtime expression. When it evaluates to `nil`,
  it means "no restriction": the call routes to the first available worker,
  with the block's options still applying. Distinct from that, a selector
  *function* that returns `nil` means "nothing matched" — the call fails with
  `{:nebula_error, {:no_worker_on_node, nil}}`, it never widens the target.

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

      # Options only — no selector: any available worker, with these options.
      # The semantic with_options, free of the trailing-opts positional gotcha.
      call_on_node timeout: 30_000 do
        MyModule.api_method()
      end
  """
  # Options-only form: `call_on_node timeout: 30_000 do ... end` — no selector
  # means "no restriction" (first available worker), the options apply through
  # the call context. The semantic with_options: it routes through the
  # transport with these opts, without the trailing-routing-opts positional
  # gotcha.
  defmacro call_on_node(opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_node(nil, opts, block, __CALLER__)
  end

  defmacro call_on_node(selector_or_nebula_ast, opts_or_block)

  # A literal keyword list in selector position is the options-only form too
  # (`call_on_node timeout: 100 do` parses as two arguments): a nebula selector
  # list contains @/&/! AST nodes, never {atom, value} pairs — the two shapes
  # cannot collide. [] stays an (empty, invalid) selector.
  defmacro call_on_node(selector_or_opts, do: block) do
    if opts_kwlist?(selector_or_opts) do
      do_call_on_node(nil, selector_or_opts, block, __CALLER__)
    else
      do_call_on_node(selector_or_opts, [], block, __CALLER__)
    end
  end

  defmacro call_on_node(selector_or_nebula_ast, opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_node(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defmacro call_on_node(selector_or_nebula_ast, opts, do: block) do
    do_call_on_node(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defp do_call_on_node(selector_or_nebula_ast, opts, block, caller) do
    # No validate_static_predicate_opts! here: this broader check subsumes it
    # (ANY predicate key is rejected on unicast), with the message that actually
    # explains the problem.
    if Keyword.keyword?(opts) and
         (Keyword.has_key?(opts, :success) or Keyword.has_key?(opts, :failure)) do
      raise CompileError,
        line: caller.line,
        file: caller.file,
        description:
          "success:/failure: only apply to multicast strategies :first and :quorum — " <>
            "call_on_node is unicast and would silently ignore them"
    end

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
        if old_selector do
          Process.put(:nebula_node_selector, old_selector)
        else
          Process.delete(:nebula_node_selector)
        end

        if old_mode do
          Process.put(:nebula_call_mode, old_mode)
        else
          Process.delete(:nebula_call_mode)
        end

        if old_opts do
          Process.put(:nebula_call_opts, old_opts)
        else
          Process.delete(:nebula_call_opts)
        end
      end
    end
  end

  @doc """
  Multicast call - execute API calls on multiple nodes.

  The selector can be either:
  - A Nebula AST expression (like `@api`, `&db`) - all matching nodes
  - A function that receives nodes_info map and returns a list of node atoms

  The selector may also be a runtime expression. When it evaluates to `nil`,
  it means "no restriction": the call fans out to every node serving the
  method (like `call_on_all_nodes`), with the block's options still applying.
  Distinct from that, a selector *function* that returns `nil` or `[]` means
  "nothing matched" — zero calls are made (`:all` returns `[]`, `:first`
  returns `{:nebula_error, :no_success, []}`, `:quorum` fails
  `:quorum_unreachable`); it never widens the target.

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

      # Options only — no selector: every node serving the method.
      # `call_on_all_nodes` is the named alias of this form.
      call_on_nodes strategy: :quorum, at_least: 2 do
        MyModule.api_method()
      end
  """
  # Options-only form: `call_on_nodes strategy: :quorum, at_least: 2 do ... end`
  # — no selector means "no restriction": fan out to every node serving the
  # method. `call_on_all_nodes` is the named alias of this form.
  defmacro call_on_nodes(opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_nodes(nil, opts, block, __CALLER__)
  end

  defmacro call_on_nodes(selector_or_nebula_ast, opts_or_block)

  # Same disambiguation as call_on_node/2: a literal keyword list in selector
  # position is the options-only form.
  defmacro call_on_nodes(selector_or_opts, do: block) do
    if opts_kwlist?(selector_or_opts) do
      do_call_on_nodes(nil, selector_or_opts, block, __CALLER__)
    else
      do_call_on_nodes(selector_or_opts, [], block, __CALLER__)
    end
  end

  defmacro call_on_nodes(selector_or_nebula_ast, opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_nodes(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defmacro call_on_nodes(selector_or_nebula_ast, opts, do: block) do
    do_call_on_nodes(selector_or_nebula_ast, opts, block, __CALLER__)
  end

  defp do_call_on_nodes(selector_or_nebula_ast, opts, block, caller) do
    validate_static_predicate_opts!(opts, caller)
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
        if old_selector do
          Process.put(:nebula_node_selector, old_selector)
        else
          Process.delete(:nebula_node_selector)
        end

        if old_mode do
          Process.put(:nebula_call_mode, old_mode)
        else
          Process.delete(:nebula_call_mode)
        end

        if old_opts do
          Process.put(:nebula_call_opts, old_opts)
        else
          Process.delete(:nebula_call_opts)
        end
      end
    end
  end

  @doc """
  Multicast call on all available nodes.

  Named alias of the selector-less `call_on_nodes` form: it targets every node
  serving the method (i.e. with a registered worker for it).

  ## Examples

      call_on_all_nodes do
        MyModule.api_method()
      end

      call_on_all_nodes timeout: 5000, strategy: :first do
        MyModule.api_method()
      end
  """
  defmacro call_on_all_nodes(opts_or_block)

  # Named alias of the selector-less call_on_nodes: nil selector = every node
  # serving the method. (It used to pass an explicit Map.keys/1 selector —
  # same target set, but a pointless trip through the nodes_info snapshot.)
  defmacro call_on_all_nodes(do: block) do
    do_call_on_nodes(nil, [], block, __CALLER__)
  end

  defmacro call_on_all_nodes(opts) when is_list(opts) do
    {block, opts} = Keyword.pop!(opts, :do)
    do_call_on_nodes(nil, opts, block, __CALLER__)
  end

  # `call_on_all_nodes timeout: 5_000 do ... end` parses as TWO arguments
  # (the opts list, then the block) — the README has always advertised this
  # form, but no arity-2 head existed to receive it: it never compiled.
  defmacro call_on_all_nodes(opts, do: block) when is_list(opts) do
    do_call_on_nodes(nil, opts, block, __CALLER__)
  end

  # A literal keyword list in selector position means the options-only form:
  # nebula selector lists contain @/&/!/atom AST shapes, never {atom, value}
  # pairs, so the two can never collide. [] is excluded on purpose — it stays
  # an (empty) selector list and fails compilation like it always has.
  defp opts_kwlist?(ast) do
    ast != [] and Keyword.keyword?(ast)
  end

  # The call_on_* macros only accept literal keyword lists, so conflicting
  # predicate keys are statically visible: fail at compile time, at the call
  # site, instead of at the first runtime call. Only key PRESENCE is checked —
  # values stay unevaluated AST. The runtime validation in
  # APIServer.validate_predicate_opts!/3 remains the backstop for dynamic opts
  # (generated functions' trailing routing opts, context merges).
  defp validate_static_predicate_opts!(opts, caller) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :success) and
         Keyword.has_key?(opts, :failure) do
      raise CompileError,
        line: caller.line,
        file: caller.file,
        description:
          "success: and failure: are mutually exclusive — pass one or the other, not both"
    end
  end

  # Build a selector function from either a Nebula AST expression or a function.
  # The is_nebula_ast? guard already disambiguates: @/&/!/list/:* shapes are
  # nebula selectors (a function never has these shapes), so any parse or
  # validation failure behind it IS an invalid selector — fail at compile time,
  # at the call site. Node selectors are compile-time by design; runtime
  # selection goes through a function selector.
  defp build_selector(selector_or_nebula_ast, mode, caller) do
    if is_nebula_ast?(selector_or_nebula_ast) do
      target_nodes =
        try do
          get_execution_nodes_from_nebula_ast!(selector_or_nebula_ast)
        rescue
          e in CompileError ->
            reraise %{e | line: caller.line, file: caller.file}, __STACKTRACE__
        end

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
      # It's a function, use it directly
      selector_or_nebula_ast
    end
  end

  defp is_nebula_ast?({:@, _, _}), do: true
  defp is_nebula_ast?({:&, _, _}), do: true
  defp is_nebula_ast?({:!, _, _}), do: true
  defp is_nebula_ast?(list) when is_list(list), do: true
  defp is_nebula_ast?(:*), do: true
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
