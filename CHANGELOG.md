# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Boot-time node-name guard.** `nebula_api_server()` records the node a release was
  *compiled* as; at boot `NebulaAPI.Server` crashes with a clear error if the *running* node
  differs — the compile-time `--name` and the runtime `RELEASE_NODE` must match, or every
  routing decision baked into the release would be wrong. The check only fires when both
  names are real, distributed names that differ; a `:nonode@nohost` on either side (dev,
  tests, nameless builds) is skipped, so it never gets in the way locally.

### Removed
- **Breaking: the `:*` selector is gone.** To make a `defapi` body run on every node,
  **omit the selector entirely** — `defapi name(args) do ... end` — the same way
  `call_on_nodes`/`call_on_all_nodes` with no selector means "everyone". `:*` was visually
  unlike every other selector and added a special case; "no selector = all nodes" is the
  natural reading. `defapi :*, f()` now raises a `CompileError`.

### Fixed
- **Canonical space-juxtaposed multi-selectors now compile in `defapi` and
  `call_on_node` / `call_on_nodes`.** The canonical NebulaAPI syntax juxtaposes
  selectors with a space (`defapi &db !@backup, get(id)`), never a bracketed
  list. Elixir folds a juxtaposed chain's trailing argument (the `defapi`
  signature, or the `call_on_*` opts) into the chain's deepest selector
  (`&db !@backup, get(id)` parses as `&db(!@backup, get(id))`); the macros now
  lift that trailing argument back out before handing the pure chain to the
  parser. Previously only a single selector or the bracketed `[&db, !@backup]`
  form compiled for these macros. The bracketed list keeps working as a
  tolerated, non-canonical alternative. Covered by `nebula_ast_parsing_test`.
- **The inline `do:` (and `else:`) form now works with multi-selectors too**, across
  `defapi`, `on_nebula_nodes` and `call_on_node` / `call_on_nodes` — e.g.
  `defapi &db !@backup, get(id), do: ...` and
  `on_nebula_nodes &worker !@backup, do: ..., else: ...`. The paren-less parse folds the
  `do:`/`else:`/opts keyword list into the selector chain (arity 1); the macros lift it
  back out alongside the signature. Block (`do ... end`) and inline forms now behave
  identically for one selector or many.

## [0.4.0] - 2026-06-13

### Changed
- **Breaking: transparent return contract.** A `defapi` body's return value is now passed
  through verbatim — there is no automatic `{:ok, value}` wrapping. `add(3, 7)` returns
  `10`; `Repo.get/2` returns `%User{}` or `nil`; an `{:ok, _}` / `{:error, _}` you return is
  preserved as-is and always means a *business* result.
- **Breaking: dedicated `:nebula_error` status for library/transport failures** (timeout,
  no worker available, worker/network crash, a body exception, quorum not reached):
  `{:nebula_error, reason}`. `:ok` / `:error` therefore never collide with library faults.
- **Breaking: multicast result shape.** Per-node results are now `{node, value}` (a
  transport failure for a node is `{node, {:nebula_error, reason}}`). `:first` without a
  qualifying success returns `{:nebula_error, :no_success, results}` — it never returns a
  bare list (a bare-list result was the one library failure outside the `:nebula_error`
  channel, and the same "list" shape meant success for `:quorum` but failure for `:first`).
  `:quorum` returns the list of `{node, value}` when reached, otherwise
  `{:nebula_error, :quorum_not_reached, results}` or `{:nebula_error, :quorum_timeout, results}`.
  Migration: expect raw body values instead of `{:ok, _}`; match `{:nebula_error, _}` for
  transport faults; update multicast matches to `{node, value}`; replace `quorum_count:`
  with `at_least:`.
