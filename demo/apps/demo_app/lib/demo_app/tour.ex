defmodule DemoApp.Tour do
  @moduledoc "Scripted tour, run once at boot. Each step logs a title then the result."
  use NebulaAPI
  require Logger

  def run do
    wait_for_cluster()
    Logger.info("\n================ NebulaAPI demo tour ================")

    step("1. @db unicast (write+read) — a Cachex store made cluster-wide", fn ->
      Db.Store.put("user:42", "alice")
      Db.Store.get("user:42")
    end)

    step("2. unicast worker — routed to ONE worker", fn ->
      Worker.Job.run_task(21)
    end)

    step("3. :all multicast — every worker responds", fn ->
      call_on_nodes &worker, strategy: :all, timeout: 5_000 do
        Worker.Job.run_task(1)
      end
    end)

    step("4. :first — fastest worker wins, others cancelled", fn ->
      call_on_nodes &worker, strategy: :first, timeout: 5_000 do
        Worker.Job.run_task(2)
      end
    end)

    step("5. :quorum OK (count: 2) — tolerates worker3's failure", fn ->
      call_on_nodes &worker, strategy: :quorum, quorum_count: 2, timeout: 5_000 do
        Worker.Job.run_task_flaky(3)
      end
    end)

    step("6. :quorum KO (count: 3) — worker3 always fails → not reached", fn ->
      call_on_nodes &worker, strategy: :quorum, quorum_count: 3, timeout: 5_000 do
        Worker.Job.run_task_flaky(3)
      end
    end)

    step("7. worker → db — counter incremented BY the workers themselves", fn ->
      Db.Store.get("tasks_done")
    end)

    Logger.info("================ tour done — attach an IEx and try Db.Store.get / Worker.Job.run_task ================\n")
  end

  defp step(title, fun) do
    Logger.info("\n--- #{title}")
    Logger.info("    => #{inspect(fun.())}")
  end

  # Dogfood the lib: multicast a ready? probe until all 3 workers + @db answer.
  defp wait_for_cluster(retries \\ 60) do
    workers_up =
      (call_on_nodes &worker, strategy: :all, timeout: 500 do
         Worker.Job.ready?()
       end)
      |> Enum.count(&match?({:ok, _, _}, &1))

    db_up? = match?({:ok, _}, (call_on_node @db, timeout: 500 do Db.Store.ready?() end))

    cond do
      workers_up >= 3 and db_up? -> :ready
      retries == 0 -> raise "cluster not ready after timeout"
      true -> Process.sleep(500); wait_for_cluster(retries - 1)
    end
  end
end
