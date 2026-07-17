# NebulaAPI formatter helper — ships in the Hex package, next to mix.exs.
#
# Loaded from a CONSUMER's .formatter.exs (never compiled into the library — it
# is a NEW module, deliberately not `NebulaAPI` itself: mix format runs before
# any compile, so the real NebulaAPI is not loaded at that point, but reopening
# a public module from a bare script is one accident away from clobbering it —
# redefining a module DROPS anything not redefined, macros included):
#
#     Code.require_file("formatter.exs", to_string(Mix.Project.deps_paths()[:nebula_api]))
#
#     [
#       inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
#     ]
#     |> NebulaAPI.Formatter.add_formatter_config()
#
# Why this shape and not `import_deps: [:nebula_api]`: `mix format` CACHES the
# resolved dep exports (_build/<env>/lib/<app>/.mix/cached_dot_formatter) and
# nothing about a config change invalidates that cache — a dynamic export would
# serve STALE tags forever. The consumer's own .formatter.exs, however, is
# evaluated on every run: code called from there stays fresh. So the static
# macro list is exported for import_deps users (macros never change between
# releases), and the tag derivation lives here, on the always-fresh path.
#
# What add_formatter_config/1 returns: your keyword list, with
# `locals_without_parens` covering the NebulaAPI macros AND your own topology
# tags, derived from your config so `mix format` keeps selector chains like
# `defapi &db !@backup, get(id)` paren-less. Add a tag to the topology and the
# very next `mix format` knows it.
#
# Error contract: a config problem CRASHES mix format with an error that says
# what to fix — a malformed :nebula_api value, or an env whose config raises
# at read time (exclude such an env with `config :nebula_api, formatter_envs:`
# in the base config.exs). Silent degradation would only move the surprise to
# the formatting output.

