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
      releases: castle!(deploy, ["releases"])
    }

    "3" =
      rpc!(deploy, "IO.puts(Enum.map(1..3, fn _ -> Sample.Counter.bump() end) |> List.last())")

    unpacked = %{
      output: castle!(deploy, ["unpack", @to]),
      releases: castle!(deploy, ["releases"])
    }

    installed = %{output: castle!(deploy, ["install", @to])}

    installed =
      Map.merge(installed, %{
        counter: rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
        os_pid: launcher!(deploy, ["pid"]),
        greeting: rpc!(deploy, "IO.puts(Sample.greeting())")
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
    test "expands runtime configuration before the system starts", %{booted: booted} do
      assert booted.greeting == "hello-from-runtime"
    end

    test "runs the project's own env.sh before expanding configuration", %{booted: booted} do
      assert booted.env_marker == "preserved"
    end

    test "creates the RELEASES file regardless of the working directory",
         %{deploy: deploy} do
      # The launcher was invoked from the workspace, not the release root.
      assert File.exists?(Path.join(deploy, "releases/RELEASES"))
    end

    test "gives runtime.exs the release variables the launcher would have set",
         %{booted: booted} do
      # env.sh is sourced before the launcher assigns these, so the integration
      # has to apply their defaults itself. runtime.exs fetches them with
      # fetch_env!, so a regression here fails the boot outright - these
      # assertions pin the values it should be seeing.
      assert booted.release_env =~ ~s(release_node: "sample")
      assert booted.release_env =~ "release_cookie_set: true"
      assert booted.release_env =~ ~s(release_mode: "embedded")
      assert booted.release_env =~ ~r/release_tmp: "[^"]+\/tmp"/
      assert booted.release_env =~ ~r/release_vm_args: "[^"]+\/vm\.args"/
    end

    test "reports the release as permanent", %{booted: booted} do
      assert booted.releases =~ ~r/#{@from}\s+permanent/
    end

    test "starts the version that was built", %{booted: booted} do
      assert booted.counter == ~s({"#{@from}", 0})
    end
  end

  describe "the working directory the preboot VM runs in" do
    # The fragment must not move the preboot VM out of the directory the
    # launcher was invoked from, or a relative RELEASE_VM_ARGS - and any
    # relative path the configuration itself reads - resolves against the
    # release root instead. Only make_releases/0 needs the root.
    test "is the caller's, so a relative RELEASE_VM_ARGS still resolves",
         %{deploy: deploy} do
      workspace = Fixture.workspace()
      vsn = deploy |> Path.join("releases/start_erl.data") |> File.read!() |> vsn_of()

      File.cp!(
        Path.join(deploy, "releases/#{vsn}/vm.args"),
        Path.join(workspace, "relative.vm.args")
      )

      on_exit(fn -> File.rm(Path.join(workspace, "relative.vm.args")) end)

      # cmd/4 runs in the workspace, which is not the release root, so this
      # only resolves if the preboot VM stayed there too.
      assert {output, 0} =
               cmd(Path.join(deploy, "bin/sample"), ["eval", "IO.puts(:evaluated)"], [
                 {"RELEASE_VM_ARGS", "relative.vm.args"}
               ]),
             "eval with a relative RELEASE_VM_ARGS failed"

      assert output =~ "evaluated"
    end

    test "still lets make_releases find the RELEASES file", %{deploy: deploy} do
      assert File.exists?(Path.join(deploy, "releases/RELEASES"))
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
  end

  describe "installing" do
    test "reports the version change", %{installed: installed} do
      assert installed.output =~ "Now running #{@to} (previously #{@from})."
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

    test "keeps the configuration that was expanded at boot", %{installed: installed} do
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
