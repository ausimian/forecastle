defmodule Forecastle.AssemblyRelupTest do
  @moduledoc """
  Assembles the sample fixture with `upgrade_from:` set and asserts on the relup
  a single `mix release` leaves behind.

  This is the half of relup generation that `Forecastle.RelupTest` cannot reach.
  That suite drives `mix castle.relup` over releases that already exist; what is
  under test here is the step between `post_assemble` and `:tar`, which is the
  one point in a build where `version_path`, `<name>.rel` and a populated `lib/`
  all exist. So the assertions are about a build rather than about a command: a
  relup in the version path, that relup inside the tarball, and a non-zero exit
  where there is something to refuse.

  **What the option does when it names nothing is as much a part of the contract
  as what it does when it names something**, and the two cases are deliberately
  different. An absent `upgrade_from:` is a documented no-op - the baseline
  assembled in `setup_all` is the evidence, and it is asserted rather than
  assumed. An `upgrade_from: []` is a build asking for an upgrade plan and naming
  nothing to generate one against, and it is refused. Collapsing the second into
  the first would assemble a release with no relup in it and say nothing, which
  is the failure this step exists to remove rather than to reproduce.

  The refusals divide by where they fire, and it is worth knowing which is which
  when one of these fails. A malformed option is refused in `pre_assemble/1`,
  before `:assemble` has created anything - that is the same placement, and the
  same reasoning, as the project-root relup's own check. A baseline that cannot
  be resolved or read is only knowable afterwards, so those runs assemble first
  and fail with the version directory already on disk.

  The fixture sets the option directly rather than through `Castle.customize/2`:
  Forecastle reads it out of the release options itself, and this half has to be
  testable without Castle's API.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # A relup names its versions as charlists, and only a literal can stand in the
  # pattern that reads one back.
  @from_vsn to_charlist(@from)
  @to_vsn to_charlist(@to)

  setup_all do
    from = assemble!(into: "assembly-relup-from", vsn: @from)

    {generated, output} =
      assemble_with!(
        "assembly-relup-to",
        "tar:" <> Path.join(from, "sample-#{@from}.tar.gz")
      )

    {:ok, from: from, generated: generated, output: output}
  end

  describe "a release that names its baselines" do
    test "writes the relup into the version path", %{generated: generated} do
      # Both directions from the one spec. `upgrade_from:` names the releases
      # this one can be upgraded *from*, and a plan that cannot be rolled back is
      # not much of an upgrade plan, so every baseline gets what `--fromto`
      # gives it rather than what `--upfrom` does.
      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(relup_path(generated)))
    end

    test "packages it in the tarball", %{generated: generated} do
      # The point of generating here rather than between two builds: `:tar` packs
      # the version directory, so a relup written into it during the same
      # `mix release` is in the artefact a deployment is handed. Nothing has to
      # be assembled a second time to pick it up.
      assert {:ok, members} =
               :erl_tar.table(to_charlist(tarball(generated, @to)), [:compressed])

      assert ~c"releases/#{@to}/relup" in members
    end

    test "generates under auto, and says what it decided", %{output: output} do
      # `auto` is the strategy the step generates under, and it is the one that
      # announces. The line is what says the classification really ran over this
      # transition rather than a relup having appeared from somewhere.
      assert output =~ "auto: every transition in this relup is a hot upgrade."
    end

    test "leaves a release that names none exactly as it was", %{from: from} do
      # The documented no-op, asserted on the baseline this suite had to build
      # anyway. A release that says nothing about upgrading is assembled the way
      # it was before this step existed - and that is why the empty list below
      # cannot be folded into the same silence.
      refute File.exists?(relup_path(from, @from))
    end

    test "generates from the tree a caller step left behind, not the one before it",
         %{from: from} do
      # `mix release` documents a function step between `:assemble` and `:tar` as
      # the way to customise an assembled release, so such a step can change what
      # the relup is generated from. The fixture's is `remove_dep_appup/1`, which
      # deletes the dependency's appup - the file `auto` consults to decide
      # whether that application's version change can be hot.
      #
      # So the placement is *observable in the relup itself*: generated before
      # the step, `auto` finds the appup and writes a hot script; generated after
      # it, the edge becomes `restart_emulator`. This asserts the second. It is
      # the regression test for a splice that put generation immediately after
      # post-assembly, where it described a tree that `:tar` then packaged
      # differently.
      {generated, output} =
        assemble_with!(
          "assembly-relup-custom",
          "rel:" <> rel(from, @from),
          [{"SAMPLE_STEPS", "custom"}]
        )

      assert {:ok,
              [
                {@to_vsn, [{@from_vsn, [], [:restart_emulator]}],
                 [{@from_vsn, [], [:restart_emulator]}]}
              ]} = :file.consult(to_charlist(relup_path(generated)))

      # And the run says so, rather than announcing a hot upgrade it did not
      # generate. `refute` on the all-hot line matters as much as the assertion:
      # that line is what a relup generated too early would have printed.
      assert output =~ "auto made a restart transition of"
      refute output =~ "every transition in this relup is a hot upgrade"
    end
  end

  describe "refusing before the release is assembled" do
    test "an upgrade_from: that names nothing" do
      {output, path} = assemble_failure!("assembly-relup-empty", "empty")

      assert output =~ "upgrade_from: names no baselines"

      # Refused in `pre_assemble/1`, so Mix has created nothing yet. A refusal
      # after `:assemble` leaves a version directory that a corrected retry
      # without `--overwrite` declines to overwrite, and that retry then exits 0
      # having assembled nothing at all.
      refute File.exists?(path), "a refused option left a partial release behind"
    end

    test "a single spec written as a string rather than a list" do
      {output, path} = assemble_failure!("assembly-relup-bare", "bare:tar:sample-#{@from}.tar.gz")

      assert output =~ "takes a list of baseline specs"
      refute File.exists?(path)
    end

    test "a hand-written relup beside upgrade_from:, naming both", %{from: from} do
      # Two upgrade plans for one release, arrived at two ways, and only one file
      # can be in the version path. Which of them got discarded would be
      # invisible in the assembled release, so this refuses rather than ordering
      # them by precedence.
      relup = Path.join(Fixture.workspace(), "relup")
      on_exit(fn -> File.rm(relup) end)
      File.write!(relup, ~s({"#{@to}", [], []}.\n))

      {output, path} =
        assemble_failure!(
          "assembly-relup-both",
          "rel:" <> rel(from, @from)
        )

      assert output =~ relup
      assert output =~ "upgrade_from:"
      refute File.exists?(path)
    end
  end

  describe "refusing a baseline that resolves to nothing" do
    test "names the release file it could not read" do
      # The shape of a defect this project has already had once: a `rel:` spec
      # that resolves to somewhere real enough to read and holding none of the
      # applications being compared. `Forecastle.Baseline` touches no filesystem
      # for `rel:`, deliberately, because the caller is what reads the release -
      # so this is where such a spec has to be answered, and it has to be
      # answered by name.
      {output, path} = assemble_failure!("assembly-relup-missing", "rel:/nope/sample")

      assert output =~ "/nope/sample.rel could not be read as a release file"
      refute File.exists?(relup_path(path)), "a refused baseline still produced a relup"
    end

    test "refuses a baseline whose library directory holds no applications" do
      # The same failure one level further in, and the one that is worth a real
      # fixture: the release file reads, so nothing about the spec looks wrong,
      # and what is missing is every application it names. A directory that
      # merely exists is not a build, and a relup generated against one would
      # describe a transition from a release that never existed.
      hollow = hollow_baseline!()

      {output, path} = assemble_failure!("assembly-relup-hollow", "rel:" <> hollow)

      # `:systools`' own refusal, and asserting *which* one matters. It searched,
      # found only the target release's copy of each application, and refused on
      # the version rather than comparing against it - and it names every
      # application the baseline lists, which is what says none was passed over.
      # A test content with a non-zero exit would go on passing if this became
      # some other failure, or if the refusal moved somewhere that reported one
      # application and skipped the rest.
      assert output =~ "sample: No valid version (\"#{@from}\") of .app file found"
      assert output =~ "sample_dep: No valid version (\"#{@from}\") of .app file found"

      refute File.exists?(relup_path(path)), "an empty baseline still produced a relup"
    end

    test "leaves the assembled release in place, and --overwrite is the way back",
         %{from: from} do
      # What a failure that can only happen *after* `:assemble` costs, pinned
      # rather than left to be discovered. Asking `:systools` needs the assembled
      # target, so this one has nowhere earlier to go - unlike the option shape,
      # the spec grammar and baseline resolution, which all now happen in
      # `pre_assemble/1` precisely so that they never reach this state.
      #
      # Mix does not tidy up after a step of its own that raised, and whether it
      # re-assembles at all is decided *before* any step runs, so nothing
      # Forecastle does can make a plain retry rebuild. `--overwrite` is the
      # remedy, and this is the test that says so.
      hollow = hollow_baseline!()
      path = Path.join(Fixture.workspace(), "assembly-relup-retry")

      File.rm_rf!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      {output, status} = mix(["release", "sample", "--path", path], env("rel:" <> hollow))
      assert status != 0, "the first attempt was expected to fail:\n\n#{output}"

      # The release is there, minus the relup: the failure happened after
      # assembly and before publication.
      assert File.dir?(Path.join([path, "releases", @to]))
      refute File.exists?(relup_path(path))

      # The same path, not pre-cleaned, with a baseline that resolves.
      {output, status} =
        mix(
          ["release", "sample", "--overwrite", "--path", path],
          env("rel:" <> rel(from, @from))
        )

      assert status == 0, "the retry failed:\n\n#{output}"

      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(relup_path(path)))

      assert {:ok, members} = :erl_tar.table(to_charlist(tarball(path, @to)), [:compressed])
      assert ~c"releases/#{@to}/relup" in members
    end
  end

  # A release file with nothing behind it: the baseline's own `.rel`, and a
  # library directory that exists and is empty. Built here rather than by
  # emptying a real release, so that it cannot depend on which files a build
  # happens to leave.
  defp hollow_baseline! do
    root = Path.join(Fixture.workspace(), "assembly-relup-hollow-baseline")
    version_dir = Path.join([root, "releases", @from])

    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(version_dir)
    File.mkdir_p!(Path.join(root, "lib"))

    File.cp!(
      rel(Path.join(Fixture.workspace(), "assembly-relup-from"), @from) <> ".rel",
      Path.join(version_dir, "sample.rel")
    )

    Path.join(version_dir, "sample")
  end

  defp assemble_with!(into, specs, extra_env \\ []) do
    workspace = Fixture.workspace()
    path = Path.join(workspace, into)

    File.rm_rf!(path)
    output = mix!(["release", "sample", "--overwrite", "--path", path], env(specs) ++ extra_env)

    {path, output}
  end

  # `mix/2` rather than `mix!/2`: assembly is meant to fail here, and what it
  # says while failing is the thing under test.
  defp assemble_failure!(into, specs) do
    workspace = Fixture.workspace()
    path = Path.join(workspace, into)

    File.rm_rf!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {output, status} = mix(["release", "sample", "--overwrite", "--path", path], env(specs))

    assert status != 0, "assembly was expected to fail:\n\n#{output}"
    {output, path}
  end

  defp env(specs) do
    [
      {"SAMPLE_VSN", @to},
      {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{@to}")},
      {"SAMPLE_UPGRADE_FROM", specs}
    ]
  end

  defp relup_path(release, vsn \\ @to), do: Path.join([release, "releases", vsn, "relup"])

  defp rel(release, vsn), do: Path.join([release, "releases", vsn, "sample"])

  defp tarball(release, vsn), do: Path.join(release, "sample-#{vsn}.tar.gz")
end
