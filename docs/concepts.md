# NebulaAPI Concepts

The core ideas behind NebulaAPI.

## Nodes

A **node** is an Erlang VM instance identified by a unique name. Each release in your
cluster runs as a separate node.

Node names follow the format `short@host`:

```
api@api.example
db@db.example
worker@worker.example
```

- **Short name**: `api` (the part before `@`)
- **Full name**: `api@api.example`

Both can be used in NebulaAPI selectors.

### Current node

At compile time, NebulaAPI determines the current node from:

1. The `self_node` option passed to `use NebulaAPI`
2. Otherwise `node()` (the Erlang node name — set it with `elixir --name`)

```elixir
# Default: uses node() at compile time
use NebulaAPI

# Explicit: specify the node (handy in dev/test, see configuration.md)
use NebulaAPI, self_node: :"api@api.example"
```

## Tags

**Tags** are labels that describe node capabilities. Instead of hardcoding node names,
you route to nodes by what they can do.

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db1.example": [:cluster, :db],
    "db@db2.example": [:cluster, :db],        # another :db node
    "worker@worker.example": [:cluster, :worker]
  ]
```

Tags are arbitrary atoms — `:db`, `:worker`, `:cache`, `:cluster` (a common membership
tag), whatever fits your topology. Multiple nodes can share a tag (load distribution),
and a node can carry several tags (multiple capabilities).

## Selectors

**Selectors** decide which nodes execute a function's real body. Everything else gets a
remote stub.

| Syntax | Meaning | Example |
|--------|---------|---------|
| `@node` | A specific node | `@db` |
| `!@node` | All nodes except this one | `!@backup` |
| `&tag` | Nodes with this tag | `&db` |
| `!&tag` | Nodes without this tag | `!&legacy` |
| `[...]` | Combine selectors | `[&db, !@backup]` |
| `:*` | All nodes (local everywhere) | `:*` |

A single selector needs no brackets — `defapi &db, ...` is the same as
`defapi [&db], ...`. Use brackets only to combine selectors.

Selectors are evaluated against the configured nodes, in order: include by name, exclude
by name, exclude by tag, include by tag (see [the AST deep-dive](deep-dive/ast-deep-dive.md)).

## Execution model

NebulaAPI makes the local/remote decision at **compile time**, not runtime:

```elixir
defapi &db, get(id) do
  Repo.get(User, id)
end
```

- Compiled on a node with `:db`: the body becomes a direct local function.
- Compiled on a node without `:db`: the body becomes an RPC stub that routes to a `:db`
  node at runtime.

The caller always uses the same `MyApp.Users.get(id)` — the routing was decided when the
release was built. See [the AST deep-dive](deep-dive/ast-deep-dive.md) for exactly what
gets generated.

## Return values

`defapi` functions don't wrap anything. A body returns its value verbatim:

```elixir
Math.add(3, 7)        # => 10        (not {:ok, 10})
Repo.get(User, id)    # => %User{} or nil
```

If your function returns `{:ok, x}` or `{:error, y}`, that tuple passes through
untouched. `:ok` and `:error` in a return value are **always yours** — they mean whatever
your business logic means by them. NebulaAPI never injects them.

### Library failures: `:nebula_error`

The only thing NebulaAPI adds is a distinct channel for **library and transport
failures** — never business outcomes. These are things that happen *around* your body, not
*in* it: a timeout, no worker available, a network crash, an exception raised inside the
body, or a quorum that wasn't reached. They take the form:

```elixir
{:nebula_error, reason}
```

Because `:nebula_error` is reserved for the lib, you can always tell a transport problem
apart from a business `{:error, reason}` your code chose to return.

An exception raised inside the body becomes `{:nebula_error, exception}` instead of
crashing the caller.

The same goes for a `throw` or an `exit` escaping the body: it becomes
`{:nebula_error, {:throw, value}}` / `{:nebula_error, {:exit, reason}}`, whether the
body ran locally or on a remote node. The `defapi` boundary is an RPC boundary:
values come out of it; everything that escapes a body is reported on the
`:nebula_error` channel — identically on every node. Code that relied on a `throw`
crossing a `defapi` call was already broken the day the topology changed.

### Unicast

A call routed to a single node either succeeds — returning the body's value verbatim — or
fails at the transport level, returning `{:nebula_error, reason}`.

### Multicast

`call_on_nodes` / `call_on_all_nodes` (or a call carrying `multicast: true`) fans a call
out to several nodes — note this is a *runtime routing* choice, not a `defapi` selector. The
shape of the result depends on the collection strategy:

| Strategy | Result |
|----------|--------|
| `:all` | a list of `{node, value}` (or `{node, {:nebula_error, reason}}` for nodes that failed) |
| `:first` | the first `{node, value}` that counts as a success; if none: `{:nebula_error, :no_success, results}` |
| `:quorum` (reached) | the list of collected `{node, value}` responses — the quorum of successes plus any non-success responses received along the way |
| `:quorum` (not reached) | `{:nebula_error, :quorum_not_reached, results}` or `{:nebula_error, :quorum_timeout, results}` |
| `:quorum` (unreachable) | `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` — returned before any call is made when the required count exceeds the number of available workers |

What counts as a "success" for `:first` and `:quorum` is configurable with a `success:`
(or `failure:`) option — a predicate `fn value -> boolean`. The default treats any node
that answered as a success. To require a business-level success instead:

```elixir
success: &match?({:ok, _}, &1)
```

## The three `use` macros

| `use ...` | For | Brings in |
|-----------|-----|-----------|
| `NebulaAPI` | modules that define `defapi` endpoints | `defapi` + `on_nebula_nodes` + `call_on_*`; registers the per-module markers and validates `self_node` |
| `NebulaAPI.Server` | the host module that wires the per-app server | `nebula_api_server/0` + `on_nebula_nodes` + `call_on_*` — without the `defapi` bookkeeping |
| `NebulaAPI.AST` | modules that only do conditional compilation or runtime calls | `on_nebula_nodes` + `call_on_*` only |

See [macros-reference.md](macros-reference.md) for each.

## Workers and discovery

For a module to be reachable remotely, a **worker** must run on the node where its
methods are local. Workers are started per app: each app wires `nebula_api_server()`
(via `use NebulaAPI.Server`) into its supervisor, which discovers the app's `NebulaAPI`
modules and starts one worker per locally-served module. Each worker registers its
methods in the cluster-wide `:pg` group `:pg_nebula_api`, keyed by
`{Module, {function, arity}}`, so any node can route to it.

Because the server lives in the app's own supervision tree, workers share the app's
lifecycle: when the app stops or crashes, its workers go down and `:pg` drops them — no
stale routing entries. See [server-and-compiler.md](server-and-compiler.md).

## Compile-time validation

NebulaAPI catches mistakes when you build, not when you ship:

```elixir
defapi @unknown_node, f() do ... end   # => CompileError: Unknown nodes in defapi call
defapi &unknown_tag, f() do ... end    # => CompileError: Unknown tags in defapi call
defapi [&db, !&db], f() do ... end     # => CompileError: No nodes found for execution
```

And the optional `:nebula` Mix compiler catches an app that has local methods but forgot
to wire `nebula_api_server()` — see [server-and-compiler.md](server-and-compiler.md).

## See Also

- [Macros Reference](macros-reference.md)
- [Configuration](configuration.md)
- [Server and Compiler](server-and-compiler.md)
- [AST Deep-Dive](deep-dive/ast-deep-dive.md)
