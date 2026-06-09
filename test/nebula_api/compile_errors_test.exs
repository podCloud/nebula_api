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
end
