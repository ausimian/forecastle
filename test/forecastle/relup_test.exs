defmodule Forecastle.RelupTest do
  @moduledoc """
  Drives `mix castle.relup` against two really-assembled releases.

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

  Two things here are driven in process rather than as a command: the
  split-and-merge, so that the merged plan can be asserted on as a term rather
  than through whatever the task prints, and publication, whose promise - that a
  failed run leaves the previous relup whole - can only be tested from inside the
  window in which it could be broken. Both are `Forecastle.Relup`'s rather than
  the task's, which is where the generation itself lives; the task is its
  command line, and everything in this suite run as a command is asserting on
  the pair.

  `Forecastle.AssemblyRelupTest` is the other caller of that module - the step
  that generates a relup into the release being assembled - and the two suites
  divide by what they can reach. What is asserted here is what the task adds:
  argument handling, `--outdir`, the three strategies and the exit status. What
  is asserted there is that a `mix release` produces a relup at all, and what it
  does when the option names nothing.

  Baseline specs are covered here only as far as the task's own part in them -
  that a bare path still means what it always meant, that `rel:` and `tar:` reach
  the same release, and that `--target` says so when it is handed a spec.
  `Forecastle.BaselineTest` covers the grammar and the three sources themselves,
  `ref:` included, and it does that in a repository of its own for reasons its
  moduledoc gives. Nothing here builds a git ref: the fixture's `:tar` step
  already leaves an artefact beside every assembly, so `tar:` costs this suite
  nothing, and `ref:` would cost it another `mix release`.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture
  alias Forecastle.Relup

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

  describe "naming a baseline" do
    test "a bare path is still a path to an assembled release", ctx do
      # Every other test in this suite spells its baselines this way, which is
      # what the grammar has to keep meaning: the switches took a path long
      # before they took a spec.
      relup!(hot(ctx) ++ ["--outdir", @outdir], @to)

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [_ | _]}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "rel: names the same thing the bare path does", ctx do
      relup!(
        ["--target", rel(ctx.to, @to), "--fromto", "rel:#{rel(ctx.from, @from)}", "--hot"] ++
          ["--outdir", @outdir],
        @to
      )

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [_ | _]}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "tar: generates against the artefact that shipped", ctx do
      # The recommended source, and the one with no rebuild in it: the fixture's
      # `:tar` step packages every assembly, so what is named here is the same
      # bytes a deployment would have been given.
      relup!(
        ["--target", rel(ctx.to, @to), "--fromto", "tar:#{tarball(ctx.from, @from)}", "--hot"] ++
          ["--outdir", @outdir],
        @to
      )

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "two spellings of one release are one transition", ctx do
      # `rel:x` and a bare `x` are the same release named two ways. Resolved and
      # then left as they came, the same from-version would appear twice in the
      # one direction of the relup - inert, since `release_handler` selects by
      # from-version and takes the first, but not something to write.
      relup!(
        ["--target", rel(ctx.to, @to), "--upfrom", rel(ctx.from, @from)] ++
          ["--upfrom", "rel:#{rel(ctx.from, @from)}", "--hot", "--outdir", @outdir],
        @to
      )

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], []}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "one release reached two ways is one baseline, not an ambiguity", ctx do
      # `rel:` hands back the path it was given, deliberately, so one release
      # arrives under as many names as there are ways to write it. A symlinked
      # spelling is the case a textual comparison cannot see through - the two
      # paths share not one character after the workspace - and refusing it would
      # block a command that names one release twice and means it.
      aliased = Path.join(Fixture.workspace(), "relup-from-alias")
      File.rm(aliased)
      File.ln_s!(ctx.from, aliased)
      on_exit(fn -> File.rm(aliased) end)

      relup!(
        ["--target", rel(ctx.to, @to), "--upfrom", rel(ctx.from, @from)] ++
          ["--upfrom", rel(aliased, @from), "--hot", "--outdir", @outdir],
        @to
      )

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], []}]} =
               :file.consult(to_charlist(ctx.relup))
    end

    test "two releases sharing one .rel file are still two baselines", ctx do
      # The other side of the test above, and the hole a `.rel`-only identity
      # left. Deduplication saw the same file - same device, same inode - and
      # dropped one of the two, while the library directory each baseline is read
      # from is derived from the *spelling* of whichever path survived. So which
      # code tree the relup was generated against came down to the order the
      # switches were written in, which is what the ambiguity refusal exists to
      # prevent.
      #
      # The `.rel` is shared and the `lib/` deliberately is not, which is the
      # whole point: the two roots agree on every application and version and
      # share not one module.
      impostor = Path.join(Fixture.workspace(), "relup-from-impostor")
      File.rm_rf!(impostor)
      on_exit(fn -> File.rm_rf!(impostor) end)

      File.mkdir_p!(Path.join([impostor, "releases", @from]))
      File.mkdir_p!(Path.join(impostor, "lib"))
      File.ln_s!(rel(ctx.from, @from) <> ".rel", rel(impostor, @from) <> ".rel")

      {output, status} =
        relup(
          ["--target", rel(ctx.to, @to), "--fromto", rel(ctx.from, @from)] ++
            ["--fromto", rel(impostor, @from), "--outdir", @outdir],
          @to
        )

      assert status != 0
      assert output =~ "2 different baselines were named for the upgrade from #{@from}"
      refute File.exists?(ctx.relup)
    end

    test "a baseline at the target version is refused, not generated as a self-transition", ctx do
      # `:systools` accepts a from-release whose version equals the target and
      # generates an entry from the version to itself, whose script carries
      # nothing but `point_of_no_return`. `release_handler` selects an entry by
      # the version it is upgrading *from* and will not unpack a version a
      # deployment already has, so such an entry could never be used - and the
      # run packaged it as the release's upgrade plan without a word.
      #
      # The way to reach it without meaning to is a release assembled twice into
      # one path with `upgrade_from:` naming that path: `:assemble` replaces the
      # directory, so the baseline and the target become the same release. The
      # rule lives in `Forecastle.Relup`, so refusing it here refuses it there.
      {output, status} =
        relup(
          ["--target", rel(ctx.to, @to), "--fromto", rel(ctx.to, @to)] ++ ["--outdir", @outdir],
          @to
        )

      assert status != 0
      assert output =~ "is version #{@to}, which is the version being generated for"
      refute File.exists?(ctx.relup)
    end

    test "two different baselines for one version are refused, not silently picked", ctx do
      # The assembled 0.1.0 and the artefact packaged from it are the same
      # release named two ways, and they resolve to two different trees - naming
      # both while checking they agree is a natural thing to write. A relup
      # carries one entry per from-version and `release_handler` selects by
      # version, so only one could ever be used and which one would come down to
      # the order the switches were written in.
      {output, status} =
        relup(
          ["--target", rel(ctx.to, @to), "--fromto", rel(ctx.from, @from)] ++
            ["--fromto", "tar:#{tarball(ctx.from, @from)}"],
          @to
        )

      assert status != 0, "two baselines for one version were accepted:\n\n#{output}"
      assert output =~ "2 different baselines were named for the upgrade from #{@from}"
    end

    test "a prefix that names no source is refused", ctx do
      {output, status} =
        relup(["--target", rel(ctx.to, @to), "--fromto", "re:#{rel(ctx.from, @from)}"], @to)

      assert status != 0, "a mistyped baseline source was accepted:\n\n#{output}"
      assert output =~ ~s(baseline source "re:")
    end

    test "--target is a path, and says so when it is given a spec", ctx do
      # Read as a path it would fail looking for `tar:...tar.gz.rel`, which
      # mentions neither the switch that does take a spec nor the reason this one
      # does not.
      {output, status} =
        relup(
          ["--target", "tar:#{tarball(ctx.to, @to)}", "--fromto", rel(ctx.from, @from)],
          @to
        )

      assert status != 0, "--target accepted a baseline spec:\n\n#{output}"
      assert output =~ "--target takes a path"
    end

    test "reads the target before it resolves a baseline", ctx do
      # Both are wrong, so which one is reported is the whole assertion.
      # Resolving a baseline can mean unpacking an artefact or building a commit,
      # and spending that before noticing the target is not where the caller said
      # it was is the wrong way round to fail - but nothing about the message for
      # either failure would show it, so the two are broken together and the
      # order decides which one comes out.
      absent = Path.join(Fixture.workspace(), "never-shipped.tar.gz")

      {output, status} =
        relup(["--target", rel(ctx.to, @to) <> "-nope", "--fromto", "tar:#{absent}"], @to)

      assert status != 0, "a missing target was accepted:\n\n#{output}"
      assert output =~ "could not be read as a release file"
      refute output =~ "never-shipped.tar.gz"
    end
  end

  describe "a generation that fails" do
    test "exits non-zero, saying what could not be done", ctx do
      # Backwards: 0.1.0's appup says nothing about coming from 0.1.1, which is
      # what a project that has not written the instructions yet looks like.
      # `--hot`, because the dependency's appup at 0.1.0 says nothing about it
      # either, so `auto` would classify this edge a restart, write it and
      # succeed - and it is the failure that is under test here.
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

    test "announces an edge it can only restart, naming the application and the gap", ctx do
      # The dependency's appup now says nothing about coming from 0.1.0 in either
      # direction, which is what a dependency that never wrote instructions for
      # this project's transitions looks like. There is no hot upgrade to be had,
      # so `auto` writes the restart and says so - which is what it used to refuse
      # to do, while nothing could complete such a transition.
      set_dep_appup!(ctx.to, @to, [], [])

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      refute_all_hot(output)
      assert output =~ "auto made a restart transition of the upgrade from #{@from}"
      assert output =~ "the downgrade to #{@from}"
      assert output =~ ":sample_dep is a dependency and changed from #{@from} to #{@to}"
      assert output =~ "sample_dep.appup has no upgrade instructions from #{@from}"
      assert output =~ "sample_dep.appup has no downgrade instructions to #{@from}"

      assert output =~ "Each uses restart_emulator"
      assert output =~ "reboots into the installed release"
      assert output =~ "stays provisional until committed"

      # And the two ways to insist on something else, so that a pipeline which
      # wanted neither has somewhere to go.
      assert output =~ "Use --hot to refuse restart transitions"
      assert output =~ "--restart to restart every transition"

      assert {:ok,
              [
                {@to_vsn, [{@from_vsn, [], [:restart_emulator]}],
                 [{@from_vsn, [], [:restart_emulator]}]}
              ]} = :file.consult(to_charlist(ctx.relup))
    end

    test "says so when the application has no appup at all", ctx do
      remove_appup!(ctx.to, @to, "sample_dep")

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      refute_all_hot(output)
      assert output =~ "there is no appup at "
      assert output =~ "sample_dep-#{@to}/ebin/sample_dep.appup"
    end

    test "classifies each direction on its own", ctx do
      # An appup's up and down lists are independent, and a from-version in one
      # need not be in the other. Here the dependency can be upgraded from 0.1.0
      # but not downgraded back to it, so the only correct answer is a hot
      # upgrade and a restart the other way - and it is the *downgrade*, alone,
      # that the announcement names. Classifying the edge once and using the
      # answer for both directions would name both.
      set_dep_appup!(ctx.to, @to, [{~c"#{@from}", []}], [])

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      refute_all_hot(output)
      assert output =~ "auto made a restart transition of the downgrade to #{@from}"
      assert output =~ "sample_dep.appup has no downgrade instructions to #{@from}"
      refute output =~ "upgrade from #{@from}"

      # And the relup carries the split, which is the half an announcement cannot
      # be trusted for: one direction generated from the appups and the other a
      # single instruction.
      assert {:ok, [{@to_vsn, [{@from_vsn, [], up}], [{@from_vsn, [], down}]}]} =
               :file.consult(to_charlist(ctx.relup))

      assert down == [:restart_emulator]
      refute :restart_emulator in up
      assert {:load_object_code, {:sample, @to_vsn, [Sample.Counter]}} in up
    end

    test "restarts a transition that changed ERTS, whatever the appups say", ctx do
      # An ERTS change is not a hot upgrade under any policy and no appup could
      # make it one, so it is not put to the appups at all - the dependency's
      # appup covers its own move here, and the ERTS change is the whole reason.
      # The decision is also taken before :systools is asked for anything, which
      # inserts restart_new_emulator for an ERTS change: the two-stage
      # transition, which nothing about the strategy asked for. What lands is the
      # one-stage instruction, written by hand.
      change_erts!(ctx.from, @from, "0.0.0")

      output = relup!(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      refute_all_hot(output)
      assert output =~ "auto made a restart transition of the upgrade from #{@from}"
      assert output =~ "ERTS changed from 0.0.0 to"
      refute output =~ ":sample_dep"

      assert {:ok,
              [
                {@to_vsn, [{@from_vsn, [], [:restart_emulator]}],
                 [{@from_vsn, [], [:restart_emulator]}]}
              ]} = :file.consult(to_charlist(ctx.relup))
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
      # default strategy would have shipped an unsupported two-stage transition
      # without anybody choosing it.
      add_appup_instruction!(ctx.hot, @hot, :restart_new_emulator)

      {output, status} = relup(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert status != 0, "a restart_new_emulator relup was accepted:\n\n#{output}"
      refute_all_hot(output)
      assert output =~ "Cannot use restart_new_emulator"
      assert output =~ "restart_new_emulator on the upgrade from #{@from}"
      assert output =~ "Castle supports only restart_emulator"
      assert output =~ "Remove the instruction from the appup"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end

    test "announces an appup that asks for the one-stage emulator restart", ctx do
      # The same announcement by another route. A restart_emulator an appup asked
      # for by name is the transition `auto` would have chosen for itself, so how
      # the relup came by it makes no difference to what the run says.
      #
      # Classification cannot see this one: nothing but :sample moves between
      # these two releases, so every edge is classified hot and the restart only
      # exists once :systools has produced a script. That is what the all-hot
      # refutation is here for - announcing the verdict from classification alone
      # had this run report a hot relup and a restart in the same breath, and now
      # that the run succeeds it would report both from a successful one.
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      output = relup!(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      refute_all_hot(output)
      assert output =~ "an appup asks for the emulator to be restarted"
      assert output =~ "restart_emulator on the upgrade from #{@from}"
      assert output =~ "Each uses restart_emulator"

      assert {:ok, [{@hot_vsn, [{@from_vsn, [], up}], _down}]} =
               :file.consult(to_charlist(ctx.relup))

      assert :restart_emulator in up
    end

    test "names both kinds of restart in one announcement", ctx do
      # Both kinds in one run. 0.1.1 is an edge `auto` classifies as a restart -
      # the dependency moves between it and 0.1.2, whose copy of the dependency's
      # appup covers nothing - while 0.1.0 is a hot edge whose appup then asks for
      # the emulator to be restarted by name.
      #
      # One verdict per invocation means both are named together, and that is only
      # possible after generation: the appup's own instruction is invisible until
      # there is a script to look at. This test used to assert the opposite - a
      # refusal naming the classified edge alone, because that refusal was settled
      # before generation while nothing could complete a restart transition.
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      output =
        relup!(project_only(ctx) ++ ["--upfrom", rel(ctx.to, @to), "--outdir", @outdir], @hot)

      refute_all_hot(output)
      assert output =~ "auto made a restart transition of the upgrade from #{@to}"
      assert output =~ "sample_dep.appup has no upgrade instructions from #{@to}"
      assert output =~ "an appup asks for the emulator to be restarted"
      assert output =~ "restart_emulator on the upgrade from #{@from}"

      # And both are in the one relup: the hand-written entry for the classified
      # edge, and the generated one carrying what the appup asked for.
      assert {:ok, [{@hot_vsn, [{@from_vsn, [], hot_up}, {@to_vsn, [], restart_up}], _down}]} =
               :file.consult(to_charlist(ctx.relup))

      assert restart_up == [:restart_emulator]
      assert :restart_emulator in hot_up
      assert {:load_object_code, {:sample, @hot_vsn, [Sample.Counter]}} in hot_up
    end

    test "reports a systools error from the hot half rather than announcing anything", ctx do
      # The same mixed plan, with a hot half that cannot be generated at all.
      # :sample is the project's own application, so classification never reads
      # its appup and the 0.1.0 edge is still classified hot - and :systools then
      # has nothing to generate that transition from.
      remove_appup!(ctx.hot, @hot, "sample")

      # The control: the hot half of that plan, on its own, really does fail in
      # :systools, which is what makes the assertions below about the mixed run
      # mean something.
      {control, status} = relup(project_only(ctx) ++ ["--outdir", @outdir], @hot)

      assert status != 0, "the hot half was generated without an appup:\n\n#{control}"
      assert control =~ "sample-#{@hot}/ebin/sample.appup"

      {output, status} =
        relup(project_only(ctx) ++ ["--upfrom", rel(ctx.to, @to), "--outdir", @outdir], @hot)

      # This is the ordering that changed with the refusal. It used to settle the
      # classified restart *first*, because while such a transition could not be
      # installed the classification was already the whole answer and a systools
      # error from the other half would only have stood in front of it. Now the
      # run can succeed, so generation comes first and its failure is the verdict:
      # there is nothing to announce about a relup that was not produced.
      assert status != 0, "a mixed relup with an ungeneratable half was accepted:\n\n#{output}"
      assert output =~ "sample-#{@hot}/ebin/sample.appup"

      refute output =~ "auto made a restart transition",
             "a run that generated nothing announced a strategy anyway:\n\n#{output}"

      refute_all_hot(output)
      refute File.exists?(ctx.relup), "a failed run wrote a relup anyway"
    end
  end

  describe "merging hot and restart transitions into one relup" do
    # `auto` is the only strategy that splits a relup's edges by class and merges
    # the two kinds back together, and it is the one place an edge could be
    # dropped, or attached to the wrong direction, or one class's script applied
    # to the whole relup. The task reaches it now that a restart transition can be
    # installed - the mixed-restart cases above go through it - but it is still
    # driven directly here, because what these assert is the *shape* of the merged
    # plan, which is a term rather than anything the task prints.
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

    test "says nothing about the strategy when the relup could not be published", ctx do
      # An announcement is a claim about a file, so it has to come after the file
      # exists. It used to be printed by the planning step, before encoding,
      # opening, writing, closing and renaming had each had their chance to fail
      # - so a run could report that every transition was a hot upgrade and then
      # produce no relup at all.
      #
      # A directory standing where the relup goes is the cheapest way to fail the
      # rename and nothing before it: the staging file writes perfectly well and
      # cannot be renamed over a directory. Permissions would do it too, but not
      # for a build running as root.
      File.mkdir_p!(Path.join(ctx.relup, "occupied"))

      {output, status} = relup(upgrade(ctx) ++ ["--outdir", @outdir], @to)

      assert status != 0
      assert output =~ "could not be renamed"
      refute output =~ "every transition in this relup is a hot upgrade"
    end

    test "replaces the previous relup, and leaves nothing else behind", ctx do
      File.write!(ctx.relup, encode_term({@from_vsn, [], []}))
      published = new_relup()

      assert :ok = Relup.publish_relup!(published, outdir(ctx))

      assert File.read!(ctx.relup) == published
      assert File.ls!(outdir(ctx)) == ["relup"], "a staging file was left behind"
    end

    test "does not collide with another run publishing into the same directory", ctx do
      # The staging file is named per run for this: two `mix castle.relup`
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
      assert output =~ "Cannot use --hot for the transition between #{@from} and #{@to}"
      assert output =~ "ERTS changes from 0.0.0 to"
      assert output =~ "Generate this relup with --restart"

      # #7 was this task exiting 0 on a failure. The other half of the same
      # promise is that a refusal writes nothing, so the relup already sitting
      # where post-assembly looks is the one that is still there afterwards.
      assert File.read!(ctx.cwd_relup) == "%% stale\n"
    end

    test "refuses an appup that restarts the emulator", ctx do
      add_appup_instruction!(ctx.hot, @hot, :restart_emulator)

      {output, status} = relup(project_only(ctx) ++ ["--hot", "--outdir", @outdir], @hot)

      assert status != 0, "an appup that restarts the emulator passed for hot:\n\n#{output}"
      assert output =~ "Cannot use --hot: an appup adds an emulator restart"
      assert output =~ "restart_emulator on the upgrade from #{@from}"
      assert output =~ "Remove the restart instruction"
      refute File.exists?(ctx.relup), "a refused relup was written anyway"
    end
  end

  describe "the restart strategy" do
    test "makes every transition a restart_emulator instruction", ctx do
      output = relup!(upgrade(ctx) ++ ["--restart", "--outdir", @outdir], @to)

      assert output =~ "--restart: every transition is a restart_emulator instruction"
      assert output =~ "Appups are ignored; no code is hot-loaded"
      assert output =~ "restart target is provisional and must be committed"

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
      # It does not cover the transition itself. `restart_upgrade_test.exs` does
      # that, end to end and against a real supervised release, so this asserts
      # on the relup and the assembled tree and stops there.
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
  # the restart arrived. It matters *more* now that those runs succeed: what it
  # forbids is a successful run saying both.
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

  # The fixture's release steps end in `:tar`, so every assembly leaves the
  # artefact a deployment would be shipped beside the tree it was made from.
  # Nothing here has to build one.
  defp tarball(release, vsn), do: Path.join(release, "sample-#{vsn}.tar.gz")

  defp relup(args, vsn), do: mix(["castle.relup" | args], env(vsn))

  defp relup!(args, vsn), do: mix!(["castle.relup" | args], env(vsn))

  # The task builds nothing, but Mix still loads the project around it. Pointing
  # it at the build tree the target release was assembled in keeps it from
  # creating another one, which is what the upgrade suite does too.
  defp env(@hot), do: env_for(@hot) ++ [{"SAMPLE_DEP_VSN", @from}]
  defp env(vsn), do: env_for(vsn)

  defp env_for(vsn) do
    [{"SAMPLE_VSN", vsn}, {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{vsn}")}]
  end
end
