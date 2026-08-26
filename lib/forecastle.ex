defmodule Forecastle do
  @moduledoc """
  Documentation for `Forecastle`.
  """

  alias Forecastle.Appup.Dep

  @app Mix.Project.config()[:app]

  @spec steps(maybe_improper_list) :: maybe_improper_list
  def steps(tasks \\ [:assemble, :tar]) when is_list(tasks) do
    if idx = Enum.find_index(tasks, &match?(:assemble, &1)) do
      {pre, [:assemble | post]} = Enum.split(tasks, idx)
      {guard, post} = place_generation(post)

      pre ++
        guard ++
        [&__MODULE__.pre_assemble/1, :assemble, &__MODULE__.post_assemble/1] ++
        post
    else
      tasks
    end
  end

  # Generation is spliced in only where the caller has not placed it, and the
  # caller's placement stands where they have.
  #
  # The one arrangement this module sends a project to by hand - packing its own
  # archive in a function step, and placing `generate_relup/1` before it because
  # nothing here can tell which step does the packing - is exactly the
  # arrangement a blind splice duplicates. Two generations is not merely the
  # summary printed twice. The spliced one runs *after* the caller's step, so the
  # archive holds the relup from the first run and `version_path` holds the one
  # from the second, and a packing step that changed the tree on its way past
  # makes those two different upgrade plans with nothing said about it.
  #
  # **Only a step after `:assemble` counts**, which is a decision rather than a
  # side effect of where the search happens to look. `Mix.Release.validate_steps!/1`
  # does not settle it: it allows at most one `:tar` and requires it after
  # `:assemble`, and says nothing at all about function steps. Three reasons, in
  # the order they carry weight:
  #
  #   * A `generate_relup/1` before `:assemble` cannot generate anything. It
  #     reads `<name>.rel` out of `version_path`, which Mix has not written yet,
  #     so `read_rel!/1` refuses that file by name - which is the documented
  #     answer to a steps list that put the step somewhere else. Counting it
  #     would mean skipping the splice on the strength of a step that generates
  #     nothing, turning a build that fails loudly into one that assembles a
  #     release with no relup in it and says nothing.
  #   * It is the same segment `before_tar/2` already searches, for the same
  #     reason: what is being decided is where generation goes among the steps
  #     that shape the assembled release.
  #   * It keeps `Enum` away from a possibly-improper tail. `pre` is a proper
  #     list by construction - `Enum.split/2` built it - but `tasks` is not, and
  #     scanning the whole of it would reintroduce exactly what `before_tar/2` is
  #     written by hand to avoid.
  #
  # **A placement after `:tar` is neither honoured nor doubled: it is guarded**,
  # and that is the one placement this has anything to say about.
  #
  # `Mix.Release.validate_steps!/1` allows function steps on either side of
  # `:tar`, so `[:assemble, :tar, &Forecastle.generate_relup/1]` is a list Mix
  # accepts - and honouring it means `:tar` packing the version directory before
  # anything has written a relup into it. The build then generates one into the
  # assembled release, prints `auto: every transition in this relup is a hot
  # upgrade`, and exits 0 having shipped an archive with no upgrade plan in it:
  # the failure this whole feature exists to remove, wearing a success. Splicing
  # a *second* step before `:tar` instead - which is what the unconditional
  # splice did - is no better: the archive gets one plan, the version path gets
  # another, and nothing says which is which.
  #
  # So neither, and it is named instead. That is the same call the module makes
  # about a hand-written `relup` beside `upgrade_from:`: two answers, no reason
  # to prefer either, and the discarded one invisible in the assembled release.
  #
  # **But it is named by a step rather than from here**, because whether that
  # placement costs anything is a fact about the release and `steps/1` is handed
  # a list. Without `upgrade_from:` generation does nothing at all - documented,
  # and the release assembles exactly as it would without the step - so refusing
  # here would fail a build with nothing wrong with what it produced, including
  # one packaging a hand-written `relup`. `refuse_unpackaged_relup/1` asks the
  # release instead.
  #
  # **And it is spliced twice**, for the reason `refuse_hand_written_relup!/0` is
  # called twice: a `Mix.Release` is the caller's to rewrite, and this module
  # already says elsewhere that a step which adds a baseline to `upgrade_from:`
  # is a thing that happens. One check up front would pass for a release that
  # named nothing yet, and a step adding the option afterwards would then reach
  # `:tar` with the placement never re-examined - packing an archive, generating
  # a relup into the release behind it, and exiting 0. So:
  #
  #   * once before `:assemble`, where a refusal costs no build and no resolved
  #     baseline - the ordinary case, and the only one worth failing early; and
  #   * once immediately before `:tar`, which is the packaging boundary and the
  #     only position that can be sure. Nothing is packed without it having run
  #     against the options as they finally are.
  #
  # The early one is not ahead of *every* step: the caller's own pre-`:assemble`
  # steps come first, because `steps/1` has never inserted anything in front of
  # those. One of them adding the option is exactly what the second guard is for.
  #
  # What neither guard can see is a step *after* `:tar` setting the option: both
  # have run by then and the archive is packed. That is
  # [#40](https://github.com/ausimian/forecastle/issues/40) rather than anything
  # here, and it is left there deliberately - it is not about a caller-placed
  # generation step at all. A project whose mutating step follows `:tar` reaches
  # the same end with generation in its ordinary position, and reaches it with
  # *no* relup anywhere and nothing printed, which is the worse half. Closing it
  # from here would mean refusing every list with a function step after `:tar`,
  # which refuses builds that have nothing to do with relups.
  #
  # A step *before* `:assemble` is deliberately not guarded at all.
  # `Forecastle.Relup.read_rel!/1` already refuses it by name, and does so before
  # `:assemble` has created anything, so a second check would be the same
  # decision made in two places. An after-`:tar` step is the one with nothing
  # downstream that could notice it, which is why it needs something here.
  defp place_generation(post) do
    cond do
      generates_after_tar?(post) ->
        {[&__MODULE__.refuse_unpackaged_relup/1],
         before_tar(post, &__MODULE__.refuse_unpackaged_relup/1)}

      generates_relup?(post) ->
        {[], post}

      true ->
        {[], before_tar(post, &__MODULE__.generate_relup/1)}
    end
  end

  # Hand-written for `before_tar/2`'s reason and one of their own: an improper
  # tail is not a list to search, and complaining about it is not their business
  # either - `steps/1` hands the malformed list back for `Mix.Release` to refuse
  # by name. Reaching the tail means no generation step was found, which is the
  # answer `[]` gives too, so the two share a clause.
  #
  # Equality rather than a guard, because a capture is a term: two occurrences of
  # `&Forecastle.generate_relup/1` are the same external fun, so a project that
  # wrote the capture is recognised. One that wrapped it - `fn release ->
  # Forecastle.generate_relup(release) end` - is not, and cannot be: nothing here
  # can see inside an anonymous function. That project gets the unconditional
  # splice's behaviour, and the remedy is to place the capture rather than a
  # wrapper around it.
  defp generates_relup?([step | post]) do
    step == (&__MODULE__.generate_relup/1) or generates_relup?(post)
  end

  defp generates_relup?(_tail), do: false

  # `Mix.Release.validate_steps!/1` allows at most one `:tar`, so the first one
  # is the only one, and everything beyond it is the unpackageable half.
  defp generates_after_tar?([:tar | post]), do: generates_relup?(post)
  defp generates_after_tar?([_other | post]), do: generates_after_tar?(post)
  defp generates_after_tar?(_tail), do: false

  @doc false
  # Spliced in twice by `steps/1`, and only when the project put
  # `generate_relup/1` after `:tar`. What it refuses, and why it is a step at all
  # rather than a refusal in `steps/1`, is in `place_generation/1`; what belongs
  # here is why the two positions are the two positions.
  #
  # The first is ahead of `pre_assemble/1`, which resolves the baselines -
  # unpacking an artefact, or building a git ref, minutes of work for a build
  # that is going to be refused - and ahead of `:assemble`, which is the half
  # that matters: Mix does not tidy up after a step of its own that raised, so a
  # refusal afterwards leaves a version directory that a corrected retry without
  # `--overwrite` declines to overwrite, and that retry then exits 0 having
  # assembled nothing. The same argument `stage_relup/1` and `stage_baselines/1`
  # make about their own checks.
  #
  # The second is immediately before `:tar`, and it is the one that cannot be
  # dropped: a caller step between the two can add `upgrade_from:` to a release
  # that named nothing when the first ran. It costs an assembled release that a
  # retry has to `--overwrite`, which is the lesser of the two prices - the
  # greater being a shipped archive announced as carrying an upgrade plan it does
  # not carry.
  #
  # `upgrade_from!/1` rather than a bare `Keyword.has_key?/2`, so that a release
  # naming nothing, or naming something malformed, is refused for what is wrong
  # with it rather than for where the step sits.
  @spec refuse_unpackaged_relup(Mix.Release.t()) :: Mix.Release.t()
  def refuse_unpackaged_relup(%Mix.Release{} = release) do
    case upgrade_from!(release) do
      :none ->
        release

      {:baselines, _specs} ->
        Mix.raise(
          "the release steps put &Forecastle.generate_relup/1 after :tar, where the relup it " <>
            "writes cannot be packaged. :tar packs the version directory, so the archive is " <>
            "built before generation has written anything into it - and the build would " <>
            "still announce the upgrade plan it generated, and succeed, having shipped an " <>
            "artefact with none in it. Move the step before :tar, or drop :tar and pack your " <>
            "own archive in a step with generation in front of it."
        )
    end
  end

  # Relup generation goes as late as it can while still preceding the packaging,
  # which is immediately before `:tar` rather than immediately after
  # post-assembly - and the difference is not cosmetic.
  #
  # `mix release` documents a function step between `:assemble` and `:tar` as the
  # way to customise an assembled release, and such a step can change exactly
  # what a relup would be generated from: an appup rewritten, a module replaced,
  # something copied into `lib/`. Generating before it means the relup describes
  # the tree as it was while `:tar` packages the tree as it became - an upgrade
  # plan for contents that did not ship, which is the failure this feature exists
  # to remove rather than to introduce. So every caller step keeps its place and
  # generation happens after all of them.
  #
  # Mix's own `validate_steps!/1` is what makes "before `:tar`" unambiguous: it
  # allows at most one `:tar` and requires it to come after `:assemble`.
  # Searching only the steps *after* `:assemble` keeps that true even for a list
  # Mix is about to refuse.
  #
  # With no `:tar` there is no packaging step to precede, so generation is
  # appended and the relup describes the finished tree. A project that packs its
  # own archive in a function step - which `Castle.customize/1` warns about
  # rather than refuses - has to place `generate_relup/1` itself, because nothing
  # here can tell which of its steps does the packing. Nothing reaches here when
  # it has: `place_generation/1` hands the caller's list straight back, so the
  # arrangement this paragraph prescribes is not also duplicated by it.
  #
  # Written by hand rather than through `Enum`/`List` so that an improper tail
  # survives: `steps/1` hands a malformed list back for `Mix.Release` to refuse
  # by name, and an `Enum` error raised out of here instead would name a module
  # the project never mentioned.
  defp before_tar([:tar | _rest] = post, step), do: [step | post]
  defp before_tar([other | post], step), do: [other | before_tar(post, step)]
  defp before_tar(tail, step), do: [step | tail]

  # Nothing here touches configuration. Mix decides which file configures a
  # release at runtime, initialises the providers a project declares, and writes
  # the `sys.config` its own launcher boots from - and all of that is left
  # exactly as Mix leaves it. Forecastle used to intercept the lot: it set
  # `runtime_config_path: false`, installed a substitute `Config.Reader` of its
  # own, rewrote every provider's init argument into a keyword list with an
  # `:env` key added, and renamed `sys.config` to `build.config` so that only
  # Castle could expand it at boot. That existed to give the version being
  # upgraded *to* a configuration resolved by its own providers, which
  # castle#13 now does properly, in a `:peer` running the target's own code, for
  # every version and by the only route Castle has left - there is no
  # `build.config` and nothing that would read one, so renaming what Mix wrote
  # would leave the standard launcher with no configuration to boot from.
  def pre_assemble(%Mix.Release{} = release) do
    release
    |> stage_baselines()
    |> stage_relup()
    |> stage_dep_appups()
    |> create_preboot_scripts()
  end

  def post_assemble(%Mix.Release{} = release) do
    release
    |> tap(&install_castle_cli/1)
    |> tap(&install_start_program/1)
    |> tap(&extend_env_script/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
    |> tap(&place_dep_appups/1)
    |> tap(&warn_unsupported_executables/1)
  end

  @doc """
  Generates this release's relup, from the `:upgrade_from` release option.

  Runs after `post_assemble/1` and immediately before `:tar`, which is the one
  point in a build where everything `:systools` needs exists: `version_path` is
  there, `<name>.rel` has been written, and `lib/` is populated. So the relup is
  generated for the release being assembled and written straight into its version
  path, and the build-generate-rebuild cycle `mix castle.relup` used to require
  disappears.

  `steps/1` places it *last* of the steps that shape the release - after any
  function step of the project's own - so that the relup describes the tree that
  is packaged rather than the tree as it was partway through building it. A
  project that placed this step itself keeps its own placement instead, and gets
  no second one: a project packing its own archive has to put generation in
  front of the step that packs, and that is the arrangement, not a mistake to
  correct. Placed *after* `:tar`, where the relup could never be packaged, it is
  refused rather than honoured or doubled - but only where the release asks for a
  relup at all, which `refuse_unpackaged_relup/1` is what decides.

  `:upgrade_from` is a list of baseline specs - `rel:`, `tar:` or `ref:`, the
  grammar `Forecastle.Baseline` documents - naming the releases this one can be
  upgraded from. Every one of them gets both directions, which is what
  `mix castle.relup --fromto` does: a relup that cannot be rolled back is not
  much of an upgrade plan. The strategy is `auto`, which is the task's default
  too; `mix castle.relup` is still where a build that has to insist on `--hot`
  or `--restart` goes.

  **Without the option this step does nothing at all**, deliberately and
  documentedly: a release that says nothing about upgrading is assembled exactly
  as it was before this existed. An `upgrade_from: []` is not that case - it is a
  build asking for an upgrade plan and naming nothing to generate one against -
  and it is refused rather than folded into the same silence.

  A hand-written `relup` in the project root and `:upgrade_from` together are
  refused rather than ordered by precedence, in `pre_assemble/1` where the
  refusal costs no build, and here as well so that this step is right on its own.
  """
  @spec generate_relup(Mix.Release.t()) :: Mix.Release.t()
  def generate_relup(%Mix.Release{} = release) do
    case upgrade_from!(release) do
      :none ->
        release

      {:baselines, specs} ->
        refuse_hand_written_relup!()
        write_generated_relup!(release, specs)
        release
    end
  end

  # `version_path` is where `release_handler` looks for a relup, and it is what
  # `:tar` packs, so a relup written here needs no copying afterwards - which is
  # the whole difference between this and the staged project-root one.
  #
  # The target is named the way `:systools` names a release: the `.rel` file
  # without its extension. It is Mix's own output at this point in the steps
  # list, so there is nothing here to check that `:assemble` has not already
  # guaranteed - and a steps list that put this step somewhere else meets
  # `read_rel!/1` refusing the file it could not read, by name.
  #
  # The baselines were resolved in `pre_assemble/1` and are read back from the
  # options here. Falling back to resolving them now is what keeps this step
  # right when it is reached without its neighbour; it is not the ordinary path,
  # and `stage_baselines/1` says why the ordinary path resolves early.
  defp write_generated_relup!(%Mix.Release{name: name, version_path: vp} = release, specs) do
    target = Path.join(vp, to_string(name))
    resolved = staged_baselines(release.options[:forecastle_baselines], specs)

    Forecastle.Relup.generate!(target, specs, specs, resolved, :auto, vp)
  end

  # The stash is used only where it answers for every spec this step is about to
  # generate from, and `nil` - resolve now - is the answer everywhere else.
  #
  # Two steps and a caller's own function steps run between the resolution and
  # the use, and a `Mix.Release` is theirs to rewrite: a step that added a
  # baseline to `upgrade_from:` would leave the map missing it. `generate!/6`
  # looks specs up with `Map.fetch!/2`, so that arrives as a `KeyError` naming a
  # map rather than as anything an author could act on - and re-resolving is not
  # merely the safer branch but the *correct* one, since what the option says now
  # is what the relup should be generated from.
  #
  # It is also the guard for a stash that is not a map at all, which
  # `stage_baselines/1` cannot leave behind but a caller's step could.
  defp staged_baselines(resolved, specs) when is_map(resolved) do
    if Enum.all?(specs, &Map.has_key?(resolved, &1)), do: resolved
  end

  defp staged_baselines(_resolved, _specs), do: nil

  # Resolving a baseline is the largest thing this feature can fail at, and
  # `pre_assemble/1` is the last moment at which failing is free.
  #
  # A `tar:` that is not there, a `ref:` that does not exist or does not build:
  # each of those raises, and raising *after* `:assemble` leaves the version
  # directory behind, because Mix does not tidy up after a step of its own that
  # raised. The corrected retry then finds that directory, declines to overwrite
  # it without `--overwrite`, and exits 0 having assembled nothing - a green
  # pipeline holding the previous artefact. `stage_relup/1` makes the same
  # argument about the project-root relup, and it is why that check is here too.
  #
  # So the whole of resolution happens before `:assemble` and the result is
  # carried forward. What is left in the late half genuinely has nowhere earlier
  # to go: reading the target's `.rel` and asking `:systools` for a script both
  # need the assembled release.
  #
  # The key is dropped unconditionally first, for the reason `stage_relup/1`
  # drops its own: Mix keeps release options it does not recognise, so a project
  # that had set this one - for whatever reason - would otherwise have its value
  # used as the resolved baselines.
  defp stage_baselines(%Mix.Release{options: options} = release) do
    options = Keyword.delete(options, :forecastle_baselines)

    case upgrade_from!(release) do
      :none ->
        %Mix.Release{release | options: options}

      {:baselines, specs} ->
        # Before resolution rather than after: a build that names two upgrade
        # plans is refused without paying for a baseline it will not use.
        refuse_hand_written_relup!()

        resolved = Forecastle.Relup.resolve_baselines!(specs)
        %Mix.Release{release | options: Keyword.put(options, :forecastle_baselines, resolved)}
    end
  end

  # `:none` or a non-empty list, and deliberately no third answer.
  #
  # `upgrade_from: []` is a project asking for an upgrade plan and naming nothing
  # to generate one against - a list read out of the environment, or filtered
  # down to nothing by a `mix.exs` that computes it. Answering `[]` for that and
  # for the absent option alike is how such a release would be assembled with no
  # relup in it and nothing said, which is the one outcome a build asking for an
  # upgrade plan must not get. So the empty list is a refusal and absence is a
  # documented no-op, and the two are told apart here rather than anywhere that
  # would have to remember to.
  #
  # `Keyword.get_values/2` rather than `fetch/2`, and more than one occurrence is
  # a refusal. `Mix.Release` keeps the options it does not recognise in the
  # keyword list it was given, and `Keyword.merge/2` preserves duplicate keys
  # *within* the list being merged in - so a release definition assembled by
  # concatenating lists, which is how the option is most naturally added
  # alongside others, really can carry two. `fetch/2` would take the first and
  # discard the rest, which is a build generating an upgrade plan against
  # baselines the project did not settle on and no word said about the ones
  # dropped. Repeated switches are refused rather than resolved by precedence in
  # `mix castle.relup` for the same reason.
  @spec upgrade_from!(Mix.Release.t()) :: :none | {:baselines, [binary(), ...]}
  defp upgrade_from!(%Mix.Release{options: options}) do
    case Keyword.get_values(options, :upgrade_from) do
      [] ->
        :none

      [specs] ->
        baselines!(specs)

      many ->
        Mix.raise(
          "the release option upgrade_from: was given #{length(many)} times (" <>
            Enum.map_join(many, ", ", &inspect/1) <>
            "), and only one of them would be used. Mix keeps every occurrence of a " <>
            "release option it does not recognise, so a definition built by joining lists " <>
            "can carry more than one. Name all the baselines in a single upgrade_from:."
        )
    end
  end

  defp baselines!([]) do
    Mix.raise(
      "the release option upgrade_from: names no baselines. It is the list of releases " <>
        "this one can be upgraded from, and a relup with no transitions in it is not an " <>
        "upgrade plan. Name at least one baseline, or leave the option out to assemble " <>
        "without a relup."
    )
  end

  defp baselines!(specs) when is_list(specs) do
    case Enum.reject(specs, &is_binary/1) do
      [] ->
        # Parsed rather than merely type-checked, and parsed *here*.
        # `Forecastle.Baseline.parse!/1` is the grammar and it touches no
        # filesystem, so an empty spec, a prefix naming no source, and a prefix
        # with nothing after it are all settleable before `:assemble` has created
        # anything - which is the whole point of reading the option in
        # `pre_assemble/1`. Left to `resolve!/2`, they would each fail *after*
        # assembly, and Mix does not tidy up after a step of its own that raised:
        # the corrected retry then finds the version directory, declines to
        # overwrite it, and exits 0 having assembled nothing.
        #
        # Resolution deliberately stays where it is. That is the half that
        # unpacks tarballs and builds commits, and it belongs beside the
        # generation that needs the target.
        Enum.each(specs, &Forecastle.Baseline.parse!/1)

        {:baselines, specs}

      not_specs ->
        Mix.raise(
          "the release option upgrade_from: takes baseline specs as strings, but " <>
            Enum.map_join(not_specs, ", ", &inspect/1) <>
            " is not one. A spec names where a previous release comes from: `rel:` an " <>
            "assembled release, `tar:` a shipped artefact, `ref:` a git ref, or a bare " <>
            "path to an assembled release."
        )
    end
  end

  defp baselines!(other) do
    Mix.raise(
      "the release option upgrade_from: takes a list of baseline specs, but got " <>
        "#{inspect(other)}. One baseline is a list of one: upgrade_from: " <>
        "[\"tar:artifacts/my_app-1.0.0.tar.gz\"]."
    )
  end

  # Two upgrade plans for one release, arrived at two ways, and no reason to
  # prefer either: a hand-written `relup` in the project root is a plan somebody
  # wrote, `upgrade_from:` is a plan this build would generate, and only one file
  # can be in the version path. Picking one silently discards the other, and
  # which one got discarded is invisible in the assembled release - so this
  # refuses and names both.
  #
  # Called from `stage_baselines/1`, where it costs neither a build nor a
  # baseline, *and* from `generate_relup/1`, so that the step cannot generate
  # over a hand-written plan if it is ever reached without its neighbour.
  defp refuse_hand_written_relup! do
    relup = project_relup()

    if File.exists?(relup) do
      Mix.raise(
        "#{relup} and the release option upgrade_from: are both upgrade plans for this " <>
          "release, and only one of them can be packaged. Remove the relup to generate " <>
          "one from the baselines, or drop upgrade_from: to package the one that is " <>
          "already written."
      )
    end

    :ok
  end

  # Before `:assemble`, deliberately. Checking the relup afterwards meant a
  # stale one failed the build only once the version directory existed, and Mix
  # does not tidy up after a step of its own that raised. A corrected retry
  # without `--overwrite` then finds that directory, declines to overwrite it,
  # and exits 0 having assembled nothing - a worse outcome than the one the
  # check exists to prevent. The checked bytes are carried through so that what
  # lands in the release is exactly what was read and checked here.
  defp stage_relup(%Mix.Release{version: vsn, options: options} = release) do
    relup = project_relup()

    # Dropped unconditionally first. Mix keeps release options it does not
    # recognise, so a project that had set this key - for whatever reason -
    # would otherwise have its value written out as the release's upgrade plan
    # without any of this having looked at it.
    options = Keyword.delete(options, :forecastle_relup)

    if File.exists?(relup) do
      staged = relup |> verify_relup!(vsn) |> encode_relup()
      %Mix.Release{release | options: Keyword.put(options, :forecastle_relup, staged)}
    else
      %Mix.Release{release | options: options}
    end
  end

  defp project_relup do
    Mix.Project.project_file() |> Path.dirname() |> Path.join("relup")
  end

  # The appups the project supplies for applications it does not own, read and
  # checked here for the same reason the relup is: `rel/appups` is arbitrary
  # Elixir evaluated for its value, its names are checked against the versions
  # this release carries, and every way one of those checks can fail is a
  # refusal. Before `:assemble`, all of it - a refusal after it leaves the
  # version directory behind, and the corrected retry then declines to overwrite
  # it and exits 0 having assembled nothing. `Forecastle.Appup.Dep` is where the
  # reading and the refusals live.
  defp stage_dep_appups(%Mix.Release{options: options} = release) do
    # Dropped unconditionally first, for `stage_relup/1`'s reason: Mix keeps
    # release options it does not recognise, so a project that had set this key
    # would otherwise have its value written into the release as appups.
    options = Keyword.delete(options, :forecastle_dep_appups)

    case Dep.stage!(release) do
      [] ->
        %Mix.Release{release | options: options}

      placements ->
        %Mix.Release{release | options: Keyword.put(options, :forecastle_dep_appups, placements)}
    end
  end

  # The script `Castle.Peer` boots. It is `start_clean` plus the applications
  # needed to run a release's own `Config.Provider` pipeline - and Castle - and
  # notably *not* the release's own applications, which must not be started a
  # second time in a VM that only exists to answer what the configuration is.
  # Its final `path` instruction is still the release's whole code path, so a
  # provider module belonging to one of those applications is loadable.
  #
  # It was written to expand configuration at boot, which is gone. It stays
  # because it is what the peer that replaced that expansion boots from, and it
  # has to be in the release being installed rather than in the one installing
  # it: only the target can say what the target's configuration is.
  defp create_preboot_scripts(%Mix.Release{boot_scripts: scripts} = release) do
    preboot =
      scripts[:start_clean]
      |> Keyword.merge(for app <- [:sasl, :compiler, :elixir, :castle], do: {app, :permanent})

    %Mix.Release{release | boot_scripts: Map.put(scripts, :preboot, preboot)}
  end

  defp install_castle_cli(%Mix.Release{path: path} = release) do
    if unix_executables?(release) do
      castle = Path.join([path, "bin", "castle"])
      File.write!(castle, render("castle.sh.eex", release))
      File.chmod!(castle, 0o755)
    end
  end

  # `bin/start` is the path `release_handler` hands to `heart:set_cmd/1` while
  # preparing an emulator restart, and it does nothing. The script itself says
  # why; what belongs here is why it is at *this* path.
  #
  # `init/1` resolves the start program as `{do_check, Configured}` when
  # `{sasl, start_prg}` is set and `{no_check, filename:join([Root, "bin",
  # "start"])}` otherwise, and `check_start_prg/2` returns the second
  # unexamined. So the default needs no configuration at all, whereas naming a
  # path of our own would mean injecting `:sasl` application configuration into
  # the release - which is exactly the interception
  # [#6](https://github.com/ausimian/forecastle/issues/6) removed and which
  # nothing here may reintroduce. `Root` is `code:root_dir()`, which for a Mix
  # release that brought its own ERTS is the release root; a release that did not
  # is refused by Castle's ERTS guard long before any of this.
  defp install_start_program(%Mix.Release{path: path} = release) do
    if unix_executables?(release) do
      start = Path.join([path, "bin", "start"])
      File.write!(start, render("start.sh.eex", release))
      File.chmod!(start, 0o755)
    end
  end

  defp extend_env_script(%Mix.Release{version_path: vp} = release) do
    env_sh = Path.join(vp, "env.sh")

    if unix_executables?(release) and File.exists?(env_sh) do
      File.write!(env_sh, render("env.sh.eex", release), [:append])
    end
  end

  defp unix_executables?(%Mix.Release{} = release) do
    :unix in executables_for(release)
  end

  # `bin/castle` is a POSIX shell script and is written only for a release that
  # asks for unix executables, so there is nothing on a Windows deployment to
  # drive an upgrade with. The .bat launcher itself does now boot - Mix writes
  # the `sys.config` it reads and expands configuration in the booting VM, which
  # it did not while Forecastle was withholding both - so what is missing is
  # release management rather than the release. Assembly succeeds either way, so
  # say so rather than let a deployment that cannot be upgraded leave the build
  # quietly.
  defp warn_unsupported_executables(%Mix.Release{} = release) do
    if :windows in executables_for(release) do
      Mix.shell().error(
        "warning: Forecastle does not support Windows releases. The .bat " <>
          "launcher this release includes will boot, but bin/castle is a POSIX " <>
          "shell script, so nothing on a Windows deployment can unpack, install " <>
          "or commit an upgrade. Set include_executables_for: [:unix] to stop " <>
          "building one."
      )
    end
  end

  defp executables_for(%Mix.Release{options: options}) do
    Keyword.get(options, :include_executables_for, [:unix, :windows])
  end

  defp render(template, %Mix.Release{} = release) do
    @app
    |> :code.priv_dir()
    |> Path.join(template)
    |> EEx.eval_file(release: release)
  end

  defp copy_relfile(%Mix.Release{name: name, version: vsn, path: path, version_path: vp}) do
    File.cp!(Path.join(vp, "#{name}.rel"), Path.join([path, "releases", "#{name}-#{vsn}.rel"]))
  end

  # Checked in `pre_assemble/1`, before Mix has created anything, so all that is
  # left here is to put the bytes that were checked into the release.
  # Re-emitted from the term that was checked rather than copied from the file
  # again: `:file.consult/1` reopens the path, and a `mix castle.relup`
  # running alongside the build can replace it in between, so a second read is
  # not necessarily the bytes that were checked. The format is the one
  # `systools` writes and `release_handler` reads - a UTF-8 coding comment and
  # a single term.
  defp encode_relup(plan) do
    case :unicode.characters_to_binary(:io_lib.format(~c"%% coding: utf-8~n~tp.~n", [plan])) do
      bytes when is_binary(bytes) -> bytes
      _not_encodable -> Mix.raise("#{project_relup()} cannot be encoded as UTF-8")
    end
  end

  defp copy_relup(%Mix.Release{options: options, version_path: vp}) do
    case Keyword.fetch(options, :forecastle_relup) do
      {:ok, bytes} -> File.write!(Path.join(vp, "relup"), bytes)
      :error -> :ok
    end
  end

  # Read and checked in `pre_assemble/1`, so all that is left here is to put the
  # bytes that were checked into the release. This is the first step at which
  # `lib/<app>-<vsn>/ebin` exists, and it is the only place any of this writes:
  # an appup written into `deps/` or into `_build`'s copy of a dependency would
  # leak one project's upgrade instructions into every build sharing that
  # checkout.
  defp place_dep_appups(%Mix.Release{options: options} = release) do
    case Keyword.fetch(options, :forecastle_dep_appups) do
      {:ok, placements} -> Dep.place!(release, placements)
      :error -> :ok
    end
  end

  # The relup is produced by a separate `mix castle.relup` run, so nothing
  # about being here says it belongs to the release being assembled. Packaging
  # one for another version is worse than packaging none at all: nothing checks
  # it again, and `release_handler` applies it as this version's upgrade plan.
  # `mix castle.relup --outdir` makes that reachable - generation succeeds
  # elsewhere and an older relup is left sitting here - and so does anything that
  # left a partial one behind: the task itself publishes by renaming a staging
  # file over the relup, and so cannot, but a copy or an editor interrupted
  # partway through can. Fail the build instead.
  defp verify_relup!(relup, vsn) do
    wanted = to_charlist(vsn)

    case :file.consult(to_charlist(relup)) do
      # The outer contract `systools_make:check_relup/1` enforces when OTP packs
      # a tarball: one term, a non-empty version string, and list-valued upgrade
      # and downgrade sections. Mix packs its own tarball, so nothing applies
      # that check on the way into a release, and `release_handler` reaches
      # straight into those two lists during an upgrade. The pinned version is
      # a non-empty charlist by construction, so matching it covers the rest.
      {:ok, [{^wanted, up, down} = plan]} when is_list(up) and is_list(down) ->
        plan

      {:ok, [{[_ | _] = other, up, down}]} when is_list(up) and is_list(down) ->
        Mix.raise(
          "#{relup} is an upgrade plan for #{other}, but this release is #{vsn}. " <>
            "Generate the relup for #{vsn} into the project root, or remove the stale one."
        )

      {:ok, terms} ->
        Mix.raise(
          "#{relup} is not an upgrade plan. Expected a single {version, upgrade, " <>
            "downgrade} tuple with a version string and two lists, which is what " <>
            "systools writes and release_handler reads, but got: #{inspect(terms)}"
        )

      {:error, reason} ->
        Mix.raise("#{relup} could not be read as an upgrade plan: #{inspect(reason)}")
    end
  end
end
