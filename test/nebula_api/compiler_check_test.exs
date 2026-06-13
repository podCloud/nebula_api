defmodule NebulaAPI.CompilerCheckTest do
  use ExUnit.Case, async: true

  alias NebulaAPI.CompilerCheck

  test "ok when no module has local methods (all remote on this node)" do
    attrs = [
      {Some.Store, [nebula_local_api_methods: [], nebula_remote_api_methods: [{:get, 1}]]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "ok when there are local methods and another module wired the server" do
    attrs = [
      # accumulate: true → one entry per defapi, each a single-element list
      {Some.Store,
       [nebula_local_api_methods: [{:get, 1}], nebula_local_api_methods: [{:put, 2}]]},
      {Some.Application, [nebula_api_server_wired: [true]]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "ok when the server is wired on the very module that has local methods" do
    attrs = [
      {Some.Store, [nebula_local_api_methods: [{:get, 1}], nebula_api_server_wired: [true]]}
    ]

    assert CompilerCheck.verify(attrs) == :ok
  end

  test "error lists the local-method modules when no server is wired anywhere" do
    attrs = [
      {Some.Store, [nebula_local_api_methods: [{:get, 1}]]},
      {Some.Other, [nebula_local_api_methods: [{:run, 1}]]},
      {Some.Application, []}
    ]

    assert {:error, modules} = CompilerCheck.verify(attrs)
    assert Enum.sort(modules) == [Some.Other, Some.Store]
  end
end
