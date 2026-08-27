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

  describe "installing while acting as the supervisor" do
    setup :release_tree

    test "reports what an install that never rebooted said", ctx do
      # The failure this used to swallow. `bin/castle install` polls the system
      # for the version it installed and cannot be answered until the release is
      # started again, which is this function's job and happens afterwards - so
      # an install that has already exited has exited about a failure, and it is
      # holding the only account of it. Waiting on the process alone spent thirty
      # seconds and then reported that a process was still running.
      #
      # The stubs are what make this assertable without a release: a launcher
      # that answers `pid` with this VM's own operating system process, which is
      # certainly alive, and a `bin/castle` that refuses the way Castle would.
      File.write!(Path.join(ctx.tree, "bin/castle"), """
      #!/bin/sh
      echo "Nothing to install: 1.1.0 has not been unpacked."
      exit 3
      """)

      File.chmod!(Path.join(ctx.tree, "bin/castle"), 0o755)

      File.write!(Path.join(ctx.tree, "bin/my_app"), """
      #!/bin/sh
      [ "$1" = "pid" ] && echo "$STUB_PID"
      exit 0
      """)

      File.chmod!(Path.join(ctx.tree, "bin/my_app"), 0o755)

      deployment =
        Deployment.new(ctx.tree, "my_app", env: [{"STUB_PID", System.pid()}])

      assert_raise ExUnit.AssertionError, ~r/Nothing to install/, fn ->
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

    tarball = Path.join(dir, "my_app-1.0.0.tar.gz")
    members = for entry <- ~w(bin lib releases), do: {~c"#{entry}", ~c"#{Path.join(tree, entry)}"}
    :ok = :erl_tar.create(to_charlist(tarball), members, [:compressed])

    # The baseline cache is deliberately left alone. It is content-keyed and
    # nothing here writes into it - which is the thing one of these tests exists
    # to assert - so an entry left behind is a cache hit for the next run rather
    # than rubbish, and clearing a directory other suites resolve into would be
    # reaching outside this one.
    on_exit(fn -> File.rm_rf!(@root) end)

    {:ok, tree: tree, rel_path: rel_path, tarball: tarball}
  end

  # A real release term, because a version directory can hold more than one
  # `.rel` and telling them apart is done by reading them.
  defp write_rel!(path) do
    term = {:release, {~c"my_app", ~c"1.0.0"}, {:erts, ~c"16.2"}, [{:kernel, ~c"10.3"}]}

    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term]))
  end
end
