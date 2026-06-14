# 1. Configuration

*The first thing to set up: which nodes exist, and what each one is for.*

This is the foundation every other page builds on. Read it first; then move on to
[Defining APIs](defining.md).

## The model: nodes and tags

A NebulaAPI cluster is a set of **nodes** — each one an Erlang VM with a unique name of the
form `short@host`:

```
api@api.example      # short name: api
db@db.example        # short name: db
worker@worker.example
```

Every node carries one or more **tags** — arbitrary atoms that describe what the node is
*for*: `:db`, `:worker`, `:cache`, `:cluster`, whatever fits your system. Tags are how you
route by capability instead of hard-coding machine names:

- multiple nodes can share a tag (`:db` on two machines = load distribution / replicas),
- a node can carry several tags (one box that's both `:api` and `:worker`).

You declare the whole map once, and the compiler reads it to decide what code goes where.

## The `nodes` option (required)

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example":       [:cluster, :api],
    "db@db.example":         [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
  ]
```

- **Node name** — an atom of the form `short@host` (quote it because of the `@`). In
  selectors you may use either the full name or the short part before `@`.
- **Tags** — a list of atoms. These are what `&tag` selectors match.

Workers are **not** configured here — each app wires `nebula_api_server()` into its own
supervision tree, which discovers its `defapi` modules and starts the workers. See
[Defining APIs → wiring the server](defining.md#wire-the-server-into-the-supervision-tree).

## Compile with the target node name

NebulaAPI decides routing at compile time, so the compiler has to know *which* node it is
building for — it reads `node()`. Compile each release with its own `--name`:

```bash
elixir --name api@api.example -S mix compile && mix release api
```

Forget `--name` and the build stops with a `CompileError`: `node()` would be
`nonode@nohost`, and a *missing* node name is distinct from an *unknown* one — so
`allow_unknown_self_node` does **not** cover it. (Opt into a nameless build with
[`allow_nonode_nohost`](#allow_nonode_nohost).)

Build each release in its own stage:

```dockerfile
# api release — compiled as node api@api.example
RUN elixir --name api@api.example -S mix compile && mix release api

# worker release — separate stage
RUN elixir --name worker@worker.example -S mix compile && mix release worker
```

### dev/test: `self_node` instead of `--name`

In dev and test you usually don't start the VM with `--name`. Tell the compiler which node
to pretend to be:

```elixir
# config/dev.exs
config :nebula_api,
  default_opts: [self_node: :"api@api.example"]
```

In production, prefer the real `--name` (then `node()` is authoritative).

## Boot-time node policy

Compile-time and runtime node names must agree: a release bakes its routing for the node it
was compiled as, so it must **run** as that node. The runtime node name comes from Mix
release's `RELEASE_NODE` + `RELEASE_DISTRIBUTION=name`
([docs](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-environment-variables)). At boot
`NebulaAPI.Server` enforces the match:

- **Running as exactly the compiled node** → serves normally — the only case that starts
  workers.
- **Running as anything else** → refuses to boot, with an explicit message: a worker build
  run as `api@host`, a build compiled without `--name` run under a real name, or a real build
  run as `nonode@nohost`. The escape hatch `ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1` boots it
  instead as a [generic node](../README.md#generic-nodes-serve-nothing-call-everything): no
  server, serves nothing, every call routes remote.
- **Compiled nameless and run as `nonode@nohost`** → a generic, inert node — no escape hatch
  needed (it's running exactly as built; see [`allow_nonode_nohost`](#allow_nonode_nohost)).

## `default_opts`

Defaults applied by every `use NebulaAPI`:

| Key | Type | Meaning |
|-----|------|---------|
| `self_node` | atom | The node to build for, when not starting the VM with `--name` (dev/test). |
| `max_concurrent_calls` | positive integer or `:infinity` | Cap on how many calls a module's worker runs at once on this node; `1` gives strict serialization. |
| `default_timeout` | positive integer (ms) | Inherited default remote-call timeout. |

A module's own `use NebulaAPI, ...` options override these.

`max_concurrent_calls` is a **server-side** cap: it bounds how many calls the module's worker
executes concurrently *on the node serving them*, not how many a caller may have in flight.
Calls over the cap **queue on the worker** until a slot frees — but the queue entry is tied to
the caller's lifetime, so if a queued call times out (or the caller goes away) before a slot
opens, it is dropped and **may never run**. `:infinity` (the default) means no cap.

```elixir
config :nebula_api,
  default_opts: [self_node: :"api@api.example", default_timeout: 10_000]
```

## `default_timeout`

Global default timeout (ms) for remote calls. Resolution order, most specific first:

```
a call's own timeout:  >  the module's default_timeout:  >  this  >  5000
```

```elixir
config :nebula_api, default_timeout: 15_000
```

## `nodes_info_refresh_interval`

How often (ms, default `5000`) each node's background `NodesInfoCache` rebuilds the
cluster node-info snapshot served to selector functions (see
[Calling across nodes → node info](calling.md#node-info-and-intelligent-routing)). Raise it
on larger clusters or when selectors tolerate staler data; until the first refresh, nodes
not yet in the snapshot are still offered to selectors with `runtime: nil`.

```elixir
config :nebula_api, nodes_info_refresh_interval: 10_000
```

### `allow_nonode_nohost`

`false` by default. Set it to `true` and `nonode@nohost` is registered as an empty, tagless
node, so a release compiled **without** `--name` builds (its `self_node` is admitted). Such a
build runs as `nonode@nohost`: `nebula_api_server()` is a no-op (no workers, a boot warning),
it serves nothing, and every `defapi` call routes remote. `nonode@nohost` isn't distributed,
so it's **inert** — out of cluster. It's a *generic node*; see
[the boot-time node policy](#boot-time-node-policy) and the README's
[Generic nodes](../README.md#generic-nodes-serve-nothing-call-everything).

You may **not** list `nonode@nohost` in `nodes` yourself — it's the reserved generic identity
and can't carry tags (doing so raises). This flag is the only way to admit it, always empty.

```elixir
config :nebula_api, allow_nonode_nohost: true
```

## Adding a node or a tag

Just edit the `nodes` list — add a node, or add a tag to an existing one:

```elixir
config :nebula_api,
  nodes: [
    "api@api.example":       [:cluster, :api],
    "db@db.example":         [:cluster, :db, :reporting],  # new :reporting tag
    "worker@worker.example": [:cluster, :worker],
    "cache@cache.example":   [:cluster, :cache]            # new node
  ]
```

Then use the new tag/node in a selector: `defapi &reporting, ...` or `defapi @cache, ...`.
Because routing is decided at compile time, a brand-new tag or node *name* means a
recompile — but bringing more instances of an *existing* role online needs nothing but
starting them.

If you cluster with [libcluster](https://hex.pm/packages/libcluster), remember to add the
node to your topology too — NebulaAPI only decides *what code goes where*; forming the
Erlang cluster (epmd, DNS, libcluster, …) is the consumer's concern.

## Reading configuration

```elixir
NebulaAPI.Config.nodes()         # => ["api@api.example": [:cluster, :api], ...]
NebulaAPI.Config.default_opts()
Application.get_env(:nebula_api, :nodes)
```

## Compile-time validation

NebulaAPI catches topology mistakes when you build, not when you ship.

### Unknown node

```elixir
defapi @nope, f() do ... end
```
```
Unknown nodes in defapi call :
	- @nope

Available nodes :
	- @api
	- @:"api@api.example"
	- @db
	- @:"db@db.example"
	- @worker
	- @:"worker@worker.example"
```

### Unknown tag

```elixir
defapi &nope, f() do ... end
```
```
Unknown tags in defapi call :
	- &nope

Available tags :
	- &api
	- &cluster
	- &db
	- &worker
```

### Unknown `self_node`

If you compile on a node not in `nodes` (and didn't set `allow_unknown_self_node: true`),
`use NebulaAPI` raises a `CompileError` telling you the `self_node` it saw and the
configured nodes.

`allow_unknown_self_node` is a per-module **`use` option**, not a config key — set it on the
module being compiled (`use NebulaAPI, allow_unknown_self_node: true`), for throwaway compiles
where the building node legitimately isn't part of the topology. It does **not** silence a
*missing* node name (`nonode@nohost`), which is a separate case — see
[No node name](#no-node-name) and [`allow_nonode_nohost`](#allow_nonode_nohost).

### No node name

If you compile without `--name` (so `node()` is `nonode@nohost`) and haven't set
[`allow_nonode_nohost: true`](#allow_nonode_nohost), `use NebulaAPI` raises a `CompileError`:
the name isn't *unknown*, it's *unset*, so `allow_unknown_self_node` does **not** silence it.
It's almost always a forgotten `--name`. See
[Compile with the target node name](#compile-with-the-target-node-name).

## Testing

Give your test node every tag, so all `defapi` bodies compile as local and your tests run
without a cluster:

```elixir
# config/test.exs
config :nebula_api,
  nodes: ["test@localhost": [:cluster, :api, :db, :worker]],
  default_opts: [self_node: :"test@localhost"]
```

## Next

- [Defining APIs](defining.md) — write `defapi` endpoints and wire the server.
- [Calling across nodes](calling.md) — call them, and override routing at runtime.
