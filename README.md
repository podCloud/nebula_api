# NebulaAPI

Transparent, safe cluster-wide APIs for Elixir — compile-time verified,
zero-overhead distributed calls.

Define your functions once. The compiler decides what runs where. Calls
across nodes look and feel like local function calls.

## The model in 30 seconds

A NebulaAPI cluster is a set of **nodes** (each one an Erlang VM, e.g.
`db@db.example`). Every node carries one or more **tags** — arbitrary atoms. No atom is
special; a tag can name a role (`:db`, `:worker`), a capability (`:cache`), or a whole
deployment (`:mainframe_cluster`, with the worker off in another cloud as
`:cloud_worker_lambda`). You declare the map once, in config:

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example":       [:mainframe_cluster, :api, :cache],
    "db@db.example":         [:mainframe_cluster, :db, :cache],
    "worker@worker.example": [:cloud_worker_lambda, :worker]
  ]
```

In your code you pick *where* things run with two sigils — by capability, or by
name:

- **`&tag`** — *any* node carrying that tag (picking by capability). `&db` reads
  as "wherever the `:db` tag lives"; the `&` turns the tag atom `:db` into a
  selector. Tags are lowercase atoms — `&db`, `&cache`, `&mainframe_cluster`.
- **`@node`** — pick a node by name. `@worker` is the **short** name (everything
  before `@`); when several nodes share it, `@worker` targets them all — that's a
  feature, see [short vs full names](#short-vs-full-names) for pinning exactly one.

`!` negates either one: `!&legacy` is "every node *without* the `:legacy` tag",
`!@backup` is "every node except `@backup`". These are **selectors** — they tell
the compiler which nodes get the real code.

Now write functions and tag each with the selector for where its body belongs:

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # `&db` → the body is compiled only on nodes carrying the :db tag.
  # On every other node, the same call becomes transparent RPC to a :db node.
  defapi &db, find(id) do
    Repo.get(User, id)        # %User{} or nil — returned verbatim, no wrapping
  end

  # A different capability, on different nodes: the cache lives on &cache nodes.
  defapi &cache, update_cache(id, user) do
    Cachex.put(:users, id, user)
  end
end
```

On a node tagged `:db`, `find/1` is a direct `Repo.get`; on every other node the same call
dispatches over Erlang distribution to a `:db` node and hands back the identical value. The
caller never knows which node ran it — and never has to. The body's value comes back as-is,
so you branch on it like any local call:

```elixir
# Same call on any node:
case MyApp.Users.find(42) do
  %User{} = user -> MyApp.Users.update_cache(user.id, user)
  nil            -> :not_found
end
```

