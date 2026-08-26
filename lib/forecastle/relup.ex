defmodule Forecastle.Relup do
  @moduledoc """
  Generating a relup: resolving the baselines, deciding what each transition can
  be, asking `:systools` for the hot half, and writing the file.

  Two things generate relups and they must not be able to disagree about any of
  it. `mix castle.relup` names a target that already exists and writes the relup
  wherever it is told, which is what covers a pair of releases nobody is
  assembling now. `Forecastle.generate_relup/1` runs between `post_assemble` and
  `:tar` and writes it into the release being assembled, which is what removes
  the build-generate-rebuild cycle the task used to require.

  Neither of them promises that nothing is rebuilt. That is a property of the
  baseline spec: `rel:` and `tar:` name something already built, `ref:` checks a
  commit out and runs its build, and both callers resolve all three through
  `Forecastle.Baseline`.

  What differs between those two is where the target comes from, which baselines
  it is against, where the file goes, and *when* the baselines were resolved -
  which is the whole of what `generate!/6` takes as arguments. Everything else is
  here, once: the refusal of two baselines for one version, the three strategies
  and how an edge is classified, the announcement, and the atomic publication.

  `Mix.Tasks.Castle.Relup`'s `@moduledoc` is the account of the strategies and of
  what an operator sees, because that is where somebody goes looking for it.
  """

  # Elixir's own applications. `:code.lib_dir/1` resolves them, but under
  # Elixir's library directory rather than OTP's, so nothing about the path
  # distinguishes them from a dependency. None of them carries an appup, so a
  # version change in any of them is a restart.
  @elixir_apps [:eex, :elixir, :ex_unit, :iex, :logger, :mix]

  # The two instructions `release_handler` treats as "reboot the emulator".
  @restart_instructions [:restart_emulator, :restart_new_emulator]

  @typedoc """
  Which upgrade strategy every transition in the relup is generated under.

  See `Mix.Tasks.Castle.Relup` for what each of them means.
  """
  @type strategy :: :auto | :hot | :restart

  @doc false
  # The whole of generating a relup, once a caller has said which release it is
  # for, which baselines it is against, and where the file goes.
  #
  # `@doc false` rather than public: the arguments are in the order the work
  # happens rather than the order a caller would choose, and both callers that
  # exist are in this project. The task's two directions arrive as two lists,
  # because a baseline can legitimately be named in one direction and not the
  # other; the assembly step passes the same list twice, which is what
  # `--fromto` means.
  #
  # `resolved` is the spec-to-path map from `resolve_baselines!/1`, or `nil` to
  # resolve here. The two callers want different answers and both are right.
  #
  # The task passes `nil`, because for it the target is a path somebody typed:
  # resolving a baseline can mean unpacking a tarball or building a git ref, and
  # spending minutes on that only to find the target release is not where the
  # caller said it was is the wrong order to fail in. So it reads the target
  # first.
  #
  # The assembly step passes a map it resolved during `pre_assemble`, because for
  # it the target is Mix's own output and cannot be missing - while resolution is
  # the largest thing that can fail *after* `:assemble` has created the version
  # directory. Mix does not tidy up after a step of its own that raised, so a
  # failure there leaves a release a corrected retry will decline to overwrite
  # and exit 0 having assembled nothing. Resolving before `:assemble` takes that
  # whole class out of the window; what is left needs the assembled target and
  # has nowhere earlier to go.
  @spec generate!(
          Path.t(),
          [binary()],
          [binary()],
          %{binary() => Path.t()} | nil,
          strategy(),
          Path.t()
        ) ::
          :ok
  def generate!(target_path, up_specs, down_specs, resolved, strategy, outdir)
      when is_list(up_specs) and is_list(down_specs) and strategy in [:auto, :hot, :restart] do
    Forecastle.Appup.ensure_systools!()

    target = read_rel!(target_path)

    resolved = resolved || resolve_baselines!(up_specs ++ down_specs)

    ups = baseline_paths(up_specs, resolved)
    downs = baseline_paths(down_specs, resolved)
    froms = read_froms!(ups ++ downs, target)

    refuse_ambiguous!("upgrade from", ups, froms)
    refuse_ambiguous!("downgrade to", downs, froms)

    # Publication before the verdict, and that ordering is load bearing. An
    # announcement is a claim about a file that exists: encoding, opening,
    # writing, closing or renaming can each fail, and every one of those leaves
    # either no relup or - deliberately - the older one that was already there.
    # Said first, the run printed that every transition was a hot upgrade and
    # then failed to produce the relup it was describing.
    {plan, verdict} = plan!(strategy, target, froms, ups, downs)

    write_relup!(plan, outdir)

    if verdict, do: Mix.shell().info(verdict)

    :ok
  end

  @doc false
  # The split-and-merge, reachable on its own.
  #
  # `auto` is what merges hand-written restart entries into the same relup as the
  # ones `:systools` generated, and it is where an edge could be dropped, or
  # attached to the wrong direction, or one strategy applied to the whole relup.
  # It is reachable through the task now that a restart transition can be
  # installed, and it stays reachable on its own: the announcement deliberately
  # sits outside the merge rather than inside it, so that the merge can be driven
  # without a shell and asserted on as a term.
  #
  # What `auto` settles is not settled here: this returns the merged relup, and
  # nothing is said about the strategy on account of it.
  @spec plan_transitions!(binary(), [binary()], [binary()], [binary()], [binary()]) ::
          {charlist(), list(), list()}
  def plan_transitions!(target_path, hot_ups, hot_downs, restart_ups, restart_downs) do
    Forecastle.Appup.ensure_systools!()

    target = read_rel!(target_path)
    froms = read_froms!(hot_ups ++ hot_downs ++ restart_ups ++ restart_downs, target)

    {plan, _appup_restarts} =
      plan_transitions(target, froms, hot_ups, hot_downs, restart_ups, restart_downs)

    plan
  end

  ## Resolving the baselines

  # Each distinct spec resolved once, and the result mapped back onto the order
  # it was named in rather than resolved per occurrence: a spec put in both
  # directions - which is what `--fromto` does, and what the assembly step does
  # with every baseline it is given - would otherwise build that commit twice,
  # or, worse, once per direction into two cache entries.
  #
  # Two spellings of one release converge here rather than being deduplicated
  # here: `rel:x` and a bare `x` resolve to the same path, and `read_froms!/2`
  # reads each distinct *path* once.
  #
  # `:release` because a relup is generated from assembled releases. That is the
  # expensive level, and it is the one this needs; the coverage check is what
  # `:compile` is there for.
  @doc false
  # Public so that a caller can resolve *before* the work that would be wasted by
  # a baseline that cannot be resolved - which for the assembly step means before
  # `:assemble`. See `generate!/6` for why the two callers differ.
  @spec resolve_baselines!([binary()]) :: %{binary() => Path.t()}
  def resolve_baselines!(specs) do
    Map.new(Enum.uniq(specs), fn spec ->
      {spec, Forecastle.Baseline.resolve!(spec, :release).rel_path}
    end)
  end

  # Made unique *after* resolution as well as before it, because two specs can be
  # one release: `rel:x` and a bare `x` are the same path written two ways, and
  # two artefacts with the same bytes resolve to the same unpacking. Left in, the
  # same from-version would appear twice in one direction of the relup -
  # `release_handler` selects by from-version and would take the first, so the
  # second is at best inert, and `:systools` was never asked a question that
  # needed asking twice.
  #
  # Each direction on its own, because a release belongs in both directions of a
  # `--fromto` and that is not a duplicate.
  defp baseline_paths(specs, resolved) do
    specs |> Enum.map(&Map.fetch!(resolved, &1)) |> Enum.uniq_by(&baseline_identity/1)
  end

  # Which release a path *is*, rather than how it was spelled. `rel:` hands back
  # the path it was given, deliberately, so one release reaches here under as
  # many names as there are ways to write it: `./rel/...` and its absolute form
  # are the same release, and so is a symlinked spelling of the same tree.
  #
  # Device and inode settle it where the filesystem will say - that is the same
  # file by the only definition that does not depend on how it was reached, and
  # it sees through a symlinked spelling of one tree, which a textual comparison
  # cannot. `Path.expand/1` is the fallback for something that cannot be stat'd:
  # this is not the place to report that, and `read_rel!/1` a moment later says
  # exactly what it could not read and why.
  #
  # **The `.rel` file *and* the library directory, and the pair is the point.**
  # The `.rel` alone was not enough, and what it left was a false *dedup* rather
  # than a false ambiguity: `lib_dir/1` derives the code tree from the spelling of
  # whichever path survived, so two release roots sharing one `.rel` - a symlink
  # or a hard link to the same file - while holding different `lib/` trees
  # collapsed into one baseline, and which code tree the relup was then generated
  # against depended on the order the switches were written in. That is exactly
  # the failure `refuse_ambiguous!/3` exists to prevent, arriving underneath it.
  # Keyed on the pair, the two survive dedup and the ambiguity refusal names them.
  #
  # It is also why the library directory is compared by inode rather than by
  # `Path.expand/1`: a symlinked spelling of one tree expands to two different
  # strings, so a textual comparison there would refuse the
  # one-release-reached-two-ways case that dedup exists for.
  defp baseline_identity(path) do
    {file_identity(path <> ".rel"), file_identity(lib_dir(path))}
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: device, inode: inode}} -> {device, inode}
      {:error, _reason} -> Path.expand(path)
    end
  end

  # Two *different* releases that share a version are not two transitions. A
  # relup entry is selected by from-version, so only one of them could ever be
  # used, and which one would be whichever `:systools` happened to put first -
  # which is to say, whichever order the switches were written in. A relup that
  # silently describes an upgrade from one of two candidate releases is worse
  # than no relup, so this refuses rather than choosing.
  #
  # The specs now make this easy to reach without meaning to: one release can be
  # named three ways, and `tar:my_app-1.0.0.tar.gz` beside `ref:v1.0.0` is a
  # natural thing to write while checking that they agree. They may well not.
  #
  # Identical `.rel` terms would not settle it either. A `.rel` names
  # applications and their versions and nothing about the code inside them, so
  # two releases can agree on every line of it and share not one module - which
  # is the whole reason `tar:` is recommended over `ref:` in the first place.
  # Deduplicating on the path is therefore as far as this can go on its own; past
  # that it is a question for whoever wrote the command line.
  defp refuse_ambiguous!(label, paths, froms) do
    paths
    |> Enum.group_by(&froms[&1].vsn)
    |> Enum.reject(&match?({_vsn, [_only]}, &1))
    |> Enum.each(fn {vsn, ambiguous} -> Mix.raise(ambiguity(label, vsn, ambiguous)) end)
  end

  defp ambiguity(label, vsn, paths) do
    "#{length(paths)} different baselines were named for the #{label} #{vsn}: " <>
      Enum.map_join(paths, ", ", &inspect/1) <>
      ". A relup carries one entry per from-version and release_handler selects by " <>
      "version, so only one of these could ever be used and which one would depend on " <>
      "the order they were given in. Name the one you mean."
  end

  ## Reading the releases

  # The `.rel` terms are the whole description of a transition that is available
  # before any appup has been read: the release name and version, the ERTS
  # version, and every application with its version. A release is named by its
  # `.rel` file without the extension, which is what `:systools` wants, so the
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
  #
  # The empty clause is a backstop rather than the refusal a caller meets. Both
  # callers refuse first, in terms of how *they* were asked - the task names its
  # three switches, `Forecastle.generate_relup/1` names the release's
  # `upgrade_from:` option - because "you named no baselines" is only actionable
  # when it says where the naming happens. What this clause is for is that a
  # relup with no transitions in it is not an upgrade plan, so the next caller,
  # or a switch that grows a way to pass none, cannot quietly produce one.
  defp read_froms!([], _target) do
    Mix.raise(
      "no baselines were named, so there are no transitions to generate: a relup with " <>
        "no transitions in it is not an upgrade plan"
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

    # A baseline at the target's own version is not a transition, and `:systools`
    # will not say so: it accepts the pair and generates an entry from the
    # version to itself, whose script carries nothing but `point_of_no_return`.
    # `release_handler` selects an entry by the version it is upgrading *from*
    # and refuses to unpack a version a deployment already has, so such an entry
    # could never be used - and a build would have packaged it as this release's
    # upgrade plan without a word.
    #
    # The way to reach it without meaning to is assembling twice into one path:
    # `upgrade_from:` pointed at the release being built names a directory
    # `:assemble` has just replaced, so both the target and the baseline describe
    # the new release. Refused here rather than in the assembly step, because the
    # same spec typed at `mix castle.relup` is the same mistake.
    if from.vsn == target.vsn do
      Mix.raise(
        "#{from.file} is version #{from.vsn}, which is the version being generated for. " <>
          "A relup describes transitions between versions, and release_handler selects an " <>
          "entry by the version it is upgrading from, so an entry from a version to itself " <>
          "could never be used. Name the release this one is upgraded from - and if that " <>
          "path is the release being assembled, it was overwritten by this build."
      )
    end

    from
  end

  ## The three strategies

  defp plan!(:restart, target, froms, ups, downs) do
    # No appup is read on this path, so there is nothing an appup could have
    # asked for: the empty list is matched rather than discarded.
    {plan, []} = plan_transitions(target, froms, [], [], ups, downs)

    {plan, restart_verdict()}
  end

  defp plan!(:hot, target, froms, ups, downs) do
    Enum.each(froms, fn {_path, from} -> refuse_erts_change!(from, target) end)

    plan =
      target
      |> systools_plan!(ups, downs)
      |> refuse_hot_restarts!()

    # `--hot` says nothing on success: what it promises is that every transition
    # is a hot upgrade, and it refuses rather than reports when one is not.
    {plan, nil}
  end

  # Two things decide what `auto` does, and only one of them is knowable before
  # the relup exists - so nothing is said until both are.
  #
  # A restart classification chose is knowable from the two `.rel` files and the
  # appups. An appup that asks for the emulator to be restarted by name is not:
  # it is invisible until `:systools` has produced a script. Announcing after
  # classification alone is how a run said every transition was a hot upgrade and
  # then reported a restart in the same breath. So generation comes first and the
  # two kinds are settled together, which is what makes one verdict per
  # invocation possible at all.
  #
  # This used to refuse a classified restart *before* generating, because while
  # such a transition could not be installed the classification was already the
  # whole answer and a `:systools` error from the hot remainder would have stood
  # in front of it. It can be installed now
  # ([castle#14](https://github.com/ausimian/castle/issues/14) and
  # [#10](https://github.com/ausimian/forecastle/issues/10)), so there is nothing
  # to settle early and the ordering above is the only one that can be right.
  defp plan!(:auto, target, froms, ups, downs) do
    {restart_ups, hot_ups} = split_edges(:up, ups, froms, target)
    {restart_downs, hot_downs} = split_edges(:down, downs, froms, target)

    chosen =
      label_edges("upgrade from", restart_ups, froms) ++
        label_edges("downgrade to", restart_downs, froms)

    {plan, appup_restarts} =
      plan_transitions(
        target,
        froms,
        edge_paths(hot_ups),
        edge_paths(hot_downs),
        edge_paths(restart_ups),
        edge_paths(restart_downs)
      )

    {plan, restart_verdict(chosen, appup_restarts)}
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
  # the relup `:systools` would then generate cannot disagree. `Forecastle.Appup`
  # is where the reading and the matching live, and where the account of what
  # `get_script_from_appup/5` does is kept - it is shared with
  # `mix castle.appup`, which has to ask about the same file, keyed by the same
  # from-version, and reach the same answer.
  #
  # What is decided here rather than there is the *file*: `<app_dir>/<app>.appup`
  # where `app_dir` holds the **target** release's copy of the application, which
  # is the directory `:systools` resolves it to for this transition. So the appup
  # that decides an edge is the new version's, keyed by the version being
  # upgraded from.
  #
  # `nil` means covered. Anything else is the phrase that says what was missing.
  defp appup_gap(direction, app, target, from_vsn) do
    file = appup_file(app, target)

    case Forecastle.Appup.read(file) do
      {:ok, appup} -> entry_gap(appup, from_vsn, direction, file)
      {:error, gap} -> gap
    end
  end

  # `<release>/lib/<app>-<vsn>/ebin/<app>.appup` at the target's version of the
  # application, which is the directory `:systools` resolves the application to
  # when it reads the appup for this transition.
  defp appup_file(app, target) do
    Path.join([lib_dir(target.path), "#{app}-#{target.apps[app]}", "ebin", "#{app}.appup"])
  end

  defp entry_gap(appup, from_vsn, direction, file) do
    entries = Forecastle.Appup.entries(appup, direction)

    case Forecastle.Appup.script(entries, from_vsn) do
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

  # The applications the project is taken to own the appups for. In
  # `Forecastle.Appup` because `mix castle.appup` defaults to the same set, and
  # two answers to "which appups are ours" that could drift apart is one more
  # than this pair of tasks can have.
  defp project_apps, do: Forecastle.Appup.project_apps()

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
      "Cannot use --hot for the transition between #{from.vsn} and #{target.vsn}: " <>
        "ERTS changes from #{from.erts} to #{target.erts}. Generate this relup with " <>
        "--restart."
    )
  end

  defp refuse_hot_restarts!(plan) do
    case found_restarts(plan) do
      [] ->
        plan

      found ->
        Mix.raise(
          "Cannot use --hot: an appup adds an emulator restart (" <>
            describe_restarts(found) <>
            "). Remove the restart instruction or generate this relup with --restart."
        )
    end
  end

  # Why the generated relup is inspected rather than trusted. `:systools` inserts
  # `restart_new_emulator` for an ERTS change, which `auto` has already taken out
  # of its hands by making that transition a restart, so anything found here came
  # from an appup that asked for it by name.
  #
  # The two-stage instruction is refused rather than shipped, whatever the
  # strategy: it boots a hybrid temporary release and continues the relup after
  # the reboot, while Castle is built for the one-stage transition.
  # The one-stage ones are handed back, because a plain `restart_emulator` from an
  # appup is the transition `auto` would have generated for itself, and is
  # settled together with `auto`'s own choices, in the one announcement. Getting
  # there by way of an appup rather than by classification makes no difference to
  # the transition, and it must not make a difference to what the run says
  # either.
  #
  # The two-stage refusal is gated on nothing and stays that way. It is not about
  # whether a restart can be completed - the one-stage one can - but about which
  # instruction Castle is built for, which no amount of restart support changes.
  defp appup_restarts!(plan) do
    case Enum.split_with(found_restarts(plan), &(elem(&1, 2) == :restart_new_emulator)) do
      {[], one_stage} ->
        one_stage

      {two_stage, _one_stage} ->
        Mix.raise(
          "Cannot use restart_new_emulator (" <>
            describe_restarts(two_stage) <>
            "): Castle supports only restart_emulator. Remove the instruction from the " <>
            "appup or generate this relup with --restart."
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

  # `restart_emulator` names the supported one-stage strategy. Keep that useful
  # vocabulary in the announcement without exposing release_handler internals.
  defp restart_verdict do
    "--restart: every transition is a restart_emulator instruction. " <>
      "Appups are ignored; no code is hot-loaded. " <>
      "The restart target is provisional and must be committed after it boots."
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

  # One verdict per invocation, arrived at once the relup exists: the transitions
  # `auto` classified as restarts and the emulator restarts an appup asked for by
  # name are the same kind of transition, so they are settled together and named
  # in one message. Saying every transition is hot before the second kind has been
  # looked for is how a run came to contradict itself, and the all-hot line lives
  # in the first clause here for exactly that reason - it is only true after
  # generation.
  #
  # These *return* the verdict rather than printing it, and `generate!/6` prints
  # it only once the relup has been published. An announcement is a claim about a
  # file, and it was being made before the file existed: a failure to encode,
  # open, write, close or rename left a run that had already said every
  # transition was a hot upgrade and then produced no relup at all - or left the
  # older one in place, which the publication contract promises and which the
  # verdict would then have been describing instead.
  #
  # This is where `auto` refused, while a restart transition could not be
  # completed. It now names the `restart_emulator` transition, the reboot and the
  # provisional state an operator must commit.
  defp restart_verdict([], []) do
    "auto: every transition in this relup is a hot upgrade."
  end

  defp restart_verdict(chosen, found) do
    describe_causes("auto made a restart transition of ", chosen, found) <>
      ". Each uses restart_emulator and reboots into the installed release, which " <>
      "stays provisional until committed. Use --hot to refuse restart transitions " <>
      "or --restart to restart every transition."
  end

  ## Writing the relup

  # A relup file is an encoding comment and a single term followed by a period,
  # which is the format `systools_relup:write_relup_file/2` writes and that
  # `release_handler` - and `Forecastle.verify_relup!/2`, on the way into a
  # release - reads back.
  defp write_relup!(plan, outdir), do: publish_relup!(encode!(plan), outdir)

  defp encode!(plan) do
    case :unicode.characters_to_binary(:io_lib.format(~c"%% coding: utf-8~n~tp.~n", [plan])) do
      bytes when is_binary(bytes) -> bytes
      _not_encodable -> Mix.raise("the relup cannot be encoded as UTF-8: #{inspect(plan)}")
    end
  end

  @doc false
  # Publication, reachable on its own.
  #
  # Every refusal happens before this is called, so the run has decided to
  # replace the relup by the time it gets here - and replacement is the whole
  # point: a new relup is meant to supersede the one in the directory, so this is
  # a rename *over* the destination rather than an exclusive create.
  #
  # What must not happen is a reader, or a build, finding neither. `File.write!/2`
  # opens the destination for truncating replacement, so a failure once it is
  # open - out of space, a killed process, a close that failed, another run
  # writing the same path - leaves `relup` empty or half a plan even though the
  # invocation failed. That is exactly the case the documented guarantee is about,
  # and the one the stale-relup tests cannot see, because they fail before the
  # write. So the bytes go to a staging file in the same directory - the same
  # filesystem, which is what makes the rename atomic - and the destination is
  # only ever replaced whole.
  #
  # `write` is a seam, and it is here because standing in the window between
  # opening the staging file and renaming it is the only way to test that the
  # previous relup survives it.
  @spec publish_relup!(binary(), Path.t(), (:file.io_device(), binary() -> :ok | {:error, term()})) ::
          :ok
  def publish_relup!(bytes, outdir, write \\ &IO.binwrite/2) do
    staging = staging_path(outdir)

    try do
      stage!(staging, bytes, write)
      rename!(staging, Path.join(outdir, "relup"))
    after
      # On every path out, including the one that succeeded - where the rename
      # has already moved it and this finds nothing. A staging file is not a
      # relup and nothing else will ever read it, which is also why nothing else
      # would ever clean it up.
      File.rm(staging)
    end
  end

  # Unique per run: two runs sharing an output directory must not stage over each
  # other - two `mix castle.relup` invocations given the same `--outdir`, or one
  # of those beside a `mix release` writing into a version path - so the name
  # carries both the OS process and a counter within it. And unmistakable for a
  # relup - a leading dot and a `.tmp` suffix - because post-assembly reads the
  # path `relup`, and a staging file taken for an upgrade plan by anything that
  # scans the directory would be worse than the failure this exists to prevent.
  defp staging_path(outdir) do
    Path.join(outdir, ".relup-#{System.pid()}-#{System.unique_integer([:positive])}.tmp")
  end

  # `:exclusive`, though the name is unique by construction: if that name is
  # somehow taken, it is not doing its job, and opening the file anyway would
  # mean writing this relup over whatever else is in there.
  defp stage!(staging, bytes, write) do
    handle = open!(staging)
    written = write.(handle, bytes)

    # Closed before either result is looked at, since bytes can still be
    # buffered - so a close that fails means the staging file is not the whole
    # relup, and a handle left open on the failing path would keep the file alive
    # after it has been removed.
    closed = File.close(handle)

    with :ok <- written, :ok <- closed do
      :ok
    else
      {:error, reason} ->
        Mix.raise(
          "the relup could not be written to #{staging}: #{inspect(reason)}. The relup " <>
            "itself was not touched: it is replaced only once the whole of it has been " <>
            "staged."
        )
    end
  end

  defp open!(staging) do
    case File.open(staging, [:write, :binary, :exclusive]) do
      {:ok, handle} -> handle
      {:error, reason} -> Mix.raise("#{staging} could not be opened: #{inspect(reason)}")
    end
  end

  defp rename!(staging, relup) do
    case File.rename(staging, relup) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("#{staging} could not be renamed to #{relup}: #{inspect(reason)}")
    end
  end
end