- Node-info is now refreshed by a per-node background `NebulaAPI.APIServer.NodesInfoCache` on a fixed
  interval instead of being rebuilt lazily on every read — this removes the refresh stampede
  under concurrency. `get_nodes_info/0` is a pure read: it never builds the snapshot itself,
  not even on a cold cache (during the boot window it returns `%{}`; selectors still see
  every pg-registered node through synthesized entries). The background tick is the one and
  only builder.
- Internal worker wire format: calls now ship as `{:nebula_call, fn_call}`.
- `use NebulaAPI` now generates a `__nebula_api__/1` accessor for its options
  (`:default_timeout`, `:max_concurrent_calls`): a function head on a literal,
  so per-call timeout resolution no longer scans the module's attribute list.
  The persisted `:nebula_api` attribute remains (server discovery, compile-time
  `self_node`).

### Added
- `success:` / `failure:` options on `call_on_nodes` (`:first` / `:quorum`): a predicate
  `fn value -> boolean` defining what counts as a business success. Default: any worker that
  responded. Example: `success: &match?({:ok, _}, &1)`. Passing either option outside
  `:first`/`:quorum` (unicast, `strategy: :all`) raises an `ArgumentError` up front;
  `call_on_node` also rejects them at compile time. A predicate that raises, throws or
  exits is contained like a body would be: the call returns `{:nebula_error, exception}`
  / `{:nebula_error, {kind, reason}}` — it never crashes the caller.
- `at_least:` option on `call_on_nodes` (`:quorum`): the number of successes required,
  as a positive integer — an absolute durability floor ("at least 2 nodes hold this
  write"), legitimately below majority. Without it the quorum defaults to a strict
  majority of the targeted workers. Malformed values raise `ArgumentError` up front.
- Options-only form for `call_on_node` / `call_on_nodes`: the selector argument can be
  omitted entirely. `call_on_node timeout: 30_000 do ... end` is a unicast to any
  available worker — a semantic with_options, free of the trailing-routing-opts
  positional gotcha. `call_on_nodes strategy: :quorum, at_least: 2 do ... end` fans out
  to every node serving the method; `call_on_all_nodes` is now the named alias of that
  form. Unambiguous by construction: a nebula selector list contains `@`/`&`/`!` AST
  nodes, never keyword pairs (`[]` stays an empty selector, rejected at compile time —
  see Fixed).
- `nodes_info_refresh_interval` config option (ms, default `5000`).
- `max_concurrent_calls` option on `use NebulaAPI` (default `:infinity`): caps how many
  calls a module's worker executes concurrently, per node. Excess calls queue (callers
  keep their own timeout); each queued entry is monitored through its caller and purged
  unexecuted the moment nobody awaits it anymore (timeout, early `:first` resolution,
  caller crash, disconnect). `max_concurrent_calls: 1` restores strict serialization,
  explicitly — per node, like the limit itself.
- Configurable timeouts: per call (`timeout:`) > per module (`use NebulaAPI,
  default_timeout: ...`) > global (`config :nebula_api, default_timeout:`) > 5000 ms.
  Both options are also accepted in `config :nebula_api, default_opts: [...]` as
  inherited defaults for every `use NebulaAPI` module.
  Timeouts are validated up front like every other call option: a non-positive,
  non-integer or `:infinity` timeout raises `ArgumentError` at the call site
  (previously, `:infinity` half-worked: fine on unicast, melted into
  `{:nebula_error, %ArithmeticError{}}` on multicast). `timeout: nil` is the one
  documented exception: it means "not set" and inherits the default resolution —
  a computed `timeout: maybe_timeout` holding nil behaves as if the option were
  absent (`false` does NOT: like any other non-integer, it raises).

### Fixed
- `:quorum` strategy no longer silently clamps an impossible `at_least:` requirement to the
  available worker count — asking for 3 confirmations and "reaching quorum" with 2 would lower the
  caller's durability guarantee behind their back. An impossible quorum now returns
  `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` before making any
  call — for a write quorum, no partial non-quorate write is even attempted.
