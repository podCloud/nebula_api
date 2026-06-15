# 2. Defining APIs

*Now that the topology exists ([Configuration](configuration.md)), define the functions
that run on it.*

This page covers `defapi`, the selector syntax, conditional compilation with
`on_nebula_nodes`, and wiring the per-app server so calls can actually reach a node.

## Which `use` do I pick?

NebulaAPI has three entry points. Pick by what the module does:

| `use ...` | Use it on | Brings into scope | Side effects |
|-----------|-----------|-------------------|--------------|
| **`NebulaAPI`** | modules that define `defapi` endpoints | `defapi`, `on_nebula_nodes`, `call_on_*` | registers the per-module markers, validates `self_node` |
| **`NebulaAPI.Server`** | the host module that wires the per-app server (usually the `Application`) | `nebula_api_server/0`, `on_nebula_nodes`, `call_on_*` | registers the `:nebula_api_server_wired` marker — **no** `defapi` bookkeeping |
| **`NebulaAPI.AST`** | modules that only do conditional compilation or runtime calls | `on_nebula_nodes`, `call_on_*` | none |

Rule of thumb: a module with `defapi` → `use NebulaAPI`; the module that wires
`nebula_api_server()` → `use NebulaAPI.Server`; a module that merely wraps a `use`/config
in `on_nebula_nodes` → `use NebulaAPI.AST`.

