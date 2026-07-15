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
# When BOTH exist (an app with its own local config inside an umbrella), both
# are read and their tags merged.
config_files =
  Enum.filter(
    ["config/config.exs", "../../config/config.exs"],
    &File.exists?/1
  )

# Every read is fully contained — a config that raises for one env (unset env
# vars, etc.) contributes nothing.
read_config = fn file, env ->
  try do
    Config.Reader.read!(file, env: env)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end

# Which envs to read the topology under. Default: the standard three plus one
# per config/<env>.exs file found (a config/staging.exs is picked up by
# itself). Escape hatch for exotic setups, in the BASE config.exs (before any
# import_config, so it is readable under any env):
#
#     config :nebula_api, formatter_envs: [:dev, :test, :prod, :edge]
#
scanned_envs = fn file ->
  case File.ls(Path.dirname(file)) do
    {:ok, files} ->
      for f <- files,
          Path.extname(f) == ".exs",
          f not in ["config.exs", "runtime.exs"],
          do: f |> Path.rootname() |> String.to_atom()

    _ ->
      []
  end
end

envs_for = fn file ->
  default_envs = Enum.uniq([:dev, :test, :prod] ++ scanned_envs.(file))

  configured_envs =
    Enum.find_value(default_envs, fn env ->
      get_in(read_config.(file, env), [:nebula_api, :formatter_envs])
    end)

  configured_envs || default_envs
end

# Union across files AND envs: a tag used only in the umbrella root config, or
# only in test.exs (an isolated test node), must stay paren-less everywhere.
tags =
  config_files
  |> Enum.flat_map(fn file ->
    Enum.flat_map(envs_for.(file), fn env ->
      (get_in(read_config.(file, env), [:nebula_api, :nodes]) || [])
      |> Enum.flat_map(fn {_node, tags} -> List.wrap(tags) end)
    end)
  end)
  |> Enum.uniq()
  |> Enum.sort()

locals_without_parens = macros ++ Enum.map(tags, &{&1, :*})

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
