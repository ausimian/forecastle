defmodule Forecastle.RelupTest do
  @moduledoc """
  Drives `mix forecastle.relup` against two really-assembled releases.

  Generating a relup needs two releases on disk, each with its `.rel` file and
  the `.appup` that carries the upgrade instructions, so there is no smaller
  fixture for this than a pair of real assemblies. The task is run as a command
  rather than through `run/1` because half of what is under test is the exit
  status a build pipeline sees, and Mix does not derive that from what a task
  returns.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # A relup names its versions as charlists, and only a literal can stand in the
  # pattern that reads one back.
  @from_vsn to_charlist(@from)
  @to_vsn to_charlist(@to)

  # Relative, so that the task is also shown resolving it against the working
  # directory rather than anything of its own choosing.
  @outdir "relups"

  setup_all do
    {:ok,
     from: assemble!(into: "relup-from", vsn: @from), to: assemble!(into: "relup-to", vsn: @to)}
  end

  setup do
    # The workspace is the working directory of every fixture command, and it is
    # where post-assembly picks a relup up from. The assembly and upgrade suites
    # each put one there and take it away again, and so does this one: the
    # workspace is memoised and shared with every other test in the run.
    cwd_relup = Path.join(Fixture.workspace(), "relup")
    outdir = Path.join(Fixture.workspace(), @outdir)

    File.rm(cwd_relup)
    File.rm_rf!(outdir)
    File.mkdir_p!(outdir)

    on_exit(fn ->
      File.rm(cwd_relup)
      File.rm_rf!(outdir)
    end)

    {:ok, cwd_relup: cwd_relup, relup: Path.join(outdir, "relup")}
  end

  describe "generating a relup somewhere other than the working directory" do
    test "writes it into the directory --outdir names", ctx do
      relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert File.exists?(ctx.relup)
    end

    test "writes nothing into the working directory", ctx do
      # `--outdir` used to be parsed and then dropped, so the relup landed here
      # regardless - overwriting whatever unrelated relup was already in it.
      relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      refute File.exists?(ctx.cwd_relup)
    end

    test "writes an upgrade plan between the two releases", ctx do
      relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(ctx.relup))
    end
  end

  describe "a generation that fails" do
    test "exits non-zero, saying what could not be done", ctx do
      # Backwards: 0.1.0's appup says nothing about coming from 0.1.1, which is
      # what a project that has not written the instructions yet looks like.
      {output, status} =
        relup(["--target", rel(ctx.from, @from), "--fromto", rel(ctx.to, @to)], @from)

      assert status != 0, "a failed generation reported success:\n\n#{output}"
      assert output =~ "No release upgrade script entry for sample-#{@from} to sample-#{@to}"
    end

    test "does not let an earlier run's relup pass for the one asked for", ctx do
      File.write!(ctx.cwd_relup, "%% stale\n")

      {_output, status} =
        relup(["--target", rel(ctx.from, @from), "--fromto", rel(ctx.to, @to)], @from)

      # The task does not remove a file it did not write, so the relup a
      # previous run left behind is still sitting where post-assembly looks for
      # one. The exit status is the only thing standing between it and being
      # packaged as this version's upgrade plan.
      assert status != 0
      assert File.read!(ctx.cwd_relup) == "%% stale\n"
    end
  end

  describe "arguments the task does not recognise" do
    test "are refused rather than discarded", ctx do
      # Both of these were silently dropped, and the relup then generated from
      # whatever was left: a plan between releases the caller had not named.
      {output, status} =
        relup(["--target", rel(ctx.to, @to), "--fromtoo", rel(ctx.from, @from)], @to)

      assert status != 0, "an unrecognised switch was accepted:\n\n#{output}"
      assert output =~ ~s(Unrecognised arguments: "--fromtoo")

      {output, status} = relup(["--target", rel(ctx.to, @to), rel(ctx.from, @from)], @to)

      assert status != 0, "a stray path was accepted:\n\n#{output}"
      assert output =~ "Unrecognised arguments:"
    end

    test "include no --target at all", ctx do
      {output, status} = relup(["--fromto", rel(ctx.from, @from)], @to)

      # Not merely non-zero: a missing --target used to be a KeyError from the
      # middle of the task, which is a bug report rather than a usage message.
      assert status != 0
      assert output =~ "** (Mix) --target is required"
    end
  end

  describe "warnings from systools" do
    test "still reach the shell", ctx do
      # `silent` is what makes the outcome inspectable, and it also stops
      # systools printing its own diagnostics. Warnings have to be passed on
      # instead of dropped: an ERTS version change arrives as one, and an
      # upgrade that silently needs the emulator restarted is worth hearing
      # about. `bad_vsn` is the cheapest of them to provoke - an appup whose
      # own version tag no longer matches the application it sits beside.
      mistag_appup(ctx)

      assert relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to) =~ "*WARNING* {bad_vsn"
      assert File.exists?(ctx.relup), "a warning is not a failure"
    end
  end

  # The appup in the assembled tree, not the fixture's source: this suite owns
  # the releases it assembled, and the source is shared with every other suite.
  # Restored anyway, since the trees are reused across tests in this module.
  defp mistag_appup(ctx) do
    appup = Path.join(ctx.to, "lib/sample-#{@to}/ebin/sample.appup")
    original = File.read!(appup)
    on_exit(fn -> File.write!(appup, original) end)

    mistagged = String.replace(original, ~s("#{@to}"), ~s("9.9.9"), global: false)
    assert mistagged != original, "could not find the appup's version tag in #{appup}"

    File.write!(appup, mistagged)
  end

  defp upgrade(ctx), do: ["--target", rel(ctx.to, @to), "--fromto", rel(ctx.from, @from)]

  defp rel(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  defp relup(args, vsn), do: mix(["forecastle.relup" | args], env(vsn))

  defp relup!(args, vsn), do: mix!(["forecastle.relup" | args], env(vsn))

  # The task builds nothing, but Mix still loads the project around it. Pointing
  # it at the build tree the target release was assembled in keeps it from
  # creating another one, which is what the upgrade suite does too.
  defp env(vsn) do
    [{"SAMPLE_VSN", vsn}, {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{vsn}")}]
  end
end
