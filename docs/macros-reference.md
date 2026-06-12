# NebulaAPI Macros Reference

## Choosing a `use`

NebulaAPI exposes three entry points. Pick by what the module does:

| `use ...` | Use it on | Brings into scope | Side effects |
|-----------|-----------|-------------------|--------------|
| **`NebulaAPI`** | modules that define `defapi` endpoints | `defapi`, `on_nebula_nodes`, `call_on_*` | registers the per-module markers (`:nebula_local/remote_api_methods`, `:nebula_api`), validates `self_node` |
| **`NebulaAPI.Server`** | the host module that wires the per-app server (usually the `Application`) | `nebula_api_server/0`, `on_nebula_nodes`, `call_on_*` | registers `:nebula_api_server_wired` (for the `:nebula` compiler) — **no** `defapi` bookkeeping |
| **`NebulaAPI.AST`** | modules that only do conditional compilation or runtime calls | `on_nebula_nodes`, `call_on_*` | none |

Rule of thumb: a module with `defapi` → `use NebulaAPI`; the module that wires
`nebula_api_server()` → `use NebulaAPI.Server`; a module that merely wraps a `use`/config
in `on_nebula_nodes` → `use NebulaAPI.AST`.

---

## `use NebulaAPI`

```elixir
defmodule MyApp.Users do
  use NebulaAPI
  # use NebulaAPI, self_node: :"api@api.example", allow_unknown_self_node: false
end
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `self_node` | atom | `node()` | Node to use for compile-time decisions |
| `allow_unknown_self_node` | boolean | `false` | Allow compiling on a node not in config |

It imports `defapi` / `on_nebula_nodes` / `call_on_*`, records which methods are local vs
remote on this node, and validates `self_node` against the configured topology.

---

## `defapi`

Defines a function whose body runs on the selected nodes; everywhere else it's a
transparent RPC stub.

```elixir
defapi <selector>, <signature> do
  <body>
end
```

### Selectors

| Pattern | Meaning |
|---------|---------|
| `@node` | this node |
| `!@node` | all nodes except this one |
| `&tag` | nodes with this tag |
| `!&tag` | nodes without this tag |
| `[a, b, ...]` | combine selectors |
| `:*` | every node (local everywhere) |

A single selector doesn't need brackets — `defapi &db, ...`. Combine with a list —
`defapi [&db, !@backup], ...`. Full node names with special chars: `defapi @:"db@db.example", ...`.

### Signatures and return values

Signatures take simple variables and defaults only:

```elixir
defapi &db, get(id), do: Repo.get(User, id)
defapi &db, list(filters \\ []), do: Repo.all(query(filters))
defapi :*, health(), do: %{node: node()}
```

Pattern-matched arguments — atoms, maps, lists, tuples — are rejected with a
`CompileError`: a `defapi` is an RPC boundary, every argument needs a *name* to
travel through the generated router and the remote call. Dispatch on values
inside the body instead.

Return values are passed through verbatim — **no wrapping**. The body's value is
returned exactly as-is to the caller:

```elixir
defapi &db, add(a, b) do
  a + b                      # Math.add(3, 7) → 10 (not {:ok, 10})
end

defapi &db, get(id) do
  Repo.get(User, id)         # %User{} or nil, untouched
end

defapi &db, create(attrs) do
  Repo.insert(changeset)     # {:ok, _} / {:error, _} preserved as-is
end
```

The only values NebulaAPI ever injects are `:nebula_error` tuples, and those signal a
**library/transport failure** — never a business outcome:

| Layer | Shape | Meaning |
|-------|-------|---------|
| Business | the body's own value (incl. `:ok` / `:error` / `{:ok, _}` / `{:error, _}`) | returned untouched |
| Library / transport | `{:nebula_error, reason}` | timeout, no worker available, worker crash, body exception, quorum not reached |

So `:ok` and `:error` always come from your code; `:nebula_error` always comes from
NebulaAPI. A raised exception inside the body is caught and surfaced as
`{:nebula_error, exception}`.

### Trailing routing options — positional, no magic

Every generated function accepts the routing options as one extra trailing
argument, after ALL of the business arguments:

```elixir
defapi &db, list(filters \\ [])
# generates: def list(filters \\ [], nebula_routing_opts \\ [])

