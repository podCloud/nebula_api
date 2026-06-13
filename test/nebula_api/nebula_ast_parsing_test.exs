defmodule NebulaAPI.NebulaAstParsingTest do
  @moduledoc """
  Source-of-truth for the CANONICAL NebulaAPI selector syntax.

  Selectors are **juxtaposed by a space** — never separated by commas, never
  wrapped in a list. This is the identity of the library; it is what keeps the
  call sites readable:

      defapi &db !@backup, find(id) do ... end          # ✅ canonical
      on_nebula_nodes &db !@backup do ... end            # ✅ canonical
      call_on_nodes &worker !@backup, strategy: :all do  # ✅ canonical

  The bracketed list form still compiles, but it is **not** the canonical
  syntax — every macro has a final test pinning it as a tolerated alternative
  so nobody "fixes" the docs back to brackets again.

      defapi [&db, !@backup], find(id) do ... end        # ⚠️ tolerated, NOT canonical

  Each test COMPILES a module from source (`Code.compile_string/1`) and inspects
  the finished code, so the syntax is verified end to end, not just parsed.
  """
  use ExUnit.Case

  setup_all do
    prev = Application.get_env(:nebula_api, :nodes)

    Application.put_env(:nebula_api, :nodes, [
      {:test@host, [:db, :api, :cache]},
      {:backup@host, [:db]},
      {:worker@host, [:worker]}
    ])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:nebula_api, :nodes, prev),
        else: Application.delete_env(:nebula_api, :nodes)
    end)

    :ok
  end

  # Compile a `use NebulaAPI` module from source. self_node is test@host, which
  # carries [:db, :api, :cache] — so &db / &api / &cache / !&worker / !@backup
  # all resolve LOCAL, and the generated body is callable without a live cluster.
  # Raises CompileError (failing the test loudly) if the macro rejects the form.
  defp compile_module!(name, body) do
    src = """
    defmodule #{name} do
      use NebulaAPI, allow_unknown_self_node: true, self_node: :"test@host"
      #{body}
    end
    """

    [{mod, _bin}] = Code.compile_string(src)
    mod
  end

  # ====================================================================
  # defapi — selector is followed by a signature
  # ====================================================================

  describe "defapi (canonical, space-juxtaposed)" do
    test "one selector" do
      mod =
        compile_module!("DefapiOne", """
        defapi &db, get(id) do
          {:got, id}
        end
        """)

      assert function_exported?(mod, :get, 1)
      assert mod.get(42) == {:got, 42}
    end

    test "two selectors juxtaposed by a space, with a negation" do
      mod =
        compile_module!("DefapiTwo", """
        defapi &db !@backup, get(id) do
          {:got, id}
        end
        """)

      # test@host has :db and is not @backup → body is LOCAL here
      assert mod.get(7) == {:got, 7}
    end

    test "three selectors juxtaposed by spaces" do
      mod =
        compile_module!("DefapiThree", """
        defapi &db &api !@backup, get(id) do
          {:got, id}
        end
        """)

      assert mod.get(1) == {:got, 1}
    end

    test "inline do: — single selector" do
      mod =
        compile_module!("DefapiInlineOne", """
        defapi &db, get(id), do: {:got, id}
        """)

      assert mod.get(5) == {:got, 5}
    end

    test "inline do: — two selectors juxtaposed by a space" do
      mod =
        compile_module!("DefapiInlineTwo", """
        defapi &db !@backup, get(id), do: {:got, id}
        """)

      assert mod.get(6) == {:got, 6}
    end

    test "inline do: — three selectors juxtaposed by spaces" do
      mod =
        compile_module!("DefapiInlineThree", """
        defapi &db &api !@backup, get(id), do: {:got, id}
        """)

      assert mod.get(7) == {:got, 7}
    end

    test "a single negation selector" do
      mod =
        compile_module!("DefapiNeg", """
        defapi !&worker, get(id) do
          {:got, id}
        end
        """)

      # test@host has no :worker tag → matches !&worker → local
      assert mod.get(9) == {:got, 9}
    end

    test ":* — every node gets a local copy" do
      mod =
        compile_module!("DefapiStar", """
        defapi :*, ping() do
          :pong
        end
        """)

      assert mod.ping() == :pong
    end

    test "[list] form still compiles — but it is NOT the canonical syntax" do
      mod =
        compile_module!("DefapiList", """
        defapi [&db, !@backup], get(id) do
          {:got, id}
        end
        """)

      assert mod.get(3) == {:got, 3}
    end
  end

  # ====================================================================
  # on_nebula_nodes — selector is the only thing before the block
  # ====================================================================

  describe "on_nebula_nodes (canonical, space-juxtaposed)" do
    test "one selector — block kept on a matching node" do
      mod =
        compile_module!("OnNodesOne", """
        on_nebula_nodes &db do
          def here?, do: true
        end
        """)

      assert function_exported?(mod, :here?, 0)
      assert mod.here?() == true
    end

    test "two selectors juxtaposed by a space, with a negation" do
      mod =
        compile_module!("OnNodesTwo", """
        on_nebula_nodes &db !@backup do
          def here?, do: true
        end
        """)

      assert mod.here?() == true
    end

    test "else branch is kept on a non-matching node" do
      mod =
        compile_module!("OnNodesElse", """
        on_nebula_nodes &worker do
          def role, do: :worker
        else
          def role, do: :not_worker
        end
        """)

      # test@host is not a :worker → else branch compiled
      assert mod.role() == :not_worker
    end

    test "[list] form still compiles — but it is NOT the canonical syntax" do
      mod =
        compile_module!("OnNodesList", """
        on_nebula_nodes [&db, !@backup] do
          def here?, do: true
        end
        """)

      assert mod.here?() == true
    end
  end

  # ====================================================================
  # call_on_node — unicast, optional trailing opts
  # ====================================================================

  describe "call_on_node (canonical, space-juxtaposed)" do
    test "one selector, block with no extra args" do
      mod =
        compile_module!("CallNodeOne", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node @test do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "two selectors juxtaposed by a space" do
      mod =
        compile_module!("CallNodeTwo", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node @test !@backup do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "selector plus trailing opts (timeout)" do
      mod =
        compile_module!("CallNodeOpts", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node @test, timeout: 100 do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "[list] form still compiles — but it is NOT the canonical syntax" do
      mod =
        compile_module!("CallNodeList", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node [@test, !@backup] do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end
  end

  # ====================================================================
  # call_on_nodes — multicast, optional trailing opts
  # ====================================================================

  describe "call_on_nodes (canonical, space-juxtaposed)" do
    test "one selector" do
      mod =
        compile_module!("CallNodesOne", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_nodes &db do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "two selectors juxtaposed by a space" do
      mod =
        compile_module!("CallNodesTwo", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_nodes &db !@backup do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "selectors plus trailing opts (strategy / timeout)" do
      mod =
        compile_module!("CallNodesOpts", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_nodes &db !@backup, strategy: :all, timeout: 100 do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "[list] form still compiles — but it is NOT the canonical syntax" do
      mod =
        compile_module!("CallNodesList", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_nodes [&db, !@backup] do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end
  end

  # ====================================================================
  # call_on_all_nodes — no selector
  # ====================================================================

  describe "call_on_all_nodes (no selector)" do
    test "block with no opts" do
      mod =
        compile_module!("CallAllOne", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_all_nodes do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "block with trailing opts" do
      mod =
        compile_module!("CallAllOpts", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_all_nodes timeout: 100, strategy: :first do payload() end)
        """)

      assert function_exported?(mod, :run, 0)
    end
  end

  # ====================================================================
  # inline `do:` / `else:` — must work for every macro, mono and multi
  # ====================================================================

  describe "on_nebula_nodes — inline do:/else:" do
    test "mono selector, inline do:" do
      mod =
        compile_module!("OnInlineMono", """
        on_nebula_nodes &db, do: def(here?, do: true)
        """)

      assert mod.here?() == true
    end

    test "two selectors, inline do:" do
      mod =
        compile_module!("OnInlineTwo", """
        on_nebula_nodes &db !@backup, do: def(here?, do: true)
        """)

      assert mod.here?() == true
    end

    test "two selectors, inline do: + else: (else taken on a non-matching node)" do
      mod =
        compile_module!("OnInlineElse", """
        on_nebula_nodes &worker !@backup, do: def(role, do: :worker), else: def(role, do: :other)
        """)

      # test@host is not a :worker → the else branch compiles
      assert mod.role() == :other
    end

    test "two selectors, block do/else" do
      mod =
        compile_module!("OnBlockElse", """
        on_nebula_nodes &worker !@backup do
          def role, do: :worker
        else
          def role, do: :other
        end
        """)

      assert mod.role() == :other
    end
  end

  describe "call_on_node / call_on_nodes — inline do:" do
    test "call_on_node — mono selector, inline do:" do
      mod =
        compile_module!("CallNodeInlineMono", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node @test, do: payload())
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "call_on_node — two selectors, inline do:" do
      mod =
        compile_module!("CallNodeInlineTwo", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_node @test !@backup, do: payload())
        """)

      assert function_exported?(mod, :run, 0)
    end

    test "call_on_nodes — two selectors + opts, inline do:" do
      mod =
        compile_module!("CallNodesInlineTwo", """
        defapi &db, payload(), do: :data

        def run, do: (call_on_nodes &db !@backup, strategy: :all, do: payload())
        """)

      assert function_exported?(mod, :run, 0)
    end
  end
end
