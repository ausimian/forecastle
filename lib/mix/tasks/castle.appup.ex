defmodule Mix.Tasks.Castle.Appup do
  @moduledoc """
  Report how an application's appup covers the modules that changed.

  This task is provided by `Forecastle`, Castle's build-time half, and named for
  `Castle` because that is the package a project depends on.

      mix castle.appup --from <spec> [--to <spec>] [--app <app>]...

  It is read-only: it writes no appup, no relup and nothing into any release. It
  exits non-zero when a module that moved is covered by no instruction, which is
  what makes it usable as a release-pipeline gate.

  ## The failure it exists to catch

  `Mix.Tasks.Compile.Appup` never sees a second version of the application, so
  it cannot tell whether the instructions it compiles are *right*. Nothing
  downstream closes that gap either. `:systools.make_relup/4` fails when an
  appup has no **entry** for the from-version being upgraded from - but it does
  not, and cannot, notice that an entry is **incomplete**.

  If modules `A` and `B` both changed and the appup mentions only `A`,
  `make_relup/4` produces a relup, the upgrade succeeds, `release_handler` swaps
  the code path, and `B` is still the version that was loaded before, serving
  calls, because nothing named it and nothing purged it. New code sits on disk,
  reachable, unused. The upgrade reports success, and the code silently changes
  underneath the system on the next restart, which nobody was upgrading.

  That failure is invisible to the compiler, to `:systools`, to `--hot` and at
  install time. This is where it becomes visible.
  `Forecastle.UpgradeTest` pins that it really happens.

  ## What it does not answer

  **It asks whether the appup names everything that moved. It does not ask
  whether the resulting script is one `systools_rc` will accept.** Those are
  different questions, and only the first needs help.

  `:systools.make_relup/4` *does* fail on a malformed script - loudly, and at the
  moment a relup is generated, which `mix castle.relup` does anyway. What it
  cannot see is an entry that is **incomplete**, which is the failure above. So
  script validity is deliberately somebody else's job: a project that runs this
  check and never generates a relup has verified its *coverage*, not its
  validity.

  Some invalid scripts are reported here anyway, because an instruction
  `:systools` will not accept covers nothing, and crediting one would overstate
  coverage. Those are cases this catches on the way to answering its own
  question, and not a promise that it catches every such script. It is not a
  substitute for `make_relup/4` and does not try to be one.

  ## Naming the two builds

  `--from` is a *baseline spec*: the same grammar `mix castle.relup` takes on
  its from-switches, naming an assembled release, a shipped artefact or a git
  ref. `Forecastle.Baseline` documents what each source costs.

      mix castle.appup --from rel:_build/prod/rel/my_app/releases/1.0.0/my_app
      mix castle.appup --from tar:artifacts/my_app-1.0.0.tar.gz
      mix castle.appup --from ref:1.0.0

  `--to` defaults to **the current build** rather than to an assembled release,
  so the everyday question - *what has changed since 1.0.0, and does my appup
  cover it?* - costs a `mix compile` and nothing more. Give it a spec to compare
  two things that already exist, and then nothing is compiled at all: a
  comparison of two artefacts does not need this working tree to be in a state
  that builds.

  Both are resolved at `Forecastle.Baseline`'s `:compile` level, so a `ref:`
  baseline is compiled rather than assembled. That is the whole reason the level
  exists.

  ## What it reports

  Per application, and per direction, because an appup's `up` and `dn` lists are
  independent and a from-version present in one need not be present in the
  other:

    * **changed or added, and no instruction *loads* it** - the failure above.
      `update`, `load_module`, `add_module` and the low-level `load` load;
      `delete_module` and the low-level `remove` do not, so a changed module
      left in either of those states is a gap and not a coverage.
    * **removed, and no instruction *deletes* it** - a missing `delete_module`.
    * **both loaded and removed by the same edge** - which of the two wins turns
      on the order `systools_rc` translates them into, and that is not the order
      they are written in: it hoists dependency-connected instructions past
      independent ones. Reported rather than resolved, because guessing it has
      been measured wrong in both directions. `Forecastle.Appup.effects/4` sets
      out why.
    * **defined by more than one instruction** - `systools_rc` builds a
      dependency graph of the instructions carrying `DepMods` and refuses a
      module with more than one vertex in it as `muldef_module`, so the edge
      produces no relup at all. An application-level instruction counts, through
      its expansion, so a `restart_application` beside an explicit `update` of
      one of that application's own modules is refused.
    * **deleted while still in the target build** - the mirror of the first, and
      worse than a stale module: `systools_rc` turns `delete_module` into a
      `remove` and a `purge` with no load, so the upgrade takes away code the
      release still has. `Forecastle.Appup` sets out where that split comes from.
    * **moved but not in the `.app`'s `modules` list** - a beam in `ebin` that
      the application resource does not name. `systools_rc:get_lib/2` resolves
      object code through that list and throws when no application in the release
      has the module, so *no* instruction can carry it and the appup is not where
      the problem is. Reported instead of a coverage gap, since it is the more
      fundamental fact.
    * **an instruction `:systools` will not accept** - reported as a gap, and
      credited with covering nothing. `systools_rc:check_syntax/1` refuses a
      shape outside its vocabulary as a `bad_instruction` before it translates
      anything, so the edge produces no relup at all. Reading such an
      instruction by its head alone was a false *pass*:
      `{restart_application, App, Anything}` looked like a whole-application
      instruction and covered the entire inventory of an appup that cannot be
      used.
    * **no entry at all for the from-version** - reported as a gap too, since
      every module that moved is then covered by nothing. This is the coarse
      failure rather than the subtle one: `:systools.make_relup/4` refuses such
      an edge outright, so an appup that deliberately offers no downgrade path
      is reported here as the same answer arriving earlier.
    * **mentioned but unchanged** - reported, and *not* a gap. It is usually a
      leftover naming the wrong module, and where it is, the module that really
      did change is covered by nothing and fails the check on its own account.
      An instruction that loads a module whose code is identical is inert, so
      failing a pipeline for one would be refusing a build for something that
      cannot go wrong.
    * **the application's version did not move** - a gap when anything else did.
      `:systools` compares application versions and consults no appup for one
      that did not change, so no instruction anywhere could carry that code.

  An edge that ends by restarting the emulator needs no module-level coverage at
  all, and nothing is reported about one: the code is going to be loaded from
  scratch by a new VM. `Forecastle.Appup` documents which edges those are, which
  is `systools_rc`'s answer rather than a reading of the appup's own ordering.

  **That exemption is per application, and it is sound in the direction it
  fires rather than complete.** `:systools` merges every application's script
  for one relup edge before `systools_rc:sort_emulator_restart/3` runs, so a
  restart named in *this* application's own entry really does restart the edge
  that entry belongs to - the exemption never lets a dangerous appup through.
  What it cannot see is a restart supplied by an application it was not asked
  about, or one `:systools` inserts for an ERTS change: there is no release here
  to read either out of, and at `:compile` level there is no `.rel` at all.
  Applications named in one invocation need not even be in one release, and each
  is checked against its own from-version rather than against a release version.
  Where a restart does come from elsewhere, this reports coverage gaps on an
  edge that would have restarted - the conservative direction - and
  `mix castle.relup` is what decides restarts properly, having both `.rel` files
  to do it with.

  **The same boundary, in its other form: an instruction is credited only to the
  application whose appup it is in.** `:systools` merges every application's
  script before translating it and resolves each module through the whole
  application list, so an instruction in *A*'s appup that names a module of *B*
  really does load it. This reports that module as a gap under *B* anyway, and
  says under *A* only that the module it names is in neither build of *A* and
  may belong to another application.

  That is the conservative direction of the same limit, and crediting it would
  need what this task has not got. Whether `:systools` consults *A*'s appup for
  this edge at all depends on whether *A*'s own version moved, and which
  applications share an edge is a fact about a release: `--app` may name two
  applications that are in no release together, each is checked against its own
  from-version, and at `:compile` level there is no `.rel` to settle it from. So
  the answer here is per application, and an appup that reaches across
  applications is reported rather than resolved.

  ## What is refused rather than reported

  An application that is in one build and not the other is a note: `:systools`
  covers both with `add_application` and `remove_application` and neither needs
  an appup. That makes *absence* a meaningful answer, which in turn makes
  anything that produces a spurious absence far more dangerous than an ordinary
  error - it exits zero. So each of these is refused by name instead of being
  read as an application this transition adds or removes:

    * a library directory that cannot be read
    * a library directory that can be read and is not one
    * an application directory with no `ebin` in it
    * an entry that is named for the application and is not a directory - a
      regular file, or a symlink with nothing at the end of it - where nothing
      else in the library directory is

  `Forecastle.Build` is where each of those lives, and where the failure each of
  them was reached through is recorded.

  ## Which applications

  `--app` may be given more than once. It defaults to the project's own
  applications plus any umbrella children - the same set `mix castle.relup`
  treats as the ones this project owns the appups for. Naming a dependency
  explicitly is how a dependency's appup gets checked.

  ## Change detection

  A module's fingerprint is `:beam_lib.md5/1` **and** its persisted attributes,
  and **not** a digest of the file bytes. `Forecastle.Build` is where that is
  read and why - a byte digest reports every module in a stripped release as
  changed, and the md5 alone misses an explicit `@vsn`. The same module is what
  `mix castle.appup.gen` diffs with, so the check and the generator cannot
  disagree about which modules moved.

  ## Compare like with like

  Nothing here can tell a change in the code from a change in how it was built.
  Two builds made with different `MIX_ENV`s, different Elixir versions or
  different dependency resolutions differ in modules that nobody edited, and
  this will report every one of them. That is the same drift `Forecastle.Baseline`
  recommends `tar:` to avoid: the artefact that shipped is the honest baseline.

  ## Not part of `mix precommit`

  It needs a baseline, and `precommit` has not got one. This is a
  release-pipeline gate.
  """
  @shortdoc "Report how an appup covers the modules that changed"

  use Mix.Task

  alias Forecastle.Appup
  alias Forecastle.Build

  # All `:keep`, including the switches that may appear only once, for the
  # reason `mix castle.relup` gives: `:string` silently keeps the last
  # occurrence, so a repeated switch would quietly answer a question other than
  # the one that was asked.
  @options [from: :keep, to: :keep, app: :keep]

  @directions [:up, :down]

  @impl Mix.Task
  def run(command_line_args) do
    Appup.ensure_systools!()

    args = parse!(command_line_args)

    # The applications and the target are settled before `--from` is resolved,
    # because resolving a baseline can mean unpacking an artefact or building a
    # commit, and spending minutes on that only to find `--app` names nothing is
    # the wrong order to fail in. `mix castle.relup` orders itself the same way.
    apps = apps!(args)
    to = target!(args)
    from = baseline!(args)

    # Every application is examined before anything is printed, and that ordering
    # is deliberate twice over. It is what lets the report and the exit status be
    # derived from one value rather than from two passes that could disagree; and
    # it means a refusal - a library directory that cannot be read, an application
    # in neither build - prints no report at all, rather than half of one that
    # reads as the answer while the run is in fact declining to give one.
    apps
    |> Enum.map(&examine(&1, from, to))
    |> report!()
  end

  ## Arguments

  # `parse/2` discards what it does not recognise, which for a task whose every
  # argument names something would silently answer about a different pair of
  # builds than the one asked about.
  defp parse!(command_line_args) do
    case OptionParser.parse(command_line_args, strict: @options) do
      {cmdline_args, [], []} ->
        cmdline_args

      {_cmdline_args, argv, invalid} ->
        Mix.raise(
          "Unrecognised arguments: " <>
            Enum.map_join(Enum.map(invalid, &elem(&1, 0)) ++ argv, ", ", &inspect/1)
        )
    end
  end

  defp baseline!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :from) do
      [spec] ->
        Build.resolve!(spec, :compile)

      [] ->
        Mix.raise(
          "--from is required: an appup is instructions for a transition, and there is " <>
            "nothing to check them against without the version being upgraded from"
        )

      many ->
        Mix.raise(repeated("--from", many))
    end
  end

  defp target!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :to) do
      [] -> Build.current!()
      [spec] -> Build.resolve!(spec, :compile)
      many -> Mix.raise(repeated("--to", many))
    end
  end

  # Made unique, because the same application named twice is one application:
  # left in, it would be examined twice and its gaps counted twice, so the
  # summary would report more of them than the report above it listed. Order is
  # the order they were given in - a report that reorders its arguments is one
  # more thing to wonder about.
  defp apps!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :app) do
      [] -> project_apps!()
      names -> names |> Enum.map(&String.to_atom/1) |> Enum.uniq()
    end
  end

  defp project_apps! do
    case Appup.project_apps() do
      [] ->
        Mix.raise(
          "this project declares no application, so there is nothing to check by default. " <>
            "Name one with --app."
        )

      apps ->
        apps
    end
  end

  defp repeated(switch, values) do
    "#{switch} may be given once, but was given #{length(values)} times: " <>
      Enum.map_join(values, ", ", &inspect/1)
  end

  ## Examining one application

  # A result is a heading and a list of sections, and a section is a label - an
  # edge, or `nil` for something said about the application rather than about a
  # direction - and the findings under it. Keeping the shape uniform is what
  # lets the report be printed and the exit status derived from the same value,
  # rather than from a second pass that could disagree with what was printed.
  defp examine(app, from, to) do
    case {Build.ebin(from, app), Build.ebin(to, app)} do
      {nil, nil} ->
        Mix.raise(
          "#{app} is in neither #{from.describe} nor #{to.describe}. Nothing was compared."
        )

      # An application added or removed between the two is not a transition an
      # appup describes. `:systools` covers both with `add_application` and
      # `remove_application`, which are hot - nothing has to be changed in
      # place, only started or stopped - so there is nothing here to be missing.
      {nil, to_ebin} ->
        whole_application(
          app,
          to_ebin,
          "#{app} is in #{to.describe} and not in #{from.describe}: an application added " <>
            "between the two, which :systools covers with add_application."
        )

      {from_ebin, nil} ->
        whole_application(
          app,
          from_ebin,
          "#{app} is in #{from.describe} and not in #{to.describe}: an application removed " <>
            "between the two, which :systools covers with remove_application."
        )

      {from_ebin, to_ebin} ->
        compare(app, from_ebin, to_ebin)
    end
  end

  # The one side there is still gets its `modules` list looked at. The appup
  # question really is moot for an application the transition adds or removes -
  # `:systools` writes the instruction itself - but "no appup needed" and "this
  # resource is one `systools_make` refuses" are different claims, and only the
  # first was being made. A named application whose `.app` cannot be accepted is
  # reported wherever it lives, so that the answer does not depend on which side
  # of the transition it happens to be on.
  #
  # Only the `modules` list, and only for an application `--app` named: this is
  # not a release validator, and the resources of applications nobody asked about
  # are still `systools_make`'s business alone.
  defp whole_application(app, ebin, phrase) do
    resource = Path.join(ebin, "#{app}.app")
    {_vsn, _inventory, listed?} = Build.app_resource!(resource, app)

    %{
      heading: to_string(app),
      sections: [%{label: nil, findings: [{:note, phrase} | unlisted(resource, listed?)]}]
    }
  end

  defp compare(app, from_ebin, to_ebin) do
    from = Build.side!(from_ebin, app)
    to = Build.side!(to_ebin, app)

    heading = "#{app} #{from.vsn} -> #{to.vsn}"

    sections =
      if from.vsn == to.vsn do
        [unmoved(from.vsn, from.modules, to.modules)]
      else
        edges(app, from, to)
      end

    %{heading: heading, sections: [resources(from, to) | sections]}
  end

  # **A `.app` whose `modules` value `:systools` will not accept, said once about
  # the build rather than left to emerge from the coverage question.** It is a
  # fact about the resource file and not about an edge, so it is reported here -
  # per side, before any direction is considered - and that is what makes it
  # independent of the restart exemption.
  #
  # It used to be left implicit: a malformed value reads as an empty inventory,
  # an empty inventory resolves nothing, so every module that moved was reported
  # by `unresolvable/2` and the run could not exit zero. That reasoning was
  # sound but *emergent*, and it leaked twice - once through a partially
  # malformed list whose surviving atoms could still be covered, and once through
  # a direction whose script restarts the emulator, where `unresolvable/2` never
  # runs at all. Two leaks in one property is the property being the wrong place
  # to put the guarantee, so the guarantee is stated directly instead.
  #
  # `systools_make:check_item/2` is still not reimplemented here. This is the one
  # key this task actually reads, and it is reported rather than validated in
  # general: the version is already refused if it is not a string, and nothing
  # else in the resource is consulted.
  defp resources(from, to) do
    findings = Enum.flat_map([from, to], &unlisted(&1.resource, &1.listed?))

    %{label: nil, findings: findings}
  end

  defp unlisted(_resource, true), do: []

  defp unlisted(resource, false) do
    [
      {:gap,
       "#{Path.relative_to_cwd(resource)} has no modules list that :systools will accept - " <>
         "it is missing, or it is not a list of atoms. systools_make refuses that as a " <>
         "missing_param or a bad_param before it builds anything, and it is what an " <>
         "application-level instruction expands over, so nothing here can be judged against " <>
         "it."}
    ]
  end

  # An application whose version did not move is one `:systools` will not
  # consult an appup for at all - `release_handler` compares versions, and an
  # unchanged one is not a transition. So modules that differ under an unchanged
  # version are carried by nothing, whatever the appup says, and there is no
  # instruction that could be added to fix it. The remedy is the version, so the
  # finding names the version rather than listing the modules.
  defp unmoved(vsn, from_modules, to_modules) do
    {changed, added, removed} = Build.moved(from_modules, to_modules)
    count = length(changed) + length(added) + length(removed)

    findings =
      if count == 0 do
        []
      else
        [
          {:gap,
           "#{count} #{plural(count, "module")} differ between the two builds, but the " <>
             "application is #{vsn} in both. :systools consults no appup for an application " <>
             "whose version did not change, so no instruction anywhere can carry this code. " <>
             "Bump the version."}
        ]
      end

    %{label: nil, findings: findings}
  end

  defp edges(app, from, to) do
    file = Path.join(to.ebin, "#{app}.appup")

    case Appup.read(file) do
      {:error, phrase} ->
        [
          %{
            label: nil,
            findings: [{:gap, "#{phrase}, so nothing covers the move from #{from.vsn}"}]
          }
        ]

      {:ok, appup} ->
        [
          bad_vsn(appup, to.vsn, file)
          | for(direction <- @directions, do: edge(direction, appup, app, from, to))
        ]
    end
  end

  # `systools_relup:get_script_from_appup/5` compares the appup's own version
  # tag against the application's and adds a `bad_vsn` warning when they differ.
  # It does not refuse, and it still uses the entry it found - so this is a note
  # rather than a gap, which is exactly what `:systools` makes of it.
  defp bad_vsn(appup, to_vsn, file) do
    tagged = to_string(Appup.vsn(appup))

    findings =
      if tagged == to_vsn do
        []
      else
        [
          {:note,
           "#{Path.relative_to_cwd(file)} is tagged #{tagged} and the application is " <>
             "#{to_vsn}. :systools warns bad_vsn for that and uses the entry anyway."}
        ]
      end

    %{label: nil, findings: findings}
  end

  # Each direction on its own, and each with its own idea of which build is the
  # old one. An upgrade goes from the baseline to the target; a downgrade goes
  # back, so what was added on the way up is removed on the way down. The
  # from-version is the same either way, because an appup's `dn` list is keyed
  # by the version being downgraded *to* - see `Forecastle.Appup`.
  defp edge(:up, appup, app, from, to) do
    edge(:up, "upgrade from #{from.vsn}", appup, app, from.vsn, from, to)
  end

  defp edge(:down, appup, app, from, to) do
    edge(:down, "downgrade to #{from.vsn}", appup, app, from.vsn, to, from)
  end

  defp edge(direction, label, appup, app, from_vsn, old, new) do
    entries = Appup.entries(appup, direction)

    findings =
      case Appup.script(entries, from_vsn) do
        :error -> [{:gap, no_entry(direction, from_vsn)}]
        {:ok, script} when is_list(script) -> findings(script, direction, app, old, new)
        {:ok, _malformed} -> [{:gap, malformed_entry(direction, from_vsn)}]
      end

    %{label: label, findings: findings}
  end

  defp no_entry(direction, from_vsn) do
    "the appup has no #{word(direction)} entry for #{from_vsn}, so every module that moved " <>
      "is covered by nothing. This is the failure :systools.make_relup/4 refuses outright " <>
      "rather than the one it cannot see."
  end

  # `appup_search_for_version/2` hands back whatever the entry's second element
  # is, and an appup is arbitrary evaluated Elixir - so it need not be a list of
  # instructions. Said rather than crashed on: iterating it would raise a
  # protocol error naming neither the appup nor the from-version, and the
  # not-a-list case is one `:systools` refuses too.
  defp malformed_entry(direction, from_vsn) do
    "the appup's #{word(direction)} entry for #{from_vsn} is not a list of instructions, so " <>
      "nothing can be said about what it covers. :systools refuses such an entry as well."
  end

  defp word(:up), do: "upgrade"
  defp word(:down), do: "downgrade"

  # Nothing is *asked* of an edge that restarts the emulator: module-level
  # instructions are moot when the code is going to be loaded from scratch by a
  # new VM, so no gap can arise and none is reported.
  #
  # That it was skipped is still said, and the reason with it. A bare "nothing
  # missing" would be true and would let a reader take a restart transition for
  # a hot one that happens to be completely covered, which are very different
  # things to have just been told about a release.
  # **What `:systools` refuses outright is reported whichever branch is taken,
  # and the test for "outright" is where in `translate_merged_script/4` the
  # refusal happens.** Both of these are raised before
  # `sort_emulator_restart/3` is reached, so the edge produces no relup and the
  # emulator never restarts on it - reporting them only on the hot branch was a
  # clean exit for a script that cannot be built:
  #
  #   * a bad instruction, from the first `check_syntax/1`.
  #   * a `muldef_module`, from `translate_dependent_instrs/4`. Measured on OTP
  #     28.3: a script of `[restart_emulator, {update, M, …}, {load_module, M,
  #     …}]` still fails with `{muldef_module, M}`, while `restart_emulator`
  #     with a single instruction is fine.
  #   * a `removed_application_present`, from `translate_application_instrs/3`
  #     under `translate_independent_instrs/4`.
  #
  # Coverage is the thing a restart really does excuse, and it stays inside the
  # branch.
  defp findings(script, direction, app, old, new) do
    refusals(script) ++
      misplaced(script) ++
      multiply_defined(script, app, new.inventory) ++
      self_removals(script, app) ++
      if Appup.restarts_emulator?(script, direction) do
        [
          {:note,
           "the emulator restarts on this edge, so no module-level instruction is needed and " <>
             "no coverage is reported for it"}
        ]
      else
        two_stage(script, direction) ++ coverage(script, app, old, new)
      end
  end

  # An instruction whose shape is not one `:systools` accepts, and which is
  # therefore credited with covering nothing - see `Forecastle.Appup.refused/1`
  # for why crediting one by its head alone was a false *pass* rather than merely
  # an inaccuracy. Said as well as not credited, because a reader told that a
  # module is uncovered needs to know that the instruction naming it is the
  # reason, rather than going looking for one that is already there.
  defp refusals(script) do
    for instruction <- Appup.refused(script) do
      {:gap,
       "#{inspect(instruction)} is not an instruction :systools accepts. " <>
         "systools_rc:check_syntax/1 refuses it as a bad_instruction, so no relup is " <>
         "produced for this edge at all, and it covers nothing here."}
    end
  end

  # Worth saying even though this task decides nothing about it: a reader who
  # got a clean bill here and then met `mix castle.relup`'s refusal would have
  # been told the appup was fine by something that had read the instruction and
  # said nothing.
  defp two_stage(script, direction) do
    if Appup.two_stage_restart?(script, direction) do
      [
        {:note,
         "this edge asks for restart_new_emulator, which Castle does not support and " <>
           "mix castle.relup refuses. Coverage is still reported for it, because the rest " <>
           "of the relup runs after the reboot."}
      ]
    else
      []
    end
  end

  # Coverage is asked per *effect* rather than per mention, and that distinction
  # is the difference between a gate and a rubber stamp. `delete_module` does not
  # load anything - `systools_rc` translates it to a `remove` and a `purge` - so
  # a changed module named only by one is not merely uncovered, it is deleted out
  # of a release that still needs it. Asking "is this module mentioned?" reported
  # that as covered and exited zero. See `Forecastle.Appup`.
  #
  # And it is asked of the state each module is *left* in rather than of two sets,
  # because a set containing both a load and a removal of one module says nothing
  # about which of them wins. Where that cannot be settled without an order this
  # task does not model, `Forecastle.Appup.effects/4` says so and `conflicts/1`
  # reports it instead of guessing - see there for the five rounds of guessing
  # wrong that produced this.
  #
  # The inventories go in per direction: an application-level instruction expands
  # to whatever the `.app` names, and which `.app` depends on which way round the
  # edge runs. Loads come from the side being moved *to*, removals from the side
  # being moved *from*.
  defp coverage(script, app, old, new) do
    effects = Appup.effects(script, app, new.inventory, old.inventory)
    loads = for {module, :load} <- effects, into: MapSet.new(), do: module
    removals = for {module, :removal} <- effects, into: MapSet.new(), do: module
    {changed, added, removed} = Build.moved(old.modules, new.modules)

    # A module the target's `.app` does not name cannot be loaded by anything, so
    # it is reported for that rather than for the appup - which is the more
    # fundamental fact and the one that has to be fixed first. Taken out of the
    # coverage question entirely so that one module does not produce two gaps
    # saying different things about the same problem.
    resolvable? = &MapSet.member?(new.inventory, &1)

    uncovered(Enum.filter(changed, resolvable?), loads, "changed, and no instruction loads it") ++
      uncovered(
        Enum.filter(added, resolvable?),
        loads,
        "was added, and no instruction loads it: an add_module is missing"
      ) ++
      unresolvable(changed ++ added, new) ++
      uncovered(
        removed,
        removals,
        "was removed, and no instruction deletes it: a delete_module is missing"
      ) ++
      deleted_but_present(removals, new.modules) ++
      conflicts(effects) ++
      mentions(
        Appup.named(script, :load),
        Appup.named(script, :removal),
        old.modules,
        new.modules
      )
  end

  # A module the script both loads and removes, where which one wins turns on an
  # order this task does not model. Reported rather than resolved, because every
  # way of guessing it has been wrong: reading the script as two sets could not
  # see the conflict at all, and reading it in source order was wrong because
  # `systools_rc` hoists dependency-connected instructions past independent ones.
  # `Forecastle.Appup.effects/4` records the measurements.
  #
  # A gap, not a note. Whichever way it resolves, one of the two instructions is
  # not doing what its author meant, and a module that ends up removed when the
  # release still needs it is exactly the failure this task exists to catch.
  defp conflicts(effects) do
    for {module, {:conflict, instructions}} <- Enum.sort(effects) do
      {:gap,
       "#{inspect(module)} is both loaded and removed by this edge, by " <>
         Enum.map_join(instructions, " and ", &inspect/1) <>
         ". Which one wins depends on the order systools_rc translates them into, " <>
         "which is not the order they are written in - it hoists dependency-connected " <>
         "instructions past independent ones. This reports it rather than guessing."}
    end
  end

  # A module defined by more than one dependency-ordered instruction, which
  # `systools_rc` refuses as `muldef_module` before it produces anything. Worth
  # its own finding because it is reachable by an appup somebody might plausibly
  # write - `{restart_application, App}` beside an explicit `{update, M, …}` for
  # one of that application's own modules is refused, measured - and because the
  # coverage question alone would call such a module covered and exit zero.
  # A legal instruction in the wrong half of the script. `split_script/1` cuts at
  # an explicit `point_of_no_return` and `check_script/2` allows only
  # `load_object_code` and `apply` before it. Reported rather than credited-and-
  # forgotten, because the instruction itself is fine and only its position is
  # not - which is also why it is not a `refusals/1` finding.
  defp misplaced(script) do
    for instruction <- Appup.misplaced(script) do
      {:gap,
       "#{inspect(instruction)} comes before this entry's point_of_no_return, where " <>
         "systools_rc allows only load_object_code and apply. It refuses that as " <>
         "bad_op_before_point_of_no_return, so no relup is produced for this edge - the " <>
         "instruction is fine, its position is not."}
    end
  end

  # A `remove_application` naming the application whose appup this is.
  # `:systools` refuses it as `removed_application_present` whenever the
  # application is still in the release being moved to - and it always is here,
  # since an appup is only consulted for an application present in both builds.
  # See `Forecastle.Appup.self_removals/2` for why crediting it was a false pass
  # rather than merely generous.
  defp self_removals(script, app) do
    for instruction <- Appup.self_removals(script, app) do
      {:gap,
       "#{inspect(instruction)} removes the application this appup belongs to, which is " <>
         "still in the other build. systools_rc refuses that as " <>
         "removed_application_present, so no relup is produced for this edge, and it " <>
         "covers nothing here."}
    end
  end

  defp multiply_defined(script, app, inventory) do
    for module <- Appup.multiply_defined(script, app, inventory) do
      {:gap,
       "#{inspect(module)} is defined by more than one instruction. systools_rc builds a " <>
         "dependency graph of them and refuses a module with more than one vertex in it as " <>
         "muldef_module, so no relup is produced for this edge at all. An application-level " <>
         "instruction counts: it expands to an add_module for every module the .app names."}
    end
  end

  defp uncovered(modules, covered, phrase) do
    for module <- modules,
        not MapSet.member?(covered, module),
        do: {:gap, "#{inspect(module)} #{phrase}"}
  end

  # A beam in `ebin` that the `.app` resource does not name. `systools_rc`
  # resolves the object code for a `load_module` or an `update` through
  # `get_lib/2`, which searches `#application.modules` and throws
  # `{no_such_module, Mod}` when no application in the release has it - so no
  # instruction can carry this module and the appup is not where the problem is.
  # `Mix.Tasks.Compile.App` derives `:modules` from the compiled beams, but only
  # with `Keyword.put_new_lazy/3`, so a project that supplies its own list in
  # `application/0` keeps it, and that is how an ordinary build gets here.
  defp unresolvable(modules, new) do
    for module <- modules,
        not MapSet.member?(new.inventory, module),
        do:
          {:gap,
           "#{inspect(module)} moved but is not in the modules list of " <>
             "#{Path.relative_to_cwd(new.resource)}. systools_rc resolves object code " <>
             "through that list, so no instruction can load this module whatever the appup " <>
             "says."}
  end

  # The other half of the same asymmetry, and a gap rather than a note. A
  # `delete_module` naming a module the target build still has takes working code
  # out of a running release: `systools_rc` accepts the script, translates it to
  # a `remove` and a `purge`, and the next call into that module fails. Module
  # names are global, so this cannot be somebody else's module the way an
  # unresolvable *load* can be - it is this application's, and it is still there.
  #
  # Asked of the modules the script *leaves* removed, which is why it needs no
  # rule of its own about what to subtract. A module taken out and put back is not
  # deleted, and `restart_application` is exactly that - a `remove` for every old
  # module followed by an `add_module` for every new one - so the ordering in
  # `Forecastle.Appup.effects/4` already answers it. Subtracting the loaded set
  # instead was a heuristic, and it was blind to the case that matters: a load
  # followed by a low-level `remove` of the same module put it in both sets and
  # cancelled out, so the gate passed a script that unloads code the release
  # needs.
  defp deleted_but_present(removals, new) do
    for module <- Enum.sort(removals),
        Map.has_key?(new, module),
        do:
          {:gap,
           "#{inspect(module)} is deleted by an instruction and is still in the target " <>
             "build. systools_rc translates delete_module into a remove and a purge with " <>
             "no load, so the upgrade would take away code the release still has."}
  end

  # The two states a mention can be in that are worth reporting and are not
  # gaps. Neither is decidably wrong: an instruction naming a module whose code
  # is identical is inert, and a *load* naming a module this application does not
  # have may belong to another one - `systools_rc:get_lib/2` resolves a module
  # against every application in the release, and refuses the relup itself if
  # none of them has it. That is why the mirror case above is a gap and this one
  # is not.
  defp mentions(loads, removals, old, new) do
    loads
    |> MapSet.union(removals)
    |> Enum.sort()
    |> Enum.flat_map(&mention(&1, old, new))
  end

  defp mention(module, old, new) do
    cond do
      not Map.has_key?(old, module) and not Map.has_key?(new, module) ->
        [
          {:note,
           "#{inspect(module)} is mentioned and is in neither build of this application. " <>
             ":systools resolves a module against every application in the release, so it " <>
             "may belong to another one."}
        ]

      Map.get(old, module) == Map.get(new, module) ->
        [{:note, "#{inspect(module)} is mentioned and did not change"}]

      true ->
        []
    end
  end

  ## The report

  # Printed in full whether or not anything was found, because "which edges were
  # examined" is half of what makes the answer trustworthy - a run that examined
  # nothing and a run that found nothing look identical otherwise.
  defp report!(results) do
    Enum.each(results, &announce/1)

    case Enum.sum(Enum.map(results, &count(&1, :gap))) do
      0 ->
        Mix.shell().info("mix castle.appup: every module that moved is covered.")

      gaps ->
        Mix.raise(
          "mix castle.appup: #{gaps} #{plural(gaps, "gap")} in " <>
            "#{describe_apps(results)}. A module whose code changed and that no instruction " <>
            "loads goes on running the code that was loaded before: the relup generates, " <>
            "the install succeeds, and the upgrade reports success."
        )
    end
  end

  defp announce(result) do
    Mix.shell().info(result.heading)

    Enum.each(result.sections, &announce_section/1)
  end

  # A labelled section is an edge and gets a line of its own with its findings
  # under it; an unlabelled one is something said about the application rather
  # than about a direction, and its findings sit directly under the heading.
  defp announce_section(%{label: nil} = section) do
    Enum.each(section.findings, fn {_kind, phrase} -> Mix.shell().info("  " <> phrase) end)
  end

  defp announce_section(section) do
    Mix.shell().info("  " <> section.label <> outcome(section))

    Enum.each(section.findings, fn {_kind, phrase} -> Mix.shell().info("    " <> phrase) end)
  end

  defp outcome(%{findings: []}), do: ": nothing missing"
  defp outcome(_section), do: ""

  defp count(result, kind) do
    Enum.sum(for section <- result.sections, {^kind, _phrase} <- section.findings, do: 1)
  end

  defp describe_apps(results) do
    apps = Enum.count(results, &(count(&1, :gap) > 0))

    "#{apps} #{plural(apps, "application")}"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