MyApp.Store.list([status: :active], multicast: true, strategy: :quorum, at_least: 2)
```

The dispatch is purely positional. Watch out when your LAST business argument has
a default: `MyApp.Store.list(multicast: true)` is a one-argument call, so the
keyword list binds to `filters` — your routing options are silently served to the
body as business data and no routing happens. Fill the business arguments
explicitly (`MyApp.Store.list([], multicast: true)`), or use the `call_on_node` /
`call_on_nodes` blocks, which carry the routing through the call context and
avoid the ambiguity entirely — their options-only form is the direct antidote:

```elixir
call_on_node timeout: 30_000 do
  MyApp.Store.list()
end
```

Routing opts are validated on every node, even when the call resolves locally and
the transport never runs: an invalid opt (`timeout: :infinity`, `strategy:` or
`success:`/`failure:` without `multicast:`) raises an `ArgumentError` identically
wherever the call happens to execute, and so does an unknown option key — the
option set is closed, a typo'd `timout:` must not be silently dropped. A
valid-but-inapplicable opt — a `timeout:` on a locally-resolved call — is a
silent no-op.

---

## `on_nebula_nodes`

Conditionally compile a block based on the current node. Unlike `defapi`, it works at any
level (module body, `use` directives, supervision children) and generates **no** remote
stub — the non-matching branch is simply absent from the bytecode.

```elixir
on_nebula_nodes &db do
  use Ecto.Repo, otp_app: :my_app
end

on_nebula_nodes @primary do
  @mode :primary
else
  @mode :replica
end
```

A module that uses only `on_nebula_nodes` (no `defapi`, no server) can `use NebulaAPI.AST`.

`on_nebula_nodes` blocks nest like compile-time `if`s: an inner block is kept only when
both selectors match, with no state involved.

**A `defapi` inside `on_nebula_nodes` disappears entirely on non-matching nodes** —
router included. That means *no transparent RPC from the other nodes*: calling it there
is an `UndefinedFunctionError`, not a remote call. It spells "this API only exists on
those nodes"; if you want "implemented here, callable from everywhere", that's a plain
`defapi` — its selector already does exactly that.

---

## `nebula_api_server/0`

Brought into scope by `use NebulaAPI.Server`. Place it in your app's supervisor children:

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

It expands to a child spec for a per-app `NebulaAPI.Server`, which discovers the app's
`NebulaAPI` modules and starts a worker for each one with local methods on this node. See
[server-and-compiler.md](server-and-compiler.md).

---

## `call_on_node` — unicast

Force a call onto a specific node (overrides the default local/remote routing).

```elixir
call_on_node @worker do
  MyApp.Jobs.transcode(file, opts)
end

# Or a selector function over live node info
call_on_node fn nodes_info ->
  nodes_info
  |> Enum.filter(fn {_, i} -> i.connected && i.runtime end)
  |> Enum.min_by(fn {_, i} -> i.runtime.memory_percent end)
  |> elem(0)
end, timeout: 10_000 do
  MyApp.HeavyTask.run()
end

# Or options only — no selector: any available worker, with these options.
# The semantic with_options: the calls in the block route through the
# transport with these opts, without the trailing-opts positional gotcha.
call_on_node timeout: 30_000 do
  MyApp.HeavyTask.run()
end
```

| Option | Type | Default |
|--------|------|---------|
| `timeout` | positive integer (ms) — `:infinity` rejected | 5000 |

`timeout:` is the **only** option `call_on_node` accepts: passing `strategy:`,
`at_least:` or `success:`/`failure:` (multicast-only), an unknown key, or a malformed
literal value (`timeout: :infinity`) is a `CompileError` at the call site. Dynamic
values (`timeout: my_var`, a whole-opts variable) are checked at runtime instead, with
the same `ArgumentError`.

**Return value.** On success, you get the body's value exactly as-is (no wrapping). If the
transport fails (timeout, no worker, crash), you get `{:nebula_error, reason}`.

**`nil` selector vs a selector returning `nil`.** The selector argument may be a runtime
expression; when it evaluates to `nil` it means "no restriction" — the call routes to the
first available worker, and the block's options (`timeout:`, ...) still apply. A selector
**function** that returns `nil` means the opposite: "nothing matched" — the call fails with
`{:nebula_error, {:no_worker_on_node, nil}}`. A no-match never widens the target.

---

## `call_on_nodes` — multicast

```elixir
call_on_nodes &worker, strategy: :all, timeout: 30_000 do
  MyApp.Jobs.health_check()
