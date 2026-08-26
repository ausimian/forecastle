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
    * two entries for one application that can both be selected for one version.
    * an appup the application itself ships that cannot be read, since this is
      about to place one over it.

  The one thing that is *not* refused is a file covering only one direction. An
  appup with an upgrade entry and no downgrade is a legitimate thing to write,
  `auto` classifies each direction on its own, and the restart it makes of the
  other direction is announced there rather than hidden.

  Two refusals are made *after* assembly, because nothing before it can be sure,
  and both cost a build:

    * an application named by a source that has no `lib/<app>-<vsn>/ebin` in the
      assembled release. Reachable rather than theoretical -
      `Mix.Release.copy_app/2` copies nothing for an OTP application when the
      release brings no ERTS of its own, since the deployment then takes those
      from the host.
    * an appup at the destination that is not the copy Mix made of the build's
      own. `:assemble` copies the applications and *then* copies the release's
      overlays over them, so a `rel/overlays/lib/<app>-<vsn>/ebin/<app>.appup` is
      a second answer to what this application's upgrade instructions are, and
      writing over it is how the other one disappears. See `verify_staged!/2`.

  ## Two files for one application are merged, in name order

  A release upgradeable from more than one baseline needs an entry per baseline,
  and a release has one appup per application to hold them. So the entries of
  every file naming the same application are concatenated, in the order the file
  names sort. That order is stated rather than incidental:
  `appup_search_for_version/2` takes the **first** entry that matches.

  **Two entries that can both be selected for one version are refused**, which is
  where that order would decide the answer. "Can both be selected" is asked with
  the function that selects rather than by comparing keys - a binary key is a
  regular expression, so two entries collide without being equal terms - and it
  is asked at the versions the sources themselves name. What is left is two
  regular expressions overlapping at a version no source names, and that stays
  stated rather than modelled: whether two regexes can match one string is not
  decidable here, and a guess is worse than a documented edge.

  ## An appup the application shipped is merged into, not written over

  A dependency may carry an appup of its own, and a release built from a project
  that supplies one for a *different* baseline must not lose it: writing the file
  whole would turn a transition the dependency did support into a restart, with
  nothing said. So what is placed is the project's entries followed by the
  application's own, read from the build directory Mix copies its `ebin` from -
  before `:assemble`, so an unreadable one is still refused for free.

  **Where both describe one transition, the project's entry is the one selected,
  and every shipped entry it shadows is named.** Supplying an appup for a
  transition a dependency already covers is how a project corrects one that is
  wrong or incomplete - which is what `mix castle.appup` reports, and the only
  remedy short of forking the dependency. The placed file is tagged with the
  version the release carries, which is also the tag `systools` wants; a shipped
  appup whose own tag disagreed with its application was a `bad_vsn` warning
  before this and is not one afterwards.
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
          sources: [binary()],
          staged: binary() | nil,
          notes: [binary()]
        }

  @doc """
  The directory project-supplied appups are read from and written to.

  Resolved against the **project file** rather than the working directory, which
  is what `Mix.Tasks.Compile.Appup` does with the `:appup` key and for the same
  reason: nothing guarantees the working directory of a `mix release` invoked
  from elsewhere. It is therefore the project Mix has loaded that decides, which
  for an umbrella is the root a release is assembled from.
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
        |> group!(app_dirs(release))
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

  # Where Mix copies each application's `ebin` from, which is where an appup the
  # application shipped for itself is read from - before `:assemble`, so that
  # refusing one costs no build. `copy_app/2` reads the same key.
  defp app_dirs(%Mix.Release{applications: applications}) do
    for {app, properties} <- applications,
        into: %{},
        do: {app, Keyword.fetch!(properties, :path)}
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

  defp group!(reads, app_dirs) do
    reads
    |> Enum.group_by(& &1.app)
    |> Enum.sort()
    |> Enum.map(fn {app, group} -> merge!(app, group, app_dirs) end)
  end

  defp merge!(app, [%{vsn: vsn} | _rest] = group, app_dirs) do
    up = Enum.flat_map(group, &Appup.entries(&1.appup, :up))
    dn = Enum.flat_map(group, &Appup.entries(&1.appup, :down))
    paths = Enum.map(group, & &1.path)
    probes = probes(group, up ++ dn)

    refuse_collision!(app, :up, up, probes, paths)
    refuse_collision!(app, :down, dn, probes, paths)

    shipped = shipped!(app, Map.fetch!(app_dirs, app))

    %{
      app: app,
      vsn: vsn,
      bytes:
        encode!(
          app,
          {to_charlist(vsn), up ++ kept(shipped, :up), dn ++ kept(shipped, :down)},
          paths
        ),
      sources: paths,
      staged: staged(shipped),
      notes: shipped_notes(app, shipped, %{up: up, down: dn}, probes)
    }
  end

  # **Two entries that can both be selected for one version is where the merge
  # order decides the answer, and the order is a filename sort.** Equality is not
  # the question, and asking it that way was a false pass found in review:
  # `release_handler` selects with `appup_search_for_version/2`, which matches a
  # **binary** key as a regular expression, so a broad regex in an earlier-sorting
  # source and a literal in a later one both answer for the same version without
  # being equal terms.
  #
  # So it is asked with the function that selects, at the versions the sources
  # themselves name: the from-version in each file name, and every entry key that
  # is a concrete version rather than a pattern. That is decidable, where "can
  # these two regular expressions match one string" is not - and it covers every
  # shape that has a version anybody wrote down behind it: literal against
  # literal, literal against regex, and two regexes overlapping at a version one
  # of the files is named for. Two regexes overlapping *only* at a version no
  # source names is what is left, and it stays stated rather than modelled.
  defp refuse_collision!(app, direction, entries, probes, paths) do
    case Enum.find(probes, &(selectable(entries, &1) > 1)) do
      nil ->
        :ok

      probe ->
        Mix.raise(
          "#{Enum.map_join(paths, " and ", &shorten/1)} give #{app} two #{word(direction)} " <>
            "entries that can both be selected for #{probe}. appup_search_for_version/2 takes " <>
            "the first entry that matches - and a binary key is a regular expression, so this " <>
            "is not only two identical keys - which makes the order the file names sort in " <>
            "decide which instructions run. That is not something to decide an upgrade with. " <>
            "Keep one."
        )
    end
  end

  # Asked one entry at a time, because the function answers with the first match
  # rather than with a count, and one entry is the smallest thing it can be asked
  # about.
  defp selectable(entries, probe) do
    Enum.count(entries, &match?({:ok, _script}, Appup.script([&1], probe)))
  end

  defp probes(group, entries) do
    Enum.uniq(
      Enum.map(group, & &1.from) ++
        for({vsn, _script} <- entries, is_list(vsn), do: to_string(vsn))
    )
  end

  defp word(:up), do: "upgrade"
  defp word(:down), do: "downgrade"

  ## The appup the application shipped for itself

  # **What is placed is a merge with what the application already has, not a
  # replacement of it, and that was a review finding.** A dependency that ships
  # an appup covering its own 1.9 to 2.0 loses that entry the moment a project
  # supplies one for 1.0 to 2.0 - the file is written whole - and the transition
  # the dependency *did* support silently becomes a restart. Which is this tree's
  # own failure mode arriving through the feature built to remove it.
  #
  # It is read here rather than out of the assembled release, from the build
  # directory Mix copies the application's `ebin` from, so a refusal is still made
  # before `:assemble`. An appup that is there and cannot be read is refused: this
  # is about to write over it, and discarding something unreadable is no better
  # than discarding something readable.
  # The bytes are kept beside the term, and both are read here, because they are
  # what `write!/2` compares the assembled copy against - see `verify_staged!/2`.
  # Reading the bytes first and consulting the path afterwards is two reads of one
  # file, which is exactly the exposure that comparison closes: a file that
  # changed in between makes the assembled copy disagree with what is held here,
  # and that is a refusal.
  defp shipped!(app, app_dir) do
    file = Path.join([app_dir, "ebin", "#{app}.appup"])

    case File.read(file) do
      {:ok, bytes} -> {file, bytes, consulted!(app, file)}
      {:error, :enoent} -> nil
      {:error, reason} -> Mix.raise("#{shorten(file)} could not be read: #{format(reason)}")
    end
  end

  defp consulted!(app, file) do
    case Appup.read(file) do
      {:ok, appup} ->
        appup

      {:error, phrase} ->
        Mix.raise(
          "#{phrase}, and this build is about to place a project-supplied appup beside it. " <>
            "What it holds cannot be carried across, and writing the file would take whatever " <>
            "#{app} shipped away without a word."
        )
    end
  end

  defp kept(nil, _direction), do: []
  defp kept({_file, _bytes, appup}, direction), do: Appup.entries(appup, direction)

  defp staged(nil), do: nil
  defp staged({_file, bytes, _appup}), do: bytes

  # **The project's entries go first, so where both describe one transition the
  # project's is the one selected - deliberately, and said rather than left to be
  # noticed.** Supplying an appup for a transition a dependency already covers is
  # how a project corrects one that is wrong or incomplete, which is exactly what
  # `mix castle.appup` reports and the only remedy short of forking the
  # dependency. What must not happen is it being *silent*, so every shipped entry
  # this shadows is named.
  #
  # **Shadowing is asked at the probes rather than of the shipped keys, and asking
  # it the other way round was a hole found in review.** Iterating the shipped
  # entries and keeping only the ones whose key is a concrete version skipped a
  # shipped *regular expression* - so a project source named for 0.1.0 placed in
  # front of a shipped `0\.1\..*` overrode it in silence, which is a concrete
  # collision at a version a source names rather than the undecidable case. Asked
  # at a probe, with the function that selects, both sides are covered whichever
  # of them is the pattern.
  defp shipped_notes(_app, nil, _project, _probes), do: []

  defp shipped_notes(app, {file, _bytes, appup}, project, probes) do
    counts =
      for direction <- [:up, :down] do
        {direction, Appup.entries(appup, direction)}
      end

    total = Enum.map_join(counts, " and ", fn {d, e} -> "#{length(e)} #{word(d)}" end)

    [
      "#{app} ships an appup of its own at #{shorten(file)}: its #{total} entries are kept, " <>
        "after the ones above."
      | overridden(counts, project, probes)
    ]
  end

  defp overridden(counts, project, probes) do
    for {direction, entries} <- counts,
        probe <- probes,
        selectable(project[direction], probe) > 0,
        selectable(entries, probe) > 0 do
      "the #{word(direction)} entry it holds for #{probe} is overridden by the one above, " <>
        "which is what supplying an appup for a transition means."
    end
  end

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
      verify_staged!(file, placement.staged)
      announce(placement, file)
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

  # **What is at the destination has to be the copy Mix made of the file this
  # merged, and anything else is a refusal. Raised in review.** `:assemble` copies
  # the applications and *then* copies the release's overlays over the tree, so a
  # `rel/overlays/lib/<app>-<vsn>/ebin/<app>.appup` - or any step Mix runs in
  # between - can install upgrade instructions of its own here. Writing over them
  # is how a supported transition disappears without a word, which is the failure
  # this whole feature is built to remove, and reconciling them instead would mean
  # doing the collision refusals after `:assemble` and modelling where an overlay
  # came from.
  #
  # So the bytes read in `pre_assemble/1` are compared against what is there:
  # equal, and Mix copied it; anything else, and something put a second answer in
  # the release. It also closes the two-reads window in `shipped!/2`, since a file
  # that changed between its read and its consult cannot match here either.
  defp verify_staged!(file, staged) do
    case {File.read(file), staged} do
      {{:ok, bytes}, bytes} ->
        :ok

      {{:error, :enoent}, nil} ->
        :ok

      {{:ok, _other}, nil} ->
        Mix.raise(interposed(file, "appeared during :assemble"))

      {{:ok, _other}, _staged} ->
        Mix.raise(interposed(file, "changed during :assemble"))

      {{:error, :enoent}, _staged} ->
        Mix.raise(interposed(file, "was taken away during :assemble"))

      {{:error, reason}, _staged} ->
        Mix.raise("#{shorten(file)} could not be read: #{format(reason)}")
    end
  end

  defp interposed(file, became) do
    "#{shorten(file)} #{became}, so it is not the copy Mix made of the build's own appup and " <>
      "something else in this build put upgrade instructions there - a release overlay is " <>
      "copied over lib/ after the applications are, and is how that happens. That is two " <>
      "answers to what this application's upgrade instructions are, and writing over one of " <>
      "them is how the other disappears without a word. Take it out, or move its entries " <>
      "into #{shorten(dir())}."
  end

  defp announce(placement, file) do
    Mix.shell().info(
      "* placing #{Enum.map_join(placement.sources, ", ", &shorten/1)} into #{shorten(file)}"
    )

    Enum.each(placement.notes, &Mix.shell().info("  " <> &1))
  end

  defp shorten(path), do: Path.relative_to_cwd(path)

  defp format(reason), do: :file.format_error(reason)
end
