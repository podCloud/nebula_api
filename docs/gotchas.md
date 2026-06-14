# 4. Gotchas and troubleshooting

*The sharp edges. Read this once before you ship; come back to it when something behaves
unexpectedly.*

## Trailing routing options are positional

Every generated function accepts the routing options as **one extra trailing argument**,
after *all* the business arguments:

```elixir
defapi &db, list(filters \\ [])
# generates: def list(filters \\ [], nebula_routing_opts \\ [])

MyApp.Store.list([status: :active], multicast: true, strategy: :quorum, at_least: 2)
```

The dispatch is purely positional — and that's the trap. When your **last business
argument has a default**, an opts-looking call can bind to it instead:

```elixir
# DANGER: list/1 is a one-argument call, so the keyword list binds to `filters`.
# Your "routing options" are served to the body as business data; no routing happens.
MyApp.Store.list(multicast: true)
```

Two ways to stay safe:

```elixir
# 1. Fill the business arguments explicitly:
MyApp.Store.list([], multicast: true)

# 2. Better: use a call_on_* block, which carries routing through the call context and
#    sidesteps the positional ambiguity entirely. Its options-only form is the direct antidote:
call_on_nodes strategy: :quorum, at_least: 2 do
  MyApp.Store.list()
end
```

Routing opts are validated on **every** node, even when the call resolves locally and the
transport never runs: an invalid opt (`timeout: :infinity`, a `strategy:`/`success:`/
`failure:` without `multicast:`) raises an `ArgumentError` identically wherever the call
executes, and so does an unknown option key — the option set is closed, so a typo'd
`timout:` is never silently dropped. A valid-but-inapplicable opt (a `timeout:` on a
locally-resolved call) is a silent no-op.

## A `call_on_*` block is per-process and one-hop

The `call_on_*` blocks set a routing context in the **process dictionary** that the
generated functions read. Four rules govern how far it reaches.

**Nested blocks replace, then restore.** An inner block replaces the *whole* context —
selector, mode, *and options*. There is no merge: an outer `timeout: 30_000` does **not**
apply inside an inner block that doesn't repeat it. On exit (normal or via an exception) the
outer block's context takes back over; after the outermost block, no context remains.

**A call's own routing opts win over the block.** The innermost explicit routing wins: a
call inside a block that carries its own truthy `node_selector:`/`multicast:` trailing opts
routes itself, exactly as it would outside the block. A routing key explicitly set to `nil`
(or `multicast: false`) opts the call **out** of the block, back to default routing:

```elixir
call_on_nodes &worker, strategy: :all do
  MyApp.Jobs.broadcast()                      # fans out per the block
  MyApp.Local.bookkeep(x, multicast: false)   # plain default call — escapes the block
end
```

**The context does not follow a spawn.** It lives in the process running the block, so a
`Task.async`/`spawn` started inside a block runs with **no** context — its `defapi` calls
route by default. Put the block *inside* the task when that's what you mean:

```elixir
# The block does NOT reach the task's call:
call_on_node @db do
  Task.async(fn -> MyApp.Users.get(42) end) |> Task.await()   # routes by default!
end

# It does when the task owns the block:
Task.async(fn ->
  call_on_node @db do
    MyApp.Users.get(42)
  end
end)
|> Task.await()
```

**A block applies to one hop.** It never crosses the RPC boundary: a `defapi` body runs on
the target node in a fresh process, so calls *inside the body* route by their own defaults —
the caller's block doesn't leak into them.

## `nil` selector vs a selector that returns `nil`

The selector argument may be a runtime expression. The two `nil`s mean opposite things:

- A selector expression that **evaluates to `nil`** means *"no restriction"*: unicast routes
  to the first available worker; multicast fans out to every node serving the method. The
  block's options still apply.
- A selector **function that returns `nil`** (or `[]`) means *"nothing matched"*: the call
  fails (`{:nebula_error, {:no_worker_on_node, nil}}` for unicast; `:all` returns `[]`,
  `:first` returns `{:nebula_error, :no_success, []}`, `:quorum` fails
  `:quorum_unreachable`). A no-match never widens the target.

## A `defapi` inside `on_nebula_nodes` has no remote stub