- `:quorum` with zero available workers no longer returns `[]` (an empty-list pseudo-success);
  it returns `{:nebula_error, :quorum_unreachable, %{workers: 0, required: m}}`.
- A function selector returning duplicate nodes no longer makes a node count twice —
  toward the `:quorum` requirement especially, where two replies from one physical node
  passed for two confirmations. Selected nodes are deduplicated before the fan-out.
- An unknown `strategy:` no longer falls into the `:all` catch-all (`strategy: :qourum`
  silently turned a quorum write into a plain broadcast); it raises `ArgumentError` up
  front, as does `strategy:` on a non-multicast call, where it would be silently ignored.
- The `nil`-means-"not set" convention now covers every call opt: `strategy: nil`
  resolves to the `:all` default (it used to raise), and `success: nil` / `failure: nil`
  are absent for the applicability check too (they used to raise "would be silently
  ignored" on unicast while already counting as unset on `:first`/`:quorum`).
- A `node_selector:` that is not a 1-arity function raises `ArgumentError` up front,
  like every other malformed call opt — it used to melt into
  `{:nebula_error, {:selector_failed, {:badfun, _}}}` at selection time, the one
  programming error reported on the transport channel. `nil` still means "not set";
  what the function does remains a contained runtime concern.
- Unknown call option keys raise `ArgumentError` up front — the option set is closed
  (`timeout:`, `node_selector:`, `multicast:`, `strategy:`, `at_least:`, `success:`,
  `failure:`), so a typo'd key (`timout:`) or a stale one (`quorum_count:`, replaced by
  `at_least:`) was silently dropped and the call ran with defaults the caller never
  chose — for a quorum, a durability requirement quietly replaced by the majority
  default.
- An empty selector list (`[]`) raises a clear `CompileError` everywhere a selector is
  accepted (`defapi`, `on_nebula_nodes`, `call_on_node`/`call_on_nodes`) — it used to
  silently select every **configured** node. `[]` selects no node, so nothing could ever
  run: `:*` is the explicit "all nodes", omitting the selector is the explicit "no
  restriction" in `call_on_*`.
- The `call_on_*` macros validate their literal options at compile time: an option the
  mode can never consume (`strategy:`/`at_least:`/`success:`/`failure:` on the unicast
  `call_on_node`), an unknown key, a malformed literal value (`timeout: :infinity`,
  `strategy: :qourum`, `at_least: 0`) or a statically-impossible combination
  (`at_least:` when the block resolves to a non-`:quorum` strategy, a predicate with
  `strategy: :all`) now fails the build at the call site instead of the first runtime
  call. Dynamic values (a variable `strategy:`, a whole-opts variable) keep the runtime
  `ArgumentError` backstop, where `nil` still means "not set".
- The "Invalid nebula selector" compile error now points out that dynamic selection (a
  variable or a selector function) only works in `call_on_node`/`call_on_nodes` —
  `defapi` and `on_nebula_nodes` are resolved statically at compile time.
- Fan-out tasks no longer grant a worker a 100 ms grace window past the multicast
  deadline (a reply earned there was always discarded — the worker just ran a body
  nobody collected); a task that starts with no budget left skips the call and reports
  `{node, {:nebula_error, :timeout}}` directly.
- The generated router detects an active `call_on_node`/`call_on_nodes` block through the
  context MODE, not the selector value: a selector expression that evaluates to `nil` at
  runtime now means "no restriction" (unicast: first available worker; multicast: every
  node serving the method) with the block's options still applying — previously the whole
  context was silently skipped, dropping `timeout:`/`strategy:`/`at_least:` and degrading
  a multicast block to a default unicast call. A selector **function** returning `nil`
  keeps its meaning: "nothing matched", zero calls — a no-match never widens the target.
