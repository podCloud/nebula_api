# NebulaAPI AST Deep-Dive

This page explains how NebulaAPI processes Elixir AST (Abstract Syntax Tree) at
compile time to generate node-specific code.

## Overview

The AST processing pipeline:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Compile-Time Pipeline                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Source Code                                                            │
│  ────────────                                                           │
│  defapi &db !@backup, get(id) do                                       │
│    Repo.get(User, id)                                                  │
│  end                                                                    │
│                                                                         │
│         │                                                               │
│         ▼                                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  1. ELIXIR COMPILER                                              │  │
│  │     Converts source to AST                                       │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│         │                                                               │
│         ▼                                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  2. AST.Parser.parse_nebula_ast/1                                │  │
│  │     Extracts: tags, not_tags, nodes, not_nodes                   │  │
│  │     Result: %{tags: [:db], not_nodes: [:backup], ...}            │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│         │                                                               │
│         ▼                                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  3. Config.nodes_for_*/2                                         │  │
│  │     Filters nodes by selector                                    │  │
│  │     Result: ["db@db.example": [...]]                             │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│         │                                                               │
│         ▼                                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  4. AST.Builder                                                  │  │
│  │     Generates remote + router (+ local on matching nodes)        │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## AST Parser

**File:** `lib/nebula_api/ast/parser.ex`

### Input: Selector AST

The canonical syntax juxtaposes selectors with a space. When you write:
```elixir
defapi &db !@backup, get(id) do ... end
```

the selector chain `&db !@backup` is *one* nested AST — each selector carries the next as
its sole argument (its "rest"):

```elixir
{:&, [], [{:db, [], [
  {:!, [], [{:@, [], [{:backup, [], nil}]}]}
]}]}
```

The parser walks that chain via its `rest` clauses (a selector identifier with a single
continuation arg), terminating at the last one (`nil` args). The bracketed list form
`[&db, !@backup]` parses to the equivalent config through a separate `is_list` clause — it
is tolerated, but not the canonical syntax.

### Parsing Process

The parser recursively extracts components:

```elixir
def parse_nebula_ast(ast) do
  ast
  |> nebula_ast()             # Initialize empty config
  |> extract_nebula_config()  # Recursively extract
end

defp nebula_ast(ast) do
  %{tags: [], not_tags: [], nodes: [], not_nodes: [], __unparsed: ast}
end
```

### Pattern Matching Rules

The parser matches AST patterns:

| Pattern | AST Structure | Extracted To |
|---------|---------------|--------------|
| `@node` | `{:@, _, [{node, _, _}]}` | `nodes` |
| `!@node` | `{:!, _, [{:@, _, [{node, _, _}]}]}` | `not_nodes` |
| `&tag` | `{:&, _, [{tag, _, _}]}` | `tags` |
| `!&tag` | `{:!, _, [{:&, _, [{tag, _, _}]}]}` | `not_tags` |
| `a b …` (space-juxtaposed) | a selector node whose args carry the next selector as its `rest` | process the chain |
| `[…]` | list | process each element (tolerated, non-canonical) |

Combine selectors by juxtaposing them with a space — `defapi &db !@backup, ...`. The
bracketed list (`defapi [&db, !@backup], ...`) parses to the same thing but is not the
canonical form.

### Lifting an absorbed trailing argument

A subtlety specific to `defapi` (and `call_on_*`): Elixir parses a space-juxtaposed chain
*followed by a trailing comma argument* — the `defapi` signature, or the `call_on_*` opts —
by folding that argument into the chain's deepest selector. `&db !@backup, get(id)` parses
as `&db(!@backup, get(id))`: the deepest selector identifier ends up with **two** args
(`!@backup` and the signature). Since a pure selector identifier only ever has `nil` or a
single continuation arg, that second arg is the unambiguous marker of an absorbed trailing
argument. The private `peel_chain/1` walks the chain, lifts the trailing argument back
out, and hands the pure selector chain to the parser — which is why the canonical
multi-selector form compiles even though the macro is `defapi/2` in that case.

### Example Parsing

