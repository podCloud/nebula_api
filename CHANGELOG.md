# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-06-10

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
  transport faults; update multicast matches to `{node, value}`.
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
- A `node_selector:` that is not a 1-arity function raises `ArgumentError` up front,
  like every other malformed call opt — it used to melt into
  `{:nebula_error, {:selector_failed, {:badfun, _}}}` at selection time, the one
  programming error reported on the transport channel. `nil` still means "not set";
  what the function does remains a contained runtime concern.
- Fan-out tasks no longer grant a worker a 100 ms grace window past the multicast
  deadline (a reply earned there was always discarded — the worker just ran a body
  nobody collected); a task that starts with no budget left skips the call and reports
  `{node, {:nebula_error, :timeout}}` directly.
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
  The same now holds for `call_on_node` / `call_on_nodes` nebula selectors: a typo'd
  node or unknown tag fails the build at the call site instead of melting into a
  runtime `{:nebula_error, {:selector_failed, ...}}`. Node selectors are compile-time
  by design — runtime selection goes through a function selector.
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
