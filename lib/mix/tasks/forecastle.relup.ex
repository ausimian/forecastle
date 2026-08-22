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

  A transition becomes a restart when the ERTS version changed, or when the
  version of an application the project does not own changed: a dependency, one
  of Elixir's own applications, or one of OTP's. Those applications carry no
  appups written for this project's transitions, and an ERTS change is not a hot
  upgrade under any policy. Which transitions were chosen, and why, is printed.

  Applications *added* or *removed* between the two releases are left to
  `:systools`, whose `add_application` and `remove_application` instructions are
  hot: nothing has to be changed in place, only started or stopped.

  `auto` does not fall back to a restart when an appup is missing. A transition
  it judged hot and `:systools` then could not generate is a failure, so that
  `auto` never silently ships something other than the upgrade it decided on;
  ask for the restart with `--restart`.

  ### `--hot`

  Every transition must be a genuine hot upgrade, and generation fails, non-zero
  and having written nothing, if one cannot be: a missing appup entry, an ERTS
  change, or an appup that asks for the emulator to be restarted. This is the
  switch for a pipeline that requires zero-downtime deployment.

  Note that this is feasibility rather than policy. `--hot` will happily upgrade
  a dependency whose appup covers the transition, which `auto` would have made a
  restart.

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
    # Elixir prunes unused OTP applications from the build's code path, which
    # would otherwise leave :systools unavailable in projects that don't
    # already depend on :sasl.
    Mix.ensure_application!(:sasl)
    {:ok, _} = :application.ensure_all_started(:sasl)

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

    {to_charlist(target.vsn), restart_entries(ups, froms), restart_entries(downs, froms)}
  end

  defp plan!(:hot, target, froms, ups, downs) do
    Enum.each(froms, fn {_path, from} -> refuse_erts_change!(from, target) end)

    target
    |> systools_plan!(ups, downs)
    |> refuse_hot_restarts!()
  end

  defp plan!(:auto, target, froms, ups, downs) do
    reasons = Map.new(froms, fn {path, from} -> {path, restart_reasons(from, target)} end)
    {restart_ups, hot_ups} = Enum.split_with(ups, &(reasons[&1] != []))
    {restart_downs, hot_downs} = Enum.split_with(downs, &(reasons[&1] != []))

    announce_auto(Enum.uniq(restart_ups ++ restart_downs), froms, reasons)

    {vsn, up_entries, down_entries} = auto_hot_plan!(target, hot_ups, hot_downs)

    {vsn, up_entries ++ restart_entries(restart_ups, froms),
     down_entries ++ restart_entries(restart_downs, froms)}
  end

  # No `:systools` run at all when every transition in the relup is a restart:
  # an appup is then neither needed nor read, which is the point of a restart
  # transition.
  defp auto_hot_plan!(target, [], []), do: {to_charlist(target.vsn), [], []}

  defp auto_hot_plan!(target, ups, downs) do
    target
    |> systools_plan!(ups, downs)
    |> refuse_new_emulator!()
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
    relpaths
    |> Enum.map(&Path.join(&1, "../../../lib/*/ebin"))
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&to_charlist/1)
  end

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

  # What makes a transition ineligible for a hot upgrade under `auto`. Two
  # kinds: an ERTS change, which is not a hot upgrade under any policy, and a
  # version change in an application the project does not own, which is a
  # policy decision - such an application's appups, if it has any, were not
  # written for this project's transitions.
  defp restart_reasons(from, target) do
    erts_reason(from, target) ++ app_reasons(from, target)
  end

  defp erts_reason(%{erts: erts}, %{erts: erts}), do: []

  defp erts_reason(from, target) do
    ["ERTS changed from #{from.erts} to #{target.erts}"]
  end

  defp app_reasons(from, target) do
    owned = project_apps()

    for {app, vsn} <- Enum.sort(from.apps),
        moved?(target.apps, app, vsn),
        app not in owned do
      "#{inspect(app)} is #{describe_app(app, owned)} and changed " <>
        "from #{vsn} to #{target.apps[app]}"
    end
  end

  defp moved?(apps, app, vsn), do: Map.has_key?(apps, app) and apps[app] != vsn

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
        "before any of the relup runs. Generate this relup with --restart, or leave the " <>
        "strategy at auto, which makes such a transition a restart_emulator."
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

  # The one thing `auto` must not do quietly. `:systools` inserts
  # `restart_new_emulator` for an ERTS change, which `auto` has already taken
  # out of its hands by making that transition a restart, so anything found here
  # came from an appup that asked for it by name. It is refused rather than
  # shipped: it is the two-stage transition, which boots a hybrid temporary
  # release and replies `{continue_after_restart, ...}`, and Castle is built for
  # the one-stage one. Plain `restart_emulator` from an appup is the transition
  # `auto` would have generated for itself, so that is allowed - and said out
  # loud, because the reboot is not what a default strategy implies.
  defp refuse_new_emulator!(plan) do
    case Enum.split_with(found_restarts(plan), &(elem(&1, 2) == :restart_new_emulator)) do
      {[], []} ->
        plan

      {[], one_stage} ->
        announce_appup_restarts(one_stage)
        plan

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

  defp announce_auto([], _froms, _reasons) do
    Mix.shell().info("auto: every transition in this relup is a hot upgrade.")
  end

  defp announce_auto(paths, froms, reasons) do
    Mix.shell().info(
      "auto: chose a restart transition for " <>
        Enum.map_join(paths, "; ", &"#{froms[&1].vsn} (#{Enum.join(reasons[&1], ", ")})") <>
        ". Each of those is a single restart_emulator instruction, so install_release/1 " <>
        "replies {ok, Vsn, Descr} rather than {continue_after_restart, Vsn, Descr}, and " <>
        "the emulator then reboots. Pass --hot to refuse a restart instead, or " <>
        "--restart to ask for one everywhere."
    )
  end

  defp announce_appup_restarts(found) do
    Mix.shell().info(
      "auto: an appup asks for the emulator to be restarted: " <>
        describe_restarts(found) <>
        ". install_release/1 replies {ok, Vsn, Descr} and the emulator then reboots."
    )
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