```elixir
# Input AST — the canonical space-juxtaposed chain for `&db !@backup`:
# each selector carries the next as its single (rest) argument.
{:&, [], [
  {:db, [], [
    {:!, [], [{:@, [], [{:backup, [], nil}]}]}
  ]}
]}

# After parsing
%{
  tags: [:db],
  not_tags: [],
  nodes: [],
  not_nodes: [:backup]
}
```

### Function Definition Parsing

```elixir
def parse_fundef_ast({fn_name, _, fn_args}) do
  # Extracts function name and arguments
  %{
    name: fn_name,
    args: [...],
    args_count: length(args)
  }
end
```

Handles:
- Simple arguments: `arg` → `arg`
- Default arguments: `arg \\ default` → `{arg, default}`

Anything else — a pattern-matched argument (atom, map, list, tuple) — raises a
`CompileError`: a `defapi` argument needs a *name* to travel through the generated router
and the remote call tuple. Dispatch on values inside the body instead.

## Config Filter Functions

**File:** `lib/nebula_api/config.ex`

These functions filter the configured nodes based on the parsed selector.

### nodes_for_tags/2

Keep nodes that carry ALL of the specified tags (intersection — `&a &b` means a AND b):

```elixir
nodes_for_tags(nodes, [:db])
# Keeps: nodes where :db is in their tag list
nodes_for_tags(nodes, [:db, :cache])
# Keeps: only nodes carrying BOTH :db and :cache
```

### nodes_for_not_tags/2

Remove nodes that have ANY specified tags:

```elixir
nodes_for_not_tags(nodes, [:backup])
# Removes: nodes where :backup is in their tag list
```

### nodes_for_nodes_names/2

Keep only specified nodes:

```elixir
nodes_for_nodes_names(nodes, [:db])
# Keeps: only nodes named "db" or "db@..."
```

### nodes_for_not_nodes_names/2

Remove specified nodes:

```elixir
nodes_for_not_nodes_names(nodes, [:backup])
# Removes: nodes named "backup" or "backup@..."
```

### Filter Chain

Filters are applied in order:

```elixir
nodes()
|> nodes_for_nodes_names(parsed.nodes)          # 1. Include by name
|> nodes_for_not_nodes_names(parsed.not_nodes)  # 2. Exclude by name
|> nodes_for_not_tags(parsed.not_tags)          # 3. Exclude by tag
|> nodes_for_tags(parsed.tags)                  # 4. Include by tag
```

## AST Builder

**File:** `lib/nebula_api/ast/builder.ex`

For each `defapi`, the builder generates:

- `__nbapi_local_<name>` — private; the real implementation — **matching nodes
  only** (on the other nodes the router never references it, so nothing is emitted)
- `__nbapi_remote_<name>` — private; dispatches via `NebulaAPI.APIServer` (every node)
- `<name>` — the public router that delegates to local or remote based on context

**Return contract.** None of these wrap the body's value. The value of the `defapi`
body is returned **verbatim** — `10`, `%User{}`, `{:ok, x}`, `{:error, y}`,
`{:ok, a, b}` are all passthrough. The `{:nebula_error, reason}` tuple is reserved for
**library/transport failures**: a timeout, no available worker, a worker crash, an
exception raised by the body, or a quorum that could not be reached. For a multicast
call the router returns a list of `{node, value}` entries, with a failing node yielding
`{node, {:nebula_error, reason}}`.

### Local function

When the current node matches the selector, `build_local_function/3` emits the real
body; on every other node it emits **nothing** — the router's default branch goes
remote there, so no code references a local implementation (a raising stub would
only exist to keep a dead reference compilable). The body's value is returned
**as-is** — there is no wrapping. Anything that escapes the body is translated: a
raised exception becomes `{:nebula_error, exception}`, a throw or exit becomes
`{:nebula_error, {kind, reason}}` — the same shapes the worker produces for a
remote call.

