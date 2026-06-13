# NebulaAPI

Transparent, safe cluster-wide APIs for Elixir — compile-time verified,
zero-overhead distributed calls.

Define your functions once. The compiler decides what runs where. Calls
across nodes look and feel like local function calls.

First, declare your cluster as a map of nodes to capability **tags**:

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
  ]
```

You target those nodes with **selectors**: `@node` picks a node by its name (short or
full), and `&tag` picks every node carrying that capability tag — so `&db` means "any
`:db` node". Now define a function and declare where its body runs:

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # The body compiles on &db nodes. Everywhere else, the same call is transparent RPC.
  defapi &db, find(id) do
    Repo.get!(User, id)
  end
end

# On any node — same call, same result:
MyApp.Users.find(42)
#=> %User{id: 42, ...}
```

On a node tagged `:db`, `find/1` is a direct `Repo.get!`. On every other node, the same
call dispatches over Erlang distribution to a `&db` node. The caller never knows.

## Why compile-time?

NebulaAPI resolves all routing decisions at compile time. This is not a
runtime router — it's a code generator that produces different bytecode
for each node.

**Smaller binaries.** Code that doesn't belong on a node doesn't exist
in its binary. Your web node doesn't carry FFmpeg bindings. Your worker
doesn't carry Phoenix routes.

