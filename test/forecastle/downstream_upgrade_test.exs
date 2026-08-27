defmodule Forecastle.DownstreamUpgradeTest do
  @moduledoc """
  The upgrade test a project outside this repository writes, written that way.

  The acceptance criterion behind the harness is that a downstream project can
  test an upgrade *without copying code out of `test/support`*, and a claim like
  that is worth exactly as much as the thing that checks it. So this suite is the
  check: everything it does to a release is `Forecastle.UpgradeCase` and
  `Forecastle.Deployment`, both of which are in `lib` and both of which ship.

  Three things here are the fixture's rather than the harness's, and they stand
  in for what a project already has:

    * `assemble!/1` is `mix release` with the sample's version in the
      environment. A project runs its own build.
    * `SAMPLE_UPGRADE_FROM` is how this fixture sets `upgrade_from:`. A project
      writes it in `mix.exs`, through `Castle.customize/1`.
    * `Sample.Counter` is the thing that has to survive. Only the project knows
      what that is, which is the whole reason this is a case template and not a
      task.

  Nothing else. `Forecastle.ReleaseCase` is used for the builds and for the
  workspace hygiene the fixture needs; every line about the *deployment* is
  shipped API.

  ## Why it is not `Forecastle.UpgradeTest` again

  That suite pins the mechanism - what `unpack`, `install` and `commit` do to a
  system, what an incomplete appup costs, what the `env.sh` hook contributes -
  and it does so through two builds and a `mix castle.relup` between them,
  because it needs to name `--hot` explicitly.

  This one is the everyday path instead, and it is shorter for a reason worth
  seeing: `upgrade_from:` puts the relup in the tarball during the single build
  that produces it, so there is no second assembly and no relup file to move
  around. What it asserts is what a project asks of an upgrade - the version
  moved, the state came with it, and the VM was never restarted.

      mix test --include e2e
  """

  use Forecastle.ReleaseCase
  use Forecastle.UpgradeCase

  alias Forecastle.Fixture

  @moduletag :e2e

  @from "0.1.0"
  @to "0.1.1"

  setup_all %{scratch: scratch} do
    # What the project shipped. Its own `:tar` step packed it, and it is the same
    # bytes a deployment would have been handed.
    shipped =
      Path.join(assemble!(into: "downstream-shipped", vsn: @from), "sample-#{@from}.tar.gz")

    # And the next version, naming that artefact as the release it can be
    # upgraded from. One `mix release`: the relup is generated between
    # post-assembly and `:tar`, so it is inside the archive this produces.
    next =
      assemble!(
        into: "downstream-next",
        vsn: @to,
        env: [{"SAMPLE_UPGRADE_FROM", "tar:#{shipped}"}]
      )

    # The upgrade test itself starts here, and everything from this line down is
    # shipped API.
    deployment = Deployment.deploy!("tar:#{shipped}", Path.join(scratch, "deploy"))
    on_exit(fn -> Deployment.stop(deployment) end)

    Deployment.start!(deployment)

    booted = %{
      counter: Deployment.rpc!(deployment, "IO.puts(inspect(Sample.Counter.info()))"),
      os_pid: Deployment.os_pid(deployment),
      version: Deployment.version(deployment)
    }

    "3" =
      Deployment.rpc!(
        deployment,
        "IO.puts(Enum.map(1..3, fn _ -> Sample.Counter.bump() end) |> List.last())"
      )

    Deployment.stage!(deployment, Path.join(next, "sample-#{@to}.tar.gz"))
    Deployment.castle!(deployment, ["unpack", @to])
    Deployment.castle!(deployment, ["install", @to])
    Deployment.castle!(deployment, ["commit"])

    upgraded = %{
      counter: Deployment.rpc!(deployment, "IO.puts(inspect(Sample.Counter.info()))"),
      os_pid: Deployment.os_pid(deployment),
      releases: Deployment.castle!(deployment, ["releases"]),
      version: Deployment.version(deployment)
    }

    {:ok,
     scratch: scratch,
     shipped: shipped,
     deployment: deployment,
     booted: booted,
     upgraded: upgraded}
  end

  describe "upgrading the artefact that shipped" do
    test "started on the version in the tarball", %{booted: booted} do
      assert booted.version == @from
      assert booted.counter == ~s({"#{@from}", 0})
    end

    test "moved to the next version", %{upgraded: upgraded} do
      assert upgraded.counter =~ ~s("#{@to}")
      assert upgraded.releases =~ ~r/#{@to}\s+permanent/
      assert upgraded.version == @to
    end

    test "kept the state the running process had", %{upgraded: upgraded} do
      # The question a project actually asks of a hot upgrade, and the one no
      # task could ask on its behalf: three calls happened before the install and
      # the count is still three after it.
      assert upgraded.counter == ~s({"#{@to}", 3})
    end

    test "never restarted the VM", %{booted: booted, upgraded: upgraded} do
      # `auto` judged this transition hot, which is what `upgrade_from:`
      # generates under. A relup that had degraded to `restart_emulator` would
      # show up here as a different operating system process - and would have
      # needed `install_supervised!/3` to get this far at all.
      assert upgraded.os_pid == booted.os_pid
    end
  end

  describe "the deployment" do
    test "was laid out in the scratch directory rather than in the cache",
         %{scratch: scratch, shipped: shipped, deployment: deployment} do
      # `tar:` resolves into `_build/castle/baselines`, which is immutable and
      # read by every later resolution of the same spec. This deployment has
      # been started, upgraded and committed, so if it were the cache entry the
      # next run resolving this artefact would get a system mid-upgrade.
      resolved = Forecastle.Baseline.resolve!("tar:#{shipped}", :release)

      assert deployment.root == Path.join(scratch, "deploy")
      refute deployment.root == Path.expand("../../..", resolved.rel_path)
      refute File.exists?(Path.expand("../../../releases/RELEASES", resolved.rel_path))
    end
  end

  describe "the environment a deployment starts a release in" do
    test "covers every control the generated launcher takes from it",
         %{deployment: deployment} do
      # Read out of the launcher Mix actually generated rather than restated
      # from a list written beside the scrub, which is the only way a variable a
      # later Elixir adds shows up as a failure instead of as a hole. Every one
      # of these is `${NAME:-default}`, so an inherited value wins: an args file
      # carrying emulator flags, a boot script, a configuration file, `embedded`
      # versus `interactive`, `sname` versus `name`. None announces itself, and
      # what each produces is a test of a release materially unlike the one that
      # would be deployed.
      inherited =
        deployment.root
        |> Path.join("bin/#{deployment.name}")
        |> File.read!()
        |> then(&Regex.scan(~r/^(RELEASE_[A-Z_]+)="\$\{\1:-/m, &1))
        |> Enum.map(fn [_line, name] -> name end)
        |> Enum.uniq()

      scrubbed = for {name, nil} <- Deployment.scrubbed_env(), do: name

      assert length(inherited) > 5, "found no launcher defaults to check: #{inspect(inherited)}"
      assert inherited -- scrubbed == []
    end
  end

  describe "what a project depending on Forecastle is given" do
    test "the harness compiled into its build" do
      # The fixture depends on Forecastle by path, so its build directory is a
      # real consumer's. Castle names Forecastle `runtime: false`, which keeps it
      # out of releases and changes nothing about this: a build-time dependency
      # is compiled and on the code path wherever the project's own tests run.
      ebin = Path.join(Fixture.workspace(), "_build-#{@from}/prod/lib/forecastle/ebin")

      for module <- [Forecastle.Deployment, Forecastle.UpgradeCase] do
        assert File.exists?(Path.join(ebin, "#{module}.beam")),
               "#{inspect(module)} did not reach a project that depends on Forecastle"
      end
    end
  end
end
