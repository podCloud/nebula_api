defmodule NebulaAPI.ConfigTest do
  use ExUnit.Case, async: true

  alias NebulaAPI.Config

  @nodes [
    {:nebula@host1, :db},
    {:storage@host2, :storage},
    {:search@host3, [:db, :search]},
    {:full@host4, [:db, :storage, :search]}
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

      assert :nebula@host1 in names
      assert :search@host3 in names
      assert :full@host4 in names
      refute :storage@host2 in names
    end

    test "keeps only nodes carrying ALL requested tags (AND semantics)" do
      result = Config.nodes_for_tags(@nodes, [:db, :search])
      names = node_names(result)

      # has [:db, :search]
      assert :search@host3 in names
      # has [:db, :storage, :search]
      assert :full@host4 in names
      # only :db (atom) — missing :search
      refute :nebula@host1 in names
      # only :storage
      refute :storage@host2 in names
    end

    test "three tags keeps only the node that has all three" do
      result = Config.nodes_for_tags(@nodes, [:db, :storage, :search])
      names = node_names(result)

      assert names == [:full@host4]
    end

    test "returns empty on empty node list" do
      assert Config.nodes_for_tags([], [:db]) == []
    end

    test "accepts single atom instead of list" do
      result = Config.nodes_for_tags(@nodes, :storage)
      names = node_names(result)

      assert :storage@host2 in names
      assert :full@host4 in names
      refute :nebula@host1 in names
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

      refute :nebula@host1 in names
      assert :storage@host2 in names
      refute :search@host3 in names
      refute :full@host4 in names
    end

    test "excludes list-tagged nodes with any overlap" do
      result = Config.nodes_for_not_tags(@nodes, [:search])
      names = node_names(result)

      assert :nebula@host1 in names
      assert :storage@host2 in names
      refute :search@host3 in names
      refute :full@host4 in names
    end

    test "accepts single atom instead of list" do
      result = Config.nodes_for_not_tags(@nodes, :storage)
      names = node_names(result)

      refute :storage@host2 in names
      refute :full@host4 in names
      assert :nebula@host1 in names
      assert :search@host3 in names
    end

    test "excludes nodes matching any of multiple exclusion tags" do
      result = Config.nodes_for_not_tags(@nodes, [:db, :storage])
      names = node_names(result)

      refute :nebula@host1 in names
      refute :storage@host2 in names
      refute :search@host3 in names
      refute :full@host4 in names
      assert result == []
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
      result = Config.nodes_for_nodes_names(@nodes, [:nebula@host1])
      assert length(result) == 1
      assert elem(hd(result), 0) == :nebula@host1
    end

    test "filters by short name (before @)" do
      result = Config.nodes_for_nodes_names(@nodes, [:nebula])
      assert length(result) == 1
      assert elem(hd(result), 0) == :nebula@host1
    end

    test "filters multiple names" do
      result = Config.nodes_for_nodes_names(@nodes, [:nebula, :storage])
      names = node_names(result)

      assert :nebula@host1 in names
      assert :storage@host2 in names
      assert length(result) == 2
    end

    test "mixes short and full names" do
      result = Config.nodes_for_nodes_names(@nodes, [:nebula, :storage@host2])
      names = node_names(result)

      assert :nebula@host1 in names
      assert :storage@host2 in names
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
      result = Config.nodes_for_not_nodes_names(@nodes, [:nebula@host1])
      names = node_names(result)

      refute :nebula@host1 in names
      assert length(result) == 3
    end

    test "excludes by short name" do
      result = Config.nodes_for_not_nodes_names(@nodes, [:nebula])
      names = node_names(result)

      refute :nebula@host1 in names
      assert length(result) == 3
    end

    test "excludes multiple nodes" do
      result = Config.nodes_for_not_nodes_names(@nodes, [:nebula, :storage])
      names = node_names(result)

      refute :nebula@host1 in names
      refute :storage@host2 in names
      assert length(result) == 2
    end

    test "mixes short and full names for exclusion" do
      result = Config.nodes_for_not_nodes_names(@nodes, [:nebula, :storage@host2])
      names = node_names(result)

      refute :nebula@host1 in names
      refute :storage@host2 in names
      assert :search@host3 in names
      assert :full@host4 in names
    end
  end

  # ============================================================================
  # validate_with_nodes
  # ============================================================================

  describe "validate_with_nodes/2" do
    @valid_config %{tags: [:db], not_tags: [], nodes: [], not_nodes: []}

    test "returns :ok with valid tags" do
      assert Config.validate_with_nodes(@valid_config, @nodes) == :ok
    end

    test "returns :ok with valid nodes" do
      config = %{tags: [], not_tags: [], nodes: [:nebula], not_nodes: []}
      assert Config.validate_with_nodes(config, @nodes) == :ok
    end

    test "returns :ok with valid full node name" do
      config = %{tags: [], not_tags: [], nodes: [:nebula@host1], not_nodes: []}
      assert Config.validate_with_nodes(config, @nodes) == :ok
    end

    test "raises CompileError for unknown tag" do
      config = %{tags: [:nonexistent], not_tags: [], nodes: [], not_nodes: []}

      assert_raise CompileError, fn ->
        Config.validate_with_nodes(config, @nodes)
      end
    end

    test "raises CompileError for unknown not_tag" do
      config = %{tags: [], not_tags: [:nonexistent], nodes: [], not_nodes: []}

      assert_raise CompileError, fn ->
        Config.validate_with_nodes(config, @nodes)
      end
    end

    test "raises CompileError for unknown node" do
      config = %{tags: [], not_tags: [], nodes: [:unknown_node], not_nodes: []}

      assert_raise CompileError, fn ->
        Config.validate_with_nodes(config, @nodes)
      end
    end

    test "raises CompileError for unknown not_node" do
      config = %{tags: [], not_tags: [], nodes: [], not_nodes: [:unknown_node]}

      assert_raise CompileError, fn ->
        Config.validate_with_nodes(config, @nodes)
      end
    end

    test "returns :ok with all empty lists" do
      config = %{tags: [], not_tags: [], nodes: [], not_nodes: []}
      assert Config.validate_with_nodes(config, @nodes) == :ok
    end
  end

  defp node_names(nodes), do: Enum.map(nodes, &elem(&1, 0))
end
