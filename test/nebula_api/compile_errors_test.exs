defmodule NebulaAPI.CompileErrorsTest do
  use ExUnit.Case

  alias NebulaAPI.AST.Parser
  alias NebulaAPI.Config

  # Build the AST the way the compiler feeds it to the macros (bare identifiers
  # carry a nil context, unlike `quote do: @db`).
  defp ast(src), do: Code.string_to_quoted!(src)

  # Compile a lone call_on_* block (with a trailing `do :ok end`) inside a
  # fresh module, the way a consumer would write it.
  defp eval_block(call) do
    Code.eval_string("""
    defmodule NebulaAPI.CompileErrorsTest.Static#{System.unique_integer([:positive])} do
      use NebulaAPI.AST

      def go do
        #{call} do
          :ok
        end
      end
    end
    """)
  end

  describe "invalid selectors (M5)" do
    test "a selector that is neither @/&/!/list raises a clear CompileError" do
      assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
        Parser.parse_nebula_ast(ast("42"))
      end
    end

    test "a string selector raises a clear CompileError" do
      assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
        Parser.parse_nebula_ast(ast(~s|"db"|))
      end
    end

    test "a function selector points at call_on_* (dynamic selection has no place in defapi)" do
      # defapi/on_nebula_nodes are resolved statically; a fn lands in the
      # parser only from them (call_on_* diverts functions before parsing),
      # so the message can name the macros where dynamic selection DOES work.
      err =
        assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
          Parser.parse_nebula_ast(ast("fn _nodes_info -> :db@host end"))
        end

      assert err.description =~ "call_on_node"
    end
  end

  describe "empty selector list ([])" do
    setup do
      Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}])
      on_exit(fn -> Application.delete_env(:nebula_api, :nodes) end)
      :ok
    end

    # [] selects no node, so nothing could ever run — it used to silently
    # select every CONFIGURED node (the empty parse passed through every
    # Config filter). Now it fails the build everywhere a selector is
    # accepted. To run on every node, omit the selector entirely (defapi);
    # in call_on_*, omitting the selector means "no restriction".

    test "the parser rejects [] directly" do
      assert_raise CompileError, ~r/empty nebula selector/i, fn ->
        Parser.parse_nebula_ast(ast("[]"))
      end
    end

    test "defapi [] raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.EmptyDefapi do
        use NebulaAPI, allow_unknown_self_node: true

        defapi [], foo() do
          :ok
        end
      end
      """

      assert_raise CompileError, ~r/empty nebula selector/i, fn ->
        Code.eval_string(code)
      end
    end

    test "on_nebula_nodes [] raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.EmptyOnNodes do
        use NebulaAPI.AST

        on_nebula_nodes [] do
          def never, do: :ok
        end
      end
      """

      assert_raise CompileError, ~r/empty nebula selector/i, fn ->
        Code.eval_string(code)
      end
    end

    test "call_on_node [] raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.EmptyCallOnNode do
        use NebulaAPI.AST

        def go do
          call_on_node [] do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/empty nebula selector/i, fn ->
        Code.eval_string(code)
      end
    end

    test "call_on_nodes [] raises a clear CompileError (it used to select every configured node)" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.EmptyCallOnNodes do
        use NebulaAPI.AST

        def go do
          call_on_nodes [], strategy: :all, timeout: 100 do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/empty nebula selector/i, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "unsupported defapi signatures (M5)" do
    test "a pattern-matched argument raises a clear CompileError" do
      assert_raise CompileError, ~r/defapi.*argument/i, fn ->
        Parser.parse_fundef_ast(ast("get(%{id: id})"))
      end
    end

    test "a list-pattern argument raises a clear CompileError" do
      assert_raise CompileError, ~r/defapi.*argument/i, fn ->
        Parser.parse_fundef_ast(ast("get([h | t])"))
      end
    end

    test "a literal-atom argument raises a clear CompileError too" do
      # An atom is a pattern match like any other literal: it used to slip
      # through and compile into `def get(:fixed, opts \\\\ [])` — a router
      # whose misses crash the caller with a FunctionClauseError, while the
      # error message claimed patterns were rejected.
      assert_raise CompileError, ~r/defapi.*argument/i, fn ->
        Parser.parse_fundef_ast(ast("get(:fixed)"))
      end
    end
  end

  describe "invalid node tags in config (L5)" do
    @parsed %{tags: [:db], not_tags: [], nodes: [], not_nodes: []}

    test "tags that are neither an atom nor a list raise a clear CompileError" do
      nodes = [{:test@host, "not-a-list-or-atom"}]

      assert_raise CompileError, ~r/tags.*test@host/i, fn ->
        Config.validate_with_nodes(@parsed, nodes)
      end
    end

    test "an atom or a list of atoms stays valid" do
      assert Config.validate_with_nodes(@parsed, [{:test@host, :db}]) == :ok
      assert Config.validate_with_nodes(@parsed, [{:test@host, [:db, :api]}]) == :ok
    end
  end

  describe "defapi without `use NebulaAPI` (L1)" do
    setup do
      Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}])
      on_exit(fn -> Application.delete_env(:nebula_api, :nodes) end)
      :ok
    end

    test "using defapi from a `use NebulaAPI.AST` module raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.MissingUse do
        use NebulaAPI.AST

        defapi &db, foo() do
          :ok
        end
      end
      """

      assert_raise CompileError, ~r/use NebulaAPI/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "invalid use NebulaAPI options (R3)" do
    setup do
      Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}])
      on_exit(fn -> Application.delete_env(:nebula_api, :nodes) end)
      :ok
    end

    test "a non-positive max_concurrent_calls raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.BadMax do
        use NebulaAPI, allow_unknown_self_node: true, max_concurrent_calls: 0
      end
      """

      assert_raise CompileError, ~r/max_concurrent_calls/, fn ->
        Code.eval_string(code)
      end
    end

    test "a non-integer default_timeout raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.BadTimeout do
        use NebulaAPI, allow_unknown_self_node: true, default_timeout: :soon
      end
      """

      assert_raise CompileError, ~r/default_timeout/, fn ->
        Code.eval_string(code)
      end
    end

    test "valid values compile" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.GoodOpts do
        use NebulaAPI,
          allow_unknown_self_node: true,
          max_concurrent_calls: 10,
          default_timeout: 15_000
      end
      """

      assert {_, _} = Code.eval_string(code)
    end
  end

  describe "success: + failure: in call_on_* macros (R4)" do
    # The macros only accept literal keyword lists, so the conflicting keys are
    # statically visible — the error belongs at compile time, not at first call.
    # Function selectors keep these tests independent from the :nodes config.
    test "passing both to call_on_nodes raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.BothPredicates do
        use NebulaAPI.AST

        def go do
          call_on_nodes fn nodes_info -> Map.keys(nodes_info) end,
            strategy: :first,
            success: fn value -> value == :ok end,
            failure: fn value -> value != :ok end do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/mutually exclusive/, fn ->
        Code.eval_string(code)
      end
    end

    test "passing both to call_on_node raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.BothPredicatesUni do
        use NebulaAPI.AST

        def go do
          call_on_node fn nodes_info -> List.first(Map.keys(nodes_info)) end,
            success: fn value -> value == :ok end,
            failure: fn value -> value != :ok end do
            :ok
          end
        end
      end
      """

      # Unicast rejects ANY predicate key — both keys or one, same refusal,
      # with the message that explains the actual problem.
      assert_raise CompileError, ~r/only apply to multicast/, fn ->
        Code.eval_string(code)
      end
    end

    test "one predicate alone still compiles" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.OnePredicate do
        use NebulaAPI.AST

        def go do
          call_on_nodes fn nodes_info -> Map.keys(nodes_info) end,
            strategy: :first,
            success: fn value -> value == :ok end do
            :ok
          end
        end
      end
      """

      assert {_, _} = Code.eval_string(code)
    end

    test "success: on call_on_node raises a clear CompileError (unicast never consumes it)" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.UnicastPredicate do
        use NebulaAPI.AST

        def go do
          call_on_node fn nodes_info -> List.first(Map.keys(nodes_info)) end,
            success: fn value -> value == :ok end do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/only apply to multicast/, fn ->
        Code.eval_string(code)
      end
    end
  end

  describe "statically invalid call_on_* options" do
    # The macros receive literal keyword lists: any option the mode can never
    # consume, unknown key, malformed literal value or impossible combination
    # is visible at the call site — fail the build there. Dynamic values keep
    # the runtime ArgumentError backstop (see generated_functions_test).

    test "strategy: on call_on_node raises (unicast can never consume it)" do
      assert_raise CompileError, ~r/only apply to multicast/, fn ->
        eval_block("call_on_node strategy: :all, timeout: 100")
      end
    end

    test "at_least: on call_on_node raises" do
      assert_raise CompileError, ~r/only apply to multicast/, fn ->
        eval_block("call_on_node at_least: 2")
      end
    end

    test "an unknown key on call_on_node raises" do
      assert_raise CompileError, ~r/unknown option/, fn ->
        eval_block("call_on_node timout: 100")
      end
    end

    test "an unknown key on call_on_nodes raises" do
      assert_raise CompileError, ~r/unknown option/, fn ->
        eval_block("call_on_nodes quorum_count: 2, strategy: :quorum")
      end
    end

    test "a literal timeout: :infinity raises at compile time" do
      assert_raise CompileError, ~r/timeout/, fn ->
        eval_block("call_on_node timeout: :infinity")
      end
    end

    test "a literal typo'd strategy raises at compile time" do
      assert_raise CompileError, ~r/strategy/, fn ->
        eval_block("call_on_nodes strategy: :qourum")
      end
    end

    test "a literal non-positive at_least raises at compile time" do
      assert_raise CompileError, ~r/at_least/, fn ->
        eval_block("call_on_nodes strategy: :quorum, at_least: 0")
      end
    end

    test "a literal non-function success:/failure: raises at compile time" do
      # No literal (atom, number, binary) can ever be a 1-arity function —
      # the runtime backstop kept catching it, but it is statically visible.
      assert_raise CompileError, ~r/success: must be a 1-arity function/, fn ->
        eval_block("call_on_nodes strategy: :first, success: :not_a_fun")
      end

      assert_raise CompileError, ~r/failure: must be a 1-arity function/, fn ->
        eval_block(~s|call_on_nodes strategy: :quorum, failure: "nope"|)
      end
    end

    test "success: nil stays 'not set' — the block compiles" do
      assert {_, _} = eval_block("call_on_nodes strategy: :first, success: nil")
    end

    test "at_least: without strategy: :quorum raises (the block resolves to :all)" do
      assert_raise CompileError, ~r/at_least.*:quorum/s, fn ->
        eval_block("call_on_nodes at_least: 2")
      end

      assert_raise CompileError, ~r/at_least.*:quorum/s, fn ->
        eval_block("call_on_nodes strategy: :first, at_least: 2")
      end
    end

    test "a predicate with a statically-:all strategy raises" do
      assert_raise CompileError, ~r/only apply to multicast strategies/, fn ->
        eval_block("call_on_nodes success: fn v -> v == :ok end")
      end

      assert_raise CompileError, ~r/only apply to multicast strategies/, fn ->
        eval_block("call_on_nodes strategy: :all, failure: fn v -> v != :ok end")
      end
    end

    test "a dynamic strategy is refused at compile time (must be a literal atom)" do
      # strategy: must be statically one of :all/:first/:quorum — a runtime value
      # is refused, so the quorum/at_least combination is always decidable.
      code = """
      defmodule NebulaAPI.CompileErrorsTest.DynamicStrategy do
        use NebulaAPI.AST

        def go(maybe_strategy) do
          call_on_nodes strategy: maybe_strategy, at_least: 2, timeout: 100 do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/strategy: must be one of.*literally/s, fn ->
        Code.eval_string(code)
      end
    end

    test "a valid quorum combination still compiles" do
      assert {_, _} =
               eval_block(
                 "call_on_nodes strategy: :quorum, at_least: 2, " <>
                   "success: fn v -> v == :ok end, timeout: 100"
               )
    end
  end

  describe "invalid selectors in call_on_* (M10)" do
    setup do
      Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}])
      on_exit(fn -> Application.delete_env(:nebula_api, :nodes) end)
      :ok
    end

    test "a typo'd node name in call_on_node raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.TypoNode do
        use NebulaAPI.AST

        def go do
          call_on_node @nonexistent do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/unknown nodes/i, fn ->
        Code.eval_string(code)
      end
    end

    test "an unknown tag in call_on_nodes raises a clear CompileError" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.TypoTag do
        use NebulaAPI.AST

        def go do
          call_on_nodes &nosuchtag do
            :ok
          end
        end
      end
      """

      assert_raise CompileError, ~r/unknown tags/i, fn ->
        Code.eval_string(code)
      end
    end

    test "a list of dynamic expressions is rejected at compile time (selectors are compile-time)" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.DynamicList do
        use NebulaAPI.AST

        def go(some_var) do
          call_on_nodes [some_var] do
            :ok
          end
        end
      end
      """

      # Never worked: it used to fail with a runtime badfun. Node selectors have
      # always been compile-time; a runtime selection goes through a function.
      assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
        Code.eval_string(code)
      end
    end

    test "a function selector still compiles and stays a runtime concern" do
      code = """
      defmodule NebulaAPI.CompileErrorsTest.FunSelector do
        use NebulaAPI.AST

        def go do
          call_on_node fn nodes_info -> List.first(Map.keys(nodes_info)) end do
            :ok
          end
        end
      end
      """

      assert {_, _} = Code.eval_string(code)
    end
  end

  describe "call_on_* require literal selector and options (no dynamic structure)" do
    defp eval_mod(body) do
      Code.eval_string("""
      defmodule NebulaAPI.CompileErrorsTest.Dyn#{System.unique_integer([:positive])} do
        use NebulaAPI.AST
        #{body}
      end
      """)
    end

    test "a variable selector is refused at compile time" do
      assert_raise CompileError, ~r/written literally/, fn ->
        eval_mod("def go(sel), do: (call_on_nodes sel, strategy: :all do :ok end)")
      end
    end

    test "a whole-opts variable is refused at compile time" do
      assert_raise CompileError, ~r/literal keyword list/, fn ->
        eval_mod("def go(opts), do: (call_on_node nil, opts do :ok end)")
      end
    end

    test "a dynamic strategy: is refused at compile time" do
      assert_raise CompileError, ~r/strategy: must be one of.*literally/s, fn ->
        eval_mod("def go(s), do: (call_on_nodes strategy: s do :ok end)")
      end
    end

    test "a dynamic quorum: is refused at compile time" do
      assert_raise CompileError, ~r/quorum: must be one of.*literally/s, fn ->
        eval_mod("def go(q), do: (call_on_nodes strategy: :quorum, quorum: q do :ok end)")
      end
    end
  end
end
