defmodule Forecastle.AppupCheckTest do
  @moduledoc """
  Drives `mix castle.appup` against two really-assembled releases.

  The check compares two builds of one application and says how the appup beside
  the newer one covers the modules that moved, so the smallest fixture for it is
  a pair of real builds of a real application - the same pair the relup suite
  needs, and made the same way.

  It is run as a command rather than through `run/1` because half of what is
  under test is the exit status a release pipeline sees, and Mix does not derive
  that from what a task returns.

  **The fixture is already the failure.** `Sample.Counter` and
  `Sample.Unmentioned` are the same module twice - both supervised GenServers,
  both carrying a compile-time version tag - and `appup.exs` names only the
  first. So the default state of the fixture is an appup with a gap in it, which
  is what the first case here asserts, and every case that needs a *covered*
  appup makes one by rewriting the file in the assembled target release. That
  is the same division the relup suite uses: the source is shared with every
  other suite, the assembled trees belong to this one.

  `Forecastle.UpgradeTest` is the other half. This suite says the check reports
  the gap before an upgrade is attempted; that one says what happens when it is
  not.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # What the fixture's own appup covers, so that a case wanting a complete appup
  # can add to it rather than restate it.
  @counter {:update, Sample.Counter, {:advanced, []}}
  @unmentioned {:update, Sample.Unmentioned, {:advanced, []}}

  # The same two in the **long** form `check_op/1` accepts directly, for the cases
  # that put an instruction somewhere the short-form rewrite does not reach - a
  # nested fragment, or the wrong side of a `point_of_no_return`. Defined here
  # rather than inside the describe that first needed them, because a module
  # attribute is evaluated where it is written: used from a describe earlier in
  # the file it is `nil`, and a script of `[nil, nil]` covers nothing and fails
  # for the wrong reason.
  @counter_long {:update, Sample.Counter, {:advanced, []}, :brutal_purge, :brutal_purge, []}
  @unmentioned_long {:update, Sample.Unmentioned, {:advanced, []}, :brutal_purge, :brutal_purge,
                     []}

  setup_all do
    {:ok,
     from: assemble!(into: "appup-from", vsn: @from), to: assemble!(into: "appup-to", vsn: @to)}
  end

  describe "the coverage check" do
    test "reports a changed module no instruction loads, and exits non-zero", ctx do
      {output, status} = appup(both(ctx))

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"

      # And says so about both directions, because an appup's two lists are
      # independent and this appup is incomplete in each of them.
      assert output =~ "upgrade from #{@from}"
      assert output =~ "downgrade to #{@from}"
    end

    test "exits zero when every module that moved is mentioned", ctx do
      set_appup!(ctx.to, @to, [@counter, @unmentioned], [@counter, @unmentioned])

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      assert output =~ "upgrade from #{@from}: nothing missing"
      assert output =~ "downgrade to #{@from}: nothing missing"
    end

    test "names the two versions it compared", ctx do
      {output, _status} = appup(both(ctx))

      assert output =~ "sample #{@from} -> #{@to}"
    end

    test "says nothing about a module the appup does mention", ctx do
      {output, _status} = appup(both(ctx))

      refute output =~ "Sample.Counter changed"
    end
  end

  describe "comparing a stripped release against an unstripped build" do
    test "reports only the modules that really moved", ctx do
      # The everyday question - what has changed since 0.1.0, and does my appup
      # cover it? - which needs no assembled target: `--to` defaults to the
      # current build, and the fixture's build root for this version is the one
      # `assemble!/1` compiled into.
      #
      # This is also the case that pins `:beam_lib.md5/1` against a digest of
      # the file bytes. A release's beams are stripped and `_build`'s are not, so
      # every module differs byte for byte between these two directories - the
      # guard below says so rather than assuming it - and a byte digest would
      # report the whole application as changed. The `refute` is the assertion
      # that matters here; the `assert` above it would pass either way.
      assert_stripped!(ctx.from)

      {output, status} = appup(["--from", "rel:" <> rel(ctx.from, @from)])

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
      refute output =~ "Sample.Counter changed"
      refute output =~ "Sample.Application changed"
      refute output =~ "Elixir.Sample changed"
    end

    test "defaults --app to the project's own applications", ctx do
      {output, _status} = appup(["--from", "rel:" <> rel(ctx.from, @from)])

      assert output =~ "sample #{@from} -> #{@to}"

      # The fixture's dependency moves with it and its appup covers nothing, so
      # a default that reached past the project's own applications would report
      # it here. Naming it is how that case is reached - see below.
      refute output =~ "sample_dep"
    end
  end

  describe "an edge that restarts the emulator" do
    test "needs no coverage, and nothing is said about it", ctx do
      # `restart_emulator` is deliberately *not* the last instruction. Its
      # position in an appup does not matter: `systools_rc:sort_emulator_restart/3`
      # filters it out wherever it was written and appends it to the end of the
      # translated script. A check that looked at the last instruction would
      # report a gap here, which is the whole point of writing it this way.
      restart = [:restart_emulator, {:load_module, Sample}]
      set_appup!(ctx.to, @to, restart, restart)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      refute output =~ "Sample.Unmentioned"

      # Skipped, and said to have been skipped. A bare "nothing missing" would
      # be true and would read as a hot edge that happens to be fully covered,
      # which is a very different thing to have just been told about a release.
      assert output =~ "the emulator restarts on this edge"
      refute output =~ "nothing missing"
    end

    test "is the downgrade meaning of restart_new_emulator too", ctx do
      # Measured in `systools_rc:sort_emulator_restart/3`: a `restart_new_emulator`
      # in a *downgrade* script is removed and a plain `restart_emulator`
      # appended in its place, so the emulator is replaced and no module-level
      # instruction is needed. On the way up it is the two-stage transition and
      # the rest of the relup still runs, so coverage is still reported - and
      # Castle does not support that transition at all, which is said rather
      # than left for `mix castle.relup` to refuse later.
      set_appup!(ctx.to, @to, [:restart_new_emulator], [:restart_new_emulator])

      {output, status} = appup(both(ctx))

      assert status != 0, "the two-stage upgrade edge was not checked:\n\n#{output}"
      assert output =~ "restart_new_emulator, which Castle does not support"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"

      # The whole asymmetry, in one report: the same instruction is a checked
      # two-stage upgrade on the way up and a one-stage emulator restart on the
      # way down. Asserting the *reason* rather than a bare "nothing missing" is
      # what makes this a claim about the direction - an implementation that
      # ignored the direction entirely and found the down edge fully covered
      # would satisfy the weaker assertion.
      assert output =~ "the emulator restarts on this edge"
      refute output =~ "nothing missing"
    end
  end

  describe "finding the entry" do
    test "matches a from-version regex the way systools_relup matches it", ctx do
      # An appup may name a from-version as a *binary*, and then it is a regular
      # expression rather than a string: `appup_search_for_version/2` runs it
      # with `re:run/3` and accepts it only when the whole match is the
      # from-version. The check calls that function rather than comparing
      # strings, so that it and `mix castle.relup`'s `auto` cannot disagree
      # about whether an appup covers an edge.
      set_appup!(
        ctx.to,
        @to,
        [{"0\\.1\\..*", [@counter, @unmentioned]}],
        [{"0\\.1\\..*", [@counter, @unmentioned]}],
        :entries
      )

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
    end

    test "reports a from-version the appup has no entry for", ctx do
      set_appup!(ctx.to, @to, [{~c"9.9.9", []}], [{~c"9.9.9", []}], :entries)

      {output, status} = appup(both(ctx))

      assert status != 0, "an appup with no entry for the from-version passed:\n\n#{output}"
      assert output =~ "the appup has no upgrade entry for #{@from}"
      assert output =~ "the appup has no downgrade entry for #{@from}"
      assert output =~ "refuses outright"
    end

    test "reports an entry that is not a list of instructions", ctx do
      # An appup is arbitrary evaluated Elixir, so an entry's script need not be
      # a list at all, and `appup_search_for_version/2` hands back whatever is
      # there. Iterating it raised a protocol error naming neither the appup nor
      # the from-version; it is now a gap, which is also what `:systools` makes
      # of such an entry.
      set_appup!(
        ctx.to,
        @to,
        [{to_charlist(@from), :not_a_list}],
        [{to_charlist(@from), :not_a_list}],
        :entries
      )

      {output, status} = appup(both(ctx))

      assert status != 0, "a malformed entry passed the check:\n\n#{output}"
      assert output =~ "is not a list of instructions"
      refute output =~ "Protocol.UndefinedError"
    end

    test "reports an application with no appup at all", ctx do
      remove_appup!(ctx.to, @to, "sample")

      {output, status} = appup(both(ctx))

      assert status != 0, "an application with no appup passed the check:\n\n#{output}"
      assert output =~ "there is no appup at "
      assert output =~ "sample-#{@to}/ebin/sample.appup"
      assert output =~ "nothing covers the move from #{@from}"
    end

    test "notes an appup tagged with a version other than the application's", ctx do
      # `systools_relup:get_script_from_appup/5` compares the two and adds a
      # `bad_vsn` warning; it does not refuse, and it uses the entry it found.
      # So this is a note and the run still turns on coverage alone - which here
      # is complete, so it passes.
      set_appup!(ctx.to, @to, [@counter, @unmentioned], [@counter, @unmentioned], :instructions,
        tag: ~c"9.9.9"
      )

      output = appup!(both(ctx))

      assert output =~ "is tagged 9.9.9 and the application is #{@to}"
      assert output =~ "bad_vsn"
    end
  end

  describe "modules that were added or removed" do
    test "are reported when no instruction covers them", ctx do
      # A module in one build and not the other. Made by taking the beam out of
      # the baseline rather than by giving the fixture a module that exists in
      # only one version: what the check reads is the beams on disk, which is
      # what `release_handler` can load, so removing one produces exactly the
      # state a module added between two versions produces.
      remove_beam!(ctx.from, @from, Sample.Unmentioned)

      {output, status} = appup(both(ctx))

      assert status != 0, "an added module mentioned nowhere passed the check:\n\n#{output}"

      # The same module, both ways round: added on the way up, removed on the
      # way back down.
      assert output =~ "Sample.Unmentioned was added, and no instruction loads it"
      assert output =~ "an add_module is missing"
      assert output =~ "Sample.Unmentioned was removed, and no instruction deletes it"
      assert output =~ "a delete_module is missing"
    end
  end

  describe "what an instruction actually does to a module" do
    test "a delete_module does not cover a module whose code changed", ctx do
      # The dangerous direction, and the reason coverage is asked per effect
      # rather than per mention. `systools_rc:translate_dep_to_low/3` turns
      # `delete_module` into a `remove` and a `purge` with **no load**, so a
      # changed module named only by one is not merely left stale - it is taken
      # out of a release that still has it. A model that asked "is this module
      # mentioned?" called this covered and exited zero.
      set_appup!(
        ctx.to,
        @to,
        [@counter, {:delete_module, Sample.Unmentioned}],
        [@counter, {:delete_module, Sample.Unmentioned}]
      )

      {output, status} = appup(both(ctx))

      assert status != 0, "a delete_module passed for coverage of a changed module:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"

      # And the mirror finding, which is about the instruction rather than the
      # module: it deletes something the target still has.
      assert output =~ "is deleted by an instruction and is still in the target build"
    end

    test "a load_module does not cover a module that was removed", ctx do
      # The other half. A removed module needs a `delete_module`; naming it in a
      # `load_module` is what `:systools` itself refuses, since
      # `systools_rc:get_lib/2` throws when no application in the release has
      # the module. Said here before a relup is ever attempted.
      remove_beam!(ctx.to, @to, Sample.Unmentioned)

      set_appup!(
        ctx.to,
        @to,
        [@counter, {:load_module, Sample.Unmentioned}],
        [@counter, {:load_module, Sample.Unmentioned}]
      )

      {output, status} = appup(both(ctx))

      assert status != 0, "a load_module passed for coverage of a removed module:\n\n#{output}"
      assert output =~ "Sample.Unmentioned was removed, and no instruction deletes it"
      assert output =~ "a delete_module is missing"
    end

    test "a low-level remove conflicting with a load is reported, not resolved", ctx do
      # `check_op/1` accepts the low-level `load` and `remove` in an appup - they
      # are what the high-level instructions translate into - and
      # `release_handler_1` implements `remove` with `code:purge/1` and
      # `code:delete/1`. So a module loaded by one instruction and removed by
      # another ends up unavailable, and the install still reports success.
      #
      # Read as two sets the module was in both, the subtraction cancelled it, and
      # nothing was said at all. Which of the two wins is not decidable from the
      # file, so it is reported rather than guessed at - see the case below for
      # why guessing by source order was wrong too.
      undone = [
        @counter,
        {:update, Sample.Unmentioned, {:advanced, []}, :brutal_purge, :brutal_purge, []},
        {:remove, {Sample.Unmentioned, :brutal_purge, :brutal_purge}}
      ]

      set_appup!(ctx.to, @to, undone, undone)

      {output, status} = appup(both(ctx))

      assert status != 0, "a low-level remove undid a load unnoticed:\n\n#{output}"
      assert output =~ "Sample.Unmentioned is both loaded and removed by this edge"
      assert output =~ "not the order they are written in"
    end

    test "dependency reordering is why a conflict is not resolved by source order", ctx do
      # The script that killed the source-order model, measured on OTP 28.3:
      # `[{update, B, ..., [A]}, {remove, {A, ...}}, {update, A, ...}]` is
      # accepted and translated to `[{load, A}, {load, B}, {remove, A}]` - the two
      # dependency-connected updates are hoisted *past* the independent low-level
      # remove, in both directions. So A ends up removed where source order says
      # it ends up loaded, and a check reading the last instruction to name a
      # module called it covered and exited zero.
      #
      # `Sample.Counter` plays B and names `Sample.Unmentioned` in its DepMods,
      # which plays A, so the two updates are dependency-connected exactly so.
      reordered = [
        {:update, Sample.Counter, {:advanced, []}, :brutal_purge, :brutal_purge,
         [Sample.Unmentioned]},
        {:remove, {Sample.Unmentioned, :brutal_purge, :brutal_purge}},
        {:update, Sample.Unmentioned, {:advanced, []}, :brutal_purge, :brutal_purge, []}
      ]

      set_appup!(ctx.to, @to, reordered, reordered)

      {output, status} = appup(both(ctx))

      assert status != 0, "a load hoisted past a removal passed the check:\n\n#{output}"
      assert output =~ "Sample.Unmentioned is both loaded and removed by this edge"
    end

    test "a remove_application of this application is refused by systools, and said to be", ctx do
      # `translate_application_instrs/3` throws `removed_application_present` when
      # the application named is still in the release being moved to - and it
      # always is here, since an appup is only consulted for an application in
      # both builds. Measured in both directions on OTP 28.3: refused when the
      # application is present in the target, accepted only when it is absent,
      # which is the case this never sees.
      #
      # Crediting it covered nothing visible in the ordinary case, but had a sharp
      # edge: an application whose last module was removed has an empty target
      # inventory, so this one instruction appeared to cover the only removal
      # there was and the run exited zero on an edge make_relup cannot build.
      self_removal = [{:remove_application, :sample}]
      set_appup!(ctx.to, @to, self_removal, self_removal)

      {output, status} = appup(both(ctx))

      assert status != 0, "a self-removing appup passed the check:\n\n#{output}"
      assert output =~ "removes the application this appup belongs to"
      assert output =~ "removed_application_present"

      # And it is credited with nothing, so what it appeared to cover is reported.
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
    end

    test "a module instruction before point_of_no_return is refused for its position", ctx do
      # `split_script/1` cuts the script at an explicit `point_of_no_return` and
      # `check_script/2` allows only `load_object_code` and `apply` before it.
      # Measured on OTP 28.3: `[{update, M, ...}, point_of_no_return]` is refused
      # with `bad_op_before_point_of_no_return`, while the same instruction after
      # the marker, or an `{apply, ...}` before it, is fine.
      #
      # Positional rather than per-instruction, which is why it reads differently
      # from a bad instruction: the instruction is legal, its position is not.
      misplaced = [@counter_long, @unmentioned_long, :point_of_no_return]
      set_appup!(ctx.to, @to, misplaced, misplaced)

      {output, status} = appup(both(ctx))

      assert status != 0, "a module instruction before the marker passed:\n\n#{output}"
      assert output =~ "comes before this entry's point_of_no_return"
      assert output =~ "bad_op_before_point_of_no_return"
      refute output =~ "every module that moved is covered"
    end

    test "a module instruction after point_of_no_return is where it belongs", ctx do
      # The other half, so this is a claim about position rather than about the
      # marker appearing at all. A script with no marker of its own is entirely
      # "after" it, which is the common case and the one every other test here
      # uses.
      placed = [:point_of_no_return, @counter_long, @unmentioned_long]
      set_appup!(ctx.to, @to, placed, placed)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      refute output =~ "point_of_no_return"
    end

    test "a module defined by two instructions is refused by systools, and said to be", ctx do
      # `systools_rc` builds a dependency graph of the instructions carrying
      # `DepMods` and throws `{muldef_module, Mod}` for a module with more than
      # one vertex in it, so no relup is produced at all. Measured: an
      # application-level instruction counts, through its expansion to an
      # `add_module` per module the `.app` names - so `restart_application` beside
      # an explicit `update` of one of that application's own modules is refused.
      #
      # A reasonable-looking thing to write, which is what makes it worth a
      # finding of its own: the coverage question alone calls every module here
      # covered and exits zero.
      muldef = [{:restart_application, :sample}, @counter]
      set_appup!(ctx.to, @to, muldef, muldef)

      {output, status} = appup(both(ctx))

      assert status != 0, "a muldef_module script passed the check:\n\n#{output}"
      assert output =~ "Sample.Counter is defined by more than one instruction"
      assert output =~ "muldef_module"
    end

    test "a low-level remove is removal coverage in its own right", ctx do
      # The other direction of the same omission, and a false *gap* rather than a
      # false pass: a removal written as the low-level instruction the high-level
      # one translates into was reported as a missing `delete_module`.
      remove_beam!(ctx.to, @to, Sample.Unmentioned)

      # The module has to *go* on the way up and *arrive* on the way back down, so
      # the two lists differ here where almost everywhere else in this suite they
      # do not. The low-level removal is the half under test.
      ups = [@counter, {:remove, {Sample.Unmentioned, :brutal_purge, :brutal_purge}}]
      downs = [@counter, {:add_module, Sample.Unmentioned}]
      set_appup!(ctx.to, @to, ups, downs)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      refute output =~ "a delete_module is missing"
    end

    test "add_application covers what arrives and not what leaves", ctx do
      # `translate_application_instrs/3` expands `add_application` into an
      # `add_module` per module of the *new* application and removes nothing, so
      # it is coverage for one effect and not for the other. The
      # whole-application instructions split along the same line the per-module
      # ones do.
      #
      # One module taken out of the baseline is all this needs, and it exercises
      # both halves at once: it is *added* on the way up and *removed* on the way
      # back down, with the same instruction in both lists.
      remove_beam!(ctx.from, @from, Sample.Counter)
      set_appup!(ctx.to, @to, [{:add_application, :sample}], [{:add_application, :sample}])

      {output, status} = appup(both(ctx))

      assert status != 0, "add_application passed for a removal:\n\n#{output}"

      # Upward, everything arrives, and add_application is coverage for all of
      # it - including the changed module the fixture's appup omits.
      assert output =~ "upgrade from #{@from}: nothing missing"

      # Downward, the same module has to *go*, and add_application removes
      # nothing.
      assert output =~ "Sample.Counter was removed, and no instruction deletes it"
    end
  end

  describe "a script element that is itself a list" do
    # `systools_rc:expand_script/1` splices a list-valued script element into the
    # script, one level deep, and `appup(4)` does not document that it does. So
    # these are scripts `:systools` accepts, and a check reading only the top
    # level of the list disagrees with the relup that would be generated.
    #
    # Every nested instruction here is written in its **long** form, because the
    # splice happens instead of the per-instruction expansion rather than before
    # it - measured on OTP 28.3: `[[{load_module, m1}]]` is refused with
    # `{bad_instruction, {load_module, m1}}`, while the long form is accepted.
    test "is read for coverage", ctx do
      nested = [[@counter_long, @unmentioned_long]]
      set_appup!(ctx.to, @to, nested, nested)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
    end

    test "is read for an emulator restart", ctx do
      # Measured: `translate_scripts(up, [[[restart_emulator]]], [], [])` answers
      # `{ok, [point_of_no_return, restart_emulator]}`, so this really is an edge
      # that needs no module-level instruction. Before the splice, the check
      # reported the fixture's gap here and would have failed a release
      # `:systools` was happy to build.
      nested = [[:restart_emulator]]
      set_appup!(ctx.to, @to, nested, nested)

      output = appup!(both(ctx))

      assert output =~ "the emulator restarts on this edge"
      refute output =~ "Sample.Unmentioned"
    end

    test "does not turn a short form into a legal one", ctx do
      # The trap in reading a fragment, and a false *pass* the first attempt at
      # this introduced. A flatten followed by the short-form rewrite is not
      # `expand_script/1`: that function rewrites an element *or* splices it, and
      # a list matches no rewrite clause, so a fragment member never gets the
      # expansion. Measured - `[{load_module, m}]` passes the syntax check and
      # `[[{load_module, m}]]` is `{bad_instruction, {load_module, m}}` - and the
      # same for `{update, Mod}` and `{add_application, App}`, the other two heads
      # whose short forms exist only because the expansion rewrites them.
      #
      # So a check that flattened first credited a nested short form with coverage
      # for an appup :systools cannot produce a relup from at all.
      nested = [[{:load_module, Sample.Counter}, {:update, Sample.Unmentioned}]]
      set_appup!(ctx.to, @to, nested, nested)

      {output, status} = appup(both(ctx))

      assert status != 0, "a nested short form was credited with coverage:\n\n#{output}"
      assert output =~ "{:load_module, Sample.Counter} is not an instruction :systools accepts"
      assert output =~ "{:update, Sample.Unmentioned} is not an instruction :systools accepts"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
      refute output =~ "every module that moved is covered"
    end

    test "does not turn a short add_application into a legal one either", ctx do
      # The whole-application form of the same thing, and the one with the most
      # to lose: `{add_application, App}` covers every module the `.app` names, so
      # crediting a nested one is a clean bill of health for an unusable appup.
      # `check_op/1` has no two-element `add_application` clause - only the
      # expansion produces the three-element form - so nested it is a
      # `bad_instruction`, measured.
      nested = [[{:add_application, :sample}]]
      set_appup!(ctx.to, @to, nested, nested)

      {output, status} = appup(both(ctx))

      assert status != 0, "a nested add_application covered the application:\n\n#{output}"
      assert output =~ "{:add_application, :sample} is not an instruction :systools accepts"
      refute output =~ "every module that moved is covered"

      # And the three-element form, which `check_op/1` does have, is accepted in
      # the same position - so this is a claim about the shape and not about
      # nesting being refused wholesale.
      legal = [[{:add_application, :sample, :permanent}]]
      set_appup!(ctx.to, @to, legal, legal)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
    end

    test "nested two levels deep is refused, not passed over", ctx do
      # `expand_script/1` splices one level, so a script written two levels deep
      # leaves a *list* sitting where an instruction should be, and `check_op/1`
      # has no clause for one - measured, `[[[[restart_emulator]]]]` fails with
      # `{bad_instruction, [restart_emulator]}`.
      #
      # Skipping it because it is not a tuple was a false pass with a nasty shape:
      # the `restart_emulator` inside is invisible to the restart check too, so an
      # appup whose other instructions happen to cover everything exited zero on
      # an edge that produces no relup at all. Which is exactly this script - the
      # two updates cover both modules that moved.
      nested = [
        [[:restart_emulator]],
        @counter_long,
        @unmentioned_long
      ]

      set_appup!(ctx.to, @to, nested, nested)

      {output, status} = appup(both(ctx))

      assert status != 0, "a doubly-nested fragment passed the check:\n\n#{output}"
      assert output =~ "is not an instruction :systools accepts"
      assert output =~ "bad_instruction"
      refute output =~ "every module that moved is covered"
    end

    test "is read for a delete_module, which is the direction that failed silently", ctx do
      # The one direction of this that was not merely noisy. A nested
      # `delete_module` translates to the `remove` and `purge` pair - measured -
      # so it takes away code the target build still has, and a check that could
      # not see it reported nothing at all about it.
      nested = [[{:delete_module, Sample.Unmentioned, []}], @counter_long]
      set_appup!(ctx.to, @to, nested, nested)

      {output, status} = appup(both(ctx))

      assert status != 0, "a nested delete_module was invisible:\n\n#{output}"
      assert output =~ "is deleted by an instruction and is still in the target build"
    end
  end

  describe "an instruction :systools will not accept" do
    test "covers nothing, and is reported", ctx do
      # The false *pass*, which is the one answer a gate must never give.
      # `{restart_application, App, Anything}` is refused by
      # `systools_rc:check_syntax/1` as a `bad_instruction` and produces no relup
      # at all - but read by its head and second element alone it looked like a
      # whole-application instruction, covered the entire inventory, and the check
      # announced that every module that moved was covered.
      bogus = [{:restart_application, :sample, :bogus}]
      set_appup!(ctx.to, @to, bogus, bogus)

      {output, status} = appup(both(ctx))

      assert status != 0, "a bad_instruction covered the whole application:\n\n#{output}"
      assert output =~ "is not an instruction :systools accepts"
      assert output =~ "bad_instruction"

      # And the coverage it was credited with is gone with it.
      refute output =~ "every module that moved is covered"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
    end

    test "does not hide the module it names", ctx do
      # The per-module half. `{update, Mod, X}` is legal for a `{advanced, _}`,
      # `soft`, `supervisor`, or a list of modules, and for nothing else: any
      # other atom matches no `expand_script/1` clause and reaches `check_op/1`
      # at an arity it has no clause for. So this names the module and covers it
      # not at all, and both facts are reported.
      bogus = [@counter, {:update, Sample.Unmentioned, :bogus}]
      set_appup!(ctx.to, @to, bogus, bogus)

      {output, status} = appup(both(ctx))

      assert status != 0, "a malformed update covered the module it names:\n\n#{output}"
      assert output =~ "is not an instruction :systools accepts"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
    end

    test "is not what a long-form instruction is taken for", ctx do
      # The other side of the same rule, and the one that would catch a shape
      # check drawn too tight. Every form here is one `:systools` accepts and
      # none of them is the short form the rest of the suite uses: an `update`
      # with explicit purges, and one with the module type and timeout spelled
      # out and a dependency list on the end.
      long = [
        {:update, Sample.Counter, {:advanced, []}, :brutal_purge, :brutal_purge, []},
        {:update, Sample.Unmentioned, :dynamic, :default, {:advanced, []}, :soft_purge,
         :brutal_purge, [Sample.Counter]}
      ]

      set_appup!(ctx.to, @to, long, long)

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      refute output =~ "is not an instruction :systools accepts"
    end
  end

  describe "change detection" do
    test "a persisted attribute change is a change", ctx do
      # `:beam_lib.md5/1` covers the code and, in its own documentation's words,
      # "compilation date and other attributes are not included" - so a module
      # differing only in an explicit `@vsn` has the same md5, measured. Those
      # attributes are loaded with the module and readable through
      # `module_info/1`, so reporting such a module as unchanged is a false pass.
      #
      # Rewritten at the `Attr` chunk of an already-compiled beam rather than by
      # giving the fixture a second source, so that what is asserted is the
      # comparison and not the compiler.
      assert_attribute_only_change!(ctx.to, @to, Sample.EchoProvider)

      {output, status} = appup(both(ctx))

      assert status != 0, "a persisted attribute change was reported as no change:\n\n#{output}"
      assert output =~ "Sample.EchoProvider changed, and no instruction loads it"
    end

    test "the persisted attributes survive release stripping unchanged", ctx do
      # What makes pairing the attributes with the md5 free of false positives,
      # and the assumption the case above rests on. If stripping perturbed the
      # decoded attribute list, every module in a release would compare unequal
      # to its unstripped build and the whole check would be noise.
      beam = "Elixir.Sample.Counter.beam"
      released = Path.join(ebin(ctx.to, @to), beam)
      built = Path.join([Fixture.workspace(), "_build-#{@to}/prod/lib/sample/ebin", beam])

      refute File.read!(released) == File.read!(built),
             "the release's beams are not stripped, so this proves nothing"

      assert attributes(released) == attributes(built)
      assert attributes(released) != []
    end

    test "a beam with no attributes chunk is compared rather than refused", ctx do
      # A beam without an `Attr` chunk is a beam the runtime loads - measured on
      # OTP 28.3: such a module loads, answers calls, and reports `[]` from
      # `module_info(attributes)` - and `:beam_lib.strip/1` produces one, which
      # is a second reason the design names it as a trap. Insisting on the chunk
      # made this task refuse to run at all against a dependency somebody had
      # stripped that way: a gate that cannot answer rather than one that says no.
      #
      # Stripped from *both* sides, because that is the state a build pipeline
      # produces and it is the assertion with something to say: `[]` on both
      # sides leaves the md5 to decide, and the md5 has not moved, so the module
      # is unchanged and nothing is reported about it.
      strip_attributes!(ctx.from, @from, Sample.EchoProvider)
      strip_attributes!(ctx.to, @to, Sample.EchoProvider)

      {output, status} = appup(both(ctx))

      refute output =~ "could not be read as a beam file"
      refute output =~ "Sample.EchoProvider"

      # And the run is still the run it was: the fixture's own gap is reported.
      assert status != 0, "the check stopped finding the fixture's gap:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
    end
  end

  describe "mentions that are not gaps" do
    test "a module that is mentioned and did not change is reported, not failed", ctx do
      # Usually a leftover naming the wrong module - and where it is, the module
      # that really did change is mentioned nowhere and fails on its own
      # account. An instruction that loads a module whose code is identical is
      # inert, so this alone must not fail a pipeline.
      set_appup!(
        ctx.to,
        @to,
        [@counter, @unmentioned, {:load_module, Sample}],
        [@counter, @unmentioned, {:load_module, Sample}]
      )

      output = appup!(both(ctx))

      assert output =~ "Sample is mentioned and did not change"
      assert output =~ "every module that moved is covered"
    end

    test "a whole-application instruction covers what the .app names, not what is on disk", ctx do
      # `translate_application_instrs/3` expands `restart_application` over
      # `#application.modules`, which comes from the `.app` resource - *not* over
      # the beams in `ebin`. So a changed module the `.app` does not name is not
      # covered by one, and treating a whole-application instruction as covering
      # everything reported it as covered while a successful upgrade left the old
      # copy loaded. That is the very failure this task exists to catch, arrived
      # at through the task itself.
      #
      # `Mix.Tasks.Compile.App` fills `:modules` in with `Keyword.put_new_lazy/3`,
      # so a project supplying its own list in `application/0` keeps it - which is
      # how an ordinary build reaches this. The fixture's own `.app` is
      # consistent, which is exactly why the covered case beside this one could
      # not expose it.
      drop_from_inventory!(ctx.to, @to, Sample.Unmentioned)

      set_appup!(ctx.to, @to, [{:restart_application, :sample}], [{:restart_application, :sample}])

      {output, status} = appup(both(ctx))

      assert status != 0,
             "a changed module missing from the .app was covered by restart_application:" <>
               "\n\n#{output}"

      assert output =~ "Sample.Unmentioned moved but is not in the modules list of"
      assert output =~ "no instruction can load this module whatever the appup says"
    end

    test "removal coverage expands over the baseline's .app, not the target's", ctx do
      # The removal half of the same rule, and the case that pins `covers/4`
      # itself rather than the modules-list check above - nothing here is
      # unresolvable, so only the coverage question can fail.
      #
      # `restart_application` removes every module of the *old* application,
      # which is `PreAppls`, which is the baseline's `.app` list. A module on
      # disk in the baseline that its own `.app` does not name is therefore not
      # removed by one; with the target no longer carrying it, the old code stays
      # loaded and nothing says so.
      drop_from_inventory!(ctx.from, @from, Sample.Unmentioned)
      remove_beam!(ctx.to, @to, Sample.Unmentioned)

      set_appup!(ctx.to, @to, [{:restart_application, :sample}], [{:restart_application, :sample}])

      {output, status} = appup(both(ctx))

      assert status != 0,
             "restart_application covered a removal the baseline's .app does not name:" <>
               "\n\n#{output}"

      assert output =~ "Sample.Unmentioned was removed, and no instruction deletes it"
    end

    test "an instruction covering the whole application covers every module", ctx do
      # `systools_rc:translate_application_instrs/3` expands `restart_application`
      # into a `remove` for every module of the old application and an
      # `add_module` for every module of the new one, so it genuinely covers
      # everything and there is nothing left to be missing.
      set_appup!(ctx.to, @to, [{:restart_application, :sample}], [{:restart_application, :sample}])

      output = appup!(both(ctx))

      assert output =~ "every module that moved is covered"
      refute output =~ "Sample.Unmentioned"
    end
  end

  describe "a .app whose modules list systools will not accept" do
    test "is reported even on an edge that restarts the emulator", ctx do
      # A fact about the resource file rather than about an edge, so it has to be
      # said independently of the restart exemption. It used to be left implicit -
      # a malformed value reads as an empty inventory, an empty inventory resolves
      # nothing, so every module that moved was reported and the run could not
      # exit zero - but that reasoning is emergent, and it leaked twice: once
      # through a partially malformed list whose surviving atoms could still be
      # covered, and once here, where `unresolvable/2` never runs at all.
      #
      # `systools_make:check_item/2` refuses the whole value as a `bad_param`
      # before it builds anything, so the edge is dead whichever direction is
      # asked about.
      malform_inventory!(ctx.to, @to)
      restart = [:restart_emulator]
      set_appup!(ctx.to, @to, restart, restart)

      {output, status} = appup(both(ctx))

      assert status != 0, "a malformed modules list passed on a restart edge:\n\n#{output}"
      assert output =~ "has no modules list that :systools will accept"
      assert output =~ "bad_param"

      # The restart is still reported for what it is, rather than the resource
      # finding swallowing it.
      assert output =~ "the emulator restarts on this edge"
    end

    test "is reported for an application that exists on only one side", ctx do
      # The appup question is genuinely moot for an application the transition
      # adds or removes - `:systools` writes the instruction itself - but "no
      # appup needed" and "this resource is one systools_make refuses" are
      # different claims, and only the first was being made. So the one side
      # there is still gets its modules list read.
      remove_beam!(ctx.to, @to, Sample.Unmentioned)
      malform_inventory!(ctx.from, @from)

      # `sample` is in the baseline and not in the target, which is the branch
      # that used to return without reading the resource at all.
      dir = Path.join(ctx.to, "lib/sample-#{@to}")
      moved = Path.join(ctx.to, "lib/moved-aside")
      File.rename!(dir, moved)
      on_exit(fn -> File.rename!(moved, dir) end)

      {output, status} = appup(both(ctx))

      assert status != 0, "a malformed resource on the sole side passed:\n\n#{output}"
      assert output =~ "an application removed between the two"
      assert output =~ "has no modules list that :systools will accept"
    end
  end

  describe "an application whose version did not move" do
    test "is reported, because :systools would consult no appup for it", ctx do
      # Made by rewriting the target's `.app`, which is where the version an
      # appup entry is keyed by comes from at this level - there is no `.rel` in
      # a `mix compile` build and the directory name does not carry it either.
      set_app_vsn!(ctx.to, @to, @from)

      {output, status} = appup(both(ctx))

      assert status != 0, "modules moved under an unchanged version passed:\n\n#{output}"
      assert output =~ "the application is #{@from} in both"
      assert output =~ "Bump the version."
    end
  end

  describe "naming an application" do
    test "reaches a dependency's appup", ctx do
      # The dependency-appup case. `:sample_dep`'s version moves with the
      # fixture's and its appup deliberately asks for nothing, so its own module
      # changed and is mentioned nowhere - which is a real gap rather than a
      # contrived one, and is invisible to the default set of applications.
      {output, status} = appup(both(ctx, "sample_dep"))

      assert status != 0, "a dependency whose appup covers nothing passed:\n\n#{output}"
      assert output =~ "sample_dep #{@from} -> #{@to}"
      assert output =~ "SampleDep changed, and no instruction loads it"
    end

    test "refuses an application that is in neither build", ctx do
      {output, status} = appup(both(ctx, "nonesuch"))

      assert status != 0, "an application in neither build was accepted:\n\n#{output}"
      assert output =~ "nonesuch is in neither"
    end
  end

  describe "arguments" do
    test "--from is required" do
      {output, status} = appup([])

      assert status != 0, "the check ran without a baseline:\n\n#{output}"
      assert output =~ "--from is required"
    end

    test "--from may be given once", ctx do
      spec = "rel:" <> rel(ctx.from, @from)
      {output, status} = appup(["--from", spec, "--from", spec])

      assert status != 0, "--from was accepted twice:\n\n#{output}"
      assert output =~ "--from may be given once, but was given 2 times"
    end

    test "an unrecognised argument is refused rather than dropped", ctx do
      {output, status} = appup(both(ctx) ++ ["--fromto", rel(ctx.from, @from)])

      assert status != 0, "an unrecognised switch was dropped:\n\n#{output}"
      assert output =~ "Unrecognised arguments: \"--fromto\""
    end

    test "a bare path is still a path to an assembled release", ctx do
      # The compatibility half of the baseline grammar, asserted here as well as
      # in the relup suite because this task takes specs on switches of its own.
      {output, status} = appup(["--from", rel(ctx.from, @from), "--to", rel(ctx.to, @to)])

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "sample #{@from} -> #{@to}"
    end

    test "a baseline whose library directory is not there is refused, not passed", ctx do
      # The regression this exists for, and it is the worst answer a gate can
      # give. Every application looks absent from a library directory that is
      # not there, and an absent application reads as one added or removed
      # between the two builds - which needs no appup. So a mistyped `--from`
      # reported "an application added between the two" and exited **zero**,
      # having compared nothing at all.
      #
      # `Forecastle.Baseline` resolves a `rel:` spec without touching the
      # filesystem, deliberately, so nothing upstream was going to catch it, and
      # this task reads no `.rel` - so nothing downstream was either.
      {output, status} = appup(["--from", "rel:/nowhere/does/not/exist/sample"])

      assert status != 0, "a baseline that is not on disk passed the check:\n\n#{output}"
      assert output =~ "is not a library directory of a build"
      refute output =~ "an application added between the two"

      # And the target side gets the same treatment, since the same inference is
      # made about it.
      #
      # **This half was a real hole, and it only showed on Linux.** The library
      # directory of a `rel:` spec is three levels up from the `.rel` path, so
      # `rel:/nope/x` resolves to `/lib` - which does not exist on macOS, where
      # the listing failed and the refusal fired, but *is* the system library
      # directory on Linux, where the listing succeeded, held no application
      # being checked, and made every one of them read as removed between the two
      # builds. A removal needs no appup, so the run reported everything covered
      # and exited zero. Being readable is not the same as being a library
      # directory, so that is now decided structurally rather than by whether the
      # path resolves - and one phrase covers both symptoms, since which one a
      # machine shows is an accident of its filesystem.
      {output, status} = appup(["--from", "rel:" <> rel(ctx.from, @from), "--to", "rel:/nope/x"])

      assert status != 0, "a target that is not on disk passed the check:\n\n#{output}"
      assert output =~ "is not a library directory of a build"
      refute output =~ "an application removed between the two"
      refute output =~ "every module that moved is covered"
    end

    test "a library directory that is readable but holds no application is refused", ctx do
      # The case above, made to happen on every platform rather than only where
      # the resolved path happens to exist. `/lib` is a directory on Linux and
      # absent on macOS, so the hole it exposed was invisible on half the CI
      # matrix - and the point is not that `/lib` in particular resolves, it is
      # that *any* readable directory did.
      #
      # Shaped like the thing it stands in for: a couple of ordinary system
      # directories, no `ebin` anywhere. The spec resolves three levels up, so
      # `.../a/b/c/sample` puts the library directory at `.../a/lib`.
      root = Path.join(Fixture.workspace(), "not-a-lib-dir")
      File.rm_rf!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      File.mkdir_p!(Path.join(root, "a/lib/x86_64-linux-gnu"))
      File.mkdir_p!(Path.join(root, "a/lib/systemd"))

      {output, status} =
        appup([
          "--from",
          "rel:" <> rel(ctx.from, @from),
          "--to",
          "rel:" <> Path.join(root, "a/b/c/sample")
        ])

      assert status != 0, "a readable non-library directory passed the check:\n\n#{output}"
      assert output =~ "is not a library directory of a build"
      assert output =~ "nothing in it is an application directory with an ebin in it"
      refute output =~ "an application removed between the two"
      refute output =~ "every module that moved is covered"
    end

    test "a library path containing glob metacharacters is read, not silently skipped", ctx do
      # The narrower form of the same silent pass. Discovery used to build a
      # `{app,app-*}/ebin` wildcard out of the library path, and
      # `:filelib.wildcard/1` has no way to quote the part of a pattern that is
      # itself a path - so a project under a directory named `a{b}` matched
      # nothing, every application looked absent, and the run exited zero.
      #
      # Reached through a symlink rather than a second assembly, since only the
      # path has to be odd. `File.rm/1` rather than `rm_rf`, so that a mistake
      # here can only take away the link.
      linked = Path.join(Fixture.workspace(), "appup-from{brace}")
      File.rm(linked)
      File.ln_s!(ctx.from, linked)
      on_exit(fn -> File.rm(linked) end)

      {output, status} =
        appup(["--from", "rel:" <> Path.join(linked, "releases/#{@from}/sample")])

      assert status != 0, "a baseline under a glob-metacharacter path passed:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"
      refute output =~ "an application added between the two"
    end

    test "a build holding only a hyphenated sibling reports the application absent", ctx do
      # The application is gone from the target and the only thing left matching
      # the `sample-` prefix belongs to something else. Treating that as the match
      # meant refusing over a missing `sample.app` in somebody else's directory,
      # which names the wrong problem: `sample` is simply not in this build, and
      # `:systools` covers that with `remove_application` without an appup.
      #
      # The `.app` resource settles identity, and a directory holding *another*
      # application's resource is the evidence that this one is absent rather than
      # unfinished - which is the distinction that keeps the incomplete-build
      # refusal alive beside this.
      real = Path.join(ctx.to, "lib/sample-#{@to}")
      moved = Path.join(ctx.to, "lib/moved-aside")
      decoy = Path.join(ctx.to, "lib/sample-decoy-9.9.9")

      File.rename!(real, moved)
      File.mkdir_p!(Path.join(decoy, "ebin"))
      File.write!(Path.join(decoy, "ebin/something_else.app"), "")

      on_exit(fn ->
        File.rm_rf!(decoy)
        File.rename!(moved, real)
      end)

      {output, status} = appup(both(ctx))

      assert status == 0, "an absent application was not read as absent:\n\n#{output}"
      assert output =~ "an application removed between the two"
      refute output =~ "could not be read as an application resource"
      refute output =~ "holds no ebin directory"
    end

    test "a sibling whose resource is not a usable file is refused, not read as absent", ctx do
      # The two questions asked about a candidate - is it ours, is it somebody
      # else's - have to share one notion of a usable resource, or they disagree.
      # They did: "ours" required a regular file while "somebody else's" only
      # matched the `.app` extension, so an `ebin` holding nothing but a
      # `sample.app` that is a *directory* answered no to the first and yes to the
      # second. That reads as another application's directory, which makes this
      # one absent, which makes the transition a removal needing no appup - a
      # broken build exiting zero.
      real = Path.join(ctx.to, "lib/sample-#{@to}")
      moved = Path.join(ctx.to, "lib/moved-aside")
      broken = Path.join(ctx.to, "lib/sample-#{@to}")

      File.rename!(real, moved)
      File.mkdir_p!(Path.join(broken, "ebin/sample.app"))

      on_exit(fn ->
        File.rm_rf!(broken)
        File.rename!(moved, real)
      end)

      {output, status} = appup(both(ctx))

      assert status != 0, "a candidate with an unusable resource passed as absent:\n\n#{output}"
      refute output =~ "an application removed between the two"
      refute output =~ "every module that moved is covered"
    end

    test "a hyphenated sibling application does not make the name ambiguous", ctx do
      # `sample-` cannot match `sample_dep-0.1.0`, but the prefix is not on its
      # own a version delimiter: an application name is an atom and `foo-bar` is a
      # legal one, so a build holding both `foo` and `foo-bar` matched twice and
      # the ambiguity refusal fired on a build that is perfectly clear.
      #
      # The `.app` resource settles it, since it is named for the application
      # rather than for the directory - `sample-other-9.9.9/ebin` holds no
      # `sample.app`. Built as a directory rather than by assembling a second
      # release, since only the naming has to be odd.
      other = Path.join(ctx.from, "lib/sample-other-9.9.9")
      File.mkdir_p!(Path.join(other, "ebin"))
      File.write!(Path.join(other, "ebin/sample_other.app"), "")
      on_exit(fn -> File.rm_rf!(other) end)

      {output, status} = appup(both(ctx))

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "sample #{@from} -> #{@to}"
      refute output =~ "more than once"
    end

    test "an application directory with no ebin is refused, not read as absent", ctx do
      # The same hole one level further in: the library directory is there, the
      # application's directory is there, and it holds no compiled modules. That
      # is an incomplete build, not a transition that adds an application.
      # Moved *inside* the application's own directory rather than beside it: a
      # sibling named `sample-...` anything is a second copy of the application
      # as far as discovery is concerned, and would be refused as ambiguous -
      # which is correct behaviour, and not the refusal under test here.
      dir = Path.join(ctx.from, "lib/sample-#{@from}")
      ebin = Path.join(dir, "ebin")
      moved = Path.join(dir, "ebin.moved")

      File.rename!(ebin, moved)
      on_exit(fn -> File.rename!(moved, ebin) end)

      {output, status} = appup(both(ctx))

      assert status != 0, "an application with no ebin passed the check:\n\n#{output}"
      assert output =~ "holds no ebin directory"
      refute output =~ "an application removed between the two"
    end

    test "an application entry that is a regular file is refused, not read as absent", ctx do
      # The third form of the same silent pass, and the narrowest. Discovery
      # matched the name and then dropped anything that was not a directory, so a
      # regular file named for the application left it looking **absent** - which
      # reads as an application removed between the two builds, needs no appup,
      # and exits zero having compared nothing.
      #
      # Moved to a name discovery cannot match, so the only thing claiming to be
      # the application is the file.
      with_replaced_app_dir!(ctx.from, @from, fn path -> File.write!(path, "") end)

      {output, status} = appup(both(ctx))

      assert status != 0, "a regular file named for the application passed:\n\n#{output}"
      assert output =~ "none of which is a directory"
      refute output =~ "an application removed between the two"
    end

    test "an application entry that is a dangling symlink is refused too", ctx do
      # The same hole through a link rather than a file, and on the other side of
      # the comparison, since the inference is made about both. `File.dir?/1`
      # follows the link and answers false, which is indistinguishable from an
      # entry that was never there.
      with_replaced_app_dir!(ctx.to, @to, fn path ->
        File.ln_s!(Path.join(Fixture.workspace(), "nothing-is-here"), path)
      end)

      {output, status} = appup(both(ctx))

      assert status != 0, "a dangling symlink named for the application passed:\n\n#{output}"
      assert output =~ "none of which is a directory"
      refute output =~ "an application added between the two"
    end

    test "a non-directory beside a real one is passed over rather than refused", ctx do
      # The other half of the rule, and why the refusal is about an application
      # with *nothing but* such entries. A legacy `sample-<vsn>.ez` archive
      # matches the prefix and is not what the upgrade would read; the directory
      # beside it is. Refusing here would break a layout that works.
      archive = Path.join(ctx.from, "lib/sample-#{@from}.ez")
      File.write!(archive, "")
      on_exit(fn -> File.rm(archive) end)

      {output, status} = appup(both(ctx))

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "sample #{@from} -> #{@to}"
      refute output =~ "none of which is a directory"
    end

    test "an explicit --to compiles nothing of the current project", ctx do
      # The compile belongs to the default `--to` and to nothing else. It used to
      # be an `@requirements`, which runs before `run/1` and so before anything
      # has looked at the arguments - so a comparison of two artefacts, neither
      # of them this checkout, waited for a compile of a working tree it was not
      # going to read, and would have failed outright had that tree not compiled.
      #
      # Asserted against a build root of its own, so that what is observed is
      # this run and not an artefact of an earlier one. Mix still puts the
      # dependencies on the code path there - it has to, since this very task
      # lives in one - which is why the assertion is about a beam the *fixture's*
      # own source would have produced.
      root = Path.join(Fixture.workspace(), "_build-untouched")
      File.rm_rf!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} =
        Fixture.mix(["castle.appup" | both(ctx)], [{"SAMPLE_VSN", @to}, {"MIX_BUILD_ROOT", root}])

      assert status != 0, "an incomplete appup passed the check:\n\n#{output}"
      assert output =~ "Sample.Unmentioned changed, and no instruction loads it"

      refute File.exists?(Path.join(root, "prod/lib/sample/ebin/Elixir.Sample.beam")),
             "the current project was compiled for a run that reads two named builds"
    end

    test "a mistyped spec is reported as a spec", ctx do
      {output, status} = appup(["--from", "re:" <> rel(ctx.from, @from)])

      assert status != 0, "a mistyped baseline spec was read as a path:\n\n#{output}"
      assert output =~ "there is no such source"
    end
  end

  ## Running the task

  defp appup(args, vsn \\ @to), do: Fixture.mix(["castle.appup" | args], build_env(vsn))

  defp appup!(args, vsn \\ @to) do
    {output, status} = appup(args, vsn)

    assert status == 0, "mix castle.appup exited #{status}:\n\n#{output}"

    output
  end

  # The two switches spelled out, since almost every case wants them and the
  # cases that do not are about the defaults.
  defp both(ctx, app \\ "sample") do
    ["--from", "rel:" <> rel(ctx.from, @from), "--to", "rel:" <> rel(ctx.to, @to), "--app", app]
  end

  # The build root the fixture was assembled with, so that the `compile` this
  # task requires is the no-op it should be and the default `--to` is the build
  # `assemble!/1` produced.
  defp build_env(vsn) do
    [{"SAMPLE_VSN", vsn}, {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{vsn}")}]
  end

  defp rel(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  defp ebin(release, vsn, app \\ "sample"), do: Path.join(release, "lib/#{app}-#{vsn}/ebin")

  ## Rewriting the assembled trees

  # The appup in the assembled target release, not the fixture's source: this
  # suite owns the releases it assembled, and the source is shared with every
  # other suite - and is deliberately incomplete, which is what the default case
  # here asserts. Restored regardless, since the trees are reused across the
  # tests in this module.
  #
  # `:instructions` wraps the two lists in an entry for the from-version, which
  # is what almost every case wants; `:entries` takes the entry lists as given,
  # for the cases that are about which from-version the entry is keyed by.
  defp set_appup!(release, vsn, ups, downs, shape \\ :instructions, opts \\ []) do
    file = Path.join(ebin(release, vsn), "sample.appup")
    {:ok, [{appup_vsn, _ups, _downs}]} = consult_and_restore!(file)

    write_term!(
      file,
      {Keyword.get(opts, :tag, appup_vsn), entries(shape, ups), entries(shape, downs)}
    )
  end

  defp entries(:entries, entries), do: entries
  defp entries(:instructions, instructions), do: [{to_charlist(@from), instructions}]

  defp set_app_vsn!(release, vsn, app_vsn) do
    file = Path.join(ebin(release, vsn), "sample.app")
    {:ok, [{:application, app, opts}]} = consult_and_restore!(file)

    write_term!(file, {:application, app, Keyword.put(opts, :vsn, to_charlist(app_vsn))})
  end

  # A `.app` whose `modules` list no longer names a module whose beam is still in
  # `ebin`, which is the state a project supplying its own `modules:` in
  # `application/0` produces - `Mix.Tasks.Compile.App` fills that key in with
  # `Keyword.put_new_lazy/3` and keeps whatever is there.
  defp drop_from_inventory!(release, vsn, module) do
    file = Path.join(ebin(release, vsn), "sample.app")
    {:ok, [{:application, app, opts}]} = consult_and_restore!(file)

    modules = Keyword.fetch!(opts, :modules)

    assert module in modules, "#{module} was not in the .app modules list to begin with"

    write_term!(file, {:application, app, Keyword.put(opts, :modules, modules -- [module])})
  end

  # A `modules` list with a non-atom in it, which `systools_make:a_list_p/1`
  # refuses whole rather than filtering. One bad element is all it takes, and the
  # rest of the list staying valid is the point: a surviving subset is what used
  # to be covered.
  defp malform_inventory!(release, vsn) do
    file = Path.join(ebin(release, vsn), "sample.app")
    {:ok, [{:application, app, opts}]} = consult_and_restore!(file)

    modules = Keyword.fetch!(opts, :modules)

    write_term!(file, {:application, app, Keyword.put(opts, :modules, modules ++ [~c"bad"])})
  end

  defp remove_appup!(release, vsn, app) do
    file = Path.join(ebin(release, vsn, app), "#{app}.appup")
    remove_and_restore!(file)
  end

  defp remove_beam!(release, vsn, module) do
    file = Path.join(ebin(release, vsn), "#{module}.beam")
    remove_and_restore!(file)
  end

  # Takes the application's directory out of the way and puts whatever `place`
  # makes there instead, so that the only entry discovery can match is the thing
  # under test. The directory is renamed to a name discovery cannot match -
  # anything beginning `sample-` would be a second copy of the application, which
  # is refused as ambiguous, and that is not the refusal under test.
  defp with_replaced_app_dir!(release, vsn, place) do
    dir = Path.join(release, "lib/sample-#{vsn}")
    moved = Path.join(release, "lib/moved-aside")

    File.rename!(dir, moved)

    on_exit(fn ->
      File.rm(dir)
      File.rename!(moved, dir)
    end)

    place.(dir)
  end

  defp remove_and_restore!(file) do
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    File.rm!(file)
  end

  defp consult_and_restore!(file) do
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    :file.consult(to_charlist(file))
  end

  defp write_term!(file, term) do
    File.write!(file, IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [term])))
  end

  ## Rewriting a beam

  # A module whose *persisted attributes* differ and whose code does not, made by
  # rebuilding the beam's own `Attr` chunk rather than by compiling a second
  # source. That is the only way to isolate the property under test: compiling a
  # module with a different `@vsn` would be a fair fixture only if nothing else
  # about the beam moved, and nothing guarantees that.
  #
  # The two assertions inside are the discriminator, not decoration. If the md5
  # moved, the case would pass against a check that compares md5 alone and would
  # be asserting nothing at all.
  defp assert_attribute_only_change!(release, vsn, module) do
    file = Path.join(ebin(release, vsn), "#{module}.beam")
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    {:ok, _module, chunks} = :beam_lib.all_chunks(original)
    {~c"Attr", data} = Enum.find(chunks, &match?({~c"Attr", _data}, &1))
    marked = :erlang.term_to_binary([{:castle_probe, [:changed]} | :erlang.binary_to_term(data)])

    rebuilt =
      Enum.map(chunks, fn
        {~c"Attr", _data} -> {~c"Attr", marked}
        other -> other
      end)

    {:ok, patched} = :beam_lib.build_module(rebuilt)
    File.write!(file, patched)

    assert :beam_lib.md5(original) == :beam_lib.md5(patched),
           "the rewrite moved the md5, so this fixture says nothing about attributes"

    refute decoded_attributes(original) == decoded_attributes(patched),
           "the rewrite did not change the attributes"
  end

  # A beam rebuilt without its `Attr` chunk, which is what `:beam_lib.strip/1`
  # leaves behind. The two assertions are the discriminator: the chunk really has
  # to be gone, and the md5 really has to still be readable, or the case says
  # nothing about what the check does with such a beam.
  defp strip_attributes!(release, vsn, module) do
    file = Path.join(ebin(release, vsn), "#{module}.beam")
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    {:ok, _module, chunks} = :beam_lib.all_chunks(original)
    {:ok, stripped} = :beam_lib.build_module(Enum.reject(chunks, &match?({~c"Attr", _data}, &1)))

    File.write!(file, stripped)

    assert match?({:error, :beam_lib, _reason}, :beam_lib.chunks(stripped, [:attributes])),
           "the Attr chunk survived, so this fixture says nothing about a beam without one"

    assert match?({:ok, {^module, _md5}}, :beam_lib.md5(stripped)),
           "the rewrite made the beam unreadable, so the refusal under test is the wrong one"
  end

  defp attributes(beam), do: beam |> File.read!() |> decoded_attributes()

  defp decoded_attributes(binary) do
    {:ok, {_module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    attributes
  end

  ## Guards on the fixture

  # That the release really is stripped, so that the case above is the one it
  # says it is. A fixture that only sometimes produces the state it names is a
  # test that only sometimes tests anything, and this one would pass vacuously
  # against unstripped release beams - there would be nothing for a byte digest
  # to get wrong.
  defp assert_stripped!(release) do
    beam = "Elixir.Sample.Application.beam"
    released = Path.join(ebin(release, @from), beam)
    built = Path.join([Fixture.workspace(), "_build-#{@from}/prod/lib/sample/ebin", beam])

    assert File.exists?(released) and File.exists?(built),
           "expected #{beam} in both #{released} and #{built}"

    refute File.read!(released) == File.read!(built),
           "the release's beams are not stripped, so this case proves nothing about " <>
             "how change is detected"

    assert :beam_lib.md5(to_charlist(released)) == :beam_lib.md5(to_charlist(built)),
           "identical code compared unequal across stripping"
  end
end
