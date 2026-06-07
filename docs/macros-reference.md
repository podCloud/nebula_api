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
`defapi [&db, !@backup], ...`. Full node names with special chars: `defapi @"db@db.example", ...`.

### Signatures and return values

Standard signatures, including defaults and inline atoms:

```elixir
defapi &db, get(id), do: Repo.get(User, id)
defapi &db, list(filters \\ []), do: Repo.all(query(filters))
defapi :*, health(), do: %{node: node()}
```

Return values are wrapped consistently:

```elixir
defapi &db, get(id) do
  Repo.get(User, id)         # raw value → {:ok, value}
end

defapi &db, create(attrs) do
  Repo.insert(changeset)     # {:ok, _} / {:error, _} preserved as-is
end

# A raised exception becomes {:error, exception}
```

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
| `quorum_count` | integer | `div(n, 2) + 1` | for `:quorum` |

| Strategy | Behavior |
|----------|----------|
| `:all` | wait for every node (or timeout); returns a list |
| `:first` | first success wins; remaining tasks cancelled |
| `:quorum` | wait for N successes; early-exit if unreachable |

A selector function receives the live `nodes_info` map (see below) and returns the list of
target nodes.

---

## `call_on_all_nodes` — broadcast

Convenience wrapper for multicast over every configured node. Same options as
`call_on_nodes`.

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
