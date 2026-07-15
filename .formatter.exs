# Used by "mix format".
#
# The export below is EVALUATED IN THE CONSUMER'S PROJECT ROOT when they use
# `import_deps: [:nebula_api]` — so besides the macros, it derives the
# consumer's own topology tags from their config and keeps THEIR selector
# chains (`&db !@backup`) paren-less too. Tag names are user-defined, so this
# is the only place they can be picked up automatically.
#
# Error contract:
# - an env whose config cannot be READ (a prod.exs demanding an unset env
#   var) is skipped: it contributes no tags, nothing breaks;
# - a config that reads fine but carries a MALFORMED :nebula_api value raises
#   a clear error here, on purpose — the same shape would fail the consumer's
#   own compile, and a silent fallback would just move the surprise to
#   formatting output.

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

# "config/config.exs" = standalone project or umbrella root. The ../../ form
# is used ONLY when the cwd genuinely looks like an umbrella app (a sibling of
# other apps under <root>/apps, with a mix.exs at the root) — without the
# guard, running mix format two levels under any unrelated directory that
# happens to carry a config/ would silently read a foreign project's config.
# When an umbrella app has a local config on top of the root one, both are
# read and their tags merged.
in_umbrella_app? =
  Path.basename(Path.dirname(File.cwd!())) == "apps" and File.exists?("../../mix.exs")

config_files =
  Enum.filter(
    ["config/config.exs"] ++ if(in_umbrella_app?, do: ["../../config/config.exs"], else: []),
    &File.exists?/1
  )

# A read failure (raise/throw/exit inside the consumer's config) skips that
# env: :unreadable, never an error.
read_config = fn file, env ->
  try do
    Config.Reader.read!(file, env: env)
  rescue
    _ -> :unreadable
  catch
    _, _ -> :unreadable
  end
end

bad_config! = fn file, key, value, expected ->
  raise ArgumentError, """
  nebula_api formatter import: invalid `config :nebula_api, #{inspect(key)}` in #{file}.

  Got: #{inspect(value)}

  Expected #{expected}.

  The `import_deps: [:nebula_api]` line in your .formatter.exs derives your
  topology tags from this config so `mix format` keeps your selector chains
  paren-less. This same shape would also fail when compiling your defapi
  modules — fix it there once.
  """
end

tags_in = fn config, file ->
  case get_in(config, [:nebula_api, :nodes]) do
    nil ->
      []

    nodes when is_list(nodes) ->
      Enum.flat_map(nodes, fn
        {_node, tags} when is_list(tags) or is_atom(tags) ->
          List.wrap(tags)

        bad ->
          bad_config!.(
            file,
            :nodes,
            bad,
            "each entry to be `{node_name, tag | [tags]}`, e.g. `\"db@host\": [:db]`"
          )
      end)

    bad ->
      bad_config!.(file, :nodes, bad, "a keyword list of `{node_name, tags}` entries")
  end
end

# Which envs to read the topology under: the standard three plus one per
# config/<env>.exs file found (a config/staging.exs is picked up by itself).
# Escape hatch for exotic setups, in the BASE config.exs (before any
# import_config, so it is readable under any env):
#
#     config :nebula_api, formatter_envs: [:dev, :test, :prod, :edge]
#
tags_for_file = fn file ->
  scanned_envs =
    case File.ls(Path.dirname(file)) do
      {:ok, files} ->
        for f <- files,
            Path.extname(f) == ".exs",
            f not in ["config.exs", "runtime.exs"],
            do: f |> Path.rootname() |> String.to_atom()

      _ ->
        []
    end

  default_envs = Enum.uniq([:dev, :test, :prod] ++ scanned_envs)

  # Each (file, env) pair is read EXACTLY ONCE (a consumer's config runs
  # arbitrary code — evaluating it twice per env per mix format would double
  # real work and side effects).
  reads = Map.new(default_envs, fn env -> {env, read_config.(file, env)} end)

  configured_envs =
    Enum.find_value(default_envs, fn env ->
      case reads[env] do
        :unreadable -> nil
        config -> get_in(config, [:nebula_api, :formatter_envs])
      end
    end)

  envs =
    case configured_envs do
      nil ->
        default_envs

      list when is_list(list) ->
        list

      bad ->
        bad_config!.(file, :formatter_envs, bad, "a list of env atoms, e.g. `[:dev, :test]`")
    end

  reads =
    Enum.reduce(envs, reads, fn env, acc ->
      Map.put_new_lazy(acc, env, fn -> read_config.(file, env) end)
    end)

  Enum.flat_map(envs, fn env ->
    case reads[env] do
      :unreadable -> []
      config -> tags_in.(config, file)
    end
  end)
end

# Union across files AND envs: a tag used only in the umbrella root config, or
# only in test.exs (an isolated test node), must stay paren-less everywhere.
tags =
  config_files
  |> Enum.flat_map(tags_for_file)
  |> Enum.uniq()
  |> Enum.sort()

locals_without_parens = macros ++ Enum.map(tags, &{&1, :*})

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
