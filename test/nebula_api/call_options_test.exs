defmodule NebulaAPI.CallOptionsTest do
  use ExUnit.Case

  alias NebulaAPI.Config

  describe "Config.default_timeout/0 (R3)" do
    test "reads the :default_timeout app env" do
      Application.put_env(:nebula_api, :default_timeout, 777)
      on_exit(fn -> Application.delete_env(:nebula_api, :default_timeout) end)

      assert Config.default_timeout() == 777
    end

    test "falls back to 5000 when unset" do
      assert Config.default_timeout() == 5_000
    end
  end

  describe "APIServer.resolve_timeout/2 (R3)" do
    alias NebulaAPI.APIServer

    # Mirrors the accessor `use NebulaAPI, default_timeout: 1234` generates.
    defmodule WithModuleDefault do
      def __nebula_api__(:default_timeout), do: 1234
    end

    defmodule WithoutOpts do
    end

    test "the call's timeout: option wins over everything" do
      assert APIServer.resolve_timeout(WithModuleDefault, timeout: 99) == 99
    end

    test "the module's default_timeout beats the global default" do
      assert APIServer.resolve_timeout(WithModuleDefault, []) == 1234
    end

    test "the global default applies when the module has none" do
      Application.put_env(:nebula_api, :default_timeout, 777)
      on_exit(fn -> Application.delete_env(:nebula_api, :default_timeout) end)

      assert APIServer.resolve_timeout(WithoutOpts, []) == 777
    end

    test "a module atom that is not a compiled module falls back safely" do
      assert APIServer.resolve_timeout(NotARealModule, []) == 5_000
    end
  end

  describe "timeout: validation (I6)" do
    alias NebulaAPI.APIServer

    test "timeout: :infinity raises ArgumentError up front — unicast and multicast alike" do
      assert_raise ArgumentError, ~r/timeout/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work}, timeout: :infinity)
      end

      assert_raise ArgumentError, ~r/timeout/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :all,
          timeout: :infinity
        )
      end
    end

    test "non-positive or non-integer timeouts raise ArgumentError" do
      for bad <- [0, -5, 1.5, "100", :soon] do
        assert_raise ArgumentError, ~r/timeout/, fn ->
          APIServer.call_remote_method(NoSuchMod, {:work}, timeout: bad)
        end
      end
    end

    test "a bad global default_timeout is caught at call time too" do
      Application.put_env(:nebula_api, :default_timeout, :infinity)
      on_exit(fn -> Application.delete_env(:nebula_api, :default_timeout) end)

      assert_raise ArgumentError, ~r/timeout/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work})
      end
    end
  end

  describe "strategy: validation (I2)" do
    alias NebulaAPI.APIServer

    test "a typo'd strategy raises instead of silently degrading to :all" do
      # Without validation, :qourum fell into the :all catch-all: an intended
      # quorum write became a plain broadcast — and both return lists, so the
      # caller would never notice the lost guarantee.
      assert_raise ArgumentError, ~r/strategy/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :qourum,
          timeout: 100
        )
      end
    end

    test "strategy: on a non-multicast call raises (it would be silently ignored)" do
      assert_raise ArgumentError, ~r/multicast/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work}, strategy: :quorum, timeout: 100)
      end
    end

    test "valid strategies still pass validation" do
      for strategy <- [:all, :first, :quorum] do
        result =
          APIServer.call_remote_method(NoSuchMod, {:work},
            multicast: true,
            strategy: strategy,
            timeout: 100
          )

        # No worker registered: each strategy fails on its own contract,
        # never with an ArgumentError.
        refute match?({:nebula_error, %ArgumentError{}}, result)
      end
    end
  end
end
