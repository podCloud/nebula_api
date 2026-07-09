defmodule NebulaAPI.MixProject do
  use Mix.Project

  @version "0.7.1"
  @source_url "https://github.com/podCloud/nebula_api"

  def project do
    [
      app: :nebula_api,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "NebulaAPI",
      description:
        "Compile-time selective compilation and transparent distributed execution for Erlang/Elixir clusters",
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {NebulaAPI.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        {"docs/README.md", title: "Documentation", filename: "documentation"},
        "docs/configuration.md",
        "docs/defining.md",
        "docs/calling.md",
        "docs/gotchas.md",
        "docs/deep-dive/ast-deep-dive.md",
        {"ABOUT-LLMS.md", title: "About LLMs"}
      ],
      groups_for_extras: [
        Guides: ~r/docs\/(configuration|defining|calling|gotchas)\.md/,
        "Deep dive": ~r/docs\/deep-dive\//,
        Project: ~r/ABOUT-LLMS/
      ],
      groups_for_modules: [
        "Public API": [
          NebulaAPI,
          NebulaAPI.Server,
          NebulaAPI.APIServer,
          NebulaAPI.Routes,
          NebulaAPI.Config,
          Mix.Tasks.Nebula.Routes
        ],
        Internals: [
          NebulaAPI.AST,
          NebulaAPI.AST.Parser,
          NebulaAPI.AST.Builder,
          NebulaAPI.APIServer.Worker,
          NebulaAPI.APIServer.NodesInfoCache,
          NebulaAPI.CompilerCheck,
          Mix.Tasks.Compile.Nebula
        ]
      ]
    ]
  end

  defp aliases do
    [
      # `mix setup` also points git at the tracked hooks dir (one-time, idempotent).
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      # Run before committing (wired as the .githooks/pre-commit hook). The test step
      # runs as a distributed node — the suite needs a real node name (plain `mix test`
      # fails on routing/:pg), so it is spawned with `--name` rather than a bare `test`.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "cmd elixir --name precommit@127.0.0.1 --cookie nebula_precommit -S mix test"
      ]
    ]
  end
end
