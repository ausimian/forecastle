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
      appup: "appup.exs",
      compilers: Mix.compilers() ++ [:appup],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
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
    [{:forecastle, path: System.get_env("FORECASTLE_PATH", @forecastle)}]
  end
end
