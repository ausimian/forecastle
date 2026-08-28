defmodule Forecastle.UpgradeTest do
  @moduledoc """
  Boots a real release under the stock Mix launcher and hot-upgrades it.

  This is the only test that proves the point of the whole library: that a
  Castle-enabled release started by `bin/<name>` can be moved from one version
  to the next without restarting the VM. It is opt-in, since it builds two
  releases and runs a node:

      mix test --include e2e

  Distribution runs without epmd (see the fixture's `rel/vm.args.eex`), so no
  daemon needs to be running on the host for this to work.

  It is also where the failure the whole upgrade-tooling design rests on is
  pinned rather than asserted as a mechanism. The fixture's appup is
  deliberately incomplete: `Sample.Counter` and `Sample.Unmentioned` are the same
  module twice over, both carrying a compile-time version tag, and only the first
  is named in `appup.exs`. `:systools.make_relup/4` cannot see that - it checks
  for an *entry* matching the from-version, never for coverage of the modules
  that actually moved - so the relup generates, `bin/castle install` exits 0, and
  one of the two processes goes on serving calls from the code that was loaded
  before. `design/upgrade-tooling.md` §1.1 and §3.5 in ausimian/castle, and
  [#25](https://github.com/ausimian/forecastle/issues/25).
  """

  use Forecastle.ReleaseCase
  use Forecastle.UpgradeCase

  alias Forecastle.Fixture

  @moduletag :e2e

  @from "0.1.0"
  @to "0.1.1"

  setup_all do
    workspace = Fixture.workspace()
    relup = Path.join(workspace, "relup")

    deploy = deployment(assemble!(into: "deploy", vsn: @from))
    next = assemble!(into: "next", vsn: @to)

    # `--hot`, explicitly, because a hot upgrade is the whole subject of this
    # suite. `auto` would produce one here too - `:sample_dep` is a dependency of
    # the fixture whose version moves with it, but its appup covers that move, so
    # `auto` judges the edge hot - and saying so is what makes the task, rather
    # than an assertion further down, the thing that fails if this transition ever
    # stops being hot.
    make_relup!({deploy.root, @from}, {next, @to}, ["--hot"])
    # Reassemble so that post-assembly copies the relup into the release, and
    # the tarball we are about to hand to release_handler contains it.
    ^next = assemble!(into: "next", vsn: @to)

    {boot_elapsed, session} =
      :timer.tc(fn ->
        Deployment.start_peer!(deploy,
          env: [
            {"SAMPLE_GREETING", "hello-from-runtime"},
            {"SAMPLE_BOOT_DELAY_MS", "200"},
            {"FORECASTLE_SCENARIO", "present"}
          ]
        )
      end)

    on_exit(fn ->
      Deployment.stop(session)
      File.rm(relup)
    end)

    Deployment.stage!(session, Path.join(next, "sample-#{@to}.tar.gz"))

    booted = %{
      greeting: Deployment.call!(session, Sample, :greeting, []),
      boot_elapsed: boot_elapsed,
      env_marker: Deployment.call!(session, Sample, :env_marker, []),
      release_env: Deployment.call!(session, Sample, :release_env, []),
      counter: Deployment.call!(session, Sample.Counter, :info, []),
      unmentioned: Deployment.call!(session, Sample.Unmentioned, :info, []),
      os_pid: Deployment.os_pid(session),
      releases: Deployment.castle!(session, ["releases"]),
      releases_file?: File.exists?(Path.join(deploy.root, "releases/RELEASES")),
      dep_lib: session |> Deployment.call!(:code, :lib_dir, [:sample_dep]) |> to_string(),
      scenario: Deployment.call!(session, System, :get_env, ["FORECASTLE_SCENARIO"]),
      mix_env: Deployment.call!(session, System, :get_env, ["MIX_ENV"]),
      erl_zflags: Deployment.call!(session, System, :get_env, ["ERL_ZFLAGS"]),
      peer_work: Deployment.call!(session, System, :get_env, ["FORECASTLE_PEER_WORK"]),
      bounded_call: Deployment.call(session, Process, :sleep, [100], 20),
      root_dir: session |> Deployment.call!(:code, :root_dir, []) |> to_string()
    }

    1 = Deployment.call!(session, Sample.Counter, :bump, [])
    2 = Deployment.call!(session, Sample.Counter, :bump, [])
    3 = Deployment.call!(session, Sample.Counter, :bump, [])

    unpacked = %{
      output: Deployment.castle!(session, ["unpack", @to]),
      releases: Deployment.castle!(session, ["releases"]),
      releases_file?: File.exists?(Path.join(deploy.root, "releases/RELEASES"))
    }

    installed = %{output: Deployment.install!(session, @to)}

    installed =
      Map.merge(installed, %{
        counter: Deployment.call!(session, Sample.Counter, :info, []),
        unmentioned: Deployment.call!(session, Sample.Unmentioned, :info, []),
        # Where the code path would find that module *now*, which is not where
        # the process is running from. "New code sits on disk, reachable,
        # unused" is the whole of §1.1, and this is the half of it an assertion
        # about the running process cannot show on its own.
        unmentioned_object:
          session
          |> Deployment.call!(:code, :get_object_code, [Sample.Unmentioned])
          |> elem(2)
          |> to_string(),
        os_pid: Deployment.os_pid(session),
        greeting: Deployment.call!(session, Sample, :greeting, []),
        releases: Deployment.castle!(session, ["releases"]),
        dep_lib: session |> Deployment.call!(:code, :lib_dir, [:sample_dep]) |> to_string()
      })

    committed = %{output: Deployment.castle!(session, ["commit"])}
    refute committed.output =~ "__CASTLE_COMMIT_"
    refute committed.output =~ "__CASTLE_NOTHING_TO_COMMIT_"

    committed =
      Map.merge(committed, %{
        releases: Deployment.castle!(session, ["releases"]),
        version: Deployment.launcher!(session, ["version"]),
        start_erl: File.read!(Path.join(deploy.root, "releases/start_erl.data"))
      })

    {:ok,
     deploy: deploy,
     session: session,
     booted: booted,
     unpacked: unpacked,
     installed: installed,
     committed: committed}
  end

  describe "booting under the stock launcher" do
    test "is configured by config/runtime.exs", %{booted: booted} do
      # Through Elixir's own pipeline, in the booting VM, with nothing of
      # Forecastle's involved: the launcher is Mix's, sys.config is the one Mix
      # wrote, and the provider that reads runtime.exs is the one Mix installed.
      assert booted.greeting == "hello-from-runtime"
    end

    test "runs the project's own env.sh", %{booted: booted} do
      # The marker is exported by the fixture's rel/env.sh.eex and read by
      # runtime.exs, so it only arrives if the project's env.sh survived being
      # extended and ran before the VM started.
      assert booted.env_marker == "preserved"
    end

    test "creates the RELEASES file before the system starts", %{booted: booted} do
      # The one thing the env.sh hook still does, and the only moment it can be
      # done: release_handler reads this file in its init and otherwise works
      # from a record built out of the boot script, which names no application
      # versions. Nothing after the boot can replace that record - see the code
      # path test below for what it costs.
      #
      # The launcher was invoked from the workspace rather than the release root,
      # so this also pins that the file lands in the release either way.
      assert booted.releases_file?
    end

    test "reports the release as permanent", %{booted: booted} do
      assert booted.releases =~ ~r/#{@from}\s+permanent/
    end

    test "gives runtime.exs the release variables the launcher sets",
         %{booted: booted} do
      # runtime.exs fetches these with fetch_env!, so a release that reached it
      # without them would fail to boot. That used to take work: the fragment ran
      # the configuration before the launcher had assigned them, and had to apply
      # the launcher's own defaults itself. Now the launcher exports them before
      # the VM it configures even starts, and these pin the values it sees.
      assert booted.release_env[:release_node] == "sample"
      assert booted.release_env[:release_cookie_set]
      assert booted.release_env[:release_mode] == "embedded"
      assert booted.release_env[:release_tmp] =~ "/tmp"
      assert booted.release_env[:release_vm_args] =~ "/vm.args"
    end

    test "starts the version that was built", %{booted: booted} do
      assert booted.counter == {@from, 0}

      # The other half of the pair, so that the stale-code test below is a
      # comparison between two versions of this module rather than an assertion
      # that it once said something. Both answers are the from-version at boot:
      # the state the process was initialised with, and the code serving the
      # call.
      assert booted.unmentioned == {@from, @from}
    end

    test "does not report the peer started before application startup finishes",
         %{booted: booted} do
      # OTP's peer user process reports `started` through
      # init:notify_when_started/1. The fixture deliberately spends 200ms inside
      # Application.start/2; returning sooner would mean wait_boot covered only
      # the control connection rather than the release boot.
      assert booted.boot_elapsed >= 200_000
    end

    test "uses the release's own ERTS and carries only scenario environment",
         %{deploy: deploy, booted: booted} do
      assert Path.expand(booted.root_dir) == deploy.root
      assert booted.scenario == "present"
      assert booted.mix_env == nil
      assert booted.erl_zflags == nil
      assert booted.peer_work == nil
      assert {:error, message} = booted.bounded_call
      assert message =~ "did not answer within 20ms"
    end
  end

  describe "the env.sh hook" do
    # It does nothing on a normal start, and this is what that buys: the stock
    # launcher's own handling of everything, unaltered. Kept as a test rather
    # than deleted with the code it covered, because the hook is still appended
    # and #10 will put work back into it.
    test "leaves a relative RELEASE_VM_ARGS resolving against the caller",
         %{deploy: deploy} do
      workspace = Fixture.workspace()
      vsn = Deployment.version(deploy)

      File.cp!(
        Path.join(deploy.root, "releases/#{vsn}/vm.args"),
        Path.join(workspace, "relative.vm.args")
      )

      on_exit(fn -> File.rm(Path.join(workspace, "relative.vm.args")) end)

      # The deployment runs its commands in the workspace, which is not the
      # release root, so this only resolves if nothing changed directory on the
      # way to starting the VM.
      assert {output, 0} =
               Deployment.launcher(deploy, ["eval", "IO.puts(:evaluated)"], [
                 {"RELEASE_VM_ARGS", "relative.vm.args"}
               ]),
             "eval with a relative RELEASE_VM_ARGS failed"

      assert output =~ "evaluated"
    end
  end

  describe "unpacking" do
    test "reports success", %{unpacked: unpacked} do
      assert unpacked.output =~ "Unpacked #{@to} ok"
    end

    test "makes the new release known to the system", %{unpacked: unpacked} do
      assert unpacked.releases =~ ~r/#{@to}\s+unpacked/
      assert unpacked.releases =~ ~r/#{@from}\s+permanent/
    end

    test "keeps the RELEASES file", %{unpacked: unpacked} do
      # release_handler rewrites it here, from the records it holds in memory, so
      # what the boot created is what those records were built from.
      assert unpacked.releases_file?
    end
  end

  describe "installing" do
    test "reports the version change", %{installed: installed} do
      assert installed.output =~ "Now running #{@to} (previously #{@from})."
    end

    test "leaves the new version as the one running", %{installed: installed} do
      # What `Castle.running/1` looks for, and what `bin/castle install` waits
      # to see before it reports success: the version installed is current, and
      # the one it came from stays permanent until it is committed. `install`
      # exiting 0 above already depended on this - asserted here so that a
      # change in what a fresh install leaves behind says so.
      assert installed.releases =~ ~r/#{@to}\s+current/
      assert installed.releases =~ ~r/#{@from}\s+permanent/
    end

    test "loads the new code", %{installed: installed} do
      assert elem(installed.counter, 0) == @to
    end

    test "preserves the state of the running process", %{installed: installed} do
      assert installed.counter == {@to, 3}
    end

    test "leaves a changed module the appup does not mention running the old code",
         %{booted: booted, installed: installed} do
      # The failure the whole of the upgrade tooling exists to catch, demonstrated
      # rather than described. `Sample.Counter` and `Sample.Unmentioned` are the
      # same module twice: both are supervised GenServers, both carry a
      # compile-time version tag, both differ between the two builds, and both
      # export a `code_change/3` that sets the tag to whatever the *new* code
      # says. The only difference between them is that `appup.exs` names the
      # first and says nothing about the second.
      #
      # `:systools.make_relup/4` checks for an entry matching the from-version,
      # never for coverage of the modules that moved, so it generated this relup
      # without complaint. Everything downstream then reported success: `unpack`,
      # `install` and `commit` all exited 0, which is what `castle!/3` raising
      # otherwise would have said, and the install announced the version change.
      assert installed.output =~ "Now running #{@to} (previously #{@from})."

      # And yet one of the two processes moved and the other did not.
      assert elem(booted.counter, 0) == @from
      assert booted.unmentioned == {@from, @from}

      assert elem(installed.counter, 0) == @to

      # Both halves of the answer, because they say different things and only
      # the second is the §1.1 claim. The state's tag being unmoved says
      # `code_change/3` was never called, which is what "no instruction reached
      # this module" looks like; the *code's* tag being unmoved says this
      # process is executing the old copy of the module, which is what "still
      # the version that was loaded before, serving calls" means. A version that
      # loaded the new code without a `code_change` would satisfy the first and
      # fail the second.
      assert installed.unmentioned == {@from, @from},
             "the unmentioned module was upgraded, so this fixture no longer demonstrates " <>
               "the incomplete-appup failure - check that appup.exs still names only " <>
               "Sample.Counter"

      # And the other half of "new code sits on disk, reachable, unused": the
      # code path the running system resolves this module through is already the
      # new release's, so the next restart loads it underneath a system nobody
      # was upgrading.
      assert installed.unmentioned_object =~ "sample-#{@to}"
    end

    test "does not restart the VM", %{booted: booted, installed: installed} do
      assert installed.os_pid == booted.os_pid
    end

    test "resolved the target's configuration in a peer", %{deploy: deploy} do
      # How Castle configures every version it installs, and the only way it
      # does: it keeps what Mix wrote as sys.config.pristine, boots a VM on the
      # target's own preboot script to run the target's own providers, and
      # renames the result over sys.config with a line saying it did. The
      # preboot script this needs is what pre_assemble/1 contributes, which is
      # why this is asserted from here.
      version_path = Path.join(deploy.root, "releases/#{@to}")

      assert File.read!(Path.join(version_path, "sys.config")) =~ "CASTLE_MATERIALISED=true"
      assert File.exists?(Path.join(version_path, "sys.config.pristine"))
      refute File.read!(Path.join(version_path, "sys.config.pristine")) =~ "CASTLE_MATERIALISED"
    end

    test "moves an application the relup never mentions onto the new code path",
         %{booted: booted, installed: installed} do
      # :sample_dep's version changes between the two builds, and its appup asks
      # for nothing, so the relup carries no instruction that loads its code. The
      # only way release_handler can know its version changed is from the release
      # records it holds - and it builds those from releases/RELEASES at startup,
      # or, when that file is missing, from the boot script, which names no
      # application versions at all.
      #
      # get_new_libs/2 is what turns "this application's version changed" into
      # the code:replace_path that runs at point_of_no_return. Seeded from a
      # record with no applications in it, it returns nothing, and the running
      # system is left reaching this application through the directory of the
      # release being replaced - which the next `remove` deletes. Nothing says
      # so at the time, which is why this is asserted rather than reasoned about.
      assert booted.dep_lib =~ "sample_dep-#{@from}"
      assert installed.dep_lib =~ "sample_dep-#{@to}"
    end

    test "left no peer, and no working directory, behind", %{deploy: deploy} do
      assert Path.wildcard(Path.join(deploy.root, "releases/*/castle-*")) == []
    end

    test "configures the version it installed", %{installed: installed} do
      # release_handler reads the target version's sys.config and applies it as
      # part of the upgrade, so this is the configuration Castle's peer resolved
      # - by running 0.1.1's own providers, in a VM of its own, before the
      # install was asked for. The peer inherits the running node's environment,
      # which is where SAMPLE_GREETING comes from.
      assert installed.greeting == "hello-from-runtime"
    end
  end

  describe "committing without a version" do
    test "commits the version that is running", %{committed: committed} do
      assert committed.output =~ "Committed #{@to}."
    end

    test "makes it permanent", %{committed: committed} do
      assert committed.releases =~ ~r/#{@to}\s+permanent/
      assert committed.releases =~ ~r/#{@from}\s+old/
    end

    test "points the stock launcher's version selection at it", %{committed: committed} do
      # start_erl.data is what bin/<name> reads to pick RELEASE_VSN, and
      # release_handler is what writes it. Forecastle contributes nothing here.
      assert committed.start_erl =~ @to
      assert committed.version == "sample #{@to}"
    end
  end
end
