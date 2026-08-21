defmodule Sample.MixProject do
  use Mix.Project

  @forecastle Path.expand("../../..", __DIR__)

  def project do
    [
      app: :sample,
      version: System.get_env("SAMPLE_VSN", "0.1.0"),
      elixir: "~> 1.18",
      appup: appup(),
      compilers: Mix.compilers() ++ [:appup],
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sample.Application, []}
    ]
  end

  defp deps do
    [
      # TEMPORARY for the 1.0.0 cycle: the fixture needs Castle's in-progress API.
      # Flip back to {:castle, "~> 1.0"} before publishing.
      {:castle, github: "ausimian/castle", branch: "release/1.0.0"},
      {:forecastle, path: System.get_env("FORECASTLE_PATH", @forecastle), override: true}
    ]
  end

  defp releases do
    [
      sample: [
        include_executables_for: executables(),
        steps: steps()
      ]
    ]
  end

  # Switched by the test suite so that the fixture can be built as a project
  # that does not ask for an appup at all. "none" rather than an empty value,
  # which `System.cmd/3` cannot pass: it unsets the variable instead. `nil` is
  # as close as this can get to dropping the key, and it is close enough - the
  # compiler reads it through `Mix.Project.config()[:appup]`, which cannot tell
  # the two apart.
  defp appup do
    case System.get_env("SAMPLE_APPUP", "appup.exs") do
      "none" -> nil
      path -> path
    end
  end

  # Switched by the test suite so that the warning about unsupported Windows
  # executables can be provoked.
  defp executables do
    case System.get_env("SAMPLE_EXECUTABLES") do
      "unix,windows" -> [:unix, :windows]
      "windows" -> [:windows]
      _ -> [:unix]
    end
  end

  # Switched by the test suite so that the same fixture can be assembled both
  # with and without Forecastle, and the two launchers compared.
  defp steps do
    if System.get_env("SAMPLE_STEPS") == "mix" do
      [:assemble, :tar]
    else
      [&Forecastle.pre_assemble/1, :assemble, &Forecastle.post_assemble/1, :tar]
    end
  end
end
