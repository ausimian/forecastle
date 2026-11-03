defmodule SampleD.MixProject do
  use Mix.Project

  # An application with no modules, added and removed with the other three. Its
  # `.app` lists `modules: []`, so `:systools` makes no `load_object_code` for it,
  # and `load_object_code` is the only way `release_handler` learns that a hot
  # upgrade adds a library whose path has to be set at `point_of_no_return`.
  # Without a path its `.app` cannot be found and `application:start/2` fails -
  # an error `release_handler` ignores. See `Forecastle.AddedAppsUpgradeTest`.
  def project do
    [app: :sample_d, version: "0.1.0", elixir: "~> 1.18"]
  end

  def application do
    [extra_applications: []]
  end
end
