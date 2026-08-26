defmodule Mix.Tasks.Castle.Relup do
  @moduledoc """
  Generate a relup file between releases.

  This task is provided by `Forecastle`, Castle's build-time half, and named for
  `Castle` because that is the package a project depends on.

  `mix castle.relup` will generate a relup between a `target` release and
  any number of other releases.

  ## When to reach for this rather than for the build

  A relup destined for the release being built does not need this task.
  `Forecastle.generate_relup/1` runs between `post_assemble` and `:tar` and
  generates it into the version path from the release's `:upgrade_from` option,
  so a single `mix release` produces a tarball with its own upgrade plan in it.
  That is the everyday path, and it is the one to use where the target is being
  assembled now.

  What this task covers is what that step cannot reach: **a target that already
  exists**, rather than one this build is producing. Generating a relup between
  two releases that shipped months ago, or against a target somebody else
  assembled, is this task and nothing else. It is also where a build insists on
  `--hot` or `--restart`, which the assembly step does not offer - it generates
  under `auto`.

  The *baselines* are the same three sources either way, and only two of them are
  read rather than made: `rel:` and `tar:` name something already built, while
  `ref:` checks the commit out and runs its build. So \"nothing is rebuilt\" is a
  property of the spec you write, not of this task - see *Naming a baseline*.

  Both go through the same code (`Forecastle.Relup`), so nothing about which one
  produced a relup changes what is in it.

  ## Command-line options:

    - `--target` - the path to the .rel file in the target release, without the
      .rel extension
    - `--fromto` - a baseline spec for a previous release
    - `--upfrom` - a baseline spec for a previous release
    - `--downto` - a baseline spec for a previous release
    - `--outdir` - the directory to write the relup. Defaults to the current directory
    - `--hot` - require every transition to be a hot upgrade
    - `--restart` - make every transition a full emulator restart
    - `--dry-run` - generate the relup, report what it would be, and write nothing

  The `--fromto`, `--upfrom` and `--downto` switches may be specified zero or more
  times and have the following behaviour:

    - `--fromto` generates both upgrade and downgrade instructions
    - `--upfrom` generates only upgrade instructions
    - `--downto` generates only downgrade instructions

  At least one of them is required: a relup with no transitions in it is not an
  upgrade plan.

  ## Naming a baseline

  The value of `--fromto`, `--upfrom` and `--downto` is a *baseline spec*: one
  grammar naming the three places a previous release can come from.

      # an assembled release, named by its .rel file without the extension
      mix castle.relup --target ... --fromto rel:_build/prod/rel/my_app/releases/1.0.0/my_app

      # the artefact that shipped
      mix castle.relup --target ... --fromto tar:artifacts/my_app-1.0.0.tar.gz

      # a git ref, checked out into a worktree and built
      mix castle.relup --target ... --fromto ref:v1.0.0

  A value with no prefix is a `rel:` path, so every invocation written before
  specs existed means exactly what it meant then. The direction stays on the
  switch name and the source stays in the value; crossing the two into separate
  switches would be a switch per combination.

  `--target` is not a spec. It names the release being generated *for*, which is
  the one that has just been assembled, so it is always a path to a `.rel` file
  on disk.

  **`tar:` is the source to prefer, and the reason is correctness rather than
  convenience.** `release_handler` selects a relup entry by from-version string
  and never checks that the running code is the code the relup was generated
  against, so a baseline rebuilt from source - with today's Elixir, today's OTP
  and today's dependencies - can have a different module set from the one that is
  deployed, and the relup then misses modules. `Forecastle.Baseline` documents
  what each source costs, what `ref:` caches and where, in full.

  The task fails if the relup could not be generated, so that a build pipeline
  does not carry on and package whatever relup happened to be lying around. It
  writes nothing when it fails, so a relup already in the output directory is
  left as it was rather than replaced by one that was then refused. The relup
  itself is never opened for writing: the bytes go to a staging file beside it
  which is renamed over it once it is whole, so a failure with a file open cannot
  leave half an upgrade plan behind either. A reader sees the whole of the old
  relup or the whole of the new one.

  `--outdir` must already exist, and a relative one is resolved from the
  directory the task is run in, not from the project root. It only ever affects
  where this task writes.
  Post-assembly copies the relup it finds in the project root, which is where
  the default puts it, so a relup destined for a release should be generated
  without `--outdir`.

  ## Upgrade strategy

  The strategy is a property of each transition in the relup rather than of the
  release, and there are three. `--hot` and `--restart` are mutually exclusive
  and may each be given once; with neither, the strategy is `auto`.

  ### `auto` (the default)

  Every transition is generated from the applications' appups, as a hot upgrade,
  unless something in that transition cannot be hot-upgraded - and then that
  transition, and only that transition, becomes a restart.

  Two things make a transition a restart. An **ERTS change** always does: it is
  not a hot upgrade under any policy, and no appup could make it one. A **version
  change in an application the project does not own** - a dependency, one of
  Elixir's own applications, one of OTP's - does so only when no appup covers
  that particular move, which is the question `:systools` would be answering a
  moment later anyway. The appup consulted is the one beside the *target*
  release's copy of the application, `lib/<app>-<vsn>/ebin/<app>.appup`, and the
  from-version is matched the way `systools_relup` matches it - which includes
  the regexes an appup is allowed to name a from-version with.

  Each *direction* is classified on its own, because an appup carries separate
  upgrade and downgrade lists and a from-version present in one need not be
  present in the other. A relup can therefore carry a hot upgrade from a version
  and a restart back down to it.

  Applications *added* or *removed* between the two releases are left to
  `:systools`, whose `add_application` and `remove_application` instructions are
  hot: nothing has to be changed in place, only started or stopped.

  `auto` does not fall back to a restart when an appup for an application the
  project *does* own is missing. A transition it judged hot and `:systools` then
  could not generate is a failure, so that `auto` never silently ships something
  other than the upgrade it decided on; ask for the restart with `--restart`.

  ### `auto` announces a restart

  A restart transition is a legitimate outcome of `auto`, not a failure, so a run
  that produces one writes the relup and says so. What it says names every edge
  that will restart and why, whether `auto` classified it or an appup asked for
  `restart_emulator` by name - the same transition arrived at two ways, and the
  run has one verdict about it either way.

  Both kinds are settled after generation, because only one of them is knowable
  before it: an appup that names the instruction is invisible until `:systools`
  has produced a script. Announcing from classification alone is how a run came
  to say that every transition was a hot upgrade and then report a restart in the
  same breath.

  `--hot` and `--restart` remain the ways to insist. `--hot` fails on a
  transition that would restart; `--restart` makes every transition one.

  ### `--hot`

  Every transition must be a genuine hot upgrade, and generation fails, non-zero
  and having written nothing, if one cannot be: a missing appup entry, an ERTS
  change, or an appup that asks for the emulator to be restarted. This is the
  switch for a pipeline that requires zero-downtime deployment.

  Note that this is feasibility rather than policy, and it is not the same
  question `auto` asks. `--hot` reads every application's appup, including those
  of the applications the project owns, and takes whatever the appups yield;
  `auto` consults the appups only of the applications the project does not own,
  in order to decide whether an edge can be hot at all.

  ### `--restart`

  Every transition is a single `restart_emulator` instruction, written directly.
  No appup is read - not for the project's own applications either - and
  `:systools` is not involved at all, which is the only way to be certain which
  of OTP's two emulator-restart instructions ends up in the relup.

  ## Asking the question without writing the answer

  `--dry-run` does everything the same invocation without it would have done,
  except publish the relup - and the plan is then discarded. It answers *can
  1.0.0 be upgraded to 1.1.0 hot, and if not, which edge and why*, before any
  appup has been written and without disturbing whatever relup is already in the
  output directory.

  It costs nothing extra, because the verdict already waits for the generated
  plan: an appup may ask for the emulator to be restarted by name, and nothing
  knows that until there is a script to look at. So what a dry run reports is
  what an ordinary run reports, per edge and per direction, arrived at by the
  same code rather than by a second opinion that could drift from it.

  **What "everything" amounts to depends on the strategy, and a dry run is worth
  exactly what the run it stands in for is worth.** The baselines are resolved
  under all three. `auto` then classifies each edge and asks `:systools` for
  whatever half it judged hot; `--hot` asks `:systools` for the whole relup;
  `--restart` reads no appup at all and never reaches `:systools`, because
  writing the entries by hand is the whole of what that strategy does. So
  `--restart --dry-run` says that the releases could be read and the entries
  built, and nothing whatever about appups - not because the mode skipped a step,
  but because `--restart` does not look either.

  **The exit status is the other half of the answer, and it is about
  generation.** Zero when the relup could have been generated, non-zero when
  generation would have failed - a dry run that cannot generate fails rather than
  reporting success with a caveat. Generation ends at the encoded bytes, which is
  the last step that is a property of the plan rather than of the destination.

  That is deliberately *not* "the status the same command without `--dry-run`
  would have had", and the gap is one-sided and worth naming. Everything that
  refuses before the write refuses here too: an `--outdir` that is not a
  directory, a baseline that cannot be resolved, two baselines for one version, a
  baseline at the target's own version, a `:systools` failure, an appup naming
  `restart_new_emulator`, `--hot` over a transition that cannot be hot. So a dry
  run never reports success where an ordinary run would have refused the *plan*.
  What it cannot see is a failure to *publish* one - a directory standing where
  the relup goes, a destination that cannot be written, no space left - because
  those are found by writing and writing is the one thing this mode does not do.
  A dry run exits 0 in front of each of them, which is said here rather than left
  to be discovered.

  Checking the destination instead of writing to it would not close that gap, it
  would disguise it: a `File.stat/1` is not a write, and it answers about a
  moment that has passed by the time the ordinary run happens. A stated boundary
  is worth more than a partial promise.

  It is orthogonal to the strategy and combines with either switch.
  `--hot --dry-run` is the pipeline's question asked before the pipeline runs:
  could every transition be hot? `--hot` announces nothing of its own on success,
  which is the whole reason the notice exists - without it, such a run is a
  silent exit 0.

  That is not the same as a run that prints one line, and a pipeline must not
  read it as one. `silent` hands `:systools`' own diagnostics back to be
  forwarded rather than printed by it, so a warning - `bad_vsn` from an appup
  whose version tag has drifted, an ERTS change - still reaches standard error
  under `--dry-run`, exactly as it would without. **The exit status is the
  machine-readable answer; the output is for a person.**

  **\"Writes nothing\" is a promise about the relup, not about the run.** A dry
  run still resolves its baselines, and resolving one writes: `tar:` unpacks the
  artefact into `_build/castle/baselines` and `ref:` checks the commit out and
  builds it into the same place. Only `rel:`, which names a release already
  sitting on disk, costs nothing at all. That is not a loophole. A baseline that
  cannot be resolved is a generation that would have failed, and the only way to
  say so is to resolve it. What is untouched is the relup and the directory it
  would have gone in.

  ## Which instruction, and what the operator sees

  OTP has two emulator-restart instructions, and they are different transitions
  rather than two spellings of one:

    - `restart_emulator` sits at the end of the script. The relup is evaluated in
      full in the running system, and the emulator then reboots.
    - `restart_new_emulator` sits at the front. `release_handler` builds a hybrid
      temporary release - the new ERTS, kernel, stdlib and sasl over the old
      applications - reboots into that, and continues the rest of the relup on
      the way up.

  Every restart this task generates is `restart_emulator`, the one-stage
  transition. `restart_new_emulator` is not a strategy here and is refused where
  it turns up: it is a materially different path, and Castle is built for the
  one-stage one.

  That is why `auto` decides the ERTS case for itself.
  `systools_relup:check_for_emulator_restart/5` inserts `restart_new_emulator`
  on its own whenever the ERTS version differs between the two releases, and
  `systools_rc:sort_emulator_restart/3` then hoists it to the front of the
  script; changes to `kernel`, `stdlib` or `sasl` bring it in through those
  applications' own appups. So an ERTS change is taken out of `:systools`' hands
  before it is asked for anything, and whatever it does produce is inspected -
  a `restart_new_emulator` arriving from an appup is refused rather than
  shipped. The task keeps the exact instruction name in its output because the
  two transitions behave differently.
  """
  @shortdoc "Generate a relup file between releases"

  use Mix.Task

  # All `:keep` or `:count`, including the switches that may appear only once.
  # `:string` would silently keep the last occurrence and `:boolean` would
  # accept `--no-hot`, so a repeated or negated switch would quietly generate
  # something other than what was asked for - the failure this task's argument
  # handling exists to prevent. `:count` makes a repeat visible here as a count
  # above one, and leaves `--no-hot` an unrecognised switch.
  @options [
    upfrom: :keep,
    downto: :keep,
    fromto: :keep,
    outdir: :keep,
    target: :keep,
    hot: :count,
    restart: :count,
    dry_run: :count
  ]

  @impl Mix.Task
  def run(command_line_args) do
    args = parse!(command_line_args)

    # Everything that can be settled from the command line alone is settled
    # first, so that a mistyped `--outdir` is reported before any release is
    # read rather than after a generation that then has nowhere to go. Naming no
    # baseline at all belongs in that set too: it is a fact about the invocation
    # rather than about anything on disk, and `Forecastle.Relup` cannot say it in
    # terms of switches because the assembly step reaches the same code with none.
    strategy = fetch_strategy!(args)
    dry_run? = dry_run?(args)
    outdir = get_outdir(args)
    target = fetch_target!(args)

    up_specs = specs(args, :upfrom) ++ specs(args, :fromto)
    down_specs = specs(args, :downto) ++ specs(args, :fromto)
    refuse_no_baselines!(up_specs, down_specs)

    # `nil` for the resolved baselines: this task reads the target first, because
    # `--target` is a path somebody typed and resolving a baseline can take
    # minutes. The assembly step resolves ahead of time instead, for the reasons
    # `Forecastle.Relup.generate!/7` gives.
    Forecastle.Relup.generate!(target, up_specs, down_specs, nil, strategy, outdir, dry_run?)
  end

  defp refuse_no_baselines!([], []) do
    Mix.raise(
      "at least one of --fromto, --upfrom or --downto is required: a relup with no " <>
        "transitions in it is not an upgrade plan"
    )
  end

  defp refuse_no_baselines!(_up_specs, _down_specs), do: :ok

  # `parse/2` discards anything it does not recognise, which for a task whose
  # every argument is a path silently drops half the request - a mistyped
  # switch, or a path given without one, would otherwise produce a relup
  # between releases the caller did not name.
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

  # `--hot` and `--restart` are the same decision made two ways, so both
  # together is a request that cannot be honoured rather than one to resolve by
  # precedence.
  defp fetch_strategy!(cmdline_args) do
    given =
      for {key, switch} <- [hot: "--hot", restart: "--restart"],
          Keyword.has_key?(cmdline_args, key),
          do: {key, switch, Keyword.fetch!(cmdline_args, key)}

    case given do
      [] ->
        :auto

      [{key, switch, count}] ->
        once!(switch, count)
        key

      _both ->
        Mix.raise("--hot and --restart ask for opposite things and cannot be combined")
    end
  end

  # `:count` for the same reasons the strategy switches are, and it is not the
  # strategy: a dry run is orthogonal to which relup would have been written, so
  # `--hot --dry-run` asks whether every transition could be hot without
  # generating anything, which is the question a pipeline has before it runs.
  defp dry_run?(cmdline_args) do
    case Keyword.fetch(cmdline_args, :dry_run) do
      :error ->
        false

      {:ok, count} ->
        once!("--dry-run", count)
        true
    end
  end

  defp once!(_switch, 1), do: :ok

  defp once!(switch, count) do
    Mix.raise("#{switch} may be given once, but was given #{count} times")
  end

  defp fetch_target!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :target) do
      [target] -> path_not_spec!(target)
      [] -> Mix.raise("--target is required: there is nothing to generate a relup for")
      many -> Mix.raise(repeated("--target", many))
    end
  end

  # `--target` is the release the relup is generated *for*, which has just been
  # assembled and is therefore on disk by definition - there is nothing for a
  # spec to resolve. Said here rather than left to resolve as a path, because a
  # `--target tar:my_app-1.0.0.tar.gz` read as a path fails looking for
  # `tar:my_app-1.0.0.tar.gz.rel`, which mentions neither the switch that does
  # take a spec nor the reason this one does not.
  defp path_not_spec!(target) do
    if Forecastle.Baseline.spec?(target) do
      Mix.raise(
        "--target #{target} looks like a baseline spec, and --target takes a path. It names " <>
          "the release being generated for, which is always an assembled release on disk. " <>
          "Only --fromto, --upfrom and --downto take a spec."
      )
    else
      target
    end
  end

  # A missing directory used to reach `systools` as a failure to open "relup",
  # which does not mention the directory it could not open it in. Say so here
  # instead. Creating it is deliberately not this task's job: a mistyped
  # `--outdir` that springs into existence is how a relup ends up somewhere
  # nothing looks for it.
  defp get_outdir(cmdline_args) do
    case Keyword.get_values(cmdline_args, :outdir) do
      [] -> "."
      [outdir] -> existing_dir!(outdir)
      many -> Mix.raise(repeated("--outdir", many))
    end
  end

  defp repeated(switch, values) do
    "#{switch} may be given once, but was given #{length(values)} times: " <>
      Enum.map_join(values, ", ", &inspect/1)
  end

  defp existing_dir!(outdir) do
    if File.dir?(outdir) do
      outdir
    else
      Mix.raise("--outdir #{outdir} is not a directory")
    end
  end

  defp specs(cmdline_args, type) do
    cmdline_args |> Keyword.take([type]) |> Keyword.values()
  end
end
