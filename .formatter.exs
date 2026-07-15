# Used by "mix format".
#
# The export below is EVALUATED IN THE CONSUMER'S PROJECT ROOT when they use
# `import_deps: [:nebula_api]` — so besides the macros, it derives the
# consumer's own topology tags from their config and keeps THEIR selector
# chains (`&db !@backup`) paren-less too. Tag names are user-defined, so this
# is the only place they can be picked up automatically.
#
# Resilience contract: this file must NEVER break a consumer's `mix format`.
# Any failure reading the config falls back to exporting the macros alone —
# formatting then parenthesizes tag chains (`&db(!@backup)`), which is the
# same AST, just not the canonical look.

macros = [
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

# "config/config.exs" = standalone project or umbrella root;
# "../../config/config.exs" = `mix format` run from inside an umbrella app.
config_file =
  Enum.find(
    ["config/config.exs", "../../config/config.exs"],
    &File.exists?/1
  )

# Union across envs: a tag used only in test.exs (an isolated test node) must
# stay paren-less in test code too. Each read is fully contained — a config
# that raises for one env (unset env vars, etc.) contributes nothing.
read_tags = fn env ->
  try do
    (get_in(Config.Reader.read!(config_file, env: env), [:nebula_api, :nodes]) || [])
    |> Enum.flat_map(fn {_node, tags} -> List.wrap(tags) end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end

tags =
  case config_file do
    nil -> []
    _ -> [:dev, :test, :prod] |> Enum.flat_map(read_tags) |> Enum.uniq() |> Enum.sort()
  end

locals_without_parens = macros ++ Enum.map(tags, &{&1, :*})

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
