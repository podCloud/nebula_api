# Used by "mix format".
#
# The export below is STATIC on purpose: `mix format` caches resolved dep
# exports (_build/<env>/lib/<app>/.mix/cached_dot_formatter) and config
# changes never invalidate that cache, so anything dynamic here would go
# stale. `import_deps: [:nebula_api]` therefore protects the MACROS only.
# To also keep their own topology tags paren-less, consumers call the
# always-fresh helper shipped as formatter.exs (see docs/defining.md,
# "mix format and the selector syntax").

locals_without_parens = [
  defapi: 1,
  defapi: 2,
  defapi: 3,
  on_nebula_nodes: 1,
  on_nebula_nodes: 2,
  call_on_node: 1,
  call_on_node: 2,
  call_on_node: 3,
  call_on_nodes: 1,
  call_on_nodes: 2,
  call_on_nodes: 3,
  call_on_all_nodes: 1,
  call_on_all_nodes: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
