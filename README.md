# NebulaAPI

Transparent, safe cluster-wide APIs for Elixir — compile-time verified,
zero-overhead distributed calls.

Define your functions once. The compiler decides what runs where. Calls
across nodes look and feel like local function calls.

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  defapi &db, find(id) do
    Repo.get!(User, id)
  end
end

# On any node — same call, same result:
MyApp.Users.find(42)
#=> %User{id: 42, ...}
```

On the `:db` node, `find/1` runs locally. On every other node, it
transparently dispatches via RPC. The caller never knows.

## Why compile-time?

NebulaAPI resolves all routing decisions at compile time. This is not a
runtime router — it's a code generator that produces different bytecode
for each node.

**Smaller binaries.** Code that doesn't belong on a node doesn't exist
in its binary. Your web node doesn't carry FFmpeg bindings. Your worker
doesn't carry Phoenix routes.

**No unnecessary deps.** Combine `defapi` with `on_nebula_nodes` to
conditionally `use Ecto.Repo` or start supervisors. Nodes that don't
need a database connection don't load Ecto at all.

**Compile-time safety.** Reference a tag or node that doesn't exist in
your topology? `CompileError`. Typo in a node name? Caught before it
ships. No silent RPC calls into the void.

**Almost zero runtime overhead.** A locally-resolved call is a direct
function call plus a handful of process-dictionary reads (~0.00002 ms) to
check for an active routing context — no routing table, no RPC
serialization. The decision was made once, at compile time.

> **"Compile per release" — the one mental shift.** NebulaAPI produces
> different bytecode per node, so each release is its own build. For Elixir
> devs used to a single runtime artifact, that's the surprising part. In
> practice it's one extra `elixir --name node@host -S mix compile` per
> release — a few seconds of CI, paid back many times over in smaller
> binaries, fewer dependencies, and zero routing overhead.

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
building for.

## Installation

```elixir
def deps do
  [
    {:nebula_api, git: "git@github.com:podCloud/NebulaAPI.git", tag: "v0.3.0"}
  ]
end
```

## Quick start

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
are all you need.

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
app (so `:pg` never holds stale entries).

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
enough — the host part is infrastructure detail.

### What gets generated

For each `defapi`, three functions are always created:

1. **`__nbapi_local_<name>/N`** — the real body (matching nodes) or a
   raising stub (everywhere else)
2. **`__nbapi_remote_<name>/N`** — RPC dispatch via `APIServer`
3. **`<name>/N`** — the public router that delegates to local or remote

The remote function is generated on **every** node, including nodes
that have the local implementation. This is what makes `call_on_node`
and `call_on_nodes` work from anywhere — even a `&db` node can call
other `&db` nodes remotely for quorum writes, load distribution, etc.

The public router decides where to dispatch:
- Inside a `call_on_node`/`call_on_nodes` block → always remote
- With explicit `:node_selector` or `:multicast` opts → always remote
- Default → local if available, remote otherwise

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

The non-matching branch is completely absent from the compiled bytecode.

## Runtime routing

Sometimes you need to override the default routing at runtime — target
a specific node, broadcast to many, or pick nodes based on load.

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

# Quorum: majority must succeed
call_on_nodes &db, strategy: :quorum, quorum_count: 2 do
  MyApp.Users.write_replica(user)
end
```

### `call_on_all_nodes` — broadcast

Calls every node that serves this method (i.e. has a registered worker for it),
not necessarily every configured node.

```elixir
call_on_all_nodes timeout: 5_000 do
  MyApp.Cache.invalidate(:all)
end
```

### Multicast strategies

Multicast results are always tagged by node. A node that answered yields
`{node, value}` (whatever the body returned); a node whose call failed at the
transport level yields `{node, {:nebula_error, reason}}`.

| Strategy | Behavior |
|---|---|
| `:all` | Wait for every node (or timeout). Returns a list of `{node, value}` / `{node, {:nebula_error, reason}}`. |
| `:first` | Returns the first `{node, value}` that counts as a success. If none qualify, returns the full list of responses. |
| `:quorum` | Reached: the list of `{node, value}`. Not reached: `{:nebula_error, :quorum_not_reached, results}` or `{:nebula_error, :quorum_timeout, results}`. |

#### Defining "success" — `success:` / `failure:`

By default, a node counts as a success for `:first` and `:quorum` as soon as it
*responds* (a `{:nebula_error, _}` never counts). To base success on the
returned value instead, pass a predicate:

```elixir
# Only count a node when it returned {:ok, _}
call_on_nodes &db, strategy: :quorum, quorum_count: 2,
  success: &match?({:ok, _}, &1) do
  MyApp.Users.write_replica(user)
end

# Mirror form: treat {:error, _} as failure, everything else as success
call_on_nodes &worker, strategy: :first,
  failure: &match?({:error, _}, &1) do
  MyApp.Jobs.transcode(file, opts)
end
```

A transport failure (`{:nebula_error, _}`) is never a success, regardless of the
predicate.

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
defapi &math, add(a, b) do
  a + b
end

Math.add(3, 7)   #=> 10

defapi &db, find(id) do
  Repo.get(User, id)      # returns %User{} or nil
end

find(1)        #=> %User{...}
find(999)      #=> nil

# Tuples you return yourself are passed through untouched — including your own
# {:ok, _} / {:error, _}:
defapi &db, create(attrs) do
  Repo.insert(User.changeset(attrs))  # {:ok, user} or {:error, changeset}
