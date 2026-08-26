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

  ## Where it writes

  The file named by the `:appup` project key, resolved against the project it
  belongs to - the current project, or an umbrella child. Where the key is unset,
  `appup.exs` beside `mix.exs`, and the report says to add the key and the
  `:appup` compiler, without which nothing compiles the file.

  An application `--app` names that is neither the current project nor an
  umbrella child - a dependency - has no source here to write. Its entry is
  printed instead.

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

    case source(app) do
      {:ok, path, configured?} ->
        write_plan(heading, path, configured?, drafted, from.vsn, to.vsn)

      :unknown ->
        unknown_project(app, heading, drafted)
    end
  end

  defp unknown_project(app, heading, drafted) do
    refusal(
      heading,
      "#{app} is neither this project nor one of its umbrella children, so its appup source " <>
        "is not this project's to write. The entry is below; it belongs in that " <>
        "application's own appup.",
      printed(drafted, @directions)
    )
  end

  # Which of the three writing cases this is. The appup source is read *before*
  # anything is decided about it, because "is this file one that can be rewritten"
  # is the question that gates the other two.
  defp write_plan(heading, path, configured?, drafted, from_vsn, to_vsn) do
    case Source.read(path) do
      :absent ->
        %{
          heading: heading,
          action: {:create, path, to_vsn, drafted},
          notes: configure(path, configured?)
        }

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

  defp configure(_path, true), do: []

  defp configure(path, false) do
    [
      "This project has no :appup key, so nothing compiles that file yet. Add " <>
        "`appup: #{inspect(Path.basename(path))}` to project/0 and `:appup` to :compilers."
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
  # `:appup` key is in its own `mix.exs` and there is no other way to ask. A
  # dependency is neither, and has no source here to write: its entry is printed.
  defp source(app) do
    cond do
      app == Mix.Project.config()[:app] ->
        appup_path()

      path = umbrella_path(app) ->
        Mix.Project.in_project(app, path, fn _module -> appup_path() end)

      true ->
        :unknown
    end
  end

  defp umbrella_path(app) do
    case Mix.Project.apps_paths() do
      nil -> nil
      paths -> paths[app]
    end
  end

  # `appup.exs` is the default name only for a project that has no `:appup` key
  # at all, and the third element says which of the two this was - because a
  # project with no key has nothing compiling the file that is about to be
  # written, and that is worth a line in the report rather than a surprise at the
  # next build.
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
        {:ok, Path.expand("appup.exs", dir), false}

      configured ->
        {:ok, Path.expand(configured, dir), true}
    end
  end

  ## Doing it

  # Rendering and writing are two failures, not one, and both end the same way:
  # a refusal naming the file, with the entry printed where one could still be
  # drafted. Nothing half-written reaches the source - see
  # `Forecastle.Appup.Source.create/2` and `replace/2` for what each does about
  # that.
  defp apply_plan(%{action: {:create, path, to_vsn, drafted}} = plan) do
    with {:ok, text} <- Source.render(to_vsn, drafted.up, drafted.down),
         :ok <- Source.create(path, text) do
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