- Inside a `call_on_*` block, the innermost explicit routing now wins: a call carrying
  its own truthy `node_selector:`/`multicast:` trailing opts routes itself (the block's
  routing and options are ignored for that call, like an inner block replaces the outer
  one) instead of being silently overwritten by the block. A routing key explicitly set
  to `nil` (or `multicast: false`) opts the call out of the block, back to default
  routing — `MyMod.f(x, multicast: false)` inside a multicast block is a plain default
  call. General rule inside a block: the block's opts are defaults, the call's own opts
  override them, an explicit `nil` opts out of the block's default back to the lib's.
- Literal `success:`/`failure:` values that can never be a predicate
  (`success: :not_a_fun`) now fail the build at the call site in the `call_on_*`
  macros, like every other malformed literal option value — no literal is ever a
  1-arity function; `nil` keeps meaning "not set", `fn`/`&` predicates stay a
  runtime concern.
- Routing opts are now validated on locally-resolved calls too: an invalid opt
  (`timeout: :infinity`, `strategy:`/`success:`/`failure:` without `multicast:`)
  raises `ArgumentError` identically on every node, instead of being silently
  ignored wherever the call happened to resolve local. Valid-but-inapplicable opts
  (a `timeout:` on a local call) stay a silent no-op; calls without opts skip
  validation entirely.
- Selectors now see every node with a registered worker, snapshot or not: pg decides WHO
  serves a method, the node-info snapshot only enriches HOW. A node whose worker just
  registered (not in the snapshot yet) gets a synthesized entry — name/host/config
  tags/connected derived locally, `runtime`/`last_seen_at` `nil` until the next refresh.
  Previously such a node was invisible to selectors (and to `call_on_all_nodes`) for up
  to `nodes_info_refresh_interval`.
- Unicast calls no longer crash the caller when a worker times out or is dead — the
  `GenServer.call` exit is caught and returned as `{:nebula_error, reason}`, with the late
  reply confined to a throwaway task (no stray messages reach the caller).
- The `:all` multicast strategy no longer exits the caller on timeout; it returns partial
  results, marking unanswered nodes `{node, {:nebula_error, :timeout}}`.
- Workers are non-blocking: each call runs in a supervised task and replies asynchronously,
  so a slow method no longer serializes a module's whole API and a re-entrant call no longer
  deadlocks (except under `max_concurrent_calls: 1`, where a re-entrant call into the same
  module waits out its own timeout — the slot is held by its parent).
- An unknown method, a malformed call, or a raising body returns `{:nebula_error, ...}`
  instead of crashing the worker. Stray info messages and casts are likewise logged and
  ignored — the worker (and its pending queue) survives anything that reaches its
  registered name.
- `NodesInfoCache` gets the same hardening as the worker: a stray info message, cast or
  call no longer crashes it (its `handle_info(:refresh)` clause had replaced the permissive
  `use GenServer` default, and the default `handle_call`/`handle_cast` raise) — repeated
  strays would have exhausted the supervisor's restart intensity.
- `build_nodes_info` no longer aborts the whole snapshot when one node's health collection
  crashes (a non-timeout task exit) — the faulty node is simply dropped.
- A body that throws or exits now yields `{:nebula_error, {kind, reason}}` locally
  too, matching the remote behavior — previously the throw/exit escaped the
  generated local function and propagated into the caller, so the same call could
  behave differently depending on where it ran.
- Invalid `defapi` selectors and signatures, using `defapi` without `use NebulaAPI`, and
  malformed node tags now raise clear `CompileError`s instead of internal crashes.
  Literal atoms in a `defapi` signature are rejected like every other pattern — they
  used to slip through and compile into a single-clause router whose misses crashed the
  caller with a `FunctionClauseError`.
  The same now holds for `call_on_node` / `call_on_nodes` nebula selectors: a typo'd
  node or unknown tag fails the build at the call site instead of melting into a
  runtime `{:nebula_error, {:selector_failed, ...}}`. Node selectors are compile-time
  by design — runtime selection goes through a function selector.
- `call_on_all_nodes timeout: 5_000 do ... end` — the block-with-options form the README
  has always advertised — now actually compiles: it parses as two arguments and no
  arity-2 head existed to receive it.
