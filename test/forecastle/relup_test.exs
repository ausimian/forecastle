defmodule Forecastle.RelupTest do
  @moduledoc """
  Drives `mix forecastle.relup` against two really-assembled releases.

  Generating a relup needs two releases on disk, each with its `.rel` file and
  the `.appup` that carries the upgrade instructions, so there is no smaller
  fixture for this than a pair of real assemblies. The task is run as a command
  rather than through `run/1` because half of what is under test is the exit
  status a build pipeline sees, and Mix does not derive that from what a task
  returns.

  The three upgrade strategies are covered here too. Two of them need a release
  the others do not: `auto` only reaches `:systools` when every application whose
  version moved is one the project owns, and the fixture's dependency otherwise
  moves with it, so there is a third assembly with that dependency pinned. What
  cannot be assembled at all is a second ERTS, so the transitions that turn on
  an ERTS change are made by rewriting a `.rel` file - which is the only thing
  the task has to go on for that decision, and, for those transitions, the only
  thing anything reads.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # A release whose only moving part is the project's own application:
  # `SAMPLE_DEP_VSN` pins the fixture's dependency at the version `@from` has, so
  # that `auto` judges the transition from `@from` hot and asks `:systools` for
  # it. Every other suite builds the fixture without that variable.
  @hot "0.1.2"

  # A relup names its versions as charlists, and only a literal can stand in the
  # pattern that reads one back.
  @from_vsn to_charlist(@from)
  @to_vsn to_charlist(@to)
  @hot_vsn to_charlist(@hot)

  # Relative, so that the task is also shown resolving it against the working
  # directory rather than anything of its own choosing.
  @outdir "relups"

  setup_all do
    {:ok,
     from: assemble!(into: "relup-from", vsn: @from),
     to: assemble!(into: "relup-to", vsn: @to),
     hot: assemble!(into: "relup-hot", vsn: @hot, env: [{"SAMPLE_DEP_VSN", @from}])}
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
      relup!(hot(ctx) ++ ["--outdir", @outdir], @to)

      assert File.exists?(ctx.relup)
    end

    test "writes nothing into the working directory", ctx do
      # `--outdir` used to be parsed and then dropped, so the relup landed here
      # regardless - overwriting whatever unrelated relup was already in it.
      relup!(hot(ctx) ++ ["--outdir", @outdir], @to)

      refute File.exists?(ctx.cwd_relup)
    end

    test "writes an upgrade plan between the two releases", ctx do
      relup!(hot(ctx) ++ ["--outdir", @outdir], @to)

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(ctx.relup))
    end
  end

  describe "a generation that fails" do
    test "exits non-zero, saying what could not be done", ctx do
      # Backwards: 0.1.0's appup says nothing about coming from 0.1.1, which is
      # what a project that has not written the instructions yet looks like.
      # `--hot`, because `auto` would make this transition a restart - the
      # fixture's dependency moves with it - and never ask for an appup at all.
      {output, status} =
        relup(["--target", rel(ctx.from, @from), "--fromto", rel(ctx.to, @to), "--hot"], @from)

      assert status != 0, "a failed generation reported success:\n\n#{output}"

      # Both of the fixture's applications lack a path back from 0.1.1, and
      # systools reports whichever it reaches first, so which one it names is not
      # the point here. The message and the two versions are.
      assert output =~
               ~r/No release upgrade script entry for \w+-#{Regex.escape(@from)} to \w+-#{Regex.escape(@to)}/
    end

    test "does not let an earlier run's relup pass for the one asked for", ctx do
      File.write!(ctx.cwd_relup, "%% stale\n")

      {_output, status} =
        relup(["--target", rel(ctx.from, @from), "--fromto", rel(ctx.to, @to), "--hot"], @from)

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

    test "include a switch that may be given once, given twice", ctx do
      # `:keep` for these two as well, so that a repeat is an error rather than
      # OptionParser quietly keeping the last one and generating from a target
      # the caller did not ask for.
      {output, status} =
        relup(
          [
            "--target",
            rel(ctx.to, @to),
            "--target",
            rel(ctx.from, @from),
            "--fromto",
            rel(ctx.from, @from)
          ],
          @to
        )

      assert status != 0, "a repeated --target was accepted:\n\n#{output}"
      assert output =~ "--target may be given once"

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir, "--outdir", @outdir], @to)

      assert status != 0, "a repeated --outdir was accepted:\n\n#{output}"
      assert output =~ "--outdir may be given once"
    end

    test "include no --target at all", ctx do
      {output, status} = relup(["--fromto", rel(ctx.from, @from)], @to)

      # Not merely non-zero: a missing --target used to be a KeyError from the
      # middle of the task, which is a bug report rather than a usage message.
      assert status != 0
      assert output =~ "** (Mix) --target is required"
    end

    test "include no from-release at all", ctx do
      {output, status} = relup(["--target", rel(ctx.to, @to)], @to)

      assert status != 0
      assert output =~ "at least one of --fromto, --upfrom or --downto is required"
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

      assert relup!(hot(ctx) ++ ["--outdir", @outdir], @to) =~ "*WARNING* {bad_vsn"
      assert File.exists?(ctx.relup), "a warning is not a failure"
    end
  end

  describe "the strategy switches" do
    test "cannot be combined", ctx do
      {output, status} = relup(upgrade(ctx) ++ ["--hot", "--restart"], @to)

      assert status != 0, "--hot --restart was accepted:\n\n#{output}"
      assert output =~ "--hot and --restart ask for opposite things"
    end

    test "may each be given once", ctx do
      {output, status} = relup(upgrade(ctx) ++ ["--hot", "--hot"], @to)

      assert status != 0, "a repeated --hot was accepted:\n\n#{output}"
      assert output =~ "--hot may be given once, but was given 2 times"

      {output, status} = relup(upgrade(ctx) ++ ["--restart", "--restart"], @to)

      assert status != 0, "a repeated --restart was accepted:\n\n#{output}"
      assert output =~ "--restart may be given once"
    end

    test "are not negatable", ctx do
      # `:count` rather than `:boolean` is what makes this an unrecognised
      # switch. As a boolean it would have parsed, and `--no-hot` would have
      # been a quiet way of asking for something the task never named.
      {output, status} = relup(upgrade(ctx) ++ ["--no-hot"], @to)

      assert status != 0, "--no-hot was accepted:\n\n#{output}"
      assert output =~ ~s(Unrecognised arguments: "--no-hot")
    end
  end

  describe "the auto strategy" do
    test "makes a transition that moved an application the project does not own a restart",
         ctx do
      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert output =~ "auto: chose a restart transition for #{@from}"
      assert output =~ ":sample_dep is a dependency and changed from #{@from} to #{@to}"

      # Which instruction it chose, and what install_release/1 will reply, are
      # in the output on purpose: the two restart instructions differ in that
      # reply, and automation reads it.
      assert output =~ "single restart_emulator instruction"
      assert output =~ "{ok, Vsn, Descr}"

      assert {:ok,
              [
                {@to_vsn, [{@from_vsn, [], [:restart_emulator]}],
                 [{@from_vsn, [], [:restart_emulator]}]}
              ]} = :file.consult(to_charlist(ctx.relup))
    end

    test "makes a transition that changed ERTS a restart, and says which one", ctx do
      # The decision is taken here rather than left to :systools, which inserts
      # restart_new_emulator for an ERTS change - the two-stage transition, which
      # boots a hybrid temporary release and replies {continue_after_restart,
      # ...}. Nothing about the strategy asked for that.
      change_erts!(ctx.from, @from, "0.0.0")

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert output =~ "ERTS changed from 0.0.0 to"

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [:restart_emulator]}], _down}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "generates from the appups when only the project's own applications moved", ctx do
      output = relup!(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert output =~ "auto: every transition in this relup is a hot upgrade."

      assert {:ok, [{@hot_vsn, [{@from_vsn, [], script}], _down}]} =
               :file.consult(to_charlist(ctx.relup))

      assert {:load_object_code, {:sample, @hot_vsn, [Sample.Counter]}} in script
      refute :restart_emulator in script
      refute :restart_new_emulator in script
    end

    test "refuses an appup that asks for the two-stage emulator restart", ctx do
      # The one gap in `auto`, and the reason the generated relup is inspected
      # rather than trusted. The ERTS case is decided before :systools is asked
      # for anything, but an appup can still name the instruction, and then the
      # default strategy would have shipped a transition that replies
      # {continue_after_restart, ...} without anybody choosing it.
      add_appup_instruction!(ctx.hot, @hot, :restart_new_emulator)

      {output, status} = relup(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert status != 0, "a restart_new_emulator relup was accepted:\n\n#{output}"
      assert output =~ "asks for the two-stage emulator restart"
      assert output =~ "restart_new_emulator on the upgrade from #{@from}"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end
  end

  describe "the hot strategy" do
    test "refuses an ERTS change rather than degrading to a restart", ctx do
      change_erts!(ctx.from, @from, "0.0.0")
      File.write!(ctx.cwd_relup, "%% stale\n")

      {output, status} = relup(hot(ctx), @to)

      assert status != 0, "an ERTS change passed for a hot upgrade:\n\n#{output}"
      assert output =~ "changes ERTS from 0.0.0 to"

      # #7 was this task exiting 0 on a failure. The other half of the same
      # promise is that a refusal writes nothing, so the relup already sitting
      # where post-assembly looks is the one that is still there afterwards.
      assert File.read!(ctx.cwd_relup) == "%% stale\n"
    end

    test "refuses an appup that restarts the emulator", ctx do
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      {output, status} = relup(project_only(ctx) ++ ["--hot", "--outdir", @outdir], @hot)

      assert status != 0, "an appup that restarts the emulator passed for hot:\n\n#{output}"
      assert output =~ "the generated relup restarts the emulator"
      assert output =~ "restart_emulator on the upgrade from #{@from}"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end
  end

  describe "the restart strategy" do
    test "makes every transition a single restart_emulator", ctx do
      output = relup!(upgrade(ctx) ++ ["--restart", "--outdir", @outdir], @to)

      assert output =~ "--restart: every transition in this relup is a single restart_emulator"

      assert {:ok,
              [
                {@to_vsn, [{@from_vsn, [], [:restart_emulator]}],
                 [{@from_vsn, [], [:restart_emulator]}]}
              ]} = :file.consult(to_charlist(ctx.relup))
    end

    test "needs no appup at all", ctx do
      # Both of the fixture's applications lose their appup, which is what a
      # project that decided the instructions were not worth maintaining looks
      # like. Nothing reads them on this path - not even for the application the
      # project owns.
      remove_appups!(ctx.to, @to)

      relup!(upgrade(ctx) ++ ["--restart", "--outdir", @outdir], @to)

      assert File.exists?(ctx.relup)

      # And the contrast: the same pair, asked for hot, cannot be generated.
      {output, status} = relup(hot(ctx), @to)
      assert status != 0, "a hot upgrade was generated without appups:\n\n#{output}"
    end

    test "honours the direction switches", ctx do
      relup!(
        ["--target", rel(ctx.to, @to), "--upfrom", rel(ctx.from, @from), "--restart"] ++
          ["--outdir", @outdir],
        @to
      )

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [:restart_emulator]}], []}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "is accepted by assembly, and lands in the release", ctx do
      # No --outdir, so the relup goes where post-assembly looks for one. What
      # this covers is Forecastle.verify_relup!/2 accepting a hand-written
      # restart plan and post-assembly copying it into the version directory.
      #
      # It does not cover the transition. Nothing can perform an
      # emulator-restart upgrade yet - castle#14 and
      # [#10](https://github.com/ausimian/forecastle/issues/10) are what make
      # the reboot come back on the installed version - so this asserts on the
      # relup and the assembled tree and stops there.
      relup!(upgrade(ctx) ++ ["--restart"], @to)

      staged =
        assemble!(into: "relup-restart", vsn: @to)
        |> Path.join("releases/#{@to}/relup")

      assert File.exists?(staged), "the restart relup was not copied into the release"

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [:restart_emulator]}], _down}]} =
               :file.consult(to_charlist(staged))
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

  # Rewritten at the term level rather than textually: a `.rel` is
  # pretty-printed over several lines, and the task consults it, so it has to
  # come back a readable term. The version named here never has to resolve to a
  # real ERTS - every strategy decides what to do about the change before
  # anything would go looking for one.
  defp change_erts!(release, vsn, erts) do
    file = rel(release, vsn) <> ".rel"
    {:ok, [{:release, name_vsn, {:erts, _erts}, apps}]} = consult_and_restore!(file)

    write_term!(file, {:release, name_vsn, {:erts, to_charlist(erts)}, apps})
  end

  defp add_appup_instruction!(release, vsn, instruction) do
    file = Path.join(release, "lib/sample-#{vsn}/ebin/sample.appup")
    {:ok, [{appup_vsn, [{from, up}], down}]} = consult_and_restore!(file)

    write_term!(file, {appup_vsn, [{from, up ++ [instruction]}], down})
  end

  defp remove_appups!(release, vsn) do
    for app <- ~w(sample sample_dep) do
      file = Path.join(release, "lib/#{app}-#{vsn}/ebin/#{app}.appup")
      original = File.read!(file)
      on_exit(fn -> File.write!(file, original) end)
      File.rm!(file)
    end
  end

  defp consult_and_restore!(file) do
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    :file.consult(to_charlist(file))
  end

  defp write_term!(file, term) do
    File.write!(file, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term]))
  end

  defp upgrade(ctx), do: ["--target", rel(ctx.to, @to), "--fromto", rel(ctx.from, @from)]

  defp hot(ctx), do: upgrade(ctx) ++ ["--hot"]

  # The transition `auto` will judge hot: only :sample changed between these two
  # releases, because the third assembly pinned the dependency.
  defp project_only(ctx), do: ["--target", rel(ctx.hot, @hot), "--fromto", rel(ctx.from, @from)]

  defp rel(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  defp relup(args, vsn), do: mix(["forecastle.relup" | args], env(vsn))

  defp relup!(args, vsn), do: mix!(["forecastle.relup" | args], env(vsn))

  # The task builds nothing, but Mix still loads the project around it. Pointing
  # it at the build tree the target release was assembled in keeps it from
  # creating another one, which is what the upgrade suite does too.
  defp env(@hot), do: env_for(@hot) ++ [{"SAMPLE_DEP_VSN", @from}]
  defp env(vsn), do: env_for(vsn)

  defp env_for(vsn) do
    [{"SAMPLE_VSN", vsn}, {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{vsn}")}]
  end
end