**No unnecessary deps.** Wrap a `use` or a child spec in `on_nebula_nodes` (conditional
compilation, [below](#on_nebula_nodes--conditional-compilation)) to `use Ecto.Repo` or
start a supervisor only where it belongs. Nodes that don't touch the database never load
Ecto at all.

**Compile-time safety.** Reference a tag or node that doesn't exist in
your topology? `CompileError`. Typo in a node name? Caught before it
ships. No silent RPC calls into the void.

**Zero runtime overhead.** A locally-resolved call is a direct function call — no routing
table, no RPC serialization, just a couple of process-dictionary reads to check for an
active routing context. The decision was made once, at compile time.

> **"Compile per release" — the one mental shift.** NebulaAPI produces
> different bytecode per node, so each release is its own build. For Elixir
> devs used to a single runtime artifact, that's the surprising part. In
> practice it's one extra `elixir --name node@host -S mix compile` per
> release — a few seconds of CI, paid back many times over in smaller
> binaries, fewer dependencies, and zero routing overhead.

## Route business code to the right node — automatically

Write your calls as plain business calls. NebulaAPI sends each one to the node that
actually implements it — no `GenServer.call` to a named node, no RPC plumbing, no "which
node am I on?":

```elixir
# A web request handler runs on the api node, but reads and encodes elsewhere:
def show(conn, %{"id" => id}) do
  user  = MyApp.Users.get(id)           # resolves on a &db node
  thumb = MyApp.Media.thumbnail(user)   # resolves on a &worker node
  render(conn, :show, user: user, thumb: thumb)
end
```

Each `defapi` already knows where it lives. You write the *business* logic; the topology
is a compile-time detail.

## Reshape your topology without touching code

This is why NebulaAPI exists: the flexibility of umbrella releases, **without rewriting
code** every time you split a node out or stand up a new release. The same source ships as
one node or many — you change config and which releases you build, nothing else.

```elixir
# dev — one node wears every hat, a single release, every call local
nodes: ["dev@localhost": [:api, :db, :worker]]

# staging — pull the database onto its own node
nodes: [
  "app@app.staging": [:api, :worker],
  "db@db.staging":   [:db]
]

# prod — scale the workers out, keep one db
nodes: [
  "app@app.prod":    [:api],
  "worker@w1.prod":  [:worker],
  "worker@w2.prod":  [:worker],
  "worker@w3.prod":  [:worker],
  "db@db.prod":      [:db]
]
```

Moving `:db` off the app node, or fanning `:worker` across three machines, is a config
change and a rebuild — never a code change. The
[runnable demo](https://github.com/podCloud/NebulaAPI/tree/main/demo) boots exactly this
kind of multi-node cluster from one codebase.

## How it works

```
┌─────────────────────────────────────────────────────────┐
│                    Source code (same)                    │
│                                                         │
│   defapi &db, find_user(id) do                          │
│     Repo.get(User, id)                                  │
│   end                                                   │
└────────────────────┬────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          │  mix compile        │
          │  --name node@host   │
          ▼                     ▼
   ┌─────────────┐      ┌─────────────┐
   │   @alpha     │      │   @beta     │
   │  (has &db)   │      │  (no &db)   │
   ├─────────────┤      ├─────────────┤
   │ find_user/1 │      │ find_user/1 │
   │ → Repo.get  │      │ → RPC call  │
   │   (local)   │      │   (remote)  │
   └─────────────┘      └──────┬──────┘
                               │
                        :pg process groups
                               │
                        ┌──────▼──────┐
                        │   @alpha    │
                        │   Worker    │
                        │   Repo.get  │
                        └─────────────┘
```

Same source, different bytecode. Each release is compiled with its
target node name — the compiler reads `node()` to know who it's
building for. For the full mechanics, see [Concepts](docs/concepts.md) and the
[AST deep-dive](docs/deep-dive/ast-deep-dive.md).

## Installation

```elixir
def deps do
  [
    {:nebula_api, git: "git@github.com:podCloud/NebulaAPI.git", tag: "v0.4.0"}
  ]
end
```

## Quick start

The four moving parts below are the whole setup; the full walkthrough is in
**[Getting started](docs/guides/getting-started.md)**.

### 1. Define your cluster topology

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
  ]
```

Each key is a full node name (`short@host`). Each value is a list of
capability tags — arbitrary atoms that describe what the node can do.

Node selectors can use either the full name or the short name (the part
before `@`). So `@db` matches `:"db@db.example"`, `@worker` matches
`:"worker@worker.example"`, etc. When there's no ambiguity, short names
are all you need. See [Configuration](docs/configuration.md) for every option.

### 2. Compile with the target node name

```bash
elixir --name api@api.example -S mix compile
```

The compiler needs `node()` to return the right value so it knows which
code to keep and which to stub out. Each release is compiled separately:

```dockerfile
# Build for the api node
ENV RELEASE_NODE=api@api.example
RUN elixir --name ${RELEASE_NODE} -S mix compile && mix release api

# Build for the worker (separate stage)
ENV RELEASE_NODE=worker@worker.example
RUN elixir --name ${RELEASE_NODE} -S mix compile && mix release worker
```

In dev/test, you typically don't start the VM with `--name`. Use
`default_opts` to tell the compiler which node to pretend to be:

```elixir
# config/dev.exs
config :nebula_api,
  default_opts: [self_node: :"api@api.example"]
```

### 3. Define distributed functions

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # Body compiles on &db nodes. Everywhere else: transparent RPC.
  defapi &db, find(id) do
    Repo.get!(User, id)
  end
end
```

### 4. Wire a server into each app's supervision tree

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
module has none of its own. Use it on the module that wires the server; use `use NebulaAPI`
on the modules that actually define `defapi` endpoints.

`nebula_api_server()` discovers the app's own modules that `use NebulaAPI` and starts a
supervised GenServer worker for each one that has local methods on this node; each worker
registers in `:pg` process groups for discovery across nodes. The set is discovered, never
declared — and because the server lives in the app's own tree, its workers die with the
app (so `:pg` never holds stale entries). See
[Server and compiler](docs/server-and-compiler.md).

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
compile error raised for a `defapi` targeting an unknown node.

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

Selectors tell the compiler which nodes should get the real
implementation. Everything else gets a remote stub.

| Syntax | Meaning |
|---|---|
| `&tag` | Nodes with this tag |
| `!&tag` | Nodes without this tag |
| `@node` | Specific node (short or full name) |
| `!@node` | All nodes except this one |
| `:*` | All nodes (local implementation everywhere) |

Combine selectors with commas:

```elixir
# Nodes with &db tag, excluding @backup
defapi &db, !@backup, run_migration(version) do
  Ecto.Migrator.run(Repo, :up, to: version)
end

# Specific node only
defapi @worker, transcode(input, opts) do
  FFmpex.new_command()
  |> FFmpex.add_input_file(input)
  |> FFmpex.add_output_file(opts[:output])
  |> FFmpex.execute()
end

# Every node gets its own local copy
defapi :*, health_check() do
  %{node: node(), uptime: :erlang.statistics(:wall_clock) |> elem(0)}
end
```

### Short names

In the config, node names are full Erlang names (`short@host`). In
selectors, you can use just the short part:

```elixir
# These are equivalent when there's no ambiguity:
defapi @db, do_something() do ... end
defapi @:"db@db.example", do_something() do ... end
```

This keeps your code readable. `@db` and `@worker` are clear
enough — the host part is infrastructure detail. The full selector grammar and every
option live in the **[Macros reference](docs/macros-reference.md)**.

### What gets generated

For each `defapi`, the macro generates:

1. **`__nbapi_remote_<name>/N`** — RPC dispatch via `APIServer`, on **every** node.
2. **`<name>/N`** — the public router callers actually invoke.
3. **`__nbapi_local_<name>/N`** — the real body, on **matching nodes only**. Elsewhere
   nothing is emitted: the router goes remote there, so there's no stub to keep.

The remote function is generated on **every** node, including nodes
that have the local implementation. This is what makes `call_on_node`
and `call_on_nodes` work from anywhere — even a `&db` node can call
other `&db` nodes remotely for quorum writes, load distribution, etc.

The public router decides where to dispatch — the innermost explicit routing wins:
- Truthy `:node_selector` / `:multicast` opts on the call → remote, even inside a block
  (the call routes itself; a key set to `nil`/`false` opts back out to the default)
- Inside a `call_on_node`/`call_on_nodes` block → remote
- Default → local on matching nodes, remote everywhere else

The codegen, step by step, is in the [AST deep-dive](docs/deep-dive/ast-deep-dive.md).

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

  # Start FFmpeg pool only on worker nodes
  on_nebula_nodes &worker do
    def extra_children, do: [MyApp.TranscoderPool]
  else
    def extra_children, do: []
  end
end
```

The non-matching branch is completely absent from the compiled bytecode. More patterns
(nesting, a `defapi` inside `on_nebula_nodes`) are in
**[Conditional compilation](docs/guides/conditional-compilation.md)**.

## Runtime routing

Sometimes you need to override the default routing at runtime — target
a specific node, broadcast to many, or pick nodes based on load. The full strategy and
return-value reference is in **[Calling across nodes](docs/guides/calling-across-nodes.md)**.

### `call_on_node` — unicast

```elixir
# Force execution on a specific node
call_on_node @worker do
  MyApp.Jobs.transcode(file, opts)
end

# Pick a node dynamically based on runtime info
call_on_node fn nodes_info ->
  nodes_info
  |> Enum.filter(fn {_, info} -> info.connected && info.runtime end)
  |> Enum.min_by(fn {_, info} -> info.runtime.memory_percent end)
  |> elem(0)
end do
  MyApp.HeavyTask.run()
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

# Quorum: at least 2 nodes must succeed (a strict majority by default)
call_on_nodes &db, strategy: :quorum, at_least: 2 do
  MyApp.Users.write_replica(user)
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
| `:first` | Return the first response that counts as a success; `{:nebula_error, :no_success, results}` if none. |
| `:quorum` | Wait for `at_least:` successes (a strict majority by default). Fails fast if the quorum becomes unreachable. |

`:first` and `:quorum` let you define what counts as a success with a `success:` (or
`failure:`) predicate. Full return-value tables, `at_least:`, and the predicates are in
[Calling across nodes](docs/guides/calling-across-nodes.md).

## Node info and intelligent routing

`call_on_node` and `call_on_nodes` accept selector functions that
receive live runtime data about every node:

```elixir
%{
  short_name: :db,
  long_name: :"db@db.example",
  host: "db.example",
  tags: [:cluster, :db],
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
`info.runtime` before reading through it (as the examples do).

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

NebulaAPI never wraps your return value. A `defapi` body returns exactly what it
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

The one value the library *does* inject is `{:nebula_error, reason}` — a **library or
transport** failure (a timeout, no worker available, a crashing body, a quorum that wasn't
reached), never a business outcome. So any `:ok` / `:error` you ever see is **yours**, and
you never have to guess whether an `{:error, _}` came from your code or the framework. The
full contract — including how throws and exits are reported — is in
**[Using `defapi`](docs/guides/using-defapi.md)**.

## Worked example: a 3-role cluster

Three nodes, three roles — an API front, a database node, and a worker:

```elixir
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
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

  defapi &worker, transcode(input, opts) do
    FFmpex.new_command()
    |> FFmpex.add_input_file(input)
    |> FFmpex.add_output_file(opts[:output])
    |> FFmpex.execute()
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

## Wrap any single-node library

Here's the pattern that tends to click: **NebulaAPI turns any single-node
library into a cluster-wide one without touching the library.** No fork, no
monkey-patch — just a few lines of `defapi` that delegate to it on a chosen
node.

If you've ever thought *"I'd love to use Cachex / a counter / a cron here, but
its state is per-node, so now I need Redis / a shared DB / `:global` locks…"* —
this is the escape hatch. The library stays exactly as it is. You add a wrapper.

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
coordinators, and feature-flag stores — with recipes (and an honest caveat on hot-path
caching) in **[Wrapping single-node libraries](docs/guides/wrapping-libraries.md)**.

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
  to. Scaling the count of *known* roles is fine; minting brand-new node identities at
  runtime is not.
- **Topologies whose roles change at runtime.** Adding a wholly new tag or node *name* to
  the cluster means a recompile — NebulaAPI decided the routing at build time. Bringing
  more instances of an existing role online needs nothing but starting them.

## Performance

Indicative, order-of-magnitude:

| Call | Typical latency |
|---|---|
| Local call (plain Elixir) | ~0.000005 ms |
| NebulaAPI, resolved local | ~0.00002 ms |
| NebulaAPI, cross-node (Erlang distribution RPC) | ~0.2–2 ms |

The point: a locally-resolved NebulaAPI call adds almost nothing — a direct function call
plus a couple of process-dictionary reads, roughly 10,000× cheaper than a cross-node call.
Cross-node calls are standard Erlang distribution RPC, i.e. fast.

## Configuration reference

```elixir
config :nebula_api,
  # Required: cluster topology — tags per node.
  # Used at compile time to decide what code goes where.
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
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

Every option is documented in **[Configuration](docs/configuration.md)**.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Compile time                        │
│                                                      │
│  AST.Parser     parses selectors (&tag, @node, !&)   │
│  AST.Builder    generates the defapi functions        │
│  Config         resolves nodes, validates topology    │
│                 → CompileError on unknown tag/node    │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│                   Runtime                            │
│                                                      │
│  NebulaAPI.Server   per-app supervisor; starts one    │
│                     Worker per locally-served module  │
│                     (wired via nebula_api_server())   │
│  APIServer          :pg routing + node-info ETS cache │
│  APIServer.Worker   per-module GenServer; registers   │
│                     its methods in :pg                │
│  :pg groups         worker discovery across nodes     │
└─────────────────────────────────────────────────────┘
```

## Documentation

**Guides**
- [Getting started](docs/guides/getting-started.md) — from zero to a working cross-node call
- [Using `defapi`](docs/guides/using-defapi.md) — define, call, return values, error handling
- [Conditional compilation](docs/guides/conditional-compilation.md) — `on_nebula_nodes`
- [Calling across nodes](docs/guides/calling-across-nodes.md) — unicast, multicast, quorum, blocks
- [Gotchas and process scope](docs/guides/gotchas-and-scope.md) — trailing opts, tasks, nesting, timeouts

**Reference**
- [Concepts](docs/concepts.md) — nodes, tags, selectors, the execution model
- [Configuration](docs/configuration.md) — topology, `default_opts`, dev/test
- [Macros reference](docs/macros-reference.md) — every macro and option
- [Server and compiler](docs/server-and-compiler.md) — workers, `:pg`, the `:nebula` compiler

**Deep dive**
- [AST deep-dive](docs/deep-dive/ast-deep-dive.md) — how the per-node code is generated

## License

MIT
