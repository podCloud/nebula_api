defmodule NebulaAPI.CompilerCheckTest do
  use ExUnit.Case, async: true

  alias NebulaAPI.CompilerCheck

  # "local on this build" is derived: self_node (from the :nebula_api opts) ∈ a method's
  # configured nodes. Fixtures mirror what `use NebulaAPI` + defapi persist.
  @self [self_node: :this@node]

  test "ok when no module has local methods (all remote on this node)" do
    attrs = [
      {Some.Store, [nebula_api: @self, nebula_configured_nodes: [{{:get, 1}, [:other@node]}]]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "ok when there are local methods and another module wired the server" do
    attrs = [
      # accumulate: true → one entry per defapi, each a single-element list
      {Some.Store,
       [
         nebula_api: @self,
         nebula_configured_nodes: [{{:get, 1}, [:this@node]}],
         nebula_configured_nodes: [{{:put, 2}, [:this@node]}]
       ]},
      {Some.Application, [nebula_api_server_wired: [true]]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "ok when the server is wired on the very module that has local methods" do
    attrs = [
      {Some.Store,
       [
         nebula_api: @self,
         nebula_configured_nodes: [{{:get, 1}, [:this@node]}],
         nebula_api_server_wired: [true]
       ]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "error lists the local-method modules when no server is wired anywhere" do
    attrs = [
      {Some.Store, [nebula_api: @self, nebula_configured_nodes: [{{:get, 1}, [:this@node]}]]},
      {Some.Other, [nebula_api: @self, nebula_configured_nodes: [{{:run, 1}, [:this@node]}]]},
      {Some.Application, []}
    ]

    assert {:error, modules} = CompilerCheck.verify(attrs)
    assert Enum.sort(modules) == [Some.Other, Some.Store]
  end
end
