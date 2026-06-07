# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
