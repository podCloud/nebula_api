# NebulaAPI Troubleshooting

## Compile-time errors

### "Unknown node" / "Unknown tags" / "No nodes found for execution"

You referenced a node or tag that isn't in `config :nebula_api, :nodes`, or a selector
that excludes every node (e.g. `[&db, !&db]`). Check spelling, add the node/tag to config,
or fix the selector. See [configuration.md](configuration.md).

### "self_node is an unknown node"

You're compiling on a node not in the configuration.

```elixir
# Add the node:
config :nebula_api, nodes: ["dev@localhost": [:cluster, :db, :worker], ...]

# Or point the compiler at a configured node without --name (dev/test):
config :nebula_api, default_opts: [self_node: :"dev@localhost"]

# Or, for throwaway compiles only:
use NebulaAPI, allow_unknown_self_node: true
```

### "... has modules with local methods but no nebula_api_server()"

The `:nebula` compiler caught an app whose `defapi` modules are local here, but no module
wired `nebula_api_server()`. Add `use NebulaAPI.Server` + `nebula_api_server()` to the
app's supervisor (see [server-and-compiler.md](server-and-compiler.md)).

## Runtime errors

### "No worker found for remote method"

```elixir
{:error, "No worker found for remote method {:get, \"abc\"}"}
```

Causes and checks:

1. **The server wasn't wired.** The most common one: the owning app never started a
   worker. Make sure that app does `use NebulaAPI.Server` + `nebula_api_server()` in its
   supervisor. (The `:nebula` compiler catches this at build time — see above.)
2. **The target node isn't connected.** `Node.list()` should include it.
3. **The method isn't local on any connected node.** Check the worker and `:pg`:

```elixir
Process.whereis(MyApp.Users)                              # the local worker, if any
NebulaAPI.APIServer.registered_local_methods(MyApp.Users) # should include {:get, 1}
:pg.get_members(:pg_nebula_api, {MyApp.Users, {:get, 1}}) # should have ≥ 1 pid
```

### Timeout

The default RPC timeout is **5000 ms**. Override per call:

```elixir
call_on_node @worker, timeout: 30_000 do
  MyApp.Jobs.transcode(file, opts)
end
```

If calls time out, check network latency (`Node.ping/1`), the target's load
(`:erlang.statistics(:run_queue)` on it), or make the operation faster.

### Serialization errors

Remote results cross Erlang distribution, so don't return non-serializable terms (PIDs,
refs, functions, open connections). Return plain data; convert PIDs to strings if you
must surface them.

## Process groups not syncing

If two connected nodes disagree on `:pg.get_members(:pg_nebula_api, ...)`:

```elixir
Process.whereis(:pg_nebula_api)     # the :pg scope should be running
:net_kernel.monitor_nodes(true)     # watch for {:nodeup, node} / {:nodedown, node}
```

`:pg` syncs across connected nodes automatically — a desync usually means the cluster
isn't actually fully connected. Forming the Erlang cluster is the consumer's concern
(epmd, DNS, libcluster).

## Inspecting what compiled where

```elixir
MyModule.__info__(:attributes) |> Keyword.get_values(:nebula_local_api_methods) |> List.flatten()
# => [{:get, 1}, ...] if local here, [] if this node only has the remote stub
```

Enable debug logging to trace routing:

```elixir
Logger.configure(level: :debug)
# [debug] Will do remote execution on MyApp.Users with fn_call: {:get, "abc"}
```

## See Also

- [Configuration](configuration.md)
- [Server and Compiler](server-and-compiler.md)
- [Concepts](concepts.md)