end

create(%{name: "Ada"})   #=> {:ok, %User{...}}
create(%{})              #=> {:error, %Ecto.Changeset{...}}
```

### `:nebula_error` — library and transport failures only

The one value NebulaAPI *does* inject is `{:nebula_error, reason}`. It signals a
failure of the library or the transport — never a business outcome:

- a call timed out,
- no worker is available for the method,
- a network/RPC crash,
- the body raised an exception (`{:nebula_error, exception}`),
- a quorum wasn't reached.

```elixir
# No &db node is up to answer
find(1)   #=> {:nebula_error, :no_worker}

# The body raised
find(1)   #=> {:nebula_error, %RuntimeError{...}}
```

This keeps the two worlds cleanly separated: any `:ok` / `:error` you ever see in
a return value is **business** — it's what your function chose to return.
`:nebula_error` is **infrastructure** — the lib telling you the call itself
didn't complete. You never have to guess whether an `{:error, _}` came from your
code or from the framework.

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
    # get/1 wraps Repo.get/2, so it returns a %User{} (or nil) directly.
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

### Rate limiter — cluster-wide Hammer

[Hammer](https://hex.pm/packages/hammer) with the ETS backend counts per node.
Wrap it so the whole cluster shares one count:

```elixir
defmodule MyApp.RateLimitLocal do
  use Hammer, backend: :ets
end

defmodule MyApp.RateLimit do
  use NebulaAPI

  defapi [@control], hit(key, scale_ms, limit) do
    MyApp.RateLimitLocal.hit(key, scale_ms, limit)
  end
end
```

Every node calls `MyApp.RateLimit.hit/3`; it resolves locally on `@control` and
routes transparently via RPC everywhere else. One coherent count, no Redis.

### Aggregated counters and metrics

An Erlang `:counters` table or a GenServer counter, pinned to a `@stats` node:

```elixir
defmodule MyApp.Metric do
  use NebulaAPI

  defapi [@stats], incr(name, n \\ 1), do: MyApp.MetricLocal.incr(name, n)
  defapi [@stats], get(name), do: MyApp.MetricLocal.get(name)
end
```

Cluster-wide counters without Prometheus or StatsD. For coarse numbers
("how many uploads this month") it's plenty.

### Run-once-per-cluster scheduling

The classic: a job that must fire **once for the cluster**, not once per node.
The usual answers are `:global` locks or pulling in Oban + Postgres. Instead,
pin a Quantum or a plain scheduler GenServer to `@scheduler`:

```elixir
defmodule MyApp.Cron do
  use NebulaAPI

  defapi [@scheduler], schedule(name, cron_expr, mfa) do
    MyApp.LocalCron.schedule(name, cron_expr, mfa)
  end
end
```

Single-execution guarantee, no external dependency.

### Singleton workers

"There must be exactly one process coordinating X across the cluster" — a
WebSocket registry, a GenStage broker, a job coordinator. `:global` works but is
verbose and fails over poorly. Wrap the GenServer on `@coordinator` and you get
the same API as the single-node version, centralized.

### Feature-flag store

An `:ets` + GenServer flag store is trivial single-node but drifts between
instances. Wrap it on `@config` so every instance sees the same state — no Redis,
no shared DB:

```elixir
defmodule MyApp.FeatureFlags do
  use NebulaAPI

  defapi [@config], enabled?(flag), do: MyApp.FeatureFlagsLocal.enabled?(flag)
  defapi [@config], set(flag, value), do: MyApp.FeatureFlagsLocal.set(flag, value)
end
```

### Caching — with an honest caveat

For values read often and invalidated rarely (dynamic config, reference data),
wrapping Cachex on a `@cache` node is great. But for a hot path doing thousands
of reads per second per node, every read becomes an RPC round-trip — that's the
**wrong** use, and a real distributed cache (Redis, or `:mnesia`) stays better.
NebulaAPI is the right tool when the access pattern fits (rare reads, or config),
not a universal replacement for a distributed cache.

## When NOT to use NebulaAPI

Being honest about the edges:

- **External clients.** If the caller isn't a node in your Erlang cluster — a
  public web client, a non-Elixir mobile app — gRPC or REST is still the right
  boundary. NebulaAPI is for intra-cluster calls.
- **Massively ephemeral fleets.** Hundreds of Kubernetes pods churning in and
  out make compile-time `--name`-per-node unworkable. Reach for runtime service
  discovery instead.
- **Topologies that change at runtime.** Continuous auto-scaling breaks the core
  assumption: NebulaAPI expects a stable topology known at compile time.

## Performance

Indicative, order-of-magnitude:

| Call | Typical latency |
|---|---|
| Local call (plain Elixir) | ~0.000005 ms |
| NebulaAPI, resolved local | ~0.00002 ms |
| NebulaAPI, cross-node (Erlang distribution RPC) | ~0.2–2 ms |

The point: a locally-resolved NebulaAPI call adds almost nothing — a direct
function call plus a few process-dictionary reads (~0.00002 ms per call), roughly
10,000× cheaper than a cross-node call. Cross-node calls are standard Erlang
distribution RPC, i.e. fast.

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
  # In production, compile with: elixir --name node@host -S mix compile
  default_opts: [self_node: :"api@api.example"]
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Compile time                        │
│                                                      │
│  AST.Parser     parses selectors (&tag, @node, !&)   │
│  AST.Builder    generates 3 functions per defapi      │
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

## License

MIT