```elixir
# is_local? = true
defp __nbapi_local_get(id) do
  Repo.get(User, id)   # value returned verbatim — no wrapping
rescue
  e ->
    require Logger
    Logger.error(Exception.format(:error, e, __STACKTRACE__))
    {:nebula_error, e}
catch
  kind, reason ->
    require Logger
    Logger.error("defapi body #{inspect(kind)}: #{inspect(reason)}")
    {:nebula_error, {kind, reason}}
end

# is_local? = false → no __nbapi_local_get at all
```

Note that only the public router carries the defaults — the private helpers are
always called with every argument, so they take plain parameters (a default there
would trigger an "is never used" compiler warning in every consumer module).

### Remote function

`build_remote_function/2` is generated on **every** node. It dispatches through the
APIServer and threads routing options. Whatever `call_remote_method/3` returns is passed
straight back to the caller — no re-wrapping, no `is_list` branching. A programming error
(an invalid call option, validated up front) is re-raised so it crashes loud at the call
site; only a genuine runtime exception becomes `{:nebula_error, exception}`. It also injects
the method's **configured serving set** (the selector resolved over the topology at compile
time, identical on every build) as a hidden `:__method_configured_nodes` opt, so a
`quorum: :configured` call knows its denominator without any runtime lookup. The stub's
set is authoritative — `Keyword.put` (not `put_new`) overwrites any caller-supplied value,
so a quorum can't be silently shrunk from the call site:

```elixir
defp __nbapi_remote_get(id, nebula_routing_opts) do
  NebulaAPI.APIServer.call_remote_method(
    __MODULE__,
    {:get, id},
    Keyword.put(nebula_routing_opts, :__method_configured_nodes, [:"db@db.example"])
  )
rescue
  e in ArgumentError -> reraise(e, __STACKTRACE__)
  e -> {:nebula_error, e}
end
```

### Public router

`build_public_function/2` is the function callers actually invoke. It reads the call
context (set by `call_on_node`/`call_on_nodes`) and decides where to go. `is_local?`
is known at codegen time, so the default branch is emitted as a direct call — local
on matching nodes, remote everywhere else — instead of a runtime check whose outcome
is predetermined:

```elixir
def get(id, nebula_routing_opts \\ []) do
  context_selector = Process.get(:nebula_node_selector)
  context_mode = Process.get(:nebula_call_mode)
  context_opts = Process.get(:nebula_call_opts, [])
  merged_opts = Keyword.merge(context_opts, nebula_routing_opts)

  cond do
    # Truthy :node_selector / :multicast opts on the call → remote.
    # The innermost explicit routing wins, even inside a call_on_* block:
    # the call routes itself, the block's routing and opts are ignored.
    nebula_routing_opts[:node_selector] || nebula_routing_opts[:multicast] ->
      __nbapi_remote_get(id, nebula_routing_opts)

    # Inside a call_on_node / call_on_nodes block (the MODE is the signal —
    # a selector expression may evaluate to nil, meaning "no restriction"),
    # and the call carries no routing key of its own. A routing key present
    # but nil/false opts the call out of the block, down to the default.
    not is_nil(context_mode) and
      not Keyword.has_key?(nebula_routing_opts, :node_selector) and
        not Keyword.has_key?(nebula_routing_opts, :multicast) ->
      __nbapi_remote_get(id, Keyword.merge(merged_opts,
        node_selector: context_selector, multicast: context_mode == :multicast))

    # Default branch, chosen at codegen time:
    true ->
      # On a matching node — routing opts validated (when present), not consumed:
      if nebula_routing_opts != [] do
        NebulaAPI.APIServer.validate_call_opts!(__MODULE__, nebula_routing_opts)
      end

      __nbapi_local_get(id)
      # __nbapi_remote_get(id, nebula_routing_opts)  # everywhere else
  end
end
```

Routing opts are validated on **every** node: a call that resolves locally still
validates the opts it was given (then ignores them — there is no transport), so an
invalid opt (`timeout: :infinity`, `strategy:`/`success:` without `multicast:`)
raises identically wherever the call runs. A valid-but-inapplicable opt, like a
`timeout:` on a local call, is a silent no-op — the same source compiles on every
node. The `!= []` guard keeps the opt-less hot path free of validation cost.

