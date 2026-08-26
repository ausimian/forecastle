defmodule Forecastle.ReleaseCase do
  @moduledoc """
  Case template for tests that assemble the sample fixture into a real release.

  Assembling a release shells out to `mix`, so these tests are slow by unit-test
  standards and are never async.

  Driving a release once it is assembled - starting it, upgrading it, asking it
  questions - is `Forecastle.Deployment`, which a suite imports for itself.
  """

  use ExUnit.CaseTemplate

  alias Forecastle.Fixture

  using do
    quote do
      import Forecastle.ReleaseCase

      @moduletag :slow
      @moduletag timeout: 600_000
    end
  end

  setup_all do
    workspace = Fixture.workspace()

    # The workspace is memoised and shared by every suite that assembles, and a
    # relup in it is now checked against the version being assembled rather than
    # copied blindly. So one left behind by a suite whose setup failed part way
    # through would fail an unrelated suite's assembly, with a version mismatch
    # that says nothing about the real cause. Cleared here, and registered for
    # clearing before anything has had the chance to assemble.
    relup = Path.join(workspace, "relup")
    on_exit(fn -> File.rm(relup) end)
    File.rm(relup)

    # `rel/appups` is the same hazard one directory further on, and a sharper one:
    # every source in there names a transition, and `Forecastle.Appup.Dep` refuses
    # one that is not the transition being assembled. So a file left behind by a
    # suite that died half way through would fail every *other* suite's assembly,
    # with a message about a version pair that says nothing about the real cause.
    appups = Path.join(workspace, "rel/appups")
    on_exit(fn -> File.rm_rf(appups) end)
    File.rm_rf!(appups)

    # And `rel/overlays`, which Mix copies over `lib/` during `:assemble`: one
    # left behind plants files in every release another suite assembles, and
    # `Forecastle.Appup.Dep` refuses a build whose dependency appup an overlay
    # replaced - so a stray one fails suites that never heard of it.
    overlays = Path.join(workspace, "rel/overlays")
    on_exit(fn -> File.rm_rf(overlays) end)
    File.rm_rf!(overlays)

    {:ok, workspace: workspace}
  end

  @doc """
  Assembles the fixture release and returns the path it was assembled into.

  Options:

    * `:into` - directory to assemble into, relative to the workspace
    * `:vsn`  - fixture version to build, defaults to `"0.1.0"`
    * `:env`  - extra environment for the build
  """
  def assemble!(opts \\ []) do
    workspace = Fixture.workspace()
    vsn = Keyword.get(opts, :vsn, "0.1.0")
    into = Path.join(workspace, Keyword.get(opts, :into, "rel"))

    env =
      [
        {"SAMPLE_VSN", vsn},
        # A build root per version, so that the fixture's compile-time version
        # tag is genuinely recompiled rather than served from a stale artefact.
        {"MIX_BUILD_ROOT", Path.join(workspace, "_build-#{vsn}")}
      ] ++ Keyword.get(opts, :env, [])

    # --overwrite lets Mix write into a non-empty directory but does not clear
    # it, so anything a previous run left behind - RELEASES, unpacked releases,
    # staged tarballs - would still be there. Start from nothing.
    File.rm_rf!(into)

    mix!(["release", "sample", "--overwrite", "--path", into], env)
    into
  end

  defdelegate mix(args, env \\ []), to: Fixture
  defdelegate mix!(args, env \\ []), to: Fixture
  defdelegate cmd!(exe, args, env \\ [], opts \\ []), to: Fixture
  defdelegate cmd(exe, args, env \\ [], opts \\ []), to: Fixture
end