defmodule NebulaAPI.Formatter do
  @moduledoc false

  @macros [
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

  @doc """
  Pipe your `.formatter.exs` keyword list through this: it adds
  `locals_without_parens` covering the NebulaAPI macros and your topology
  tags. Your own `locals_without_parens` entries, if any, are appended.
  """
  def add_formatter_config(config \\ []) do
    {extra, rest} = Keyword.pop(config, :locals_without_parens, [])
    Keyword.put(rest, :locals_without_parens, locals_without_parens() ++ extra)
  end

  @doc """
  Just the `locals_without_parens` list (macros + derived tags), for manual
  composition.
  """
  def locals_without_parens do
    @macros ++ Enum.map(tags(), &{&1, :*})
  end

  # ---------------------------------------------------------------------------

  # "config/config.exs" = standalone project or umbrella root. The ../../ form
  # is used ONLY when the cwd genuinely looks like an umbrella app (a sibling
  # of other apps under <root>/apps, with a mix.exs at the root) — without the
  # guard, running mix format two levels under any unrelated directory that
  # happens to carry a config/ would silently read a foreign project's config.
  # When an umbrella app has a local config on top of the root one, both are
  # read and their tags merged.
  defp config_files do
    in_umbrella_app? =
      Path.basename(Path.dirname(File.cwd!())) == "apps" and File.exists?("../../mix.exs")

    Enum.filter(
      ["config/config.exs"] ++ if(in_umbrella_app?, do: ["../../config/config.exs"], else: []),
      &File.exists?/1
    )
  end

  # Union across files AND envs: a tag used only in the umbrella root config,
  # or only in test.exs (an isolated test node), must stay paren-less
  # everywhere.
  defp tags do
    config_files()
    |> Enum.flat_map(&tags_for_file/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Which envs to read the topology under: one per *.exs file found next to the
  # base file, MINUS config.exs and runtime.exs — dev.exs, test.exs, staging.exs,
  # ... whatever the project actually has. Auto-discovery is a directory
  # listing, not a Config.Reader-aware scan: ANY other .exs file sitting in
  # config/ (a secrets.exs conditionally imported by hand, a docker.exs, a
  # one-off override that isn't a real "env") is picked up and probed the same
  # way. Usually harmless — read_quietly/2 swallows a bad read — but a candidate
  # whose read has a SIDE EFFECT (rare, but Config.Reader runs arbitrary code)
  # still runs it. A single read when there are no *.exs files at all
  # (Config.Reader needs SOME env to evaluate config_env() against; :dev).
  #
  # To bypass auto-discovery entirely, define the exact env list yourself in
  # the BASE config.exs (before any import_config, so it is discoverable under
  # any env) — this REPLACES the directory scan, so leave out anything you
  # don't want read (weird one-off files included):
  #
  #     config :nebula_api, formatter_envs: [:dev, :test, :edge]
  #
  defp tags_for_file(file) do
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

    candidate_envs = if scanned_envs == [], do: [:dev], else: scanned_envs

    # Quiet probe: find the override without letting one broken env hide it
    # (otherwise the escape hatch could never take effect). These probe reads
    # double as the memoized first read of each env — every (file, env) pair
    # is read once per mix format run on the happy path (a consumer's config
    # runs arbitrary code).
    probes = Map.new(candidate_envs, fn env -> {env, read_quietly(file, env)} end)

    configured_envs =
      Enum.find_value(candidate_envs, fn env ->
        case probes[env] do
          :unreadable -> nil
          config -> get_in(config, [:nebula_api, :formatter_envs])
        end
      end)

    envs =
      case configured_envs do
        nil ->
          candidate_envs

        list when is_list(list) ->
          list

        bad ->
          bad_config!(file, :formatter_envs, bad, "a list of env atoms, e.g. `[:dev, :test]`")
      end

    # Loud phase, on the SELECTED envs only: reuse the probe when it
    # succeeded, read loudly (crash with the way out) when it didn't or
    # wasn't probed.
    Enum.flat_map(envs, fn env ->
      config =
        case probes[env] do
          nil -> read_config!(file, env)
          :unreadable -> read_config!(file, env)
          config -> config
        end

      tags_in(config, file)
    end)
  end

  defp tags_in(config, file) do
    case get_in(config, [:nebula_api, :nodes]) do
      nil ->
        []

      nodes when is_list(nodes) ->
        Enum.flat_map(nodes, fn
          {_node, tags} when is_list(tags) or is_atom(tags) ->
            List.wrap(tags)

          bad ->
            bad_config!(
              file,
              :nodes,
              bad,
              "each entry to be `{node_name, tag | [tags]}`, e.g. `\"db@host\": [:db]`"
            )
        end)

      bad ->
        bad_config!(file, :nodes, bad, "a keyword list of `{node_name, tags}` entries")
    end
  end

  # Contained read — used ONLY to discover the formatter_envs override.
  defp read_quietly(file, env) do
    Config.Reader.read!(file, env: env)
  rescue
    _ -> :unreadable
  catch
    _, _ -> :unreadable
  end

  # Loud read — used for the envs actually selected: a config that cannot be
  # read is a real problem the user can act on, so crash with the way out.
  defp read_config!(file, env) do
    Config.Reader.read!(file, env: env)
  rescue
    e ->
      reraise(
        ArgumentError.exception("""
        NebulaAPI.Formatter: reading #{file} under env #{inspect(env)} raised:

        #{Exception.format(:error, e)}

        Your .formatter.exs calls NebulaAPI.Formatter.add_formatter_config/1, which
        reads your config to derive your topology tags. If this env's config genuinely
        cannot be evaluated at format time (e.g. it demands env vars only set in
        deployment), you can disable auto-discovery of env files and set a custom
        list instead, excluding the weird/touchy one, in the BASE config.exs:

            config :nebula_api, formatter_envs: [:dev, :test]
        """),
        __STACKTRACE__
      )
  end

  defp bad_config!(file, key, value, expected) do
    raise ArgumentError, """
    NebulaAPI.Formatter: invalid `config :nebula_api, #{inspect(key)}` in #{file}.

    Got: #{inspect(value)}

    Expected #{expected}.

    Your .formatter.exs calls NebulaAPI.Formatter.add_formatter_config/1, which
    reads your config to derive your topology tags. If this env's config genuinely
    cannot be evaluated at format time (e.g. it demands env vars only set in
    deployment), you can disable auto-discovery of env files and set a custom
    list instead, excluding the weird/touchy one, in the BASE config.exs:

        config :nebula_api, formatter_envs: [:dev, :test]
    """
  end
end
