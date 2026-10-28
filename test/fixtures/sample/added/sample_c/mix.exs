defmodule SampleC.MixProject do
  use Mix.Project

  # Depends on `:sample_b`; see its `mix.exs`.
  def project do
    [
      app: :sample_c,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:sample_b, path: "../sample_b"}]
    ]
  end

  def application do
    [extra_applications: [], mod: {SampleC, []}]
  end
end