That `update_cache/2` call carries `&cache`, so **by default it resolves on one node** —
locally if the caller is a `&cache` node, otherwise a single `&cache` worker (the first
registered one; it's a unicast, not a broadcast and not a race). The *other* `&cache` nodes
still hold a stale copy. When you mean "reach more than one", say so explicitly:

```elixir
# every &cache node serving the method
call_on_all_nodes do
  MyApp.Users.update_cache(user.id, user)
end

# one specific node
call_on_node @db do
  MyApp.Users.update_cache(user.id, user)
end

# every &cache node except @db — multicast, space-juxtaposed selector + negation
call_on_nodes &cache !@db do
  MyApp.Users.update_cache(user.id, user)
end
```

## What you get from compile-time

NebulaAPI resolves all routing decisions at compile time. This is not a
runtime router — it's a code generator that produces different bytecode
for each node. That buys you four things:

**No unnecessary deps.** Wrap a `use`, an `import`, or a child spec in `on_nebula_nodes` so
it exists only where it belongs:

```elixir
defmodule MyApp.Cache do
  use NebulaAPI

  on_nebula_nodes &cache do
    import Cachex, only: [put: 3]   # only &cache nodes even reference Cachex
  end

  defapi &cache, update_cache(id, user), do: put(:users, id, user)
end
```

The non-matching branch is absent from the bytecode, so a non-`&cache` node never loads
Cachex (gate the dependency itself the same way and it isn't even pulled in).

**Smaller binaries.** Code that doesn't belong on a node doesn't exist in its binary — a
`defapi` body is only emitted on matching nodes. Whole dependencies fall away the same way. The
[runnable demo](https://github.com/podCloud/NebulaAPI/tree/main/demo) pins Cachex to its
`db` node (`on_nebula_nodes @db` plus a conditional dep), so only that build carries Cachex
and its dependency tree (~570 KB); every other node never compiles it and comes out
**~38% smaller — ≈860 KB vs the db node's 1.4 MB** (measured, per-node `_build` from
`mix compile`). Your web node doesn't carry FFmpeg bindings; your worker doesn't carry
Phoenix routes.

**Compile-time safety.** Reference a tag or node that isn't in your topology and the build
stops — no silent RPC into the void:

```elixir
defapi @nope, f() do ... end
```
```
** (CompileError) Unknown nodes in defapi call :
	- @nope

Available nodes :
	- @api
	- @:"api@api.example"
	- @db
	- @:"db@db.example"
	- @worker
	- @:"worker@worker.example"
```

The `:nebula` compiler goes one further: an app with `defapi` modules but no
`nebula_api_server()` wired in fails to compile, instead of silently shipping workers that
never register:

```
Found 1 module(s) using NebulaAPI with local methods in app :my_app, but no
nebula_api_server() has been found in :my_app's supervisor — their RPC workers
will never start.

   App:         :my_app
   Application: MyApp.Application
                ^------ hint: add nebula_api_server() to its supervisor's children
   Modules using NebulaAPI (with local methods on this node):
         - MyApp.Users
```

**Zero runtime overhead.** A locally-resolved call is a direct function call — no routing
table, no RPC serialization, just a couple of process-dictionary reads to check for an
active routing context. Measured, that's **~60 ns** versus **~8 ns** for a plain call (see
[Performance](#performance)) — about **0.00005 ms** of overhead, free in any practical
sense. The decision was made once, at compile time.

> **"Compile per release" — the one mental shift.** NebulaAPI produces
> different bytecode per node, so each release is its own build. For Elixir
> devs used to a single runtime artifact, that's the surprising part. In
> practice it's one extra `elixir --name node@host -S mix compile` per
> release — a few seconds of CI, paid back many times over in smaller
> binaries, fewer dependencies, and zero routing overhead.

## How it works

Same source, different bytecode. Each release is compiled with its target node name (the
compiler reads `node()`), so a `&db` body is **real code** on a node that has `:db` and an
**RPC stub** everywhere else — the stub routes through `:pg` process groups to a node that
does have the body.

```
  defapi &db, find_user(id)
  ── compiled per node (--name) ──

  on a :db node
    → find_user/1 runs Repo.get locally

  on any other node
    → find_user/1 is an RPC stub
         │
         ▼  :pg groups
       a :db node's Worker runs Repo.get
```

## Reshape your topology without touching code

This is why NebulaAPI exists: the flexibility of umbrella releases, **without rewriting
code** every time you split a node out or stand up a new release. The same source ships as
one node or many — you change config and which releases you build, nothing else.

```elixir
# dev — one node wears every hat, a single release, every call local
nodes: ["dev@localhost": [:api, :db, :worker, :cache]]

# staging — pull the database onto its own node
nodes: [
  "app@app.staging": [:staging_cluster, :api, :worker, :cache],
  "db@db.staging":   [:staging_cluster, :db, :cache]
]

# prod — scale the workers out, keep one db; w3 lives in another cloud
nodes: [
  "app@app.prod":    [:mainframe_cluster, :api, :cache],
  "worker@w1.prod":  [:mainframe_cluster, :gpu],
  "worker@w2.prod":  [:alpha_cluster, :llm],
  "worker@w3.prod":  [:cloud_worker_lambda, :gpu, :storage],
  "db@db.prod":      [:mainframe_cluster, :db, :cache]
]
```

Moving `:db` off the app node, or fanning workers across three machines, is a config change
and a rebuild — never a code change. And the tags follow how you actually think about the
fleet: the three workers share the short name `worker@` (so `@worker` hits all of them
without any `:worker` tag), the deployment tag varies by environment and even by node
(`worker@w3.prod` is `:cloud_worker_lambda` — off in another cloud), and the capability
tags (`:gpu`, `:llm`, `:storage`) carve out *which* worker you mean (`@worker &gpu`). A tag
is just a label; slice the cluster however suits you.

## Installation

Add `:nebula_api` to your deps — from [Hex](https://hex.pm/packages/nebula_api):

```elixir
def deps do
  [
    {:nebula_api, "~> 0.5"}
  ]
end
```

Or track the repo directly (e.g. for an unreleased fix):

```elixir
def deps do
  [
    {:nebula_api, git: "git@github.com:podCloud/NebulaAPI.git", tag: "v0.5.1"}
  ]
end
```

## Quick start

### 1. Define your cluster topology

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example": [:mainframe_cluster, :api],
    "db@db.example": [:mainframe_cluster, :db],
    "worker@worker.example": [:alpha_cluster, :worker]
  ]
```

Each key is a full node name (`short@host`); each value is a list of capability
**tags** (see [the model above](#the-model-in-30-seconds)). In selectors you can
use the short name: `@db` matches `:"db@db.example"`, `@worker` matches
`:"worker@worker.example"` — when there's no ambiguity, short names are all you
need.

### 2. Define distributed functions

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # Body compiles on &db nodes. Everywhere else: transparent RPC.
  defapi &db, find(id) do
    Repo.get!(User, id)
  end
end
```

### 3. Wire a server into each app's supervision tree

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

`use NebulaAPI.Server` brings the `nebula_api_server/0` macro into scope (plus the
`on_nebula_nodes` / `call_on_*` macros) — without the `defapi` bookkeeping, since the host
module defines none of its own. Use it on the module that wires the server; use
`use NebulaAPI` on the modules that actually define `defapi` endpoints.

`nebula_api_server()` discovers the app's own modules that `use NebulaAPI` and starts a
supervised GenServer worker for each one that has local methods on this node; each worker
registers in `:pg` process groups for discovery across nodes. No module list to maintain —
and because the server lives in the app's own tree, its workers die with the app (so `:pg`
never holds stale entries).

#### Optional: guard against forgetting it

Add the `:nebula` compiler to catch a missing `nebula_api_server()` at compile time:

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers() ++ [:nebula]
  ]
end
```

If an app has modules with local methods but no `nebula_api_server()` wired into its
supervisor, `mix compile` fails with an explanatory error — the same spirit as the
compile error raised for a `defapi` targeting an unknown node. It also *warns* (without
failing the build) when an app wires `nebula_api_server()` but defines no `defapi` at all —
a server with nothing to serve.

In an **umbrella**, add `:nebula` to **each child app's** `compilers:` — a placement in the
umbrella-root `mix.exs` does nothing (`mix compile` recurses into the children and only runs
*their* compilers). One `compilers: Mix.compilers() ++ [:nebula]` per app that uses NebulaAPI.

### 4. Compile with the target node name

With the code and server in place, compile each release **as the node it will run as** —
NebulaAPI keys its codegen on `node()` at **compile time**, which you set with the `--name`
flag on `mix compile`:

```bash
elixir --name api@api.example -S mix compile && mix release api
```

Forget `--name` and the build stops with a clear `CompileError` (`node()` would be
`nonode@nohost` — the name isn't *unknown*, it's *unset*, so `allow_unknown_self_node`
won't paper over it). Set `allow_nonode_nohost: true` if you really mean a nameless
[generic build](#generic-nodes-serve-nothing-call-everything).

Build each release in its own stage, pinning the compile-time node name:

```dockerfile
# api release — compiled as node api@api.example
RUN elixir --name api@api.example -S mix compile && mix release api

# worker release — separate stage, compiled as node worker@worker.example
RUN elixir --name worker@worker.example -S mix compile && mix release worker
```

Then each release must **boot as that same node name**. That's a separate, *runtime*
concern, handled by [Mix release's own env vars](https://hexdocs.pm/mix/Mix.Tasks.Release.html#module-environment-variables)
— `RELEASE_NODE` (the node name) and `RELEASE_DISTRIBUTION` (`name` for fully-qualified
names across hosts; the default is `sname`):

```bash
# at run time, in the api container
RELEASE_DISTRIBUTION=name RELEASE_NODE=api@api.example bin/api start
```

The compile-time `--name` and the runtime `RELEASE_NODE` **must match** — that's the whole
contract: the routing was decided for `api@api.example` at build, so the release has to
actually be `api@api.example` when it runs. NebulaAPI enforces it: if the running node
differs from the one the release was compiled as, the server **crashes at boot** with a
clear message rather than misrouting silently — unless you opt into running it as a
[generic node](#generic-nodes-serve-nothing-call-everything). (`RELEASE_NODE` defaults to
`<release_name>@…` with short-name distribution, so set it explicitly to get the
fully-qualified name.)

In dev/test, you typically don't start the VM with `--name`. Use
`default_opts` to tell the compiler which node to pretend to be:

```elixir
# config/dev.exs
config :nebula_api,
  default_opts: [self_node: :"api@api.example"]
```

### 5. Call it — local or remote, same API

```elixir
# On @db (has &db) → local Repo.get!
MyApp.Users.find(42)
#=> %User{id: 42, ...}

# On @worker (no &db) → transparent RPC to a &db node
MyApp.Users.find(42)
#=> %User{id: 42, ...}
```

## Selectors

Selectors tell the compiler which nodes get the real implementation. Every other node
gets a *stub* in its place — a generated function that forwards the call over RPC to a
node that does have the body.

| Syntax | Meaning |
|---|---|
| `&tag` | Nodes with this tag |
| `!&tag` | Nodes without this tag |
| `@node` | Specific node (short or full name) |
| `!@node` | All nodes except this one |
| *(no selector)* | Every node — the body is local everywhere |

Combine selectors by **juxtaposing them with a space** — no commas between them, no
brackets. This is the canonical NebulaAPI syntax, and it's what keeps the code readable
(`&db !@backup` reads as "a `:db` node, but not `@backup`"):

```elixir
# Nodes with the :db tag, excluding @backup
defapi &db !@backup, run_migration(version) do
  Ecto.Migrator.run(Repo, :up, to: version)
end

# Specific node only
defapi @worker, transcode(input, opts) do
  FFmpex.new_command()
  |> FFmpex.add_input_file(input)
  |> FFmpex.add_output_file(opts[:output])
  |> FFmpex.execute()
end

# No selector → the body is local on every node, each returning its own data
defapi get_node_health() do
  %{node: node(), uptime: :erlang.statistics(:wall_clock) |> elem(0)}
end
```

### Short vs full names

In config, node names are full Erlang names — `short@host`. In a selector you can use just
the **short** part (everything before `@`), which keeps call sites readable:

```elixir
# Equivalent when only one node is named "db@…":
defapi @db, do_something() do ... end
defapi @:"db@db.example", do_something() do ... end   # full name as an atom
```

The full-name form is `@:"name@host"` (an atom, because of the `@`) — and `!@:"name@host"`
to negate it.

**The short name is intentionally "many": that's a feature.** A short name matches *every*
node that shares it, which is usually exactly what you want for a horizontally-scaled role.
Picture three nodes running the same `worker` release on three hosts (as the
[runnable demo](https://github.com/podCloud/NebulaAPI/tree/main/demo) does), each kitted out
differently:

```elixir
"worker@worker1.test": [:alpha_cluster, :gpu, :storage],
"worker@worker2.test": [:beta_server, :llm],
"worker@worker3.test": [:alpha_cluster, :vps]
```

`@worker` targets *all three* — every node whose release name is `worker`, across hosts,
whatever capability tags they happen to carry. To pin exactly one, reach for its full name:
`@:"worker@worker2.test"`.

### What gets generated

For each `defapi`, the macro generates:

1. **`<name>/N`** — the public router callers actually invoke.
2. **`__nbapi_remote_<name>/N`** — RPC dispatch via `APIServer`, on **every** node.
3. **`__nbapi_local_<name>/N`** — the real body, on **matching nodes only**. Elsewhere
   nothing is emitted: the router goes remote there, so there's no stub to keep.

The remote function is generated on **every** node, including nodes
that have the local implementation. This is what makes `call_on_node`
and `call_on_nodes` work from anywhere — even a `&db` node can call
other `&db` nodes remotely for quorum writes, load distribution, etc.

## Router and priorities

The public router on each `defapi` decides where a call goes, from the default outward —
the more explicit you get, the more it wins. Take the same call, `MyApp.Cache.get(key)`:

1. **Default** — `MyApp.Cache.get(key)` runs locally if this node serves the method,
   otherwise a single remote call (unicast).
2. **Wrapped in a block** — the same call inside `call_on_nodes &cache do … end` routes per
   the block instead.
3. **Its own trailing opts win over the block** — `MyApp.Cache.get(key, multicast: true)`
   routes itself, even inside a block; a routing key set to `nil` / `false` opts the call
   back out to the default.

**Default unicast goes to the first node on the `:pg` list that serves the method — never
the others.** Concretely that's the first node serving the API that connected to NebulaAPI
(joined the method's `:pg` group); that's the only node that runs the call. No fan-out, no
load-balancing by default. Membership is live, though: if that node drops, `:pg` removes it,
so the next call simply lands on whoever is now first among the nodes still connected. (Want
several nodes at once, a specific one, a random one, or a load-aware pick? That's
[runtime routing](#runtime-routing).)

## `on_nebula_nodes` — conditional compilation

Include or exclude entire blocks of code based on the current node.
Unlike `defapi`, this works at any level — module body, `use`
directives, supervision trees:

```elixir
defmodule MyApp.Repo do
  use NebulaAPI.AST

  # Only connect to the database on &db nodes.
  # Other nodes don't even load Ecto.
  on_nebula_nodes &db do
    use Ecto.Repo, otp_app: :my_app
  end
end

defmodule MyApp.Application do
  use NebulaAPI.AST

  # Start the FFmpeg pool only on worker nodes
  on_nebula_nodes &worker do
    def extra_children, do: [MyApp.TranscoderPool]
  else
    def extra_children, do: []
  end
end
```

The non-matching branch is completely absent from the compiled bytecode. A module that
does only this can `use NebulaAPI.AST` — the lightest entry point, no `defapi` bookkeeping.

## Runtime routing

The selector on a `defapi` is the *default* route. Sometimes you need to override it at
runtime — send one call to a specific node, fan it out to several, or pick a node by load.
Three macros wrap a block to do that, named after how far the call goes:

- **`call_on_node`** — *unicast*: run on exactly one node.
- **`call_on_nodes`** — *multicast*: run on every node a selector matches.
- **`call_on_all_nodes`** — *broadcast*: run on every node that serves the method.

### `call_on_node` — unicast

```elixir
# Force execution on a specific node
call_on_node @worker do
  MyApp.Jobs.transcode(file, opts)
end

# Pick a node dynamically based on runtime info — least loaded
call_on_node fn nodes_info ->
  nodes_info
  |> Enum.filter(fn {_, info} -> info.connected && info.runtime end)
  |> Enum.min_by(fn {_, info} -> info.runtime.memory_percent end)
  |> elem(0)
end do
  MyApp.HeavyTask.run()
end

# Or just pick one at random
call_on_node fn nodes_info -> nodes_info |> Map.keys() |> Enum.random() end do
  MyApp.Jobs.transcode(file, opts)
end
```

### `call_on_nodes` — multicast

```elixir
# Call all &worker nodes, wait for all results
call_on_nodes &worker, strategy: :all, timeout: 30_000 do
  MyApp.Jobs.health_check()
end

# First to respond wins
call_on_nodes &worker, strategy: :first do
  MyApp.Jobs.transcode(file, opts)
end

# Quorum: a strict majority of the configured &db nodes must succeed (the default).
# A single live node out of three configured refuses — that's the point of a quorum.
call_on_nodes &db, strategy: :quorum do
  MyApp.Users.write_replica(user)
end

# A selector function over live node info — fan out only to nodes seen recently
call_on_nodes fn nodes_info ->
  cutoff = DateTime.add(DateTime.utc_now(), -30, :second)
  nodes_info
  |> Enum.filter(fn {_, i} -> i.last_seen_at && DateTime.compare(i.last_seen_at, cutoff) == :gt end)
  |> Enum.map(&elem(&1, 0))
end, strategy: :all do
  MyApp.Cache.invalidate(:all)
end
```

### `call_on_all_nodes` — broadcast

```elixir
call_on_all_nodes timeout: 5_000 do
  MyApp.Cache.invalidate(:all)
end
```

### Multicast strategies

Results are always tagged per node — `{node, value}` on success,
`{node, {:nebula_error, reason}}` for a node whose call failed at the transport level.

| Strategy | Behavior |
|---|---|
| `:all` | Wait for every node (or timeout). Returns a list of `{node, value}`. |
| `:first` | Return the first response that counts as a success (then stop waiting on the rest — the pending tasks are brutal-killed); `{:nebula_error, :no_success, results}` if none. |
| `:quorum` | Wait for a strict majority of the quorum set, or an exact `at_least:` count. The set is the **configured** nodes serving the method (`quorum: :configured`, the default — connected or not, so a single live node can't pass a 3-node quorum) or the connected workers (`quorum: :available`). The moment the quorum is reached it stops waiting on the rest (same brutal-kill as `:first`); fails fast (`:quorum_unreachable`) when the live set can't reach it. |

> "Stops waiting" is exactly that: once you have what you asked for (a first success, or
> the quorum), the rest is just wasted waiting — so NebulaAPI kills the local tasks still
> awaiting a reply and discards their late responses. A body that already started running on
> a remote node isn't aborted — the RPC was already sent.

`:first` and `:quorum` let you define what counts as a success with a `success:` (or
`failure:`) predicate — by default, any node that responded counts:

```elixir
# A write quorum that only accepts {:ok, _} replies
call_on_nodes &replica, strategy: :quorum, success: &match?({:ok, _}, &1) do
  MyApp.Store.write(key, value)
end
```

## Node info and intelligent routing

`call_on_node` and `call_on_nodes` accept selector functions that
receive live runtime data about every node:

```elixir
%{
  short_name: :db,
  long_name: :"db@db.example",
  host: "db.example",
  tags: [:mainframe_cluster, :db],
  connected: true,
  last_seen_at: ~U[2024-06-15 12:00:00Z],
  runtime: %{
    memory_used_mb: 256,
    memory_total_mb: 1024,
    memory_percent: 25.0,
    process_count: 1542,
    schedulers: 8,
    otp_release: "26",
    uptime_seconds: 86400
  }
}
```

A node whose worker just registered but isn't in the background snapshot yet still appears,
with `runtime: nil` / `last_seen_at: nil` until the next refresh — so filter on
`info.runtime` before reading through it.

```elixir
# Route to the node with the most headroom
call_on_node fn nodes_info ->
  nodes_info
  |> Enum.filter(fn {_, info} -> info.connected && info.runtime end)
  |> Enum.min_by(fn {_, info} -> info.runtime.memory_percent end)
  |> elem(0)
end do
  MyApp.HeavyTask.run()
end

# Only call nodes seen in the last 30 seconds
call_on_nodes fn nodes_info ->
  cutoff = DateTime.add(DateTime.utc_now(), -30, :second)
  nodes_info
  |> Enum.filter(fn {_, info} ->
    info.last_seen_at && DateTime.compare(info.last_seen_at, cutoff) == :gt
  end)
  |> Enum.map(&elem(&1, 0))
end do
  MyApp.Cache.invalidate(:all)
end
```

## Return values

NebulaAPI **never wraps** your return value. A `defapi` body returns exactly what it
computed — local or over RPC, the result is identical:

```elixir
defapi &db, find(id) do
  Repo.get(User, id)      # returns %User{} or nil
end

find(1)        #=> %User{...}
find(999)      #=> nil

# Tuples you return yourself are passed through untouched, including your own
# {:ok, _} / {:error, _}:
defapi &db, create(attrs) do
  Repo.insert(User.changeset(attrs))  # {:ok, user} or {:error, changeset}
end

create(%{name: "Ada"})   #=> {:ok, %User{...}}
create(%{})              #=> {:error, %Ecto.Changeset{...}}
```

The one value the library *does* inject is a `:nebula_error` tuple — a **library or
transport** failure (a timeout, no worker available, a crashing body, a quorum that wasn't
reached), never a business outcome. So any `:ok` / `:error` you ever see is **yours**, and
you never have to guess whether an `{:error, _}` came from your code or the framework. An
exception, throw or exit escaping a body is reported the same way — identically whether the
body ran locally or remotely.

Its shape depends on the scope of the failure. A **single-node** failure (unicast, or one
node inside a multicast result) is the 2-tuple `{:nebula_error, reason}`. A **whole-call**
multicast failure carries an extra element with the partial results — `{:nebula_error,
:no_success, results}`, `{:nebula_error, :quorum_not_reached, results}`,
`{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` (see
[Calling → multicast results](docs/calling.md#multicast-results)). Match the 3-tuples when
you handle a `:first` / `:quorum` call's top-level outcome, not just `{:nebula_error, _}`.

## Wrap any single-node library

Here's the pattern that tends to click: **NebulaAPI turns any single-node
library into a cluster-wide one without touching the library.** No fork, no
monkey-patch — just a few lines of `defapi` that delegate to it on a chosen
node.

If you've ever thought *"I'd love to use Cachex / a counter / a cron here, but
its state is per-node, so now I need Redis / a shared DB / `:global` locks…"* —
this is the escape hatch. The library stays exactly as it is. You pin it to one
node and wrap it.

```elixir
# Cachex runs only on the @cache node; every node shares one cache through the wrapper.
defmodule MyApp.Cache do
  use NebulaAPI

  defapi @cache, get(key),        do: Cachex.get(:app_cache, key)
  defapi @cache, put(key, value), do: Cachex.put(:app_cache, key, value)
end
```

Any node calls `MyApp.Cache.get/1`; it resolves locally on `@cache` and routes
transparently everywhere else. One shared cache, no Redis. The same trick gives you
cluster-wide rate limiters, counters, run-once-per-cluster schedulers, singleton
coordinators, and feature-flag stores.

> **An honest caveat.** This is great for values read often and invalidated rarely
> (dynamic config, reference data). But for a hot path doing thousands of reads per second
> per node, every read becomes an RPC round-trip — that's the **wrong** use, and a real
> distributed cache (Redis, or `:mnesia`) stays better. NebulaAPI is the right tool when
> the access pattern fits, not a universal replacement for a distributed cache.

## Worked example: a 3-role cluster

Three nodes, three roles — an API front, a database node, and a worker:

```elixir
config :nebula_api,
  nodes: [
    "api@api.example": [:mainframe_cluster, :api],
    "db@db.example": [:alpha_server, :db],
    "worker@worker.example": [:mainframe_cluster, :gpu]
  ]
```

### Data access — `&db` nodes only

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  defapi &db, get(id) do
    Repo.get(User, id)
  end

  defapi &db, list(filters \\ []) do
    User |> where_filters(filters) |> Repo.all()
  end

  # A plain def — no defapi: keep utils and pure business logic local, on every release.
  def user_name(%User{nickname: name}), do: name

  # Helper only exists on &db nodes
  on_nebula_nodes &db do
    defp where_filters(query, filters) do
      Enum.reduce(filters, query, fn {k, v}, q -> where(q, [u], field(u, ^k) == ^v) end)
    end
  end
end
```

### Background jobs — `@worker` only

```elixir
defmodule MyApp.Jobs do
  use NebulaAPI

  # @worker targets the worker node by its (short) name — no :worker tag needed.
  defapi @worker, transcode(input, opts) do
    FFmpex.new_command()
    |> FFmpex.add_input_file(input)
    |> FFmpex.add_output_file(opts[:output])
    |> FFmpex.execute()
  end

  # @worker AND &gpu — a faster path that only the GPU-equipped workers carry.
  defapi @worker &gpu, quick_transcode(input, opts) do
    GpuTranscoder.run(input, opts)
  end
end
```

### Conditional application setup

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    # Only the &db node starts the Repo; everyone runs the nebula server.
    children =
      [nebula_api_server()] ++
        on_nebula_nodes &db do
          [MyApp.Repo]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

### Cross-node calls from a web controller

```elixir
defmodule MyAppWeb.UserController do
  def show(conn, %{"id" => id}) do
    # "Just works" on any node. Local on @db, RPC everywhere else.
    # get/1 returns the struct (or nil) directly — no wrapping.
    case MyApp.Users.get(id) do
      %MyApp.User{} = user -> render(conn, :show, user: user)
      nil -> send_resp(conn, 404, "Not found")
    end
  end

  def transcode(conn, %{"path" => path}) do
    # Explicitly route to a worker, even if we have the code locally
    call_on_node @worker do
      MyApp.Jobs.transcode(path, output: "/tmp/out.mp3")
    end
  end
end
```

## When NOT to use NebulaAPI

Being honest about the edges:

- **External clients.** If the caller isn't a node in your Erlang cluster — a
  public web client, a non-Elixir mobile app — gRPC or REST is still the right
  boundary. NebulaAPI is for intra-cluster calls.
- **Node names unknown at build time.** NebulaAPI needs your node names and tags in
  config when you compile. The nodes themselves can come up and go down freely at
  runtime — workers register and drop through `:pg`, and selectors only ever route to
  what's actually connected. What it can't handle is a node whose *name* wasn't known at
  build time: an unbounded fleet of randomly-named pods has no compiled identity to route
  to — though a fixed, generic *caller* node is easy (see
  [generic nodes](#generic-nodes-serve-nothing-call-everything)). Scaling the count of *known* roles
  is fine; minting brand-new node identities at
  runtime is not.
- **Topologies whose roles change at runtime.** Adding a wholly new tag or node *name* to
  the cluster means a recompile — NebulaAPI decided the routing at build time. Bringing
  more instances of an existing role online needs nothing but starting them.

## Performance

Measured by [`bench/routing.exs`](bench/routing.exs) on OTP 26 (run it yourself with
`elixir --name bench@127.0.0.1 --cookie nebula_bench -S mix run bench/routing.exs`):

| Call | Per call |
|---|---|
| Plain local Elixir call (baseline) | ~8 ns |
| NebulaAPI, resolved local | ~60 ns |
| Cross-node round-trip, same host (loopback) | ~50 µs |

The point: a locally-resolved NebulaAPI call adds only a handful of nanoseconds over a
plain call — a couple of process-dictionary reads and a `cond` — so it's free in any
practical sense. A cross-node call is a standard Erlang-distribution round-trip; the ~50 µs
above is loopback (same host), and over a real network you pay link latency on top
(commonly ~0.2–2 ms). Either way the rule of thumb holds: resolve local whenever you can,
and a cross-node hop costs roughly what a distributed `GenServer.call` costs — no more.

## Configuration reference

```elixir
config :nebula_api,
  # Required: cluster topology — tags per node.
  # Used at compile time to decide what code goes where.
  nodes: [
    "api@api.example": [:mainframe_cluster, :api, :cache],
    "db@db.example": [:mainframe_cluster, :db, :cache],
    "worker@worker.example": [:cloud_worker_lambda, :worker]
  ],

  # Optional: override node identity for dev/test.
  # In production, compile with: elixir --name node@host -S mix compile.
  # default_opts also accepts inherited defaults for every `use NebulaAPI` module:
  # max_concurrent_calls: and default_timeout:.
  default_opts: [self_node: :"api@api.example"],

  # Optional: global default timeout (ms) for remote calls.
  # Per-call timeout: > per-module default_timeout: > this > 5000.
  default_timeout: 5_000,

  # Optional: how often (ms) each node's background NodesInfoCache rebuilds
  # the node-info snapshot served to selector functions.
  nodes_info_refresh_interval: 5_000
```

## Generic nodes: serve nothing, call everything

A release is normally tied to one node: it must run as the node it was compiled for (see
[the boot policy](#4-compile-with-the-target-node-name)). A **generic node** is the
exception — a node that serves nothing (no workers, registers nothing in `:pg`) and routes
**every** `defapi` call remotely. To actually reach the cluster it must be **distributed** (a
real `name@host`); a `nonode@nohost` build can't join a cluster (`Node.connect` is a no-op
there), so it stays **inert** — safe, but it calls no one. Two ways to get one:

**1. A dedicated server-less build (`allow_nonode_nohost`).** Set the flag and compile
**without** `--name`, so `node()` is `nonode@nohost` and every `defapi` compiles as a pure
remote stub — no local bodies, no server, the smallest binary:

```elixir
config :nebula_api, nodes: [ ...the real cluster nodes... ], allow_nonode_nohost: true
```
```bash
mix compile && mix release console   # no --name → a generic, server-less build
```

The flag registers `nonode@nohost` as an empty, tagless node so the build compiles cleanly
(you can't list it in `:nodes` yourself — it's reserved; the flag is the only way to admit
it). Run it as `nonode@nohost` and it's inert; launch it under a **real** name to make it a
connected, calls-everything client.

**2. Any build, repurposed.** No dedicated build on hand? Boot an existing release (a
`worker`, an `api`) under a node name that *isn't* the one it was compiled for. It serves
nothing and routes every call remote just the same — you only carry the extra local bodies
that build happens to contain.

Either way, launching under a name that isn't the compiled one is a node mismatch, so you opt
in with `ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1` (keep `allow_nonode_nohost` in the build that
wants it, not the shared cluster config). The operational recipe — a prod console, a debug
shell — is in
[Calling → spawning a generic node](docs/calling.md#spawning-a-generic-node-debug-or-call-anything-remotely).

## But wait — how do the nodes actually connect?

NebulaAPI decides *what code goes where*; it does **not** form the Erlang cluster. That's
deliberate — clustering is your call, and the library stays agnostic. All it needs is that
the nodes are connected Erlang nodes (so `:pg` syncs and distribution RPC flows); *how* they
find each other is entirely up to you. Anything that ends up calling `Node.connect/1` works:

- **[libcluster](https://hex.pm/packages/libcluster)** — the usual answer. Pick a strategy
  for your environment: `Gossip` on a flat network, `Kubernetes` / `Kubernetes.DNS` on k8s,
  `EpmdDNS` behind a headless service, or a static `Epmd` list for a fixed fleet. Point its
  topology at the same node names you put in `config :nebula_api, :nodes`. (The
  [runnable demo](https://github.com/podCloud/NebulaAPI/tree/main/demo) does exactly this
  with libcluster's `Epmd` strategy over a Docker network.)
- **Plain epmd + `Node.connect/1`** — for a handful of known hosts, a few `Node.connect`
  calls at boot (or `-kernel sync_nodes_mandatory ...` in `vm.args`) are enough.
- **Anything else** — a custom strategy, a service-discovery hook, manual connects from a
  release `env.sh`. NebulaAPI never looks; it only ever reads `node()` and `:pg`.

Two practical notes: share the **same cookie** across the cluster, and use **long names**
(`name@host`, `RELEASE_DISTRIBUTION=name`) so the running node names match what you compiled
for. Once the nodes are connected, NebulaAPI's workers register in `:pg` and routing just
works.

## Architecture

Two halves: a **compile-time** code generator (`AST.Parser` / `AST.Builder` / `Config`,
which fail the build on an unknown tag or node) and a small **runtime** layer
(`NebulaAPI.Server` per app starting a `Worker` per locally-served module, `APIServer`
holding the `:pg` routing and the node-info ETS cache).

```
  COMPILE TIME
  · AST.Parser   selectors → tags/nodes
  · AST.Builder  emits the defapi funs
  · Config       resolves & validates
             (CompileError if unknown)
        │  per-node bytecode
        ▼
  RUNTIME
  · NebulaAPI.Server  one Worker per
       locally-served module, per app
  · APIServer  :pg routing + node cache
  · Worker     registers methods in :pg
```

## Seeing where things route

`mix nebula.routes` prints a "git lola"-style map of where every `defapi` is served — one
continuous rail per node, a `●` where each method is local, the rail (`|`) where it isn't:

```
mix nebula.routes               # static: ● local · | not local here (config-known)
mix nebula.routes --available   # live overlay from :pg + Node.list (∆ remote-ok · x worker down · X node down)
mix nebula.routes --follow      # refresh every 5s (implies --available)
mix nebula.routes --sort locality   # most-local-first (also: module [default], name)
```

The static view asserts only **locality** (compile-time) — it makes no claim that a method
actually runs remotely, so non-local cells are just the rail. From a running node, the same map
without leaving iex: `NebulaAPI.Server.print_routes()` (or `print_routes(available: true)`).
For a single method, `NebulaAPI.APIServer.configured_nodes/2` (compile-time set) and
`available_nodes/2` (live `:pg`). The map lists only what *this* build carries — see
[Calling → Seeing the whole routing map](docs/calling.md#seeing-the-whole-routing-map).

## Documentation

This README is the whole picture. The [`docs/`](docs/README.md) pages go deeper, in the order you
meet each theme:

1. [Configuration](docs/configuration.md) — nodes, tags, topology, compile-per-node, dev/test, validation
2. [Defining APIs](docs/defining.md) — the three `use` macros, `defapi`, selectors, return values, `on_nebula_nodes`, wiring the server
3. [Calling across nodes](docs/calling.md) — calling endpoints, `call_on_*`, multicast strategies, node-info routing, introspection, the routing map (`mix nebula.routes` / `print_routes`), wrapping single-node libraries, spawning a generic node
4. [Gotchas and troubleshooting](docs/gotchas.md) — trailing opts, process scope, the `nil`-selector distinction, common errors

Deep dive:

- [AST deep-dive](docs/deep-dive/ast-deep-dive.md) — how the per-node code is generated

See also [About LLMs](ABOUT-LLMS.md) — how (and how much) LLMs were used to build this library.

## License

MIT
