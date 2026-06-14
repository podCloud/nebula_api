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

    test "timeout: nil means 'not set' — the default resolution applies" do
      # nil is the one non-integer that does NOT raise: a computed
      # `timeout: maybe_timeout` holding nil falls back to the module/global
      # default, exactly as if the option were absent.
      assert APIServer.resolve_timeout(WithModuleDefault, timeout: nil) == 1234
      assert APIServer.resolve_timeout(WithoutOpts, timeout: nil) == 5_000
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
      # false is NOT nil: it must raise like any other non-integer, not melt
      # into the default behind the caller's back.
      for bad <- [0, -5, 1.5, "100", :soon, false] do
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
            # :quorum defaults to :configured, which needs the method's set
            # (normally injected by the stub); ignored by :all / :first.
            __method_configured_nodes: [:n1@h, :n2@h],
            timeout: 100
          )

        # No worker registered: each strategy fails on its own contract,
        # never with an ArgumentError.
        refute match?({:nebula_error, %ArgumentError{}}, result)
      end
    end
  end

  describe "nil call opts mean 'not set' across the board" do
    alias NebulaAPI.APIServer

    test "strategy: nil resolves to the :all default, multicast or not" do
      # Same convention as timeout:/node_selector: nil — a computed
      # `strategy: maybe_strategy` holding nil must neither raise nor
      # half-apply. Multicast with no workers → [] is :all's own contract.
      assert APIServer.call_remote_method(NoSuchMod, {:work},
               multicast: true,
               strategy: nil,
               timeout: 100
             ) == []

      assert {:nebula_error, {:no_worker, _}} =
               APIServer.call_remote_method(NoSuchMod, {:work}, strategy: nil, timeout: 100)
    end

    test "success:/failure: nil are absent for the applicability check too" do
      # Before the fix, Keyword.has_key? counted a nil predicate as PRESENT:
      # success: nil raised 'would be silently ignored' on unicast while being
      # treated as unset on :first — nil meant two different things one line
      # apart.
      assert {:nebula_error, {:no_worker, _}} =
               APIServer.call_remote_method(NoSuchMod, {:work}, success: nil, timeout: 100)

      assert APIServer.call_remote_method(NoSuchMod, {:work},
               multicast: true,
               strategy: :all,
               failure: nil,
               timeout: 100
             ) == []
    end

    test "multicast: nil routes as unicast and validates cleanly" do
      assert {:nebula_error, {:no_worker, _}} =
               APIServer.call_remote_method(NoSuchMod, {:work}, multicast: nil, timeout: 100)

      # The inapplicability checks must speak about the OPT, not crash on a
      # bare `not nil`.
      assert_raise ArgumentError, ~r/at_least/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: nil,
          at_least: 2,
          timeout: 100
        )
      end
    end
  end

  describe "node_selector: validation" do
    alias NebulaAPI.APIServer

    test "a non-function node_selector raises ArgumentError up front — unicast and multicast" do
      # Without form validation this melted into
      # {:nebula_error, {:selector_failed, {:badfun, _}}} at selection time —
      # the one call opt reported on the transport channel while every other
      # malformed opt (strategy:, at_least:, timeout:, success:) crashed loud.
      for bad <- [:not_a_fun, "db", fn -> :wrong_arity end, fn _a, _b -> :wrong_arity end] do
        assert_raise ArgumentError, ~r/node_selector/, fn ->
          APIServer.call_remote_method(NoSuchMod, {:work}, node_selector: bad, timeout: 100)
        end

        assert_raise ArgumentError, ~r/node_selector/, fn ->
          APIServer.call_remote_method(NoSuchMod, {:work},
            multicast: true,
            node_selector: bad,
            timeout: 100
          )
        end
      end
    end

    test "node_selector: nil means 'not set' — the call routes as if the option were absent" do
      # Same convention as timeout: nil; the router's cond already treats a
      # nil selector as no selector at all.
      assert {:nebula_error, {:no_worker, _}} =
               APIServer.call_remote_method(NoSuchMod, {:work}, node_selector: nil, timeout: 100)
    end

    test "a 1-arity function still passes validation (its bugs stay a runtime concern)" do
      result =
        APIServer.call_remote_method(NoSuchMod, {:work},
          node_selector: fn _nodes_info -> nil end,
          timeout: 100
        )

      refute match?({:nebula_error, %ArgumentError{}}, result)
    end
  end

  describe "unknown call option keys" do
    alias NebulaAPI.APIServer

    test "a typo'd key raises ArgumentError up front instead of being silently dropped" do
      assert_raise ArgumentError, ~r/unknown call option/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work}, timout: 100)
      end
    end

    test "a stale key (quorum_count:, removed in 0.4.0) raises instead of degrading the quorum" do
      # Silently dropping it would leave the quorum at the majority default —
      # a durability requirement quietly replaced behind the caller's back.
      assert_raise ArgumentError, ~r/unknown call option/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :quorum,
          quorum_count: 2,
          timeout: 100
        )
      end
    end

    test "every documented key still passes the closed-set check" do
      # Every valid key at once (minus failure:, exclusive with success:): the
      # only failure left is the quorum's own contract (no worker serves the
      # method), never an unknown-key refusal.
      assert {:nebula_error, :quorum_unreachable, _} =
               APIServer.call_remote_method(NoSuchMod, {:work},
                 multicast: true,
                 strategy: :quorum,
                 at_least: 1,
                 success: &match?({:ok, _}, &1),
                 node_selector: fn _nodes_info -> [] end,
                 timeout: 100
               )
    end
  end

  describe "quorum: option" do
    alias NebulaAPI.APIServer

    test "quorum: :configured is a valid option with strategy: :quorum" do
      # No worker serves the method, so the only failure left is the quorum's
      # own contract — never an unknown-key or invalid-value refusal. The set is
      # what the generated stub injects.
      assert {:nebula_error, :quorum_unreachable, _} =
               APIServer.call_remote_method(NoSuchMod, {:work},
                 multicast: true,
                 strategy: :quorum,
                 quorum: :configured,
                 __method_configured_nodes: [:a@h, :b@h, :c@h],
                 timeout: 100
               )
    end

    test "quorum: :available is a valid option with strategy: :quorum" do
      assert {:nebula_error, :quorum_unreachable, _} =
               APIServer.call_remote_method(NoSuchMod, {:work},
                 multicast: true,
                 strategy: :quorum,
                 quorum: :available,
                 timeout: 100
               )
    end

    test "an unknown quorum: value raises ArgumentError up front" do
      assert_raise ArgumentError, ~r/quorum/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :quorum,
          quorum: :bogus,
          timeout: 100
        )
      end
    end

    test "quorum: only applies to the :quorum strategy" do
      assert_raise ArgumentError, ~r/quorum:/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :all,
          quorum: :configured,
          timeout: 100
        )
      end
    end

    test "at_least: and quorum: are mutually exclusive" do
      assert_raise ArgumentError, ~r/at_least.*quorum|quorum.*at_least|mutually exclusive/, fn ->
        APIServer.call_remote_method(NoSuchMod, {:work},
          multicast: true,
          strategy: :quorum,
          at_least: 2,
          quorum: :configured,
          timeout: 100
        )
      end
    end

    test "quorum: nil means 'not set' — falls back to the default (:configured)" do
      assert {:nebula_error, :quorum_unreachable, _} =
               APIServer.call_remote_method(NoSuchMod, {:work},
                 multicast: true,
                 strategy: :quorum,
                 quorum: nil,
                 __method_configured_nodes: [:a@h, :b@h, :c@h],
                 timeout: 100
               )
    end
  end
end
