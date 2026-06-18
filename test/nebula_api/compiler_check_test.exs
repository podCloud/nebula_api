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

  test "warns when the server is wired but the app has no defapi methods at all" do
    attrs = [
      {Some.Application, [nebula_api_server_wired: [true]]}
    ]

    assert CompilerCheck.verify(attrs) == {:warn, :server_without_methods}
  end

  test "does NOT warn when the server is wired and the app has defapi (even if all remote here)" do
    # youpod-style build: the app has defapi methods, but none are local on this node.
    # The server legitimately starts no workers here — that is not a smell.
    attrs = [
      {Some.Store, [nebula_api: @self, nebula_configured_nodes: [{{:get, 1}, [:other@node]}]]},
      {Some.Application, [nebula_api_server_wired: [true]]}
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
