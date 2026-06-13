# Guide: Wrapping single-node libraries

The pattern that tends to click: **NebulaAPI turns any single-node library into a
cluster-wide one without touching the library.** No fork, no monkey-patch — just a few
lines of `defapi` that delegate to it on a chosen node.

If you've ever thought *"I'd love to use Cachex / a counter / a cron here, but its state
is per-node, so now I need Redis / a shared DB / `:global` locks…"* — this is the escape
hatch. The library stays exactly as it is. You pin it to one node and wrap it.

The shape is always the same: start the library only where it lives (a plain supervised
child, optionally guarded by [`on_nebula_nodes`](conditional-compilation.md) so other
nodes don't even load it), then expose its API through `defapi` selectors. Every node
calls the wrapper; it resolves locally on the chosen node and routes transparently via RPC
everywhere else.

## Shared cache — Cachex

[Cachex](https://hex.pm/packages/cachex) keeps its table in one VM. Pin it to a `@cache`
node and the whole cluster shares it:

```elixir
defmodule MyApp.Cache do
  use NebulaAPI

  defapi @cache, get(key),        do: Cachex.get(:app_cache, key)
  defapi @cache, put(key, value), do: Cachex.put(:app_cache, key, value)
  defapi @cache, del(key),        do: Cachex.del(:app_cache, key)
end
```

Start the Cachex instance only on the cache node:

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    children =
      [nebula_api_server()] ++
        on_nebula_nodes @cache do
          [{Cachex, name: :app_cache}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

> **An honest caveat.** This is great for values read often and invalidated rarely
> (dynamic config, reference data). But for a hot path doing thousands of reads per second
> per node, every read becomes an RPC round-trip — that's the **wrong** use, and a real
> distributed cache (Redis, or `:mnesia`) stays better. NebulaAPI is the right tool when
> the access pattern fits, not a universal replacement for a distributed cache.

## Rate limiter — cluster-wide Hammer

[Hammer](https://hex.pm/packages/hammer) with the ETS backend counts per node. Wrap it so
the whole cluster shares one count:

```elixir
defmodule MyApp.RateLimitLocal do
  use Hammer, backend: :ets
end

defmodule MyApp.RateLimit do
  use NebulaAPI

  defapi @control, hit(key, scale_ms, limit) do
    MyApp.RateLimitLocal.hit(key, scale_ms, limit)
  end
end
```

Every node calls `MyApp.RateLimit.hit/3`; it resolves locally on `@control` and routes
transparently via RPC everywhere else. One coherent count, no Redis.

## Aggregated counters and metrics

An Erlang `:counters` table or a GenServer counter, pinned to a `@stats` node:

```elixir
defmodule MyApp.Metric do
  use NebulaAPI

  defapi @stats, incr(name, n \\ 1), do: MyApp.MetricLocal.incr(name, n)
  defapi @stats, get(name),          do: MyApp.MetricLocal.get(name)
end
```

Cluster-wide counters without Prometheus or StatsD. For coarse numbers ("how many uploads
this month") it's plenty.

## Run-once-per-cluster scheduling

The classic: a job that must fire **once for the cluster**, not once per node. The usual
answers are `:global` locks or pulling in Oban + Postgres. Instead, pin a Quantum or a
plain scheduler GenServer to `@scheduler`:

```elixir
defmodule MyApp.Cron do
  use NebulaAPI

  defapi @scheduler, schedule(name, cron_expr, mfa) do
    MyApp.LocalCron.schedule(name, cron_expr, mfa)
  end
end
```

Single-execution guarantee, no external dependency.

## Singleton workers

"There must be exactly one process coordinating X across the cluster" — a WebSocket
registry, a GenStage broker, a job coordinator. `:global` works but is verbose and fails
over poorly. Wrap the GenServer on `@coordinator` and you get the same API as the
single-node version, centralized:

```elixir
defmodule MyApp.Coordinator do
  use NebulaAPI

  defapi @coordinator, enqueue(job), do: MyApp.CoordinatorLocal.enqueue(job)
  defapi @coordinator, status(),     do: MyApp.CoordinatorLocal.status()
end
```

## Feature-flag store

An `:ets` + GenServer flag store is trivial single-node but drifts between instances. Wrap
it on `@config` so every instance sees the same state — no Redis, no shared DB:

```elixir
defmodule MyApp.FeatureFlags do
  use NebulaAPI

  defapi @config, enabled?(flag),    do: MyApp.FeatureFlagsLocal.enabled?(flag)
  defapi @config, set(flag, value),  do: MyApp.FeatureFlagsLocal.set(flag, value)
end
```

## Picking the node

These examples pin to a single tagged node (`@cache`, `@control`, `@stats`, …) because the
whole point is *one* authoritative instance. Tag exactly one node with that capability in
your [topology](../configuration.md), and the wrapper is local there, remote everywhere
else. If you'd rather replicate across several nodes (a quorum write, say), that's a
[multicast call](calling-across-nodes.md), not a single-node wrapper.

## See also

- [Using `defapi`](using-defapi.md) — the macro these recipes are built on
- [Conditional compilation](conditional-compilation.md) — starting the library only where it lives
- [Calling across nodes](calling-across-nodes.md) — when you want several nodes, not one
