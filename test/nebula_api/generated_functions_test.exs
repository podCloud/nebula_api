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

      def unicast_bad_timeout(sel) do
        call_on_node sel, timeout: :infinity do
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

      def unicast_opts_only_bad_timeout do
        call_on_node timeout: :infinity do
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
        CtxCaller.unicast_bad_timeout(nil)
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
        CtxCaller.unicast_opts_only_bad_timeout()
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
end
