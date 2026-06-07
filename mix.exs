defmodule NebulaAPI.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/podCloud/NebulaAPI"

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
      description: "Compile-time selective compilation and transparent distributed execution for Erlang/Elixir clusters",
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
      extras: [
        "README.md",
        "docs/concepts.md",
        "docs/configuration.md",
        "docs/macros-reference.md",
        "docs/examples.md",
        "docs/api-server.md",
        "docs/ast-deep-dive.md",
        "docs/troubleshooting.md",
        "docs/guides/adding-nebula-api.md"
      ],
      groups_for_extras: [
        Guides: ~r/docs\/guides\//,
        Reference: ~r/docs\//
      ]
    ]
  end

  defp aliases do
    [setup: ["deps.get"]]
  end
end
