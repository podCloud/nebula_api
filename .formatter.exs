# Used by "mix format"
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
  # Consumers pick this up with `import_deps: [:nebula_api]` — see
  # docs/defining.md ("mix format and the selector syntax") for the full
  # recipe, including deriving tag names from the topology config.
  export: [locals_without_parens: locals_without_parens]
]
