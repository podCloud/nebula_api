# nebula_api — live demo

A 5-node heterogeneous cluster showing `nebula_api` in action.

```bash
docker compose run --rm db mix deps.get   # one-time: fetch deps (incl. cachex)
docker compose up                          # build + start the 5 nodes
```

`demo_app` runs a scripted **tour** in its logs (unicast → `:all` → `:first` →
`:quorum`). The real fun is interactive — attach an IEx to any node and call the
API directly:

```bash
./console.sh worker2
```
```elixir
Db.Store.get("user:42")     # routed to @db — watch the `db` container logs light up
Worker.Job.run_task(7)      # runs locally on worker2
Code.ensure_loaded?(Cachex) # false on a worker, true on db — same Db.Store works everywhere
```

## The cluster

| Node | Tag | Role |
|---|---|---|
| `demo_app` | `&app` | runs the tour |
| `worker1/2/3` | `&worker` | compute (`Worker.Job.run_task`) |
| `db` | `&db` | a Cachex store made cluster-wide (`Db.Store`) |

## What it demonstrates

- **Transparent routing** — call `Db.Store.get` / `Worker.Job.run_task` from any node; it runs on the right one, and the target node's logs show it.
- **Multicast strategies** — `:all`, `:first`, `:quorum`. `worker3` always fails (via `on_nebula_nodes @:"worker@worker3.test"`), so `at_least: 2` succeeds (fault-tolerant) while `at_least: 3` returns `{:nebula_error, :quorum_not_reached, ...}`.
- **Wrap a third-party lib cluster-wide** — `Db.Store` wraps [Cachex](https://hex.pm/packages/cachex); the cache lives only on `@db`.
- **Conditional deps & compilation** — Cachex is pulled, compiled and started only on `@db`. `Code.ensure_loaded?(Cachex)` is `false` on every other node, yet `Db.Store` works everywhere (smaller binaries, no unnecessary deps).

## How it's built

The nebula dev approach: the source is mounted and each container compiles at
startup with its own `--name $RELEASE_NODE` (`X@X.test` — `.test` is a reserved
TLD, fully-qualified so Erlang long-name distribution is happy). `nebula_api`
generates different bytecode per node, so each node gets its own `_build`
(keyed by `RELEASE_NODE`). Dependencies are fetched once (the setup step), shared
read-only across nodes. No release needed; `mix release` is optional and not used
here.
