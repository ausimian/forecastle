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
    * an application directory with no `ebin` in it
    * an entry that is named for the application and is not a directory - a
      regular file, or a symlink with nothing at the end of it - where nothing
      else in the library directory is

  ## Which applications

  `--app` may be given more than once. It defaults to the project's own
  applications plus any umbrella children - the same set `mix castle.relup`
  treats as the ones this project owns the appups for. Naming a dependency
  explicitly is how a dependency's appup gets checked.

  ## Change detection

  A module's fingerprint is `:beam_lib.md5/1` **and** its persisted attributes,
  and **not** a digest of the file bytes.

  A byte digest is useless here. `Mix.Release.strip_beam/2` rebuilds every beam
  in a release from `@additional_chunks ++ :beam_lib.significant_chunks()`, so a
  release's copy of a module is a different sequence of bytes from the `_build`
  copy of identical code - measured on Elixir 1.19.5 / OTP 28, where the chunk
  list goes from
  `AtU8 Code StrT ImpT ExpT FunT LitT LocT Attr CInf Dbgi Docs ExCk Line Type`
  to `Attr Line Type AtU8 Code StrT ImpT ExpT FunT LitT`. A byte digest reports
  every module in a release as changed; the md5 is stable across that stripping,
  which is what lets `--from` name a stripped release while `--to` is an
  unstripped `_build`.

  The md5 alone is not enough either, and `:beam_lib`'s own documentation says
  why: it covers the code, and "compilation date and other attributes are not
  included". Measured - two modules differing only in an explicit `@vsn`, or in
  an attribute registered with `Module.register_attribute(persist: true)`, have
  the same md5. Those attributes are loaded with the module and readable through
  `module_info/1`, and an explicit `@vsn` is exactly the sort of thing
  hot-upgrade code carries, so a module whose only change is one of them is a
  module an appup has to reload. Reporting it as unchanged was a false pass.

  Pairing the two costs nothing in the other direction. `Attr` is one of the
  chunks stripping keeps, and the *decoded* attribute list is identical before
  and after it while the bytes are not - measured, and asserted by the suite
  rather than assumed. Documentation is not in `Attr`, so a `@moduledoc` or
  `@doc` change still moves nothing and still needs no instruction. And a module
  with no explicit `@vsn` is given the md5 itself as its `vsn`, so for ordinary
  code the pair moves exactly when the code does.

  A beam with no `Attr` chunk at all is compared on the md5 alone rather than
  refused: the runtime loads such a module and reports `[]` for its attributes,
  so `[]` is what it is fingerprinted with. `:beam_lib.strip/1` produces them,
  which is a second reason to name it as a trap.

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
  alias Forecastle.Baseline

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
        resolved(spec)

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
      [] -> current_build()
      [spec] -> resolved(spec)
      many -> Mix.raise(repeated("--to", many))
    end
  end

  # `:compile` rather than `:release`: this reads compiled modules and the appup
  # beside them, and never a `.rel`. For `rel:` and `tar:` the level changes
  # nothing - they name something already built - but for `ref:` it is the
  # difference between a `mix compile` and a `mix release` of an old commit.
  defp resolved(spec) do
    baseline = Baseline.resolve!(spec, :compile)

    build(spec, baseline.lib_dir)
  end

  # `_build/<target_><env>/lib`, which holds `<app>/ebin` per application - the
  # shape `Forecastle.Baseline` promises `<lib_dir>/*/ebin` matches alongside a
  # release's `<app>-<vsn>/ebin`.
  #
  # **The compile happens here rather than in `@requirements`, which is to say
  # only when the current build is the thing being read.** A check run against
  # beams that do not reflect the source is a wrong answer rather than a stale
  # one, so the default `--to` has to compile. But `@requirements` runs before
  # `run/1` and therefore before anyone has looked at the arguments, which made a
  # comparison of two artefacts - `--from tar:a --to tar:b`, both of them built
  # elsewhere and neither of them this checkout - wait for a compile of a
  # checkout it was not going to read, and *fail* if that checkout does not
  # compile. A read-only comparison of two things that already exist should not
  # need the working tree to be in a fit state.
  defp current_build do
    Mix.Task.run("compile", [])

    build("the current build", Path.join(Mix.Project.build_path(), "lib"))
  end

  # **The library directory is established here, not assumed, and that is the
  # difference between a gate and a decoration.** Everything downstream reads an
  # application's *absence* from a build as a fact about the transition - one
  # application added, or one removed, neither of which needs an appup. A library
  # directory that is not there makes every application look absent, so a
  # mistyped `--from` reported "an application added between the two" and exited
  # **zero**, having compared nothing at all. Measured, before it was fixed.
  #
  # That is the one answer a check like this must never give, and it is worth
  # naming why it was so easy to reach: `Forecastle.Baseline` resolves a `rel:`
  # spec without touching the filesystem, deliberately, because the caller is
  # what reads the release a moment later and can say what it could not read.
  # `mix castle.relup` is that caller for a `.rel` file. This task reads no
  # `.rel` at all, so nothing else was ever going to notice.
  #
  # Listing it once also settles the discovery below without a glob. Globbing
  # `<lib_dir>/{app,app-*}/ebin` has the same failure in a narrower form: a
  # project whose path contains a glob metacharacter - a directory named
  # `a{b}` is enough - matches nothing and every application looks absent again.
  # `:filelib.wildcard/1` has no way to quote the part of a pattern that is a
  # path, so the fix is not to build a pattern out of one.
  #
  # **Readable is not the same as being a library directory, and the difference
  # was a silent pass that only showed up on Linux.** `Forecastle.Baseline`
  # derives the library directory of a `rel:` spec by climbing three levels from
  # the `.rel` path, so a nonsense spec lands on a real path: `rel:/nope/x`
  # resolves to `/lib`. That does not exist on macOS, so `File.ls/1` failed and
  # the refusal below fired. On Linux `/lib` is a directory - the system one -
  # so the listing *succeeded*, held no application being checked, and every one
  # of them read as removed between the two builds. A removal is a legitimate hot
  # transition that `:systools` covers with `remove_application` and that needs no
  # appup, so the run reported "every module that moved is covered" and exited
  # **zero** having compared nothing. The same class as the mistyped `--from`
  # above, reached through a path that happens to exist.
  #
  # So a library directory has to *look* like one, which is decided structurally
  # rather than by trusting the spec: at least one entry that is an application
  # directory with an `ebin` in it. A build's library directory always has one -
  # an empty one is not a build - and no directory that is merely nearby does.
  # The one check that cannot be fooled by a path being resolvable.
  defp build(describe, lib_dir) do
    case File.ls(lib_dir) do
      {:ok, entries} ->
        if Enum.any?(entries, &application_dir?(lib_dir, &1)) do
          %{describe: describe, lib_dir: lib_dir, entries: entries}
        else
          refuse_lib_dir!(
            describe,
            lib_dir,
            "nothing in it is an application directory with an ebin in it"
          )
        end

      {:error, reason} ->
        refuse_lib_dir!(describe, lib_dir, :file.format_error(reason))
    end
  end

  defp application_dir?(lib_dir, name), do: File.dir?(Path.join([lib_dir, name, "ebin"]))

  # One phrase for both, because they are one bug with two symptoms and which of
  # them a given machine shows depends on whether the resolved path happens to
  # exist there.
  defp refuse_lib_dir!(describe, lib_dir, because) do
    Mix.raise(
      "#{describe}: #{Path.relative_to_cwd(lib_dir)} is not a library directory of a build - " <>
        "#{because}. Every application would look absent from it, and an absent application " <>
        "reads as one this transition adds or removes, which needs no appup and passes. So " <>
        "this refuses rather than reporting one."
    )
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
    case {ebin(from, app), ebin(to, app)} do
      {nil, nil} ->
        Mix.raise(
          "#{app} is in neither #{from.describe} nor #{to.describe}. Nothing was compared."
        )

      # An application added or removed between the two is not a transition an
      # appup describes. `:systools` covers both with `add_application` and
      # `remove_application`, which are hot - nothing has to be changed in
      # place, only started or stopped - so there is nothing here to be missing.
      {nil, _to_ebin} ->
        whole_application(
          app,
          "#{app} is in #{to.describe} and not in #{from.describe}: an application added " <>
            "between the two, which :systools covers with add_application."
        )

      {_from_ebin, nil} ->
        whole_application(
          app,
          "#{app} is in #{from.describe} and not in #{to.describe}: an application removed " <>
            "between the two, which :systools covers with remove_application."
        )

      {from_ebin, to_ebin} ->
        compare(app, from_ebin, to_ebin)
    end
  end

  defp whole_application(app, phrase) do
    %{heading: to_string(app), sections: [%{label: nil, findings: [{:note, phrase}]}]}
  end

  # `<app>` for a Mix build and `<app>-<vsn>` for a release, which is the only
  # thing `Forecastle.Baseline` promises about the layout. `nil` means the
  # application really is not in this build - which is a claim worth making only
  # because `build/2` established that the library directory itself is there,
  # and only because nothing in it claimed to be this application. See
  # `app_dirs/2` for the second half of that.
  defp ebin(build, app) do
    case app_dirs(build, app) do
      {[], []} ->
        nil

      {[], others} ->
        not_directories!(others, build, app)

      {[dir], _others} ->
        ebin!(dir, build, app)

      {many, _others} ->
        Mix.raise(
          "#{app} is in #{build.describe} more than once: " <>
            Enum.map_join(many, ", ", &inspect(Path.relative_to_cwd(&1))) <>
            ". Which of them the upgrade would use depends on the code path, so this " <>
            "refuses rather than choosing."
        )
    end
  end

  # Matched exactly rather than by prefix alone: `sample-` cannot match
  # `sample_dep-0.1.0`, because an application name cannot contain a hyphen.
  #
  # The two halves are kept apart rather than filtered down to one, because
  # *whether anything matched at all* is a different question from *whether what
  # matched is usable*, and collapsing them answered the second as though it were
  # the first. An entry that matches the name and is not a directory - a regular
  # file, or a symlink whose target is not there - was dropped, so the
  # application looked **absent**, which reads as one added or removed between
  # the two builds, needs no appup, and exits **zero**. That is the same silent
  # pass `build/2` exists to prevent, arriving one level further in, and it is the
  # answer this task must never give.
  #
  # A non-directory beside a real directory is still passed over rather than
  # refused. A legacy `sample-0.1.0.ez` archive sitting next to `sample-0.1.0`
  # matches the prefix and is not the application the upgrade would read; the
  # directory is. Only an application that has *nothing but* such entries is a
  # refusal, because only then is the alternative to call it absent.
  defp app_dirs(build, app) do
    prefix = "#{app}-"

    build.entries
    |> Enum.filter(&(&1 == "#{app}" or String.starts_with?(&1, prefix)))
    |> Enum.map(&Path.join(build.lib_dir, &1))
    |> Enum.split_with(&File.dir?/1)
  end

  defp not_directories!(paths, build, app) do
    Mix.raise(
      "#{app} is named in #{build.describe} by " <>
        Enum.map_join(paths, ", ", &inspect(Path.relative_to_cwd(&1))) <>
        ", none of which is a directory - a regular file, or a symlink with nothing at the " <>
        "end of it. That is a broken build rather than an application added or removed " <>
        "between the two, so this refuses rather than reporting one."
    )
  end

  # An application directory with no `ebin` in it is an incomplete build, not an
  # application this transition adds or removes - and treating it as the latter
  # is the same silent pass `build/2` exists to prevent, arriving one level
  # further in.
  defp ebin!(dir, build, app) do
    ebin = Path.join(dir, "ebin")

    if File.dir?(ebin) do
      ebin
    else
      Mix.raise(
        "#{app} is in #{build.describe} at #{Path.relative_to_cwd(dir)}, which holds no " <>
          "ebin directory. That is an incomplete build rather than an application added or " <>
          "removed between the two, so this refuses rather than reporting one."
      )
    end
  end

  # One side of the comparison: the version an appup entry is keyed by, the beams
  # on disk, and the `.app` resource's own module list. The last two are
  # different things and both are needed - the beams are what *moved*, and the
  # inventory is what `:systools` can *resolve*. See `read_inventory!/2`.
  defp side!(ebin, app) do
    resource = Path.join(ebin, "#{app}.app")
    {vsn, inventory} = app_resource!(resource, app)

    %{vsn: vsn, inventory: inventory, modules: modules!(ebin), ebin: ebin, resource: resource}
  end

  defp compare(app, from_ebin, to_ebin) do
    from = side!(from_ebin, app)
    to = side!(to_ebin, app)

    heading = "#{app} #{from.vsn} -> #{to.vsn}"

    if from.vsn == to.vsn do
      %{heading: heading, sections: [unmoved(from.vsn, from.modules, to.modules)]}
    else
      %{heading: heading, sections: edges(app, from, to)}
    end
  end

  # An application whose version did not move is one `:systools` will not
  # consult an appup for at all - `release_handler` compares versions, and an
  # unchanged one is not a transition. So modules that differ under an unchanged
  # version are carried by nothing, whatever the appup says, and there is no
  # instruction that could be added to fix it. The remedy is the version, so the
  # finding names the version rather than listing the modules.
  defp unmoved(vsn, from_modules, to_modules) do
    {changed, added, removed} = moved(from_modules, to_modules)
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
  #
  # Coverage is the thing a restart really does excuse, and it stays inside the
  # branch.
  defp findings(script, direction, app, old, new) do
    refusals(script) ++
      multiply_defined(script, app, new.inventory) ++
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
    {changed, added, removed} = moved(old.modules, new.modules)

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

  # The whole of the diff, in terms of the direction's own old and new builds.
  # Sorted, so that a report is stable between runs and between machines -
  # `File.ls/1` answers in whatever order the filesystem hands back, and the
  # maps these are built from have no order of their own either.
  defp moved(old, new) do
    changed =
      for {module, print} <- new, Map.has_key?(old, module), old[module] != print, do: module

    added = for {module, _print} <- new, not Map.has_key?(old, module), do: module
    removed = for {module, _print} <- old, not Map.has_key?(new, module), do: module

    {Enum.sort(changed), Enum.sort(added), Enum.sort(removed)}
  end

  ## Reading a build

  # The beams on disk rather than the `.app` file's `modules` list. A beam is
  # what `release_handler` can load and what an instruction can name, and the
  # `.app` list is derived from the same directory anyway - so this asks the
  # question of the thing the upgrade acts on.
  #
  # Listed rather than globbed, for the reason `build/2` gives: a `*.beam`
  # pattern is built out of a path, and a path that happens to contain a glob
  # metacharacter would match nothing and report the application as empty.
  # `File.ls!/1` rather than a message of this task's own, because the directory
  # was established as one moments ago - a failure here is a race or a
  # permissions change, and Elixir's own error names the path and the reason.
  defp modules!(ebin) do
    for name <- File.ls!(ebin), Path.extname(name) == ".beam", into: %{} do
      fingerprint!(Path.join(ebin, name))
    end
  end

  # `:beam_lib.md5/1` rather than a digest of the bytes: see the moduledoc. The
  # module name comes out of the same call rather than from the filename,
  # because the beam is what says which module it holds.
  #
  # **Paired with the persisted attributes, because the md5 does not cover
  # them.** `:beam_lib`'s own documentation says so - "compilation date and other
  # attributes are not included" - and it was measured: two modules differing
  # only in an explicit `@vsn` have the same md5. Those attributes are loaded
  # with the module and readable through `module_info/1`, so a module whose only
  # change is one of them is a module whose observable content changed and which
  # an appup has to reload. Reporting it as unchanged was a false pass.
  #
  # Adding them costs no accuracy in the other direction. The `Attr` chunk is one
  # of the two `Mix.Release.strip_beam/2` keeps beyond the significant ones, and
  # the *decoded* attribute list is identical before and after stripping while
  # the file bytes are not - measured on the fixture's own release, and asserted
  # by `Forecastle.AppupCheckTest`. Docs do not appear in it either, so a
  # `@moduledoc` change still moves nothing. And an ordinary module has no
  # explicit `@vsn`: Elixir gives it the md5 itself, so the pair moves exactly
  # when the code does.
  #
  # One read of the file, both questions asked of the same bytes - the file is
  # what could change between two reads.
  #
  # **`allow_missing_chunks`, because a beam without an `Attr` chunk is a beam
  # the runtime loads.** Measured on OTP 28.3: a module rebuilt without it loads,
  # answers calls, and reports `[]` from `module_info(attributes)` - and
  # `:beam_lib.strip/1`, the function the design names as a trap precisely
  # because it drops `Attr`, is one way to get one. Insisting on the chunk made
  # this task *refuse to run* against a dependency somebody had stripped that
  # way, which is a gate that cannot answer rather than a gate that says no.
  #
  # `:missing_chunk` is normalised to `[]` rather than to a sentinel of its own,
  # because `[]` is what such a module really has: the attribute half of the
  # fingerprint is "what `module_info/1` would report", and for these it reports
  # nothing. Two builds of such a module then compare on the md5 alone, which is
  # the documented weaker answer, and is the right one - there are no attributes
  # for it to miss.
  defp fingerprint!(beam) do
    binary = File.read!(beam)
    chunks = :beam_lib.chunks(binary, [:attributes], [:allow_missing_chunks])

    case {:beam_lib.md5(binary), chunks} do
      {{:ok, {module, md5}}, {:ok, {module, [attributes: attributes]}}} ->
        {module, {md5, attributes(attributes)}}

      {{:error, :beam_lib, reason}, _attributes} ->
        Mix.raise(beam_error(beam, reason))

      {_md5, {:error, :beam_lib, reason}} ->
        Mix.raise(beam_error(beam, reason))
    end
  end

  defp attributes(:missing_chunk), do: []
  defp attributes(attributes), do: attributes

  defp beam_error(beam, reason) do
    "#{Path.relative_to_cwd(beam)} could not be read as a beam file: #{inspect(reason)}"
  end

  # Two things come out of the `.app` resource, and both are needed.
  #
  # The **version** an appup entry is keyed by is the application's own, and at
  # `:compile` level there is no `.rel` to read it out of and the directory name
  # does not carry it either. This file is where it is, in both layouts.
  #
  # The **modules list** is what `systools_rc` means by "every module of the
  # application": `#application.modules` comes from here, so it is what an
  # `add_application` or a `restart_application` expands over, and it is what
  # `get_lib/2` resolves object code through. It is deliberately *not* assumed to
  # agree with the beams in `ebin` - see `unresolvable/2` and
  # `Forecastle.Appup.effects/4` for what happens where it does not.
  #
  # A missing or malformed list is read as an **empty** one, and that is not what
  # `:systools` makes of it: `systools_make:check_item/2` ends in
  # `throw({missing_param, Item})`, and a `modules` value that is not a list of
  # atoms is a `bad_param`. Validating a `.app` is that function's job and it
  # does it when a release or a relup is built; a second, weaker copy of it here
  # could only disagree with the first, which is the very failure
  # `Forecastle.Appup` exists to prevent for appups.
  #
  # Reading it as empty is the conservative direction rather than the convenient
  # one, which is what makes leaving it to `:systools` safe. An empty inventory
  # resolves nothing, so every module that moved is reported by `unresolvable/2`
  # and an application-level instruction covers nothing beyond what it names by
  # hand - strictly more findings and a non-zero exit, never fewer. A malformed
  # resource cannot buy a clean bill of health here.
  defp app_resource!(file, app) do
    case :file.consult(to_charlist(file)) do
      {:ok, [{:application, ^app, opts}]} when is_list(opts) ->
        {fetch_vsn!(opts, file), inventory(opts)}

      {:ok, terms} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} is not an application resource file for #{app}. " <>
            "Expected a single {application, #{app}, Options} tuple, but got: " <>
            "#{inspect(terms)}"
        )

      {:error, reason} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} could not be read as an application resource " <>
            "file: #{inspect(reason)}"
        )
    end
  end

  # A list with a non-atom anywhere in it is read as **empty**, not filtered down
  # to the atoms in it. `systools_make:a_list_p/1` is all-or-nothing - one
  # non-atom and the whole `modules` value is a `bad_param` - so keeping the valid
  # subset invented an inventory `:systools` never accepts, and a
  # whole-application instruction could then cover a changed module out of it and
  # exit zero. That is the one thing the conservative reading of a malformed `.app`
  # is supposed to rule out: it errs toward *more* findings precisely so a
  # malformed resource cannot buy a clean bill of health, and a surviving subset
  # broke that.
  defp inventory(opts) do
    case List.keyfind(opts, :modules, 0) do
      {:modules, modules} when is_list(modules) ->
        if Enum.all?(modules, &is_atom/1), do: MapSet.new(modules), else: MapSet.new()

      _absent_or_malformed ->
        MapSet.new()
    end
  end

  # `List.keyfind/3` rather than `Keyword.fetch/2`, and `is_list/1` on the way in:
  # a `.app` file is arbitrary consulted terms rather than something this project
  # wrote, and `Keyword` functions raise on a list that is not a keyword list -
  # which would report a malformed resource file as a crash in this task instead
  # of as the file it could not make sense of.
  #
  # `to_string/1` takes the version whether the file spells it as a charlist,
  # which is what every tool writes, or as a binary.
  defp fetch_vsn!(opts, file) do
    case List.keyfind(opts, :vsn, 0) do
      {:vsn, vsn} when is_list(vsn) or is_binary(vsn) ->
        to_string(vsn)

      nil ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} names no version, so there is no from-version to " <>
            "look an appup entry up by."
        )

      {:vsn, vsn} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} names the version #{inspect(vsn)}, which is not a " <>
            "string. An appup entry is keyed by the version as it is written, so there is " <>
            "nothing to look one up by."
        )
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
