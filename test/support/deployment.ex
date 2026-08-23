defmodule Forecastle.Deployment do
  @moduledoc """
  Drives an assembled fixture release from outside: generates a relup between
  two of them, starts one as a daemon, waits for it to answer, and runs the
  stock launcher, `bin/castle` and `rpc` against it.

  These started life as private functions in the upgrade suite. They are here
  because more than one suite needs them now, and because the emulator-restart
  work ([#10](https://github.com/ausimian/forecastle/issues/10)) will need them
  too. They know the fixture by name - `bin/sample`, `SAMPLE_VSN` - which is the
  same thing `Forecastle.ReleaseCase.assemble!/1` already does.

  Deliberately *not* imported by `use Forecastle.ReleaseCase`: `castle!/3` here
  runs `bin/castle` against a real release, and `castle_cli_test.exs` has a
  private function of the same name that runs it against a launcher stub. A
  suite says which of the two it means by importing this module or not.
  """

  import ExUnit.Assertions

  alias Forecastle.Fixture

  # How long `daemon` itself is given to return. Generous, because on a first
  # start it sources `env.sh`, which runs a preboot VM to create
  # `releases/RELEASES` and waits for it.
  @start_timeout 180_000

  @doc """
  Generates a relup between two assembled releases, into the workspace.

  `from` and `to` are `{path, version}` pairs. `extra_args` is appended to the
  task's arguments, which is where an upgrade strategy switch goes.

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

    Fixture.mix!(
      ["forecastle.relup" | args ++ extra_args],
      [{"SAMPLE_VSN", to_vsn}, {"MIX_BUILD_ROOT", Path.join(workspace, "_build-#{to_vsn}")}]
    )

    assert File.exists?(relup), "mix forecastle.relup did not produce a relup"

    # And that it is a plan between these two versions, not merely a file.
    contents = File.read!(relup)
    assert contents =~ ~s("#{to_vsn}"), "relup does not target #{to_vsn}:\n\n#{contents}"
    assert contents =~ ~s("#{from_vsn}"), "relup has no path from #{from_vsn}:\n\n#{contents}"

    relup
  end

  @doc """
  Starts an assembled release as a daemon and waits for it to answer.

  Returns what the launcher printed, which is how a suite gets at what `env.sh`
  said on the way past - the two streams merged, the way `Forecastle.Fixture`
  merges them. `launcher!/3` raises if the start itself failed, so a caller that
  ignores the return value still gets that.

  **The launcher is given a deadline, and that is not belt-and-braces.** A boot
  that hangs is a real failure mode of what this suite covers - two `-heart`
  flags leave `heart:check_start_heart/0` with no clause for `{ok, [[], []]}` and
  the node never finishes starting, having printed nothing - and it hangs
  *inside* `daemon` rather than after it, because `env.sh` runs a preboot VM
  synchronously on a first start and that VM inherits the same options.
  `System.cmd/3` has no deadline of its own and `setup_all` has no ExUnit
  timeout, so without this a regression in the `-heart` guard stops the suite for
  as long as whatever is running it will wait. Measured, by putting the guard
  back the way it was.
  """
  def start!(deploy, env \\ []) do
    started = Task.async(fn -> launcher!(deploy, ["daemon"], env) end)

    output =
      case Task.yield(started, @start_timeout) do
        {:ok, output} -> output
        _no_answer -> abandoned!(started, deploy)
      end

    await_boot!(deploy)
    output
  end

  defp abandoned!(started, deploy) do
    Task.shutdown(started, :brutal_kill)

    flunk(
      "#{deploy} did not finish starting within #{div(@start_timeout, 1000)}s. " <>
        "A launcher that never returns is a boot that hung rather than one that " <>
        "failed, and the usual cause is the VM being given two -heart flags: " <>
        "init:get_argument(heart) reports {ok, [[], []]}, which heart's own " <>
        "startup check has no clause for. Nothing is printed when that happens, " <>
        "so there is no output to report here."
    )
  end

  @doc """
  The operating system pid of the running release, as the release reports it.

  `bin/<name> pid` is an rpc, so this is the beam's own `System.pid/0` rather
  than anything about the process that asked - which is what makes it usable
  both for telling one incarnation of the node from another and for waiting on
  the first to go away.
  """
  def os_pid(deploy), do: launcher!(deploy, ["pid"])

  @doc """
  Waits until the operating system process `pid` is gone, or fails the test.

  Asked of the operating system rather than of the node: a node that has stopped
  answering rpc is not necessarily a process that has exited, and starting the
  replacement while the old beam still holds the distribution port is how a
  supervised restart turns into a name clash instead of a boot.
  """
  def await_exit!(pid, attempts \\ 300)

  def await_exit!(pid, 0), do: flunk("process #{pid} was still running at the timeout")

  def await_exit!(pid, attempts) do
    case System.cmd("ps", ["-o", "pid=", "-p", pid], stderr_to_stdout: true) do
      {_output, 0} -> Process.sleep(100) && await_exit!(pid, attempts - 1)
      {_output, _} -> :ok
    end
  end

  @doc """
  Installs `vsn` through `bin/castle` while acting as the release's supervisor.

  A transition that restarts the emulator reboots the node, and nothing inside
  the release starts it again - that is the whole design: `bin/start` is inert
  and systemd, Docker or runit owns the restart. So the test has to be the
  supervisor. `bin/castle install` is run in a task, because it keeps asking the
  system what it is running until the version it installed answers; this waits
  for the old process to go, starts the release again, and then collects what the
  install made of it.

  Returns `{output, status}`, with the two streams merged the way
  `Forecastle.Fixture.cmd/4` merges them.
  """
  def install_supervised!(deploy, vsn, env \\ []) do
    pid = os_pid(deploy)
    castle = Path.join(deploy, "bin/castle")

    installing = Task.async(fn -> Fixture.cmd(castle, ["install", vsn], env) end)

    await_exit!(pid)
    start!(deploy, env)

    Task.await(installing, 300_000)
  end

  @doc "Waits until the release accepts an rpc, or fails the test."
  def await_boot!(deploy, attempts \\ 100)

  def await_boot!(deploy, 0) do
    flunk("#{deploy} did not accept an rpc within the timeout")
  end

  def await_boot!(deploy, attempts) do
    case Fixture.cmd(Path.join(deploy, "bin/sample"), ["rpc", "IO.puts(:booted)"]) do
      {_output, 0} -> :ok
      {_output, _} -> Process.sleep(200) && await_boot!(deploy, attempts - 1)
    end
  end

  @doc "Runs the stock Mix launcher against an assembled release."
  def launcher!(deploy, args, env \\ []) do
    deploy |> Path.join("bin/sample") |> Fixture.cmd!(args, env) |> String.trim()
  end

  @doc "Runs `bin/castle` against an assembled release."
  def castle!(deploy, args, env \\ []) do
    deploy |> Path.join("bin/castle") |> Fixture.cmd!(args, env) |> String.trim()
  end

  @doc "Evaluates an expression in the running release."
  def rpc!(deploy, expression, env \\ []), do: launcher!(deploy, ["rpc", expression], env)

  @doc "The release version out of a `start_erl.data`, which is `<erts vsn> <release vsn>`."
  def vsn_of(start_erl_data), do: start_erl_data |> String.split() |> List.last()

  defp rel_path(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")
end
