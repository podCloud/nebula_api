# Micro-benchmark of NebulaAPI routing — real numbers, no Benchee dependency.
#
# Run from the project root, on a DISTRIBUTED node (needed for the cross-node row):
#
#     elixir --name bench@127.0.0.1 --cookie nebula_bench -S mix run bench/routing.exs
#
# It measures three paths over many iterations and prints ns/op and ms/op:
#   1. a plain local Elixir function call (baseline)
#   2. a NebulaAPI defapi call resolved LOCAL on this node (the routing overhead)
#   3. a real Erlang-distribution round-trip to a peer node on the same host
#      (the transport a cross-node defapi call rides on; cross-HOST adds network latency)

defmodule Bench do
  def measure(label, fun, iters) do
    fun.()
    {us, _} = :timer.tc(fn -> spin(fun, iters) end)
    ns = us * 1_000 / iters
    :io.format("~-52ts ~12.5f ms/op   (~10.1f ns/op)~n", [label, ns / 1.0e6, ns])
  end

  defp spin(_fun, 0), do: :ok
  defp spin(fun, n), do: (fun.(); spin(fun, n - 1))
end

defmodule Bench.Math do
  def add(a, b), do: a + b
end

# --- NebulaAPI local-resolved call ------------------------------------------
self = node()
Application.put_env(:nebula_api, :nodes, [{self, [:bench]}])
{:ok, _} = Application.ensure_all_started(:nebula_api)

Code.eval_string("""
defmodule Bench.Api do
  use NebulaAPI
  defapi &bench, add(a, b), do: a + b
end
""")

# --- peer node for the cross-node round-trip --------------------------------
cross =
  case :peer.start_link(%{name: :peer, host: ~c"127.0.0.1", args: [~c"-setcookie", ~c"nebula_bench"]}) do
    {:ok, _peer, peer_node} ->
      # :erlang.+/2 exists on every node, so no code shipping is needed — this
      # times the bare distribution round-trip, which is what the worker call rides on.
      fn -> :erpc.call(peer_node, :erlang, :+, [3, 7]) end

    other ->
      IO.puts("(peer node unavailable: #{inspect(other)} — run with --name to enable the cross-node row)")
      nil
  end

IO.puts("\nNebulaAPI routing — #{:erlang.system_info(:otp_release)} / #{self}\n")
Bench.measure("plain local call (baseline)", fn -> Bench.Math.add(3, 7) end, 5_000_000)
Bench.measure("NebulaAPI, resolved local", fn -> Bench.Api.add(3, 7) end, 5_000_000)
if cross, do: Bench.measure("cross-node round-trip (erpc, same host)", cross, 100_000)
