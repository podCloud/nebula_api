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
end
