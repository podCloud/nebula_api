# Guide: Adding a NebulaAPI Function

A practical walkthrough for adding cross-node functions to your app.

## When to reach for it

Use NebulaAPI when a function needs to run on a node with a specific capability — data on
a `:db` node, encoding on a `:worker` node — but you want to call it from anywhere as if
it were local.

## 1. Add NebulaAPI to the module

```elixir
defmodule MyApp.Users do
  use NebulaAPI
end
```

## 2. Define functions with `defapi`

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  # Runs on :db nodes; transparent RPC everywhere else
  defapi &db, get(id) do
    Repo.get(User, id)
  end

  # Specific node
  defapi @primary, run_migration(version) do
    Ecto.Migrator.run(Repo, :up, to: version)
  end

  # Nodes with :db tag, excluding @backup
  defapi [&db, !@backup], write(attrs) do
    Repo.insert(User.changeset(%User{}, attrs))
  end

  # Every node reports its own value
  defapi :*, health() do
    %{node: node(), uptime: :erlang.statistics(:wall_clock) |> elem(0)}
  end
end
```

A single selector needs no brackets (`defapi &db, ...`); combine with a list
(`defapi [&db, !@backup], ...`). See [macros-reference.md](../macros-reference.md).

## 3. Wire the server into the app's supervisor

Defining `defapi` is not enough — a worker has to run on the node where the methods are
local, so other nodes can route to it. Wire one per app:

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

`use NebulaAPI.Server` is the lightweight host entry point (it brings `nebula_api_server/0`
and the `on_nebula_nodes`/`call_on_*` macros into scope, without the `defapi` bookkeeping).
Forget this step and calls fail at runtime with *"No worker found"* — so consider adding
the [`:nebula` compiler](../server-and-compiler.md) to catch it at build time.

## 4. Configure the topology

```elixir
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
  ]
```

Each release is compiled with its target node name (`elixir --name node@host -S mix
compile`), or in dev/test set `default_opts: [self_node: ...]`. See
[configuration.md](../configuration.md).

## 5. Call it — same API everywhere

```elixir
# Local on a :db node, transparent RPC elsewhere:
{:ok, user} = MyApp.Users.get(42)

# Override routing when you need to:
call_on_node @worker do
  MyApp.Jobs.transcode(path, opts)
end
```

## Conditional code with `on_nebula_nodes`

For code that should only *exist* on some nodes (a `use`, a child spec, a helper), use
`on_nebula_nodes` — no remote stub is generated. A module that does only this can `use
NebulaAPI.AST` (no need for the full `use NebulaAPI`):

```elixir
defmodule MyApp.Repo do
  use NebulaAPI.AST

  # Only :db nodes connect to (and even load) Ecto.
  on_nebula_nodes &db do
    use Ecto.Repo, otp_app: :my_app
  end
end
```

## Best practices

- **Keep functions small and single-purpose** — they're RPC boundaries.
- **Return plain data** — results cross Erlang distribution; no PIDs/refs/connections.
- **Be explicit in docs** about which node a function runs on.
- **Handle errors** in the body when you care about the shape; otherwise rely on the
  automatic `{:ok, _}` / `{:error, _}` wrapping.

## See Also

- [Macros Reference](../macros-reference.md)
- [Server and Compiler](../server-and-compiler.md)
- [Configuration](../configuration.md)
