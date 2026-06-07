# Server, Workers and the `:nebula` Compiler

How NebulaAPI starts and supervises workers at runtime, and how the optional compiler
guards your wiring.

## The pieces

```
┌─────────────────────────────────────────────────────────────────────┐
│  per OTP app                                                          │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  NebulaAPI.Server  (one per app, in the app's own supervisor)   │  │
│  │   - resolves the app's modules                                  │  │
│  │   - keeps those that use NebulaAPI with LOCAL methods here      │  │
│  │   - starts one Worker per such module                           │  │
│  │      ┌───────────────┐  ┌───────────────┐                       │  │
│  │      │ Worker(Mod A) │  │ Worker(Mod B) │  ... → join :pg       │  │
│  │      └───────────────┘  └───────────────┘                       │  │
│  └────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  NebulaAPI.APIServer  (one per node — cluster-wide plumbing)          │
│   - :pg scope :pg_nebula_api   (worker discovery + routing)           │
│   - ETS node-info cache        (memory/load per node, TTL'd)          │
│   - call_remote_method/3       (unicast / multicast / quorum)         │
└─────────────────────────────────────────────────────────────────────┘
```

## NebulaAPI.Server (per app)

Each OTP application wires one server into its supervision tree with `use NebulaAPI.Server`
and the `nebula_api_server/0` macro:

```elixir
defmodule MyApp.Application do
  use Application
  use NebulaAPI.Server

  def start(_type, _args) do
    Supervisor.start_link([nebula_api_server()], strategy: :one_for_one, name: MyApp.Sup)
  end
end
```

At startup the server:

1. resolves the OTP app it belongs to (from the host module),
2. lists that app's modules,
3. keeps the ones that `use NebulaAPI` **and** have at least one method compiled as local
   on this node,
4. starts one `NebulaAPI.APIServer.Worker` per retained module.

No module list, no config. The set is discovered from the compiled `.beam` metadata.

**Lifecycle is correct for free.** Because the server lives in the app's own tree, if the
app stops or crashes its server and workers go down with it, and `:pg` drops their
entries — there are no stale routing targets. (Contrast a central registry, which would
keep advertising a worker whose app has died.)

## Worker

A `NebulaAPI.APIServer.Worker` is a `GenServer` named after its module. On init it
registers each of the module's local methods in `:pg`:

```elixir
:pg.join(:pg_nebula_api, {module, {function, arity}}, self())
```

On a remote call it `apply/3`s the function and replies. It's supervised `:one_for_one`
under its app's `NebulaAPI.Server`.

## APIServer (per node)

`NebulaAPI.APIServer` is a small supervisor holding the cluster-wide plumbing only:

- the `:pg` scope `:pg_nebula_api` used to find workers across nodes,
- an ETS cache of node info (memory, load, `last_seen_at`) with a short TTL,
- `call_remote_method/3`, which routes a call (unicast, multicast `:all`/`:first`/`:quorum`).

It does **not** start workers — that's each app's `NebulaAPI.Server`.

```elixir
# Inspect routing state
:pg.which_groups(:pg_nebula_api)
:pg.get_members(:pg_nebula_api, {MyApp.Users, {:get, 1}})
Process.whereis(MyApp.Users)   # the worker for that module, if local here
```

## The `:nebula` compiler (optional guard)

It's easy to forget `nebula_api_server()` in an app that has `defapi` modules — the
result is workers that never start and calls that fail at runtime with *"No worker
found"*. The optional `:nebula` Mix compiler turns that into a **compile error**.

Opt in from the app's `mix.exs`:

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers() ++ [:nebula]
  ]
end
```

After `:app` compiles, it reads the persisted attributes from the `.beam` files and, if an
app has modules with local methods but no module wired `nebula_api_server()` (no
`:nebula_api_server_wired` marker), it fails compilation:

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

This is the same spirit as the `CompileError` NebulaAPI already raises for a `defapi`
targeting an unknown node — catch it at build time, not in production. In an umbrella the
compiler is `@recursive`, so it checks each child app in its own context.

## See Also

- [Macros Reference](macros-reference.md)
- [Concepts](concepts.md)
- [Troubleshooting](troubleshooting.md)
