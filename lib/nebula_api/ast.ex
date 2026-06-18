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
                   defapi: 1,
                   defapi: 2,
                   defapi: 3,
                   on_nebula_nodes: 1,
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

  Selectors are juxtaposed by a space (never commas, never a `[list]`):

  - `@node` - specific node (short or full name)
  - `&tag` - nodes with the tag
  - `!@node` / `!&tag` - negation
  - `@a &b` - combine by juxtaposition (e.g. `@worker &gpu`)
  - *(no selector)* - the body runs on every node (local everywhere)

  ## Examples

      defapi @api, get_user(id) do
        Repo.get(User, id)
      end

      defapi &db !@worker, find_podcast(slug) do
        MyApp.Repo.find_one(:db, "records", %{identifier: slug})
      end

      # No selector → available on every node, each returns its own data.
      defapi get_node_health() do
        collect_runtime_info()
      end
  """
  # Canonical multi-selector with an INLINE `do:` — `defapi &db !@backup, get(id), do: ...`.
  # Paren-less parsing folds the continuation selector, the signature AND the `[do: ...]`
  # all into the chain, so the call arrives at arity 1. peel_chain/1 lifts the whole
  # absorbed tail back out: [signature, [do: body]].
  defmacro defapi(selectors_signature_and_do) do
    case peel_chain(selectors_signature_and_do) do
      {nebula_ast, [fn_ast, [do: do_fn]]} ->
        expand_defapi(nebula_ast, fn_ast, do_fn, __CALLER__)

      _ ->
        raise CompileError,
          line: __CALLER__.line,
          file: __CALLER__.file,
          description: """
          Malformed defapi. Expected: defapi <selectors>, name(args) do ... end
          (or the inline `, do:` form). Selectors are juxtaposed by a space, e.g.
          `defapi &db !@backup, get(id) do ... end`.
          """
    end
  end

  # Arity 2 covers two shapes:
  #   * NO selector — `defapi name(args) do ... end` — the body runs on EVERY node
  #     (the signature is arg0; there is no selector at all).
  #   * a `do ... end` BLOCK multi-selector — `defapi &db !@backup, get(id) do` — where the
  #     signature got folded into the selector chain (peel_chain/1 lifts it back out).
  defmacro defapi(selector_or_signature, do: do_fn) do
    if selector_head?(selector_or_signature) do
      case peel_chain(selector_or_signature) do
        {nebula_ast, [fn_ast]} ->
          expand_defapi(nebula_ast, fn_ast, do_fn, __CALLER__)

        {_clean, _} ->
          raise CompileError,
            line: __CALLER__.line,
            file: __CALLER__.file,
            description: """
            defapi is missing a function signature.

            Expected: defapi <selectors>, name(args) do ... end — or omit the selectors
            entirely to run on every node (`defapi name(args) do ... end`). Selectors are
            juxtaposed by a space.
            """
      end
    else
      # No selector at all → the body is local on every node.
      expand_defapi(:all, selector_or_signature, do_fn, __CALLER__)
    end
  end

  # Single selector (or the tolerated [list] form): selector and signature are
  # already two distinct arguments — nothing absorbed, nothing to peel.
  defmacro defapi(nebula_ast, fn_ast, do: do_fn) do
    expand_defapi(nebula_ast, fn_ast, do_fn, __CALLER__)
  end

  defp expand_defapi(nebula_ast, fn_ast, do_fn, caller) do
    is_current_node = defapi_local?(nebula_ast, caller)

    # The CONFIGURED nodes that serve this method (the selector resolved over the
    # topology, or every node for the no-selector form). Baked into the remote stub
    # so a quorum: :configured call knows its denominator — same on every build.
    serving_nodes = defapi_serving_nodes(nebula_ast)

    fundef = fn_ast |> NebulaAPI.AST.Parser.parse_fundef_ast()

    # Persist the method's configured serving set — the single source of truth, queryable
    # at runtime (APIServer.configured_nodes/2) on every node (the stub carries it
    # everywhere). local/remote on a node are derived from it (node ∈ configured ⇒ local),
    # so no separate local/remote method attributes are kept.
    caller.module
    |> Module.put_attribute(
      :nebula_configured_nodes,
      {{fundef.name, fundef.args_count}, serving_nodes}
    )

    # Generate the defapi functions: remote + router everywhere, the local
    # implementation only on matching nodes (build_local_function emits
    # nothing elsewhere).
    quote do
      unquote(NebulaAPI.AST.Builder.build_local_function(fundef, do_fn, is_current_node))
      unquote(NebulaAPI.AST.Builder.build_remote_function(fundef, serving_nodes))
      unquote(NebulaAPI.AST.Builder.build_public_function(fundef, is_current_node))
    end
  rescue
    e in CompileError ->
      raise %{e | line: caller.line, file: caller.file}
  end

  # The configured node names that serve this method: the no-selector form runs
  # everywhere, otherwise the selector resolved over the topology. Compile-time and
  # config-derived, so identical on every build.
  defp defapi_serving_nodes(:all), do: NebulaAPI.Config.nodes() |> Keyword.keys()

  defp defapi_serving_nodes(nebula_ast) do
    nebula_ast
    |> get_execution_nodes_from_nebula_ast!()
    |> Keyword.keys()
  end

  # `:all` is the no-selector form — the body is local on every node.
  defp defapi_local?(:all, caller) do
    # Still require `use NebulaAPI` for the bookkeeping defapi relies on.
    _ = fetch_self_node!(caller)
    true
  end

  defp defapi_local?(nebula_ast, caller) do
    self_node = fetch_self_node!(caller)

    nebula_ast
    |> get_execution_nodes_from_nebula_ast!()
    |> Keyword.keys()
    |> Enum.member?(self_node)
  end

  defp fetch_self_node!(caller) do
    case Module.get_attribute(caller.module, :nebula_api) do
      nil ->
        raise CompileError,
          description: """
          defapi used in #{inspect(caller.module)} without `use NebulaAPI`.

          Only `use NebulaAPI` registers the bookkeeping defapi needs. Use it on
          modules that define defapi endpoints — `use NebulaAPI.AST` is for
          on_nebula_nodes / call_on_* only.
          """

      opts ->
        Keyword.fetch!(opts, :self_node)
    end
  end

  # A selector chain head: `&tag`, `@node`, `!...`, or a `[...]` list. Anything else
  # in selector position (a `name(args)` signature) means the no-selector form.
  defp selector_head?({op, _, _}) when op in [:&, :@, :!], do: true
  defp selector_head?(list) when is_list(list), do: true
  defp selector_head?(_), do: false

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
    expand_on_nebula_nodes(nebula_ast, opts, __CALLER__)
  end

  # Inline form: `on_nebula_nodes &db !@backup, do: ..., else: ...` — the multi-selector
  # chain, the do: AND the else: all fold into one arity-1 arg. peel_chain/1 lifts the
  # do:/else: kwlist back out.
  defmacro on_nebula_nodes(selectors_and_opts) do
    case peel_chain(selectors_and_opts) do
      {nebula_ast, [opts]} when is_list(opts) ->
        expand_on_nebula_nodes(nebula_ast, opts, __CALLER__)

      _ ->
        raise CompileError,
          line: __CALLER__.line,
          file: __CALLER__.file,
          description: """
          Malformed on_nebula_nodes. Expected: on_nebula_nodes <selectors> do ... [else ...] end
          (or the inline `, do:` / `, else:` form). Selectors are juxtaposed by a space.
          """
    end
  end

  defp expand_on_nebula_nodes(nebula_ast, opts, caller) do
    execution_nodes = nebula_ast |> get_execution_nodes_from_nebula_ast!()

    self_node =
      case caller.module do
        nil -> node()
        mod -> Module.get_attribute(mod, :nebula_api, []) |> Keyword.get(:self_node, node())
      end

    is_current_node =
      execution_nodes
      |> Keyword.keys()
      |> Enum.member?(self_node)

    if(is_current_node, do: Keyword.get(opts, :do), else: Keyword.get(opts, :else))
  rescue
    e in CompileError ->
      raise %{e | line: caller.line, file: caller.file}
  end

  @doc """
  Unicast call - execute API calls on a specific node.

  The selector must be written literally at the call site — one of:
  - A Nebula AST expression (like `@api`, `&db`)
  - A literal function that receives the nodes_info map and returns a single node atom
  - Omitted (the options-only form, or a literal `nil`) — "no restriction": the call routes
    to the first available worker, with the block's options still applying.

  A variable or computed selector is a compile error (branch in Elixir and write a separate
  `call_on_*` per case). Distinct from omitting it, a selector *function* that returns `nil`
  means "nothing matched" — the call fails with `{:nebula_error, {:no_worker_on_node, nil}}`,
  it never widens the target.

  Inside the block, the innermost explicit routing wins: a call carrying its
  own truthy `node_selector:`/`multicast:` trailing opts routes itself (the
  block's routing and options are ignored for that call), and a routing key
  explicitly set to `nil` opts the call out of the block, back to default
  routing.

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

  # Inline `do:` with a multi-selector chain — `call_on_node @a !@b, do: ...` folds the
  # chain, the opts AND the do into one arity-1, non-list arg (a plain opts list is the
  # options-only clause above). Lift them back out.
  defmacro call_on_node(selectors_opts_and_do) when not is_list(selectors_opts_and_do) do
    {selector, opts, block} = unwrap_inline_chain_call!(selectors_opts_and_do, __CALLER__)
    do_call_on_node(selector, opts, block, __CALLER__)
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
    {selector_or_nebula_ast, opts} = absorb_trailing_opts(selector_or_nebula_ast, opts)
    validate_literal_selector!(selector_or_nebula_ast, caller)
    validate_static_opts!(opts, :unicast, caller)
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

  The selector must be written literally at the call site — one of:
  - A Nebula AST expression (like `@api`, `&db`) - all matching nodes
  - A literal function that receives the nodes_info map and returns a list of node atoms
  - Omitted (the options-only form, or a literal `nil`) — "no restriction": the call fans out
    to every node serving the method (like `call_on_all_nodes`), with the block's options
    still applying.

  A variable or computed selector is a compile error (branch in Elixir and write a separate
  `call_on_*` per case). Distinct from omitting it, a selector *function* that returns `nil`
  or `[]` means "nothing matched" — zero calls are made (`:all` returns `[]`, `:first`
  returns `{:nebula_error, :no_success, []}`, `:quorum` fails `:quorum_unreachable`); it never
  widens the target.

  Inside the block, the innermost explicit routing wins: a call carrying its
  own truthy `node_selector:`/`multicast:` trailing opts routes itself (the
  block's routing and options are ignored for that call), and a routing key
  explicitly set to `nil` or `false` opts the call out of the block, back to
  default routing — `MyMod.f(x, multicast: false)` inside a multicast block
  is a plain default call.

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

  # Inline `do:` with a multi-selector chain — `call_on_nodes @a !@b, strategy: :all, do: ...`
  # folds the chain, the opts AND the do into one arity-1, non-list arg.
  defmacro call_on_nodes(selectors_opts_and_do) when not is_list(selectors_opts_and_do) do
    {selector, opts, block} = unwrap_inline_chain_call!(selectors_opts_and_do, __CALLER__)
    do_call_on_nodes(selector, opts, block, __CALLER__)
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
    {selector_or_nebula_ast, opts} = absorb_trailing_opts(selector_or_nebula_ast, opts)
    validate_literal_selector!(selector_or_nebula_ast, caller)
    validate_static_opts!(opts, :multicast, caller)
    opts = enforce_fn_selector_quorum!(selector_or_nebula_ast, opts, caller)
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
  # an (empty) selector, which the parser rejects at compile time: [] selects
  # no node, "no restriction" is spelled by omitting the selector.
  defp opts_kwlist?(ast) do
    ast != [] and Keyword.keyword?(ast)
  end

  @unicast_block_opts [:timeout]
  @multicast_only_opts [:strategy, :at_least, :success, :failure, :quorum]
  @multicast_block_opts @unicast_block_opts ++ @multicast_only_opts
  @valid_strategies [:all, :first, :quorum]
  @valid_quorum_modes [:configured, :available]

  # A literal `fn … end` selector picks its set dynamically, so quorum: :configured
  # (a majority of a STATIC configured set) has nothing to count — refuse it at compile
  # time, with no silent downgrade: the call must say how to count, quorum: :available
  # or at_least: n. Only an anonymous-function literal is decided here: a nil/omitted selector
  # is the no-restriction form (the method's own configured set), a variable defers to
  # runtime (it may evaluate to nil), and an @/&/! selector is static.
  defp enforce_fn_selector_quorum!(selector, opts, caller) do
    if match?({:fn, _, _}, selector) and static_value(opts, :strategy) == {:literal, :quorum} and
         Keyword.get(opts, :quorum) != :available and not opt_present?(opts, :at_least) do
      compile_error!(
        caller,
        "a function selector with strategy: :quorum can't use the :configured quorum (the " <>
          "default) — a runtime function has no static configured set to take a majority of. " <>
          "Pass quorum: :available, or at_least: n."
      )
    end

    opts
  end

  # Compile-time validation of the call_on_* block options. The macros receive
  # literal keyword lists, so anything statically decidable fails the build at
  # the call site: a key the mode can never consume, an unknown key, a
  # malformed literal value, a combination no runtime value could make valid.
  # Values are still unevaluated AST, though — only plain literals are
  # decidable here; a variable or computed expression falls through to the
  # runtime backstop, APIServer.validate_call_opts!/2, where the
  # nil-means-"not set" convention applies. A whole-opts variable
  # (`call_on_node sel, my_opts do`) skips this entirely for the same reason.
  defp validate_static_opts!(opts, mode, caller) do
    unless Keyword.keyword?(opts) do
      compile_error!(
        caller,
        "call_on_* options must be a literal keyword list (e.g. strategy: :quorum, " <>
          "timeout: 100) — a variable or computed opts list isn't allowed. Individual " <>
          "values may be dynamic (timeout: t), but the option keys must be visible at " <>
          "compile time. Branch in Elixir and write a separate call_on_* per case."
      )
    end

    keys = opts |> Keyword.keys() |> Enum.uniq()
    validate_static_keys!(keys, mode, caller)
    validate_static_values!(opts, caller)
    if mode == :multicast, do: validate_static_combos!(opts, caller)

    :ok
  end

  defp validate_static_keys!(keys, :unicast, caller) do
    case Enum.filter(keys, &(&1 in @multicast_only_opts)) do
      [] ->
        :ok

      invalid ->
        compile_error!(
          caller,
          "#{format_opt_keys(invalid)} only apply to multicast calls " <>
            "(call_on_nodes / call_on_all_nodes) — call_on_node is unicast and " <>
            "would silently ignore them"
        )
    end

    validate_unknown_keys!(keys, @unicast_block_opts, "call_on_node", caller)
  end

  defp validate_static_keys!(keys, :multicast, caller) do
    validate_unknown_keys!(
      keys,
      @multicast_block_opts,
      "call_on_nodes / call_on_all_nodes",
      caller
    )
  end

  defp validate_unknown_keys!(keys, allowed, macro_label, caller) do
    case keys -- allowed do
      [] ->
        :ok

      unknown ->
        compile_error!(
          caller,
          "unknown option(s) for #{macro_label}: #{format_opt_keys(unknown)} — " <>
            "accepted options are #{format_opt_keys(allowed)}"
        )
    end
  end

  # A literal value is decidable at compile time; nil keeps meaning "not set".
  defp static_value(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :absent
      {:ok, v} when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v) -> {:literal, v}
      {:ok, _expr} -> :dynamic
    end
  end

  defp validate_static_values!(opts, caller) do
    case static_value(opts, :timeout) do
      {:literal, t} when not is_nil(t) and not (is_integer(t) and t > 0) ->
        compile_error!(
          caller,
          "timeout: must be a positive integer in milliseconds, got: #{inspect(t)}" <>
            if(t == :infinity,
              do: " — :infinity is not supported; use a large finite budget instead",
              else: ""
            )
        )

      _ ->
        :ok
    end

    case static_value(opts, :strategy) do
      :dynamic ->
        compile_error!(
          caller,
          "strategy: must be one of #{inspect(@valid_strategies)} given literally — " <>
            "a runtime value isn't allowed (branch in Elixir and write a separate call_on_*)"
        )

      {:literal, s} when not is_nil(s) and s not in @valid_strategies ->
        compile_error!(
          caller,
          "strategy: must be one of #{inspect(@valid_strategies)}, got: #{inspect(s)}"
        )

      _ ->
        :ok
    end

    case static_value(opts, :at_least) do
      {:literal, n} when not is_nil(n) and not (is_integer(n) and n > 0) ->
        compile_error!(
          caller,
          "at_least: must be a positive integer (a number of workers), got: #{inspect(n)}"
        )

      _ ->
        :ok
    end

    case static_value(opts, :quorum) do
      :dynamic ->
        compile_error!(
          caller,
          "quorum: must be one of #{inspect(@valid_quorum_modes)} given literally — " <>
            "a runtime value isn't allowed (branch in Elixir and write a separate call_on_*)"
        )

      {:literal, m} when not is_nil(m) and m not in @valid_quorum_modes ->
        compile_error!(
          caller,
          "quorum: must be one of #{inspect(@valid_quorum_modes)}, got: #{inspect(m)}"
        )

      _ ->
        :ok
    end

    # No literal can ever be a 1-arity function, so a non-nil literal
    # predicate is always wrong; nil keeps meaning "not set". Real predicates
    # (fn / & captures) are AST, classified :dynamic — the runtime backstop
    # validates their form.
    for key <- [:success, :failure] do
      case static_value(opts, key) do
        {:literal, v} when not is_nil(v) ->
          compile_error!(caller, "#{key}: must be a 1-arity function, got: #{inspect(v)}")

        _ ->
          :ok
      end
    end

    :ok
  end

  defp validate_static_combos!(opts, caller) do
    if opt_present?(opts, :success) and opt_present?(opts, :failure) do
      compile_error!(
        caller,
        "success: and failure: are mutually exclusive — pass one or the other, not both"
      )
    end

    # The strategy this block resolves to, when statically known: an absent or
    # nil strategy IS known — it resolves to the :all default. Only a dynamic
    # value defers the combination checks to runtime.
    strategy_static =
      case static_value(opts, :strategy) do
        :absent -> :all
        {:literal, nil} -> :all
        {:literal, s} -> s
        :dynamic -> :unknown
      end

    if opt_present?(opts, :at_least) and strategy_static not in [:quorum, :unknown] do
      compile_error!(
        caller,
        "at_least: only applies to the :quorum strategy — this block resolves to " <>
          "#{inspect(strategy_static)}"
      )
    end

    if opt_present?(opts, :quorum) and strategy_static not in [:quorum, :unknown] do
      compile_error!(
        caller,
        "quorum: only applies to the :quorum strategy — this block resolves to " <>
          "#{inspect(strategy_static)}"
      )
    end

    if opt_present?(opts, :quorum) and opt_present?(opts, :at_least) do
      compile_error!(
        caller,
        "at_least: and quorum: are mutually exclusive — at_least: asks for a precise " <>
          "count, quorum: for a majority of a set"
      )
    end

    if (opt_present?(opts, :success) or opt_present?(opts, :failure)) and
         strategy_static not in [:first, :quorum, :unknown] do
      compile_error!(
        caller,
        "success:/failure: only apply to multicast strategies :first and :quorum — " <>
          "this block resolves to #{inspect(strategy_static)} and would silently " <>
          "ignore them"
      )
    end
  end

  # Present for combination purposes: the key is there with anything but a
  # literal nil (nil means "not set", a dynamic value may consume the option).
  defp opt_present?(opts, key) do
    static_value(opts, key) not in [:absent, {:literal, nil}]
  end

  defp format_opt_keys(keys), do: Enum.map_join(keys, ", ", &"#{&1}:")

  defp compile_error!(caller, description) do
    raise CompileError, line: caller.line, file: caller.file, description: description
  end

  # --- Canonical space-juxtaposed selectors ----------------------------------
  #
  # The canonical NebulaAPI syntax juxtaposes selectors with a SPACE, never a
  # bracketed list:
  #
  #     defapi &db !@backup, get(id) do ... end
  #     call_on_nodes &db !@backup, strategy: :all do ... end
  #
  # Elixir parses a space-juxtaposed chain followed by a trailing comma argument
  # (the defapi signature, or the call_on_* opts) by folding that trailing
  # argument INTO the deepest selector call:
  #
  #     &db !@backup, get(id)            ==>  &db(!@backup, get(id))
  #     &db !@backup, strategy: :all     ==>  &db(!@backup, [strategy: :all])
  #
  # So the chain arrives with the signature/opts (and, in the inline `do:` form, the
  # `[do: ...]` too) absorbed as extra args of its deepest selector. peel_chain/1 walks
  # the chain and lifts that whole absorbed tail back out, returning
  # {pure_selector_ast, absorbed_list} — [] when nothing was absorbed. The pure chain is
  # exactly what the single-selector / bracketed forms already feed the parser. A pure
  # selector identifier carries `nil` or a single continuation arg, so any extra args on
  # a selector identifier are the absorbed tail.
  defp peel_chain({op, meta, [inner]}) when op in [:&, :@, :!] do
    {clean, absorbed} = peel_chain(inner)
    {{op, meta, [clean]}, absorbed}
  end

  defp peel_chain({name, meta, ctx}) when is_atom(ctx) do
    {{name, meta, ctx}, []}
  end

  defp peel_chain({name, meta, [cont | absorbed]}) do
    {clean_cont, deeper} = peel_chain(cont)
    {{name, meta, [clean_cont]}, absorbed ++ deeper}
  end

  # Anything that isn't a selector chain head (a [list], a function selector,
  # a variable, a bare opts list, a no-selector signature): nothing to peel.
  defp peel_chain(other), do: {other, []}

  # Only peel actual selector chain heads (@/&/!); leave function selectors,
  # lists and opts-only lists untouched.
  defp maybe_peel_chain({op, _, _} = selector) when op in [:&, :@, :!], do: peel_chain(selector)
  defp maybe_peel_chain(selector), do: {selector, []}

  # For call_on_* : lift any opts the canonical syntax folded into the selector
  # back out and merge them ahead of opts passed the long way (the explicit ones
  # win on conflict — they can't realistically both be present, but be safe).
  defp absorb_trailing_opts(selector, opts) do
    case maybe_peel_chain(selector) do
      {clean, [absorbed_opts]} when is_list(absorbed_opts) ->
        {clean, Keyword.merge(absorbed_opts, opts)}

      {clean, _} ->
        {clean, opts}
    end
  end

  # call_on_* inline form: `call_on_node @a !@b, opt: v, do: block` folds the selector
  # chain, the opts and the do into one arity-1 arg. Peel the chain, then split the do
  # block out of the absorbed opts. Returns {clean_selector, opts, block}.
  defp unwrap_inline_chain_call!(ast, caller) do
    with {selector, [opts]} when is_list(opts) <- peel_chain(ast),
         {block, rest} when not is_nil(block) <- Keyword.pop(opts, :do) do
      {selector, rest, block}
    else
      _ ->
        raise CompileError,
          line: caller.line,
          file: caller.file,
          description: """
          Malformed call_on_* call. Expected a do block, e.g.
          `call_on_nodes &db !@backup, strategy: :all do ... end` (selectors juxtaposed by a space).
          """
    end
  end

  # Selectors must be written literally at the call site: a static nebula
  # selector (@/&/!/list), a literal `fn`, or omitted (nil). A variable or any
  # computed expression is refused — branch in plain Elixir and write a separate
  # call_on_* per case. Keeping the selector statically visible is what lets the
  # quorum denominator be decided at compile time (see enforce_fn_selector_quorum!).
  defp validate_literal_selector!(selector, caller) do
    cond do
      is_nil(selector) ->
        :ok

      # A function capture (`&fun/1`) shares the `&` head with a `&tag` selector but
      # wraps a `/` (the arity) — catch it here with a clear message instead of letting
      # it mangle through the tag parser into a confusing "unknown tag". A real selector
      # function is written as a literal `fn nodes_info -> ... end`.
      match?({:&, _, [{:/, _, _}]}, selector) ->
        compile_error!(
          caller,
          "a function capture (&fun/1) isn't a valid call_on_* selector — write the " <>
            "selector function as a literal `fn nodes_info -> ... end`, or use a " <>
            "&tag / @node selector."
        )

      is_nebula_ast?(selector) ->
        :ok

      match?({:fn, _, _}, selector) ->
        :ok

      true ->
        compile_error!(
          caller,
          "call_on_* selectors must be written literally (a &tag/@node selector, a literal " <>
            "fn, or none) — a variable or computed selector isn't allowed. Branch in Elixir " <>
            "and write a separate call_on_* per case."
        )
    end
  end

  # Build a selector function from either a Nebula AST expression or a function.
  # The is_nebula_ast? guard already disambiguates: @/&/!/list shapes are
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
          # Return the CONFIGURED matching set, not just the present ones. Routing
          # still intersects with the live workers downstream (call_selected_workers),
          # so who actually gets called is unchanged — but a quorum: :configured call
          # can now count the configured set (its denominator), connected or not.
          quote do
            fn _nodes_info -> unquote(target_node_names) end
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
