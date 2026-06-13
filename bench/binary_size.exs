# Shows the "smaller binaries" effect, with real numbers. Run from the project root:
#
#     elixir -S mix run bench/binary_size.exs
#
# It compiles the SAME defapi module twice — once as a node that MATCHES the
# selector (the body is emitted) and once as a node that does NOT (only the
# router + remote stub) — and compares the resulting .beam byte sizes. The body
# of a defapi simply does not exist in the bytecode of a node that doesn't run it.

Application.put_env(:nebula_api, :nodes, [{:"heavy@h", [:heavy]}, {:"light@h", [:light]}])

source = fn mod, self_node ->
  """
  defmodule #{mod} do
    use NebulaAPI, allow_unknown_self_node: true, self_node: :"#{self_node}"

    defapi &heavy, transcode(input, opts) do
      # A non-trivial body — the kind a worker carries and a web node shouldn't.
      profile = Keyword.get(opts, :profile, :default)
      for i <- 1..50, do: {i, :crypto.hash(:sha256, "\#{input}-\#{i}-\#{profile}")}
      |> Enum.map(fn {i, h} -> {i, Base.encode16(h)} end)
      |> Enum.reduce(%{}, fn {i, h}, acc -> Map.put(acc, i, String.slice(h, 0, 8)) end)
      |> Map.put(:profile, profile)
    end
  end
  """
end

[{_, local}] = Code.compile_string(source.("SizeOnMatchingNode", "heavy@h"))
[{_, remote}] = Code.compile_string(source.("SizeOnOtherNode", "light@h"))

l = byte_size(local)
r = byte_size(remote)

IO.puts("\nsmaller binaries — one defapi module, .beam size\n")
:io.format("  matching node (body compiled in):   ~6w bytes~n", [l])
:io.format("  other node    (router + stub only): ~6w bytes~n", [r])
:io.format("  the body isn't there:               ~6w bytes smaller (~.1f%)~n", [l - r, (l - r) * 100 / l])
