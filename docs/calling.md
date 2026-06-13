# 3. Calling across nodes

*You've defined endpoints ([Defining APIs](defining.md)). Now call them — and, when you
need to, override where they run.*

## Just call it

A `defapi` function is called like any other. Local on a matching node, transparent RPC
everywhere else — same call, same result:

```elixir
# Local on a :db node, RPC elsewhere. get/2 returns the struct (or nil) directly.
user = MyApp.Users.get(42)
#=> %User{id: 42, ...}  (or nil)
```

The body's value comes back verbatim ([no wrapping](defining.md#return-values--no-wrapping)).
A **transport** failure — timeout, no worker, a crashing body — comes back as
`{:nebula_error, reason}`, never confused with a business result:

```elixir
case MyApp.Users.get(42) do
  {:nebula_error, reason} -> handle_transport_failure(reason)
  user -> use(user)
end
```

That's the default routing the selector chose for you. The rest of this page is about
*overriding* it at runtime.

## Overriding routing at runtime

Three macros wrap a block, named after how far the call goes:

- **`call_on_node`** — *unicast*: run on exactly one node.
- **`call_on_nodes`** — *multicast*: run on every node a selector matches.
- **`call_on_all_nodes`** — *broadcast*: run on every node that serves the method.

Only `defapi`-generated functions read this context — wrapping a plain function call in a
`call_on_*` block does nothing to it.

### `call_on_node` — unicast

Force a call onto a specific node.

```elixir
call_on_node @worker do
  MyApp.Jobs.transcode(file, opts)
end

# Or a selector function over live node info (see below)
call_on_node fn nodes_info ->
  nodes_info
  |> Enum.filter(fn {_, i} -> i.connected && i.runtime end)
  |> Enum.min_by(fn {_, i} -> i.runtime.memory_percent end)
  |> elem(0)
end, timeout: 10_000 do
  MyApp.HeavyTask.run()
end

# Or options only — no selector: any available worker, with these options.
# This options-only form is the antidote to the trailing-opts gotcha (see Gotchas).
call_on_node timeout: 30_000 do
  MyApp.HeavyTask.run()
end
```

| Option | Type | Default |
|--------|------|---------|
| `timeout` | positive integer (ms) — `:infinity` rejected | 5000 |

`timeout:` is the **only** option `call_on_node` accepts; passing a multicast-only option
(`strategy:`, `at_least:`, `success:`/`failure:`), an unknown key, or `timeout: :infinity`
is a `CompileError` at the call site.

**Return value.** On success, the body's value exactly as-is. On a transport failure
(timeout, no worker, crash), `{:nebula_error, reason}`.

### `call_on_nodes` — multicast

```elixir
call_on_nodes &worker, strategy: :all, timeout: 30_000 do
  MyApp.Jobs.health_check()
end

# First to respond wins
call_on_nodes &worker, strategy: :first do
  MyApp.Jobs.transcode(file, opts)
end

# Quorum: at least 2 successes (a strict majority by default)
call_on_nodes &db, strategy: :quorum, at_least: 2 do
  MyApp.Users.write_replica(user)
end

# Options only — no selector: every node serving the method.
call_on_nodes strategy: :quorum, at_least: 2 do
  MyApp.Users.write_replica(user)
end
```

Selectors use the canonical space-juxtaposed syntax here too
(`call_on_nodes &db !@backup, strategy: :all do`).

| Option | Type | Default | |
|--------|------|---------|--|
| `timeout` | positive integer (ms) — `:infinity` rejected | 5000 | |
| `strategy` | atom | `:all` | `:all` / `:first` / `:quorum` |
| `at_least` | positive integer | `div(n, 2) + 1` (strict majority) | for `:quorum` — successes required |
| `success` | `fn value -> boolean` | a worker that *responded* | what counts as success for `:first` / `:quorum` |
| `failure` | `fn value -> boolean` | — | mirror of `success`; a matching value is a non-success |

Everything statically visible is validated at compile time (an unknown key, a malformed
literal, an impossible combination like `at_least:` with a non-`:quorum` strategy, or a
predicate with `strategy: :all`). Dynamic values defer to runtime, raising the same
`ArgumentError`.

### `call_on_all_nodes` — broadcast

The named alias of the selector-less `call_on_nodes` form: every node that **serves the
method** (has a registered worker for it), not necessarily every configured node.

