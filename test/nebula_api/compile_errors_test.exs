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
      nodes = [{:"test@host", "not-a-list-or-atom"}]

      assert_raise CompileError, ~r/tags.*test@host/i, fn ->
        Config.validate_with_nodes(@parsed, nodes)
      end
    end

    test "an atom or a list of atoms stays valid" do
      assert Config.validate_with_nodes(@parsed, [{:"test@host", :db}]) == :ok
      assert Config.validate_with_nodes(@parsed, [{:"test@host", [:db, :api]}]) == :ok
    end
  end
end
