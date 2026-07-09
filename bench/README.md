# Benchmarks and measurements

Reproduce the numbers quoted in the project README.

## Routing latency — `routing.exs`

```bash
elixir --name bench@127.0.0.1 --cookie nebula_bench -S mix run bench/routing.exs
```

Plain local call vs NebulaAPI-resolved-local vs a cross-node round-trip (loopback peer).
Typical on OTP 26: ~8 ns / ~60–120 ns (machine-dependent) / ~50 µs.

## Smaller binaries — two ways

### Per-module `.beam` delta — `binary_size.exs`

```bash
elixir -S mix run bench/binary_size.exs
```

Compiles the same `defapi` module as a matching node (body emitted) vs a non-matching one
(router + stub only). The non-matching `.beam` is ~38% smaller — the body isn't there.

### Whole-dependency delta — the runnable demo

Each demo node compiles only the apps (and therefore the deps) it actually needs. The `db`
node owns the cache, so it's the only build that pulls Cachex; `apps/db/mix.exs` declares
Cachex as a conditional dep and `apps/db/lib/db/application.ex` starts it under
`on_nebula_nodes @db`.

```bash
cd demo
docker compose build
docker compose run --rm db       mix deps.get
docker compose run --rm db       mix compile
docker compose run --rm worker1  mix compile
docker compose run --rm demo_app mix compile
du -sh _build/db@db.test _build/worker@worker1.test _build/demo_app@demo_app.test
```

Measured (dev build): `db` ≈ 1.4 MB (carries Cachex + eternal/jumper/sleeplocks/unsafe,
~570 KB) vs `worker` ≈ 860 KB and `demo_app` ≈ 892 KB — the nodes that don't run the cache
are ~38% smaller because they never compile it.