`use NebulaAPI` accepts the per-module overrides `self_node`, `allow_unknown_self_node`,
`max_concurrent_calls`, and `default_timeout` (the latter two default from `default_opts`,
see [Configuration](configuration.md#default_opts)).

## `defapi`

Defines a function whose body runs on the selected nodes; everywhere else it's a
transparent RPC stub.

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # Runs on :db nodes; transparent RPC everywhere else
  defapi &db, get(id) do
    Repo.get(User, id)
  end
end
```

### Selectors

Selectors decide which nodes execute the real body. Everything else gets a remote stub —
a generated function that forwards the call over RPC to a node that does have the body.

| Pattern | Meaning |
|---------|---------|
| `&tag` | nodes with this tag |
| `!&tag` | nodes without this tag |
| `@node` | this node (short or full name) |
| `!@node` | all nodes except this one |
| *(no selector)* | every node — the body is local everywhere |

**Combine selectors by juxtaposing them with a space — no commas between them, no
brackets.** This is the canonical NebulaAPI syntax, and it is what keeps call sites
readable:

```elixir
# :db nodes, excluding @backup
defapi &db !@backup, run_migration(version) do
  Ecto.Migrator.run(Repo, :up, to: version)
end

# a specific node only
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

Omitting the selector entirely is how you say "run on every node". The bracketed list form
(`defapi [&db, !@backup], ...`) still compiles, but it is **not** the canonical syntax —
prefer the space-juxtaposed form everywhere. A full
node name with special characters goes in as an atom: `defapi @:"db@db.example", ...`.

#### Combining selectors

Juxtaposed selectors **narrow** — every combinator is an intersection:

| Form | Matches |
|------|---------|
| `&a &b` | nodes carrying **both** `a` **and** `b` |
| `@n &t` | node `n`, **and** only if it carries `t` |
| `&t !&u` | nodes with `t`, **minus** those with `u` |
| `!&a !&b` | nodes with **neither** `a` nor `b` |

```elixir
# Only the GPU-equipped workers (carry both :worker and :gpu):
defapi &worker &gpu, quick_transcode(input, opts) do
  GpuTranscoder.run(input, opts)
end
```

To target nodes that have *either* of two capabilities, give both groups a shared tag in
config (`:a_or_b`) and select that — union is a topology fact, expressed once where the
topology lives, not at every call site.

### Short names

In config, node names are full Erlang names (`short@host`); in selectors you can use just
the short part. These are equivalent when there's no ambiguity:

```elixir
defapi @db, do_something() do ... end
defapi @:"db@db.example", do_something() do ... end
```

`@db` and `@worker` are clear enough — the host part is infrastructure detail.

### Signatures

Signatures take simple variables and defaults only:

```elixir
defapi &db, get(id), do: Repo.get(User, id)
defapi &db, list(filters \\ []), do: Repo.all(query(filters))
defapi get_node_health(), do: %{node: node()}
```

Pattern-matched arguments — atoms, maps, lists, tuples — are rejected with a
`CompileError`: a `defapi` is an RPC boundary, so every argument needs a *name* to travel
through the generated router and the remote call. Dispatch on values inside the body
instead.

### Return values — no wrapping

A `defapi` body returns **exactly** what it computed. NebulaAPI never wraps it:

```elixir
defapi &db, add(a, b), do: a + b           # add(3, 7) => 10, not {:ok, 10}
defapi &db, get(id),   do: Repo.get(User, id)   # %User{} or nil, untouched
defapi &db, create(a), do: Repo.insert(cs)      # {:ok, _} / {:error, _} preserved as-is
```

The only value the library itself injects is `{:nebula_error, reason}` — a **library or
transport** failure (a timeout, no worker available, a crashing body, a quorum not
reached), never a business outcome:

| Layer | Shape | Meaning |
|-------|-------|---------|
| Business | the body's own value (incl. `:ok` / `:error` / `{:ok, _}` / `{:error, _}`) | returned untouched |
| Library / transport | `{:nebula_error, reason}` | timeout, no worker, worker crash, body exception, quorum not reached |

So `:ok` / `:error` always come from your code; `:nebula_error` always comes from
NebulaAPI. An exception, throw, or exit escaping the body is surfaced as
`{:nebula_error, _}` — identically whether the body ran locally or remotely.

The 2-tuple `{:nebula_error, reason}` is the **single-node** shape: a unicast call, or one
node inside a multicast result list. A **whole-call** multicast failure carries an extra
element — `{:nebula_error, :no_success, results}`, `{:nebula_error, :quorum_not_reached,
results}`, `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` — so match the
3-tuples when handling a `:first` / `:quorum` top-level outcome (see
[Calling → multicast results](calling.md#multicast-results)).

> The trailing routing-options argument (`MyApp.Users.get(id, timeout: 100)`) and its
> positional pitfall live in [Gotchas](gotchas.md#trailing-routing-options-are-positional).

### What gets generated

For each `defapi`, the macro generates:

1. **`<name>/N`** — the public router callers actually invoke.
2. **`__nbapi_remote_<name>/N`** — RPC dispatch via `APIServer`, on **every** node.
3. **`__nbapi_local_<name>/N`** — the real body, on **matching nodes only**. Elsewhere
   nothing is emitted: the router goes remote there, so there's no stub to keep.

The remote function exists on **every** node, including nodes that have the local
implementation — that's what lets `call_on_node` / `call_on_nodes` work from anywhere (even
a `&db` node can call other `&db` nodes remotely, for quorum writes or load distribution).
The exact codegen is in the [AST deep-dive](deep-dive/ast-deep-dive.md).

## `on_nebula_nodes` — conditional compilation

Conditionally compile a block based on the current node. Unlike `defapi`, it works at any
level (module body, `use` directives, supervision children) and generates **no** remote
stub — the non-matching branch is simply absent from the bytecode.

```elixir
defmodule MyApp.Repo do
  use NebulaAPI.AST

  # Only :db nodes connect to (and even load) Ecto.
  on_nebula_nodes &db do
    use Ecto.Repo, otp_app: :my_app
  end
end

defmodule MyApp.Application do
  use NebulaAPI.AST

  on_nebula_nodes &worker do
    def extra_children, do: [MyApp.TranscoderPool]
  else
    def extra_children, do: []
  end
end
```

Selectors use the same space-juxtaposed syntax (`on_nebula_nodes &db !@backup do`). Blocks
nest like compile-time `if`s: an inner block is kept only when both selectors match.

**A `defapi` inside `on_nebula_nodes` disappears entirely on non-matching nodes** — router
included. That means *no transparent RPC from the other nodes*: calling it there is an
`UndefinedFunctionError`, not a remote call. It spells "this API only exists on those
nodes". If you want "implemented here, callable from everywhere", that's a plain
`defapi` — its selector already does exactly that.

## Wire the server into the supervision tree

Defining `defapi` is not enough — a **worker** has to run on the node where the methods are
local, so other nodes can route to it. Wire one server per app:

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

At startup the server resolves the OTP app it belongs to, lists its modules, keeps the ones
that `use NebulaAPI` **and** have at least one method local on this node, and starts one
`NebulaAPI.APIServer.Worker` per such module. The set is discovered from the compiled
`.beam` metadata — no module list to maintain.

Each worker registers its local methods in the cluster-wide `:pg` group `:pg_nebula_api`,
keyed by `{Module, {function, arity}}`, so any node can route to it. On a remote call the
worker runs the body in a supervised task and replies asynchronously, so a slow body never
blocks the module's other calls.

**Lifecycle is correct for free.** Because the server lives in the app's own tree, if the
app stops or crashes its workers go down with it and `:pg` drops their entries — no stale
routing targets.

**On a generic node** (a nameless `nonode@nohost` build, or any release booted with
`ALLOW_RUNTIME_NEBULA_NODE_MISMATCH=1`), `nebula_api_server()` is a no-op: it logs a warning,
starts no workers, and serves nothing — every `defapi` call routes remote. See
[Configuration → boot-time node policy](configuration.md#boot-time-node-policy).

### Guard against forgetting it — the `:nebula` compiler

Forgetting `nebula_api_server()` in an app that has `defapi` modules means workers that
never start and calls that fail at runtime with `{:nebula_error, {:no_worker, ...}}`. The
optional `:nebula` Mix compiler turns that into a compile error:

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers() ++ [:nebula]
  ]
end
```

After `:app` compiles, it reads the persisted `.beam` attributes and fails the build if an
app has modules with local methods but no module wired `nebula_api_server()`:

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

In an umbrella the compiler is `@recursive`, so it checks each child app in its own
context.

## Inspecting what compiled where

```elixir
MyModule.__info__(:attributes) |> Keyword.get_values(:nebula_local_api_methods) |> List.flatten()
# => [{:get, 1}, ...] if local here, [] if this node only has the remote stub

:pg.which_groups(:pg_nebula_api)
:pg.get_members(:pg_nebula_api, {MyApp.Users, {:get, 1}})
Process.whereis(MyApp.Users)   # the worker for that module, if local here
```

## Next

- [Calling across nodes](calling.md) — call your endpoints and override routing at runtime.
- [Gotchas](gotchas.md) — the sharp edges (trailing opts, process scope, nesting).
