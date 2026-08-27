defmodule Forecastle.DeploymentTest do
  @moduledoc """
  The parts of the shipped harness that can be asserted without booting
  anything: laying a release out, naming it, staging an archive into it, and the
  environment every command it runs carries.

  A release tree is a directory with three subdirectories in it, so everything
  here works against one built in the test - the same trick
  `Forecastle.BaselineTest` uses, and for the same reason: the end-to-end suites
  already pay for real assemblies, and none of these questions needs one.

  What *cannot* be asserted here is anything about a running system, which is
  `Forecastle.DownstreamUpgradeTest`'s.
  """

  use ExUnit.Case, async: false

  alias Forecastle.Deployment
  alias Forecastle.Fixture

  @moduletag :slow
  @moduletag timeout: 600_000

  @root Path.join(Fixture.repo_root(), "_build/fixtures/deployments")

  describe "naming a release tree" do
    setup :release_tree

    test "expands the root it was given", ctx do
      deployment = Deployment.new(Path.join(ctx.tree, "."), "my_app")

      assert deployment.root == ctx.tree
    end

    test "runs its commands from the caller's directory unless told otherwise", ctx do
      # Not the release root, and deliberately: a launcher invoked from
      # somewhere else is the ordinary case, and defaulting to the release would
      # take that coverage away from every test written on this.
      assert Deployment.new(ctx.tree, "my_app").cd == File.cwd!()
      assert Deployment.new(ctx.tree, "my_app", cd: @root).cd == Path.expand(@root)
    end

    test "carries the environment it was given", ctx do
      deployment = Deployment.new(ctx.tree, "my_app", env: [{"SOME_VAR", "value"}])

      assert deployment.env == [{"SOME_VAR", "value"}]
    end

    test "takes a boot deadline from the project, since only it knows one", ctx do
      # Twenty seconds describes a release that does nothing on the way up. One
      # that runs migrations, warms a cache or waits on a dependency takes
      # longer, and with no way to say so `start!/2` would report a healthy cold
      # boot as a failure.
      assert Deployment.new(ctx.tree, "my_app").boot_timeout == 20_000
      assert Deployment.new(ctx.tree, "my_app", boot_timeout: 90_000).boot_timeout == 90_000
    end

    test "reports the version an ordinary start would boot", ctx do
      assert Deployment.version(Deployment.new(ctx.tree, "my_app")) == "1.0.0"
    end

    test "reads the version the way the launcher reads it", ctx do
      # `bin/<name>` takes RELEASE_VSN from `cut -d' ' -f2`, so the release
      # version is the *second* field. Taking the last one instead - which is
      # what this did while it was a private helper - answers `rc1` for a version
      # Castle permits and the launcher would boot as `1.2.0`.
      File.write!(Path.join(ctx.tree, "releases/start_erl.data"), "16.2 1.2.0 rc1\n")

      assert Deployment.version(Deployment.new(ctx.tree, "my_app")) == "1.2.0"
    end

    test "refuses a start_erl.data with no version in it", ctx do
      File.write!(Path.join(ctx.tree, "releases/start_erl.data"), "16.2")

      assert_raise Mix.Error, ~r/does not name a release version/, fn ->
        Deployment.version(Deployment.new(ctx.tree, "my_app"))
      end
    end
  end

  describe "running the release's own commands" do
    setup :release_tree

    # Against stubs that report their arguments, because what is being asserted
    # is which program each of these reaches and what it does with the answer.
    # That a real launcher answers is every other suite's.

    test "the launcher and bin/castle are two different programs", ctx do
      deployment = echoing!(ctx.tree)

      assert Deployment.launcher!(deployment, ["version"]) == "my_app: version"
      assert Deployment.castle!(deployment, ["releases"]) == "castle: releases"
    end

    test "an rpc is the launcher with the expression after it", ctx do
      deployment = echoing!(ctx.tree)

      assert Deployment.rpc!(deployment, "IO.puts(:hello)") == "my_app: rpc IO.puts(:hello)"
    end

    test "the pid is what the release says its own is", ctx do
      # Through `bin/<name> pid`, which is an rpc, so it is the beam's own
      # `System.pid/0` rather than anything about the process that asked.
      deployment = stubbed!(ctx.tree, "4242", "exit 0\n")

      assert Deployment.os_pid(deployment) == "4242"
    end

    test "the non-bang forms hand back the status", ctx do
      deployment = refusing!(ctx.tree)

      assert {output, 7} = Deployment.launcher(deployment, ["version"])
      assert output =~ "refused"
      assert {_output, 7} = Deployment.castle(deployment, ["releases"])
    end

    test "stopping tolerates a system that is not running", ctx do
      # It belongs in an `on_exit`, where a setup that died half way through may
      # have left nothing to stop - and a teardown that raised there would
      # report itself instead of the failure that got it there.
      deployment = refusing!(ctx.tree)

      assert {_output, 7} = Deployment.stop(deployment)
    end

    test "a start's own environment reaches the readiness check", ctx do
      # `RELEASE_NODE` and `RELEASE_COOKIE` are both scrubbed, so a start
      # carrying its own comes up under that identity - and a readiness rpc made
      # with the defaults asks the wrong node. What that looks like is a release
      # that started perfectly and was reported as one that never answered.
      # `daemon` succeeds either way, so what the second half below measures is
      # the readiness rpc and not the start.
      stub!(ctx.tree, "my_app", """
      if [ "$1" = "daemon" ]; then exit 0; fi
      if [ "$RELEASE_NODE" != "elsewhere" ]; then exit 1; fi
      exit 0
      """)

      deployment = Deployment.new(ctx.tree, "my_app", boot_timeout: 600)

      assert Deployment.start!(deployment, [{"RELEASE_NODE", "elsewhere"}]) == ""

      # And the failing half, so that the case above is about the environment
      # arriving rather than about the stub answering everything. The deadline
      # is the deployment's, which is what makes this quick.
      assert_raise ExUnit.AssertionError, ~r/did not accept an rpc within/, fn ->
        Deployment.start!(deployment)
      end
    end

    # The linked task's crash report is the point of the case, not noise to read.
    @tag :capture_log
    test "a launcher that failed is reported as a failure, not as a hang", ctx do
      # `Task.async/1` links, so a launcher exiting non-zero normally takes the
      # calling process down with `launcher!/3`'s message before `Task.yield/2`
      # returns - which is why the diagnostic was not being lost. Under a caller
      # that traps exits, `yield` answers `{:exit, _}` instead, and the wildcard
      # that used to be here called that a 180-second hang with nothing to
      # report.
      Process.flag(:trap_exit, true)

      stub!(ctx.tree, "my_app", ~s|echo "no cookie file"\nexit 1\n|)
      deployment = Deployment.new(ctx.tree, "my_app", boot_timeout: 600)

      assert_raise ExUnit.AssertionError, ~r/could not be started/, fn ->
        Deployment.start!(deployment)
      end
    end

    test "the bang forms name the program that failed", ctx do
      deployment = refusing!(ctx.tree)

      assert_raise RuntimeError, ~r/my_app version exited with 7/, fn ->
        Deployment.launcher!(deployment, ["version"])
      end

      assert_raise RuntimeError, ~r/castle releases exited with 7/, fn ->
        Deployment.castle!(deployment, ["releases"])
      end
    end
  end

  describe "installing while acting as the supervisor" do
    setup :release_tree

    # An install can fail on either side of the reboot, and the two are not the
    # same failure: one leaves the node running and the other is reported after
    # it has come back. Both are driven against stubs rather than a release,
    # because what is being asserted is what this function does with each answer
    # - `Forecastle.RestartUpgradeTest` is where a real transition lives.

    test "reports what an install that never rebooted said", ctx do
      # The near side, and the failure this used to swallow. `bin/castle
      # install` polls the system for the version it installed and cannot be
      # answered until the release is started again - which is this function's
      # own next line - so an install that has already exited has exited about a
      # failure, and it is holding the only account of it. Waiting on the
      # process alone spent thirty seconds and then reported that a process was
      # still running.
      #
      # This VM's own operating system process stands in for a node that never
      # went away, since it certainly does not.
      deployment = stubbed!(ctx.tree, System.pid(), ~s|echo "Nothing to unpack."\nexit 3\n|)

      assert_raise ExUnit.AssertionError, ~r/Nothing to unpack/, fn ->
        Deployment.install_supervised(deployment, "1.1.0")
      end
    end

    test "asks for the pid with the environment the install was given", ctx do
      # The pid it waits on is read before the install starts, and it is read
      # from a node the install's own environment may be what identifies. Read
      # with the defaults instead, it fails, `launcher!/3` raises, and the
      # install never happens.
      stub!(ctx.tree, "my_app", """
      if [ "$RELEASE_NODE" != "elsewhere" ]; then exit 1; fi
      if [ "$1" = "pid" ]; then echo #{System.pid()}; fi
      exit 0
      """)

      stub!(ctx.tree, "castle", ~s|echo "Nothing to unpack."\nexit 3\n|)

      deployment = Deployment.new(ctx.tree, "my_app")

      assert_raise ExUnit.AssertionError, ~r/Nothing to unpack/, fn ->
        Deployment.install_supervised(deployment, "1.1.0", [{"RELEASE_NODE", "elsewhere"}])
      end
    end

    test "hands back a status from the far side of the reboot", ctx do
      # The other side, which is the one a bang name is doing work for. The
      # process goes, the release is started again, and `bin/castle install`
      # then reports that the version it installed is not the one running - a
      # provisional release that rolled back on the way up.
      deployment =
        stubbed!(ctx.tree, transient_pid(), ~s|sleep 2\necho "1.1.0 is not running."\nexit 4\n|)

      assert {output, 4} = Deployment.install_supervised(deployment, "1.1.0")
      assert output =~ "1.1.0 is not running."
    end

    test "raises on it under the bang, which is the whole of the difference", ctx do
      # Returning the tuple under a bang name is what let a test written the way
      # the documentation suggests - `install_supervised!/3` in place of
      # `castle!/3` - carry on to `commit` and assert against a system the
      # install had already given up on.
      deployment =
        stubbed!(ctx.tree, transient_pid(), ~s|sleep 2\necho "1.1.0 is not running."\nexit 4\n|)

      assert_raise RuntimeError, ~r/1\.1\.0 is not running/, fn ->
        Deployment.install_supervised!(deployment, "1.1.0")
      end
    end
  end

  describe "deploying a baseline" do
    setup :release_tree

    test "lays the release out where it was asked to", ctx do
      into = Path.join(@root, "deployed")

      deployment = Deployment.deploy!("rel:#{ctx.rel_path}", into)

      assert deployment.root == Path.expand(into)
      assert deployment.name == "my_app"
      assert File.exists?(Path.join(into, "releases/1.0.0/my_app.rel"))
    end

    test "names the release out of the .rel term, not off the filename", ctx do
      # An unpacked release holds two `.rel` files: Mix's `<name>.rel` and the
      # `<name>-<vsn>.rel` that `release_handler` copies in beside it,
      # byte-identical. `Forecastle.Baseline` de-duplicates on the consulted term
      # and `Path.wildcard/1` sorts the compatibility copy first, so it is the
      # one that comes back - and its basename names a launcher, `bin/my_app-
      # 1.0.0`, that does not exist. Every command the deployment made would fail
      # on it.
      write_rel!(Path.join(ctx.tree, "releases/1.0.0/my_app-1.0.0.rel"))
      tarball = tar_up!(ctx.tree, Path.join(@root, "source/unpacked-1.0.0.tar.gz"))

      assert Deployment.deploy!("tar:#{tarball}", Path.join(@root, "deployed-unpacked")).name ==
               "my_app"

      # And named directly, so the case does not rest on which of the two the
      # resolver happened to pick.
      assert Deployment.deploy!(
               "rel:#{ctx.tree}/releases/1.0.0/my_app-1.0.0",
               Path.join(@root, "deployed-compat")
             ).name == "my_app"
    end

    test "keeps the launcher executable", ctx do
      # The whole point of a deployment is that it can be started, and a
      # launcher copied without its mode cannot be. Asserted rather than left to
      # `File.cp_r!/2`'s documentation, because a release that will not start is
      # a long way from the line that caused it.
      into = Path.join(@root, "deployed-modes")

      deployment = Deployment.deploy!("rel:#{ctx.rel_path}", into)

      assert File.stat!(Path.join(deployment.root, "bin/my_app")).mode ==
               File.stat!(Path.join(ctx.tree, "bin/my_app")).mode
    end

    test "empties the destination first", ctx do
      into = Path.join(@root, "deployed-stale")
      File.mkdir_p!(into)
      File.write!(Path.join(into, "left-over"), "from an earlier run")

      Deployment.deploy!("rel:#{ctx.rel_path}", into)

      refute File.exists?(Path.join(into, "left-over"))
    end

    test "leaves the resolved baseline exactly as it was", ctx do
      # The reason a deployment is a copy. `tar:` and `ref:` resolve into a cache
      # keyed on what the entry was built from, and every later resolution of
      # that spec reads it back - so a system started in place would leave the
      # cache holding a booted, half-upgraded release with nothing to say so.
      resolved = Forecastle.Baseline.resolve!("tar:#{ctx.tarball}", :release)
      cached = Path.expand("../../..", resolved.rel_path)

      deployment = Deployment.deploy!("tar:#{ctx.tarball}", Path.join(@root, "deployed-tar"))

      refute deployment.root == cached

      # What starting a release does to the tree it is started in.
      File.write!(Path.join(deployment.root, "releases/RELEASES"), "[].")

      refute File.exists?(Path.join(cached, "releases/RELEASES"))
    end

    test "refuses a destination inside the release", ctx do
      # `File.rm_rf!/1` on the destination is the first thing a deployment does,
      # so an overlapping one deletes what it is about to copy. Both directions,
      # because `rel:` names a tree the project built and the cache is read by
      # every later resolution of the same spec.
      inside = Path.join(ctx.tree, "deployed")

      assert_raise Mix.Error, ~r/are the same directory or one is inside the other/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", inside)
      end

      assert_raise Mix.Error, ~r/are the same directory or one is inside the other/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", ctx.tree)
      end

      assert_raise Mix.Error, ~r/are the same directory or one is inside the other/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", Path.dirname(ctx.tree))
      end

      assert File.exists?(Path.join(ctx.tree, "releases/1.0.0/my_app.rel"))
    end

    test "refuses a spec that resolves to no release, before emptying anything", ctx do
      # `rel:` is read off disk by whatever uses the path, and here that is a
      # recursive copy that would name two directories and no spec. Asked before
      # the destination is emptied, so a mistyped spec does not cost the caller
      # the directory they aimed it at as well as the run.
      into = Path.join(@root, "deployed-missing")
      File.mkdir_p!(into)
      File.write!(Path.join(into, "precious"), "not this run's to delete")

      assert_raise Mix.Error, ~r/there is no such file/, fn ->
        Deployment.deploy!("rel:#{ctx.tree}-typo/releases/1.0.0/my_app", into)
      end

      assert File.exists?(Path.join(into, "precious"))
    end

    test "refuses a spec with too few directories above the .rel to have a root" do
      # The dangerous shape, and the reason the preflight is about the *shape* of
      # the spec rather than about the directory it lands on. `Path.expand/2`
      # climbing past the top of an absolute path stops at `/` instead of
      # failing, so three parents up from `/tmp/missing` is the filesystem root -
      # and what came after it was `File.rm_rf!/1` on the destination followed by
      # a recursive copy of everything.
      into = Path.join(@root, "deployed-shallow")
      File.mkdir_p!(into)
      File.write!(Path.join(into, "precious"), "not this run's to delete")

      assert_raise Mix.Error, ~r/there is no such file/, fn ->
        Deployment.deploy!("rel:/tmp/missing", into)
      end

      assert File.exists?(Path.join(into, "precious"))
    end

    test "refuses a .rel that exists but is not under releases/<vsn>" do
      # The same climb, with the file present. Three directories up means
      # something only because the grammar puts the `.rel` at
      # `<root>/releases/<vsn>/<name>`; from anywhere else it lands on whatever
      # happens to be three levels above.
      flat = Path.join(@root, "flat")
      File.mkdir_p!(flat)
      write_rel!(Path.join(flat, "my_app.rel"))

      assert_raise Mix.Error, ~r/not under a `releases\/<vsn>\/` directory/, fn ->
        Deployment.deploy!("rel:#{flat}/my_app", Path.join(@root, "deployed-flat"))
      end
    end

    test "refuses the filesystem root as a destination", ctx do
      # `/` contains every absolute path, and the textual prefix test this
      # replaced could not see that: `/` with a separator appended is `//`, which
      # nothing begins with. So a destination of `/` reached `File.rm_rf!/1`.
      assert_raise Mix.Error, ~r/are the same directory or one is inside the other/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", "/")
      end
    end

    test "refuses a destination whose release is still running", ctx do
      # The deletion that comes back as a passing test. A deployment is a stable
      # path, so a run interrupted before its `on_exit` leaves a daemon running
      # out of this tree - and emptying the directory does not stop that node.
      # It goes on holding the release's distribution name, and the readiness
      # rpc after the next start is as likely to reach it as the new system, at
      # which point the from-version assertions pass against last run's code.
      into = occupied!(Path.join(@root, "deployed-live"), "my_app", "echo 4242\nexit 0\n")

      assert_raise Mix.Error, ~r/it is running as process 4242/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", into)
      end

      # Refused rather than stopped, and refused without touching it.
      assert File.exists?(Path.join(into, "bin/my_app"))
    end

    test "asks the destination's own release, not the one being deployed", ctx do
      # A previous run may have put a different release here, or the same one
      # under a name the project has since changed. Probing `bin/<incoming
      # name>` asks about a launcher that is not even present, comes back
      # "nothing running", and deletes a live tree.
      into = occupied!(Path.join(@root, "deployed-renamed"), "old_app", "echo 4242\nexit 0\n")

      assert_raise Mix.Error, ~r/holds a old_app deployment/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", into)
      end
    end

    test "probes from the directory the deployment runs its commands in", ctx do
      # A release started from a working directory of its own may have been given
      # a *relative* `RELEASE_VM_ARGS`, which `Forecastle.UpgradeTest` covers on
      # purpose. A probe made from somewhere else cannot resolve it, the launcher
      # fails, that reads as "nothing running", and the live deployment is
      # deleted underneath the node.
      gated_on_cwd = """
      if [ ! -f ./marker ]; then exit 1; fi
      echo 4242
      """

      into = occupied!(Path.join(@root, "deployed-elsewhere"), "my_app", gated_on_cwd)
      workdir = Path.join(@root, "workdir")
      File.mkdir_p!(workdir)
      File.write!(Path.join(workdir, "marker"), "")

      assert_raise Mix.Error, ~r/it is running as process 4242/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", into, cd: workdir)
      end
    end

    test "reaches a deployment started with a node name of its own", ctx do
      # A release started with `RELEASE_NODE` or `RELEASE_COOKIE` of its own is
      # only reachable with them, and both are on the scrub list - so a probe
      # built from the defaults asks the wrong node and is told nothing is
      # running. The caller's `:env` is what the deployment will carry, and is
      # what the run before it carried.
      answers_only_by_name = """
      if [ "$RELEASE_NODE" != "somewhere" ]; then exit 1; fi
      echo 4242
      """

      without = occupied!(Path.join(@root, "deployed-unnamed"), "my_app", answers_only_by_name)
      with_name = occupied!(Path.join(@root, "deployed-named"), "my_app", answers_only_by_name)

      # Both halves, because the second says nothing on its own: a probe that
      # answered either way would refuse here and look correct. This is the
      # deletion of a live tree that carrying the caller's environment prevents.
      assert Deployment.deploy!("rel:#{ctx.rel_path}", without)

      assert_raise Mix.Error, ~r/it is running as process 4242/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", with_name, env: [{"RELEASE_NODE", "somewhere"}])
      end
    end

    test "deploys over one that is not running", ctx do
      # The other half, so that the refusal is about a *live* release rather
      # than about the launcher being there at all - which it always is, since
      # the last deployment put it there.
      into = occupied!(Path.join(@root, "deployed-dead"), "my_app", "exit 1\n")

      assert Deployment.deploy!("rel:#{ctx.rel_path}", into).root == Path.expand(into)
    end

    test "refuses a destination that reaches the release through a symlink", ctx do
      # `Path.expand/2` is lexical, so `<root>/source/my_app` and
      # `<root>/alias/my_app` are different segment lists naming one directory -
      # which is the shape `/tmp` and `/private/tmp` have on a Mac, and the shape
      # any symlinked parent has anywhere. Read as no overlap, `File.rm_rf!/1`
      # follows the link and deletes the release that was about to be copied.
      aliased = Path.join(@root, "alias")
      File.ln_s!(Path.dirname(ctx.tree), aliased)

      assert_raise Mix.Error, ~r/are the same directory or one is inside the other/, fn ->
        Deployment.deploy!("rel:#{ctx.rel_path}", Path.join(aliased, "my_app"))
      end

      assert File.exists?(Path.join(ctx.tree, "releases/1.0.0/my_app.rel"))
    end

    test "a sibling whose name merely starts the same is not an overlap", ctx do
      # The prefix test is on path *segments*, so `my_app-next` beside `my_app`
      # is a different directory rather than one inside it.
      into = ctx.tree <> "-next"

      assert Deployment.deploy!("rel:#{ctx.rel_path}", into).root == Path.expand(into)
    end
  end

  describe "staging an archive" do
    setup :release_tree

    test "puts it where release_handler looks for one", ctx do
      deployment = Deployment.deploy!("rel:#{ctx.rel_path}", Path.join(@root, "deployed-staging"))

      staged = Deployment.stage!(deployment, ctx.tarball)

      assert staged == Path.join(deployment.root, "releases/my_app-1.0.0.tar.gz")
      assert File.exists?(staged)
    end
  end

  describe "the environment a release is started with" do
    test "unsets what would otherwise carry emulator flags into every start" do
      env = Deployment.scrubbed_env()

      for variable <- ~w(ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS) do
        assert {variable, nil} in env
      end
    end

    test "unsets the one whose name carries the emulator's OTP major" do
      # It cannot be written into a literal list, so it is the one that gets
      # forgotten - and erlexec prepends it exactly like the other four.
      assert {"ERL_OTP#{:erlang.system_info(:otp_release)}_FLAGS", nil} in Deployment.scrubbed_env()
    end

    test "and the one for an OTP this VM is not running" do
      # Asking `:erlang.system_info/1` what this VM is scrubs the wrong name for
      # the deployment this harness most wants to be usable: a `tar:` baseline is
      # the artefact that shipped, which may have been built against a different
      # OTP, and the erlexec inside that release reads its own major's variable.
      # A `-heart` arriving through it is the two-flag hang.
      System.put_env("ERL_OTP19_FLAGS", "-heart")
      on_exit(fn -> System.delete_env("ERL_OTP19_FLAGS") end)

      assert {"ERL_OTP19_FLAGS", nil} in Deployment.scrubbed_env()
    end

    test "unsets the build environment the release is being started from" do
      # A deployed release is started with no Mix and no `MIX_ENV`; a release
      # started from a test run inherits `test`, measured on the generated
      # launcher. Nothing Mix or Forecastle writes reads it - what it changes is
      # whatever the project's own `config/runtime.exs` makes of it, and that is
      # the one file a project routinely shares between a Mix run and a release.
      assert {"MIX_ENV", nil} in Deployment.scrubbed_env()
    end

    test "unsets what would redirect the launcher to another project's args file" do
      # Sharper than an extra flag: these do not add anything, they send the
      # launcher to a different `vm.args` entirely, which presents as a bug in
      # the release rather than as a leaked variable.
      env = Deployment.scrubbed_env()

      assert {"RELEASE_VM_ARGS", nil} in env
      assert {"RELEASE_REMOTE_VM_ARGS", nil} in env
    end

    test "lets the caller set one of them anyway" do
      # `System.cmd/3` applies the list in order, so a test that wants to give a
      # release a hostile environment to boot in simply names the variable.
      env = Deployment.scrubbed_env([{"ERL_AFLAGS", "-env PROBE set"}])

      assert Enum.find_index(env, &(&1 == {"ERL_AFLAGS", nil})) <
               Enum.find_index(env, &(&1 == {"ERL_AFLAGS", "-env PROBE set"}))
    end
  end

  describe "reaching a project that depends on Forecastle" do
    test "the harness is library code rather than test support" do
      # The acceptance criterion behind the whole extraction, asked of the beams
      # rather than of the directory listing: a downstream project has to be
      # able to write an upgrade test without copying anything out of
      # `test/support`, and `test/support` is compiled only in `:test` and
      # packaged nowhere.
      for module <- [Forecastle.Deployment, Forecastle.UpgradeCase] do
        source = List.to_string(module.module_info(:compile)[:source])

        assert source =~ ~r"(^|/)lib/forecastle/", "#{inspect(module)} is compiled from #{source}"
        refute source =~ ~r"(^|/)test/", "#{inspect(module)} is compiled from #{source}"
      end
    end

    test "and lib is what the package ships" do
      assert "lib" in Mix.Project.config()[:package][:files]
    end
  end

  # A release-shaped tree, and the archive of it that `tar:` names. Small enough
  # to build per test, which is what keeps each case independent of what the last
  # one deployed.
  defp release_tree(_ctx) do
    dir = Path.join(@root, "source")
    tree = Path.join(dir, "my_app")

    File.rm_rf!(@root)
    File.mkdir_p!(Path.join(tree, "releases/1.0.0"))
    File.mkdir_p!(Path.join(tree, "lib/my_app-1.0.0/ebin"))
    File.mkdir_p!(Path.join(tree, "bin"))

    File.write!(Path.join(tree, "bin/my_app"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(tree, "bin/my_app"), 0o755)
    File.write!(Path.join(tree, "releases/start_erl.data"), "16.2 1.0.0")

    rel_path = Path.join(tree, "releases/1.0.0/my_app")
    write_rel!(rel_path <> ".rel")

    tarball = tar_up!(tree, Path.join(dir, "my_app-1.0.0.tar.gz"))

    # The baseline cache is deliberately left alone. It is content-keyed and
    # nothing here writes into it - which is the thing one of these tests exists
    # to assert - so an entry left behind is a cache hit for the next run rather
    # than rubbish, and clearing a directory other suites resolve into would be
    # reaching outside this one.
    on_exit(fn -> File.rm_rf!(@root) end)

    {:ok, tree: tree, rel_path: rel_path, tarball: tarball}
  end

  # A launcher that answers `pid` with whatever the deployment carries, and a
  # `bin/castle` with the given body. Between them they are enough to drive
  # `install_supervised/3` through every answer it has to tell apart, with no
  # release and no node.
  defp stubbed!(tree, pid, castle_body) do
    stub!(tree, "my_app", ~s|[ "$1" = "pid" ] && echo "$STUB_PID"\nexit 0\n|)
    stub!(tree, "castle", castle_body)

    Deployment.new(tree, "my_app", env: [{"STUB_PID", pid}])
  end

  # A launcher and a `bin/castle` that each report which of the two ran and with
  # what, so a call reaching the wrong program is a failed comparison rather than
  # an indistinguishable success.
  defp echoing!(tree) do
    stub!(tree, "my_app", ~s|echo "my_app: $*"\n|)
    stub!(tree, "castle", ~s|echo "castle: $*"\n|)

    Deployment.new(tree, "my_app")
  end

  defp refusing!(tree) do
    stub!(tree, "my_app", ~s|echo refused\nexit 7\n|)
    stub!(tree, "castle", ~s|echo refused\nexit 7\n|)

    Deployment.new(tree, "my_app")
  end

  # A destination that already holds a deployment: the `.rel` that says which
  # release is in it, and a launcher that answers `pid` however the case wants.
  defp occupied!(into, name, launcher_body) do
    File.mkdir_p!(Path.join(into, "bin"))
    File.mkdir_p!(Path.join(into, "releases/1.0.0"))
    write_rel!(Path.join(into, "releases/1.0.0/#{name}.rel"))
    stub!(into, name, launcher_body)

    into
  end

  defp stub!(tree, name, body) do
    path = Path.join(tree, "bin/#{name}")

    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  # An operating system process that is alive now and gone in about a second,
  # which is what a reboot looks like from outside. Its output is detached so
  # that `System.cmd/3` returns as soon as the shell that started it does.
  defp transient_pid do
    {out, 0} = System.cmd("sh", ["-c", "sleep 1 >/dev/null 2>&1 & echo $!"])

    String.trim(out)
  end

  # Named members rather than a `cd` into the tree, because `:erl_tar.create/3`
  # otherwise resolves its file list against the working directory - which this
  # suite must not move.
  defp tar_up!(tree, tarball) do
    File.rm(tarball)
    members = for entry <- ~w(bin lib releases), do: {~c"#{entry}", ~c"#{Path.join(tree, entry)}"}
    :ok = :erl_tar.create(to_charlist(tarball), members, [:compressed])

    tarball
  end

  # A real release term, because a version directory can hold more than one
  # `.rel` and telling them apart is done by reading them.
  defp write_rel!(path) do
    term = {:release, {~c"my_app", ~c"1.0.0"}, {:erts, ~c"16.2"}, [{:kernel, ~c"10.3"}]}

    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term]))
  end
end
