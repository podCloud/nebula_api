# NebulaAPI Documentation

NebulaAPI is a compile-time, cross-node RPC framework for Elixir: you declare *where*
functions run, and the compiler generates a local implementation or a transparent RPC
stub per node. Start with the [project README](../README.md) for the overview and quick
start; these pages go deeper.

## Pages

- **[Concepts](concepts.md)** — nodes, tags, selectors, the execution model, result
  wrapping, and the three `use` macros.
- **[Configuration](configuration.md)** — the `nodes` topology, `default_opts`, dev/test
  setup, and compile-time validation.
- **[Macros Reference](macros-reference.md)** — `defapi`, `on_nebula_nodes`,
  `nebula_api_server`, `call_on_node` / `call_on_nodes` / `call_on_all_nodes`, and which
  `use` to pick.
- **[Server and Compiler](server-and-compiler.md)** — `NebulaAPI.Server` (per app),
  `APIServer` and `:pg` routing, workers, and the optional `:nebula` Mix compiler.
- **[Troubleshooting](troubleshooting.md)** — common compile-time and runtime errors.

## Deep dive

- **[AST Deep-Dive](deep-dive/ast-deep-dive.md)** — how selectors are parsed and how the
  three functions per `defapi` are generated, with worked examples.

## Guides

- **[Adding a NebulaAPI Function](guides/adding-nebula-api.md)** — a step-by-step
  walkthrough.

## Which `use` do I pick?

| `use ...` | For |
|-----------|-----|
| `NebulaAPI` | a module that defines `defapi` endpoints |
| `NebulaAPI.Server` | the module (usually the `Application`) that wires `nebula_api_server()` |
| `NebulaAPI.AST` | a module that only uses `on_nebula_nodes` / `call_on_*` |
