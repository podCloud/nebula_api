defmodule NebulaAPI.AST.ParserTest do
  use ExUnit.Case, async: true

  alias NebulaAPI.AST.Parser

  # Parse from source so the AST matches what the compiler feeds the macros
  # (bare identifiers have a `nil` context, unlike `quote do: @db`).
  defp parse(src), do: src |> Code.string_to_quoted!() |> Parser.parse_nebula_ast()

  test "short node name → nodes" do
    assert %{nodes: [:db]} = parse("@db")
  end

  test "tag → tags" do
    assert %{tags: [:worker]} = parse("&worker")
  end

  test "negations" do
    assert %{not_nodes: [:backup]} = parse("!@backup")
    assert %{not_tags: [:legacy]} = parse("!&legacy")
  end

  test "full node name as an atom: @:\"node@host\"" do
    assert %{nodes: [:"worker@worker3.test"]} = parse(~s|@:"worker@worker3.test"|)
  end

  test "negated full node name (atom)" do
    assert %{not_nodes: [:"db@db.example"]} = parse(~s|!@:"db@db.example"|)
  end

  test "combined selectors in a list" do
    parsed = parse("[&db, !@backup]")
    assert parsed.tags == [:db]
    assert parsed.not_nodes == [:backup]
  end
end
