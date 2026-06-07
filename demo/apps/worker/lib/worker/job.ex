defmodule Worker.Job do
  @moduledoc "Compute jobs, runnable on any &worker node."
  use NebulaAPI
  require Logger

  defapi &worker, run_task(arg) do
    Logger.info("⚙️  [#{node()}] Worker.Job.run_task(#{inspect(arg)})")
    Process.sleep(:rand.uniform(400))   # variable latency → makes :first meaningful
    Db.Store.incr("tasks_done")          # worker → @db (cluster call from a worker)
    %{node: node(), result: arg * 2}
  end

  # Quorum + conditional compilation: worker3 ALWAYS fails — the raise is compiled
  # ONLY on @worker3 (on_nebula_nodes), no config, no randomness.
  defapi &worker, run_task_flaky(arg) do
    Logger.info("⚙️  [#{node()}] Worker.Job.run_task_flaky(#{inspect(arg)})")

    on_nebula_nodes @worker3 do
      raise "simulated failure on #{node()}"
    else
      %{node: node(), result: arg * 2}
    end
  end

  # Readiness probe (dogfooding).
  defapi &worker, ready?(), do: true
end
