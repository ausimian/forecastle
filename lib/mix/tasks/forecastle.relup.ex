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

  The `--fromto`, `--upfrom` and `--downto` switches may be specified zero or more
  times and have the following behaviour:

    - `--fromto` generates both upgrade and downgrade instructions
    - `--upfrom` generates only upgrade instructions
    - `--downto` generates only downgrade instructions

  The task fails if the relup could not be generated, so that a build pipeline
  does not carry on and package whatever relup happened to be lying around.

  `--outdir` must already exist, and only ever affects where this task writes.
  Post-assembly copies the relup it finds in the project root, which is where
  the default puts it, so a relup destined for a release should be generated
  without `--outdir`.
  """
  @shortdoc "Generate a relup file between releases"

  use Mix.Task

  @options [upfrom: :keep, downto: :keep, fromto: :keep, outdir: :string, target: :string]

  @impl Mix.Task
  def run(command_line_args) do
    # Elixir prunes unused OTP applications from the build's code path, which
    # would otherwise leave :systools unavailable in projects that don't
    # already depend on :sasl.
    Mix.ensure_application!(:sasl)
    {:ok, _} = :application.ensure_all_started(:sasl)

    relup_args = command_line_args |> parse!() |> make_relup_args()

    # Through `apply/3`: `:sasl` is not a dependency, so `:systools` is not on
    # the code path this module is compiled against.
    :systools |> apply(:make_relup, relup_args) |> report()
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

  defp make_relup_args(cmdline_args) do
    target = cmdline_args |> fetch_target!() |> to_charlist()
    upfrom = get_rel_paths(cmdline_args, :upfrom)
    downto = get_rel_paths(cmdline_args, :downto)
    fromto = get_rel_paths(cmdline_args, :fromto)
    opts = get_opts(cmdline_args, [target] ++ upfrom ++ downto ++ fromto)
    [target, upfrom ++ fromto, downto ++ fromto, opts]
  end

  defp fetch_target!(cmdline_args) do
    case Keyword.fetch(cmdline_args, :target) do
      {:ok, target} -> target
      :error -> Mix.raise("--target is required: there is nothing to generate a relup for")
    end
  end

  # `silent` is what makes the outcome inspectable: without it `make_relup/4`
  # prints its own diagnostics and collapses every failure into a bare `:error`.
  # Not `noexec`, which returns the same shapes but writes no relup at all.
  defp get_opts(cmdline_args, relpaths) do
    [:silent, {:path, get_ebin_paths(relpaths)}] ++ get_outdir(cmdline_args)
  end

  # A missing directory reaches `systools` as a failure to open "relup", which
  # does not mention the directory it could not open it in. Say so here instead.
  # Creating it is deliberately not this task's job: a mistyped `--outdir` that
  # springs into existence is how a relup ends up somewhere nothing looks for it.
  defp get_outdir(cmdline_args) do
    case Keyword.fetch(cmdline_args, :outdir) do
      {:ok, outdir} -> [{:outdir, existing_dir!(outdir)}]
      :error -> []
    end
  end

  defp existing_dir!(outdir) do
    if File.dir?(outdir) do
      to_charlist(outdir)
    else
      Mix.raise("--outdir #{outdir} is not a directory")
    end
  end

  defp get_rel_paths(cmdline_args, type) do
    cmdline_args
    |> Keyword.take([type])
    |> Keyword.values()
    |> Enum.map(&to_charlist/1)
  end

  defp get_ebin_paths(relpaths) do
    relpaths
    |> Enum.map(&Path.join(&1, "../../../lib/*/ebin"))
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&to_charlist/1)
  end

  # The warnings are the ones `make_relup/4` would have printed itself; `silent`
  # hands them over instead, and an ERTS version change is not something to
  # swallow. The module to format either with is the one the result names - an
  # error can come from `systools_make` rather than `systools_relup`.
  defp report({:ok, _relup, module, warnings}) do
    warnings
    |> List.wrap()
    |> Enum.each(&Mix.shell().error(format(module, :format_warning, &1)))
  end

  defp report({:error, module, error}) do
    Mix.raise(format(module, :format_error, error))
  end

  # Only `silent`'s shapes can arrive here. Anything else means `make_relup/4`
  # did not honour it, and failing is the safe direction: it is a bare `:error`
  # passing for success that this reporting exists to prevent.
  defp report(other) do
    Mix.raise("Unexpected result from :systools.make_relup/4: #{inspect(other)}")
  end

  defp format(module, fun, term) do
    module |> apply(fun, [term]) |> to_string() |> String.trim_trailing()
  end
end
