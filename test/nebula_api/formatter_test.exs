# formatter.exs is not part of lib/ -- it ships standalone, next to mix.exs,
# and is loaded by a CONSUMER's own .formatter.exs via Code.require_file (see
# the header comment in formatter.exs for why). Load it the same way here.
Code.require_file("../../formatter.exs", __DIR__)

defmodule NebulaAPI.FormatterTest do
  # NebulaAPI.Formatter.config_files/0 reads relative to File.cwd!/0, which is
  # a single, VM-wide value in the BEAM (not per-process) -- every test here
  # changes it for the duration of a call. async: false makes ExUnit defer
  # this whole module until no async: true test is running concurrently.
  use ExUnit.Case, async: false

  alias NebulaAPI.Formatter

  # Builds a throwaway project directory from `{relative_path, content}` pairs,
  # changes the VM's cwd into it for the duration of `fun`, then restores the
  # original cwd and removes the directory -- even if `fun` raises.
  defp in_project(files, fun) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "nebula_formatter_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    # System.unique_integer/1 restarts from 1 on every fresh BEAM boot, so a
    # prior run force-killed mid-test (a stale directory its own `after`
    # never got to remove) could otherwise leave files behind for a later
    # run's colliding counter value to silently pick up.
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    Enum.each(files, fn {rel_path, content} ->
      full = Path.join(tmp, rel_path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    original_cwd = File.cwd!()
    File.cd!(tmp)

    try do
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(tmp)
    end
  end

  defp tags_of(locals_without_parens) do
    locals_without_parens
    |> Enum.reject(&(&1 in Formatter.macros()))
    |> Enum.map(&elem(&1, 0))
  end

  describe "no config/ directory at all" do
    test "degrades gracefully to the macro list, no tags" do
      in_project([], fn ->
        assert Formatter.locals_without_parens() == Formatter.macros()
      end)
    end
  end

  describe "a single config/config.exs, no per-env files" do
    test "derives tags from :nebula_api, :nodes, wrapping a bare atom tag" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["db@host": [:db, :postgres], "web@host": :web]
           """}
        ],
        fn ->
          assert tags_of(Formatter.locals_without_parens()) == [:db, :postgres, :web]
        end
      )
    end
  end

  describe "env auto-discovery" do
    test "unions tags across the base config and every discovered *.exs env file" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["root@host": [:root_tag]]
           import_config("\#{config_env()}.exs")
           """},
          {"config/dev.exs",
           """
           import Config
           config :nebula_api, nodes: ["dev@host": [:dev_tag]]
           """},
          {"config/test.exs",
           """
           import Config
           config :nebula_api, nodes: ["test@host": [:test_tag]]
           """}
        ],
        fn ->
          assert tags_of(Formatter.locals_without_parens()) == [:dev_tag, :root_tag, :test_tag]
        end
      )
    end

    test "a tag used only in one env's file stays paren-less (not just the env mix format runs under)" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           import_config("\#{config_env()}.exs")
           """},
          {"config/dev.exs",
           """
           import Config
           config :nebula_api, nodes: ["dev@host": [:only_in_dev]]
           """},
          {"config/staging.exs",
           """
           import Config
           config :nebula_api, nodes: ["staging@host": [:only_in_staging]]
           """}
        ],
        fn ->
          # Both env files carry a tag found in NEITHER of the others -- a
          # regression that only reads the first discovered *.exs (whichever
          # that is; File.ls order isn't guaranteed) drops exactly one of
          # these two, so the exact-set assertion catches it regardless of
          # discovery order. A membership check on a single tag would not:
          # it stayed green under that exact mutation during review.
          assert tags_of(Formatter.locals_without_parens()) == [:only_in_dev, :only_in_staging]
        end
      )
    end
  end

  describe "umbrella root + local config merge" do
    test "unions tags from an app's local config and the umbrella root's" do
      in_project(
        [
          {"mix.exs", "# umbrella root marker\n"},
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["root@host": [:root_wide_tag]]
           """},
          {"apps/myapp/mix.exs", "# app marker\n"},
          {"apps/myapp/config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["local@host": [:local_only_tag]]
           """}
        ],
        fn ->
          File.cd!("apps/myapp", fn ->
            tags = tags_of(Formatter.locals_without_parens())
            assert :root_wide_tag in tags
            assert :local_only_tag in tags
          end)
        end
      )
    end
  end

  describe "umbrella detection honors a custom apps_path" do
    test "merges the root config even when the umbrella's apps directory isn't named \"apps\"" do
      in_project(
        [
          {"mix.exs", "  apps_path: \"packages\",\n"},
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["root@host": [:root_wide_tag]]
           """},
          {"packages/myapp/mix.exs", "# app marker\n"},
          {"packages/myapp/config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["local@host": [:local_only_tag]]
           """}
        ],
        fn ->
          File.cd!("packages/myapp", fn ->
            tags = tags_of(Formatter.locals_without_parens())
            assert :root_wide_tag in tags
            assert :local_only_tag in tags
          end)
        end
      )
    end
  end

  describe "formatter_envs conflict resolution is deterministic" do
    test "the alphabetically-first candidate env's override wins, not whichever the filesystem lists first" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           import_config("\#{config_env()}.exs")
           """},
          # Written zzz before aaa on purpose: File.ls/1 is not guaranteed to
          # return sorted entries (commonly creation/inode order), so writing
          # in reverse-alphabetical order is what would have exposed the
          # pre-fix nondeterminism on a filesystem that preserves creation
          # order.
          {"config/zzz.exs",
           """
           import Config
           config :nebula_api, formatter_envs: [:zzz]
           config :nebula_api, nodes: ["z@host": [:tag_z]]
           """},
          {"config/aaa.exs",
           """
           import Config
           config :nebula_api, formatter_envs: [:aaa]
           config :nebula_api, nodes: ["a@host": [:tag_a]]
           """}
        ],
        fn ->
          assert tags_of(Formatter.locals_without_parens()) == [:tag_a]
        end
      )
    end
  end

  describe "malformed config raises a loud, actionable error" do
    test "a non-list :nodes value" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: :not_a_list
           """}
        ],
        fn ->
          assert_raise ArgumentError, ~r/invalid `config :nebula_api, :nodes`/, fn ->
            Formatter.locals_without_parens()
          end
        end
      )
    end

    test "a node entry whose tags are neither a list nor an atom" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["bad@host": 123]
           """}
        ],
        fn ->
          assert_raise ArgumentError, ~r/invalid `config :nebula_api, :nodes`/, fn ->
            Formatter.locals_without_parens()
          end
        end
      )
    end

    test "a node's tag list containing a non-atom element" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, nodes: ["bad@host": ["not_an_atom", :real_tag]]
           """}
        ],
        fn ->
          assert_raise ArgumentError, ~r/invalid `config :nebula_api, :nodes`/, fn ->
            Formatter.locals_without_parens()
          end
        end
      )
    end

    test "a non-list :formatter_envs override" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, formatter_envs: :not_a_list
           """}
        ],
        fn ->
          assert_raise ArgumentError, ~r/invalid `config :nebula_api, :formatter_envs`/, fn ->
            Formatter.locals_without_parens()
          end
        end
      )
    end
  end

  describe "an env whose config genuinely cannot be read" do
    test "crashes loudly, naming the offending env and the formatter_envs escape hatch" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           if config_env() == :staging, do: System.fetch_env!("NEBULA_FORMATTER_TEST_UNSET")
           config :nebula_api, nodes: ["root@host": [:root_tag]]
           import_config("\#{config_env()}.exs")
           """},
          {"config/dev.exs",
           """
           import Config
           config :nebula_api, nodes: ["dev@host": [:dev_tag]]
           """},
          {"config/staging.exs",
           """
           import Config
           """}
        ],
        fn ->
          assert_raise ArgumentError, ~r/under env :staging raised/, fn ->
            Formatter.locals_without_parens()
          end
        end
      )
    end

    test "formatter_envs lets the working envs be read while excluding the broken one" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           config :nebula_api, formatter_envs: [:dev]
           if config_env() == :staging, do: System.fetch_env!("NEBULA_FORMATTER_TEST_UNSET")
           config :nebula_api, nodes: ["root@host": [:root_tag]]
           import_config("\#{config_env()}.exs")
           """},
          {"config/dev.exs",
           """
           import Config
           config :nebula_api, nodes: ["dev@host": [:dev_tag]]
           """},
          {"config/staging.exs",
           """
           import Config
           """}
        ],
        fn ->
          assert tags_of(Formatter.locals_without_parens()) == [:dev_tag, :root_tag]
        end
      )
    end
  end

  describe "memoization" do
    test "each (file, env) pair is read exactly once per call" do
      in_project(
        [
          {"config/config.exs",
           """
           import Config
           send(Process.get(:nebula_formatter_test_pid) || self(), {:nebula_formatter_read, config_env()})
           config :nebula_api, nodes: []
           import_config("\#{config_env()}.exs")
           """},
          {"config/dev.exs", "import Config\n"},
          {"config/test.exs", "import Config\n"}
        ],
        fn ->
          Formatter.locals_without_parens()

          reads =
            Stream.repeatedly(fn ->
              receive do
                {:nebula_formatter_read, env} -> env
              after
                0 -> nil
              end
            end)
            |> Enum.take_while(&(&1 != nil))

          assert Enum.sort(reads) == [:dev, :test]
        end
      )
    end
  end
end
