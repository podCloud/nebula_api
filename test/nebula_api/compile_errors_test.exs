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

      assert_raise CompileError, ~r/mutually exclusive/, fn ->
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
  end
end
