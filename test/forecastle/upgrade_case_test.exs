defmodule Forecastle.UpgradeCaseTest do
  @moduledoc """
  The case template on its own, which is the way a downstream project takes it.

  Every other suite that uses it also uses `Forecastle.ReleaseCase`, because they
  all assemble the fixture first - so without this one the arrangement a project
  actually writes, a single `use Forecastle.UpgradeCase`, would be the one
  arrangement nothing compiled.

  What it can assert is the contract the template offers and nothing about a
  running system, which is `Forecastle.DownstreamUpgradeTest`'s.
  """

  use Forecastle.UpgradeCase

  test "aliases the module that drives a release" do
    # A missing alias would leave this comparing `Elixir.Deployment` - a
    # perfectly good atom that no module answers to - against the real one, so
    # this fails rather than failing to compile.
    assert Deployment == Forecastle.Deployment
  end

  test "gives the module a timeout a release can be booted inside", context do
    # ExUnit's default is 60 seconds, which is a description of a unit test. A
    # module here can deploy a release, boot a node and reboot it.
    assert context.timeout == 600_000
  end

  test "names a scratch directory of this module's own", %{scratch: scratch} do
    assert Path.basename(scratch) == "Forecastle.UpgradeCaseTest"
    assert Path.dirname(Path.dirname(scratch)) =~ ~r"/castle$"
  end

  test "leaves it a path rather than an empty directory", %{scratch: scratch} do
    # Cleared on the way in, and created by the first thing that deploys into
    # it, so a module using this template for the alias and the timeout - which
    # is what this one is doing - leaves nothing behind to explain.
    refute File.exists?(scratch)
  end
end
