defmodule Forecastle.RelupTest do
  @moduledoc """
  Drives `mix forecastle.relup` against two really-assembled releases.

  Generating a relup needs two releases on disk, each with its `.rel` file and
  the `.appup` that carries the upgrade instructions, so there is no smaller
  fixture for this than a pair of real assemblies. The task is run as a command
  rather than through `run/1` because half of what is under test is the exit
  status a build pipeline sees, and Mix does not derive that from what a task
  returns.

  The three upgrade strategies are covered here too. `auto` classifies each edge
  from the two `.rel` files and from the appups beside the target release, so the
  cases it has to tell apart are made by rewriting one of those. The fixture's
  dependency moves with the sample and its appup covers that move in both
  directions, which is the interesting default; what the tests vary is what that
  appup says, direction by direction. What cannot be assembled at all is a second
  ERTS, so the transitions that turn on an ERTS change are made by rewriting a
  `.rel` file - which is the only thing the task has to go on for that decision,
  and, for those transitions, the only thing anything reads.

  A third assembly pins that dependency with `SAMPLE_DEP_VSN`, which is how a
  transition in which *only* project-owned applications moved gets built. It is
  the target of the tests about appup-supplied instructions, and of the
  split-and-merge test, where it supplies a hot edge to sit beside a restart one.

  Two things here are driven in process rather than as a command, for the same
  reason: the split-and-merge, which the refusal in front of it puts out of the
  task's reach, and publication, whose promise - that a failed run leaves the
  previous relup whole - can only be tested from inside the window in which it
  could be broken.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture
  alias Mix.Tasks.Forecastle.Relup

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
      # `--hot`, because the dependency's appup at 0.1.0 says nothing about it
      # either, so `auto` would classify this edge a restart and refuse it before
      # `:systools` was asked for anything.
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
    test "upgrades an application the project does not own when its appup covers the move",
         ctx do
      # The fixture's dependency moves from 0.1.0 to 0.1.1 and its appup names
      # 0.1.0 in both lists. That is an instruction for this transition, whoever
      # wrote it, so the edge is hot: `auto` restarting it would be refusing an
      # upgrade that is demonstrably feasible, which is what "hot where it can
      # be" cannot mean.
      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert output =~ "auto: every transition in this relup is a hot upgrade."

      assert {:ok, [{@to_vsn, [{@from_vsn, [], up}], [{@from_vsn, [], down}]}]} =
               :file.consult(to_charlist(ctx.relup))

      assert {:load_object_code, {:sample, @to_vsn, [Sample.Counter]}} in up

      for script <- [up, down] do
        refute :restart_emulator in script
        refute :restart_new_emulator in script
      end
    end

    test "matches an appup from-version the way systools_relup matches it", ctx do
      # An appup may name a from-version as a *binary*, and then it is a regular
      # expression: `appup_search_for_version/2` runs it with `re:run/3` and
      # accepts the entry when the whole match is the from-version. Comparing
      # strings would miss this one, and `auto` would restart a transition
      # `:systools` was about to generate perfectly well from the same entry.
      set_dep_appup!(ctx.to, @to, [{"0\\.1\\..*", []}], [{"0\\.1\\..*", []}])

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert output =~ "auto: every transition in this relup is a hot upgrade."

      assert {:ok, [{@to_vsn, [{@from_vsn, [], _up}], [{@from_vsn, [], _down}]}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "refuses an edge it could only restart, naming the application and the gap", ctx do
      # The dependency's appup now says nothing about coming from 0.1.0 in either
      # direction, which is what a dependency that never wrote instructions for
      # this project's transitions looks like. There is no hot upgrade to be had,
      # and a restart transition cannot yet be performed, so `auto` refuses
      # rather than write an upgrade plan that will not install.
      set_dep_appup!(ctx.to, @to, [], [])

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert status != 0, "a restart transition was written by auto:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "auto would make a restart transition of the upgrade from #{@from}"
      assert output =~ "the downgrade to #{@from}"
      assert output =~ ":sample_dep is a dependency and changed from #{@from} to #{@to}"
      assert output =~ "sample_dep.appup has no upgrade instructions from #{@from}"
      assert output =~ "sample_dep.appup has no downgrade instructions to #{@from}"

      # The override is named, because refusing without saying what to do instead
      # would leave a pipeline with no way forward.
      assert output =~ "Pass --restart to generate it anyway"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end

    test "says so when the application has no appup at all", ctx do
      remove_appup!(ctx.to, @to, "sample_dep")

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert status != 0, "a restart transition was written by auto:\n\n#{output}"
      assert output =~ "there is no appup at "
      assert output =~ "sample_dep-#{@to}/ebin/sample_dep.appup"
    end

    test "classifies each direction on its own", ctx do
      # An appup's up and down lists are independent, and a from-version in one
      # need not be in the other. Here the dependency can be upgraded from 0.1.0
      # but not downgraded back to it, so the only correct answer is a hot
      # upgrade and a restart the other way - and it is the *downgrade*, alone,
      # that the refusal names. Classifying the edge once and using the answer
      # for both directions would name both.
      set_dep_appup!(ctx.to, @to, [{~c"#{@from}", []}], [])

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert status != 0, "a restart transition was written by auto:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "auto would make a restart transition of the downgrade to #{@from}"
      assert output =~ "sample_dep.appup has no downgrade instructions to #{@from}"
      refute output =~ "upgrade from #{@from}"
    end

    test "refuses a transition that changed ERTS, whatever the appups say", ctx do
      # An ERTS change is not a hot upgrade under any policy and no appup could
      # make it one, so it is not put to the appups at all - the dependency's
      # appup covers its own move here, and the ERTS change is the whole reason.
      # The decision is also taken before :systools is asked for anything, which
      # inserts restart_new_emulator for an ERTS change: the two-stage
      # transition, which nothing about the strategy asked for.
      change_erts!(ctx.from, @from, "0.0.0")

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert status != 0, "an ERTS change was written as a restart transition:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "auto would make a restart transition of the upgrade from #{@from}"
      assert output =~ "ERTS changed from 0.0.0 to"
      refute output =~ ":sample_dep"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
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
      refute_all_hot(output)
      assert output =~ "asks for the two-stage emulator restart"
      assert output =~ "restart_new_emulator on the upgrade from #{@from}"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end

    test "refuses an appup that asks for the one-stage emulator restart", ctx do
      # The same refusal by another route. A restart_emulator an appup asked for
      # by name is the transition `auto` would have chosen for itself, and it is
      # just as uninstallable, so how the relup came by it makes no difference.
      #
      # Classification cannot see this one: nothing but :sample moves between
      # these two releases, so every edge is classified hot and the restart only
      # exists once :systools has produced a script. That is what the all-hot
      # refutation is here for - announcing the verdict from classification alone
      # had this run report a hot relup and a restart in the same breath, and
      # would have it report both from a run that succeeded once a restart
      # transition can be written.
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      {output, status} = relup(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert status != 0, "an appup-supplied restart was accepted by auto:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "an appup asks for the emulator to be restarted"
      assert output =~ "restart_emulator on the upgrade from #{@from}"
      assert output =~ "--restart"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end

    test "settles the restart it chose without generating the rest of the relup", ctx do
      # Both kinds of restart in one run. 0.1.1 is an edge `auto` classifies as a
      # restart - the dependency moves between it and 0.1.2, whose copy of the
      # dependency's appup covers nothing - while 0.1.0 is a hot edge whose appup
      # then asks for the emulator to be restarted by name.
      #
      # While a classified restart is refused, that classification is already the
      # whole answer: the run fails whatever the hot half turns out to be. So it
      # is settled first and the hot half is never generated, which is why the
      # appup's own restart goes unmentioned - it is reported by the run that
      # follows, once the classified edge is gone. This test used to assert both
      # in one refusal, which is what put generation in front of a decision that
      # had already been made; when the refusal becomes an announcement the run
      # proceeds and the two are named together again.
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      {output, status} =
        relup(project_only(ctx) ++ ["--upfrom", rel(ctx.to, @to), "--outdir", @outdir], @hot)

      assert status != 0, "a relup with two kinds of restart in it was accepted:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "auto would make a restart transition of the upgrade from #{@to}"
      assert output =~ "sample_dep.appup has no upgrade instructions from #{@to}"
      refute output =~ "an appup asks for the emulator to be restarted"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end

    test "refuses the restart it chose rather than a systools error from the rest", ctx do
      # The same mixed plan, with a hot half that cannot be generated at all.
      # :sample is the project's own application, so classification never reads
      # its appup and the 0.1.0 edge is still classified hot - and :systools then
      # has nothing to generate that transition from.
      remove_appup!(ctx.hot, @hot, "sample")

      # The control, which is what makes the refutation below mean anything: the
      # hot half of that plan, on its own, really does fail in :systools.
      {control, status} = relup(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert status != 0, "the hot half was generated without an appup:\n\n#{control}"
      assert control =~ "sample-#{@hot}/ebin/sample.appup"

      {output, status} =
        relup(project_only(ctx) ++ ["--upfrom", rel(ctx.to, @to), "--outdir", @outdir], @hot)

      # The restart on the 0.1.1 edge is the reason this run cannot succeed, and
      # it is what the user is shown. Generating first reported the systools error
      # instead - an error about the other half of the relup, in front of a
      # refusal that was already known - and fixing it only uncovered this
      # refusal on the next run.
      assert status != 0, "a mixed relup with an ungeneratable half was accepted:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "auto would make a restart transition of the upgrade from #{@to}"
      assert output =~ "sample_dep.appup has no upgrade instructions from #{@to}"

      refute output =~ "sample-#{@hot}/ebin/sample.appup",
             "a systools error preempted the restart refusal:\n\n#{output}"

      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end
  end

  describe "merging hot and restart transitions into one relup" do
    # `auto` is the only strategy that splits a relup's edges by class and merges
    # the two kinds back together, and while a restart transition cannot be
    # performed it refuses to emit one - so the merge is not reachable through the
    # task. It is still the defining behaviour, and the one place an edge could be
    # dropped, or attached to the wrong direction, or one class's script applied
    # to the whole relup. So it is driven directly, in process, past the refusal
    # that sits in front of it. This is the test that has to keep working when
    # that refusal is flipped back to an announcement.
    #
    # 0.1.2 is the target: 0.1.0 is a hot edge to it (only :sample moved, since
    # this assembly pins the dependency) and 0.1.1 is declared a restart edge,
    # which is what `auto` would classify it as - the dependency moves, and
    # 0.1.2's copy of it says nothing about coming from 0.1.1.
    setup ctx do
      {:ok,
       plan:
         Relup.plan_transitions!(
           rel(ctx.hot, @hot),
           [rel(ctx.from, @from)],
           [rel(ctx.from, @from)],
           [rel(ctx.to, @to)],
           [rel(ctx.to, @to)]
         )}
    end

    test "keeps every from-version, in both directions", %{plan: plan} do
      assert {@hot_vsn, [{@from_vsn, [], _}, {@to_vsn, [], _}],
              [{@from_vsn, [], _}, {@to_vsn, [], _}]} = plan
    end

    test "puts the restart instruction on the restart edge and nowhere else", %{plan: plan} do
      {@hot_vsn, [{@from_vsn, [], hot_up}, {@to_vsn, [], restart_up}],
       [{@from_vsn, [], hot_down}, {@to_vsn, [], restart_down}]} = plan

      assert restart_up == [:restart_emulator]
      assert restart_down == [:restart_emulator]

      for script <- [hot_up, hot_down] do
        refute :restart_emulator in script
        refute :restart_new_emulator in script
      end
    end

    test "generates the hot edge from the appups, in both directions", %{plan: plan} do
      {@hot_vsn, [{@from_vsn, [], hot_up}, _restart_up],
       [{@from_vsn, [], hot_down}, _restart_down]} = plan

      # The instruction :sample's appup asks for, translated - and the version in
      # it is the only thing in this relup that tells the two hot scripts apart.
      # An upgrade loads the code being moved *to* and a downgrade the code being
      # returned to, which is `systools_rc:translate_scripts/4` resolving the
      # module against the target release's applications for `up` and against the
      # from-release's for `dn`. So each direction names its own version, and
      # accepting whatever version happened to be there would let the up and down
      # scripts be swapped at the merge without a single test noticing: the
      # from-versions, the restart scripts and the module are all identical
      # between the two sections, and assembly only checks that a script is
      # structurally valid.
      assert {:load_object_code, {:sample, @hot_vsn, [Sample.Counter]}} in hot_up
      assert {:load_object_code, {:sample, @from_vsn, [Sample.Counter]}} in hot_down
    end

    test "keeps the two directions' from-releases apart", ctx do
      # Asymmetric on purpose, and the only shape here that is. Every other plan
      # in this suite offers the same from-releases to both directions, so a merge
      # that swapped its up and down arguments - or used one of them twice - would
      # produce the same set twice and pass. Here 0.1.1 is a restart edge on the
      # way up and nothing is offered as a restart on the way down, so either
      # mistake moves an entry into a section it does not belong in.
      plan =
        Relup.plan_transitions!(
          rel(ctx.hot, @hot),
          [rel(ctx.from, @from)],
          [rel(ctx.from, @from)],
          [rel(ctx.to, @to)],
          []
        )

      assert {@hot_vsn, [{@from_vsn, [], _hot_up}, {@to_vsn, [], [:restart_emulator]}],
              [{@from_vsn, [], _hot_down}]} = plan
    end

    test "is accepted by assembly, and lands in the release", %{plan: plan, cwd_relup: relup} do
      # The other half of what a merged relup has to satisfy: it goes through
      # Forecastle's own check on the way into a release, which reaches into both
      # sections, and comes out the other side unchanged.
      write_term!(relup, plan)

      staged =
        assemble!(into: "relup-merged", vsn: @hot, env: [{"SAMPLE_DEP_VSN", @from}])
        |> Path.join("releases/#{@hot}/relup")

      assert File.exists?(staged), "the merged relup was not copied into the release"
      assert {:ok, [^plan]} = :file.consult(to_charlist(staged))
    end
  end

  describe "publishing the relup" do
    # The last thing the task does, and the one step whose failure the stale-relup
    # tests above cannot see: they fail before anything is written, where every
    # refusal is. Once the write itself is under way the destination is what is at
    # risk, so this is driven in process, past the refusals, with the write made
    # to fail in the window that matters. The relup is published by renaming a
    # staging file over it, so there is no window in which the destination is
    # neither the old plan nor the new one.
    test "leaves the previous relup byte-identical when the write fails partway", ctx do
      previous = encode_term({@from_vsn, [{@to_vsn, [], [:restart_emulator]}], []})
      File.write!(ctx.relup, previous)

      # Half the bytes out and then a failure, which is what running out of space
      # looks like. `File.write!/2` opens the destination for truncating
      # replacement, so this is where it left a relup that was neither: empty, or
      # half a plan, behind a run that failed.
      assert_raise Mix.Error, fn ->
        Relup.publish_relup!(new_relup(), outdir(ctx), &half_written/2)
      end

      assert File.read!(ctx.relup) == previous
      assert File.ls!(outdir(ctx)) == ["relup"], "a staging file was left behind"
    end

    test "replaces the previous relup, and leaves nothing else behind", ctx do
      File.write!(ctx.relup, encode_term({@from_vsn, [], []}))
      published = new_relup()

      assert :ok = Relup.publish_relup!(published, outdir(ctx))

      assert File.read!(ctx.relup) == published
      assert File.ls!(outdir(ctx)) == ["relup"], "a staging file was left behind"
    end

    test "does not collide with another run publishing into the same directory", ctx do
      # The staging file is named per run for this: two `mix forecastle.relup`
      # invocations sharing an --outdir must not stage into the same file, or one
      # could publish a relup that is partly the other's. Whichever wins the
      # rename, the file is one of them whole.
      published = for n <- 1..8, do: encode_term({to_charlist("0.1.#{n}"), [], []})

      published
      |> Enum.map(fn bytes -> Task.async(fn -> Relup.publish_relup!(bytes, outdir(ctx)) end) end)
      |> Task.await_many()

      assert File.read!(ctx.relup) in published
      assert File.ls!(outdir(ctx)) == ["relup"], "a staging file was left behind"
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

  # A run has one verdict about its strategy, so a run with a restart in it must
  # not also have said that every transition was hot. Classification alone cannot
  # answer that - an appup can ask for the emulator to be restarted by name, and
  # nothing knows until :systools has produced a script - so this is asserted
  # against every `auto` case that ends in a restart, whichever of the two ways
  # the restart arrived. It has to keep holding when the refusal becomes an
  # announcement: then it is a *successful* run that must not say both.
  defp refute_all_hot(output) do
    refute output =~ "every transition in this relup is a hot upgrade",
           "auto announced an all-hot relup for a transition it restarts:\n\n#{output}"
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

  # The dependency's appup in the assembled target release, rewritten to say
  # exactly what a test needs it to say. It is the application `auto` consults -
  # the one the project does not own whose version moves with the sample's - and
  # the fixture's own version of it covers 0.1.0 both ways, so what these tests
  # vary is this file.
  defp set_dep_appup!(release, vsn, ups, downs) do
    file = Path.join(release, "lib/sample_dep-#{vsn}/ebin/sample_dep.appup")
    {:ok, [{appup_vsn, _ups, _downs}]} = consult_and_restore!(file)

    write_term!(file, {appup_vsn, ups, downs})
  end

  defp remove_appups!(release, vsn) do
    for app <- ~w(sample sample_dep), do: remove_appup!(release, vsn, app)
  end

  defp remove_appup!(release, vsn, app) do
    file = Path.join(release, "lib/#{app}-#{vsn}/ebin/#{app}.appup")
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    File.rm!(file)
  end

  defp consult_and_restore!(file) do
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    :file.consult(to_charlist(file))
  end

  defp write_term!(file, term), do: File.write!(file, encode_term(term))

  # The bytes the task itself would publish for this term: an encoding comment
  # and a single term. What the publication tests compare is bytes, so they need
  # the encoding rather than the term.
  defp encode_term(term) do
    :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term]) |> IO.iodata_to_binary()
  end

  defp new_relup, do: encode_term({@to_vsn, [{@from_vsn, [], [:restart_emulator]}], []})

  # A write that gets part of the relup out and then fails, which is the failure
  # the staging file exists for. `IO.binwrite/2` reports a real one exactly this
  # way, so nothing about the path under test is special-cased for the test.
  defp half_written(handle, bytes) do
    :ok = IO.binwrite(handle, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    {:error, :enospc}
  end

  defp outdir(ctx), do: Path.dirname(ctx.relup)

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