end

# Options only — no selector: every node serving the method.
# `call_on_all_nodes` is the named alias of this form.
call_on_nodes strategy: :quorum, at_least: 2 do
  MyApp.Users.write_replica(user)
end
```

| Option | Type | Default | |
|--------|------|---------|--|
| `timeout` | positive integer (ms) — `:infinity` rejected | 5000 | |
| `strategy` | atom | `:all` | `:all` / `:first` / `:quorum` |
| `at_least` | positive integer | `div(n, 2) + 1` (strict majority) | for `:quorum` — number of successes required; an absolute floor, may be below majority |
| `success` | `fn value -> boolean` | a worker that *responded* | what counts as a business success for `:first` / `:quorum` — **raises `ArgumentError` with any other strategy** |
| `failure` | `fn value -> boolean` | — | mirror of `success`: a matching value is treated as a non-success — **raises `ArgumentError` with any other strategy** |

| Strategy | Behavior |
|----------|----------|
| `:all` | wait for every node (or timeout); returns a list of all results |
| `:first` | return the first **success**; remaining tasks cancelled |
| `:quorum` | wait for N **successes**; early-exit if it can no longer be reached |

Everything statically visible in the options is validated at compile time: an unknown
key, a malformed literal value (`strategy: :qourum`, `at_least: 0`,
`timeout: :infinity`) or an impossible combination (`at_least:` when the block
statically resolves to a non-`:quorum` strategy, a predicate with `strategy: :all`)
is a `CompileError` at the call site. Dynamic values (a variable `strategy:`, a
whole-opts variable) defer those checks to runtime, where they raise the same
`ArgumentError`.

A selector function receives the live `nodes_info` map (see below) and returns the list of
target nodes. Every node with a registered worker is included — a node not yet in the
background snapshot appears with `runtime: nil` / `last_seen_at: nil` until the next
refresh, so filter on `info.runtime` before reading through it.

**`nil` selector vs a selector returning `nil`.** The selector argument may be a runtime
expression; when it evaluates to `nil` it means "no restriction" — the call fans out to
every node serving the method (like `call_on_all_nodes`), and the block's options
(`strategy:`, `at_least:`, `timeout:`, ...) still apply. A selector **function** that
returns `nil` or `[]` means the opposite: "nothing matched" — zero calls are made (`:all`
returns `[]`, `:first` returns `{:nebula_error, :no_success, []}`, `:quorum` fails
`{:nebula_error, :quorum_unreachable, ...}`). A no-match never widens the target.

### Return values

Each per-node result keeps the body's value verbatim, tagged with its node. Transport
failures for a given node surface as `{:nebula_error, reason}` in that node's slot.

| Strategy | Returns |
|----------|---------|
| `:all` | a list of `{node, value}` — failed nodes appear as `{node, {:nebula_error, reason}}` |
| `:first` | the first `{node, value}` that counts as a success; if none succeed: `{:nebula_error, :no_success, results}` — never a bare list |
| `:quorum` (reached) | the list of collected `{node, value}` responses — the quorum of successes plus any non-success responses received along the way |
| `:quorum` (not reached) | `{:nebula_error, :quorum_not_reached, results}` |
| `:quorum` (timed out) | `{:nebula_error, :quorum_timeout, results}` |
| `:quorum` (unreachable) | `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` — returned before any call is made when the required count exceeds the number of available workers |

In every case `value` is the unwrapped body value (your `:ok` / `:error` / plain term),
and `results` is the list of `{node, value}` collected so far.

### Defining success: `success:` / `failure:`

By default, **any worker that responded** counts as a success for `:first` and `:quorum` —
a body returning `{:error, :not_found}` is still a successful *response*. When you need a
quorum or first-wins to hinge on the **business** outcome, narrow it with `success:` (or its
mirror `failure:`):

```elixir
# A write quorum that only accepts {:ok, _} replies.
call_on_nodes &replica, strategy: :quorum, success: &match?({:ok, _}, &1) do
  MyApp.Store.write(key, value)
end

# Equivalent framing via the mirror option.
call_on_nodes &replica, strategy: :first, failure: &match?({:error, _}, &1) do
  MyApp.Store.read(key)
