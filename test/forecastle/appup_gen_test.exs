defmodule Forecastle.AppupGenTest do
  @moduledoc """
  Drives `mix castle.appup.gen` against two really-assembled releases.

  The generator writes *source*, so what this suite needs beyond the coverage
  check's fixture is somewhere for that source to go. The fixture's `:appup` key
  is switched by `SAMPLE_APPUP`, so each case points it at a file it owns -
  `generated.exs`, which nothing else reads - and the two cases that are about
  the project's *own* `appup.exs` put it back from the pristine source in
  `test/fixtures/sample` rather than from a copy taken at the time. A run killed
  half way through then leaves nothing for the next suite to trip on.

  **The fixture's own `appup.exs` computes**, which is not incidental: it is a
  `case` on `SAMPLE_VSN`, so it is exactly the third writing case, and the
  default state of the fixture is therefore the refusal. Nothing here completes
  it - see `AGENTS.md` on why that file must stay incomplete.

  **The acceptance criterion is wired in rather than eyeballed.** Two cases
  generate an appup and then run `mix castle.appup` over the result, asserting a
  zero exit: a generator whose output the gate rejects would be worse than no
  generator, and a test that read the file and agreed with itself would not
  notice.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Fixture

  @from "0.1.0"
  @to "0.1.1"

  # The same two as charlists, for the relup terms that are matched on rather
  # than searched in. A pattern cannot call `to_charlist/1`.
  @from_vsn ~c"0.1.0"
  @to_vsn ~c"0.1.1"

  # What the fixture's two versioned modules are, and so what any draft of this
  # transition has to contain: both carry a compile-time version tag and both are
  # `use GenServer`, so both are a changed module classified on its behaviour.
  @counter "{:update, Sample.Counter, {:advanced, []}}"
  @unmentioned "{:update, Sample.Unmentioned, {:advanced, []}}"

  setup_all do
    {:ok, from: assemble!(into: "gen-from", vsn: @from), to: assemble!(into: "gen-to", vsn: @to)}
  end

  setup do
    restore!()
    on_exit(&restore!/0)
  end

  describe "an application with no appup" do
    setup do
      # The first case is a project that has neither an `:appup` key nor a file,
      # which is where a project that has never had an appup starts. The
      # fixture's own file is put back by `restore!/0` after every case.
      File.rm!(appup_source())
    end

    test "writes one, and the coverage check passes against it", ctx do
      output = gen!(both(ctx), "none")

      assert output =~ "wrote appup.exs"
      assert File.read!(appup_source()) =~ @counter
      assert File.read!(appup_source()) =~ @unmentioned

      # The version tag is the target's, and both directions are written -
      # :systools refuses an edge with no entry for the from-version, so an
      # upgrade-only draft would leave the downgrade failing outright.
      assert File.read!(appup_source()) =~ "{~c\"#{@to}\","
      assert File.read!(appup_source()) =~ "{~c\"#{@from}\","

      # The acceptance criterion. The check compiles the file it was just given
      # and reports on the appup that comes out of it, so a draft that named the
      # wrong modules, or only some of them, fails here.
      check = check!(["--from", "rel:" <> rel(ctx.from, @from)], "appup.exs")

      assert check =~ "every module that moved is covered"
      assert check =~ "upgrade from #{@from}: nothing missing"
      assert check =~ "downgrade to #{@from}: nothing missing"
    end

    test "says the project has no :appup key, without which nothing compiles the file", ctx do
      output = gen!(both(ctx), "none")

      assert output =~ "This project has no :appup key"
      assert output =~ ~s|appup: "appup.exs"|
      assert output =~ ":compilers"
    end

    test "says the same of a project whose :appup key is false", ctx do
      # `Mix.Tasks.Compile.Appup.source/0` reads the key with
      # `if src = Mix.Project.config()[:appup]`, so *any* falsy value compiles
      # nothing. Reading it as configured wrote the file and left off the note,
      # which is a successful run producing a source no build reads. Raised in
      # review.
      output = gen!(both(ctx), "false")

      assert output =~ "wrote appup.exs"
      assert output =~ "This project has no :appup key"
    end

    test "says what it could not decide, beside the instructions it drafted", ctx do
      gen!(both(ctx), "none")

      source = File.read!(appup_source())

      # The four things §3.4 says the generator must say rather than decide. A
      # draft that hides its uncertainty is worse than no draft, so these are
      # asserted on the file rather than left to the moduledoc.
      assert source =~ "Nothing can derive it."
      assert source =~ "Extra = []"
      assert source =~ "supervision tree"
      assert source =~ "Ordering is stable, not correct"
    end
  end

  describe "an appup that states a literal" do
    test "gains the entry without disturbing the from-versions already there", ctx do
      write_generated!("""
      # a comment the merge has to keep
      {~c"#{@to}",
       [
         {~c"0.0.9", [{:load_module, Sample}]}
       ],
       []}
      """)

      output = gen!(both(ctx), "generated.exs")
      source = File.read!(generated())

      assert output =~ "merged into generated.exs"
      assert source =~ "# a comment the merge has to keep"
      assert source =~ "{~c\"0.0.9\", [{:load_module, Sample}]}"
      assert source =~ @counter
      assert source =~ @unmentioned

      check = check!(["--from", "rel:" <> rel(ctx.from, @from)], "generated.exs")

      assert check =~ "every module that moved is covered"
    end

    test "prints the diff, and a formatted appup gains lines and loses none", ctx do
      # A merge is a text splice rather than a re-render, so nothing already in
      # the file moves - and where the list's `[` ends its line, which is what a
      # formatted appup looks like, the diff is purely additive. An appup written
      # on one line has its one line split instead, which is the only way an
      # existing line changes at all.
      write_generated!("""
      {~c"#{@to}",
       [
         {~c"0.0.9", []}
       ],
       [
         {~c"0.0.9", []}
       ]}
      """)

      output = gen!(both(ctx), "generated.exs")
      removed = for "- " <> line <- diff_lines(output), do: line

      assert Enum.any?(diff_lines(output), &String.starts_with?(&1, "+ "))
      assert removed == []
    end

    test "adds nothing the second time, and says so", ctx do
      write_generated!(~s|{~c"#{@to}", [], []}\n|)

      gen!(both(ctx), "generated.exs")
      after_first = File.read!(generated())

      output = gen!(both(ctx), "generated.exs")

      assert output =~ "already has an upgrade and a downgrade entry for #{@from}"
      assert output =~ "0 appups written"
      assert File.read!(generated()) == after_first
    end

    test "leaving an incomplete entry alone is not a claim that it covers anything", ctx do
      # An entry existing and an entry being complete are different things, and
      # only the first is what stops this adding one. So a run over the fixture's
      # own gap - an entry naming Sample.Counter and not Sample.Unmentioned -
      # exits zero having written nothing, and the coverage check still fails on
      # it. The second assertion is the point: without it this case would pass
      # against a generator that had quietly declared the appup complete.
      write_generated!("""
      {~c"#{@to}",
       [
         {~c"#{@from}", [#{@counter}]}
       ],
       [
         {~c"#{@from}", [#{@counter}]}
       ]}
      """)

      before = File.read!(generated())
      output = gen!(both(ctx), "generated.exs")

      assert output =~ "already has an upgrade and a downgrade entry"
      assert output =~ "not the same as it covering everything that moved"
      assert File.read!(generated()) == before

      {check, status} =
        Fixture.mix(
          ["castle.appup", "--from", "rel:" <> rel(ctx.from, @from)],
          env("generated.exs")
        )

      assert status != 0, "the incomplete appup passed the coverage check:\n\n#{check}"
      assert check =~ "Sample.Unmentioned changed, and no instruction loads it"
    end

    test "adds only the direction that is missing", ctx do
      write_generated!(~s|{~c"#{@to}", [], [{~c"#{@from}", [{:load_module, Sample}]}]}\n|)

      output = gen!(both(ctx), "generated.exs")

      assert output =~ "already had a downgrade entry for #{@from}"
      assert output =~ "Only an upgrade entry was added"

      # The hand-written downgrade entry is left exactly as it was: once a
      # transition has instructions they are the author's.
      assert {{_vsn, _up, [{~c"0.1.0", [{:load_module, Sample}]}]}, []} =
               Code.eval_file(generated())
    end
  end

  describe "an appup that computes" do
    test "is refused, the entry is printed, and the file is untouched", ctx do
      # The fixture's own appup is a `case` on SAMPLE_VSN, so this is the default
      # state of the fixture rather than something the test arranges.
      before = File.read!(appup_source())

      {output, status} = gen(both(ctx), "appup.exs")

      assert status != 0, "a computed appup was rewritten:\n\n#{output}"
      assert output =~ "computes its appup rather than stating one"
      assert output =~ "the upgrade entry:"
      assert output =~ "the downgrade entry:"
      assert output =~ @counter
      assert output =~ "0 appups written"
      assert File.read!(appup_source()) == before
    end
  end

  describe "what it refuses rather than drafting" do
    test "an application whose version did not move", ctx do
      # Both sides the same release, so every module compares equal and the
      # version is the same in both. There is no transition to key an entry by,
      # and an entry written anyway would never be selected.
      spec = "rel:" <> rel(ctx.to, @to)

      {output, status} = gen(["--from", spec, "--to", spec, "--app", "sample"], "generated.exs")

      assert status != 0, "an application that did not move was drafted for:\n\n#{output}"
      assert output =~ "#{@to} in both builds"
      assert output =~ "Bump the version"
      refute File.exists?(generated())
    end

    test "a build of the application with no beams in it", ctx do
      # The shape that would otherwise produce an entry deleting the whole
      # application: an ebin holding the .app and nothing else makes every module
      # of the other side read as removed.
      root = lib_copy!(ctx.to, "gen-no-beams")
      Enum.each(Path.wildcard(Path.join(root, "lib/sample-*/ebin/*.beam")), &File.rm!/1)

      {output, status} =
        gen(
          ["--from", "rel:" <> rel(ctx.from, @from), "--to", "rel:" <> rel(root, @to)],
          "generated.exs"
        )

      assert status != 0, "an application with no beams was drafted for:\n\n#{output}"
      assert output =~ "holds no beam files"
      assert output =~ "load or delete the whole of sample"
      refute File.exists?(generated())
    end

    test "an application in one build and not the other", ctx do
      # `:systools` covers that with add_application, which no appup entry
      # describes. `mix castle.appup` reports the same state as a note and exits
      # zero; this exits non-zero, because it was asked to write something and
      # there is nothing to write.
      hide_app_dir!(ctx.from, "sample_dep")

      {output, status} = gen(both(ctx, "sample_dep"), "generated.exs")

      assert status != 0, "an application absent from a build was drafted for:\n\n#{output}"
      assert output =~ "which is not a transition an appup describes"
      assert output =~ "add_application"
      refute File.exists?(generated())
    end
  end

  describe "an application this project does not own" do
    test "writes rel/appups/<app>-<from>-<to>.exs rather than printing the entry", ctx do
      # The fixture's dependency. Its version moves with the sample's, so there
      # really is a transition to draft - and forecastle#30 gave the project a
      # place to put one, which is what retired the refusal this used to be. The
      # name carries the whole transition, because nothing else does: no `:appup`
      # key names this file and nothing compiles it.
      output = gen!(both(ctx, "sample_dep"), "generated.exs")

      assert output =~ "1 appup written"
      assert output =~ "wrote rel/appups/sample_dep-#{@from}-#{@to}.exs"

      # `SampleDep` declares no behaviour, so the decision table's last row is the
      # one that applies and the instruction is the common, useful case: an
      # application whose modules are all stateless drafts to `load_module`.
      assert {{@to_vsn, [{@from_vsn, up}], [{@from_vsn, down}]}, []} =
               Code.eval_file(dep_source())

      assert up == [{:load_module, SampleDep}]
      assert down == [{:load_module, SampleDep}]
    end

    test "says what puts the file into a release, and what never does", ctx do
      output = gen!(both(ctx, "sample_dep"), "generated.exs")
      source = File.read!(dep_source())

      # Both the report and the file itself, because they are read at different
      # times by different people and the second is the one that survives.
      assert output =~ "nothing writes one into deps/"
      assert output =~ "lib/sample_dep-#{@to}/ebin/sample_dep.appup"
      assert output =~ "refuses it once sample_dep is no longer #{@to} there"

      assert source =~ "an application this project does not own"
      assert source =~ "nothing writes it into deps/"
      assert source =~ "lib/sample_dep-#{@to}/ebin/sample_dep.appup"
      assert source =~ "refuses it once"

      # And nothing was written into the dependency's own checkout or its build,
      # which is the failure the location exists to avoid rather than a detail of
      # it: those are shared by every release built from this tree.
      assert Path.wildcard(Path.join(Fixture.workspace(), "deps/**/*.appup")) == []
    end

    test "leaves the transition alone where a sibling source already answers for it", ctx do
      # Raised in review. A dependency's appups are one file per transition and
      # the release merges every file naming the application into one appup, so
      # coverage is a question about the *set*: this sibling is keyed on a regular
      # expression that already selects 0.1.0, and writing a second entry for it
      # would leave a tree the next build refuses. Reported success on a tree that
      # no longer assembles is the shape of failure this whole tooling is for.
      sibling = write_dep_source!("sample_dep-0.1.9-#{@to}.exs", regex_appup(~S(0\\.1\\..*)))

      output = gen!(both(ctx, "sample_dep"), "generated.exs")

      assert output =~ "0 appups written"
      assert output =~ "already answers for #{@from} in both directions"
      assert output =~ Path.relative_to(sibling, Fixture.workspace())
      refute File.exists?(dep_source())

      # And the tree it left still assembles, which is the half an announcement
      # cannot be trusted for. The project's own appup is the checked-in one
      # here, since this case wrote none.
      into = Path.join(Fixture.workspace(), "gen-sibling-rel")
      on_exit(fn -> File.rm_rf!(into) end)

      {assembled, status} =
        Fixture.mix(["release", "sample", "--overwrite", "--path", into], env("appup.exs"))

      assert status == 0, "the tree the generator left does not assemble:\n\n#{assembled}"
    end

    test "refuses where a sibling answers for one direction only", ctx do
      # Half-covered is a refusal rather than a no-op: the file this would write
      # is one the next build refuses, because that direction would have two
      # entries that can both be selected for 0.1.0.
      write_dep_source!("sample_dep-0.1.9-#{@to}.exs", regex_appup(~S(0\\.1\\..*), :up))

      {output, status} = gen(both(ctx, "sample_dep"), "generated.exs")

      assert status != 0, "a colliding entry was written:\n\n#{output}"
      assert output =~ "already answers for #{@from} in the upgrade direction"
      assert output =~ "the upgrade entry:"
      refute File.exists?(dep_source())
    end

    test "counts the destination's own coverage as part of the set", ctx do
      # Raised in review. The file this would write covers the upgrade and a
      # sibling covers the downgrade, so between them the set covers both and
      # there is nothing to add - and nothing about that release fails to
      # assemble. Asking the siblings without asking the destination refused it.
      write_dep_source!("sample_dep-#{@from}-#{@to}.exs", literal_appup(@from, :up))
      write_dep_source!("sample_dep-0.1.9-#{@to}.exs", regex_appup(~S(0\\.1\\..*), :down))

      output = gen!(both(ctx, "sample_dep"), "generated.exs")

      assert output =~ "0 appups written"
      assert output =~ "answer for #{@from} between them, in both directions"
    end

    test "refuses where the file itself and a sibling answer for one direction", ctx do
      # The same multiplicity one file further in: the destination holds an
      # upgrade entry for 0.1.0 and a sibling's pattern selects it too, which the
      # next `mix release` refuses. Counting only the siblings reduced the pair to
      # one covered direction and merged the missing one into a tree that does not
      # assemble.
      write_dep_source!("sample_dep-#{@from}-#{@to}.exs", literal_appup(@from, :up))
      write_dep_source!("sample_dep-0.1.9-#{@to}.exs", regex_appup(~S(0\\.1\\..*), :up))

      {output, status} = gen(both(ctx, "sample_dep"), "generated.exs")

      assert status != 0, "a colliding destination and sibling were merged into:\n\n#{output}"
      assert output =~ "both answer for #{@from} in the upgrade direction"
    end

    test "refuses a file holding two entries that can both be selected", ctx do
      # And the same question inside one file, which the release asks too.
      write_dep_source!("sample_dep-#{@from}-#{@to}.exs", twice_appup(@from, ~S(0\\.1\\..*)))

      {output, status} = gen(both(ctx, "sample_dep"), "generated.exs")

      assert status != 0, "a file with two selectable entries was merged into:\n\n#{output}"
      assert output =~ "holds more than one upgrade entry that can be selected for #{@from}"
    end

    test "refuses two siblings that answer for one direction between them", ctx do
      # A tree the release already refuses, so reporting a successful no-op over
      # it would be this task saying a release is fine about one that does not
      # assemble. Collapsing the directions to a set before noticing was the false
      # pass.
      write_dep_source!("sample_dep-0.1.8-#{@to}.exs", regex_appup(~S(0\\.1\\..*), :up))
      write_dep_source!("sample_dep-0.1.9-#{@to}.exs", regex_appup(~S(0\\.1\\..*), :up))

      {output, status} = gen(both(ctx, "sample_dep"), "generated.exs")

      assert status != 0, "two colliding siblings were reported as covered:\n\n#{output}"
      assert output =~ "both answer for #{@from} in the upgrade direction"
      refute File.exists?(dep_source())
    end

    test "refuses a version that would put the file somewhere other than rel/appups", ctx do
      # Raised in review. The name is built out of two version strings, and
      # `Forecastle.Build` refuses a version that is not valid UTF-8 or that
      # carries control characters but says nothing about path separators -
      # which reach nothing anywhere else and reach the filesystem here. A `.app`
      # naming its version this way would have had the task create and write
      # `config/runtime.exs`.
      root = dep_copy!(ctx.to, "gen-escaping-vsn")
      set_dep_vsn!(root, "2.0/x/../../../../config/runtime")

      # The fixture has one, which is the point rather than an inconvenience: the
      # path this escapes to is a file the project already owns.
      runtime = Path.join(Fixture.workspace(), "config/runtime.exs")
      before = File.read!(runtime)

      {output, status} =
        gen(
          ["--from", "rel:" <> rel(ctx.from, @from), "--to", "rel:" <> rel(root, @to)] ++
            ["--app", "sample_dep"],
          "generated.exs"
        )

      assert status != 0, "a version naming a path was written to:\n\n#{output}"
      assert output =~ "do not make a file name in rel/appups"
      assert File.read!(runtime) == before, "the fixture's own config/runtime.exs was rewritten"
    end

    test "never rewrites an entry it already has, the same as for an owned application", ctx do
      gen!(both(ctx, "sample_dep"), "generated.exs")
      output = gen!(both(ctx, "sample_dep"), "generated.exs")

      # The file this writes is named for one transition, so a second run of the
      # same one meets its own output - which is the merge case, answering that
      # both directions are already covered.
      assert output =~ "0 appups written"
      assert output =~ "already has an upgrade and a downgrade entry for #{@from}"
    end
  end

  describe "the drafted script through :systools" do
    test "make_relup accepts it, which is the question the check does not answer", ctx do
      # `mix castle.appup` asks whether the appup names everything that moved and
      # deliberately does not ask whether the resulting script is one
      # `systools_rc` will accept — that is `make_relup/4`'s own answer, enforced
      # the moment a relup is generated. But this task *invents* the script, so
      # that question is its to answer: an instruction whose shape `:systools`
      # refuses covers nothing, and a draft nobody can build a relup from would
      # be worse than no draft. So the drafted entry is planted in the target
      # release and a real relup is generated from it.
      write_generated!(~s|{~c"#{@to}", [], []}\n|)
      gen!(both(ctx), "generated.exs")

      {appup, []} = Code.eval_file(generated())
      plant_appup!(ctx.to, appup)

      outdir = "gen-relups"
      relups = Path.join(Fixture.workspace(), outdir)
      File.mkdir_p!(relups)
      on_exit(fn -> File.rm_rf!(relups) end)

      mix!(
        ["castle.relup", "--target", rel(ctx.to, @to)] ++
          ["--fromto", "rel:" <> rel(ctx.from, @from), "--hot", "--outdir", outdir],
        env("generated.exs")
      )

      # Both directions, and each carrying instructions: an entry `:systools`
      # accepted and translated into a script with something in it. An empty
      # upgrade list here would mean the draft named nothing it could resolve.
      assert {:ok, [{@to_vsn, [{@from_vsn, [], [_ | _]}], [{@from_vsn, [], [_ | _]}]}]} =
               :file.consult(to_charlist(Path.join(relups, "relup")))
    end
  end

  describe "an empty diff" do
    test "writes the entry with an empty script and says why it is empty", ctx do
      # Nothing moved and the version did, which is a real state rather than a
      # degenerate one: `:systools` selects an entry by from-version and refuses
      # an edge that has none, so the entry is required and its script is empty.
      # The comment is what stops that reading as an omission - and writing
      # nothing at all here would be the silent success this task must never
      # report.
      root = lib_copy!(ctx.to, "gen-same-beams")
      set_app_vsn!(root, @to, "0.1.2")

      output =
        gen!(
          ["--from", "rel:" <> rel(ctx.to, @to), "--to", "rel:" <> rel(root, @to)],
          "generated.exs"
        )

      source = File.read!(generated())

      assert output =~ "1 appup written"
      assert source =~ "No module moved between these two builds"
      assert source =~ "make_relup/4 refuses an edge that has none"

      assert Code.eval_file(generated()) ==
               {{~c"0.1.2", [{to_charlist(@to), []}], [{to_charlist(@to), []}]}, []}
    end
  end

  ## Running the tasks

  defp gen(args, appup), do: Fixture.mix(["castle.appup.gen" | args], env(appup))

  defp gen!(args, appup) do
    {output, status} = gen(args, appup)

    assert status == 0, "mix castle.appup.gen exited #{status}:\n\n#{output}"

    output
  end

  defp check!(args, appup) do
    {output, status} = Fixture.mix(["castle.appup" | args], env(appup))

    assert status == 0, "mix castle.appup exited #{status} on generated output:\n\n#{output}"

    output
  end

  defp both(ctx, app \\ "sample") do
    ["--from", "rel:" <> rel(ctx.from, @from), "--to", "rel:" <> rel(ctx.to, @to), "--app", app]
  end

  # The build root the fixture was assembled with, so that a `compile` is the
  # no-op it should be, and the `:appup` key the case is about.
  defp env(appup) do
    [
      {"SAMPLE_VSN", @to},
      {"SAMPLE_APPUP", appup},
      {"MIX_BUILD_ROOT", Path.join(Fixture.workspace(), "_build-#{@to}")}
    ]
  end

  defp rel(release, vsn), do: Path.join(release, "releases/#{vsn}/sample")

  ## The workspace's appup sources

  defp appup_source, do: Path.join(Fixture.workspace(), "appup.exs")

  defp generated, do: Path.join(Fixture.workspace(), "generated.exs")

  defp write_generated!(source), do: File.write!(generated(), source)

  # Where a dependency's entry goes. Named for the transition rather than by a
  # project key, which is the whole of how the assembly step knows which release
  # it belongs to.
  defp dep_source do
    Path.join(dep_sources(), "sample_dep-#{@from}-#{@to}.exs")
  end

  defp dep_sources, do: Path.join(Fixture.workspace(), "rel/appups")

  defp write_dep_source!(name, contents) do
    File.mkdir_p!(dep_sources())

    path = Path.join(dep_sources(), name)
    File.write!(path, contents)

    path
  end

  # An appup whose from-version is a **binary**, which is a regular expression to
  # `appup_search_for_version/2` rather than a version compared for equality - so
  # it answers for 0.1.0 without being named for it.
  defp regex_appup(pattern, directions \\ :both) do
    dep_appup(~s|"#{pattern}"|, directions)
  end

  # And the same shape keyed on a version rather than a pattern.
  defp literal_appup(from, directions) do
    dep_appup(~s|~c"#{from}"|, directions)
  end

  # One file holding two upgrade entries that can both be selected for `from` -
  # the literal and a pattern that matches it - which is the multiplicity question
  # asked inside a single source rather than across two.
  defp twice_appup(from, pattern) do
    ~s|{~c"#{@to}", [{~c"#{from}", []}, {"#{pattern}", []}], []}\n|
  end

  # `directions` is which lists get the entry: an appup covering one direction and
  # not the other is a legitimate thing to write, and is what the cases about
  # coverage across a set of sources need.
  defp dep_appup(key, directions) do
    entry = ~s|[{#{key}, [{:load_module, SampleDep}]}]|
    up = if directions == :down, do: "[]", else: entry
    down = if directions == :up, do: "[]", else: entry

    ~s|{~c"#{@to}", #{up}, #{down}}\n|
  end

  # Put back from the checked-in fixture rather than from a copy taken at setup
  # time, so that a run killed part way through cannot leave a rewritten appup
  # behind for another suite to build against. `ReleaseCase` clears a stale
  # `relup` for the same reason.
  defp restore! do
    File.cp!(
      Path.join(Fixture.repo_root(), "test/fixtures/sample/appup.exs"),
      appup_source()
    )

    File.rm(generated())

    # A dependency's entry is written into the workspace's `rel/appups`, which
    # every other suite assembles against: a source left there names a transition
    # and `Forecastle.Appup.Dep` refuses one that is not the transition being
    # built, so it would fail their assemblies rather than this one's.
    File.rm_rf!(dep_sources())

    :ok
  end

  ## Scratch builds

  # A release-shaped tree holding one application, which is all
  # `Forecastle.Build` reads: it resolves a `rel:` spec by climbing three levels
  # from the path and never opens the `.rel`. Copying one application rather than
  # a whole release keeps this cheap and keeps the assembled trees this suite
  # shares untouched.
  defp lib_copy!(release, into) do
    root = Path.join(Fixture.workspace(), into)
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "lib"))
    File.cp_r!(Path.join(release, "lib/sample-#{@to}"), Path.join(root, "lib/sample-#{@to}"))

    root
  end

  # The compiled appup in the assembled target release, which is where
  # `:systools.make_relup/4` reads one from. Restored, since the trees are shared
  # by every case in this module.
  defp plant_appup!(release, appup) do
    file = Path.join(release, "lib/sample-#{@to}/ebin/sample.appup")
    original = File.read!(file)
    on_exit(fn -> File.write!(file, original) end)

    File.write!(file, IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [appup])))
  end

  # The same shape as `lib_copy!/2` for the dependency instead of the project's
  # own application, which is what the cases about a dependency's source need.
  defp dep_copy!(release, into) do
    root = Path.join(Fixture.workspace(), into)
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "lib"))

    File.cp_r!(
      Path.join(release, "lib/sample_dep-#{@to}"),
      Path.join(root, "lib/sample_dep-#{@to}")
    )

    root
  end

  # The version in the `.app` resource, which is what `Forecastle.Build` reads and
  # what the task names the file after - the directory keeps its own name, since
  # nothing resolves an application by it.
  defp set_dep_vsn!(root, app_vsn) do
    file = Path.join(root, "lib/sample_dep-#{@to}/ebin/sample_dep.app")
    {:ok, [{:application, app, opts}]} = :file.consult(to_charlist(file))

    File.write!(
      file,
      IO.iodata_to_binary(
        :io_lib.format(~c"~tp.~n", [{:application, app, Keyword.put(opts, :vsn, ~c"#{app_vsn}")}])
      )
    )
  end

  defp set_app_vsn!(root, vsn, app_vsn) do
    file = Path.join(root, "lib/sample-#{vsn}/ebin/sample.app")
    {:ok, [{:application, app, opts}]} = :file.consult(to_charlist(file))

    File.write!(
      file,
      IO.iodata_to_binary(
        :io_lib.format(~c"~tp.~n", [{:application, app, Keyword.put(opts, :vsn, ~c"#{app_vsn}")}])
      )
    )
  end

  # Renamed to something discovery cannot match, so the application really is
  # absent from that build rather than present twice. Restored regardless, since
  # the assembled trees are shared by every case in this module.
  defp hide_app_dir!(release, app) do
    [dir] = Path.wildcard(Path.join(release, "lib/#{app}-*"))
    moved = Path.join(release, "lib/hidden-#{app}")

    File.rename!(dir, moved)
    on_exit(fn -> File.rename!(moved, dir) end)
  end

  defp diff_lines(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(&(String.starts_with?(&1, "+ ") or String.starts_with?(&1, "- ")))
  end
end
