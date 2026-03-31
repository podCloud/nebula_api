defmodule NebulaAPI.ConfigTest do
  use ExUnit.Case, async: true

  alias NebulaAPI.Config

  @nodes [
    {:"nebula@host1", :db},
    {:"storage@host2", :storage},
    {:"search@host3", [:db, :search]},
    {:"full@host4", [:db, :storage, :search]}
  ]

  # ============================================================================
  # nodes_for_tags
  # ============================================================================

  describe "nodes_for_tags/2" do
    test "returns all nodes when tags is empty" do
      assert Config.nodes_for_tags(@nodes, []) == @nodes
    end

    test "filters atom-tagged node by single tag" do
      result = Config.nodes_for_tags(@nodes, [:db])
      names = node_names(result)

      assert :"nebula@host1" in names
      assert :"search@host3" in names
      assert :"full@host4" in names
      refute :"storage@host2" in names
    end

    test "filters list-tagged nodes requiring ALL tags" do
      result = Config.nodes_for_tags(@nodes, [:db, :search])
      names = node_names(result)

      assert :"search@host3" in names
      assert :"full@host4" in names
      refute :"nebula@host1" in names
      refute :"storage@host2" in names
    end

    test "three tags narrows to only the node with all three" do
      result = Config.nodes_for_tags(@nodes, [:db, :storage, :search])
      names = node_names(result)

      assert names == [:"full@host4"]
    end

    test "accepts single atom instead of list" do
      result = Config.nodes_for_tags(@nodes, :storage)
      names = node_names(result)

      assert :"storage@host2" in names
      assert :"full@host4" in names
      refute :"nebula@host1" in names
    end

    test "returns empty when no node matches" do
      assert Config.nodes_for_tags(@nodes, [:nonexistent]) == []
    end
  end

  # ============================================================================
  # nodes_for_not_tags
  # ============================================================================

  describe "nodes_for_not_tags/2" do
    test "returns all nodes when exclusion list is empty" do
      assert Config.nodes_for_not_tags(@nodes, []) == @nodes
    end

    test "excludes atom-tagged nodes" do
      result = Config.nodes_for_not_tags(@nodes, [:db])
      names = node_names(result)

      refute :"nebula@host1" in names
      assert :"storage@host2" in names
      refute :"search@host3" in names
      refute :"full@host4" in names
    end

    test "excludes list-tagged nodes with any overlap" do
      result = Config.nodes_for_not_tags(@nodes, [:search])
      names = node_names(result)

      assert :"nebula@host1" in names
      assert :"storage@host2" in names
      refute :"search@host3" in names
      refute :"full@host4" in names
    end

    test "accepts single atom instead of list" do
      result = Config.nodes_for_not_tags(@nodes, :storage)
      names = node_names(result)

      refute :"storage@host2" in names
      refute :"full@host4" in names
      assert :"nebula@host1" in names
      assert :"search@host3" in names
    end

    test "returns all when excluding a nonexistent tag" do
      assert Config.nodes_for_not_tags(@nodes, [:nonexistent]) == @nodes
    end
  end

  # ============================================================================
  # nodes_for_nodes_names
  # ============================================================================

  describe "nodes_for_nodes_names/2" do
    test "returns all nodes when names is empty" do
      assert Config.nodes_for_nodes_names(@nodes, []) == @nodes
    end

    test "filters by full node name" do
      result = Config.nodes_for_nodes_names(@nodes, [:"nebula@host1"])
      assert length(result) == 1
      assert elem(hd(result), 0) == :"nebula@host1"
    end

    test "filters by short name (before @)" do
      result = Config.nodes_for_nodes_names(@nodes, [:nebula])
      assert length(result) == 1
      assert elem(hd(result), 0) == :"nebula@host1"
    end

    test "filters multiple names" do
      result = Config.nodes_for_nodes_names(@nodes, [:nebula, :storage])
      names = node_names(result)

      assert :"nebula@host1" in names
      assert :"storage@host2" in names
      assert length(result) == 2
    end
  end

  # ============================================================================
  # nodes_for_not_nodes_names
  # ============================================================================

  describe "nodes_for_not_nodes_names/2" do
    test "returns all nodes when exclusion is empty" do
      assert Config.nodes_for_not_nodes_names(@nodes, []) == @nodes
    end

    test "excludes by full node name" do
      result = Config.nodes_for_not_nodes_names(@nodes, [:"nebula@host1"])
      names = node_names(result)

      refute :"nebula@host1" in names
      assert length(result) == 3
    end

    test "excludes by short name" do
      result = Config.nodes_for_not_nodes_names(@nodes, [:nebula])
      names = node_names(result)

      refute :"nebula@host1" in names
      assert length(result) == 3
    end
  end

  defp node_names(nodes), do: Enum.map(nodes, &elem(&1, 0))
end
