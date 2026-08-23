defmodule Mix.Tasks.Forecastle.Relup do
  @moduledoc """
  Generate a relup file between releases.

  `mix forecastle.relup` will generate a relup between a `target` release and
  any number of other releases. The paths specifed in the options should
  be the paths to `.rel` files (but without the .rel extension)

  ## Command-line options:

    - `--target` - the path to the .rel file in the target release
    - `--fromto` - the path to the .rel file from a previous release
    - `--upfrom` - the path to the .rel file from a previous release
    - `--downto` - the path to the .rel file from a previous release
    - `--outdir` - the directory to write the relup. Defaults to the current directory
    - `--hot` - require every transition to be a hot upgrade
    - `--restart` - make every transition a full emulator restart

  The `--fromto`, `--upfrom` and `--downto` switches may be specified zero or more
  times and have the following behaviour:

    - `--fromto` generates both upgrade and downgrade instructions
    - `--upfrom` generates only upgrade instructions
    - `--downto` generates only downgrade instructions

  At least one of them is required: a relup with no transitions in it is not an
  upgrade plan.

  The task fails if the relup could not be generated, so that a build pipeline
  does not carry on and package whatever relup happened to be lying around. It
  writes nothing when it fails, so a relup already in the output directory is
  left as it was rather than replaced by one that was then refused.

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

  ### `auto` refuses a restart, for now

  Castle can install a relup that restarts the emulator but cannot yet *complete*
  the transition, so while that holds `auto` refuses rather than writes a restart
  transition. It exits non-zero, having written nothing, naming the edge that
  forced the restart and why. `auto` is what a run with no switches gets, and a
  default that quietly produces an upgrade plan which cannot be installed is
  worse than one that stops and says so.

  That covers a `restart_emulator` an appup asked for by name just as much as one
  `auto` chose for itself, and the two are settled together rather than one after
  the other: the relup is generated first, and only then does the run say which
  transitions restart - or that none of them do. So a run has one verdict, and
  cannot announce an all-hot relup and a restart in the same breath.

  This is temporary, and `--hot` and `--restart` are unaffected. `--restart` is
  the deliberate override for anyone who wants the relup anyway.

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

  ## Which instruction, and what the operator sees

  OTP has two emulator-restart instructions, and they are different transitions
  rather than two spellings of one:

    - `restart_emulator` sits at the end of the script. The relup is evaluated in
      full in the running system, `release_handler:install_release/1` replies
      `{ok, Vsn, Descr}`, and the emulator then reboots.
    - `restart_new_emulator` sits at the front. `release_handler` builds a hybrid
      temporary release - the new ERTS, kernel, stdlib and sasl over the old
      applications - reboots into that, and continues the rest of the relup on
      the way up. `install_release/1` replies `{continue_after_restart, Vsn,
      Descr}`.

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
  shipped. Both matter to automation, because the reply an operator or a CI
  check reads back from `install_release/1` differs between the two.
  """
  @shortdoc "Generate a relup file between releases"

  use Mix.Task

  # Elixir's own applications. `:code.lib_dir/1` resolves them, but under
  # Elixir's library directory rather than OTP's, so nothing about the path
  # distinguishes them from a dependency. None of them carries an appup, so a
  # version change in any of them is a restart.
  @elixir_apps [:eex, :elixir, :ex_unit, :iex, :logger, :mix]

  # The two instructions `release_handler` treats as "reboot the emulator".
  @restart_instructions [:restart_emulator, :restart_new_emulator]

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
    restart: :count
  ]

  @impl Mix.Task
  def run(command_line_args) do
    ensure_systools!()

    args = parse!(command_line_args)

    # Everything that can be settled from the command line alone is settled
    # first, so that a mistyped `--outdir` is reported before any release is
    # read rather than after a generation that then has nowhere to go.
    strategy = fetch_strategy!(args)
    outdir = get_outdir(args)

    target = read_rel!(fetch_target!(args))
    ups = rel_paths(args, :upfrom) ++ rel_paths(args, :fromto)
    downs = rel_paths(args, :downto) ++ rel_paths(args, :fromto)
    froms = read_froms!(ups ++ downs, target)

    strategy
    |> plan!(target, froms, ups, downs)
    |> write_relup!(outdir)
  end

  @doc false
  # The split-and-merge, reachable on its own.
  #
  # `auto` is what merges hand-written restart entries into the same relup as the
  # ones `:systools` generated, and it is where an edge could be dropped, or
  # attached to the wrong direction, or one strategy applied to the whole relup.
  # While a restart transition cannot be performed `auto` refuses to emit one at
  # all (see `restart_transitions_installable?/0`), so the merge is not reachable
  # through the task - the refusal deliberately sits outside the merge rather
  # than inside it, which is both what keeps this callable and what makes
  # flipping that predicate back a one-line change.
  #
  # What `auto` settles is not settled here: this returns the merged relup, and
  # nothing is said about the strategy or refused on account of it.
  @spec plan_transitions!(binary(), [binary()], [binary()], [binary()], [binary()]) ::
          {charlist(), list(), list()}
  def plan_transitions!(target_path, hot_ups, hot_downs, restart_ups, restart_downs) do
    ensure_systools!()

    target = read_rel!(target_path)
    froms = read_froms!(hot_ups ++ hot_downs ++ restart_ups ++ restart_downs, target)

    {plan, _appup_restarts} =
      plan_transitions(target, froms, hot_ups, hot_downs, restart_ups, restart_downs)

    plan
  end

  # Elixir prunes unused OTP applications from the build's code path, which would
  # otherwise leave :systools - and :systools_relup, which answers whether an
  # appup covers a transition - unavailable in projects that don't already depend
  # on :sasl.
  defp ensure_systools! do
    Mix.ensure_application!(:sasl)
    {:ok, _started} = :application.ensure_all_started(:sasl)
    :ok
  end

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
      [] -> :auto
      [{key, switch, count}] -> once!(key, switch, count)
      _both -> Mix.raise("--hot and --restart ask for opposite things and cannot be combined")
    end
  end

  defp once!(key, _switch, 1), do: key

  defp once!(_key, switch, count) do
    Mix.raise("#{switch} may be given once, but was given #{count} times")
  end

  defp fetch_target!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :target) do
      [target] -> target
      [] -> Mix.raise("--target is required: there is nothing to generate a relup for")
      many -> Mix.raise(repeated("--target", many))
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

  defp rel_paths(cmdline_args, type) do
    cmdline_args |> Keyword.take([type]) |> Keyword.values()
  end

  ## Reading the releases

  # The `.rel` terms are the whole description of a transition that is available
  # before any appup has been read: the release name and version, the ERTS
  # version, and every application with its version. The switches name a `.rel`
  # file without its extension, which is what `:systools` wants, so the
  # extension goes back on here.
  defp read_rel!(path) do
    file = path <> ".rel"

    case :file.consult(to_charlist(file)) do
      {:ok, [{:release, {name, vsn}, {:erts, erts}, apps}]} when is_list(apps) ->
        %{
          file: file,
          path: path,
          name: to_string(name),
          vsn: to_string(vsn),
          erts: to_string(erts),
          apps: Map.new(apps, &{elem(&1, 0), to_string(elem(&1, 1))})
        }

      {:ok, terms} ->
        Mix.raise(
          "#{file} is not a release file. Expected a single {release, {Name, Vsn}, " <>
            "{erts, Vsn}, Applications} tuple, but got: #{inspect(terms)}"
        )

      {:error, reason} ->
        Mix.raise("#{file} could not be read as a release file: #{inspect(reason)}")
    end
  end

  # Every from-release read once, and its name checked here rather than in each
  # strategy: a relup between two differently-named releases is a mistake under
  # all three, and `:systools` does not refuse it - `check_for_emulator_restart/5`
  # carries both names into a warning and generates the relup regardless.
  defp read_froms!([], _target) do
    Mix.raise(
      "at least one of --fromto, --upfrom or --downto is required: a relup with no " <>
        "transitions in it is not an upgrade plan"
    )
  end

  defp read_froms!(paths, target) do
    Map.new(Enum.uniq(paths), fn path -> {path, read_from!(path, target)} end)
  end

  defp read_from!(path, target) do
    from = read_rel!(path)

    if from.name != target.name do
      Mix.raise(
        "#{from.file} is release #{from.name}, but #{target.file} is release " <>
          "#{target.name}. A relup describes transitions within one release."
      )
    end

    from
  end

  ## The three strategies

  defp plan!(:restart, target, froms, ups, downs) do
    announce_restart()

    # No appup is read on this path, so there is nothing an appup could have
    # asked for: the empty list is matched rather than discarded.
    {plan, []} = plan_transitions(target, froms, [], [], ups, downs)

    plan
  end

  defp plan!(:hot, target, froms, ups, downs) do
    Enum.each(froms, fn {_path, from} -> refuse_erts_change!(from, target) end)

    target
    |> systools_plan!(ups, downs)
    |> refuse_hot_restarts!()
  end

  # The relup is generated *before* anything is said about the strategy, because
  # classification is only half of what decides it: an appup can ask for the
  # emulator to be restarted by name, and that is not visible until `:systools`
  # has produced a script. Announcing after classification alone is how a run
  # said every transition was a hot upgrade and then reported a restart in the
  # same breath - and, once a restart transition can be written, would have said
  # both in a run that succeeded. So the two kinds are settled together, once,
  # and there is one verdict per invocation.
  defp plan!(:auto, target, froms, ups, downs) do
    {restart_ups, hot_ups} = split_edges(:up, ups, froms, target)
    {restart_downs, hot_downs} = split_edges(:down, downs, froms, target)

    {plan, appup_restarts} =
      plan_transitions(
        target,
        froms,
        edge_paths(hot_ups),
        edge_paths(hot_downs),
        edge_paths(restart_ups),
        edge_paths(restart_downs)
      )

    settle_restarts!(
      label_edges("upgrade from", restart_ups, froms) ++
        label_edges("downgrade to", restart_downs, froms),
      appup_restarts
    )

    plan
  end

  # Each direction on its own. An appup carries separate upgrade and downgrade
  # lists, and a from-version present in one need not be present in the other, so
  # the same edge can be hot one way and a restart the other - which is also why
  # nothing here is shared between the two calls beyond the releases themselves.
  defp split_edges(direction, paths, froms, target) do
    paths
    |> Enum.map(&{&1, restart_reasons(direction, froms[&1], target)})
    |> Enum.split_with(fn {_path, reasons} -> reasons != [] end)
  end

  defp edge_paths(edges), do: Enum.map(edges, &elem(&1, 0))

  defp label_edges(label, edges, froms) do
    for {path, reasons} <- edges, do: {label, froms[path].vsn, reasons}
  end

  ## Merging the two kinds of transition

  # Both clauses return `{plan, appup_restarts}`: the relup, and whatever
  # emulator restarts the generated half turned out to carry. The caller decides
  # what to do about those, because only `auto` has anything to decide - and it
  # cannot decide it until the relup exists.
  #
  # No `:systools` run at all when every transition in the relup is a restart: an
  # appup is then neither needed nor read, which is the point of a restart
  # transition, and is what `--restart` promises.
  defp plan_transitions(target, froms, [], [], restart_ups, restart_downs) do
    plan =
      {to_charlist(target.vsn), restart_entries(restart_ups, froms),
       restart_entries(restart_downs, froms)}

    {plan, []}
  end

  # The generated entries and the hand-written ones go into one relup, per
  # direction. `release_handler` selects by from-version and checks each script
  # on its own, so the order of entries for distinct from-versions does not
  # matter; what matters is that every from-version survives and that each keeps
  # the script its own direction was classified for.
  defp plan_transitions(target, froms, hot_ups, hot_downs, restart_ups, restart_downs) do
    {vsn, up_entries, down_entries} = generated = systools_plan!(target, hot_ups, hot_downs)

    plan =
      {vsn, up_entries ++ restart_entries(restart_ups, froms),
       down_entries ++ restart_entries(restart_downs, froms)}

    {plan, appup_restarts!(generated)}
  end

  ## Restart transitions

  # Written by hand rather than asked of `:systools`, which is the only way to
  # be certain which of the two emulator-restart instructions lands in the
  # relup: `:systools` inserts `restart_new_emulator` by itself for an ERTS
  # change, and its own `restart_emulator` option only appends to a script it
  # still built out of appups. The description is `[]`, which is what
  # `systools_relup` writes for a from-release named without one, and what
  # `install_release/1` hands back to the caller.
  defp restart_entries(paths, froms) do
    for path <- paths, do: {to_charlist(froms[path].vsn), [], [:restart_emulator]}
  end

  ## Hot transitions

  # `silent` and `noexec` together. `silent` is what makes the outcome
  # inspectable: without it `make_relup/4` prints its own diagnostics and
  # collapses every failure into a bare `:error`. `noexec` is what stops it
  # writing, because the relup is written here instead, from the term that came
  # back. Two things need that. A `--hot` run that has to be refused must leave
  # whatever relup was already in the output directory alone rather than replace
  # it with the one it is about to reject; and a transition `auto` chose to
  # restart has to be merged into the same file as the ones `:systools`
  # generated, which cannot be done once `:systools` has written it.
  defp systools_plan!(target, ups, downs) do
    args = [
      to_charlist(target.path),
      Enum.map(ups, &to_charlist/1),
      Enum.map(downs, &to_charlist/1),
      [:silent, :noexec, {:path, ebin_paths([target.path | ups ++ downs])}]
    ]

    # Through `apply/3`: `:sasl` is not a dependency, so `:systools` is not on
    # the code path this module is compiled against.
    :systools |> apply(:make_relup, args) |> report()
  end

  defp ebin_paths(relpaths) do
    for relpath <- relpaths, do: to_charlist(Path.join(lib_dir(relpath), "*/ebin"))
  end

  # A `.rel` path is `<release>/releases/<vsn>/<name>`, so the release's library
  # directory - which holds one `<app>-<vsn>/ebin` per application, appups
  # included - is three levels up from it.
  defp lib_dir(relpath), do: Path.expand(Path.join(relpath, "../../../lib"))

  # The warnings are the ones `make_relup/4` would have printed itself; `silent`
  # hands them over instead, and an ERTS version change is not something to
  # swallow. The module to format either with is the one the result names - an
  # error can come from `systools_make` rather than `systools_relup`.
  defp report({:ok, relup, module, warnings}) do
    warnings
    |> List.wrap()
    |> Enum.each(&Mix.shell().error(format(module, :format_warning, &1)))

    relup
  end

  defp report({:error, module, error}) do
    Mix.raise(format(module, :format_error, error))
  end

  # Only the shapes `silent` and `noexec` produce can arrive here. Anything else
  # means `make_relup/4` did not honour them, and failing is the safe direction:
  # it is a bare `:error` passing for success that this reporting exists to
  # prevent.
  defp report(other) do
    Mix.raise("Unexpected result from :systools.make_relup/4: #{inspect(other)}")
  end

  defp format(module, fun, term) do
    module |> apply(fun, [term]) |> to_string() |> String.trim_trailing()
  end

  ## Classifying a transition

  # What makes one direction of a transition ineligible for a hot upgrade under
  # `auto`. Two kinds: an ERTS change, which is not a hot upgrade under any
  # policy and which no appup could make one, and a version change in an
  # application the project does not own that no appup covers.
  defp restart_reasons(direction, from, target) do
    erts_reason(from, target) ++ app_reasons(direction, from, target)
  end

  defp erts_reason(%{erts: erts}, %{erts: erts}), do: []

  defp erts_reason(from, target) do
    ["ERTS changed from #{from.erts} to #{target.erts}"]
  end

  defp app_reasons(direction, from, target) do
    owned = project_apps()

    from.apps
    |> Enum.sort()
    |> Enum.filter(fn {app, vsn} -> moved?(target.apps, app, vsn) and app not in owned end)
    |> Enum.flat_map(&app_reason(direction, &1, target, owned))
  end

  # A moved application the project does not own is a restart only when nothing
  # covers the move. Its appup, if it has one, was written for somebody else's
  # transitions - but an entry that matches this from-version *is* an instruction
  # for this transition, and refusing to use it would make `auto` restart edges
  # that are demonstrably feasible. Asking here asks the same question
  # `:systools` would be asked a moment later, so the two cannot disagree.
  defp app_reason(direction, {app, vsn}, target, owned) do
    case appup_gap(direction, app, target, vsn) do
      nil ->
        []

      gap ->
        [
          "#{inspect(app)} is #{describe_app(app, owned)} and changed from #{vsn} to " <>
            "#{target.apps[app]}, and #{gap}"
        ]
    end
  end

  defp moved?(apps, app, vsn), do: Map.has_key?(apps, app) and apps[app] != vsn

  ## Whether an appup covers a transition

  # Answered the way `systools_relup` answers it, so that `auto`'s judgement and
  # the relup `:systools` would then generate cannot disagree. What its
  # `get_script_from_appup/5` does, in OTP 28.3's `sasl-4.3`:
  #
  #   - it reads `<app_dir>/<app>.appup`, where `app_dir` holds the *target*
  #     release's copy of the application. So the appup that decides an edge is
  #     the new version's, and its entries are keyed by the version being
  #     upgraded from - see `appup_file/2`.
  #   - it takes the `up` list for an upgrade and the `dn` list for a downgrade.
  #     Hence the direction: the two lists are independent, and a from-version in
  #     one need not be in the other.
  #   - it selects the entry with `appup_search_for_version/2`, *not* by string
  #     equality. A from-version given as a charlist matches by term equality;
  #     one given as a **binary** is a regular expression, run against the
  #     from-version with `re:run/3` and accepted only when the whole match is
  #     the from-version itself. That function is exported for reuse ("Used by
  #     release_handler:find_script/4. Also used by kernel, stdlib and sasl
  #     tests"), so it is called here rather than reimplemented, and a regex
  #     from-version resolves exactly as the upgrade will resolve it.
  #
  # `nil` means covered. Anything else is the phrase that says what was missing.
  defp appup_gap(direction, app, target, from_vsn) do
    file = appup_file(app, target)

    case appup_entries(file, direction) do
      {:ok, entries} -> entry_gap(entries, from_vsn, direction, file)
      {:error, gap} -> gap
    end
  end

  # `<release>/lib/<app>-<vsn>/ebin/<app>.appup` at the target's version of the
  # application, which is the directory `:systools` resolves the application to
  # when it reads the appup for this transition.
  defp appup_file(app, target) do
    Path.join([lib_dir(target.path), "#{app}-#{target.apps[app]}", "ebin", "#{app}.appup"])
  end

  defp appup_entries(file, direction) do
    case :file.consult(to_charlist(file)) do
      {:ok, [{_appup_vsn, up, down}]} when is_list(up) and is_list(down) ->
        {:ok, if(direction == :up, do: up, else: down)}

      {:ok, _terms} ->
        {:error, "#{shorten(file)} cannot be read as an appup"}

      {:error, :enoent} ->
        {:error, "there is no appup at #{shorten(file)}"}

      {:error, reason} ->
        {:error, "#{shorten(file)} could not be read: #{inspect(reason)}"}
    end
  end

  defp entry_gap(entries, from_vsn, direction, file) do
    # Through `apply/3`, as `:systools.make_relup/4` is, and for the same reason:
    # `:sasl` is not a dependency, so neither module is on the code path this is
    # compiled against.
    args = [to_charlist(from_vsn), entries]

    case apply(:systools_relup, :appup_search_for_version, args) do
      {:ok, _script} -> nil
      :error -> missing_entry(direction, file, from_vsn)
    end
  end

  defp missing_entry(:up, file, vsn) do
    "#{shorten(file)} has no upgrade instructions from #{vsn}"
  end

  defp missing_entry(:down, file, vsn) do
    "#{shorten(file)} has no downgrade instructions to #{vsn}"
  end

  defp shorten(path), do: Path.relative_to_cwd(path)

  # The applications the project is taken to own the appups for: its own, plus
  # every child of an umbrella. Everything else in the release is something
  # whose upgrade instructions, if it has any, were written for somebody else's
  # transitions.
  defp project_apps do
    umbrella =
      case Mix.Project.apps_paths() do
        nil -> []
        paths -> Map.keys(paths)
      end

    Enum.reject([Mix.Project.config()[:app] | umbrella], &is_nil/1)
  end

  # For the message only - the decision above rests on ownership alone. That is
  # why `Mix.Project.deps_apps/0`, which loads and caches the whole dependency
  # tree, is reached only once something has already been found to report.
  defp describe_app(app, owned) do
    cond do
      app in owned -> "an application this project owns"
      app in @elixir_apps -> "one of Elixir's own applications"
      app in Mix.Project.deps_apps() -> "a dependency"
      otp_app?(app) -> "one of OTP's own applications"
      true -> "not an application this project owns"
    end
  end

  # `:code.lib_dir/1` resolves an OTP application whether or not it has been
  # loaded, so this does not depend on what the build happens to have left on
  # its code path. It resolves dependencies and Elixir's own applications too,
  # hence the comparison against OTP's library directory rather than a bare
  # success.
  defp otp_app?(app) do
    case :code.lib_dir(app) do
      {:error, _reason} -> false
      dir -> List.starts_with?(dir, :code.lib_dir())
    end
  end

  ## Refusals

  defp refuse_erts_change!(%{erts: erts}, %{erts: erts}), do: :ok

  defp refuse_erts_change!(from, target) do
    Mix.raise(
      "--hot was given, but the transition between #{from.vsn} and #{target.vsn} changes " <>
        "ERTS from #{from.erts} to #{target.erts}. An ERTS change cannot be hot: " <>
        ":systools inserts restart_new_emulator for one, which reboots the emulator " <>
        "before any of the relup runs. Generate this relup with --restart, which makes " <>
        "it a single restart_emulator transition instead."
    )
  end

  defp refuse_hot_restarts!(plan) do
    case found_restarts(plan) do
      [] ->
        plan

      found ->
        Mix.raise(
          "--hot was given, but the generated relup restarts the emulator: " <>
            describe_restarts(found) <>
            ". An appup asked for it. Generate this relup with --restart if the restart " <>
            "is wanted, or take the instruction out of the appup."
        )
    end
  end

  # Why the generated relup is inspected rather than trusted. `:systools` inserts
  # `restart_new_emulator` for an ERTS change, which `auto` has already taken out
  # of its hands by making that transition a restart, so anything found here came
  # from an appup that asked for it by name.
  #
  # The two-stage instruction is refused rather than shipped, whatever the
  # strategy: it boots a hybrid temporary release and replies
  # `{continue_after_restart, ...}`, and Castle is built for the one-stage one.
  # The one-stage ones are handed back, because a plain `restart_emulator` from an
  # appup is the transition `auto` would have generated for itself, and is
  # settled together with `auto`'s own choices - announced, or refused while such
  # a transition cannot be performed. Getting there by way of an appup rather
  # than by classification makes no difference to whether the relup can be
  # installed, and it must not make a difference to what the run says either.
  defp appup_restarts!(plan) do
    case Enum.split_with(found_restarts(plan), &(elem(&1, 2) == :restart_new_emulator)) do
      {[], one_stage} ->
        one_stage

      {two_stage, _one_stage} ->
        Mix.raise(
          "the generated relup asks for the two-stage emulator restart: " <>
            describe_restarts(two_stage) <>
            ". restart_new_emulator boots a hybrid temporary release and continues the " <>
            "relup on the way up, replying {continue_after_restart, Vsn, Descr} rather " <>
            "than {ok, Vsn, Descr}; Castle is built for the one-stage restart_emulator. " <>
            "Generate this relup with --restart, or take the instruction out of the appup."
        )
    end
  end

  defp found_restarts({_vsn, ups, downs}) do
    for {label, entries} <- [{"upgrade from", ups}, {"downgrade to", downs}],
        {from, _descr, script} <- entries,
        instruction <- Enum.filter(script, &(&1 in @restart_instructions)),
        do: {label, to_string(from), instruction}
  end

  defp describe_restarts(found) do
    Enum.map_join(found, "; ", fn {label, vsn, instruction} ->
      "#{instruction} on the #{label} #{vsn}"
    end)
  end

  ## Saying which strategy was chosen

  # The two instructions differ in what `install_release/1` replies, and an
  # operator or a CI check reads that reply, so which one a run chose is not
  # something to leave implicit.
  defp announce_restart do
    Mix.shell().info(
      "--restart: every transition in this relup is a single restart_emulator " <>
        "instruction. No appup is read and nothing is hot-loaded; install_release/1 " <>
        "replies {ok, Vsn, Descr} and the emulator then reboots."
    )
  end

  defp announce_restarts(chosen, found) do
    Mix.shell().info(
      "auto: " <>
        describe_causes("chose a restart transition for ", chosen, found) <>
        ". Each of those is a single restart_emulator instruction, so install_release/1 " <>
        "replies {ok, Vsn, Descr} rather than {continue_after_restart, Vsn, Descr}, and " <>
        "the emulator then reboots. Pass --hot to refuse a restart instead, or " <>
        "--restart to ask for one everywhere."
    )
  end

  # The two ways a restart arrives, in one clause, so that a run has one verdict
  # rather than one per kind. Either list may be empty - but not both, which is
  # the all-hot case and is said elsewhere.
  defp describe_causes(chosen_phrase, chosen, found) do
    [
      {chosen_phrase, chosen, &describe_edges/1},
      {"an appup asks for the emulator to be restarted: ", found, &describe_restarts/1}
    ]
    |> Enum.reject(fn {_phrase, causes, _describe} -> causes == [] end)
    |> Enum.map_join(", and ", fn {phrase, causes, describe} -> phrase <> describe.(causes) end)
  end

  defp describe_edges(edges) do
    Enum.map_join(edges, "; ", fn {label, vsn, reasons} ->
      "the #{label} #{vsn} (#{Enum.join(reasons, ", ")})"
    end)
  end

  ## While a restart transition cannot be performed

  # The one place that decides whether `auto` may write a restart transition at
  # all, and deliberately temporary. A single named predicate on purpose: not a
  # version sniff, not an environment variable, nothing a deployment could set
  # by accident.
  #
  # A restart relup can be generated and packaged, but the transition it
  # describes cannot yet be completed. `release_handler` calls `heart:set_cmd/1`
  # while preparing the reboot - from `prepare_restart_new_emulator/7`, which
  # both restart instructions go through - and that raises `badarg` where there
  # is no `heart` process, so the install fails before anything reboots. Past
  # that, the reboot would come back on the old permanent version anyway, because
  # only `commit` writes `releases/start_erl.data`.
  # [castle#14](https://github.com/ausimian/castle/issues/14) and
  # [#10](https://github.com/ausimian/forecastle/issues/10) close those halves.
  #
  # `auto` is the strategy a run with no switches gets. Emitting a restart
  # transition from it would mean a routine invocation producing an upgrade plan
  # that is known not to install - worse than one that refuses and says why. So
  # it refuses, naming the edge, the reason, and `--restart` as the override.
  # `--hot` and `--restart` are unaffected either way: both are explicit
  # requests, and it is fine for `--restart` to produce a relup that cannot yet
  # be deployed.
  #
  # When those two issues land, make this `true`. `announce_restarts/2` is what
  # `auto` says instead, and nothing else has to change.
  defp restart_transitions_installable?, do: false

  # One verdict per invocation, arrived at once the relup exists: the transitions
  # `auto` classified as restarts and the emulator restarts an appup asked for by
  # name are the same kind of transition, so they are settled together. Saying
  # every transition is hot before the second kind has been looked for is how a
  # run came to contradict itself.
  defp settle_restarts!([], []) do
    Mix.shell().info("auto: every transition in this relup is a hot upgrade.")
  end

  defp settle_restarts!(chosen, found) do
    if restart_transitions_installable?() do
      announce_restarts(chosen, found)
    else
      refuse_restarts!(chosen, found)
    end
  end

  defp refuse_restarts!(chosen, found) do
    Mix.raise(
      describe_causes("auto would make a restart transition of ", chosen, found) <>
        ". A restart transition cannot yet be performed: release_handler calls " <>
        "heart:set_cmd/1 while preparing the reboot, which fails where there is no heart " <>
        "process, so the install fails before rebooting - and the reboot would come back " <>
        "on the old permanent version even if it did not. castle#14 and forecastle#10 " <>
        "close that. Rather than write an upgrade plan that cannot be installed, auto " <>
        "refuses. Pass --restart to generate it anyway, which is the deliberate override; " <>
        "pass --hot to fail on the transition itself instead; or " <>
        describe_remedies(chosen, found) <> "."
    )
  end

  defp describe_remedies(chosen, found) do
    [
      {chosen, "take the change that forced the restart out of this release"},
      {found, "take the restart instruction out of the appup"}
    ]
    |> Enum.reject(fn {causes, _remedy} -> causes == [] end)
    |> Enum.map_join(" and ", fn {_causes, remedy} -> remedy end)
  end

  ## Writing the relup

  # A relup file is an encoding comment and a single term followed by a period,
  # which is the format `systools_relup:write_relup_file/2` writes and that
  # `release_handler` - and `Forecastle.verify_relup!/2`, on the way into a
  # release - reads back.
  defp write_relup!(plan, outdir) do
    File.write!(Path.join(outdir, "relup"), encode!(plan))
  end

  defp encode!(plan) do
    case :unicode.characters_to_binary(:io_lib.format(~c"%% coding: utf-8~n~tp.~n", [plan])) do
      bytes when is_binary(bytes) -> bytes
      _not_encodable -> Mix.raise("the relup cannot be encoded as UTF-8: #{inspect(plan)}")
    end
  end
end
