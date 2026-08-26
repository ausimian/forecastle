defmodule ForecastleTest do
  use ExUnit.Case, async: true

  doctest Forecastle

  describe "steps/1" do
    test "wraps the assemble step" do
      assert [pre, :assemble, post, relup, :tar] = Forecastle.steps()
      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "puts relup generation after post-assembly and before :tar" do
      # The position is the whole of what makes generation possible: before
      # `:assemble` there is no `<name>.rel` and no populated `lib/` to generate
      # from, and after `:tar` the archive has already been packed without it.
      # Asserting the list in order is what catches a splice that put the step
      # somewhere it would find nothing or change nothing.
      assert [_pre, :assemble, _post, relup, :tar] = Forecastle.steps()
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "preserves the caller's own steps around the injected ones" do
      before_step = fn release -> release end
      after_step = fn release -> release end

      assert [^before_step, pre, :assemble, post, relup, :tar, ^after_step] =
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

      assert [pre, :assemble, post, ^custom, relup, :tar] =
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

      assert [_pre, :assemble, _post, ^custom, relup] = Forecastle.steps([:assemble, custom])
      assert relup == (&Forecastle.generate_relup/1)
    end

    test "is a no-op when there is no assemble step" do
      assert Forecastle.steps([:tar]) == [:tar]
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

    test "resolves afresh when the staged baselines do not cover the option", %{
      tmp_dir: tmp_dir
    } do
      # Two steps and any function step of the project's own run between the
      # resolution in pre-assembly and its use here, and a Mix.Release is theirs
      # to rewrite. A stash that no longer answers for every spec is therefore
      # discarded rather than indexed into: generate!/6 looks specs up with
      # Map.fetch!/2, so a missing one would arrive as a KeyError naming a map.
      # Re-resolving is also the correct branch, not merely the safe one - what
      # the option says now is what the relup should be generated from.
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
      Keyword.split(options, [:upgrade_from, :forecastle_baselines])

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
