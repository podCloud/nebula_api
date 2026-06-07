# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `nebula_api_server/0` macro: wire it into an OTP application's supervision tree to
  start a per-app `NebulaAPI.Server`. The server discovers that app's modules using
  `NebulaAPI` and supervises one worker per locally-served module.

### Changed
- **Breaking:** removed the `registered_modules` config option. Module workers are now
  discovered per app at runtime (via `nebula_api_server/0`) instead of being listed in
  config. Migration: drop `registered_modules` and add `nebula_api_server()` to each
  consuming app's supervisor children.
- Workers now live in the supervision tree of the app that owns their module, so they
  share the app's lifecycle — when the app stops or crashes, its workers go down and
  `:pg` drops them (no more stale routing entries). The central `APIServer` is reduced
  to the `:pg` scope, the node-health ETS cache, and routing.

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
