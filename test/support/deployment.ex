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

  @doc "Starts an assembled release as a daemon and waits for it to answer."
  def start!(deploy, env \\ []) do
    launcher!(deploy, ["daemon"], env)
    await_boot!(deploy)
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
