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
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @moduletag :e2e

  @from "0.1.0"
  @to "0.1.1"

  setup_all do
    workspace = Fixture.workspace()
    relup = Path.join(workspace, "relup")

    deploy = assemble!(into: "deploy", vsn: @from)
    next = assemble!(into: "next", vsn: @to)

    make_relup!(deploy, next)
    # Reassemble so that post-assembly copies the relup into the release, and
    # the tarball we are about to hand to release_handler contains it.
    ^next = assemble!(into: "next", vsn: @to)

    File.cp!(
      Path.join(next, "sample-#{@to}.tar.gz"),
      Path.join(deploy, "releases/sample-#{@to}.tar.gz")
    )

    on_exit(fn ->
      cmd(Path.join(deploy, "bin/sample"), ["stop"])
      File.rm(relup)
    end)

    start!(deploy)

    booted = %{
      greeting: rpc!(deploy, "IO.puts(Sample.greeting())"),
      env_marker: rpc!(deploy, "IO.puts(Sample.env_marker())"),
      release_env: rpc!(deploy, "IO.puts(inspect(Sample.release_env()))"),
      counter: rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
      os_pid: launcher!(deploy, ["pid"]),
      releases: castle!(deploy, ["releases"]),
      releases_file?: File.exists?(Path.join(deploy, "releases/RELEASES")),
      dep_lib: rpc!(deploy, "IO.puts(:code.lib_dir(:sample_dep))")
    }

    "3" =
      rpc!(deploy, "IO.puts(Enum.map(1..3, fn _ -> Sample.Counter.bump() end) |> List.last())")

    unpacked = %{
      output: castle!(deploy, ["unpack", @to]),
      releases: castle!(deploy, ["releases"]),
      releases_file?: File.exists?(Path.join(deploy, "releases/RELEASES"))
    }

    installed = %{output: castle!(deploy, ["install", @to])}

    installed =
      Map.merge(installed, %{
        counter: rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
        os_pid: launcher!(deploy, ["pid"]),
        greeting: rpc!(deploy, "IO.puts(Sample.greeting())"),
        releases: castle!(deploy, ["releases"]),
        dep_lib: rpc!(deploy, "IO.puts(:code.lib_dir(:sample_dep))")
      })

    committed = %{output: castle!(deploy, ["commit"])}

    committed =
      Map.merge(committed, %{
        releases: castle!(deploy, ["releases"]),
        version: launcher!(deploy, ["version"]),
        start_erl: File.read!(Path.join(deploy, "releases/start_erl.data"))
      })

    {:ok,
     deploy: deploy,
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
      assert booted.release_env =~ ~s(release_node: "sample")
      assert booted.release_env =~ "release_cookie_set: true"
      assert booted.release_env =~ ~s(release_mode: "embedded")
      assert booted.release_env =~ ~r/release_tmp: "[^"]+\/tmp"/
      assert booted.release_env =~ ~r/release_vm_args: "[^"]+\/vm\.args"/
    end

    test "starts the version that was built", %{booted: booted} do
      assert booted.counter == ~s({"#{@from}", 0})
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
      vsn = deploy |> Path.join("releases/start_erl.data") |> File.read!() |> vsn_of()

      File.cp!(
        Path.join(deploy, "releases/#{vsn}/vm.args"),
        Path.join(workspace, "relative.vm.args")
      )

      on_exit(fn -> File.rm(Path.join(workspace, "relative.vm.args")) end)

      # cmd/4 runs in the workspace, which is not the release root, so this only
      # resolves if nothing changed directory on the way to starting the VM.
      assert {output, 0} =
               cmd(Path.join(deploy, "bin/sample"), ["eval", "IO.puts(:evaluated)"], [
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
      assert installed.counter =~ ~s("#{@to}")
    end

    test "preserves the state of the running process", %{installed: installed} do
      assert installed.counter == ~s({"#{@to}", 3})
    end

    test "does not restart the VM", %{booted: booted, installed: installed} do
      assert installed.os_pid == booted.os_pid
    end

    test "resolved the target's configuration in a peer", %{deploy: deploy} do
      # The release has no build.config, which is what sends Castle down the
      # peer path: it keeps what Mix wrote as sys.config.pristine, boots a VM on
      # the target's own preboot script to run the target's own providers, and
      # renames the result over sys.config with a line saying it did.
      version_path = Path.join(deploy, "releases/#{@to}")

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
      assert Path.wildcard(Path.join(deploy, "releases/*/castle-*")) == []
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

  defp make_relup!(from, to) do
    # No --outdir: the relup is wanted in the workspace, which is where
    # post-assembly looks for one. The task exits non-zero if it could not
    # generate it, so `mix!` raising is what rules out a relup left over from
    # an earlier run satisfying the assertions below.
    relup = Path.join(Fixture.workspace(), "relup")

    mix!(
      [
        "forecastle.relup",
        "--target",
        Path.join(to, "releases/#{@to}/sample"),
        "--fromto",
        Path.join(from, "releases/#{@from}/sample")
      ],
      [{"SAMPLE_VSN", @to}, {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{@to}")}]
    )

    assert File.exists?(relup), "mix forecastle.relup did not produce a relup"

    # And that it is a plan between these two versions, not merely a file.
    contents = File.read!(relup)
    assert contents =~ ~s("#{@to}"), "relup does not target #{@to}:\n\n#{contents}"
    assert contents =~ ~s("#{@from}"), "relup has no path from #{@from}:\n\n#{contents}"
  end

  defp start!(deploy) do
    launcher!(deploy, ["daemon"], [{"SAMPLE_GREETING", "hello-from-runtime"}])
    await_boot!(deploy, 100)
  end

  defp await_boot!(deploy, 0) do
    flunk("#{deploy} did not accept an rpc within the timeout")
  end

  defp await_boot!(deploy, attempts) do
    case cmd(Path.join(deploy, "bin/sample"), ["rpc", "IO.puts(:booted)"]) do
      {_output, 0} -> :ok
      {_output, _} -> Process.sleep(200) && await_boot!(deploy, attempts - 1)
    end
  end

  defp launcher!(deploy, args, env \\ []) do
    deploy |> Path.join("bin/sample") |> cmd!(args, env) |> String.trim()
  end

  defp castle!(deploy, args, env \\ []) do
    deploy |> Path.join("bin/castle") |> cmd!(args, env) |> String.trim()
  end

  defp rpc!(deploy, expression), do: launcher!(deploy, ["rpc", expression])

  # start_erl.data is "<erts vsn> <release vsn>".
  defp vsn_of(start_erl_data), do: start_erl_data |> String.split() |> List.last()
end
