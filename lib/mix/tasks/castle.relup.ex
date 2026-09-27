defmodule Mix.Tasks.Castle.Relup do
  @moduledoc """
  Generates a relup for an existing target release.

      mix castle.relup --target <path> --fromto <spec>

  For a release being assembled now, prefer `upgrade_from:` with
  `Castle.customize/1`; Forecastle then writes the relup immediately before
  `:tar`. Use this task for an existing target, separate upgrade and downgrade
  baselines, explicit strategies, or a dry run.

  ## Options

  - `--target` names the target `.rel` path without the extension.
  - `--fromto` generates both directions from a baseline.
  - `--upfrom` generates only an upgrade from a baseline.
  - `--downto` generates only a downgrade to a baseline.
  - `--outdir` selects an existing output directory. It defaults to the current
    directory.
  - `--hot` requires every transition to remain hot.
  - `--restart` makes every transition restart the emulator.
  - `--dry-run` validates and reports the plan without writing the relup.

  Supply at least one baseline switch. `--hot` and `--restart` are mutually
  exclusive.

  ## Baselines

  Baseline switches accept three sources:

      rel:_build/prod/rel/my_app/releases/1.0.0/my_app
      tar:artifacts/my_app-1.0.0.tar.gz
      ref:v1.0.0

  A path without a prefix means `rel:`. `rel:` names an assembled release,
  `tar:` unpacks a release artifact, and `ref:` builds a git revision. Prefer
  `tar:` when the shipped artifact is available because a rebuilt baseline may
  differ from the deployed code.

  `--target` is always a path, not a baseline spec.

  The task writes a complete relup through a staging file. A failed generation
  leaves any existing output untouched. Use the default output directory when a
  later release build should package the project-root `relup`.

  ## Strategies

  `auto`, the default, keeps a transition hot unless the ERTS changes or an
  unowned application changes version without a matching appup. Upgrade and
  downgrade directions are classified separately. A missing appup for an owned
  application remains an error. Added and removed applications remain hot.

  `--hot` rejects a missing appup, ERTS change, or appup instruction that would
  restart the emulator. Use it for pipelines that require hot deployment.

  `--restart` emits a single `restart_emulator` instruction for each transition.
  It does not read appups or call `:systools`.

  Forecastle reports every restart edge and its reason. It supports only the
  one-stage `restart_emulator` transition and rejects `restart_new_emulator`,
  including instructions introduced by appups.

  ## Dry runs

  `--dry-run` resolves baselines and generates the complete plan without
  publishing the relup. Its exit status reports whether generation succeeded.
  It cannot detect a destination write failure.

  Baseline resolution may still write to `_build/castle/baselines`: `tar:`
  unpacks an artifact and `ref:` builds a revision. The relup and output
  directory remain untouched.
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
