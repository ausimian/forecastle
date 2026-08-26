defmodule Forecastle.Build do
  @moduledoc """
  Reading one build of an application, and diffing two of them.

  A build here is a *library directory* - `_build/<env>/lib` for a compiled
  project, `lib` for an assembled release - together with the one application
  inside it a question is being asked about. `Forecastle.Baseline` turns a spec
  into the directory; this turns the directory into an answer about an
  application: which version it is, which modules it holds, what the `.app`
  resource says its inventory is, and which modules differ between two of them.

  **It exists once for the same reason `Forecastle.Appup` does.**
  `mix castle.appup` asks whether the committed appup covers the modules that
  moved and `mix castle.appup.gen` drafts the instructions for them, and the two
  must not be able to disagree about *which* modules moved: a generator that
  drafted from one diff while the check gated on another would produce output
  that fails the check, or worse, output that passes a check computed
  differently from the upgrade. So the reading and the diffing live here, once,
  and both tasks go through them.

  ## Absence is a meaningful answer, which makes a spurious absence the worst
  ## bug this can have

  An application in one build and not the other is a *note*, not a gap:
  `:systools` covers that with `add_application` / `remove_application` and
  neither needs an appup. So anything that makes an application merely *look*
  absent exits zero having compared nothing, and that is the one answer a gate
  must never give.

  Every refusal in this module is there because that failure was reached, and
  most of them were reached in this tree rather than imagined:

    * a library directory that cannot be read - a mistyped `--from`, where every
      application looked added and the run announced full coverage.
    * a library directory that *can* be read and is not one. `rel:/nope/x`
      resolves to `/lib`, which exists on Linux and does not on macOS, so the
      same nonsense spec refused on one platform and passed on the other.
    * an application directory with no `ebin`, which is an incomplete build
      rather than an application the transition removed.
    * an entry named for the application that is not a directory - a regular
      file, or a symlink with nothing at the end of it - where nothing else in
      the library directory is.

  Each is refused **by name** rather than read as an absence.

  ## Change detection is `:beam_lib.md5/1` *and* the persisted attributes

  A digest of the file bytes is useless here. `Mix.Release.strip_beam/2` rebuilds
  every beam in a release from `@additional_chunks ++
  :beam_lib.significant_chunks()`, so a release's copy of a module is a different
  sequence of bytes from the `_build` copy of identical code - measured on Elixir
  1.19.5 / OTP 28, where the chunk list goes from `AtU8 Code StrT ImpT ExpT FunT
  LitT LocT Attr CInf Dbgi Docs ExCk Line Type` to `Attr Line Type AtU8 Code StrT
  ImpT ExpT FunT LitT`. A byte digest reports every module in a release as
  changed; the md5 is stable across that stripping, which is what lets a baseline
  name a stripped release while the target is an unstripped `_build`.

  The md5 alone is not enough either, and `:beam_lib`'s own documentation says
  why: it covers the code, and "compilation date and other attributes are not
  included". Measured - two modules differing only in an explicit `@vsn`, or in
  an attribute registered with `Module.register_attribute(persist: true)`, have
  the same md5. Those attributes are loaded with the module and readable through
  `module_info/1`, and an explicit `@vsn` is exactly the sort of thing
  hot-upgrade code carries, so reporting such a module as unchanged was a false
  pass.

  Pairing them costs nothing in the other direction. `Attr` is one of the chunks
  stripping keeps, and the *decoded* attribute list is identical before and after
  it while the bytes are not. Documentation is not in `Attr`, so a `@moduledoc`
  change still moves nothing, and a module with no explicit `@vsn` is given the
  md5 itself as its `vsn`, so for ordinary code the pair moves exactly when the
  code does.

  The `Attr` chunk is also where `behaviours/2` reads from, which is the whole of
  what `mix castle.appup.gen` classifies on - so the fingerprint and the
  classification come out of one read of one file rather than two.
  """

  alias Forecastle.Baseline

  @typedoc """
  One side of a comparison, before an application has been picked out of it.

  `describe` is how the build is named in a refusal, `lib_dir` the library
  directory, and `entries` its listing - taken once, because every discovery
  below is a question about that list rather than a glob over the path. See
  `build/2`.
  """
  @type t :: %{describe: binary(), lib_dir: binary(), entries: [binary()]}

  @typedoc """
  One application in one build.

  `vsn` and `inventory` come from the `.app` resource, `modules` from the beams
  in `ebin`. The last two are different things and both are needed: the beams are
  what *moved*, and the inventory is what `:systools` can *resolve*.
  """
  @type side :: %{
          vsn: binary(),
          inventory: MapSet.t(module()),
          listed?: boolean(),
          modules: %{module() => fingerprint()},
          exports: %{module() => MapSet.t({atom(), arity()})},
          ebin: binary(),
          resource: binary()
        }

  @typedoc "What a module is compared on: its code, and the attributes the md5 does not cover."
  @type fingerprint :: {binary(), keyword()}

  @doc """
  Resolves a baseline spec and reads the library directory it names.

  `:compile` rather than `:release` is what both callers want: they read compiled
  modules and the appup beside them, and never a `.rel`. For `rel:` and `tar:`
  the level changes nothing - they name something already built - but for `ref:`
  it is the difference between a `mix compile` and a `mix release` of an old
  commit.
  """
  @spec resolve!(binary(), Baseline.level()) :: t()
  def resolve!(spec, level) do
    baseline = Baseline.resolve!(spec, level)

    build(spec, baseline.lib_dir)
  end

  @doc """
  The current build: `_build/<target_><env>/lib`, compiled first.

  **The compile happens here rather than in a task's `@requirements`, which is to
  say only when the current build is the thing being read.** A check run against
  beams that do not reflect the source is a wrong answer rather than a stale one,
  so a default target has to compile. But `@requirements` runs before `run/1` and
  therefore before anyone has looked at the arguments, which made a comparison of
  two artefacts - `--from tar:a --to tar:b`, both of them built elsewhere and
  neither of them this checkout - wait for a compile of a checkout it was not
  going to read, and *fail* if that checkout does not compile. A read-only
  comparison of two things that already exist should not need the working tree to
  be in a fit state.
  """
  @spec current!() :: t()
  def current! do
    Mix.Task.run("compile", [])

    build("the current build", Path.join(Mix.Project.build_path(), "lib"))
  end

  # **The library directory is established here, not assumed, and that is the
  # difference between a gate and a decoration.** Everything downstream reads an
  # application's *absence* from a build as a fact about the transition - one
  # application added, or one removed, neither of which needs an appup. A library
  # directory that is not there makes every application look absent, so a
  # mistyped `--from` reported "an application added between the two" and exited
  # **zero**, having compared nothing at all. Measured, before it was fixed.
  #
  # That is the one answer a check like this must never give, and it is worth
  # naming why it was so easy to reach: `Forecastle.Baseline` resolves a `rel:`
  # spec without touching the filesystem, deliberately, because the caller is
  # what reads the release a moment later and can say what it could not read.
  # `mix castle.relup` is that caller for a `.rel` file. Nothing here reads a
  # `.rel` at all, so nothing else was ever going to notice.
  #
  # Listing it once also settles the discovery below without a glob. Globbing
  # `<lib_dir>/{app,app-*}/ebin` has the same failure in a narrower form: a
  # project whose path contains a glob metacharacter - a directory named
  # `a{b}` is enough - matches nothing and every application looks absent again.
  # `:filelib.wildcard/1` has no way to quote the part of a pattern that is a
  # path, so the fix is not to build a pattern out of one.
  #
  # **Readable is not the same as being a library directory, and the difference
  # was a silent pass that only showed up on Linux.** `Forecastle.Baseline`
  # derives the library directory of a `rel:` spec by climbing three levels from
  # the `.rel` path, so a nonsense spec lands on a real path: `rel:/nope/x`
  # resolves to `/lib`. That does not exist on macOS, so `File.ls/1` failed and
  # the refusal below fired. On Linux `/lib` is a directory - the system one -
  # so the listing *succeeded*, held no application being checked, and every one
  # of them read as removed between the two builds. A removal is a legitimate hot
  # transition that `:systools` covers with `remove_application` and that needs no
  # appup, so the run reported "every module that moved is covered" and exited
  # **zero** having compared nothing. The same class as the mistyped baseline
  # above, reached through a path that happens to exist.
  #
  # So a library directory has to *look* like one, which is decided structurally
  # rather than by trusting the spec: at least one entry that is an application
  # directory with an `ebin` in it. A build's library directory always has one -
  # an empty one is not a build - and no directory that is merely nearby does.
  # The one check that cannot be fooled by a path being resolvable.
  @doc """
  Reads a library directory, refusing anything that is not one.

  `describe` is how the build is named in every refusal that follows, so it
  should read as a noun phrase: `"the current build"`, or the spec that named it.
  """
  @spec build(binary(), binary()) :: t()
  def build(describe, lib_dir) do
    case File.ls(lib_dir) do
      {:ok, entries} ->
        if Enum.any?(entries, &application_dir?(lib_dir, &1)) do
          %{describe: describe, lib_dir: lib_dir, entries: entries}
        else
          refuse_lib_dir!(
            describe,
            lib_dir,
            "nothing in it is an application directory with an ebin in it"
          )
        end

      {:error, reason} ->
        refuse_lib_dir!(describe, lib_dir, :file.format_error(reason))
    end
  end

  defp application_dir?(lib_dir, name), do: File.dir?(Path.join([lib_dir, name, "ebin"]))

  # One phrase for both, because they are one bug with two symptoms and which of
  # them a given machine shows depends on whether the resolved path happens to
  # exist there.
  defp refuse_lib_dir!(describe, lib_dir, because) do
    Mix.raise(
      "#{describe}: #{Path.relative_to_cwd(lib_dir)} is not a library directory of a build - " <>
        "#{because}. Every application would look absent from it, and an absent application " <>
        "reads as one this transition adds or removes, which needs no appup and passes. So " <>
        "this refuses rather than reporting one."
    )
  end

  @doc """
  The `ebin` of one application in one build, or `nil` if it is not in it.

  `<app>` for a Mix build and `<app>-<vsn>` for a release, which is the only
  thing `Forecastle.Baseline` promises about the layout. `nil` means the
  application really is not in this build - which is a claim worth making only
  because `build/2` established that the library directory itself is there, and
  only because nothing in it claimed to be this application. See `app_dirs/2`
  for the second half of that.
  """
  @spec ebin(t(), atom()) :: binary() | nil
  def ebin(build, app) do
    case app_dirs(build, app) do
      {[], []} ->
        nil

      {[], others} ->
        not_directories!(others, build, app)

      {dirs, _others} ->
        which!(dirs, build, app)
    end
  end

  # **The name says which directories to look at; the `.app` resource says which
  # of them is this application.** `<dir>/ebin/<app>.app` is named for the
  # application rather than for the directory, so it is the only exact answer -
  # the prefix is not one, because a version may itself contain a hyphen
  # (`sample-1.0.0-rc.1`) and so may an application name. Two things fall out of
  # asking it rather than trusting the name:
  #
  #   * `foo-1.0.0` beside `foo-bar-1.0.0`, checking `foo`, is no longer
  #     ambiguous. Only the first holds a `foo.app`.
  #   * a build holding *only* `foo-bar-1.0.0`, checking `foo`, is `foo` being
  #     **absent** rather than a broken build. Reading it as a match meant
  #     refusing over a missing `foo.app` in somebody else's directory, which
  #     names the wrong problem.
  #
  # The incomplete-build refusal survives that, and it has to - it is what stops
  # a half-written build reading as an application this transition removed, which
  # needs no appup and exits zero. So a candidate that holds no `.app` **at all**
  # is still an incomplete build and still refused; only one holding somebody
  # else's is passed over. That is the difference between "this directory is not
  # ours" and "this directory is ours and unfinished", and it is decidable.
  defp which!(dirs, build, app) do
    case Enum.split_with(dirs, &ours?(&1, app)) do
      {[dir], _theirs} -> Path.join(dir, "ebin")
      {[_ | _] = ours, _theirs} -> ambiguous!(ours, build, app)
      {[], theirs} -> absent_or_incomplete!(theirs, build, app)
    end
  end

  # An **exact** name match is ours whatever it contains, and only a *prefix*
  # match has to prove itself. `_build/<env>/lib/foo` is named for the
  # application with no version after it, so it cannot be another application's
  # directory - and a `bar.app` inside it, or no readable `foo.app`, makes it an
  # unfinished or broken build of `foo` rather than somebody else's. Treating that
  # as somebody else's read it as absent, and an absent application is one the
  # transition removed, which needs no appup and exits zero. Only `foo-bar-1.0.0`
  # is genuinely ambiguous about whose it is, because only a prefix match can
  # belong to a longer name.
  defp ours?(dir, app), do: Path.basename(dir) == "#{app}" or "#{app}" in resources_in(dir)

  # Nothing that matched the name holds this application's resource. Either they
  # all belong to other applications - in which case this one really is absent -
  # or one of them is an unfinished build of this one, which is a refusal. A
  # directory holding some other application's resource is evidence of the
  # former; one with no `ebin`, or an `ebin` with no usable resource in it at all,
  # is evidence of the latter.
  defp absent_or_incomplete!(dirs, build, app) do
    case Enum.reject(dirs, &(resources_in(&1) != [])) do
      [] -> nil
      [dir | _rest] -> ebin!(dir, build, app)
    end
  end

  # The application resources in a candidate directory that `:systools` could
  # actually read: a **regular file** named `<name>.app`. Both questions asked
  # about a candidate - is it ours, is it somebody else's - are derived from this
  # one list, because writing them separately is how they came to disagree: "ours"
  # required a regular file while "somebody else's" only matched the extension, so
  # an `ebin` holding nothing but a `foo.app` that was a dangling symlink or a
  # directory answered *no* to the first and *yes* to the second. That reads as
  # another application's directory, which makes this one absent, which makes the
  # transition a removal needing no appup - a broken build exiting zero.
  #
  # One definition, two derivations, and the three states a candidate can be in
  # stay exhaustive: ours, somebody else's, or unusable and therefore refused.
  defp resources_in(dir) do
    ebin = Path.join(dir, "ebin")

    case File.ls(ebin) do
      {:ok, names} ->
        for name <- names,
            Path.extname(name) == ".app",
            File.regular?(Path.join(ebin, name)),
            do: Path.rootname(name)

      {:error, _reason} ->
        []
    end
  end

  defp ambiguous!(dirs, build, app) do
    Mix.raise(
      "#{app} is in #{build.describe} more than once: " <>
        Enum.map_join(dirs, ", ", &inspect(Path.relative_to_cwd(&1))) <>
        ", each holding an ebin/#{app}.app. Which of them the upgrade would use depends on " <>
        "the code path, so this refuses rather than choosing."
    )
  end

  # Matched exactly rather than by prefix alone: `sample-` cannot match
  # `sample_dep-0.1.0`. The prefix is only ever a *candidate* filter, though -
  # see `which!/3` for what settles it, and why the prefix cannot.
  #
  # The two halves are kept apart rather than filtered down to one, because
  # *whether anything matched at all* is a different question from *whether what
  # matched is usable*, and collapsing them answered the second as though it were
  # the first. An entry that matches the name and is not a directory - a regular
  # file, or a symlink whose target is not there - was dropped, so the
  # application looked **absent**, which reads as one added or removed between
  # the two builds, needs no appup, and exits **zero**. That is the same silent
  # pass `build/2` exists to prevent, arriving one level further in, and it is the
  # answer these tasks must never give.
  #
  # A non-directory beside a real directory is still passed over rather than
  # refused. A legacy `sample-0.1.0.ez` archive sitting next to `sample-0.1.0`
  # matches the prefix and is not the application the upgrade would read; the
  # directory is. Only an application that has *nothing but* such entries is a
  # refusal, because only then is the alternative to call it absent.
  defp app_dirs(build, app) do
    prefix = "#{app}-"

    build.entries
    |> Enum.filter(&(&1 == "#{app}" or String.starts_with?(&1, prefix)))
    |> Enum.map(&Path.join(build.lib_dir, &1))
    |> Enum.split_with(&File.dir?/1)
  end

  defp not_directories!(paths, build, app) do
    Mix.raise(
      "#{app} is named in #{build.describe} by " <>
        Enum.map_join(paths, ", ", &inspect(Path.relative_to_cwd(&1))) <>
        ", none of which is a directory - a regular file, or a symlink with nothing at the " <>
        "end of it. That is a broken build rather than an application added or removed " <>
        "between the two, so this refuses rather than reporting one."
    )
  end

  # An application directory with no `ebin` in it is an incomplete build, not an
  # application this transition adds or removes - and treating it as the latter
  # is the same silent pass `build/2` exists to prevent, arriving one level
  # further in.
  defp ebin!(dir, build, app) do
    ebin = Path.join(dir, "ebin")

    if File.dir?(ebin) do
      ebin
    else
      Mix.raise(
        "#{app} is in #{build.describe} at #{Path.relative_to_cwd(dir)}, which holds no " <>
          "ebin directory. That is an incomplete build rather than an application added or " <>
          "removed between the two, so this refuses rather than reporting one."
      )
    end
  end

  @doc """
  One side of the comparison: the version an appup entry is keyed by, the beams
  on disk, and the `.app` resource's own module list.

  The last two are different things and both are needed - the beams are what
  *moved*, and the inventory is what `:systools` can *resolve*. See
  `app_resource!/2`.
  """
  @spec side!(binary(), atom()) :: side()
  def side!(ebin, app) do
    resource = Path.join(ebin, "#{app}.app")
    {vsn, inventory, listed?} = app_resource!(resource, app)
    {modules, exports} = read!(ebin)

    %{
      vsn: vsn,
      inventory: inventory,
      listed?: listed?,
      modules: modules,
      exports: exports,
      ebin: ebin,
      resource: resource
    }
  end

  @doc """
  The whole of the diff between two module maps, in terms of the direction's own
  old and new builds.

  Sorted, so that an answer is stable between runs and between machines -
  `File.ls/1` answers in whatever order the filesystem hands back, and the maps
  these are built from have no order of their own either.
  """
  @spec moved(%{module() => fingerprint()}, %{module() => fingerprint()}) ::
          {[module()], [module()], [module()]}
  def moved(old, new) do
    changed =
      for {module, print} <- new, Map.has_key?(old, module), old[module] != print, do: module

    added = for {module, _print} <- new, not Map.has_key?(old, module), do: module
    removed = for {module, _print} <- old, not Map.has_key?(new, module), do: module

    {Enum.sort(changed), Enum.sort(added), Enum.sort(removed)}
  end

  @doc """
  The OTP behaviours a module declares, read from the `Attr` chunk.

  **This is the only signal `mix castle.appup.gen` classifies on, and reading it
  here is what makes it one read of one file rather than two.** The attribute
  half of the fingerprint is already the decoded attribute list, so the
  behaviours come out of the same bytes the change detection compared.

  **Both attribute spellings are read, and that is measured rather than
  defensive.** The Erlang compiler preserves the spelling the source used:
  `-behaviour(gen_server).` is stored under `behaviour` and
  `-behavior(gen_server).` under `behavior` - measured on OTP 28.3, where the
  two compile to `[behaviour: [:gen_server]]` and `[behavior: [:gen_server]]`
  respectively. Elixir's `@behaviour` always produces the British spelling, so
  the American one only turns up in Erlang sources - which is exactly where a
  dependency's `gen_server` is likely to live.

  A module absent from the build, or one whose beam declares none, answers `[]`.
  """
  @spec behaviours(side(), module()) :: [atom()]
  def behaviours(side, module) do
    case Map.fetch(side.modules, module) do
      {:ok, {_md5, attributes}} ->
        Enum.flat_map(attributes, fn
          {:behaviour, behaviours} when is_list(behaviours) -> behaviours
          {:behavior, behaviours} when is_list(behaviours) -> behaviours
          _other -> []
        end)

      :error ->
        []
    end
  end

  @doc """
  Whether a module exports a function, read from the beam's `ExpT` chunk.

  **This is not a classification signal and must never become one.**
  `design/upgrade-tooling.md` §3.2 is explicit that `code_change/3` being
  *exported* says nothing: Elixir injects an overridable one into every
  `use GenServer` module, and the injected one cannot be told from a hand-written
  one at a release's beams. Which instruction a module needs is decided by
  `behaviours/2` and by nothing else.

  What an *absent* export decides is a different question, and that one is
  answerable. `code_change/3` is an optional callback of `gen_server` and
  `gen_event`, and `code_change/4` of `gen_statem` and `gen_fsm`, so a module can
  legitimately declare the behaviour and export neither - `@behaviour GenServer`
  without `use`, or any Erlang callback module. Measured on OTP 28:
  `sys:change_code/4` on such a process answers
  `{error, {'EXIT', {undef, [{Mod, code_change, ...}]}}}`, and
  `release_handler_1:change_code/5` matches `ok = sys:change_code(...)`, so the
  install fails. `mix castle.appup.gen` reports that beside the instruction it
  drafted rather than choosing a different one.

  A module absent from the build, or one whose beam has no export table, answers
  `false`.
  """
  @spec exports?(side(), module(), atom(), arity()) :: boolean()
  def exports?(side, module, name, arity) do
    case Map.fetch(side.exports, module) do
      {:ok, exports} -> MapSet.member?(exports, {name, arity})
      :error -> false
    end
  end

  # The beams on disk rather than the `.app` file's `modules` list. A beam is
  # what `release_handler` can load and what an instruction can name, and the
  # `.app` list is derived from the same directory anyway - so this asks the
  # question of the thing the upgrade acts on.
  #
  # Listed rather than globbed, for the reason `build/2` gives: a `*.beam`
  # pattern is built out of a path, and a path that happens to contain a glob
  # metacharacter would match nothing and report the application as empty.
  # `File.ls!/1` rather than a message of this module's own, because the
  # directory was established as one moments ago - a failure here is a race or a
  # permissions change, and Elixir's own error names the path and the reason.
  # Two maps out of one listing and one read per beam: the fingerprints that
  # change detection compares, and the export sets `exports/2` answers from.
  #
  # **They are kept apart rather than folded into one value, and that is the
  # point.** What counts as a module having *changed* is `:beam_lib.md5/1` and
  # the persisted attributes, and nothing else - putting the exports in the same
  # tuple would silently make an export-only difference a change, which is a
  # claim about upgrades nobody has made. Exports are read for a different
  # question entirely: whether an instruction the behaviours imply can actually
  # run. See `exports/2`.
  defp read!(ebin) do
    ebin
    |> File.ls!()
    |> Enum.filter(&(Path.extname(&1) == ".beam"))
    |> Enum.reduce({%{}, %{}}, fn name, {modules, exports} ->
      {module, fingerprint, exported} = fingerprint!(Path.join(ebin, name))

      {Map.put(modules, module, fingerprint), Map.put(exports, module, exported)}
    end)
  end

  # `:beam_lib.md5/1` rather than a digest of the bytes: see the moduledoc. The
  # module name comes out of the same call rather than from the filename,
  # because the beam is what says which module it holds.
  #
  # One read of the file, both questions asked of the same bytes - the file is
  # what could change between two reads.
  #
  # **`allow_missing_chunks`, because a beam without an `Attr` chunk is a beam
  # the runtime loads.** Measured on OTP 28.3: a module rebuilt without it loads,
  # answers calls, and reports `[]` from `module_info(attributes)` - and
  # `:beam_lib.strip/1`, the function the design names as a trap precisely
  # because it drops `Attr`, is one way to get one. Insisting on the chunk made
  # these tasks *refuse to run* against a dependency somebody had stripped that
  # way, which is a gate that cannot answer rather than a gate that says no.
  #
  # `:missing_chunk` is normalised to `[]` rather than to a sentinel of its own,
  # because `[]` is what such a module really has: the attribute half of the
  # fingerprint is "what `module_info/1` would report", and for these it reports
  # nothing. Two builds of such a module then compare on the md5 alone, which is
  # the documented weaker answer, and is the right one - there are no attributes
  # for it to miss. It also means `behaviours/2` answers `[]` for one, which is
  # the same thing the runtime would say about it.
  # The two chunks are looked up by name rather than matched positionally.
  # `:beam_lib.chunks/3` answers in the order it was asked, so a positional match
  # works today - and a `case` with no clause for any other order is a
  # `CaseClauseError` in a task that had something else to report, for a change
  # in OTP that nothing here would otherwise care about.
  defp fingerprint!(beam) do
    binary = File.read!(beam)
    chunks = :beam_lib.chunks(binary, [:attributes, :exports], [:allow_missing_chunks])

    case {:beam_lib.md5(binary), chunks} do
      {{:ok, {module, md5}}, {:ok, {module, read}}} when is_list(read) ->
        {module, {md5, attributes(read[:attributes])}, exports(read[:exports])}

      {{:error, :beam_lib, reason}, _chunks} ->
        Mix.raise(beam_error(beam, reason))

      {_md5, {:error, :beam_lib, reason}} ->
        Mix.raise(beam_error(beam, reason))
    end
  end

  defp attributes(:missing_chunk), do: []
  defp attributes(attributes) when is_list(attributes), do: attributes

  # `ExpT` is one of `:beam_lib.significant_chunks()`, so stripping keeps it and
  # a beam the runtime can load always has one. `allow_missing_chunks` is on for
  # `Attr`'s sake, so this has to answer for the case anyway: an empty set, which
  # is what a module with no export table would report, and which makes
  # `exports/2` say "no" to every question rather than raising in a task that had
  # something else to report.
  defp exports(:missing_chunk), do: MapSet.new()
  defp exports(exports) when is_list(exports), do: MapSet.new(exports)

  defp beam_error(beam, reason) do
    "#{Path.relative_to_cwd(beam)} could not be read as a beam file: #{inspect(reason)}"
  end

  @doc """
  The version, the `modules` inventory and whether `:systools` would accept the
  inventory, out of an application resource file.

  Two things come out of the `.app` resource, and both are needed.

  The **version** an appup entry is keyed by is the application's own, and at
  `:compile` level there is no `.rel` to read it out of and the directory name
  does not carry it either. This file is where it is, in both layouts.

  The **modules list** is what `systools_rc` means by "every module of the
  application": `#application.modules` comes from here, so it is what an
  `add_application` or a `restart_application` expands over, and it is what
  `get_lib/2` resolves object code through. It is deliberately *not* assumed to
  agree with the beams in `ebin`.

  A missing or malformed list is read as an **empty** one, and that is not what
  `:systools` makes of it: `systools_make:check_item/2` ends in
  `throw({missing_param, Item})`, and a `modules` value that is not a list of
  atoms is a `bad_param`. Validating a `.app` is that function's job and it does
  it when a release or a relup is built; a second, weaker copy of it here could
  only disagree with the first, which is the very failure `Forecastle.Appup`
  exists to prevent for appups.

  Reading it as empty is the conservative direction rather than the convenient
  one, which is what makes leaving it to `:systools` safe. An empty inventory
  resolves nothing, so every module that moved is reported as unresolvable and an
  application-level instruction covers nothing beyond what it names by hand -
  strictly more findings and a non-zero exit, never fewer. A malformed resource
  cannot buy a clean bill of health. The third element of the answer is what lets
  a caller say so directly rather than leaving it to be inferred.
  """
  @spec app_resource!(binary(), atom()) :: {binary(), MapSet.t(module()), boolean()}
  def app_resource!(file, app) do
    case :file.consult(to_charlist(file)) do
      {:ok, [{:application, ^app, opts}]} when is_list(opts) ->
        {inventory, listed?} = inventory(opts)

        {fetch_vsn!(opts, file), inventory, listed?}

      {:ok, terms} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} is not an application resource file for #{app}. " <>
            "Expected a single {application, #{app}, Options} tuple, but got: " <>
            "#{inspect(terms)}"
        )

      {:error, reason} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} could not be read as an application resource " <>
            "file: #{inspect(reason)}"
        )
    end
  end

  # A list with a non-atom anywhere in it is read as **empty**, not filtered down
  # to the atoms in it. `systools_make:a_list_p/1` is all-or-nothing - one
  # non-atom and the whole `modules` value is a `bad_param` - so keeping the valid
  # subset invented an inventory `:systools` never accepts, and a
  # whole-application instruction could then cover a changed module out of it and
  # exit zero. That is the one thing the conservative reading of a malformed `.app`
  # is supposed to rule out: it errs toward *more* findings precisely so a
  # malformed resource cannot buy a clean bill of health, and a surviving subset
  # broke that.
  #
  # The second element says whether `:systools` would accept the value at all, so
  # that a caller can report it as the fact about the build that it is, rather
  # than leaving it to be inferred from an empty inventory downstream.
  defp inventory(opts) do
    case List.keyfind(opts, :modules, 0) do
      {:modules, modules} when is_list(modules) ->
        if Enum.all?(modules, &is_atom/1),
          do: {MapSet.new(modules), true},
          else: {MapSet.new(), false}

      _absent_or_malformed ->
        {MapSet.new(), false}
    end
  end

  # `List.keyfind/3` rather than `Keyword.fetch/2`, and `is_list/1` on the way in:
  # a `.app` file is arbitrary consulted terms rather than something this project
  # wrote, and `Keyword` functions raise on a list that is not a keyword list -
  # which would report a malformed resource file as a crash in a task instead of
  # as the file it could not make sense of.
  #
  # `to_string/1` takes the version whether the file spells it as a charlist,
  # which is what every tool writes, or as a binary.
  defp fetch_vsn!(opts, file) do
    case List.keyfind(opts, :vsn, 0) do
      {:vsn, vsn} when is_list(vsn) or is_binary(vsn) ->
        to_string(vsn)

      nil ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} names no version, so there is no from-version to " <>
            "look an appup entry up by."
        )

      {:vsn, vsn} ->
        Mix.raise(
          "#{Path.relative_to_cwd(file)} names the version #{inspect(vsn)}, which is not a " <>
            "string. An appup entry is keyed by the version as it is written, so there is " <>
            "nothing to look one up by."
        )
    end
  end
end
