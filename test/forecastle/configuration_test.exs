defmodule Forecastle.ConfigurationTest do
  @moduledoc """
  Assembles the fixture as a project that configures itself in the two ways
  Forecastle used to get wrong, and asserts that what Mix does with them reaches
  the release untouched.

  Both of these used to be defects in Forecastle's parallel implementation of
  Mix's config-provider semantics - `:runtime_config_path` read as a boolean
  while the substitute provider was hardcoded to `config/runtime.exs`, and
  provider init arguments rewritten into a keyword list with an `:env` key
  added. Neither is repaired here. The implementation that got them wrong is
  gone, so there is nothing left to disagree with Mix.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @vsn "0.1.0"

  setup_all do
    release = assemble!(into: "rel-config", env: [{"SAMPLE_CONFIG", "custom"}])

    {:ok, [release: release] ++ sys_config(release)}
  end

  describe ":runtime_config_path" do
    test "is the file the release carries, with config/runtime.exs beside it",
         %{release: release} do
      # The fixture has both files. Mix copies the one the release named into the
      # version directory and points the Config.Reader it installs at that copy.
      assert File.read!(Path.join(release, "releases/#{@vsn}/runtime.exs")) ==
               File.read!(Path.join(Fixture.workspace(), "config/prod_runtime.exs"))
    end

    test "is the file the release evaluates", %{release: release} do
      # A release, booted, saying which file configured it. The other file sets
      # this key too, and to something else, so there is no way to pass this by
      # reading the wrong one.
      assert eval!(release, "IO.puts(Sample.greeting())") == "from-prod-runtime"
      assert eval!(release, "IO.puts(Sample.env_marker())") == "prod-runtime"
    end
  end

  describe "config providers" do
    # Mix.Release allows any term as a provider's init argument, and hands it to
    # `init/1` as it stands. The fixture's provider returns whatever it is given,
    # so the terms below are what init/1 saw.

    test "declared with a binary reach init/1 unchanged", %{providers: providers} do
      assert {Sample.EchoProvider, "a binary"} in providers
    end

    test "declared with a map reach init/1 unchanged", %{providers: providers} do
      assert {Sample.EchoProvider, %{a: :map}} in providers
    end

    test "declared with a list that is not a keyword list reach init/1 unchanged",
         %{providers: providers} do
      assert {Sample.EchoProvider, [:not, :a, :keyword, :list]} in providers
    end

    test "are Mix's own list, in Mix's own order", %{providers: providers} do
      # Mix puts the runtime configuration reader in front of the project's own
      # providers, and Forecastle no longer has a list of its own to append to.
      assert [{Config.Reader, _reader} | declared] = providers

      assert declared == [
               {Sample.EchoProvider, "a binary"},
               {Sample.EchoProvider, %{a: :map}},
               {Sample.EchoProvider, [:not, :a, :keyword, :list]}
             ]
    end

    test "are still run at boot", %{release: release} do
      # The providers above are reached through the same pipeline as the reader,
      # so a release that could not run them would not be configured at all.
      assert eval!(release, "IO.puts(Sample.greeting())") == "from-prod-runtime"
    end
  end

  defp sys_config(release) do
    {:ok, [terms]} = :file.consult(to_charlist(Path.join(release, "releases/#{@vsn}/sys.config")))
    %Config.Provider{providers: providers} = terms[:elixir][:config_provider_init]

    [sys_config: terms, providers: providers]
  end

  defp eval!(release, expression) do
    release |> Path.join("bin/sample") |> cmd!(["eval", expression]) |> String.trim()
  end
end
