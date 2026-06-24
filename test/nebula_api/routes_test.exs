defmodule NebulaAPI.RoutesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias NebulaAPI.Routes

  test "build/2 marks each method local on its configured nodes, remote elsewhere; sorted" do
    module_methods = [
      {MyApp.Users, [{{:get, 1}, [:db@h]}, {{:list, 1}, [:db@h]}]},
      {MyApp.Jobs, [{{:transcode, 2}, [:worker@h]}]}
    ]

    nodes = [:api@h, :db@h, :worker@h]

    assert Routes.build(module_methods, nodes) == [
             %{
               module: MyApp.Jobs,
               fun: :transcode,
               arity: 2,
               nodes: %{api@h: :remote, db@h: :remote, worker@h: :local}
             },
             %{
               module: MyApp.Users,
               fun: :get,
               arity: 1,
               nodes: %{api@h: :remote, db@h: :local, worker@h: :remote}
             },
             %{
               module: MyApp.Users,
               fun: :list,
               arity: 1,
               nodes: %{api@h: :remote, db@h: :local, worker@h: :remote}
             }
           ]
  end

  test "build/2 with no modules is an empty list" do
    assert Routes.build([], [:api@h]) == []
  end

  test "render/4 draws a node rail per node and a glyph row per method" do
    rows = Routes.build([{MyApp.Users, [{{:get, 1}, [:db@h]}]}], [:api@h, :db@h])
    nodes = [{:api@h, [:api]}, {:db@h, [:db]}]

    out = Routes.render(rows, nodes, :db@h, color: false)

    assert out =~ "current node: db@h"
    # a blank line separates the scope line from the start of the graph
    assert out =~ "build: db@h\n\n/~~ api@h @api &api"
    # rail headers with name + selectors
    assert out =~ "api@h @api &api"
    assert out =~ "db@h @db &db"
    # method row: api not-local (rail |), db local (●), spaced, then the label
    assert out =~ "| ● MyApp.Users.get/1"
    assert out =~ "● local"
    # continuous rails: the "| |" line sits directly above the first method row, no blank
    assert out =~ "| |\n| ● MyApp.Users.get/1"
  end

  test "render flags a current node that isn't in the configured topology" do
    rows = Routes.build([{M, [{{:f, 0}, [:a@h]}]}], [:a@h, :b@h])
    out = Routes.render(rows, [{:a@h, []}, {:b@h, []}], :observer@h, color: false)

    assert out =~ "current node observer@h is not in the configured topology"
    # the note sits before the blank line that opens the graph
    assert out =~ "configured topology)\n\n/~~ a@h"
  end

  test "render/4 with no rows says so" do
    assert Routes.render([], [{:api@h, [:api]}], :api@h, color: false) =~
             "no defapi methods found"
  end

  test "print/1 renders the given modules to stdout" do
    out =
      capture_io(fn ->
        Routes.print(
          modules: [{MyApp.Users, [{{:get, 1}, [:db@h]}]}],
          nodes: [{:api@h, [:api]}, {:db@h, [:db]}],
          current_node: :db@h,
          color: false
        )
      end)

    assert out =~ "MyApp.Users.get/1"
    assert out =~ "● local"
  end

  test "print/1 sort: :name orders by function name across modules" do
    modules = [
      {MyApp.B, [{{:aaa, 0}, [:n@h]}]},
      {MyApp.A, [{{:zzz, 0}, [:n@h]}]}
    ]

    out =
      capture_io(fn ->
        Routes.print(
          modules: modules,
          nodes: [{:n@h, []}],
          current_node: :n@h,
          color: false,
          sort: :name
        )
      end)

    lines = String.split(out, "\n")

    assert Enum.find_index(lines, &(&1 =~ "MyApp.B.aaa/0")) <
             Enum.find_index(lines, &(&1 =~ "MyApp.A.zzz/0"))
  end

  test "build_available/4 classifies serving nodes by liveness, relative to current" do
    rows =
      Routes.build([{M, [{{:f, 0}, [:a@h, :b@h, :c@h]}]}], [:a@h, :b@h, :c@h, :d@h])

    # current = a (local); b configured-local but DOWN; c configured-local + worker; d not served.
    out = Routes.build_available(rows, [:a@h, :c@h], %{{M, {:f, 0}} => [:c@h]}, :a@h)

    assert [
             %{
               nodes: %{
                 a@h: :local,
                 b@h: :node_unavailable,
                 c@h: :remote_available,
                 d@h: :not_served
               }
             }
           ] = out
  end

  test "build_available/4 reports :unknown for everything when it can't observe the cluster (offline)" do
    rows = Routes.build([{M, [{{:f, 0}, [:a@h, :b@h]}]}], [:a@h, :b@h])

    # current = a@h, but nothing is connected (e.g. the task runs as nonode@nohost and `current`
    # is only the config self_node fallback). We can't observe anything → assert nothing.
    out = Routes.build_available(rows, [], %{{M, {:f, 0}} => []}, :a@h)

    assert [%{nodes: %{a@h: :unknown, b@h: :unknown}}] = out
  end

  test "render available legend lists the unknown glyph; offline renders rails not X" do
    rows = [%{module: M, fun: :f, arity: 0, nodes: %{a@h: :unknown, b@h: :unknown}}]

    out = Routes.render(rows, [{:a@h, []}, {:b@h, []}], :a@h, color: false, available: true)

    assert out =~ "| unknown"
    assert out =~ "| | M.f/0"
  end

  test "render shows the available glyphs ● ∆ x X" do
    rows = [
      %{
        module: M,
        fun: :f,
        arity: 0,
        nodes: %{
          a@h: :local,
          b@h: :node_unavailable,
          c@h: :remote_available,
          e@h: :worker_unavailable
        }
      }
    ]

    out =
      Routes.render(rows, [{:a@h, []}, {:b@h, []}, {:c@h, []}, {:e@h, []}], :a@h, color: false)

    assert out =~ "● X ∆ x M.f/0"
  end

  test "print/1 sort: :locality orders by local-node count desc, then module" do
    modules = [
      {MyApp.One, [{{:a, 0}, [:n1@h]}]},
      {MyApp.Three, [{{:c, 0}, [:n1@h, :n2@h, :n3@h]}]},
      {MyApp.Two, [{{:b, 0}, [:n1@h, :n2@h]}]}
    ]

    out =
      capture_io(fn ->
        Routes.print(
          modules: modules,
          nodes: [{:n1@h, []}, {:n2@h, []}, {:n3@h, []}],
          current_node: :n1@h,
          color: false,
          sort: :locality
        )
      end)

    lines = String.split(out, "\n")
    i3 = Enum.find_index(lines, &(&1 =~ "MyApp.Three.c/0"))
    i2 = Enum.find_index(lines, &(&1 =~ "MyApp.Two.b/0"))
    i1 = Enum.find_index(lines, &(&1 =~ "MyApp.One.a/0"))

    assert i3 < i2 and i2 < i1
  end
end