end
```

`success:` is `fn value -> boolean`; `failure:` is its negation (a matching `value` is *not*
a success). Either way, a `{:nebula_error, _}` result is **never** a success regardless of
the predicate — the predicate only ever runs against the body's own value, so library and
transport failures can never be mistaken for a healthy reply.

A buggy predicate is contained like a buggy body: a raise, throw or exit inside it makes
the whole call return `{:nebula_error, exception}` / `{:nebula_error, {kind, reason}}` —
it never crashes the caller.

Both options are **only meaningful with `:first` or `:quorum`**. Passing either on a unicast
call or with `strategy: :all` raises an `ArgumentError` up front — they would otherwise be
silently ignored. `call_on_node` also rejects them at compile time.

---

## `call_on_all_nodes` — broadcast

Named alias of the selector-less `call_on_nodes` form: multicast over every node
that **serves this method** — i.e. every node that has a registered worker for
it, not necessarily every configured node. Same options as `call_on_nodes`.

```elixir
call_on_all_nodes timeout: 5_000 do
  MyApp.Cache.invalidate(:all)
end
```

---

## Nesting and process scope

The `call_on_*` blocks set a routing context that the generated functions read. Four
rules govern how far it reaches:

**Nested blocks replace, then restore.** An inner `call_on_*` block replaces the whole
context — selector, mode *and options*. There is no merge: an outer `timeout: 30_000`
does **not** apply inside an inner block that doesn't repeat it. On exit (normal or via
an exception) the outer block's context takes back over, and after the outermost block
no context remains.

**A call's own routing opts win over the block.** The innermost explicit routing
wins: a call inside a block that carries its own truthy `node_selector:`/`multicast:`
trailing opts routes itself, exactly as it would outside the block — the block's
routing *and options* are ignored for that call. A routing key explicitly set to
`nil` (or `multicast: false`) opts the call out of the block, back to **default**
routing (local on a serving node, remote otherwise):

```elixir
call_on_nodes &worker, strategy: :all do
  MyApp.Jobs.broadcast()                      # fans out per the block
  MyApp.Local.bookkeep(x, multicast: false)   # plain default call — escapes the block
end
```

For the other opts the same logic reads as: the block's opts are defaults, the
call's own trailing opts override them, and an explicit `nil` opts out of the
block's default back to the lib's own default (a `timeout: nil` on the call
resolves to the module/global default, not to the block's `timeout:`).

**The context is per process.** It lives in the process dictionary of the process
running the block, so it does not follow a spawn: a `Task.async`/`spawn` started inside
a block runs with **no** context — its `defapi` calls route by default, the surrounding
block silently does not apply. Put the `call_on_*` block *inside* the task when that is
what you mean:

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

**A block applies to one hop.** It never crosses the RPC boundary: a `defapi` body
executes on the target node in a fresh process, so calls *inside the body* route by
their own defaults — the caller's block doesn't leak into them (a caller's
`strategy: :quorum` applying to a body's internal calls is exactly what you don't
want). A block governs the `defapi` calls written directly in it, nothing further.

Also note that only `defapi`-generated functions read the context: wrapping a plain
function call in a `call_on_*` block does nothing to it.

---

## The `nodes_info` map

Selector functions for `call_on_node`/`call_on_nodes` receive live runtime data per node:

```elixir
%{
  short_name: :db,
  long_name: :"db@db.example",
  host: "db.example",
  tags: [:cluster, :db],
  connected: true,
  last_seen_at: ~U[2024-06-15 12:00:00Z],
  runtime: %{
    memory_used_mb: 256, memory_total_mb: 1024, memory_percent: 25.0,
    process_count: 1542, schedulers: 8, otp_release: "26", uptime_seconds: 86400
  }
}
```

`last_seen_at` lets you avoid nodes that look connected but have gone quiet. This info is
an ETS snapshot rebuilt in the background by `NebulaAPI.APIServer.NodesInfoCache` every
`nodes_info_refresh_interval` ms (default 5000) — reads never trigger a rebuild. A node
whose worker just registered and isn't in the snapshot yet is still offered to selectors,
with `runtime: nil` / `last_seen_at: nil` until the next refresh.

## See Also

- [Concepts](concepts.md)
- [Server and Compiler](server-and-compiler.md)
- [AST Deep-Dive](deep-dive/ast-deep-dive.md)
