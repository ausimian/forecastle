defmodule Forecastle.ReleaseCase do
  @moduledoc """
  Case template for tests that assemble the sample fixture into a real release.

  Assembling a release shells out to `mix`, so these tests are slow by unit-test
  standards and are never async.

  Driving a release once it is assembled - starting it, upgrading it, asking it
  questions - is `Forecastle.Deployment`, which ships. This is the fixture's half
  of the arrangement and nothing more: everything here knows the sample by name -
  `bin/sample`, `SAMPLE_VSN`, the workspace it is built in - which is exactly why
  none of it is in `lib`.

  A suite that upgrades a release adds `use Forecastle.UpgradeCase` beside this
  one. The two compose: this one assembles, that one deploys and drives.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Forecastle.Deployment
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

  @doc """
  A `Forecastle.Deployment` over an assembled fixture release.

  `cd:` is the workspace rather than the release root, and that is load bearing
  in two places: `Forecastle.UpgradeTest` starts a release from there and then
  asserts `releases/RELEASES` landed in the release anyway, and it passes a
  *relative* `RELEASE_VM_ARGS` that only resolves if nothing changed directory on
  the way to starting the VM.
  """
  def deployment(root) do
    Deployment.new(root, "sample", cd: Fixture.workspace())
  end

  @doc """
  Generates a relup between two assembled releases, into the workspace.

  `from` and `to` are `{path, version}` pairs. `extra_args` is appended to the
  task's arguments, which is where an upgrade strategy switch goes.

  Through `mix castle.relup` as a command rather than through
  `Forecastle.Relup`, because that is the interface a project has: the task is
  what refuses a transition `--hot` cannot generate, and a suite that named the
  strategy would otherwise be asserting about a function no downstream caller
  reaches.

  Returns the path of the relup it wrote.
  """
  def make_relup!({from, from_vsn}, {to, to_vsn}, extra_args \\ []) do
    # No --outdir: the relup is wanted in the workspace, which is where
    # post-assembly looks for one. The task exits non-zero if it could not
    # generate it, so `mix!` raising is what rules out a relup left over from
    # an earlier run satisfying the assertions below.
    workspace = Fixture.workspace()
    relup = Path.join(workspace, "relup")

    args = ["--target", rel_path(to, to_vsn), "--fromto", rel_path(from, from_vsn)]

    mix!(
      ["castle.relup" | args ++ extra_args],
      [{"SAMPLE_VSN", to_vsn}, {"MIX_BUILD_ROOT", Path.join(workspace, "_build-#{to_vsn}")}]
    )

    assert File.exists?(relup), "mix castle.relup did not produce a relup"

    # And that it is a plan between these two versions, not merely a file.
    contents = File.read!(relup)
    assert contents =~ ~s("#{to_vsn}"), "relup does not target #{to_vsn}:\n\n#{contents}"
    assert contents =~ ~s("#{from_vsn}"), "relup has no path from #{from_vsn}:\n\n#{contents}"

    relup
  end

  defp rel_path(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  defdelegate mix(args, env \\ []), to: Fixture
  defdelegate mix!(args, env \\ []), to: Fixture
  defdelegate cmd!(exe, args, env \\ [], opts \\ []), to: Fixture
  defdelegate cmd(exe, args, env \\ [], opts \\ []), to: Fixture
end
