defmodule NebulaAPI.GeneratedFunctionsTest do
  use ExUnit.Case

  setup_all do
    Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}])
    on_exit(fn -> Application.delete_env(:nebula_api, :nodes) end)

    Code.eval_string("""
    defmodule NebulaAPI.GeneratedFunctionsTest.RemoteMod do
      use NebulaAPI, allow_unknown_self_node: true

      defapi &db, foo() do
        :ok
      end
    end
    """)

    Code.eval_string("""
    defmodule NebulaAPI.GeneratedFunctionsTest.LocalKindsMod do
      use NebulaAPI, allow_unknown_self_node: true, self_node: :"test@host"

      defapi &db, boom_throw() do
        throw(:ball)
      end

      defapi &db, boom_exit() do
        exit(:bye)
      end

      defapi &db, boom_raise() do
        raise "kaboom"
      end
    end
    """)

    Code.eval_string("""
    defmodule NebulaAPI.GeneratedFunctionsTest.LocalOptsMod do
      use NebulaAPI, allow_unknown_self_node: true, self_node: :"test@host"

      defapi &db, echo(x) do
        x
      end

      # Reserved for the served-worker tests: only those register a worker for
      # it, so the no-worker assertions on echo/1 stay deterministic.
      defapi &db, echo_served(x) do
        x
      end
    end
    """)

    # A LOCALLY-compiled defapi wrapped in call_on_* blocks whose selector is a
    # runtime expression — the value (nil included) is only known at call time.
    Code.eval_string("""
    defmodule NebulaAPI.GeneratedFunctionsTest.CtxCaller do
      use NebulaAPI.AST

      alias NebulaAPI.GeneratedFunctionsTest.LocalOptsMod

      def unicast(sel) do
        call_on_node sel, timeout: 100 do
          LocalOptsMod.echo(41)
        end
      end

      # The bad timeout arrives through a VARIABLE: a literal one is rejected
      # at compile time (see compile_errors_test), a dynamic one must keep
      # raising through the runtime backstop.
      def unicast_bad_timeout(sel, t) do
        call_on_node sel, timeout: t do
          LocalOptsMod.echo(41)
        end
      end

      def quorum(sel) do
        call_on_nodes sel, strategy: :quorum, at_least: 2, timeout: 100 do
          LocalOptsMod.echo(41)
        end
      end

      # Options-only forms: no selector argument at all.
      def unicast_opts_only do
        call_on_node timeout: 100 do
          LocalOptsMod.echo(41)
        end
      end

      # Same variable trick as unicast_bad_timeout/2, options-only form.
      def unicast_opts_only_bad_timeout(t) do
        call_on_node timeout: t do
          LocalOptsMod.echo(41)
        end
      end

      def quorum_opts_only do
        call_on_nodes strategy: :quorum, at_least: 2, timeout: 100 do
          LocalOptsMod.echo(41)
        end
      end

      def all_opts_only do
        call_on_nodes strategy: :all, timeout: 500 do
          LocalOptsMod.echo_served(41)
        end
      end

      def all_nodes_alias do
        call_on_all_nodes timeout: 500 do
          LocalOptsMod.echo_served(41)
        end
      end

      # A whole-opts variable is invisible to the static validation: the
      # runtime backstop must still reject what it carries.
      def unicast_dynamic_opts(opts) do
        call_on_node nil, opts do
          LocalOptsMod.echo(41)
        end
      end

      # Nested blocks: the inner one REPLACES the whole context (selector,
      # mode, opts — no merge); the outer one takes back over on exit.
      def nested_blocks do
        call_on_nodes strategy: :quorum, at_least: 2, timeout: 100 do
          inner =
            call_on_node timeout: 50 do
              LocalOptsMod.echo(1)
            end

          {inner, LocalOptsMod.echo(2)}
        end
      end

      # The outer context must survive an exception inside the inner block.
      def nested_blocks_inner_raise do
        call_on_nodes strategy: :quorum, at_least: 2, timeout: 100 do
          try do
            call_on_node timeout: 50 do
              raise "boom"
            end
          rescue
            _ -> :ok
          end

          LocalOptsMod.echo(3)
        end
      end

      # The context lives in the process dictionary: a process spawned inside
      # the block does NOT inherit it — its defapi calls route by default.
      def spawned_task_escapes_block do
        call_on_nodes strategy: :quorum, at_least: 2, timeout: 100 do
          Task.async(fn -> LocalOptsMod.echo(4) end) |> Task.await()
        end
      end

      # Trailing routing opts on a call INSIDE a block: the innermost explicit
      # routing wins (a truthy node_selector:/multicast: routes the call
      # itself, block routing AND opts ignored), and a routing key set to nil
      # opts the call out of the block, back to the default branch.
      def block_call_overrides do
        call_on_nodes strategy: :quorum, at_least: 2, timeout: 100 do
          LocalOptsMod.echo(7, node_selector: fn _nodes_info -> :"phantom@host" end)
        end
      end

      def block_call_multicast_escape do
        call_on_node fn _nodes_info -> node() end, timeout: 100 do
          LocalOptsMod.echo(10, multicast: true, strategy: :all, timeout: 100)
        end
      end

      def block_call_cancels do
        call_on_node fn _nodes_info -> node() end, timeout: 100 do
          LocalOptsMod.echo(8, node_selector: nil)
        end
      end

      def block_call_multicast_cancel do
        call_on_nodes strategy: :all, timeout: 100 do
          LocalOptsMod.echo(12, multicast: false)
        end
      end
    end
    """)

    :ok
  end

  describe "local/remote symmetry for non-exception escapes (M11)" do
    import ExUnit.CaptureLog

    alias NebulaAPI.GeneratedFunctionsTest.LocalKindsMod

    test "a throwing body returns {:nebula_error, {:throw, value}} locally, like remotely" do
      capture_log(fn ->
        assert LocalKindsMod.boom_throw() == {:nebula_error, {:throw, :ball}}
      end)
    end

    test "an exiting body returns {:nebula_error, {:exit, reason}} locally, like remotely" do
      capture_log(fn ->
        assert LocalKindsMod.boom_exit() == {:nebula_error, {:exit, :bye}}
      end)
    end

    test "a raising body still returns {:nebula_error, exception} (unchanged shape)" do
      capture_log(fn ->
        assert {:nebula_error, %RuntimeError{message: "kaboom"}} = LocalKindsMod.boom_raise()
      end)
    end
  end

  describe "defapi codegen is warning-free (I4)" do
    test "compiling local and remote defapi modules emits no compiler warning" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.eval_string("""
          defmodule NebulaAPI.GeneratedFunctionsTest.WarningFreeLocal do
            use NebulaAPI, allow_unknown_self_node: true, self_node: :"test@host"

            defapi &db, w_add(a, b) do
              a + b
            end

            defapi &db, w_list(filters \\\\ []) do
              filters
            end
          end

          defmodule NebulaAPI.GeneratedFunctionsTest.WarningFreeRemote do
            use NebulaAPI, allow_unknown_self_node: true

            defapi &db, w_get(id) do
              id
            end
          end
          """)
        end)

      refute stderr =~ "never used"
      refute stderr =~ "warning:"
    end
  end

  describe "locally-resolved calls validate routing opts too (M1)" do
    alias NebulaAPI.GeneratedFunctionsTest.LocalOptsMod

    test "a valid-but-inapplicable opt is a silent no-op and the call stays local" do
      # No worker is registered for echo/1: if this went remote it would return
      # {:nebula_error, {:no_worker, _}} — getting the value back IS the proof
      # that the call resolved locally, opts validated then ignored.
      assert LocalOptsMod.echo(1, timeout: 100) == 1
    end

    test "no opts means no validation work, the call just runs" do
      assert LocalOptsMod.echo(2) == 2
    end

    test "strategy: without multicast raises locally, exactly like on a remote node" do
      assert_raise ArgumentError, ~r/multicast/, fn ->
        LocalOptsMod.echo(1, strategy: :quorum)
      end
    end

    test "an invalid timeout raises locally, exactly like on a remote node" do
      assert_raise ArgumentError, ~r/timeout/, fn ->
        LocalOptsMod.echo(1, timeout: :infinity)
      end
    end

    test "predicates without multicast raise locally, exactly like on a remote node" do
      assert_raise ArgumentError, ~r/multicast/, fn ->
        LocalOptsMod.echo(1, success: &match?({:ok, _}, &1))
      end
    end

    test "an unknown opt key raises locally, exactly like on a remote node" do
      assert_raise ArgumentError, ~r/unknown call option/, fn ->
        LocalOptsMod.echo(1, timout: 100)
      end
    end
  end

  describe "programming errors cross the generated stub (I2)" do
    test "an invalid success: raises ArgumentError through a defapi-generated function" do
      assert_raise ArgumentError, ~r/success: must be a 1-arity function/, fn ->
        NebulaAPI.GeneratedFunctionsTest.RemoteMod.foo(
          multicast: true,
          strategy: :first,
          success: :not_a_fun
        )
      end
    end

    test "a transport failure still comes back as {:nebula_error, _}, not a raise" do
      # No worker registered for foo/0: a genuine transport failure.
      assert {:nebula_error, {:no_worker, _}} =
               NebulaAPI.GeneratedFunctionsTest.RemoteMod.foo(timeout: 100)
    end
  end

  describe "call_on_* with a selector that evaluates to nil (no restriction)" do
    alias NebulaAPI.GeneratedFunctionsTest.CtxCaller

    # The defapi inside the blocks is compiled LOCAL and no worker is started:
    # reaching the transport ({:no_worker, ...}) is the proof that the block's
    # context was honored. Before keying the router on the context MODE, a nil
    # selector fell through to the default branch — the call ran locally and
    # every context opt was silently dropped.

    test "call_on_node nil still routes through the context, opts applied" do
      assert {:nebula_error, {:no_worker, _}} = CtxCaller.unicast(nil)
    end

    test "context opts are validated even with a nil selector" do
      assert_raise ArgumentError, ~r/timeout/, fn ->
        CtxCaller.unicast_bad_timeout(nil, :infinity)
      end
    end

    test "call_on_nodes nil multicasts to every serving node, opts applied" do
      # Zero workers serve echo/1, so a REAL multicast quorum is unreachable —
      # before the fix this returned 41: a quorum write silently degraded to a
      # local call.
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} =
               CtxCaller.quorum(nil)
    end

    test "a non-nil selector keeps its meaning" do
      target = node()

      assert {:nebula_error, {:no_worker_on_node, ^target}} =
               CtxCaller.unicast(fn _nodes_info -> target end)
    end
  end

  describe "call_on_* options-only form (no selector argument)" do
    alias NebulaAPI.GeneratedFunctionsTest.CtxCaller
    alias NebulaAPI.GeneratedFunctionsTest.LocalOptsMod

    defmodule FakeWorker do
      use GenServer
      def init(reply), do: {:ok, reply}
      def handle_call({:nebula_call, _fn_call}, _from, reply), do: {:reply, reply, reply}
    end

    defp start_fake_for(module, method, arity, reply) do
      {:ok, pid} = GenServer.start(FakeWorker, reply)
      :pg.join(:pg_nebula_api, {module, {method, arity}}, pid)
      pid
    end

    test "call_on_node with options only is a unicast through the transport" do
      # The semantic with_options: no restriction, the opts carried by the
      # context. No worker serves echo/1 → the unicast no-worker shape.
      assert {:nebula_error, {:no_worker, _}} = CtxCaller.unicast_opts_only()
    end

    test "options-only opts are validated like any call opts" do
      assert_raise ArgumentError, ~r/timeout/, fn ->
        CtxCaller.unicast_opts_only_bad_timeout(:infinity)
      end
    end

    test "a dynamic opts list still hits the runtime backstop (unknown key)" do
      # A whole-opts variable is invisible to the macro's static validation —
      # the closed-set runtime check refuses it instead of silently routing
      # with defaults.
      assert_raise ArgumentError, ~r/unknown call option/, fn ->
        CtxCaller.unicast_dynamic_opts(bogus: 1)
      end
    end

    test "call_on_nodes with options only multicasts to every serving node" do
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} =
               CtxCaller.quorum_opts_only()
    end

    test "call_on_nodes options-only collects {node, value} like call_on_all_nodes" do
      pid = start_fake_for(LocalOptsMod, :echo_served, 1, 41)

      this = node()
      assert [{^this, 41}] = CtxCaller.all_opts_only()
      # call_on_all_nodes is the named alias: same target set, same shape.
      assert [{^this, 41}] = CtxCaller.all_nodes_alias()

      GenServer.stop(pid)
    end
  end

  describe "nested call_on_* blocks" do
    alias NebulaAPI.GeneratedFunctionsTest.CtxCaller

    # echo/1 is compiled LOCAL and no worker is registered, so each routing
    # mode has a distinct, unfakeable signature: default → local → the value;
    # inner unicast → {:nebula_error, {:no_worker, _}}; outer quorum →
    # {:nebula_error, :quorum_unreachable, _}.

    test "the inner block replaces the context; the outer one takes back over on exit" do
      assert {{:nebula_error, {:no_worker, _}},
              {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}}} =
               CtxCaller.nested_blocks()

      # No context survives the outermost block (try/after restoration).
      assert Process.get(:nebula_call_mode) == nil
      assert Process.get(:nebula_call_opts) == nil
      assert Process.get(:nebula_node_selector) == nil
    end

    test "the outer context survives a raise inside the inner block" do
      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} =
               CtxCaller.nested_blocks_inner_raise()

      assert Process.get(:nebula_call_mode) == nil
    end

    test "a process spawned inside a block does not inherit the context" do
      # The context lives in the spawning process's dictionary: the Task's
      # defapi call routes by DEFAULT (local here), proving the surrounding
      # quorum block silently does not apply. Wrap the call_on_* inside the
      # task when that is what you mean.
      assert CtxCaller.spawned_task_escapes_block() == 4
    end
  end

  describe "trailing routing opts on a call inside a block (innermost routing wins)" do
    alias NebulaAPI.GeneratedFunctionsTest.CtxCaller
    alias NebulaAPI.GeneratedFunctionsTest.LocalOptsMod

    test "an explicit node_selector: on the call wins over the block, full escape" do
      # Three candidate behaviors, three distinct shapes: the old block-wins
      # gives {:nebula_error, :quorum_unreachable, _}; an escape that inherited
      # the block's opts would raise (strategy: :quorum on a unicast call);
      # the full escape routes through the call's own selector.
      assert {:nebula_error, {:no_worker_on_node, :phantom@host}} =
               CtxCaller.block_call_overrides()
    end

    test "multicast: true on the call escapes a unicast block" do
      # Block path would give {:no_worker_on_node, node()}; default local
      # would give 10; the call's own :all multicast with zero serving
      # workers gives [].
      assert CtxCaller.block_call_multicast_escape() == []
    end

    test "node_selector: nil on the call opts out of the block, back to default routing" do
      # echo/1 is compiled local with no worker: the block's fn selector would
      # yield {:no_worker_on_node, node()}; getting the value back proves the
      # call fell through to the DEFAULT branch (local), not to the transport.
      assert CtxCaller.block_call_cancels() == 8
    end

    test "multicast: false on the call opts out of a multicast block (plain default call)" do
      # The block's :all multicast with zero serving workers would give [];
      # the value back means the call ran as a plain default (local) call.
      assert CtxCaller.block_call_multicast_cancel() == 12
    end

    test "outside a block, node_selector: nil still means 'not set' (default local routing)" do
      assert LocalOptsMod.echo(11, node_selector: nil) == 11
    end
  end

  describe "defapi inside on_nebula_nodes" do
    test "the whole defapi (router included) only exists on matching nodes" do
      # Conditional compilation composes: on a non-matching node nothing is
      # generated AT ALL — no transparent RPC, calling it is an
      # UndefinedFunctionError. 'This API only exists on those nodes' is the
      # semantics; expecting transparency here is the documented footgun.
      Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}, {:other@host, [:db]}])
      on_exit(fn -> Application.put_env(:nebula_api, :nodes, [{:test@host, [:db]}]) end)

      Code.eval_string("""
      defmodule NebulaAPI.GeneratedFunctionsTest.CondApi do
        use NebulaAPI, allow_unknown_self_node: true, self_node: :"test@host"

        on_nebula_nodes @:"test@host" do
          defapi &db, present_here() do
            :ok
          end
        end

        on_nebula_nodes @:"other@host" do
          defapi &db, absent_here() do
            :ok
          end
        end
      end
      """)

      alias NebulaAPI.GeneratedFunctionsTest.CondApi

      assert function_exported?(CondApi, :present_here, 1)
      refute function_exported?(CondApi, :absent_here, 1)
    end
  end
end
