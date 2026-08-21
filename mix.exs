defmodule Forecastle.MixProject do
  use Mix.Project

  @version "0.1.3"
  @source_url "https://github.com/ausimian/forecastle"

  def project do
    [
      app: :forecastle,
      description: "Build-Time Hot-Code Upgrade support for Elixir",
      version: System.get_env("VERSION_OVERRIDE", @version),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # The sample application under test/fixtures is a project in its own
      # right, not a collection of test files. (Elixir 1.19 and later.)
      test_ignore_filters: [~r"^test/fixtures/"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :eex]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test --include e2e"
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Nick Gunn"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Castle" => "https://hex.pm/packages/castle"
      },
      files: ~w(lib priv CHANGELOG.md LICENSE mix.exs README.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: @version,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
