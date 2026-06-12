defmodule NebulaAPI.CompileErrorsTest do
  use ExUnit.Case

  alias NebulaAPI.AST.Parser
  alias NebulaAPI.Config

  # Build the AST the way the compiler feeds it to the macros (bare identifiers
  # carry a nil context, unlike `quote do: @db`).
  defp ast(src), do: Code.string_to_quoted!(src)

  describe "invalid selectors (M5)" do
    test "a selector that is neither @/&/!/list/:* raises a clear CompileError" do
      assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
        Parser.parse_nebula_ast(ast("42"))
      end
    end

    test "a string selector raises a clear CompileError" do
      assert_raise CompileError, ~r/invalid nebula selector/i, fn ->
        Parser.parse_nebula_ast(ast(~s|"db"|))
      end
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
    # accepted; :* says "all nodes", omitting the selector says "no
    # restriction" in call_on_*.

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
end