### Function signature building

```elixir
defp build_function_signature(fn_name, fn_args) do
  Macro.var(fn_name, nil) |> put_elem(2, fn_args_to_defaulted_vars(fn_args))
end
```

Handles default arguments (public router only — see the note above):
```elixir
# Input
[{:query, %{}}, {:opts, []}]

# Output signature (public)
get(query \\ %{}, opts \\ [])
```

### Remote call tuple

Arguments are packed into a tuple:

```elixir
defp build_remote_function_call(fn_name, fn_args) do
  quote do
    {unquote(fn_name), unquote_splicing(fn_args |> fn_args_to_vars)}
  end
end
```

```elixir
# Function: get(id, opts)
# Becomes: {:get, id, opts}
```

## Complete Example

### Source

```elixir
defmodule MyApp.Users do
  use NebulaAPI

  defapi &db, get(id, opts \\ []) do
    Repo.get(User, id, opts)
  end
end
```

### Compiled on a `:db` node

```elixir
@nebula_local_api_methods [{:get, 2}]
@nebula_remote_api_methods []

# public router → local
def get(id, opts \\ [], nebula_routing_opts \\ []) do
  # ...routes to __nbapi_local_get by default
end

defp __nbapi_local_get(id, opts) do
  Repo.get(User, id, opts)   # body value returned as-is
rescue
  e -> {:nebula_error, e}
end
```

### Compiled on a node without `:db`

```elixir
@nebula_local_api_methods []
@nebula_remote_api_methods [{:get, 2}]

# public router → remote (no __nbapi_local_get is generated on this node)
def get(id, opts \\ [], nebula_routing_opts \\ []) do
  # ...routes to __nbapi_remote_get
end

defp __nbapi_remote_get(id, opts, nebula_routing_opts) do
  NebulaAPI.APIServer.call_remote_method(MyApp.Users, {:get, id, opts}, nebula_routing_opts)
  # result returned verbatim
rescue
  e in ArgumentError -> reraise(e, __STACKTRACE__)
  e -> {:nebula_error, e}
end
```

The persisted module attributes (`@nebula_local_api_methods` /
`@nebula_remote_api_methods`) record what is local vs remote on this node — they're how
`NebulaAPI.Server` knows which workers to start.

## Validation

### Compile-time checks

```elixir
def validate_with_nodes(config, nodes) do
  # Check all tags exist
  unknown_tags = config.tags -- all_nodes_tags
  if Enum.any?(unknown_tags), do: raise(CompileError, description: "Unknown tags...")

  # Check all nodes exist
  unknown_nodes = config.nodes -- all_nodes_names
  if Enum.any?(unknown_nodes), do: raise(CompileError, description: "Unknown nodes...")
end
```

### Empty execution set

```elixir
if Enum.empty?(execution_nodes) do
  raise CompileError, description: "No nodes found for execution of nebula macro ..."
end
```

## Debugging AST

### Inspect a parsed selector

```elixir
NebulaAPI.AST.Parser.parse_nebula_ast(Code.string_to_quoted!("&db !@backup"))
# => %{nodes: [], tags: [:db], not_tags: [], not_nodes: [:backup]}
```

Parse the selector from source (`Code.string_to_quoted!/1`), not `quote do: &db !@backup`:
`quote` tags the identifiers with a macro context (`{:backup, _, Elixir}`), while the parser
matches bare source identifiers (`{:backup, _, nil}`) — the form `defapi` actually receives.

### Check execution nodes

```elixir
import NebulaAPI.Config

nodes()
|> nodes_for_tags([:db])
|> nodes_for_not_nodes_names([:backup])
# => ["db@db.example": [...]]
```

## See Also

- [Defining APIs](../defining.md) — using `defapi`, `on_nebula_nodes`, wiring the server
- [Calling across nodes](../calling.md) — runtime routing and the worker/`:pg` layer
- [Elixir Metaprogramming Guide](https://elixir-lang.org/getting-started/meta/quote-and-unquote.html)
