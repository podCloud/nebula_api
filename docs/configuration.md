# NebulaAPI Configuration

How to configure nodes and tags.

## Configuration location

NebulaAPI is configured under the `:nebula_api` application:

```elixir
# config/config.exs
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db],
    "worker@worker.example": [:cluster, :worker]
  ]
```

## Options

### `nodes`

A keyword list mapping node names to their tags. **Required.**

```elixir
nodes: [
  "name@host": [:tag1, :tag2],
  "other@host": [:tag1, :tag3]
]
```

- **Node name** — an atom of the form `short@host` (quote it for the `@`).
  Selectors accept either the full name or the short part before `@`.
- **Tags** — a list of atoms describing the node's capabilities. Used in `defapi`
  selectors (`&tag`).

Workers are configured in the supervision tree, not here: each app wires
`nebula_api_server()` (via `use NebulaAPI.Server`) into its supervisor, which discovers
its `defapi` modules and starts the workers — see
[server-and-compiler.md](server-and-compiler.md).

### `default_opts`

Defaults applied by `use NebulaAPI`. The useful one is `self_node`, to tell the compiler
which node to build for **without** starting the VM with `--name` (handy in dev/test):

```elixir
# config/dev.exs
config :nebula_api,
  default_opts: [self_node: :"api@api.example"]
```

In production, prefer compiling each release with `elixir --name node@host -S mix compile`
(then `node()` is authoritative).

`default_opts` also accepts inherited defaults for every `use NebulaAPI` module:
`max_concurrent_calls:` (positive integer or `:infinity`) and `default_timeout:`
(positive integer, ms). A module's own `use NebulaAPI` options override them.

### `default_timeout`

Global default timeout (ms) for remote calls. Resolution order for every call:
the call's `timeout:` option, then the module's `default_timeout:`
(`use NebulaAPI, default_timeout: ...`), then this setting, then 5000.

```elixir
config :nebula_api, default_timeout: 15_000
```

### `nodes_info_refresh_interval`

How often (ms, default `5000`) each node's background `NodesInfoCache` rebuilds the
cluster node-info snapshot served to selector functions. Raise it on larger clusters
or when selectors tolerate staler info; until the first refresh completes, nodes not
yet in the snapshot are offered to selectors with `runtime: nil`.

```elixir
config :nebula_api, nodes_info_refresh_interval: 10_000
```

## Adding a node or a tag

Just edit the `nodes` list — add a node, or add a tag to an existing node:

```elixir
config :nebula_api,
  nodes: [
    "api@api.example": [:cluster, :api],
    "db@db.example": [:cluster, :db, :reporting],   # new :reporting tag
    "worker@worker.example": [:cluster, :worker],
    "cache@cache.example": [:cluster, :cache]        # new node
  ]
```

Then use the new tag/node in a selector: `defapi &reporting, ...` or `defapi @cache, ...`.

If you cluster with [libcluster](https://hex.pm/packages/libcluster), remember to add the
node to your topology too — NebulaAPI only decides *what code goes where*; forming the
Erlang cluster (epmd, DNS, libcluster, …) is the consumer's concern.

## Reading configuration

```elixir
# All nodes
NebulaAPI.Config.nodes()
# => ["api@api.example": [:cluster, :api], ...]

# Defaults
NebulaAPI.Config.default_opts()

iex> Application.get_env(:nebula_api, :nodes)
```

## Validation

NebulaAPI validates at **compile time**:

### Unknown node

```elixir
defapi @nope, f() do ... end
```
```
Unknown nodes in defapi call:
  - @nope

Available nodes:
  - @api
  - @"api@api.example"
  - @db
  - @worker
```

### Unknown tag

```elixir
defapi &nope, f() do ... end
```
```
Unknown tags in defapi call:
  - &nope

Available tags:
  - &api
  - &cluster
  - &db
  - &worker
```

### Unknown self_node

If you compile on a node not in `nodes` (and didn't set `allow_unknown_self_node: true`),
`use NebulaAPI` raises a `CompileError` telling you the `self_node` it saw and the
configured nodes.

## Testing

Give your test node every tag so all `defapi` bodies compile as local:

```elixir
# config/test.exs
config :nebula_api,
  nodes: [
    "test@localhost": [:cluster, :api, :db, :worker]
  ],
  default_opts: [self_node: :"test@localhost"]
```

## See Also

- [Concepts](concepts.md)
- [Server and Compiler](server-and-compiler.md)
- [Troubleshooting](troubleshooting.md)
