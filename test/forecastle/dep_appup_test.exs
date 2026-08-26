defmodule Forecastle.DepAppupTest do
  @moduledoc """
  The appups a project supplies for its dependencies, against real assemblies.

  **The fixture's dependency is built shipping no appup of its own**, which is
  what makes any of this measurable. With `dep/appup.exs` in place `auto` already
  calls the edge hot, so a project-supplied appup would be indistinguishable from
  the one it replaced - and the state this feature exists for is the one a
  dependency taken from Hex is almost always in: a version that moved, and no
  instructions for it anywhere. `SAMPLE_DEP_APPUP=none` is that state.

  **The acceptance criterion is wired in rather than eyeballed.** The same
  transition is assembled twice, with a project-supplied appup and without, and
  `mix castle.relup` is run over both: without one `auto` says the edge is a
  restart and names the missing file, with one it says every transition is a hot
  upgrade and the relup carries a `load_object_code` for the dependency. A suite
  that only read the placed file back and agreed with itself would not notice a
  placement `:systools` never consults.

  Every refusal here is a *build* that fails, and each asserts that the release
  directory was never created - because all of them are made before `:assemble`.
  That is not incidental: `Forecastle` says at length why a refusal after
  assembly turns a corrected retry into a green build that assembled nothing.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # The same two as charlists, for the appup and relup terms that are matched on
  # rather than searched in. A pattern cannot interpolate.
  @from_vsn ~c"0.1.0"
  @to_vsn ~c"0.1.1"

  # A dependency in the state this feature is for: its version moves and it ships
  # no appup at all.
  @bare_dep [{"SAMPLE_DEP_APPUP", "none"}]

  # **A build root of this suite's own, which one of the assertions rests on.**
  # Every other suite shares `_build-<vsn>` and builds the fixture with the
  # dependency shipping its own appup, so a `sample_dep.appup` in there is
  # ordinarily somebody else's compiler output - and "nothing was written into
  # the shared build" cannot be asserted against a directory somebody else is
  # legitimately writing into. Here nothing builds but this suite, and nothing it
  # builds asks for that appup, so the file being absent means exactly what it
  # says.
  @build_root "_build-dep-appups"

  setup_all do
    # The order here is the whole of the setup. `from` and `bare` are assembled
    # while `rel/appups` is empty - `Forecastle.ReleaseCase` clears it before this
    # runs - because a source named for a transition *to* 0.1.1 is stale in a
    # 0.1.0 build by construction, and `bare` is the control that has to be
    # assembled without one. The source goes in only for `supplied`, and comes out
    # again so that no other suite's assembly meets it.
    {from, _output, 0} = assemble("dep-appup-from", @from)
    {bare, _bare_output, 0} = assemble("dep-appup-bare")

    write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))
    {supplied, _supplied_output, 0} = assemble("dep-appup-supplied")
    clear!()

    {:ok, from: from, bare: bare, supplied: supplied}
  end

  setup do
    on_exit(&clear!/0)
    clear!()
  end

  describe "an appup the project supplies for a dependency" do
    test "keeps the edge hot under auto, where a dependency without one restarts it", ctx do
      # The control first, because "instead of degrading to a restart" is half the
      # claim, and asserting the other half alone would hold just as well if
      # `auto` had never restarted this edge in the first place.
      restarted = relup!(ctx.bare, ctx.from, "dep-appup-bare-relup")

      refute restarted =~ "every transition in this relup is a hot upgrade"
      assert restarted =~ "there is no appup at "
      assert restarted =~ "sample_dep-#{@to}/ebin/sample_dep.appup"

      hot = relup!(ctx.supplied, ctx.from, "dep-appup-supplied-relup")

      assert hot =~ "auto: every transition in this relup is a hot upgrade."
    end

    test "is what :systools generates the transition from", ctx do
      # The announcement is not the artefact. What says the placed appup was
      # *read* rather than merely present is the relup loading the dependency's
      # code - an instruction only that appup could have asked for, and the one
      # the fixture's own dependency appup deliberately never asks for.
      relup!(ctx.supplied, ctx.from, "dep-appup-script")

      relup = Path.join([Fixture.workspace(), "dep-appup-script", "relup"])

      assert {:ok, [{@to_vsn, [{@from_vsn, [], up}], _down}]} = :file.consult(to_charlist(relup))
      assert {:load_object_code, {:sample_dep, @to_vsn, [SampleDep]}} in up
    end

    test "lands in the release, and nothing is written into deps/", ctx do
      placed = Path.join(ctx.supplied, "lib/sample_dep-#{@to}/ebin/sample_dep.appup")

      assert {:ok, [{@to_vsn, [{@from_vsn, [{:load_module, SampleDep}]}], _down}]} =
               :file.consult(to_charlist(placed))

      # The appup belongs to the release being assembled and to nothing else.
      # `deps/` and `_build`'s copy of a dependency are shared by every release
      # built from this tree, so an appup in either is one project's upgrade
      # instructions sitting in somebody else's build.
      assert Path.wildcard(Path.join(Fixture.workspace(), "deps/**/*.appup")) == []

      shared = "#{@build_root}-#{@to}/prod/lib/sample_dep/ebin/sample_dep.appup"

      refute File.exists?(Path.join(Fixture.workspace(), shared))
    end

    test "covers what moved, which is the check's answer rather than this one's", ctx do
      # `mix castle.appup` is the gate this whole tooling falls out of, so the
      # placed appup is put to it - pointed at the assembled release, because that
      # is the only build a dependency's project-supplied appup is ever in.
      {output, status} =
        Fixture.mix(
          [
            "castle.appup",
            "--from",
            "rel:" <> rel(ctx.from, @from),
            "--to",
            "rel:" <> rel(ctx.supplied, @to),
            "--app",
            "sample_dep"
          ],
          env(@to)
        )

      assert status == 0, "mix castle.appup rejected the placed appup:\n\n#{output}"
      assert output =~ "sample_dep"
    end

    test "says what it placed" do
      # A release quietly acquiring upgrade instructions is the shape of thing
      # `design/upgrade-tooling.md` D2 exists to prevent, so a placement is
      # announced. Assembled again here rather than read out of `setup_all`'s
      # output, which nothing keeps.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {_path, output, status} = assemble("dep-appup-announced")

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "* placing rel/appups/sample_dep-#{@from}-#{@to}.exs into "
      assert output =~ "lib/sample_dep-#{@to}/ebin/sample_dep.appup"
    end
  end

  describe "what it refuses, before :assemble has created anything" do
    test "a source named for a version of the application this release does not carry" do
      # The stale case. The dependency moved on and the file did not, and
      # packaging it would hand `release_handler` instructions for a transition
      # this release is not part of.
      {path, output, status} = refuse("sample_dep-#{@from}-0.9.9.exs", source(@from, "0.9.9"))

      assert status != 0, "a stale appup was packaged:\n\n#{output}"
      assert output =~ "is named for a version of sample_dep other than #{@to}"
      assert output =~ "refused rather than left out"
      refute File.exists?(path)
    end

    test "a source for an application this project owns" do
      {path, output, status} = refuse("sample-#{@from}-#{@to}.exs", source(@from, @to))

      assert status != 0, "an appup for the project's own application was placed:\n\n#{output}"
      assert output =~ "is an appup for sample, which this project owns"
      refute File.exists?(path)
    end

    test "a source whose version tag is not the version the release carries" do
      {path, output, status} =
        refuse("sample_dep-#{@from}-#{@to}.exs", source(@from, @to, tag: "0.9.9"))

      assert status != 0, "an appup tagged for another version was placed:\n\n#{output}"
      assert output =~ ~s|is tagged ~c"0.9.9", but sample_dep is #{@to} in this release|
      refute File.exists?(path)
    end

    test "a source whose appup says nothing about the from-version it is named for" do
      {path, output, status} = refuse("sample_dep-0.0.9-#{@to}.exs", source(@from, @to))

      assert status != 0, "a mislabelled appup was placed:\n\n#{output}"
      assert output =~ "is named for a transition from 0.0.9"
      assert output =~ "no entry for 0.0.9 in either direction"
      refute File.exists?(path)
    end

    test "a source that does not evaluate to an appup" do
      {path, output, status} = refuse("sample_dep-#{@from}-#{@to}.exs", ":not_an_appup\n")

      assert status != 0, "something that is not an appup was placed:\n\n#{output}"
      assert output =~ "does not evaluate to an appup"
      refute File.exists?(path)
    end

    test "a file in the directory that is not an appup source at all" do
      # A misspelled extension is the case worth refusing. Passing it over
      # quietly would leave somebody with an appup they wrote, a build that
      # succeeded, and a restart nobody can account for.
      {path, output, status} = refuse("sample_dep-#{@from}-#{@to}.ex", source(@from, @to))

      assert status != 0, "a file that is not an appup source was passed over:\n\n#{output}"
      assert output =~ "is not an appup source"
      assert output =~ "named <app>-<from>-<to>.exs"
      refute File.exists?(path)
    end
  end

  describe "more than one source for one application" do
    test "merges them, in the order the names sort" do
      # A release upgradeable from more than one baseline needs an entry per
      # baseline, and a release has one appup per application to hold them.
      write_source!("sample_dep-0.0.9-#{@to}.exs", source("0.0.9", @to))
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {path, output, status} = assemble("dep-appup-merged")

      assert status == 0, "two sources for one application failed to merge:\n\n#{output}"

      placed = Path.join(path, "lib/sample_dep-#{@to}/ebin/sample_dep.appup")

      assert {:ok, [{@to_vsn, [{~c"0.0.9", _first}, {@from_vsn, _second}], _down}]} =
               :file.consult(to_charlist(placed))
    end

    test "refuses two entries for one from-version, which is where the order decides" do
      # `appup_search_for_version/2` takes the first entry that matches, so which
      # of two entries keyed by the same from-version ran would be settled by the
      # order the file names sort in. That is not something to decide an upgrade
      # with. Both files are legitimate on their own - each is named for a
      # from-version its own appup has an entry for.
      write_source!("sample_dep-0.0.9-#{@to}.exs", source(["0.0.9", @from], @to))
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {path, output, status} = assemble("dep-appup-collision")

      assert status != 0, "two entries for one from-version were packaged:\n\n#{output}"
      assert output =~ "give sample_dep two upgrade entries"
      refute File.exists?(path)
    end
  end

  ## The appup sources this suite writes

  # The instruction is a real one rather than the empty script the fixture's own
  # dependency appup carries, because a `load_module` is what makes the placement
  # visible in the relup: `SampleDep` bakes in a compile-time version tag, so it
  # genuinely differs between the two builds.
  defp source(froms, to, opts \\ []) do
    entries = froms |> List.wrap() |> Enum.map_join(",\n ", &entry/1)

    """
    # Written by Forecastle.DepAppupTest.
    {~c"#{Keyword.get(opts, :tag, to)}", [#{entries}], [#{entries}]}
    """
  end

  defp entry(from), do: ~s|{~c"#{from}", [{:load_module, SampleDep}]}|

  defp write_source!(name, contents) do
    dir = appups_dir()
    File.mkdir_p!(dir)

    path = Path.join(dir, name)
    File.write!(path, contents)

    path
  end

  defp appups_dir, do: Path.join(Fixture.workspace(), "rel/appups")

  defp clear!, do: File.rm_rf!(appups_dir())

  ## Assembling

  # Deliberately not `ReleaseCase.assemble!/1`: every case in the second describe
  # block is a build that has to fail, and a helper which raises on a non-zero
  # exit cannot say what the build printed. It is also what keeps every build
  # this suite makes inside `@build_root`.
  defp assemble(into, vsn \\ @to) do
    path = Path.join(Fixture.workspace(), into)

    File.rm_rf!(path)

    {output, status} = Fixture.mix(["release", "sample", "--overwrite", "--path", path], env(vsn))

    {path, output, status}
  end

  defp refuse(name, contents) do
    write_source!(name, contents)

    assemble("dep-appup-refused")
  end

  ## Generating a relup between two assembled releases

  defp relup!(target, from, into) do
    outdir = Path.join(Fixture.workspace(), into)

    File.rm_rf!(outdir)
    File.mkdir_p!(outdir)
    on_exit(fn -> File.rm_rf!(outdir) end)

    mix!(
      ["castle.relup", "--target", rel(target, @to), "--fromto", rel(from, @from)] ++
        ["--outdir", into],
      env(@to)
    )
  end

  defp rel(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  defp env(vsn) do
    [
      {"SAMPLE_VSN", vsn},
      {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "#{@build_root}-#{vsn}")}
    ] ++ @bare_dep
  end
end