```elixir
call_on_all_nodes timeout: 5_000 do
  MyApp.Cache.invalidate(:all)
end
```

## Multicast results

Per-node results are tagged — `{node, value}` on success, `{node, {:nebula_error, reason}}`
for a node whose call failed at the transport level.

| Strategy | Returns |
|----------|---------|
| `:all` | a list of `{node, value}` — failed nodes appear as `{node, {:nebula_error, reason}}` |
| `:first` | the first `{node, value}` that counts as a success; if none: `{:nebula_error, :no_success, results}` — never a bare list |
| `:quorum` (reached) | the list of `{node, value}` collected — the quorum of successes plus any non-success responses seen along the way |
| `:quorum` (not reached) | `{:nebula_error, :quorum_not_reached, results}` |
| `:quorum` (timed out) | `{:nebula_error, :quorum_timeout, results}` |
| `:quorum` (unreachable) | `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` — returned before any call is made when the required count exceeds available workers |

In every case `value` is the unwrapped body value.

### Defining "success": `success:` / `failure:`

By default, **any worker that responded** counts as a success for `:first` and `:quorum` —
a body returning `{:error, :not_found}` is still a successful *response*. To hinge on the
**business** outcome instead, narrow it:

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

`success:` is `fn value -> boolean`; `failure:` is its negation. A `{:nebula_error, _}`
result is **never** a success regardless of the predicate — the predicate only ever runs
against the body's own value, so library/transport failures can never be mistaken for a
healthy reply. A buggy predicate is contained like a buggy body (it becomes
`{:nebula_error, _}`, it never crashes the caller). Both options are meaningful **only**
with `:first` or `:quorum`; passing either elsewhere raises an `ArgumentError` up front.

## Node info and intelligent routing

`call_on_node` / `call_on_nodes` accept a **selector function** that receives live runtime
data about every node and returns the target(s):

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

This is an ETS snapshot rebuilt in the background every `nodes_info_refresh_interval` ms
(see [Configuration](configuration.md#nodes_info_refresh_interval)); reads never trigger a
rebuild. A node whose worker just registered but isn't in the snapshot yet still appears,
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

A selector function that returns `nil` / `[]` means "nothing matched" — it never widens the
target (the full `nil`-selector vs selector-returning-`nil` distinction is in
[Gotchas](gotchas.md)).

## Wrap any single-node library

The pattern that tends to click: **NebulaAPI turns any single-node library into a
cluster-wide one without touching the library.** No fork, no monkey-patch — pin it to one
node and expose its API through `defapi`. The library stays exactly as it is.

```elixir
# Cachex runs only on @cache; every node shares one cache through the wrapper.
defmodule MyApp.Cache do
  use NebulaAPI

  defapi @cache, get(key),        do: Cachex.get(:app_cache, key)
  defapi @cache, put(key, value), do: Cachex.put(:app_cache, key, value)
  defapi @cache, del(key),        do: Cachex.del(:app_cache, key)
end
```

Start the instance only where it lives, guarded by `on_nebula_nodes` so other nodes don't
even load it:

```elixir
children =
  [nebula_api_server()] ++
    on_nebula_nodes @cache do
      [{Cachex, name: :app_cache}]
    else
      []
    end
```

The same trick gives you cluster-wide rate limiters (a `:ets`-backed Hammer), aggregated
counters/metrics, run-once-per-cluster schedulers (a Quantum on `@scheduler`), singleton
coordinators, and feature-flag stores — each pinned to a single tagged node, local there,
transparent RPC everywhere else.

> **An honest caveat.** This is great for values read often and invalidated rarely (dynamic
> config, reference data). For a hot path doing thousands of reads per second per node,
> every read becomes an RPC round-trip — that's the **wrong** use, and a real distributed
> cache (Redis, or `:mnesia`) stays better. NebulaAPI is the right tool when the access
> pattern fits, not a universal replacement for a distributed cache.

If you'd rather replicate across several nodes (a quorum write, say), that's a
[multicast call](#call_on_nodes--multicast), not a single-node wrapper.

## Next

- [Gotchas](gotchas.md) — trailing opts, process scope, nesting, timeouts, common errors.
- [AST deep-dive](deep-dive/ast-deep-dive.md) — how the generated routers work under the hood.
