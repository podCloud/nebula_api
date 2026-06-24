# NebulaAPI Documentation

NebulaAPI is a compile-time, cross-node RPC framework for Elixir: you declare *where*
functions run, and the compiler generates a local implementation or a transparent RPC stub
per node. Start with the [project README](../README.md) for the overview and the canonical
syntax; these pages go deeper, in the order you meet each theme.

## The four themes, in order

1. **[Configuration](configuration.md)** — nodes, tags, the `nodes` topology,
   compile-per-node, dev/test, and compile-time validation. *Set this up first.*
2. **[Defining APIs](defining.md)** — the three `use` macros, `defapi` (and the canonical
   space-juxtaposed selector syntax), signatures, return values, `on_nebula_nodes`, and
   wiring the per-app server.
3. **[Calling across nodes](calling.md)** — calling endpoints, overriding routing at
   runtime (`call_on_node` / `call_on_nodes` / `call_on_all_nodes`), multicast strategies,
   node-info routing, [introspection and the routing map](calling.md#seeing-the-whole-routing-map)
   (`mix nebula.routes` / `NebulaAPI.Server.print_routes/0`), wrapping single-node libraries, and
   [spawning a generic node](calling.md#spawning-a-generic-node-debug-or-call-anything-remotely)
   for a prod console or debug shell.
4. **[Gotchas and troubleshooting](gotchas.md)** — trailing routing options, per-process /
   one-hop block scope, the `nil`-selector distinction, serialization, and the common
   compile-time and runtime errors.

## Deep dive

- **[AST Deep-Dive](deep-dive/ast-deep-dive.md)** — how selectors are parsed and how the
  functions behind each `defapi` are generated, with worked examples.

## Canonical syntax, in one line

Selectors juxtapose with a **space**, never commas, never brackets:
`defapi &db !@backup, get(id) do … end`. The bracketed list form still compiles but is not
canonical — see [Defining APIs](defining.md#selectors).
