# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NebulaAPI is a **compile-time, cross-node RPC framework** for Elixir. You declare a cluster
topology (nodes + tags) in config; the compiler generates, per node, either a real local
implementation or a transparent RPC stub for each `defapi` function — **same source,
different bytecode per node, keyed on `node()` at compile time**.

This file is for working *on* the library. The user-facing model and API live in the docs —
read them, don't duplicate them here:

- [`README.md`](README.md) — the whole picture and the canonical selector syntax
- [`docs/`](docs/README.md) — Configuration · Defining · Calling · Gotchas (in that order)
- [`docs/deep-dive/ast-deep-dive.md`](docs/deep-dive/ast-deep-dive.md) — how the per-node code is generated
- [`ABOUT-LLMS.md`](ABOUT-LLMS.md) — provenance and how LLMs are used here

## Commands

**The test suite runs as a distributed node** — plain `mix test` will not work (the suite
exercises `:pg`, `:rpc`, and `node()`):

```bash
elixir --name probe@127.0.0.1 --cookie nebula_probe -S mix test
# single file / line:
elixir --name probe@127.0.0.1 --cookie nebula_probe -S mix test test/nebula_api/quorum_configured_test.exs:45
```

- `mix format` (review runs `mix format --check-formatted`).
- `mix docs` — must stay at **0 warnings**. The `extras:` list in `mix.exs` must match the
  real files under `docs/`, and links must point at files (never a bare directory) or ex_doc
  breaks the build. `/doc` is gitignored.
- `mix hex.build` dry-runs the package tarball; `mix hex.publish` releases it. A **public
  version can be overwritten only within 1 hour** of first publish (`mix hex.publish
  --replace`); after that, ship a new patch instead.

There is **no `config/` dir**. Tests set `config :nebula_api, :nodes` via
`Application.put_env` in their own `setup`, and compile throwaway modules with
`Code.compile_string/1`. To investigate parsing/codegen, compile a throwaway module and run
the generated functions — don't reason about the AST in your head.

## Architecture — two halves

Routing is decided at **compile time**, not runtime. Detail is in `docs/deep-dive`; the big
picture spans several files:

**Compile-time** (`lib/nebula_api/ast.ex`, `ast/parser.ex`, `ast/builder.ex`, `config.ex`,
`nebula_api.ex`):
- `AST.Parser` turns a selector AST (`&tag`, `@node`, `!…`, space-juxtaposed chains) into
  `%{tags, not_tags, nodes, not_nodes}`. Paren-less chains absorb trailing args into the
  deepest selector; `peel_chain/1` / `absorb_trailing_opts` lift them back out.
- `Config.nodes_for_*` filter the configured topology. **Tag filtering is intersection**
  (`Enum.all?`): `&a &b` means a AND b. The whole filter chain narrows.
- `AST.Builder` emits, per `defapi`: the public router, `__nbapi_remote_*` (every node), and
  `__nbapi_local_*` (matching nodes only). `is_local?` is known at codegen, so the router
  emits one default branch, not a runtime check.

**Runtime** (`api_server.ex`, `server.ex`, `api_server/worker.ex`,
`api_server/nodes_info_cache.ex`):
- `NebulaAPI.Server` — one per consumer app (wired with `nebula_api_server()`); discovers the
  app's `use NebulaAPI` modules with local methods and starts a `Worker` each. `server_mode/3`
  is the pure boot-policy function (serve / generic-noop / refuse) — test it without a second VM.
- `APIServer.Worker` — named after the consumer module; registers methods in `:pg`, runs each
  call in a supervised task, queues over `max_concurrent_calls` with caller-monitored entries.
- `APIServer.call_remote_method/3` — unicast / multicast (`:all` / `:first` / `:quorum`) and
  all the confinement.
- `NodesInfoCache` — rebuilds the node-info snapshot on a timer; reads never fan out.

## Invariants — do not break these when editing

Deliberate and load-bearing; a "cleanup" that violates one is a regression:

- **The caller never crashes, never hangs.** Every escape — a body exception/throw/exit, a
  `success:`/`failure:` predicate, a selector function — is confined to `{:nebula_error, _}`.
  Keep the `try/rescue/catch` and the `try/after` (kill tasks, `flush_ref`) intact.
- **`:infinity` timeout is rejected everywhere**, unicast included — an unbounded wait would
  hang the caller forever.
- **The `quorum: :configured` denominator is compile-time, never runtime.** The serving set
  is baked into the remote stub (`:__method_configured_nodes`, injected with `Keyword.put` so
  a caller can't spoof it). Do not "fix" it to count live workers.
- **Workers are registered under the consumer module's own name**, so stray messages reach
  them. The `handle_call`/`handle_info`/`handle_cast` catch-alls keep one stray message from
  killing the queue — don't remove them.
- **`nil` means "not set"** for every call option. Bad opts raise *up front* (outside the
  transport rescue); only genuine transport failures become `{:nebula_error, _}`.
- **Selectors are literal** at `call_on_*` sites (a `&tag`/`@node`, a literal `fn`, or none);
  variables and function captures (`&fun/1`) are compile errors. Static checks live in
  `ast.ex`, with a runtime backstop in `APIServer.validate_call_opts!`.
- **Error-tuple shape:** a single-node failure is `{:nebula_error, reason}`; a whole-call
  multicast failure is a 3-tuple (`:no_success`, `:quorum_not_reached`, `:quorum_timeout`,
  `:quorum_unreachable`).

## Releasing

Cut a release as a single commit:
- Bump the version **everywhere it is written**: `@version` in `mix.exs` and the `tag:` in the
  README git-install example. (`{:nebula_api, "~> X.Y"}` already covers patches.) Add a
  `CHANGELOG.md` section, keeping prior ones as history.
- Annotated tag `vX.Y.Z` on the release commit; merge to `main` with `--no-ff` (never squash).
  Pre-1.0, breaking changes bump the minor.

Push, merge, tag, and publish are **human-gated**: prepare them, but don't run them without
explicit confirmation.
