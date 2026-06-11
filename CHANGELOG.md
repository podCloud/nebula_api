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
- Node-info is now refreshed by a per-node background `NebulaAPI.NodesInfoCache` on a fixed
  interval instead of being rebuilt lazily on every read — this removes the refresh stampede
  under concurrency. `get_nodes_info/0` is a pure read: it never builds the snapshot itself,
  not even on a cold cache (during the boot window it returns `%{}`; selectors still see
  every pg-registered node through synthesized entries). The background tick is the one and
  only builder.
- Internal worker wire format: calls now ship as `{:nebula_call, fn_call}`.

### Added
- `success:` / `failure:` options on `call_on_nodes` (`:first` / `:quorum`): a predicate
  `fn value -> boolean` defining what counts as a business success. Default: any worker that
  responded. Example: `success: &match?({:ok, _}, &1)`. Passing either option outside
  `:first`/`:quorum` (unicast, `strategy: :all`) raises an `ArgumentError` up front;
  `call_on_node` also rejects them at compile time.
- `quorum_proportion:` option on `call_on_nodes` (`:quorum`): a number in `(0.5, 1]` that
  expresses the required quorum as a fraction of targeted workers — `required = ceil(p ×
  workers)`. The strict lower bound enforces a majoritarian quorum. Mutually exclusive with
  `quorum_count:`. Both options raise `ArgumentError` when malformed, up front.
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

### Fixed
- `:quorum` strategy no longer silently clamps an impossible `quorum_count` to the available
  worker count — asking for 3 confirmations and "reaching quorum" with 2 would lower the
  caller's durability guarantee behind their back. An impossible quorum now returns
  `{:nebula_error, :quorum_unreachable, %{workers: n, required: m}}` before making any
  call — for a write quorum, no partial non-quorate write is even attempted.
- `:quorum` with zero available workers no longer returns `[]` (an empty-list pseudo-success);
  it returns `{:nebula_error, :quorum_unreachable, %{workers: 0, required: m}}`.
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
  deadlocks.
- An unknown method, a malformed call, or a raising body returns `{:nebula_error, ...}`
  instead of crashing the worker.
- `build_nodes_info` no longer aborts the whole snapshot when one node's health collection
  crashes (a non-timeout task exit) — the faulty node is simply dropped.
- Invalid `defapi` selectors and signatures, using `defapi` without `use NebulaAPI`, and
  malformed node tags now raise clear `CompileError`s instead of internal crashes.
- `mix docs` (and therefore `mix hex.publish`) no longer fails — the `docs` extras point at
  files that exist.

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
