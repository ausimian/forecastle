defmodule SampleB.MixProject do
  use Mix.Project

  # One of three applications only a release built with `SAMPLE_ADDED_APPS=true`
  # carries, so that a relup from a release without them adds all three. This one
  # is what the other two depend on, and its name sorts between theirs: Mix
  # writes the `.rel` alphabetically past the project, so `:sample_a` comes
  # before it and `:sample_c` after it, and `:systools` emits the starts and
  # stops in that order. See `Forecastle.AddedAppsUpgradeTest`.
  def project do
    [app: :sample_b, version: "0.1.0", elixir: "~> 1.18"]
  end

  def application do
    [extra_applications: [], mod: {SampleB, []}]
  end
end
