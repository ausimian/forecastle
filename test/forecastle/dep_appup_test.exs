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

    test "is in place before the relup this build generates, which is what reads it", ctx do
      # `steps/1` runs `post_assemble/1` before `generate_relup/1`, so a release
      # that names its own baselines has the appup by the time `auto` classifies
      # the transition. The ordering is the whole claim: generated first, this
      # same edge is a restart, and the two suites above only exercise the relup
      # a *separate* `mix castle.relup` produces from an already-assembled tree.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {path, output, status} =
        assemble("dep-appup-upgrade-from", @to, [
          {"SAMPLE_UPGRADE_FROM", "rel:" <> rel(ctx.from, @from)}
        ])

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "auto: every transition in this relup is a hot upgrade."

      relup = Path.join([path, "releases", @to, "relup"])

      assert {:ok, [{@to_vsn, [{@from_vsn, [], up}], _down}]} = :file.consult(to_charlist(relup))
      assert {:load_object_code, {:sample_dep, @to_vsn, [SampleDep]}} in up
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

    test "a source keyed on something that is not a regular expression re can compile" do
      # A binary key *is* a regular expression to `appup_search_for_version/2`,
      # which raises rather than returning on a pattern it cannot compile -
      # measured on OTP 28.3. Every question this asks of an entry goes through
      # that function, so an uncompilable key would otherwise come back out of the
      # middle of a build as a bare argument error naming nothing.
      {path, output, status} =
        refuse("sample_dep-#{@from}-#{@to}.exs", regex_source(~S(0\\.1\\.[), @to))

      assert status != 0, "an uncompilable pattern reached the search:\n\n#{output}"
      assert output =~ "which is not a regular expression re can compile"
      refute output =~ "ArgumentError"
      refute File.exists?(path)
    end

    test "a source that does not evaluate to an appup" do
      {path, output, status} = refuse("sample_dep-#{@from}-#{@to}.exs", ":not_an_appup\n")

      assert status != 0, "something that is not an appup was placed:\n\n#{output}"
      assert output =~ "does not evaluate to an appup"
      refute File.exists?(path)
    end

    test "an appup a release overlay put into the assembled tree" do
      # Raised in review, and the one refusal that cannot be made before
      # `:assemble`: Mix copies the applications and *then* copies the release's
      # overlays over them, so an overlay can install upgrade instructions of its
      # own after everything this staged was read. Writing over them is how a
      # supported transition disappears without a word.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))
      write_overlay!("lib/sample_dep-#{@to}/ebin/sample_dep.appup", overlay_appup())

      {_path, output, status} = assemble("dep-appup-overlay")

      assert status != 0, "an overlay's appup was written over:\n\n#{output}"
      assert output =~ "appeared during :assemble"
      assert output =~ "a release overlay is copied over lib/"
    end

    test "a symlink an overlay left where the appup goes, whatever it points at" do
      # Raised in review, and the sharper half of the case above. `File.cp_r!/2`
      # copies a symlink *as a symlink*, so an overlay can leave one here - and
      # reading through it answered about something else: a dangling one read as
      # "no appup here", and one pointing at the dependency's own build appup read
      # back exactly the staged bytes and passed for "Mix copied it". The write
      # would then have followed it, out of the release and into the shared build.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))
      link_overlay!("lib/sample_dep-#{@to}/ebin/sample_dep.appup", "../../../nowhere.appup")

      {_path, output, status} = assemble("dep-appup-overlay-link")

      assert status != 0, "a symlink at the destination was written through:\n\n#{output}"
      assert output =~ "is a symlink rather than the regular file Mix copies an ebin entry as"
      refute File.exists?(Path.join(Fixture.workspace(), "nowhere.appup"))
    end

    test "a rel/appups that is a link to somewhere that is not there" do
      # `File.ls/1` follows a directory symlink, so a checked-in
      # `rel/appups -> ../shared/appups` whose target is missing in CI answers
      # exactly as an absent directory does - and the release would assemble with
      # none of the appups it names, silently, which is the whole failure this
      # feature exists to remove.
      clear!()
      File.ln_s!("../does-not-exist", appups_dir())
      on_exit(&clear!/0)

      {path, output, status} = assemble("dep-appup-dangling-dir")

      assert status != 0, "a dangling rel/appups was read as an empty one:\n\n#{output}"
      assert output =~ "is a link to somewhere that is not there"
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

    test "refuses a regular-expression key that competes with a literal one" do
      # Raised in review, and the case a comparison of key *terms* passes: a
      # binary key is a regular expression to `appup_search_for_version/2`, so
      # these two entries both answer for 0.1.0 without being equal terms - and
      # the earlier-sorting file would have decided which instructions ran.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))
      write_source!("sample_dep-0.1.9-#{@to}.exs", regex_source(~S(0\\.1\\..*), @to))

      {path, output, status} = assemble("dep-appup-regex-collision")

      assert status != 0, "a regex entry competing with a literal was packaged:\n\n#{output}"
      assert output =~ "two upgrade entries that can both be selected for #{@from}"
      assert output =~ "a binary key is a regular expression"
      refute File.exists?(path)
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

  describe "an appup the application ships for itself" do
    test "is kept beside the project's rather than written over" do
      # Raised in review, and the fixture had been hiding it: the dependency's
      # own appup covers 0.1.0, the project supplies one for 0.0.9, and writing
      # the file whole would turn the transition the dependency *did* support
      # into a restart with nothing said about it.
      write_source!("sample_dep-0.0.9-#{@to}.exs", source("0.0.9", @to))

      {path, output, status} = assemble("dep-appup-shipping", @to, shipping_dep())

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "sample_dep ships an appup of its own at"
      assert output =~ "its 1 upgrade and 1 downgrade entries are kept"

      placed = Path.join(path, "lib/sample_dep-#{@to}/ebin/sample_dep.appup")

      assert {:ok,
              [
                {@to_vsn, [{~c"0.0.9", [{:load_module, SampleDep}]}, {@from_vsn, []}],
                 [{~c"0.0.9", [{:load_module, SampleDep}]}, {@from_vsn, []}]}
              ]} = :file.consult(to_charlist(placed))
    end

    test "is overridden where its own key is a pattern too, and says so" do
      # Raised in review, and the case that asking the question of the *shipped
      # keys* skipped: a shipped key that is a binary is a regular expression, so
      # `0\.1\..*` is overridden by a project entry named for 0.1.0 without ever
      # being a concrete version anybody could iterate. Asked at the probe, with
      # the function that selects, it is the same question either way round.
      write_dep_appup!("regex_appup.exs", regex_source(~S(0\\.1\\..*), @to))
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {_path, output, status} =
        assemble("dep-appup-shipped-regex", @to, shipping_dep("regex_appup.exs"))

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "the upgrade entry it holds for #{@from} is overridden"
      assert output =~ "the downgrade entry it holds for #{@from} is overridden"
    end

    test "is overridden where the project's key is the pattern, at a version nothing names" do
      # Raised in review, and the mirror of the case above: a project source may
      # hold entries beyond the version its name claims, so a broad key of its own
      # can select a shipped literal for some *other* version - one that never
      # became a probe, so nothing said it had been overridden while
      # release_handler ran the generic script instead of the specific one. The
      # shipped appup's own concrete versions are probes now.
      write_dep_appup!("wide_appup.exs", source("0.1.5", @to))
      write_source!("sample_dep-#{@from}-#{@to}.exs", regex_source(~S(0\\.1\\..*), @to))

      {_path, output, status} =
        assemble("dep-appup-wide-project", @to, shipping_dep("wide_appup.exs"))

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "the upgrade entry it holds for 0.1.5 is overridden"
      assert output =~ "the downgrade entry it holds for 0.1.5 is overridden"
    end

    test "is overridden where the project supplies one for the same transition, and says so" do
      # The other half, and it is deliberate rather than tolerated: supplying an
      # appup for a transition a dependency already covers is how a project
      # corrects one that is wrong or incomplete. What must not happen is it
      # being silent.
      write_source!("sample_dep-#{@from}-#{@to}.exs", source(@from, @to))

      {path, output, status} = assemble("dep-appup-override", @to, shipping_dep())

      assert status == 0, "the assembly failed:\n\n#{output}"
      assert output =~ "the upgrade entry it holds for #{@from} is overridden"
      assert output =~ "the downgrade entry it holds for #{@from} is overridden"

      placed = Path.join(path, "lib/sample_dep-#{@to}/ebin/sample_dep.appup")

      # The project's entry first, so it is the one `appup_search_for_version/2`
      # selects; the dependency's is still behind it rather than discarded.
      assert {:ok,
              [{@to_vsn, [{@from_vsn, [{:load_module, SampleDep}]}, {@from_vsn, []}], _down}]} =
               :file.consult(to_charlist(placed))
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

  # A source whose entry key is a **binary**, which `appup_search_for_version/2`
  # matches as a regular expression rather than by equality. `pattern` is the text
  # as it appears between the quotes in the generated file.
  defp regex_source(pattern, to) do
    """
    # Written by Forecastle.DepAppupTest.
    {~c"#{to}", [{"#{pattern}", [{:load_module, SampleDep}]}],
     [{"#{pattern}", [{:load_module, SampleDep}]}]}
    """
  end

  defp write_source!(name, contents) do
    dir = appups_dir()
    File.mkdir_p!(dir)

    path = Path.join(dir, name)
    File.write!(path, contents)

    path
  end

  defp appups_dir, do: Path.join(Fixture.workspace(), "rel/appups")

  defp clear!, do: File.rm_rf!(appups_dir())

  # `rel/overlays` is Mix's own: everything under it is copied over the release
  # root during `:assemble`, after the applications have been copied into `lib/`.
  # Taken away again, because it would otherwise plant this file in every release
  # another suite assembles.
  defp write_overlay!(relative, contents) do
    root = Path.join(Fixture.workspace(), "rel/overlays")
    path = Path.join(root, relative)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf!(root) end)

    path
  end

  # An overlay entry that is a *symlink*, which is what `File.cp_r!/2` carries
  # into the release rather than dereferencing.
  defp link_overlay!(relative, target) do
    root = Path.join(Fixture.workspace(), "rel/overlays")
    path = Path.join(root, relative)

    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
    on_exit(fn -> File.rm_rf!(root) end)

    path
  end

  defp overlay_appup do
    ~s|{~c"#{@to}", [{~c"0.0.1", [{:load_module, SampleDep}]}], [{~c"0.0.1", []}]}.\n|
  end

  ## Assembling

  # Deliberately not `ReleaseCase.assemble!/1`: every case in the second describe
  # block is a build that has to fail, and a helper which raises on a non-zero
  # exit cannot say what the build printed. It is also what keeps every build
  # this suite makes inside `@build_root`.
  defp assemble(into, vsn \\ @to, extra \\ []) do
    path = Path.join(Fixture.workspace(), into)

    File.rm_rf!(path)

    # `extra` first and then uniqued by name, so a case that needs a different
    # value for one of the defaults gets it rather than relying on which of two
    # entries with the same name `System.cmd/3` happens to keep.
    env = Enum.uniq_by(extra ++ env(vsn), &elem(&1, 0))

    {output, status} = Fixture.mix(["release", "sample", "--overwrite", "--path", path], env)

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

  # The dependency shipping its own appup again, in a build root of its own. Not
  # `@build_root`: the `:appup` compiler writes `sample_dep.appup` into whichever
  # build tree it runs in, and leaving one there would make the assertion that
  # nothing was written into the shared build depend on the order the cases ran.
  defp shipping_dep(source \\ "appup.exs") do
    [
      {"SAMPLE_DEP_APPUP", source},
      {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "#{@build_root}-shipping-#{@to}")}
    ]
  end

  # An appup source in the dependency's own project, which its `:appup` key names
  # through `SAMPLE_DEP_APPUP`. The `:appup` compiler rewrites the output on every
  # build, so cases sharing a build root do not have to sort themselves out.
  defp write_dep_appup!(name, contents) do
    path = Path.join([Fixture.workspace(), "dep", name])

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    path
  end
end
