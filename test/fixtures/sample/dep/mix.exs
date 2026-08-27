defmodule SampleDep.MixProject do
  use Mix.Project

  @forecastle Path.expand("../../../..", __DIR__)

  # An application whose version moves in step with the sample application's,
  # and whose appup deliberately asks for nothing.
  #
  # It exists to be the application a relup does not mention. `systools` needs
  # an appup for every application whose version changed, so there has to be
  # one, but its instruction lists are empty - which means the relup carries no
  # `load_object_code` for this application, and `release_handler` only learns
  # that its version changed at all from the release records in RELEASES. A
  # system running on the record OTP synthesises when that file is missing sees
  # no change here, and leaves its code path pointing into the superseded
  # release.
  def project do
    [
      app: :sample_dep,
      version: version(),
      elixir: "~> 1.18",
      appup: appup(),
      compilers: Mix.compilers() ++ [:appup],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
  end

  # Switched by the test suite so that the fixture can present the state the
  # project-supplied appups exist for: a dependency that ships none of its own,
  # which is what a dependency taken from Hex almost always is. Unset, it ships
  # the file beside this one, as it always did.
  #
  # "none" rather than an empty value, for the reason the sample's own
  # `SAMPLE_APPUP` gives: `System.cmd/3` cannot pass an empty one.
  defp appup do
    case System.get_env("SAMPLE_DEP_APPUP", "appup.exs") do
      "none" -> nil
      path -> path
    end
  end

  @doc """
  This application's version, which `appup.exs` needs too.

  `SAMPLE_DEP_VSN` pins it independently of the sample's, so that the fixture
  can be assembled as a transition in which *only* project-owned applications
  changed. `mix castle.relup`'s `auto` strategy makes a transition a restart
  when the version of an application the project does not own moved, and this
  application - a dependency of the sample - otherwise always moves with it.
  Unset, which is how every other suite builds the fixture, it moves in step as
  it always did.
  """
  def version, do: System.get_env("SAMPLE_DEP_VSN") || System.get_env("SAMPLE_VSN", "0.1.0")

  defp deps do
    # Build-time only, for the `:appup` compiler above. See the sample's own
    # `mix.exs` for why the shape matters.
    [{:forecastle, path: System.get_env("FORECASTLE_PATH", @forecastle), runtime: false}]
  end
end
