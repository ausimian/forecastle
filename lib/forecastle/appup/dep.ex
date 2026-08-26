defmodule Forecastle.Appup.Dep do
  @moduledoc """
  The appups a project supplies for applications it does not own.

  Most Elixir hot upgrades die on a dependency: it bumped a patch version, it
  ships no appup, and `mix castle.relup`'s `auto` degrades the whole edge to a
  restart. Nothing is wrong with that classification - there genuinely is no hot
  upgrade to be had - but the missing piece is small and the project is in a
  position to supply it.

  The consuming half already exists. `Forecastle.Relup` reads the **target
  release's** copy of a dependency's appup and honours an entry that matches this
  from-version whoever wrote it, precisely because such an entry *is* an
  instruction for this transition. What was missing is a place to put one and a
  step that puts it there.

  ## Where they live

  `rel/appups/<app>-<from>-<to>.exs`, beside `rel/env.sh.eex`, in the same
  source-you-commit spirit as the file the `:appup` key names. The path is
  resolved against the **project file** rather than the working directory, which
  is what `Mix.Tasks.Compile.Appup` does with the `:appup` key and for the same
  reason: nothing guarantees the working directory of a `mix release` invoked
  from elsewhere.

  **It is a fixed path rather than `:rel_templates_path`, and that is a decision
  rather than an oversight.** That option belongs to one release, and
  `mix castle.appup.gen` - which writes these files - has no release to read it
  from. Two answers to "where do the dependency appups live" that could disagree
  is one more than a writer and a reader of the same directory can have, and the
  half that disagreed would write a file no build ever reads.

  ## Never into `deps/`

  The appup belongs to the release being assembled, not to the checkout it was
  built from. `deps/` and `_build/`'s copy of a dependency are shared by every
  release built from that tree - and, with a shared build cache, by other
  projects - so writing there would leak one project's upgrade instructions into
  builds that never asked for them. Nothing here writes outside
  `Mix.Release.path`.

  ## The filename is read against the release, not parsed

  A version may itself contain a `-` (`1.7.0-rc.2` is an ordinary one), so
  splitting `<app>-<from>-<to>` on dashes is a guess, and a guess is what this
  tree does not make about which transition a file describes.

  It is not split, because both ends are already known. The release says which
  applications it carries and at which version, so for every application `A` at
  version `V` the name `A-<from>-V` is matched by anchoring `"A-"` at the front
  and `"-V"` at the back and taking whatever is left as the from-version. That is
  exact whatever either version contains. A name that matches no application at
  that application's version is **refused**, which is the stale case: the release
  moved on and the file did not.

  ## Nothing here is skipped quietly

  A file in this directory was written to be packaged, so every way one can fail
  to be packaged is a refusal that names it. All of them are made from
  `Forecastle.pre_assemble/1`, before Mix has created the version directory,
  where failing costs no build - `Forecastle.stage_relup/1` says at length why
  that matters, and it matters identically here.

    * an entry that is not a `.exs` file. Dotfiles are excepted, because
      `.DS_Store` and `.gitkeep` belong to the filesystem and the editor rather
      than to this directory; nothing else is, and nothing recurses.
    * a name that matches no application in the release, or matches one at a
      version the release does not carry.
    * a name that can be read as two different applications.
    * an application the project owns. Its appup comes from the `:appup`
      compiler, and a file here would be written over the compiled one after the
      compiler had produced it.
    * a file that does not evaluate to an appup, that introduces top-level
      bindings, that holds something which is not a `{from_version, script}`
      entry, or whose version tag is not the version the release carries.
    * a file whose own appup has no entry for the from-version its name claims.
    * two entries for one application keyed by the same from-version.

  The one thing that is *not* refused is a file covering only one direction. An
  appup with an upgrade entry and no downgrade is a legitimate thing to write,
  `auto` classifies each direction on its own, and the restart it makes of the
  other direction is announced there rather than hidden.

  One refusal is made *after* assembly, because nothing before it can be sure: an
  application named by a source that has no `lib/<app>-<vsn>/ebin` in the
  assembled release. That is reachable rather than theoretical -
  `Mix.Release.copy_app/2` copies nothing for an OTP application when the release
  brings no ERTS of its own, since the deployment then takes those from the host -
  so it is named rather than modelled here, and it costs a build.

  ## Two files for one application are merged, in name order

  A release upgradeable from more than one baseline needs an entry per baseline,
  and a release has one appup per application to hold them. So the entries of
  every file naming the same application are concatenated, in the order the file
  names sort. That order is stated rather than incidental:
  `appup_search_for_version/2` takes the **first** entry that matches.

  Two entries keyed by the same from-version are refused, because that is the
  case where the order decides the answer and nothing here can decide it. Two
  *regular expression* keys that overlap are not refused: whether two regexes can
  match the same version is not a question this can answer exactly, and answering
  it approximately is the shape of guess this tree does not make. They resolve
  the way `release_handler` resolves them - first match wins, in name order.
  """

  alias Forecastle.Appup

  @typedoc """
  One application's appup, read and encoded, ready to be written into the
  assembled release.
  """
  @type placement :: %{
          app: atom(),
          vsn: binary(),
          bytes: binary(),
          sources: [binary()]
        }

  @doc """
  The directory project-supplied appups are read from and written to.

  Resolved against the project file, so a run from anywhere reads and writes the
  same directory the assembly step will.
  """
  @spec dir() :: binary()
  def dir do
    Mix.Project.project_file() |> Path.dirname() |> Path.join("rel/appups")
  end

  @doc """
  Reads every appup source in `dir/0` and returns what to write into the release.

  Called from `Forecastle.pre_assemble/1`, so every refusal below happens before
  Mix has created anything. The bytes are produced here rather than at write time
  for the reason `Forecastle.copy_relup/1` gives about the relup: these files are
  *arbitrary Elixir evaluated for their value*, so reading them a second time is
  not necessarily reading what was checked.
  """
  @spec stage!(Mix.Release.t()) :: [placement()]
  def stage!(%Mix.Release{} = release) do
    case sources!() do
      [] ->
        []

      sources ->
        # `script/2` matches a from-version through `:systools_relup`, which is
        # not on the code path this is compiled against. `Forecastle.Relup` asks
        # for the same thing during assembly, so this is not a new dependency of
        # the build - only a new place that has it.
        Appup.ensure_systools!()

        versions = versions(release)

        sources
        |> Enum.map(&read!(&1, versions))
        |> group!()
    end
  end

  @doc """
  Writes the staged appups into the assembled release.

  Called from `Forecastle.post_assemble/1`, which is the first moment
  `lib/<app>-<vsn>/ebin` exists. Each one is announced, because an appup is an
  instruction `release_handler` will act on and a release quietly acquiring one
  is the shape of thing `design/upgrade-tooling.md` D2 exists to prevent.
  """
  @spec place!(Mix.Release.t(), [placement()]) :: :ok
  def place!(%Mix.Release{path: path}, placements) do
    Enum.each(placements, &write!(path, &1))
  end

  ## Finding the sources

  defp sources! do
    dir = dir()

    case File.ls(dir) do
      # Sorted here, once, so that the merge order in `group!/1` is the order the
      # names sort in rather than the order the filesystem happened to list them.
      {:ok, entries} ->
        entries |> Enum.sort() |> Enum.flat_map(&source!(dir, &1))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Mix.raise("#{shorten(dir)} could not be read: #{:file.format_error(reason)}")
    end
  end

  defp source!(_dir, "." <> _dotfile), do: []

  defp source!(dir, entry) do
    path = Path.join(dir, entry)

    if Path.extname(entry) == ".exs" and File.regular?(path) do
      [path]
    else
      Mix.raise(
        "#{shorten(path)} is not an appup source. Everything in #{shorten(dir)} is one, " <>
          "named <app>-<from>-<to>.exs, and nothing recurses into a directory there. A file " <>
          "that is neither would be left out of the release without a word, which is the one " <>
          "answer this refuses to give. Rename it, or move it out of #{shorten(dir)}."
      )
    end
  end

  # The versions the release carries, which are both halves of what a filename
  # is matched against. `Mix.Release` holds them as charlists, because that is
  # what an application resource says.
  defp versions(%Mix.Release{applications: applications}) do
    for {app, properties} <- applications, do: {app, to_string(Keyword.fetch!(properties, :vsn))}
  end

  ## Reading one source

  defp read!(path, versions) do
    {app, vsn, from} = named!(path, versions)

    refuse_owned!(app, path)

    appup = appup!(path, app, vsn)

    refuse_uncovered!(appup, from, path)

    %{app: app, vsn: vsn, from: from, path: path, appup: appup}
  end

  defp named!(path, versions) do
    base = Path.basename(path, ".exs")

    case Enum.flat_map(versions, &anchored(base, &1)) do
      [one] -> one
      [] -> Mix.raise(unnamed(path, base, versions))
      many -> Mix.raise(ambiguous(path, many))
    end
  end

  # Anchored at both ends against a version the release actually carries, so the
  # from-version is whatever is left rather than whatever a split produced. The
  # length test is what keeps a prefix and a suffix that overlap - which
  # `binary_part/3` would answer with a negative length - out of the match.
  defp anchored(base, {app, vsn}) do
    prefix = "#{app}-"
    suffix = "-#{vsn}"
    length = byte_size(base) - byte_size(prefix) - byte_size(suffix)

    if length > 0 and String.starts_with?(base, prefix) and String.ends_with?(base, suffix) do
      [{app, vsn, binary_part(base, byte_size(prefix), length)}]
    else
      []
    end
  end

  # The stale case, and the message is most of what it is worth. A file naming an
  # application the release carries at some other version is reported against
  # that version, because "which release is this appup for" is the question the
  # author has to answer and the release is holding the answer.
  defp unnamed(path, base, versions) do
    case Enum.filter(versions, fn {app, _vsn} -> String.starts_with?(base, "#{app}-") end) do
      [] ->
        "#{shorten(path)} does not name an application in this release. The name is " <>
          "<app>-<from>-<to>.exs, where <to> is the version of <app> this release carries."

      named ->
        "#{shorten(path)} is named for a version " <>
          Enum.map_join(named, " or ", fn {app, vsn} -> "of #{app} other than #{vsn}" end) <>
          ", which is what this release carries. An appup for a transition this release is " <>
          "not part of would be packaged as this release's instructions and applied by " <>
          "release_handler as though it were, so it is refused rather than left out. Rename " <>
          "it for the transition this release is, or take it out of #{shorten(dir())}."
    end
  end

  defp ambiguous(path, many) do
    "#{shorten(path)} can be read as an appup for " <>
      Enum.map_join(many, " and for ", fn {app, vsn, from} -> "#{app} #{from} -> #{vsn}" end) <>
      ", and nothing here chooses between them. Rename it so that exactly one reading of " <>
      "<app>-<from>-<to> is possible."
  end

  defp refuse_owned!(app, path) do
    if app in Appup.project_apps() do
      Mix.raise(
        "#{shorten(path)} is an appup for #{app}, which this project owns. Its appup comes " <>
          "from the :appup compiler and the source the :appup key names, and a file here " <>
          "would be written over the compiled one after the compiler had produced it - two " <>
          "sources of truth for one application's upgrade instructions, with the loser " <>
          "decided by the order of the build. Put the entry in the project's own appup " <>
          "source instead; mix castle.appup.gen writes it there."
      )
    end
  end

  defp appup!(path, app, vsn) do
    case evaluate!(path) do
      {tag, up, dn} = appup when is_list(up) and is_list(dn) ->
        refuse_bad_vsn!(tag, vsn, app, path)
        refuse_bad_entry!(up ++ dn, path)
        appup

      other ->
        Mix.raise(
          "#{shorten(path)} does not evaluate to an appup. Expected a single " <>
            "{version, upgrade, downgrade} tuple with two lists in it, which is what the " <>
            ":appup compiler writes and systools reads, but got: #{inspect(other)}"
        )
    end
  end

  # The same contract `Mix.Tasks.Compile.Appup` evaluates an appup source under,
  # said rather than left to a MatchError: the file is evaluated for its value
  # and must not introduce top-level bindings.
  defp evaluate!(path) do
    case Code.eval_file(path) do
      {appup, []} ->
        appup

      {_appup, bindings} ->
        Mix.raise(
          "#{shorten(path)} introduced top-level bindings: " <>
            "#{Enum.map_join(bindings, ", ", fn {name, _value} -> inspect(name) end)}. An " <>
            "appup source is evaluated for its value, the way the :appup compiler evaluates " <>
            "the file the :appup key names."
        )
    end
  end

  # `systools_relup` reports a tag that is not the application's version as a
  # `bad_vsn` warning and uses the entry anyway, which is why
  # `Forecastle.Appup.vsn/1` exposes it rather than checking it. Here it is
  # refused: the file names a version in its tag and another in its name, and two
  # of them disagreeing means one of them describes a transition this release is
  # not part of.
  defp refuse_bad_vsn!(tag, vsn, app, path) do
    wanted = to_charlist(vsn)

    if tag != wanted do
      Mix.raise(
        "#{shorten(path)} is tagged #{inspect(tag)}, but #{app} is #{vsn} in this release. " <>
          "The tag is the version the appup belongs to, and systools would report the " <>
          "mismatch as a bad_vsn warning and use the entry regardless."
      )
    end
  end

  defp refuse_bad_entry!(entries, path) do
    case Enum.reject(entries, &entry?/1) do
      [] ->
        :ok

      [bad | _rest] ->
        Mix.raise(
          "#{shorten(path)} holds something that is not an appup entry: #{inspect(bad)}. An " <>
            "entry is a {from_version, instructions} pair, and systools refuses an appup " <>
            "that holds anything else."
        )
    end
  end

  defp entry?({vsn, script}) when (is_list(vsn) or is_binary(vsn)) and is_list(script), do: true
  defp entry?(_element), do: false

  # Asked the way `release_handler` asks it rather than by comparing strings, so
  # a from-version written as a regular expression counts as naming the one the
  # file is named for.
  defp refuse_uncovered!(appup, from, path) do
    covered? =
      Enum.any?([:up, :down], fn direction ->
        match?({:ok, _script}, Appup.script(Appup.entries(appup, direction), from))
      end)

    if covered? do
      :ok
    else
      Mix.raise(
        "#{shorten(path)} is named for a transition from #{from}, but the appup in it has " <>
          "no entry for #{from} in either direction - selected the way release_handler " <>
          "selects one, so a from-version written as a regular expression counts. The name " <>
          "and the contents describe different transitions and nothing here decides which " <>
          "was meant."
      )
    end
  end

  ## One appup per application

  defp group!(reads) do
    reads
    |> Enum.group_by(& &1.app)
    |> Enum.sort()
    |> Enum.map(fn {app, group} -> merge!(app, group) end)
  end

  defp merge!(app, [%{vsn: vsn} | _rest] = group) do
    up = Enum.flat_map(group, &Appup.entries(&1.appup, :up))
    dn = Enum.flat_map(group, &Appup.entries(&1.appup, :down))
    sources = Enum.map(group, & &1.path)

    refuse_collision!(app, :up, up, sources)
    refuse_collision!(app, :down, dn, sources)

    %{
      app: app,
      vsn: vsn,
      bytes: encode!(app, {to_charlist(vsn), up, dn}, sources),
      sources: sources
    }
  end

  defp refuse_collision!(app, direction, entries, sources) do
    duplicates =
      entries
      |> Enum.map(&elem(&1, 0))
      |> Enum.frequencies()
      |> Enum.filter(fn {_vsn, count} -> count > 1 end)

    case duplicates do
      [] ->
        :ok

      [{vsn, _count} | _rest] ->
        Mix.raise(
          "#{Enum.map_join(sources, " and ", &shorten/1)} give #{app} two #{word(direction)} " <>
            "entries for #{inspect(vsn)}. appup_search_for_version/2 takes the first entry " <>
            "that matches, so which of them ran would be decided by the order the file names " <>
            "sort in - which is not something to decide an upgrade with. Keep one."
        )
    end
  end

  defp word(:up), do: "upgrade"
  defp word(:down), do: "downgrade"

  # The encoding the `:appup` compiler writes, so a project-supplied appup and a
  # compiled one are the same kind of file. Measured on OTP 28.3: `file:consult/1`
  # reads UTF-8 with or without a coding comment, so the comment
  # `Forecastle.Relup` puts on a relup is not what makes this readable - the
  # refusal below is, because chardata that will not encode is written as lone
  # bytes that `systools` then cannot read back.
  defp encode!(app, appup, sources) do
    case :unicode.characters_to_binary(:io_lib.format(~c"~tp.~n", [appup])) do
      bytes when is_binary(bytes) ->
        bytes

      _not_encodable ->
        Mix.raise(
          "the appup for #{app} in #{Enum.map_join(sources, " and ", &shorten/1)} cannot be " <>
            "encoded as UTF-8"
        )
    end
  end

  ## Writing

  defp write!(path, %{app: app, vsn: vsn} = placement) do
    ebin = Path.join([path, "lib", "#{app}-#{vsn}", "ebin"])
    file = Path.join(ebin, "#{app}.appup")

    if File.dir?(ebin) do
      announce(placement, file, File.exists?(file))
      File.write!(file, placement.bytes)
    else
      Mix.raise(
        "this release has no #{Path.relative_to(ebin, path)} to place " <>
          "#{Enum.map_join(placement.sources, " and ", &shorten/1)} into. #{app} is #{vsn} in " <>
          "this release, so either a step changed the tree under this one, or the application " <>
          "was never copied into lib/ - which is what a release built with " <>
          "include_erts: false does with OTP's own applications, since a deployment then " <>
          "takes them from the host and there is nothing in the release to place an appup in."
      )
    end
  end

  defp announce(placement, file, replacing?) do
    Mix.shell().info(
      "* placing #{Enum.map_join(placement.sources, ", ", &shorten/1)} into " <>
        "#{shorten(file)}#{replaced(replacing?, placement.app)}"
    )
  end

  defp replaced(false, _app), do: ""
  defp replaced(true, app), do: ", replacing the appup #{app} shipped"

  defp shorten(path), do: Path.relative_to_cwd(path)
end
