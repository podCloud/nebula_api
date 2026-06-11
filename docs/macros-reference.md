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

Standard signatures, including defaults and inline atoms:

```elixir
defapi &db, get(id), do: Repo.get(User, id)
defapi &db, list(filters \\ []), do: Repo.all(query(filters))
defapi :*, health(), do: %{node: node()}
```

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
```

| Option | Type | Default |
|--------|------|---------|
| `timeout` | integer (ms) | 5000 |

**Return value.** On success, you get the body's value exactly as-is (no wrapping). If the
transport fails (timeout, no worker, crash), you get `{:nebula_error, reason}`.

---

## `call_on_nodes` — multicast

```elixir
call_on_nodes &worker, strategy: :all, timeout: 30_000 do
  MyApp.Jobs.health_check()
end
```

| Option | Type | Default | |
|--------|------|---------|--|
| `timeout` | integer (ms) | 5000 | |
| `strategy` | atom | `:all` | `:all` / `:first` / `:quorum` |
| `quorum_count` | positive integer | `div(n, 2) + 1` | for `:quorum` — mutually exclusive with `quorum_proportion` |
| `quorum_proportion` | number `(0.5, 1]` | — | for `:quorum` — resolved as `ceil(p × workers)`; mutually exclusive with `quorum_count` |
| `success` | `fn value -> boolean` | a worker that *responded* | what counts as a business success for `:first` / `:quorum` — **raises `ArgumentError` with any other strategy** |
| `failure` | `fn value -> boolean` | — | mirror of `success`: a matching value is treated as a non-success — **raises `ArgumentError` with any other strategy** |

| Strategy | Behavior |
|----------|----------|
| `:all` | wait for every node (or timeout); returns a list of all results |
| `:first` | return the first **success**; remaining tasks cancelled |
| `:quorum` | wait for N **successes**; early-exit if it can no longer be reached |

A selector function receives the live `nodes_info` map (see below) and returns the list of
target nodes.

### Return values

Each per-node result keeps the body's value verbatim, tagged with its node. Transport
failures for a given node surface as `{:nebula_error, reason}` in that node's slot.

| Strategy | Returns |
|----------|---------|
| `:all` | a list of `{node, value}` — failed nodes appear as `{node, {:nebula_error, reason}}` |
| `:first` | the first `{node, value}` that counts as a success; if none succeed, the list of all responses |
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

Both options are **only meaningful with `:first` or `:quorum`**. Passing either on a unicast
call or with `strategy: :all` raises an `ArgumentError` up front — they would otherwise be
silently ignored. `call_on_node` also rejects them at compile time.

---

## `call_on_all_nodes` — broadcast

Convenience wrapper for multicast over every node that **serves this method** —
i.e. every node that has a registered worker for it, not necessarily every
configured node. Same options as `call_on_nodes`.

```elixir
call_on_all_nodes timeout: 5_000 do
  MyApp.Cache.invalidate(:all)
end
```

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
cached in ETS with a short TTL; refresh manually with
`NebulaAPI.APIServer.refresh_nodes_cache/0`.

## See Also

- [Concepts](concepts.md)
- [Server and Compiler](server-and-compiler.md)
- [AST Deep-Dive](deep-dive/ast-deep-dive.md)
