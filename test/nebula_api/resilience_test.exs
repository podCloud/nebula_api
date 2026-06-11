defmodule NebulaAPI.ResilienceTest do
  use ExUnit.Case

  alias NebulaAPI.APIServer

  @pg_scope :pg_nebula_api

  setup_all do
    case :pg.start(@pg_scope) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case :ets.whereis(:nebula_nodes_cache) do
      :undefined ->
        :ets.new(:nebula_nodes_cache, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  # Test worker that replies through a function, with an optional delay before replying.
  defmodule SlowFake do
    use GenServer
    def init(state), do: {:ok, state}

    def handle_call(
          {:nebula_call, fn_call},
          _from,
          %{delay: delay, reply: reply} = state
        ) do
      if delay > 0, do: Process.sleep(delay)
      _ = fn_call
      {:reply, reply, state}
    end
  end

  defp start_fake(module, method, arity, delay, reply) do
    {:ok, pid} = GenServer.start(SlowFake, %{delay: delay, reply: reply})
    :pg.join(@pg_scope, {module, {method, arity}}, pid)
    pid
  end

  # A module carrying the persisted :nebula_local_api_methods marker the worker
  # reads to register itself and validate incoming calls.
  defmodule LocalMethodsMod do
    Module.register_attribute(__MODULE__, :nebula_local_api_methods,
      accumulate: true,
      persist: true
    )

    @nebula_local_api_methods {:slow, 0}
    @nebula_local_api_methods {:fast, 0}

    def slow do
      Process.sleep(300)
      {:ok, :slow}
    end

    def fast, do: {:ok, :fast}
  end

  describe "unicast — timeout resilience (H1)" do
    test "a worker slower than the timeout returns {:nebula_error, :timeout} without crashing the caller" do
      pid = start_fake(UnicastTimeoutMod, :slow, 0, 300, {:ok, :too_late})

      result = APIServer.call_remote_method(UnicastTimeoutMod, {:slow}, timeout: 50)

      assert {:nebula_error, :timeout} = result
      # The caller (this test process) is still alive: the next line runs.
      assert Process.alive?(self())

      GenServer.stop(pid)
    end

    test "through a node selector, a too-slow worker returns {:nebula_error, :timeout} without crashing" do
      pid = start_fake(UnicastSelectorMod, :slow, 0, 300, {:ok, :too_late})
      target = node()

      result =
        APIServer.call_remote_method(
          UnicastSelectorMod,
          {:slow},
          node_selector: fn _nodes_info -> target end,
          timeout: 50
        )

      assert {:nebula_error, :timeout} = result
      assert Process.alive?(self())

      GenServer.stop(pid)
    end

    test "a late worker reply does not land in the caller's mailbox" do
      # Replies 200ms AFTER the 50ms timeout.
      pid = start_fake(GarbageMod, :slow, 0, 250, {:ok, :too_late})

      assert {:nebula_error, :timeout} =
               APIServer.call_remote_method(GarbageMod, {:slow}, timeout: 50)

      # Let the worker emit its late reply.
      Process.sleep(400)

      # No {reference, _} 2-tuple (the gen_server:call garbage shape) may be left
      # in our mailbox: it was confined to the dead Task.
      {:messages, msgs} = Process.info(self(), :messages)

      refute Enum.any?(msgs, fn
               {ref, _} when is_reference(ref) -> true
               _ -> false
             end)

      GenServer.stop(pid)
    end
  end

  describe "unicast — trap_exit callers (R2)" do
    test "a trap_exit caller gets no EXIT message from a unicast call" do
      pid = start_fake(TrapExitMod, :fast, 0, 0, :value)
      parent = self()

      spawn(fn ->
        Process.flag(:trap_exit, true)
        result = APIServer.call_remote_method(TrapExitMod, {:fast}, timeout: 500)
        # Leave time for any {:EXIT, _, :normal} from a linked task to arrive.
        Process.sleep(100)
        {:messages, msgs} = Process.info(self(), :messages)
        send(parent, {:observed, result, msgs})
      end)

      assert_receive {:observed, :value, msgs}, 2_000
      refute Enum.any?(msgs, &match?({:EXIT, _, _}, &1))

      GenServer.stop(pid)
    end
  end

  describe "multicast :all — timeout resilience (H2)" do
    test "a worker slower than the timeout returns a partial list without crashing" do
      pid = start_fake(AllTimeoutMod, :slow, 0, 400, {:ok, :too_late})

      result =
        APIServer.call_remote_method(
          AllTimeoutMod,
          {:slow},
          multicast: true,
          strategy: :all,
          timeout: 80
        )

      assert is_list(result)
      assert [{_node, {:nebula_error, :timeout}}] = result
      # No crash: we're still here.
      assert Process.alive?(self())

      GenServer.stop(pid)
    end
  end

  describe "build_nodes_info — a crashing node is not fatal (L3)" do
    test "a non-timeout task exit is dropped, not raised" do
      # async_stream yields {:exit, reason} when a task crashes (not just on timeout).
      # Such a result must be treated as a drop, never crash the whole build.
      assert APIServer.normalize_stream_result({:exit, %ArithmeticError{}}) == :dropped
      assert APIServer.normalize_stream_result({:exit, :killed}) == :dropped
    end

    test "successful results pass through; timed-out tasks are dropped" do
      assert APIServer.normalize_stream_result({:ok, {:ok, %{a: 1}, :n@h}}) ==
               {:ok, %{a: 1}, :n@h}

      assert APIServer.normalize_stream_result({:exit, :timeout}) == :dropped
    end
  end

  describe "node-info cache refresh (M4)" do
    test "NodesInfoCache repopulates the snapshot periodically" do
      # Wipe the snapshot, start a fast-refreshing cache, expect it back.
      :ets.delete(:nebula_nodes_cache, :__nodes_info_snapshot__)

      {:ok, pid} = NebulaAPI.APIServer.NodesInfoCache.start_link(name: nil, interval: 50)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Let it tick a couple of times.
      Process.sleep(150)

      assert match?(
               [{_, %{data: _}}],
               :ets.lookup(:nebula_nodes_cache, :__nodes_info_snapshot__)
             )
    end

    test "get_nodes_info serves an existing snapshot without rebuilding it" do
      marker = %{:marker@host => %{long_name: :marker@host, connected: false}}

      # updated_at deliberately far in the past: under the old TTL logic this would
      # have forced a rebuild; the new behavior serves it regardless of age.
      stale_at = System.monotonic_time(:millisecond) - 60_000

      :ets.insert(
        :nebula_nodes_cache,
        {:__nodes_info_snapshot__, %{data: marker, updated_at: stale_at}}
      )

      # A stale snapshot is served as-is (the cache keeps it fresh in the
      # background); get_nodes_info no longer rebuilds on read.
      assert APIServer.get_nodes_info() == marker
    end
  end

  describe "worker — non-blocking execution (H3)" do
    test "a slow call does not block a concurrent fast call" do
      {:ok, worker} = NebulaAPI.APIServer.Worker.start_link(LocalMethodsMod)
      parent = self()

      spawn(fn ->
        send(parent, {:slow_done, GenServer.call(worker, {:nebula_call, {:slow}}, 5_000)})
      end)

      # Let the slow call reach the worker.
      Process.sleep(30)

      t0 = System.monotonic_time(:millisecond)
      fast = GenServer.call(worker, {:nebula_call, {:fast}}, 5_000)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert fast == {:ok, :fast}
      # The fast call must NOT have waited out the slow call's 300ms.
      assert elapsed < 150
      assert_receive {:slow_done, {:ok, :slow}}, 1_000

      GenServer.stop(worker)
    end

    test "an unknown-method call returns an error without killing the worker" do
      {:ok, worker} = NebulaAPI.APIServer.Worker.start_link(LocalMethodsMod)

      assert {:nebula_error, {:undefined_local_method, LocalMethodsMod, :nope, 0}} =
               GenServer.call(worker, {:nebula_call, {:nope}}, 1_000)

      # The worker survives and keeps serving its real methods.
      assert Process.alive?(worker)
      assert GenServer.call(worker, {:nebula_call, {:fast}}, 1_000) == {:ok, :fast}

      GenServer.stop(worker)
    end
  end

  describe "transparent return values (L2 / B)" do
    test "a bare value passes through as-is (no :ok wrapping)" do
      pid = start_fake(BareValueMod, :add, 0, 0, 10)
      assert APIServer.call_remote_method(BareValueMod, {:add}) == 10
      GenServer.stop(pid)
    end

    test "a 3-tuple business return passes through unchanged, unicast and :all" do
      pid = start_fake(ThreeTupleMod, :work, 0, 0, {:ok, :a, :b})

      # unicast: returned exactly as-is
      assert APIServer.call_remote_method(ThreeTupleMod, {:work}) == {:ok, :a, :b}

      # :all: paired with the node, value untouched (no re-wrap, no asymmetry)
      assert [{_node, {:ok, :a, :b}}] =
               APIServer.call_remote_method(
                 ThreeTupleMod,
                 {:work},
                 multicast: true,
                 strategy: :all,
                 timeout: 500
               )

      GenServer.stop(pid)
    end
  end

  describe "success/failure predicate for :first/:quorum (B)" do
    test ":first treats any replied worker as success by default" do
      pid = start_fake(PredDefaultMod, :work, 0, 0, {:error, :nope})

      assert {_node, {:error, :nope}} =
               APIServer.call_remote_method(
                 PredDefaultMod,
                 {:work},
                 multicast: true,
                 strategy: :first,
                 timeout: 500
               )

      GenServer.stop(pid)
    end

    test ":first with success: skips a business error (no success → :no_success)" do
      pid = start_fake(PredSuccessMod, :work, 0, 0, {:error, :nope})

      result =
        APIServer.call_remote_method(
          PredSuccessMod,
          {:work},
          multicast: true,
          strategy: :first,
          timeout: 500,
          success: &match?({:ok, _}, &1)
        )

      assert result == {:nebula_error, :no_success, [{node(), {:error, :nope}}]}

      GenServer.stop(pid)
    end

    test ":first with zero workers is :no_success with empty results, not a bare []" do
      result =
        APIServer.call_remote_method(
          NoWorkersFirstMod,
          {:noop},
          multicast: true,
          strategy: :first,
          timeout: 100
        )

      assert result == {:nebula_error, :no_success, []}
    end

    test ":quorum with failure: still reaches quorum on a non-matching reply" do
      pid = start_fake(PredQuorumMod, :work, 0, 0, {:ok, :good})

      result =
        APIServer.call_remote_method(
          PredQuorumMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          quorum_count: 1,
          timeout: 500,
          failure: &match?({:error, _}, &1)
        )

      assert result == [{node(), {:ok, :good}}]

      GenServer.stop(pid)
    end

    test "passing both success: and failure: raises ArgumentError" do
      pid = start_fake(PredBothMod, :work, 0, 0, {:ok, :good})

      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        APIServer.call_remote_method(
          PredBothMod,
          {:work},
          multicast: true,
          strategy: :first,
          timeout: 500,
          success: &match?({:ok, _}, &1),
          failure: &match?({:error, _}, &1)
        )
      end

      GenServer.stop(pid)
    end

    test "a raising predicate is contained and leaves no stray {ref, _} in the mailbox" do
      pid = start_fake(PredRaiseMod, :work, 0, 0, {:ok, :good})

      result =
        APIServer.call_remote_method(
          PredRaiseMod,
          {:work},
          multicast: true,
          strategy: :first,
          timeout: 500,
          success: fn _value -> raise "predicate bug" end
        )

      assert {:nebula_error, %RuntimeError{message: "predicate bug"}} = result

      # The caller's mailbox must stay clean even on this failure path.
      Process.sleep(100)
      {:messages, msgs} = Process.info(self(), :messages)

      refute Enum.any?(msgs, fn
               {ref, _} when is_reference(ref) -> true
               _ -> false
             end)

      GenServer.stop(pid)
    end

    test "a raising predicate (:quorum) is contained and leaves no stray {ref, _} in the mailbox" do
      pid = start_fake(PredRaiseQuorumMod, :work, 0, 0, {:ok, :good})

      result =
        APIServer.call_remote_method(
          PredRaiseQuorumMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          quorum_count: 1,
          timeout: 500,
          success: fn _value -> raise "predicate bug" end
        )

      assert {:nebula_error, %RuntimeError{message: "predicate bug"}} = result

      # The caller's mailbox must stay clean even on this failure path.
      Process.sleep(100)
      {:messages, msgs} = Process.info(self(), :messages)

      refute Enum.any?(msgs, fn
               {ref, _} when is_reference(ref) -> true
               _ -> false
             end)

      GenServer.stop(pid)
    end

    test "success: on a unicast call raises ArgumentError (it would be silently ignored)" do
      pid = start_fake(PredUnicastMod, :work, 0, 0, {:ok, :good})

      assert_raise ArgumentError, ~r/only apply to multicast/, fn ->
        APIServer.call_remote_method(
          PredUnicastMod,
          {:work},
          timeout: 500,
          success: &match?({:ok, _}, &1)
        )
      end

      GenServer.stop(pid)
    end

    test "failure: on a multicast :all call raises ArgumentError" do
      pid = start_fake(PredAllMod, :work, 0, 0, {:ok, :good})

      assert_raise ArgumentError, ~r/only apply to multicast/, fn ->
        APIServer.call_remote_method(
          PredAllMod,
          {:work},
          multicast: true,
          strategy: :all,
          timeout: 500,
          failure: &match?({:error, _}, &1)
        )
      end

      GenServer.stop(pid)
    end
  end

  describe "node-info cache — refresh fault containment (R6)" do
    import ExUnit.CaptureLog

    alias NebulaAPI.APIServer.NodesInfoCache

    test "a raising refresh returns :error instead of crashing" do
      capture_log(fn ->
        assert NodesInfoCache.protected_refresh(fn -> raise "boom" end) == :error
      end)
    end

    test "a throwing refresh returns :error instead of crashing" do
      capture_log(fn ->
        assert NodesInfoCache.protected_refresh(fn -> throw(:boom) end) == :error
      end)
    end

    test "an exiting refresh returns :error instead of crashing" do
      capture_log(fn ->
        assert NodesInfoCache.protected_refresh(fn -> exit(:boom) end) == :error
      end)
    end

    test "a successful refresh returns :ok" do
      assert NodesInfoCache.protected_refresh(fn -> :whatever end) == :ok
    end
  end

  describe "unicast — node_selector error wrapping (R4)" do
    test "a node_selector raising ArgumentError is wrapped, not propagated" do
      pid = start_fake(SelectorRaiseMod, :fast, 0, 0, :value)

      result =
        APIServer.call_remote_method(
          SelectorRaiseMod,
          {:fast},
          node_selector: fn _nodes_info -> raise ArgumentError, "user selector bug" end,
          timeout: 500
        )

      # What this proves: selector errors are converted to {:nebula_error, _} by
      # safe_call_selector/2 before they ever leave call_selected_worker — a user
      # exception in routing code is a transport failure, never an uncaught raise.
      # (Bad call OPTS, by contrast, raise up front — see the predicate tests.)
      assert {:nebula_error, _} = result

      GenServer.stop(pid)
    end
  end

  describe "quorum unreachable + quorum_proportion (I3)" do
    test "an impossible quorum fails fast without calling any worker" do
      pid = start_fake(QuorumUnreachableMod, :work, 0, 0, :should_never_run)

      result =
        APIServer.call_remote_method(
          QuorumUnreachableMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          # single node → 1 worker; ask for 3
          quorum_count: 3,
          timeout: 500
        )

      assert {:nebula_error, :quorum_unreachable, %{workers: 1, required: 3}} = result

      GenServer.stop(pid)
    end

    test ":quorum with zero workers is unreachable, not an empty success" do
      result =
        APIServer.call_remote_method(
          NoWorkersQuorumMod,
          {:noop},
          multicast: true,
          strategy: :quorum,
          quorum_count: 1,
          timeout: 100
        )

      assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 1}} = result
    end

    test "quorum_proportion resolves against the worker count" do
      pid = start_fake(QuorumPropMod, :work, 0, 0, {:ok, :good})

      # 1 worker, p = 0.6 → required = max(1, ceil(0.6)) = 1 → reachable, succeeds.
      result =
        APIServer.call_remote_method(
          QuorumPropMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          quorum_proportion: 0.6,
          timeout: 500
        )

      assert [{_node, {:ok, :good}}] = result

      GenServer.stop(pid)
    end

    test "quorum_proportion outside (0.5, 1] raises ArgumentError" do
      for bad <- [0.5, 0.0, 1.1, -1, :half] do
        assert_raise ArgumentError, ~r/quorum_proportion/, fn ->
          APIServer.call_remote_method(
            SomeMod,
            {:work},
            multicast: true,
            strategy: :quorum,
            quorum_proportion: bad
          )
        end
      end
    end

    test "quorum_count and quorum_proportion together raise ArgumentError" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        APIServer.call_remote_method(
          SomeMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          quorum_count: 2,
          quorum_proportion: 0.6
        )
      end
    end

    test "a non-positive quorum_count raises ArgumentError" do
      assert_raise ArgumentError, ~r/quorum_count/, fn ->
        APIServer.call_remote_method(
          SomeMod,
          {:work},
          multicast: true,
          strategy: :quorum,
          quorum_count: 0
        )
      end
    end
  end

  describe "selectors see pg-registered nodes not yet in the snapshot (M9)" do
    test "a worker node missing from the snapshot is offered to the selector, runtime: nil" do
      # Snapshot deliberately EMPTY: simulates the window between a node joining
      # (pg knows its worker) and the next NodesInfoCache refresh.
      :ets.insert(
        :nebula_nodes_cache,
        {:__nodes_info_snapshot__, %{data: %{}, updated_at: 0}}
      )

      on_exit(fn -> :ets.delete(:nebula_nodes_cache, :__nodes_info_snapshot__) end)

      pid = start_fake(PgFirstMod, :work, 0, 0, :reached)
      parent = self()

      result =
        APIServer.call_remote_method(
          PgFirstMod,
          {:work},
          node_selector: fn nodes_info ->
            send(parent, {:seen, nodes_info})
            List.first(Map.keys(nodes_info))
          end,
          timeout: 500
        )

      assert result == :reached

      assert_receive {:seen, nodes_info}
      this = node()
      assert %{^this => info} = nodes_info
      assert info.long_name == this
      assert info.runtime == nil
      assert info.last_seen_at == nil

      GenServer.stop(pid)
    end
  end
end