- `mix docs` (and therefore `mix hex.publish`) no longer fails — the `docs` extras point at
  files that exist.
- `defapi` no longer emits compiler warnings in consumer modules ("default values for
  the optional arguments ... are never used" on every defapi, "variable is unused" on
  remote-compiled defapis with arguments) — defaults now live only on the generated
  public function. Consumers building with `warnings_as_errors` compile cleanly.
- The generated router no longer carries a branch whose outcome is known at codegen
  time: its default branch is emitted directly as local (matching nodes) or remote
  (everywhere else), and the raising `__nbapi_local_*` stub — which only existed to
  keep that dead branch compilable on remote nodes — is not generated at all anymore.

### Documentation
- Rewrote all return-value documentation for the transparent contract. Corrected the
  local-call overhead figure (~0.00002 ms — a few process-dictionary reads, not zero) and
  clarified that `call_on_all_nodes` targets the nodes that serve the method, not every
  configured node.
- Documented nesting and process scope of the `call_on_*` blocks: an inner block
  replaces the whole context (no option merge) and the outer one is restored on exit,
  exceptions included; the context is per process — it follows neither a spawned
  process nor the RPC boundary (a block governs one hop, the calls written directly in
  it). Also documented that a `defapi` inside `on_nebula_nodes` disappears entirely
  (router included) on non-matching nodes — no transparent RPC from there.

## [0.3.0] - 2026-06-08

### Added
- `use NebulaAPI.Server` + `nebula_api_server/0` macro: wire it into an OTP application's
  supervision tree to start a per-app `NebulaAPI.Server`, which discovers that app's
  modules using `NebulaAPI` and supervises one worker per locally-served module.
  `use NebulaAPI.Server` is the lightweight host-module entry point — it brings the macro
  (and the `NebulaAPI.AST` macros) into scope without the `defapi` bookkeeping that
  `use NebulaAPI` performs.
- Optional `:nebula` Mix compiler (`compilers: Mix.compilers() ++ [:nebula]`): fails
  compilation with an explanatory error when an app has modules with local methods but
  no `nebula_api_server()` wired into its supervisor.
- Select a full node name with an atom selector `@:"node@host"` in `defapi` /
  `on_nebula_nodes` — the parser previously accepted only short-name identifiers (`@db`).

### Changed
- **Breaking:** removed the `registered_modules` config option. Module workers are now
  discovered per app at runtime (via `nebula_api_server/0`) instead of being listed in
  config. Migration: drop `registered_modules` and add `nebula_api_server()` to each
  consuming app's supervisor children.
- Workers now live in the supervision tree of the app that owns their module, so they
  share the app's lifecycle — when the app stops or crashes, its workers go down and
  `:pg` drops them (no more stale routing entries). The central `APIServer` is reduced
  to the `:pg` scope, the node-health ETS cache, and routing.

### Documentation
- Rewrote the README and `docs/` to be generic and library-only, and added a 5-node
  `docker compose` demo under `demo/`.

## [0.2.0] - 2026-06-07

First standalone release, extracted from the podCloud Nebula umbrella with its
full git history preserved.

### Added
- Unicast/multicast remote calls — `call_on_node`, `call_on_nodes`,
  `call_on_all_nodes` — with `:all` / `:first` / `:quorum` strategies.
- `nodes_info` cache with `last_seen_at` tracking for intelligent routing.

### Changed
- Zero external dependencies: `libcluster` removed — clustering is the
  consumer's concern (use libcluster, epmd, DNS, Kubernetes, etc.). The
  podCloud-specific cluster strategy now lives in the consuming application.

### Documentation
- Expanded README: "Wrap any single-node library" (cluster-wide Hammer, counters,
  cron, singletons, feature flags, cache caveat), "When NOT to use NebulaAPI", a
  "compile per release" callout, and an indicative performance table.