Worth repeating from [Defining APIs](defining.md#on_nebula_nodes--conditional-compilation):
a `defapi` wrapped in `on_nebula_nodes` disappears entirely on non-matching nodes —
**router included**. Calling it there is an `UndefinedFunctionError`, not a transparent RPC.
For "implemented here, callable everywhere", use a plain `defapi`.

## Return only serializable data

Remote results cross Erlang distribution, so don't return non-serializable terms (PIDs,
refs, functions, open connections). Return plain data; convert PIDs to strings if you must
surface them.

---

# Troubleshooting

## Compile-time errors

**"Unknown node" / "Unknown tags" / "No nodes found for execution"** — you referenced a
node or tag not in `config :nebula_api, :nodes`, or a selector that excludes every node
(e.g. `&db !&db`). Check spelling, add the node/tag, or fix the selector. See
[Configuration](configuration.md#compile-time-validation).

**"self_node is an unknown node"** — you're compiling on a node not in the config:

```elixir
config :nebula_api, nodes: ["dev@localhost": [:cluster, :db, :worker], ...]
# or, without --name (dev/test):
config :nebula_api, default_opts: [self_node: :"dev@localhost"]
# or, for throwaway compiles only:
use NebulaAPI, allow_unknown_self_node: true
```

**"... has modules with local methods but no nebula_api_server()"** — the `:nebula`
compiler caught an app whose `defapi` modules are local here but no module wired
`nebula_api_server()`. Add `use NebulaAPI.Server` + `nebula_api_server()` to the app's
supervisor (see [Defining APIs](defining.md#wire-the-server-into-the-supervision-tree)).

## Runtime errors

### Refuses to boot — "node mismatch"

A release bakes its routing for the node it was compiled as, so it must **run** as that node.
If `NebulaAPI.Server` boots and `node()` doesn't match the compiled node, it raises and the
app won't start: a worker build launched as `api@host`, a real build launched as
`nonode@nohost` (forgot `RELEASE_DISTRIBUTION=name` / `RELEASE_NODE`), or a nameless build
given a real name. The runtime node comes from Mix release's `RELEASE_NODE` +
`RELEASE_DISTRIBUTION=name` — set both. For a deliberate generic console, boot with
`ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1` (serves nothing, every call routes remote). See
[Configuration → boot-time node policy](configuration.md#boot-time-node-policy).

### `{:nebula_error, {:no_worker, ...}}`

No worker is reachable for a method. `{:nebula_error, {:no_worker_on_node, node}}` means a
selector targeted a node that has no worker for the method. Checks:

1. **The server wasn't wired** (most common). Make sure the owning app does
   `use NebulaAPI.Server` + `nebula_api_server()`. (The `:nebula` compiler catches this at
   build time.)
2. **The target node isn't connected.** `Node.list()` should include it.
3. **The method isn't local on any connected node:**

```elixir
Process.whereis(MyApp.Users)                              # the local worker, if any
NebulaAPI.APIServer.registered_local_methods(MyApp.Users) # should include {:get, 1}
:pg.get_members(:pg_nebula_api, {MyApp.Users, {:get, 1}}) # should have ≥ 1 pid
```

### Timeout

The default RPC timeout is **5000 ms** (override per call, per module, or globally — see
[Configuration](configuration.md#default_timeout)). A timeout does **not** crash the
caller: a unicast call returns `{:nebula_error, :timeout}`; in multicast, the failure for a
given node is reported per-node as `{node, {:nebula_error, :timeout}}`.

If calls time out, check network latency (`Node.ping/1`), the target's load
(`:erlang.statistics(:run_queue)` on it), or make the operation faster. Other transport
faults follow the same shape: `{:nebula_error, {:selector_failed, reason}}` when a selector
function raises, `{:nebula_error, exception}` when the body raises.

### Process groups not syncing

If two connected nodes disagree on `:pg.get_members(:pg_nebula_api, ...)`:

```elixir
Process.whereis(:pg_nebula_api)     # the :pg scope should be running
:net_kernel.monitor_nodes(true)     # watch {:nodeup, node} / {:nodedown, node}
```

`:pg` syncs across connected nodes automatically — a desync usually means the cluster isn't
actually fully connected. Forming the Erlang cluster (epmd, DNS, libcluster) is the
consumer's concern.

### Tracing routing

```elixir
Logger.configure(level: :debug)
# [debug]   Will do remote execution on MyApp.Users
#   with fn_call : {:get, "abc"}
#   opts: []
```

## See also

- [Configuration](configuration.md) · [Defining APIs](defining.md) · [Calling across nodes](calling.md)
- [AST deep-dive](deep-dive/ast-deep-dive.md)
