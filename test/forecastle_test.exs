defmodule ForecastleTest do
  use ExUnit.Case, async: true

  doctest Forecastle

  describe "steps/1" do
    test "wraps the assemble step" do
      assert [pre, :assemble, post, relup, :tar, late] = Forecastle.steps()
      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
      assert late == (&Forecastle.refuse_late_upgrade_from/1)
    end

    test "puts relup generation after post-assembly and before :tar" do
      # The position is the whole of what makes generation possible: before
      # `:assemble` there is no `<name>.rel` and no populated `lib/` to generate
      # from, and after `:tar` the archive has already been packed without it.
      # Asserting the list in order is what catches a splice that put the step
      # somewhere it would find nothing or change nothing.
      assert [_pre, :assemble, _post, relup, :tar, _late] = Forecastle.steps()
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "preserves the caller's own steps around the injected ones" do
      before_step = fn release -> release end
      after_step = fn release -> release end

      assert [^before_step, pre, :assemble, post, relup, :tar, ^after_step, _late] =
               Forecastle.steps([before_step, :assemble, :tar, after_step])

      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "generates the relup after a caller step between :assemble and :tar" do
      # `mix release` documents a function step there as the way to customise an
      # assembled release, and such a step can change what a relup would be
      # generated from - an appup rewritten, a module replaced, something copied
      # into `lib/`. Generating before it would describe the tree as it was while
      # `:tar` packages the tree as it became. `Forecastle.AssemblyRelupTest`
      # pins the consequence on a real release; this pins the order.
      custom = fn release -> release end

      assert [pre, :assemble, post, ^custom, relup, :tar, _late] =
               Forecastle.steps([:assemble, custom, :tar])

      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "appends relup generation when there is no :tar step" do
      # Nothing to precede, so the relup describes the finished tree. A project
      # that packs its own archive in a function step has to place the step
      # itself: nothing here can tell which of its steps does the packing.
      custom = fn release -> release end

      assert [_pre, :assemble, _post, ^custom, relup, _late] =
               Forecastle.steps([:assemble, custom])

      assert relup == (&Forecastle.generate_relup/1)
    end

    test "keeps a relup step the caller placed, rather than splicing a second" do
      # The arrangement the module sends a project to when it packs its own
      # archive: generation in front of the step that packs, because nothing in
      # `steps/1` can tell which step that is. A splice that did not look would
      # add a second one *after* the packing step, so the archive would hold the
      # relup from the first run and the version path the one from the second -
      # two upgrade plans for one release, with nothing saying they differ.
      # `Forecastle.AssemblyRelupTest` pins that consequence on a real build.
      #
      # The list being exactly this long is half the assertion: one generation
      # step, in the caller's position.
      pack = fn release -> release end

      assert [pre, :assemble, post, relup, ^pack, _late] =
               Forecastle.steps([:assemble, &Forecastle.generate_relup/1, pack])

      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "keeps the caller's placement rather than moving it in front of :tar" do
      # The same rule where there *is* a `:tar` to precede. Generation before a
      # caller step is not where `steps/1` would have put it, and that is the
      # point: a placement made deliberately is not a mistake to correct.
      custom = fn release -> release end

      assert [_pre, :assemble, _post, relup, ^custom, :tar, _late] =
               Forecastle.steps([:assemble, &Forecastle.generate_relup/1, custom, :tar])

      assert relup == (&Forecastle.generate_relup/1)
    end

    test "guards a relup step the caller put after :tar" do
      # `Mix.Release.validate_steps!/1` allows function steps on either side of
      # `:tar`, so this is a list Mix accepts. Honouring it would have `:tar`
      # pack the version directory before anything wrote a relup into it, and the
      # build would then generate one into the assembled release, announce it,
      # and exit 0 having shipped an archive with no upgrade plan - the failure
      # this feature exists to remove, wearing a success. Splicing a second step
      # before `:tar` is no better: the archive gets one plan and the version
      # path another, with nothing saying which is which.
      #
      # So neither. A guard goes in, and it is a *step* because whether the
      # placement costs anything is a fact about the release rather than about
      # the list - see `refuse_unpackaged_relup/1` below.
      #
      # **Twice**, and the second position is the one that cannot be dropped: a
      # `Mix.Release` is the caller's to rewrite, so a step between the two can
      # add `upgrade_from:` to a release that named nothing when the first ran.
      # Immediately before `:tar` is the packaging boundary, and the only
      # position sure of the options as they finally are.
      assert [guard, _pre, :assemble, _post, guard, :tar, relup, _late] =
               Forecastle.steps([:assemble, :tar, &Forecastle.generate_relup/1])

      assert guard == (&Forecastle.refuse_unpackaged_relup/1)
      assert relup == (&Forecastle.generate_relup/1)

      # Including where the caller placed a packageable one as well: the
      # after-`:tar` step would still overwrite what was packed. Both of the
      # caller's steps keep their places, and nothing is added but the guards.
      assert [^guard, _pre, :assemble, _post, first, ^guard, :tar, second, _late] =
               Forecastle.steps([
                 :assemble,
                 &Forecastle.generate_relup/1,
                 :tar,
                 &Forecastle.generate_relup/1
               ])

      assert first == (&Forecastle.generate_relup/1)
      assert second == (&Forecastle.generate_relup/1)
    end

    test "does not refuse a caller step after :tar that is not relup generation" do
      # The refusal is about one capture in one position, not about steps after
      # `:tar`, which `mix release` allows and this has no opinion on.
      after_tar = fn release -> release end

      assert [_pre, :assemble, _post, relup, :tar, ^after_tar, _late] =
               Forecastle.steps([:assemble, :tar, after_tar])

      assert relup == (&Forecastle.generate_relup/1)
    end

    test "counts only a relup step after :assemble" do
      # Before `:assemble` the step cannot generate anything: it reads
      # `<name>.rel` out of `version_path`, which Mix has not written yet, and
      # fails naming that file. A project that put one there is a build that
      # already fails loudly, and counting it would trade that for a release
      # assembled with no relup in it and nothing said.
      # `Mix.Release.validate_steps!/1` does not settle this - it constrains
      # `:tar` and says nothing about function steps.
      caller = &Forecastle.generate_relup/1

      assert [^caller, pre, :assemble, post, relup, :tar, _late] =
               Forecastle.steps([caller, :assemble, :tar])

      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "hands an improper list back rather than raising out of Forecastle" do
      # `Mix.Release.validate_steps!/1` refuses a malformed steps list by name,
      # and that is a better error than anything raised from here would be: an
      # `Enum` failure would name a module the project never mentioned. So the
      # splice is written by hand, and the search for a caller-placed generation
      # step has to be too - it walks the same possibly-improper list.
      assert [_pre, :assemble, _post, appended, late | :nonsense] =
               Forecastle.steps([:assemble | :nonsense])

      assert appended == (&Forecastle.generate_relup/1)
      assert late == (&Forecastle.refuse_late_upgrade_from/1)

      assert [_pre, :assemble, _post, spliced, :tar, ^late | :nonsense] =
               Forecastle.steps([:assemble, :tar | :nonsense])

      assert spliced == (&Forecastle.generate_relup/1)

      # And with a caller-placed step in front of the improper tail, where the
      # search has to reach that tail to answer at all.
      assert [_pre, :assemble, _post, placed, ^late | :nonsense] =
               Forecastle.steps([:assemble, (&Forecastle.generate_relup/1) | :nonsense])

      assert placed == (&Forecastle.generate_relup/1)
    end

    test "reads upgrade_from: once more after every step has run" do
      # The only position from which a step that sets the option *after* `:tar`
      # is visible at all. Generation runs immediately before `:tar`, so at every
      # point it could read the option that mutation has not happened yet, and by
      # the time it has the archive is packed - a build asking for an upgrade
      # plan and shipping an artefact with none in it, at exit 0.
      #
      # Appended to every list this splices rather than only to the ones where a
      # step could still change something. Which steps run after generation is a
      # fact about where `steps/1` puts generation, and a rule resting on that
      # would quietly stop being true the next time the placement moves.
      after_tar = fn release -> release end
      pack = fn release -> release end

      assert [_pre, :assemble, _post, _relup, :tar, ^after_tar, late] =
               Forecastle.steps([:assemble, :tar, after_tar])

      assert late == (&Forecastle.refuse_late_upgrade_from/1)

      # Including where the caller placed generation itself and there is no
      # `:tar` for it to precede: the packing step still runs after it.
      assert [_pre, :assemble, _post, _relup, ^pack, ^late] =
               Forecastle.steps([:assemble, &Forecastle.generate_relup/1, pack])

      # And on the plainest list of all, where nothing can change the option and
      # the step is a no-op that costs a call.
      assert [_pre, :assemble, _post, _relup, :tar, ^late] = Forecastle.steps()
    end

    test "is a no-op when there is no assemble step" do
      assert Forecastle.steps([:tar]) == [:tar]
    end
  end

  describe "refuse_late_upgrade_from/1" do
    test "refuses baselines with no record that pre-assembly resolved them" do
      # The hole adversarial review found, and the reason a missing record is not
      # read here as "pre-assembly never ran, so there is nothing to do". A caller
      # step can write the option by replacing the release options rather than
      # rewriting them, which adds the baseline and deletes the record in one
      # move - so a check lenient about the absence let exactly the build this
      # exists to refuse through to exit 0.
      #
      # This release is also the *other* thing that shape can be: a step may have
      # replaced the options carrying the specs pre-assembly did resolve, and
      # nothing here can tell the two apart. So the message says the record is
      # missing rather than that the baselines were never resolved, which would
      # be false in that case - and asserting on the wording is what keeps a
      # refusal that cannot know from claiming it does.
      release = release(upgrade_from: ["rel:some/release/releases/1.0.0/sample"])

      error =
        assert_raise Mix.Error, fn ->
          Forecastle.refuse_late_upgrade_from(release)
        end

      assert error.message =~ "no record that this is the option"
      refute error.message =~ "never resolved"
      assert error.message =~ "rel:some/release/releases/1.0.0/sample"
      assert error.message =~ "before :assemble"
    end

    test "leaves a release with no record and no baselines alone" do
      # The other side of that, and the line is where this module always puts it:
      # ask the release, not the bookkeeping. A build naming no baselines produces
      # nothing wrong whatever became of a private key, and a release that says
      # nothing about upgrading has to assemble exactly as it did before any of
      # this existed. Refusing here failed builds with nothing to do with relups,
      # which is the objection that made `refuse_unpackaged_relup/1` a step.
      release = release([])

      assert Forecastle.refuse_late_upgrade_from(release) == release
    end

    test "passes an option that is the one pre-assembly resolved" do
      specs = ["rel:some/release/releases/1.0.0/sample"]

      release =
        release(
          upgrade_from: specs,
          forecastle_upgrade_from: {:baselines, specs}
        )

      assert Forecastle.refuse_late_upgrade_from(release) == release
    end

    test "passes a release that named nothing and still names nothing" do
      release = release(forecastle_upgrade_from: :none)

      assert Forecastle.refuse_late_upgrade_from(release) == release
    end

    test "refuses a baseline a step added after pre-assembly, and names the remedy" do
      # The shape #40 is about: the option is resolved before `:assemble` and
      # read at generation, so one that arrives afterwards is either too late to
      # be generated from or too late to be packaged. The message has to carry
      # both halves of the difference and where to put the option instead, since
      # a project reaching this has a step that works and a placement that does
      # not.
      release =
        release(
          upgrade_from: ["rel:some/release/releases/1.0.0/sample"],
          forecastle_upgrade_from: :none
        )

      error =
        assert_raise Mix.Error, fn ->
          Forecastle.refuse_late_upgrade_from(release)
        end

      assert error.message =~ "named no baselines"
      assert error.message =~ "rel:some/release/releases/1.0.0/sample"
      assert error.message =~ "before :assemble"
    end

    test "refuses a baseline list a step rewrote into a different one" do
      release =
        release(
          upgrade_from: ["rel:b/releases/1.0.0/sample"],
          forecastle_upgrade_from: {:baselines, ["rel:a/releases/1.0.0/sample"]}
        )

      assert_raise Mix.Error, ~r/changed while the build was running/, fn ->
        Forecastle.refuse_late_upgrade_from(release)
      end
    end

    test "refuses an option a step took away as readily as one it added" do
      # A build that asked for an upgrade plan, had its baselines resolved, and
      # then dropped the option is not a release that says nothing about
      # upgrading - it is one whose answer changed. Every difference is refused,
      # which is what makes this the same comparison at both positions.
      release = release(forecastle_upgrade_from: {:baselines, ["rel:a/releases/1.0.0/sample"]})

      assert_raise Mix.Error, ~r/changed while the build was running/, fn ->
        Forecastle.refuse_late_upgrade_from(release)
      end
    end

    test "refuses a malformed option for what is wrong with the option" do
      # `upgrade_from!/1` rather than a comparison of raw values, so a step that
      # left the option naming nothing is told that rather than being told its
      # answer changed - the same call `refuse_unpackaged_relup/1` makes.
      release = release(upgrade_from: [], forecastle_upgrade_from: :none)

      assert_raise Mix.Error, ~r/upgrade_from: names no baselines/, fn ->
        Forecastle.refuse_late_upgrade_from(release)
      end
    end
  end

  describe "refuse_unpackaged_relup/1" do
    test "does nothing when the release asks for no relup" do
      # The reason this is a step rather than a refusal inside `steps/1`.
      # `generate_relup/1` without `upgrade_from:` does nothing at all -
      # documented, and the release assembles exactly as it would without the
      # step - so a project whose steps put it after `:tar` and never asks for a
      # relup has nothing wrong with what it produces, including one packaging a
      # hand-written `relup`. `steps/1` is handed a list and cannot tell; this
      # can, because it is handed the release.
      release = release([])

      assert Forecastle.refuse_unpackaged_relup(release) == release
    end

    test "names the placement when the release does ask for one" do
      assert_raise Mix.Error, ~r/after :tar/, fn ->
        Forecastle.refuse_unpackaged_relup(
          release(upgrade_from: ["rel:some/release/1.0.0/sample"])
        )
      end
    end

    test "refuses a malformed option for what is wrong with the option" do
      # `upgrade_from!/1` rather than a bare presence check, so a release naming
      # nothing is told that rather than being told where its steps sit - the
      # placement is not the first thing wrong with such a build.
      assert_raise Mix.Error, ~r/upgrade_from: names no baselines/, fn ->
        Forecastle.refuse_unpackaged_relup(release(upgrade_from: []))
      end
    end
  end

  describe "pre_assemble/1" do
    setup do
      release = %Mix.Release{
        name: :sample,
        version: "1.2.3",
        config_providers: [{Config.Reader, "/nowhere/provider.exs"}],
        boot_scripts: %{start_clean: [kernel: :permanent, stdlib: :permanent]},
        options: []
      }

      {:ok, release: release, assembled: Forecastle.pre_assemble(release)}
    end

    test "refuses to carry a staged relup it did not stage itself" do
      # Mix keeps release options it does not recognise, so without dropping
      # this key first a project that had set it would have had its value
      # written out as the release's upgrade plan, unchecked. A release of its
      # own rather than the one from setup: what is under test is what
      # pre_assemble does with an option it finds already there.
      refute File.exists?(Path.join(File.cwd!(), "relup")),
             "this test assumes the project has no relup of its own"

      release = %Mix.Release{
        name: :sample,
        version: "1.2.3",
        config_providers: [],
        boot_scripts: %{start_clean: [kernel: :permanent, stdlib: :permanent]},
        options: [forecastle_relup: "not a plan"]
      }

      options = release |> Forecastle.pre_assemble() |> Map.fetch!(:options)

      assert Keyword.fetch(options, :forecastle_relup) == :error
    end

    test "leaves the config providers with Mix", %{release: release, assembled: assembled} do
      # They used to be taken away here and replayed into the release's
      # configuration afterwards, with their init arguments rewritten into a
      # keyword list on the way through. Mix initialises them itself, with
      # whatever term the project declared, and nothing here has an opinion.
      assert assembled.config_providers == release.config_providers
    end

    test "says nothing about runtime configuration", %{assembled: assembled} do
      # Setting :runtime_config_path to false is what used to stop Mix expanding
      # runtime configuration at all, so that Castle could do it at boot instead.
      refute Keyword.has_key?(assembled.options, :runtime_config_path)
    end

    test "stashes nothing under its own key", %{assembled: assembled} do
      # The accumulator the stripped providers were collected in. Nothing reads
      # it any more, so nothing may write it either: Mix carries release options
      # it does not recognise straight into the assembled release.
      refute Keyword.has_key?(assembled.options, Forecastle)
    end

    test "adds a preboot script that can start Castle", %{assembled: assembled} do
      # The script Castle's peer boots to work out the configuration of the
      # version being installed.
      preboot = assembled.boot_scripts[:preboot]

      assert preboot[:kernel] == :permanent
      assert preboot[:stdlib] == :permanent

      for app <- [:sasl, :compiler, :elixir, :castle] do
        assert preboot[app] == :permanent, "expected #{app} in the preboot script"
      end
    end

    test "leaves the start_clean script alone", %{assembled: assembled} do
      assert assembled.boot_scripts[:start_clean] == [kernel: :permanent, stdlib: :permanent]
    end

    test "refuses an upgrade_from: that names nothing, before anything is assembled" do
      # Here as well as in `generate_relup/1`, and that is the point of it being
      # here: `:assemble` has not run, so nothing has created the version
      # directory that a retry without `--overwrite` would then decline to
      # overwrite. The same reasoning as the project-root relup's own check.
      assert_raise Mix.Error, ~r/upgrade_from: names no baselines/, fn ->
        Forecastle.pre_assemble(release(upgrade_from: []))
      end
    end

    test "carries a usable upgrade_from: through, and resolves it" do
      refute File.exists?(Path.join(File.cwd!(), "relup")),
             "this test assumes the project has no relup of its own"

      # `rel:` names an assembled release and deliberately touches no
      # filesystem, so it is the one source that resolves without anything on
      # disk - which is what makes this assertion about carrying the option
      # rather than about resolving a real baseline.
      specs = ["rel:some/release/releases/1.0.0/sample"]
      assembled = Forecastle.pre_assemble(release(upgrade_from: specs))

      # The option is read here and used two steps later, so pre-assembly must
      # neither consume it nor rewrite it. `generate_relup/1` reads it out of
      # `options` again rather than being handed anything.
      assert assembled.options[:upgrade_from] == specs

      # And the resolution it did is carried forward, so that the step does not
      # have to do it again after `:assemble` has created the version directory.
      assert assembled.options[:forecastle_baselines] == %{
               "rel:some/release/releases/1.0.0/sample" => "some/release/releases/1.0.0/sample"
             }

      # And what it *read* is recorded beside what that resolved to, which is
      # what `refuse_late_upgrade_from/1` compares a later answer against. The
      # resolved map cannot stand in for it: that is keyed by spec, so it answers
      # for a set rather than for the list the project wrote.
      assert assembled.options[:forecastle_upgrade_from] == {:baselines, specs}
    end

    test "records that the release named nothing, rather than recording nothing" do
      # The two things a missing record would have to mean at once: a release
      # that named no baselines, and a build where `pre_assemble/1` never ran.
      # Only the first is a refusal when a later step names something, so the
      # `:none` branch writes the record too.
      assembled = Forecastle.pre_assemble(release([]))

      assert assembled.options[:forecastle_upgrade_from] == :none
    end

    test "refuses to carry a record of its own that it did not write" do
      # Mix carries release options it does not recognise straight into the
      # assembled release, so a project that had set this key would otherwise
      # decide what a later step is compared against. Dropped unconditionally,
      # for the same reason the baselines key is.
      assembled =
        Forecastle.pre_assemble(
          release(forecastle_upgrade_from: {:baselines, ["rel:invented/by/the/project"]})
        )

      assert assembled.options[:forecastle_upgrade_from] == :none
    end

    test "resolves the baselines before anything is assembled" do
      # The largest thing this feature can fail at, moved to the last moment at
      # which failing is free. A `tar:` naming no artefact used to raise from the
      # generation step - after `:assemble` had created the version directory,
      # which Mix does not tidy up and will not overwrite unasked, so the
      # corrected retry exits 0 having assembled nothing.
      assert_raise Mix.Error, ~r/which is not a file that can be read/, fn ->
        Forecastle.pre_assemble(release(upgrade_from: ["tar:nowhere/sample-1.0.0.tar.gz"]))
      end
    end

    test "stashes nothing under the baselines key when there is no option" do
      # Mix carries release options it does not recognise straight into the
      # assembled release, so a project that had set this key would otherwise
      # have its value used as the resolved baselines. Dropped unconditionally,
      # for the same reason `stage_relup/1` drops its own.
      assembled = Forecastle.pre_assemble(release(forecastle_baselines: %{"x" => "y"}))

      refute Keyword.has_key?(assembled.options, :forecastle_baselines)
    end

    test "refuses a malformed spec before anything is assembled" do
      # The grammar is settleable without touching the filesystem, so it is
      # settled here. Left to resolution, a mistyped prefix would fail *after*
      # `:assemble` had created the version directory - and Mix does not tidy up
      # after a step that raised, so the corrected retry finds it, declines to
      # overwrite, and exits 0 having assembled nothing.
      for spec <- ["", "tar:", "nope:v1.0.0"] do
        assert_raise Mix.Error, fn ->
          Forecastle.pre_assemble(release(upgrade_from: [spec]))
        end
      end
    end
  end

  describe "generate_relup/1" do
    @describetag :tmp_dir

    test "does nothing at all when the release names no baselines", %{tmp_dir: tmp_dir} do
      # The documented no-op, and the reason the empty list is not folded into
      # it: a release that says nothing about upgrading is assembled exactly as
      # it was before this step existed. Asserting the *directory* rather than
      # the return value is what says nothing was written.
      release = release(version_path: tmp_dir)

      assert Forecastle.generate_relup(release) == release
      assert File.ls!(tmp_dir) == []
    end

    test "refuses an upgrade_from: that names nothing", %{tmp_dir: tmp_dir} do
      # `upgrade_from: []` is a build asking for an upgrade plan and naming
      # nothing to generate one against - a list read out of the environment, or
      # computed down to nothing. Assembling it in silence would leave a release
      # with no relup in it and nothing said, which is the outcome this whole
      # step exists to produce the opposite of.
      release = release(version_path: tmp_dir, upgrade_from: [])

      assert_raise Mix.Error, ~r/upgrade_from: names no baselines/, fn ->
        Forecastle.generate_relup(release)
      end

      assert File.ls!(tmp_dir) == []
    end

    test "refuses a single spec written as a string rather than a list", %{tmp_dir: tmp_dir} do
      release = release(version_path: tmp_dir, upgrade_from: "tar:sample-0.1.0.tar.gz")

      assert_raise Mix.Error, ~r/takes a list of baseline specs/, fn ->
        Forecastle.generate_relup(release)
      end
    end

    test "refuses a list element that is not a spec", %{tmp_dir: tmp_dir} do
      # A charlist arrives here as a list of integers, so `is_list/1` alone is
      # not the check: what makes a list a list of specs is its elements.
      release = release(version_path: tmp_dir, upgrade_from: [~c"tar:sample-0.1.0.tar.gz"])

      assert_raise Mix.Error, ~r/takes baseline specs as strings/, fn ->
        Forecastle.generate_relup(release)
      end
    end

    test "names the target it could not read before resolving anything", %{tmp_dir: tmp_dir} do
      # The target is Mix's own output at this point in the steps list, so this
      # is only reachable through a hand-written steps list that put the step
      # somewhere else - and then the failure has to name the file rather than
      # arrive as something about a baseline. It also pins the ordering:
      # resolving a baseline can mean unpacking an artefact or building a git
      # ref, and doing minutes of that before noticing the target is not there
      # is the wrong order to fail in.
      release = release(version_path: tmp_dir, upgrade_from: ["tar:/nowhere/sample.tar.gz"])

      assert_raise Mix.Error, ~r|#{Path.join(tmp_dir, "sample.rel")} could not be read|, fn ->
        Forecastle.generate_relup(release)
      end
    end

    test "reads a missing record as a step list without pre-assembly", %{tmp_dir: tmp_dir} do
      # The other half of the strictness `refuse_late_upgrade_from/1` has about
      # the same absence, and the reason the two are not one function. This step
      # is reachable without `pre_assemble/1` - a caller who placed it before
      # `:assemble` - and `read_rel!/1` already answers that by naming the file
      # it could not read. A second refusal here would be the same decision made
      # in two places, which is what this module declines to do elsewhere.
      #
      # The assertion is which failure comes out: the target, not the record.
      release = release(version_path: tmp_dir, upgrade_from: ["rel:some/release/1.0.0/sample"])

      error =
        assert_raise Mix.Error, fn ->
          Forecastle.generate_relup(release)
        end

      assert error.message =~ "could not be read"
      refute error.message =~ "no record that this is the option"
    end

    test "resolves afresh when the staged baselines do not cover the option", %{
      tmp_dir: tmp_dir
    } do
      # A stash that does not answer for every spec is discarded rather than
      # indexed into: generate!/7 looks specs up with Map.fetch!/2, so a missing
      # one would arrive as a KeyError naming a map rather than as anything an
      # author could act on.
      #
      # This used to be how a step that added a baseline mid-build was
      # accommodated. That is now refused outright - see
      # refuse_late_upgrade_from/1 - so what is left here is a guard: a steps
      # list that reached generation without pre_assemble/1 has no stash and no
      # record either, and a caller's step could leave something behind that is
      # not a map at all. This release is the first of those, having no record.
      #
      # The target has to be readable for this to assert anything: reading it
      # comes first, so a test with no `.rel` here would raise the same Mix.Error
      # whether the stash was trusted or not. With one in place the run reaches
      # the lookup, and *which* failure comes out is the assertion - a trusted
      # stash raises KeyError from Map.fetch!/2, a rejected one re-resolves and
      # reports the artefact it could not read.
      File.write!(
        Path.join(tmp_dir, "sample.rel"),
        ~s({release, {"sample", "1.2.3"}, {erts, "16.2"}, []}.\n)
      )

      release =
        release(
          version_path: tmp_dir,
          upgrade_from: ["tar:/nowhere/sample.tar.gz"],
          forecastle_baselines: %{"tar:/somewhere/else.tar.gz" => "/somewhere/else"}
        )

      assert_raise Mix.Error, ~r/which is not a file that can be read/, fn ->
        Forecastle.generate_relup(release)
      end
    end

    test "refuses an option a step changed, before reading the target", %{tmp_dir: tmp_dir} do
      # The first of the two positions the comparison runs at, and the cheap one:
      # a build that changed the option is refused before the target's `.rel` is
      # read and before any baseline is resolved, which can mean unpacking an
      # artefact or building a git ref.
      #
      # The ordering is the assertion. There is no `sample.rel` in `tmp_dir`, so
      # a run that reached the target first would raise about the file it could
      # not read, and that is the failure this has to come in front of.
      release =
        release(
          version_path: tmp_dir,
          upgrade_from: ["tar:/nowhere/sample.tar.gz"],
          forecastle_upgrade_from: :none
        )

      assert_raise Mix.Error, ~r/changed while the build was running/, fn ->
        Forecastle.generate_relup(release)
      end

      assert File.ls!(tmp_dir) == []
    end

    test "generates from an option that is the one pre-assembly resolved", %{tmp_dir: tmp_dir} do
      # The ordinary path, and the one the refusal must not stand in front of: a
      # record that agrees with the option is not a change, so the step goes on
      # to do its work. It gets as far as the target it cannot read, which is the
      # next thing wrong with this release and the evidence that the comparison
      # let it through.
      specs = ["tar:/nowhere/sample.tar.gz"]

      release =
        release(
          version_path: tmp_dir,
          upgrade_from: specs,
          forecastle_upgrade_from: {:baselines, specs}
        )

      assert_raise Mix.Error, ~r|#{Path.join(tmp_dir, "sample.rel")} could not be read|, fn ->
        Forecastle.generate_relup(release)
      end
    end

    test "refuses a second upgrade_from: rather than taking the first", %{tmp_dir: tmp_dir} do
      # `Mix.Release` keeps options it does not recognise in the keyword list it
      # was given, and `Keyword.merge/2` preserves duplicate keys within the list
      # merged in - so a release definition built by joining lists really can
      # carry two. Taking the first would generate against baselines the project
      # did not settle on, with nothing said about the ones dropped.
      release =
        release([
          {:version_path, tmp_dir},
          {:upgrade_from, ["tar:a.tar.gz"]},
          {:upgrade_from, ["tar:b.tar.gz"]}
        ])

      assert_raise Mix.Error, ~r/upgrade_from: was given 2 times/, fn ->
        Forecastle.generate_relup(release)
      end

      assert File.ls!(tmp_dir) == []
    end

    test "refuses a duplicate that would otherwise have been the ignored one", %{
      tmp_dir: tmp_dir
    } do
      # The order that matters most: a first occurrence that resolves and a
      # second that is a refusal on its own. `Keyword.fetch/2` would have taken
      # the first, generated a relup, and never seen that the project also asked
      # for something impossible.
      release =
        release([
          {:version_path, tmp_dir},
          {:upgrade_from, ["tar:a.tar.gz"]},
          {:upgrade_from, []}
        ])

      assert_raise Mix.Error, ~r/upgrade_from: was given 2 times/, fn ->
        Forecastle.generate_relup(release)
      end

      assert File.ls!(tmp_dir) == []
    end
  end

  defp release(options) do
    {release_options, struct_options} =
      Keyword.split(options, [:upgrade_from, :forecastle_baselines, :forecastle_upgrade_from])

    struct!(
      %Mix.Release{
        name: :sample,
        version: "1.2.3",
        config_providers: [],
        boot_scripts: %{start_clean: [kernel: :permanent, stdlib: :permanent]},
        options: release_options
      },
      struct_options
    )
  end
end
