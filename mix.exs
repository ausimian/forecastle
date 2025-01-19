defmodule Forecastle.MixProject do
  use Mix.Project

  def project do
    [
      app: :forecastle,
      version: "0.1.3",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/ausimian/forecastle",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :eex]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.27", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "Build-Time Hot-Code Upgrade support for Elixir",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ausimian/castle",
        "Castle" => "https://hex.pm/packages/castle"
      }
    ]
  end
end
