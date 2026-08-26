defmodule Mix.Tasks.Castle.Appup.Gen do
  @moduledoc """
  Draft the appup entry for a transition, and write or merge it into the appup
  source.

  This task is provided by `Forecastle`, Castle's build-time half, and named for
  `Castle` because that is the package a project depends on.

      mix castle.appup.gen --from <spec> [--to <spec>] [--app <app>]...

  The arguments are `mix castle.appup`'s, and the diff is the same diff:
  `Forecastle.Build` reads both builds for both tasks, so the check and the
  generator cannot disagree about which modules moved. What is added here is
  writing.

  `.gen.` is the established Elixir idiom for *this writes source you will review
  and commit*, which is exactly the intent. `design/upgrade-tooling.md` §D2 in
  ausimian/castle is why: an appup synthesised during assembly would ship
  upgrade instructions nobody read, derived from a comparison nobody saw. So
  generation is an explicit act, its output is a source file, and the `:appup`
  compiler is unchanged.

  ## What it drafts, and what it refuses to decide

  `Forecastle.Appup.Draft` holds the decision table - behaviours out of the
  beam's `Attr` chunk, and nothing else - and the comments that go beside each
  instruction. Those comments are not decoration. The `Extra` term in an
  `{:advanced, Extra}` is always `[]` and nothing can derive it; a
  `{:update, M, :supervisor}` reconciles child *specs* and does not upgrade the
  children; `update` only reaches processes found through the supervision tree,
  so an unsupervised process keeps its old code silently while the appup looks as
  though it covered it; and the ordering is stable rather than correct. A draft
  that hides its uncertainty is worse than no draft.

  Three more are said where they apply, and each is a fact about one module
  rather than a property of the table: an instruction naming a module the `.app`
  does not list cannot resolve object code; an advanced update on a module that
  exports no `code_change` fails the install with `undef`; and a module whose
  behaviour *role* changed between the two builds is drafted for what it becomes
  while the process running now was started by the old code. All three still
  draft the instruction - leaving one out silently is the failure this tooling
  exists to catch, arriving from the other direction.

  ## The three writing cases

    * **no appup yet** - the file is written.
    * **an existing appup whose AST is a pure literal** - the entry is merged in
      and the diff printed.
    * **an existing appup that computes** - **refused**, with the entry printed
      to merge by hand.

  The third is what makes the other two safe. An appup source is arbitrary
  evaluated Elixir, and flattening one into a static term would silently discard
  the logic that decides what it produces. `Forecastle.Appup.Source` is where
  that is decided, and it is decided on the parsed AST rather than guessed at
  from the text.

  An entry is added to a direction only where
  `systools_relup:appup_search_for_version/2` - the function `:systools` and
  `release_handler` select an entry with, which `mix castle.appup` and
  `mix castle.relup`'s `auto` also call - finds none. An entry that is already
  there is never rewritten: once a transition has instructions, they are the
  author's.

  ## What it never does silently

  **Every way this run can end without writing an instruction is either a
  refusal or a named no-op.** That is a deliberate answer to the failure this
  tree has produced repeatedly - something that reports success having done
  nothing - and it is what the exit status is derived from.

  Refused, by name, and non-zero:

    * an application in one build and not the other. `:systools` covers that with
      `add_application` / `remove_application` and no appup entry describes it,
      so there is nothing to draft. `mix castle.appup` reports the same state as
      a *note* and exits zero, and the difference is deliberate: a check has an
      answer for it and a generator that was asked to write something has not.
    * an application whose version did not move. `:systools` consults no appup
      for one, so an entry keyed by the version it already has is not a
      transition.
    * a build of the application with no beams in it. Every module of the other
      side would read as added or removed, and the entry drafted from that would
      be an instruction to load or delete the whole application. Refused rather
      than written, and the hand-written empty entry is printed instead for the
      rare application that genuinely has no code.
    * an appup that computes, one that is not an appup, and one whose merged form
      does not read back as the entry that was drafted.
    * a source that could not be written: one that appeared after being read as
      absent, one that changed after being read, or a write that failed. Nothing
      is left half-written - see `Forecastle.Appup.Source.create/2` and
      `replace/2` - and the entry is printed so the refusal leaves something to
      act on.

  Named, and zero:

    * **nothing moved, and the version did.** The entry is written with an empty
      script, and the comment beside it says the script is empty and why: an
      appup with no entry for a from-version is refused by `make_relup/4`
      outright, so an empty script is the instruction that nothing has to be
      loaded rather than an omission.
    * **the appup already has an entry for this from-version** in both
      directions. Nothing is added and the run says so - and it says, too, that
      an entry existing is not the same as it covering everything that moved,
      because nothing here has checked that and `mix castle.appup` is what does.
    * **another `rel/appups` source for the same dependency already answers for
      it** in both directions. A dependency's appups are one file per transition
      and the release merges every file naming the application into one appup, so
      coverage is a question about the *set*: a sibling keyed on a regular
      expression can already select this from-version. Covered in one direction
      only, this is a **refusal** rather than a no-op, because the file it would
      write is one the next build would refuse.

  ## Where it writes

  The file named by the `:appup` project key, resolved against the project it
  belongs to - the current project, or an umbrella child. Where the key is unset,
  `appup.exs` beside `mix.exs`, and the report says to add the key and the
  `:appup` compiler, without which nothing compiles the file.

  An application `--app` names that is neither the current project nor an
  umbrella child - a dependency - is written to `rel/appups/<app>-<from>-<to>.exs`
  instead, which `Forecastle.Appup.Dep` reads while assembling a release and
  places at `lib/<app>-<vsn>/ebin/<app>.appup`. Nothing is ever written into
  `deps/`: that is the shared checkout, and an appup there would be one project's
  upgrade instructions in every build that uses it.

  **It writes there rather than printing, and that was the open question.** The
  answer is in what the refusal it replaces actually said: a dependency's appup
  was printed because there was "no source here to write", not because writing one
  would have been wrong. `rel/appups` is that source, so the premise is gone -
  and once a destination exists, printing is the *inconsistent* branch. D2 holds
  either way: what comes out is source a person reviews and commits, nothing
  generates an appup during assembly, and what assembly does is place a file
  somebody wrote after checking that its name still describes the transition being
  built. That check is a guarantee the project's own `appup.exs` has not got: a
  drifted tag there is a `bad_vsn` note, while a dependency file that no longer
  names this transition fails the build.

  **A `:appup` key naming a file that does not exist is a compilation error, and
  it is in the way of the default `--to`.** `Mix.Tasks.Compile.Appup` refuses a
  configured-but-missing source deliberately, and the default `--to` compiles. So
  the first appup for a project that has already set the key needs an explicit
  `--to`, which compiles nothing; leaving the key unset until there is a file to
  name is the other way round it.

  ## Review it

  The output is a draft. Run `mix castle.appup --from <spec>` against it - which
  is the gate, and the artefact this task falls out of - and read the comments
  before committing.
  """
  @shortdoc "Draft and merge the appup entry for a transition"

  use Mix.Task

  alias Forecastle.Appup
  alias Forecastle.Appup.Dep
  alias Forecastle.Appup.Draft
  alias Forecastle.Appup.Source
  alias Forecastle.Build

  # All `:keep`, including the switches that may appear only once, for the reason
  # `mix castle.appup` gives: `:string` silently keeps the last occurrence, so a
  # repeated switch would quietly answer a question other than the one asked.
  @options [from: :keep, to: :keep, app: :keep]

  @directions [:up, :down]

  @impl Mix.Task
  def run(command_line_args) do
    Appup.ensure_systools!()

    args = parse!(command_line_args)
    spec = spec!(args)

    # The applications and the target are settled before `--from` is resolved,
    # because resolving a baseline can mean unpacking an artefact or building a
    # commit, and spending minutes on that only to find `--app` names nothing is
    # the wrong order to fail in. `mix castle.appup` orders itself the same way.
    apps = apps!(args)
    to = target!(args)
    from = Build.resolve!(spec, :compile)

    # Planned for every application before anything is written, so that a
    # refusal - a library directory that cannot be read, an application in
    # neither build - leaves no file behind. Writing is then one pass, and the
    # report is derived from what it did rather than from a second guess at it.
    apps
    |> Enum.map(&plan(&1, from, to))
    |> Enum.map(&apply_plan/1)
    |> report!(spec)
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

  defp spec!(cmdline_args) do
    case Keyword.get_values(cmdline_args, :from) do
      [spec] ->
        spec

      [] ->
        Mix.raise(
          "--from is required: an appup is instructions for a transition, and there is " <>
            "nothing to draft without the version being upgraded from"
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
  # left in, it would be drafted twice and the second write would merge into the
  # file the first one wrote.
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
          "this project declares no application, so there is nothing to draft by default. " <>
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

  ## Planning one application

  defp plan(app, from, to) do
    case {Build.ebin(from, app), Build.ebin(to, app)} do
      {nil, nil} ->
        Mix.raise(
          "#{app} is in neither #{from.describe} nor #{to.describe}. Nothing was compared."
        )

      {nil, _to_ebin} ->
        absent(app, to.describe, from.describe, "add_application")

      {_from_ebin, nil} ->
        absent(app, from.describe, to.describe, "remove_application")

      {from_ebin, to_ebin} ->
        draft(app, Build.side!(from_ebin, app), Build.side!(to_ebin, app))
    end
  end

  defp absent(app, present, missing, instruction) do
    refusal(
      to_string(app),
      "#{app} is in #{present} and not in #{missing}, which is not a transition an appup " <>
        "describes - :systools covers it with #{instruction}, and no entry keyed by a " <>
        "from-version would be consulted for it. There is nothing to draft."
    )
  end

  defp draft(app, from, to) do
    heading = "#{app} #{from.vsn} -> #{to.vsn}"

    cond do
      from.modules == %{} or to.modules == %{} ->
        refusal(heading, empty_build(app, from, to))

      from.vsn == to.vsn ->
        refusal(heading, unmoved(app, from.vsn))

      true ->
        entries(app, heading, from, to)
    end
  end

  # A build with no beams makes every module of the other side read as added or
  # removed, so what would be drafted from it is an instruction to load or delete
  # the whole application - which is the same silent-pass shape `Forecastle.Build`
  # refuses a missing library directory for, arriving one level further in and
  # with a file written at the end of it.
  #
  # An application that genuinely has no compiled modules is rare and real, and
  # the entry it needs is the empty one - printed here, because a refusal that
  # leaves somebody stuck is worse than the case it was guarding.
  defp empty_build(app, from, to) do
    empty = if from.modules == %{}, do: from, else: to

    "#{Path.relative_to_cwd(empty.ebin)} holds no beam files, so every module of the other " <>
      "build would read as added or removed and the entry drafted from that would load or " <>
      "delete the whole of #{app}. If this application really has no compiled modules, the " <>
      ~s|entry it needs is {~c"#{from.vsn}", []} in both directions.|
  end

  defp unmoved(app, vsn) do
    "#{app} is #{vsn} in both builds. :systools compares application versions and consults " <>
      "no appup for one that did not change, so an entry keyed by #{vsn} would never be " <>
      "selected. Bump the version; there is no instruction that substitutes for it."
  end

  # Each direction on its own, and each with its own idea of which build is the
  # old one: an upgrade goes from the baseline to the target, a downgrade goes
  # back. The from-version is the baseline's either way, because an appup's `dn`
  # list is keyed by the version being downgraded *to*.
  defp entries(app, heading, from, to) do
    drafted = %{
      up: Draft.entry(from.vsn, from, to),
      down: Draft.entry(from.vsn, to, from)
    }

    {path, kind, notes} = source(app, from.vsn, to.vsn)

    case siblings(kind, path, from.vsn) do
      [] -> write_plan(heading, path, kind, notes, drafted, from.vsn, to.vsn)
      covered -> sibling_plan(heading, covered, drafted, from.vsn)
    end
  end

  ## The sources beside the one this would write

  # **A dependency's appups are one file per transition and the release merges
  # every file naming the application into one appup, so "is this transition
  # already covered" is a question about the *set* rather than about this file.
  # Raised in review.** A sibling keyed on a regular expression that already
  # selects this from-version makes the entry this would write a second one that
  # `Forecastle.Appup.Dep` refuses - deterministically, from the next build
  # onwards. The generator would have reported success and left a tree that no
  # longer assembles, which is exactly the disagreement between what writes an
  # appup and what reads it that this pair of tasks exists not to have.
  #
  # Asked with `appup_search_for_version/2` over each sibling's own term, which is
  # the function the assembly step asks with, so the two cannot disagree about
  # coverage. There is no such set for an owned application: the `:appup` key
  # names one file, and `merge_plan/4` already asks this of it.
  defp siblings(kind, path, from_vsn)

  defp siblings(:project, _path, _from_vsn), do: []

  defp siblings({:dependency, app, to_vsn}, path, from_vsn) do
    app
    |> sibling_files(to_vsn, path)
    |> Enum.flat_map(&covered_directions!(&1, from_vsn))
  end

  # Named the way `Forecastle.Appup.Dep` reads a name - the application at the
  # front, the version this release carries at the back - and anchored at both
  # ends for its reason: a version may itself contain a `-`, so a split is a
  # guess. A directory that cannot be listed is not this task's to report, since
  # it is the assembly step that has to read it.
  defp sibling_files(app, to_vsn, path) do
    dir = Dep.dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(&sibling?(&1, app, to_vsn))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reject(&(&1 == path))

      {:error, _reason} ->
        []
    end
  end

  defp sibling?(entry, app, to_vsn) do
    base = Path.basename(entry, ".exs")

    Path.extname(entry) == ".exs" and String.starts_with?(base, "#{app}-") and
      String.ends_with?(base, "-#{to_vsn}")
  end

  # **A sibling that computes is a refusal rather than an omission.** This task
  # deliberately does not evaluate an appup source it has not read as a literal -
  # `Forecastle.Appup.Source` is built on that - so what such a file covers is not
  # knowable from here. Assembly *does* evaluate it, and is where the collision
  # would land, so guessing that it covers nothing is the one answer that could
  # leave a tree that no longer builds.
  defp covered_directions!(file, from_vsn) do
    case Source.read(file) do
      {:literal, literal} ->
        for direction <- @directions,
            covered?(literal.term, direction, from_vsn),
            do: {direction, Path.relative_to_cwd(file)}

      :absent ->
        []

      {tag, phrase} when tag in [:computed, :malformed] ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} #{phrase}, and it names the same application and " <>
            "version as the file this would write. Whether it already answers for " <>
            "#{from_vsn} cannot be read from here, and if it does then the release refuses " <>
            "both of them. Nothing was written."
        )
    end
  end

  defp sibling_plan(heading, covered, drafted, from_vsn) do
    files = covered |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.join(", ")

    case covered |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() do
      [:down, :up] ->
        %{
          heading: heading,
          action: :covered,
          notes: [
            "#{files} already answers for #{from_vsn} in both directions, and the release " <>
              "merges every source naming this application into one appup. Nothing was " <>
              "added: a second entry there would be one appup_search_for_version/2 never " <>
              "selects, and the build refuses rather than choosing between them.",
            "An entry existing is not the same as it covering everything that moved, and " <>
              "nothing here has checked that it does. mix castle.appup is what answers it."
          ]
        }

      [direction] ->
        refusal(
          heading,
          "#{files} already answers for #{from_vsn} in the #{word(direction)} direction, and " <>
            "the release merges every source naming this application into one appup - so " <>
            "this file would " <>
            "give that direction two entries that can both be selected for #{from_vsn}, and " <>
            "the next build refuses it. Nothing was written; the entry to merge into that " <>
            "file by hand is below.",
          printed(drafted, @directions)
        )
    end
  end

  # Which of the three writing cases this is. The appup source is read *before*
  # anything is decided about it, because "is this file one that can be rewritten"
  # is the question that gates the other two.
  defp write_plan(heading, path, kind, notes, drafted, from_vsn, to_vsn) do
    case Source.read(path) do
      :absent ->
        %{heading: heading, action: {:create, path, to_vsn, kind, drafted}, notes: notes}

      {:literal, literal} ->
        merge_plan(heading, literal, drafted, from_vsn)

      {tag, phrase} when tag in [:computed, :malformed] ->
        refusal(
          heading,
          "#{Path.relative_to_cwd(path)} #{phrase}. Nothing was written; the entry to merge " <>
            "by hand is below.",
          printed(drafted, @directions)
        )
    end
  end

  # An entry is added only to a direction that has none, and "has none" is
  # `systools_relup:appup_search_for_version/2`'s answer rather than a comparison
  # of version strings - so this and `mix castle.appup` cannot disagree about
  # whether a transition is already covered, and a from-version written as a
  # regular expression is matched the way `release_handler` matches it.
  defp merge_plan(heading, literal, drafted, from_vsn) do
    case Enum.reject(@directions, &covered?(literal.term, &1, from_vsn)) do
      [] ->
        %{
          heading: heading,
          action: :covered,
          notes: [
            "#{Path.relative_to_cwd(literal.path)} already has an upgrade and a downgrade " <>
              "entry for #{from_vsn}. Nothing was added: once a transition has instructions " <>
              "they are the author's, and this never rewrites one.",
            "An entry existing is not the same as it covering everything that moved, and " <>
              "nothing here has checked that it does. mix castle.appup is what answers it."
          ]
        }

      directions ->
        %{
          heading: heading,
          action: {:merge, literal, Enum.map(directions, &{&1, drafted[&1]})},
          notes: partial(directions, literal.path, from_vsn)
        }
    end
  end

  defp covered?(term, direction, from_vsn) do
    match?({:ok, _script}, Appup.script(Appup.entries(term, direction), from_vsn))
  end

  defp partial([_up, _down], _path, _from_vsn), do: []

  defp partial([direction], path, from_vsn) do
    [
      "#{Path.relative_to_cwd(path)} already had #{other(direction)} entry for #{from_vsn}, " <>
        "which is left as it is. Only #{article(direction)} entry was added."
    ]
  end

  defp other(:up), do: "a downgrade"
  defp other(:down), do: "an upgrade"

  defp article(:up), do: "an upgrade"
  defp article(:down), do: "a downgrade"

  defp word(:up), do: "upgrade"
  defp word(:down), do: "downgrade"

  defp unconfigured(path) do
    "This project has no :appup key, so nothing compiles that file yet. Add " <>
      "`appup: #{inspect(Path.basename(path))}` to project/0 and `:appup` to :compilers."
  end

  # What a reader of a *dependency's* file needs and cannot get from the term:
  # nothing compiles it, and what puts it into a release is an assembly step that
  # checks the name against the version the release carries.
  defp dependency_notes(app, to_vsn) do
    [
      "#{app} is not this project's to compile an appup for, and nothing writes one into " <>
        "deps/ - that would leak this project's upgrade instructions into every build " <>
        "sharing that checkout.",
      "Forecastle places that file at lib/#{app}-#{to_vsn}/ebin/#{app}.appup while " <>
        "assembling a release, and refuses it once #{app} is no longer #{to_vsn} there. The " <>
        "name is what says which transition it is for, so rename it rather than editing it."
    ]
  end

  defp refusal(heading, phrase, lines \\ []) do
    %{heading: heading, action: {:refused, phrase, lines}, notes: []}
  end

  ## Where the appup source is

  # The `:appup` key is a path relative to the *project file* rather than to the
  # working directory, which is what `Mix.Tasks.Compile.Appup` resolves it
  # against - so a run from anywhere writes the file that compiler will read.
  #
  # An umbrella child is reached through `Mix.Project.in_project/3`, because its
  # `:appup` key is in its own `mix.exs` and there is no other way to ask.
  #
  # **A dependency is neither, and it is written to all the same** - into
  # `rel/appups/<app>-<from>-<to>.exs`, which `Forecastle.Appup.Dep` owns. That is
  # a change of answer rather than a change of policy, and the old answer said so
  # itself: it refused because a dependency "has no source here to write", not
  # because writing one would be wrong. forecastle#30 gave it one, so the premise
  # is gone.
  #
  # Consistency argues the same way round once there is a destination. For an
  # owned application this task writes, and printing for a dependency would leave
  # the merge case dead and a second, weaker workflow - copy this out of your
  # terminal - beside the good one. D2 is satisfied identically either way: the
  # output is source a person reviews and commits, and nothing generates an appup
  # during assembly. What assembly does with it is place a file somebody wrote,
  # after checking that its name still describes the transition being built.
  #
  # The safety story is in fact stronger here than for `appup.exs`. A dependency
  # file is named for exactly the transition it was drafted for, so the moment the
  # dependency moves on the build refuses it by name; an `appup.exs` whose tag has
  # drifted is only a `bad_vsn` note.
  defp source(app, from_vsn, to_vsn) do
    cond do
      app == Mix.Project.config()[:app] ->
        appup_path()

      path = umbrella_path(app) ->
        Mix.Project.in_project(app, path, fn _module -> appup_path() end)

      true ->
        dependency_path(app, from_vsn, to_vsn)
    end
  end

  # The from-version and the to-version are both in the name, because that is
  # what `Forecastle.Appup.Dep` reads it as, and it is the only thing saying which
  # transition the file is for: nothing about a dependency's appup is keyed to a
  # `:appup` project key that could name it.
  defp dependency_path(app, from_vsn, to_vsn) do
    dir = Dep.dir()
    path = Path.join(dir, "#{app}-#{from_vsn}-#{to_vsn}.exs")

    confined!(path, dir, from_vsn, to_vsn)

    {path, {:dependency, app, to_vsn}, dependency_notes(app, to_vsn)}
  end

  # **The name is built out of two version strings, so it has to be checked to be
  # a name. Raised in review.** `Forecastle.Build` refuses a version that is not
  # valid UTF-8 or that carries control characters, because those reach a report
  # and a terminal - it says nothing about path separators, which reach nothing
  # anywhere else. Here they reach the filesystem: a `.app` naming its version
  # `2.0/x/../../../../config/runtime` makes this create and write
  # `config/runtime.exs`, which is a file outside the appup directory altogether
  # and one the project may already have.
  #
  # Checked by expansion rather than by looking for separators, because that is
  # the same question the filesystem will answer and a `..` is not a separator.
  # `bin/castle` refuses a path separator in a version for the same reason, one
  # layer out: a version that names a directory is not a version.
  defp confined!(path, dir, from_vsn, to_vsn) do
    if Path.dirname(Path.expand(path)) != Path.expand(dir) do
      Mix.raise(
        "#{from_vsn} and #{to_vsn} do not make a file name in #{Path.relative_to_cwd(dir)}: " <>
          "#{Path.relative_to_cwd(Path.expand(path))} is somewhere else. An appup for a " <>
          "dependency is named for its transition, so a version carrying a path separator or " <>
          "a .. would put the source outside the directory the build reads - or over a file " <>
          "that is already there. Nothing was written."
      )
    end
  end

  defp umbrella_path(app) do
    case Mix.Project.apps_paths() do
      nil -> nil
      paths -> paths[app]
    end
  end

  # `appup.exs` is the default name only for a project that has no `:appup` key
  # at all, and the note that comes back with it says so - because a project with
  # no key has nothing compiling the file that is about to be written, and that is
  # worth a line in the report rather than a surprise at the next build.
  # **Whether the key is set is asked the way the compiler asks it, which is
  # truthiness and not `nil`.** `Mix.Tasks.Compile.Appup.source/0` is
  # `if src = Mix.Project.config()[:appup]`, so `appup: false` compiles nothing -
  # and reading it as configured here wrote a file and left off the note saying
  # nothing would compile it, which is a successful run producing a source no
  # build reads. Raised in review. The compiler's own reading is the one that
  # decides, so this matches it rather than approximating it.
  defp appup_path do
    dir = Path.dirname(Mix.Project.project_file())

    case Mix.Project.config()[:appup] do
      configured when configured in [nil, false] ->
        {Path.expand("appup.exs", dir), :project, [unconfigured("appup.exs")]}

      configured ->
        {Path.expand(configured, dir), :project, []}
    end
  end

  ## Doing it

  # Rendering and writing are two failures, not one, and both end the same way:
  # a refusal naming the file, with the entry printed where one could still be
  # drafted. Nothing half-written reaches the source - see
  # `Forecastle.Appup.Source.create/2` and `replace/2` for what each does about
  # that.
  defp apply_plan(%{action: {:create, path, to_vsn, kind, drafted}} = plan) do
    with {:ok, text} <- Source.render(to_vsn, drafted.up, drafted.down, kind),
         :ok <- created(path, text) do
      %{plan | action: {:wrote, ["wrote #{Path.relative_to_cwd(path)}"]}}
    else
      # The entries go out here for the same reason they do on a computed appup:
      # the draft exists, and a refusal that keeps it is a refusal that leaves
      # somebody with nothing to do but run the whole thing again.
      {:error, phrase} ->
        %{
          plan
          | action:
              {:refused, "#{Path.relative_to_cwd(path)} #{phrase}", printed(drafted, @directions)}
        }
    end
  end

  defp apply_plan(%{action: {:merge, literal, additions}} = plan) do
    with {:ok, text} <- Source.merge(literal, additions),
         :ok <- Source.replace(literal, text) do
      %{
        plan
        | action:
            {:wrote,
             [
               "merged into #{Path.relative_to_cwd(literal.path)}"
               | Source.diff(literal.source, text)
             ]}
      }
    else
      {:error, phrase} ->
        %{
          plan
          | action:
              {:refused, "#{Path.relative_to_cwd(literal.path)} #{phrase}",
               printed(Map.new(additions), Enum.map(additions, &elem(&1, 0)))}
        }
    end
  end

  defp apply_plan(plan), do: plan

  # `rel/appups` is the ordinary case of a directory that is not there yet: a
  # project with no dependency appups has no reason to have one. Creating it is
  # not a weakening of `Source.create/2`'s exclusive create - that refusal is
  # about the file, and it still owns whether this run was the one that made it.
  defp created(path, text) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        Source.create(path, text)

      {:error, reason} ->
        {:error, "could not be created: nor could its directory (#{format(reason)})"}
    end
  end

  defp format(reason), do: :file.format_error(reason)

  defp printed(drafted, directions) do
    Enum.flat_map(directions, fn direction ->
      ["", "#{label(direction)}:" | String.split(Source.entry_text(drafted[direction]), "\n")]
    end)
  end

  defp label(:up), do: "the upgrade entry"
  defp label(:down), do: "the downgrade entry"

  ## The report

  # Printed in full whether or not anything was written, because "which
  # applications were considered" is half of what makes the answer trustworthy -
  # a run that considered nothing and a run that had nothing to do look identical
  # otherwise.
  defp report!(plans, spec) do
    Enum.each(plans, &announce/1)

    case Enum.filter(plans, &refused?/1) do
      [] -> Mix.shell().info(summary(plans, spec))
      refused -> Mix.raise(refusal_summary(refused, plans))
    end
  end

  defp announce(plan) do
    Mix.shell().info(plan.heading)

    Enum.each(lines(plan.action), &Mix.shell().info("  " <> &1))
    Enum.each(plan.notes, &Mix.shell().info("  " <> &1))
  end

  defp lines({:wrote, lines}), do: lines
  defp lines({:refused, phrase, lines}), do: [phrase | lines]
  defp lines(:covered), do: []

  defp refused?(%{action: {:refused, _phrase, _lines}}), do: true
  defp refused?(_plan), do: false

  defp wrote?(%{action: {:wrote, _lines}}), do: true
  defp wrote?(_plan), do: false

  # A run that wrote nothing is not told to go and read the comments it did not
  # write. The counts are the same either way, and the sentence after them is
  # what makes "0 appups written" read as the outcome it is rather than as a
  # success with an odd number in it.
  defp summary(plans, spec) do
    wrote = Enum.count(plans, &wrote?/1)
    alone = Enum.count(plans) - wrote

    "mix castle.appup.gen: #{wrote} #{plural(wrote, "appup")} written, " <>
      "#{alone} #{plural(alone, "application")} left alone. " <> advice(wrote, spec)
  end

  defp advice(0, spec) do
    "Nothing was written, and nothing here has checked what is already there: " <>
      "mix castle.appup --from #{spec} is what says whether it covers the transition."
  end

  defp advice(_wrote, spec) do
    "This is a draft: read the comments beside every instruction, then run " <>
      "mix castle.appup --from #{spec} to check it."
  end

  defp refusal_summary(refused, plans) do
    wrote = Enum.count(plans, &wrote?/1)

    "mix castle.appup.gen: #{length(refused)} " <>
      "#{plural(length(refused), "application")} refused, #{wrote} " <>
      "#{plural(wrote, "appup")} written. Nothing was written for a refused application, " <>
      "and where an entry could still be drafted it is printed above to be merged by hand."
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
