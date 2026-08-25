defmodule Forecastle.BaselineTest do
  @moduledoc """
  Drives `Forecastle.Baseline` over all three sources.

  The grammar and the `tar:` source are exercised in process. A tarball is only
  a directory that has been rolled up, so the whole of `tar:` - the extraction,
  the content-keyed cache, finding the `.rel` inside - can be tested against a
  release-shaped tree built here rather than against a real assembly, which the
  relup suite already pays for once.

  **`ref:` is driven through `mix run` in a project of its own**, and that is not
  incidental. The resolver takes its repository from the working directory and
  its cache from `Mix.Project`, so calling it in process would resolve against
  Forecastle's *own* checkout: it would add git worktrees to the repository this
  suite is running in, and cache a build of it under the `_build` the suite is
  using. `File.cd/1` is not a way round that either - it moves the whole
  operating system process, and two of this suite's modules are `async: true`.

  So each `ref:` case gets a throwaway repository under `_build/fixtures`,
  holding a Mix project small enough to compile in seconds, and the resolver is
  called from inside it by a probe script that prints the baseline it got back.
  What that costs is a `mix` invocation per assertion; what it buys is that a
  test which mishandles a worktree damages a repository nobody minds about.

  The tag the tests build is deliberately outside the shallow clone's slice, so
  the shallow case is the real one: a clone that has the tag's *name* would not
  exercise anything.
  """

  use ExUnit.Case, async: false

  alias Forecastle.Baseline
  alias Forecastle.Fixture

  @moduletag :slow
  @moduletag timeout: 600_000

  @root Path.join(Fixture.repo_root(), "_build/fixtures/baselines")

  # A repository built for a test must not inherit whatever the developer's git
  # configuration says. `commit.gpgsign` is the one that actually stops a run -
  # a commit with no key available fails outright - but `init.templateDir` and
  # global hooks are the same class of problem, and an identity has to come from
  # somewhere on a machine that has never configured one, CI included.
  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Forecastle"},
    {"GIT_AUTHOR_EMAIL", "forecastle@example.invalid"},
    {"GIT_COMMITTER_NAME", "Forecastle"},
    {"GIT_COMMITTER_EMAIL", "forecastle@example.invalid"}
  ]

  # Mix variables that would otherwise leak from the developer's shell into these
  # builds and redirect their output - which for `MIX_BUILD_PATH` would put a
  # baseline's artefacts wherever the outer build's already are, the exact
  # failure a build root per baseline exists to prevent. `MIX_TARGET` and
  # `MIX_EXS` are here as much for the assertions as for the builds: one case
  # sets a target of its own and reads back the directory Mix names for it, and
  # every other case takes the host.
  @scrubbed ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_QUIET MIX_DEBUG
               MIX_TARGET MIX_EXS)

  # `prod`, because that is the environment a release is built in and the
  # resolver hands the calling build's environment to the baseline's. Running
  # these in `test` would exercise a combination nothing real uses.
  @mix_env [{"MIX_ENV", "prod"}]

  # Module level rather than inside the `ref:` block, which is where it is
  # wanted: ExUnit does not allow `setup_all` inside `describe`. Building it
  # costs two commits and a clone, and the expensive part - the first `mix` run
  # in it - is paid by the first test that needs one.
  setup_all :git_project

  ## The grammar

  describe "parsing a spec" do
    test "a value with no prefix is a path to an assembled release" do
      assert Baseline.parse!("_build/prod/rel/my_app/releases/1.0.0/my_app") ==
               {:rel, "_build/prod/rel/my_app/releases/1.0.0/my_app"}
    end

    test "rel: names an assembled release" do
      assert Baseline.parse!("rel:some/releases/1.0.0/my_app") ==
               {:rel, "some/releases/1.0.0/my_app"}
    end

    test "tar: names an artefact" do
      assert Baseline.parse!("tar:artifacts/my_app-1.0.0.tar.gz") ==
               {:tar, "artifacts/my_app-1.0.0.tar.gz"}
    end

    test "ref: names a git ref" do
      assert Baseline.parse!("ref:v1.0.0") == {:ref, "v1.0.0"}
    end

    test "only the first colon separates the source from the value" do
      assert Baseline.parse!("tar:weird:name.tar.gz") == {:tar, "weird:name.tar.gz"}
    end

    test "a prefix that names no source is refused, and the ones that exist are named" do
      # Not read as a path. A mistyped prefix that resolved as one would fail
      # looking for a release called `re:v1.0.0`, which mentions neither the
      # typo nor the fact that there is a grammar here at all.
      message = assert_raise Mix.Error, fn -> Baseline.parse!("re:v1.0.0") end

      assert message.message =~ ~s(baseline source "re:")
      assert message.message =~ "`rel:`"
      assert message.message =~ "`tar:`"
      assert message.message =~ "`ref:`"
    end

    test "a prefix with nothing after it names no baseline" do
      assert_raise Mix.Error, ~r/nothing after the prefix/, fn -> Baseline.parse!("ref:") end
    end

    test "an empty value names no baseline" do
      assert_raise Mix.Error, ~r/cannot be empty/, fn -> Baseline.parse!("") end
    end
  end

  describe "recognising a spec" do
    test "anything shaped like a prefix is one" do
      assert Baseline.spec?("rel:x")
      assert Baseline.spec?("tar:x")
      assert Baseline.spec?("ref:x")

      # Shaped like a prefix without naming a source. This is what lets a switch
      # that takes a path say so, rather than resolving the typo as a filename.
      assert Baseline.spec?("re:x")
    end

    test "a path is not one" do
      refute Baseline.spec?("_build/prod/rel/my_app/releases/1.0.0/my_app")
      refute Baseline.spec?("/absolute/path")
      refute Baseline.spec?("./relative/path")
      refute Baseline.spec?("my_app")
    end

    test "a single character before the colon is not one" do
      # Windows is not supported here, but refusing to name `c:/...` at all
      # would be a poor way to say so - and `rel:` in front of it is the way
      # through for any path that genuinely looks like a spec.
      refute Baseline.spec?("c:/releases/1.0.0/my_app")
    end
  end

  ## rel:

  describe "resolving rel:" do
    test "resolves to the path it was given" do
      baseline = Baseline.resolve!("rel:some/rel/releases/1.0.0/my_app", :release)

      assert baseline.source == :rel
      assert baseline.rel_path == "some/rel/releases/1.0.0/my_app"
      refute baseline.rebuilt?
    end

    test "a bare path resolves the same way" do
      bare = Baseline.resolve!("some/rel/releases/1.0.0/my_app", :release)
      prefixed = Baseline.resolve!("rel:some/rel/releases/1.0.0/my_app", :release)

      # Everything but `:spec`, which keeps what it was given so that a
      # diagnostic can quote the caller rather than a normalised form of it.
      assert Map.delete(Map.from_struct(bare), :spec) ==
               Map.delete(Map.from_struct(prefixed), :spec)
    end

    test "reads nothing off disk, so the task keeps saying what it could not read" do
      # Deliberately a path that does not exist. `mix castle.relup` reports a
      # missing or malformed `.rel` in terms of the file and the reason, and a
      # check here would either duplicate that or stand in front of it with less
      # to say.
      baseline = Baseline.resolve!("rel:nowhere/releases/9.9.9/nothing", :release)

      assert baseline.rel_path == "nowhere/releases/9.9.9/nothing"
    end

    test "derives the release's library directory from the .rel path" do
      baseline = Baseline.resolve!("rel:/opt/my_app/releases/1.0.0/my_app", :release)

      assert baseline.lib_dir == "/opt/my_app/lib"
    end
  end

  ## tar:

  describe "resolving tar:" do
    setup :release_tarball

    test "resolves to the .rel inside the artefact", ctx do
      baseline = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      assert baseline.source == :tar
      assert Path.basename(baseline.rel_path) == "my_app"
      assert File.exists?(baseline.rel_path <> ".rel")
      refute baseline.rebuilt?
    end

    test "the library directory it reports holds the unpacked applications", ctx do
      baseline = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      assert File.dir?(Path.join(baseline.lib_dir, "my_app-1.0.0/ebin"))
    end

    test "unpacks once and reuses the unpacking", ctx do
      first = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      # Observed by taking something away rather than by timing: if the second
      # resolution unpacked again, the applications would be back. Something the
      # resolution does not itself read, so that removing it cannot be what makes
      # the second resolution behave differently.
      File.rm_rf!(first.lib_dir)

      second = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      assert second.rel_path == first.rel_path
      refute File.dir?(second.lib_dir)
    end

    test "keys the cache on the contents rather than on the path", ctx do
      # A pipeline that writes `my_app-1.0.0.tar.gz` afresh on every build would
      # otherwise be served the first build's release for ever.
      first = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      File.rm_rf!(Path.join(ctx.tree, "releases"))
      File.mkdir_p!(Path.join(ctx.tree, "releases/1.0.1"))
      write_rel!(Path.join(ctx.tree, "releases/1.0.1/my_app.rel"), "1.0.1")
      tar_up!(ctx.tarball, ctx.tree)

      second = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      refute second.rel_path == first.rel_path
      assert Path.basename(Path.dirname(second.rel_path)) == "1.0.1"
    end

    test "says so when the artefact is not there", ctx do
      missing = Path.join(ctx.dir, "absent.tar.gz")

      assert_raise Mix.Error, ~r/#{Regex.escape(missing)}, which is not a file/, fn ->
        Baseline.resolve!("tar:#{missing}", :release)
      end
    end

    test "says so when there is no release inside it", ctx do
      empty = Path.join(ctx.dir, "empty.tar.gz")
      File.mkdir_p!(Path.join(ctx.dir, "empty/nothing"))

      :ok =
        :erl_tar.create(
          to_charlist(empty),
          [{~c"nothing", to_charlist(Path.join(ctx.dir, "empty/nothing"))}],
          [:compressed]
        )

      assert_raise Mix.Error, ~r/Is it a release tarball\?/, fn ->
        Baseline.resolve!("tar:#{empty}", :release)
      end
    end

    test "an unpacked release's two .rel files are one release, not two", ctx do
      # `release_handler:do_unpack_release/4` copies `releases/<name>-<vsn>.rel`
      # into the version directory beside Mix's `<name>.rel`, "for backwards
      # compatibility reasons with older systools:make_tar" (OTP-9746). A
      # tarball made from a deployment rather than from a build therefore holds
      # two byte-identical copies, and that is normal rather than ambiguous.
      copy = Path.join(ctx.tree, "releases/1.0.0/my_app-1.0.0.rel")
      File.cp!(Path.join(ctx.tree, "releases/1.0.0/my_app.rel"), copy)
      tar_up!(ctx.tarball, ctx.tree)

      baseline = Baseline.resolve!("tar:#{ctx.tarball}", :release)

      assert Path.basename(baseline.rel_path) in ~w(my_app my_app-1.0.0)
    end

    test "refuses an artefact holding a hard link, which unpacking would drop", ctx do
      # `:erl_tar` writes regular files, directories and symlinks and ignores
      # everything else *without failing*, so a hard link comes out as a missing
      # file and a successful extraction. A release tree is full of identical
      # files for tar to store that way, and `tar:` is meant to be the artefact
      # that shipped - which may have been rolled by something other than Mix.
      hard_linked = tarball_with!(ctx, "hard-linked", &hard_link!/1, :link)

      assert_raise Mix.Error, ~r/would not reproduce as themselves/, fn ->
        Baseline.resolve!("tar:#{hard_linked}", :release)
      end
    end

    test "refuses an artefact holding a fifo, which unpacking would empty", ctx do
      # The other half of the same problem, and the reason the accepted list is
      # shorter than the list `:erl_tar` tolerates: a fifo, a character device
      # and a block device are each created as an *empty regular file*. At a
      # payload path that is a `.beam` replaced by nothing, reported as success.
      fifo = tarball_with!(ctx, "fifo", &fifo!/1, :fifo)

      assert_raise Mix.Error, ~r/would not reproduce as themselves/, fn ->
        Baseline.resolve!("tar:#{fifo}", :release)
      end
    end

    test "refuses an artefact whose members unpack to the same path", ctx do
      # The other way an archive can unpack into something it does not list.
      # `:erl_tar` extracts in order, so which of two members landing on one path
      # survives is a property of the order rather than of the archive - and a
      # symlink over an existing file is refused by the filesystem outright.
      colliding = tarball_with_colliding_members!(ctx)

      assert_raise Mix.Error, ~r/unpack to the same path/, fn ->
        Baseline.resolve!("tar:#{colliding}", :release)
      end
    end

    test "refuses a tarball holding two different releases", ctx do
      File.mkdir_p!(Path.join(ctx.tree, "releases/2.0.0"))
      write_rel!(Path.join(ctx.tree, "releases/2.0.0/my_app.rel"), "2.0.0")
      tar_up!(ctx.tarball, ctx.tree)

      assert_raise Mix.Error, ~r/holds 2 different releases/, fn ->
        Baseline.resolve!("tar:#{ctx.tarball}", :release)
      end
    end
  end

  ## ref:

  describe "resolving ref:" do
    setup :cold_cache

    test "builds the commit once and reuses it", ctx do
      first = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)

      assert field(first, "source") == "ref"
      assert field(first, "rebuilt?") == "true"
      assert first =~ "building the baseline for"
      refute first =~ "reusing the baseline"

      second = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)

      assert second =~ "reusing the baseline already built for"
      refute second =~ "building the baseline for"
      assert field(second, "lib_dir") == field(first, "lib_dir")

      # Said on both, because it is a property of the baseline rather than of the
      # work done to get it: "generated against a rebuilt 1.0.0" and "generated
      # against the 1.0.0 that shipped" are different claims about the same
      # relup, and a cache hit does not turn the first into the second.
      assert first =~ "was rebuilt from"
      assert second =~ "was rebuilt from"
    end

    test "a compiled baseline yields the modules and no release", ctx do
      output = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)

      assert field(output, "rel_path") == ""
      assert File.dir?(Path.join(field(output, "lib_dir"), "baseline_fixture/ebin"))
    end

    test "a released baseline yields a .rel the relup task can be given", ctx do
      output = resolve!(ctx.repo, "ref:#{ctx.tag}", :release)

      assert File.exists?(field(output, "rel_path") <> ".rel")
      assert File.dir?(field(output, "lib_dir"))
    end

    test "removes the worktree it built in, and keeps what it built", ctx do
      output = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)

      assert File.dir?(Path.join(field(output, "lib_dir"), "baseline_fixture/ebin"))

      # What is claimed is that *its own* worktree is gone, not that the
      # repository has exactly one. Asserting the whole list would make this test
      # fail or pass depending on which other test ran first, since the
      # repository is shared and ExUnit randomises the order.
      refute Enum.any?(worktrees(ctx.repo), &String.contains?(&1, "castle/baselines"))
    end

    test "refuses to resolve a baseline while one is being built", ctx do
      # Building an old commit runs that commit's own mix.exs, which in a project
      # using Castle configures the release - so without this, a baseline whose
      # build asks for a baseline goes round again against a release nobody named.
      output = resolve(ctx.repo, "ref:#{ctx.tag}", :compile, env: [{"CASTLE_BASELINE", ctx.sha}])

      assert output =~ "was asked for while building the baseline"
      assert output =~ String.slice(ctx.sha, 0, 12)
    end

    test "names --unshallow when the clone is shallow and the ref is not in it", ctx do
      output = resolve(ctx.shallow, "ref:#{ctx.tag}", :compile)

      assert output =~ "which is a shallow clone"
      assert output =~ "git fetch --tags --unshallow"
    end

    test "says the ref does not exist when the clone is not shallow", ctx do
      output = resolve(ctx.repo, "ref:no-such-tag", :compile)

      assert output =~ "names no commit in this repository"
      refute output =~ "shallow"
    end

    test "a ref beginning with a dash is a ref, not an option to git", ctx do
      # A spec arrives off a command line, so it can look like anything. What
      # must not happen is git reading it as one of its own options and this
      # reporting whatever that produced as though it were a revision.
      output = resolve(ctx.repo, "ref:--local-env-vars", :compile)

      assert output =~ "names no commit in this repository"
      refute output =~ "GIT_DIR"
    end

    test "a warning on git's standard error does not become part of the sha", ctx do
      # Git writes advice and warnings to standard error and still exits zero -
      # dubious ownership, a deprecated config key, a hint about something
      # unrelated. Folded into the output of `rev-parse`, those lines become part
      # of a directory name and part of a revision to check out, and a resolution
      # that would have worked fails somewhere that says nothing about why.
      output = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile, path: ctx.git_shim)

      # First that the shim was reached at all. Without this the test passes on a
      # PATH that never picked it up, which is a test asserting nothing.
      assert output =~ "a shimmed git wrote this to standard error"

      assert File.dir?(Path.join(field(output, "lib_dir"), "baseline_fixture/ebin"))
      refute field(output, "lib_dir") =~ "warning"
    end

    test "builds a project that is not at the top of its repository", ctx do
      # `git worktree add` checks out the repository, not the project, so a
      # project one directory down has to be built one directory down inside the
      # worktree too. Built at the root instead, the child finds no mix.exs - or,
      # in a monorepo, the wrong one.
      output = resolve!(ctx.nested_project, "ref:#{ctx.tag}", :compile)

      assert File.dir?(Path.join(field(output, "lib_dir"), "baseline_fixture/ebin"))
    end

    test "two projects sharing a build root do not share a baseline", ctx do
      # An umbrella's children share one `_build`, so the cache directory is the
      # same for both. Keyed on the commit alone, `apps/a` and `apps/b` resolving
      # the same ref land on one entry and whichever built first answers for
      # both - a different project's artefacts, under a key that said nothing
      # about which project it was.
      shared = [{"MIX_BUILD_ROOT", ctx.shared_build}]
      one = resolve!(ctx.siblings.a, "ref:#{ctx.tag}", :compile, env: shared)
      two = resolve!(ctx.siblings.b, "ref:#{ctx.tag}", :compile, env: shared)

      assert two =~ "building the baseline for"
      refute two =~ "reusing the baseline"
      refute field(two, "lib_dir") == field(one, "lib_dir")

      assert File.read!(Path.join(entry_of(field(one, "lib_dir")), "context.txt")) =~
               "project=apps/a/"
    end

    test "finds the modules whatever Mix called the build directory", ctx do
      # The nested project sets `build_per_environment: false`, so Mix writes to
      # `shared` rather than to the environment's name. That is the *baseline
      # project's* configuration and the calling project cannot know it, which is
      # why the directory is found rather than reconstructed.
      output = resolve!(ctx.nested_project, "ref:#{ctx.tag}", :compile)

      assert Path.basename(Path.dirname(field(output, "lib_dir"))) == "shared"
      assert File.dir?(Path.join(field(output, "lib_dir"), "baseline_fixture/ebin"))
    end

    test "a baseline built for one target is not handed to another", ctx do
      # `Mix.target/0` is process state in the calling build - it can come from
      # `def cli` rather than from the environment - so it has to be handed to the
      # child explicitly. The directory Mix names for a non-host target is what
      # says it arrived: without it the child builds `prod` and this reads
      # `rpi3_prod`.
      host = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)
      rpi3 = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile, env: [{"MIX_TARGET", "rpi3"}])

      assert Path.basename(Path.dirname(field(host, "lib_dir"))) == "prod"
      assert Path.basename(Path.dirname(field(rpi3, "lib_dir"))) == "rpi3_prod"

      assert rpi3 =~ "building the baseline for"
      refute rpi3 =~ "reusing the baseline"

      assert File.read!(Path.join(entry_of(field(rpi3, "lib_dir")), "context.txt")) =~
               "mix_target=rpi3"
    end

    test "a baseline built for one environment is not handed to another", ctx do
      # The child is built with the caller's MIX_ENV, so the same commit built
      # twice is two different baselines. Keyed on the sha alone, the first build
      # would answer for both - and the second caller would be given a lib
      # directory for an environment nothing ever built.
      prod = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)
      dev = resolve!(ctx.repo, "ref:#{ctx.tag}", :compile, env: [{"MIX_ENV", "dev"}])

      assert dev =~ "building the baseline for"
      refute dev =~ "reusing the baseline"
      refute field(dev, "lib_dir") == field(prod, "lib_dir")

      assert File.dir?(Path.join(field(dev, "lib_dir"), "baseline_fixture/ebin"))

      assert File.read!(Path.join(entry_of(field(prod, "lib_dir")), "context.txt")) =~
               "mix_env=prod"
    end

    test "a build that fails leaves nothing a later run would reuse", ctx do
      # The commit `broken` does not compile. What must not survive it is a
      # published entry: an entry exists only when it is whole, so a failure has
      # to leave the cache exactly as it found it - and the next run has to do the
      # work again rather than find something to reuse.
      output = resolve(ctx.repo, "ref:broken", :compile)

      assert output =~ "could not be built"
      assert entries(ctx.repo) == []
      assert staging(ctx.repo) == []

      assert resolve(ctx.repo, "ref:broken", :compile) =~ "building the baseline for"
    end

    test "leaves a worktree registration it did not make alone", ctx do
      # `git worktree prune` would clear this one too. It is not this task's to
      # clear: a checkout on a disk that is not mounted today looks exactly like a
      # dead one, and a relup run has no business deregistering it.
      unrelated = Path.join(ctx.dir, "somebody-elses-worktree")
      git!(ctx.repo, ["worktree", "add", "--detach", "--quiet", unrelated, "HEAD"])
      File.rm_rf!(unrelated)

      # The repository is shared with the rest of this block, so the registration
      # this deliberately strands has to go again afterwards. Pruning is safe
      # here for the same reason it is not safe in the resolver: this repository
      # is one the suite made and nobody else has anything in it.
      on_exit(fn -> git!(ctx.repo, ["worktree", "prune"]) end)

      resolve!(ctx.repo, "ref:#{ctx.tag}", :compile)

      assert unrelated in worktrees(ctx.repo)
    end
  end

  ## The release-shaped tree the tar: cases are built from

  defp release_tarball(_ctx) do
    dir = Path.join(@root, "tar")
    tree = Path.join(dir, "my_app")
    tarball = Path.join(dir, "my_app-1.0.0.tar.gz")

    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(tree, "releases/1.0.0"))
    File.mkdir_p!(Path.join(tree, "lib/my_app-1.0.0/ebin"))
    write_rel!(Path.join(tree, "releases/1.0.0/my_app.rel"), "1.0.0")
    tar_up!(tarball, tree)

    # The cache is content-keyed, so nothing here is reused between tests - but
    # it is written under the `_build` this suite is running in, and a suite that
    # leaves rubbish behind is a suite whose next run starts from somewhere
    # slightly different.
    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(cache_dir())
    end)

    {:ok, dir: dir, tree: tree, tarball: tarball}
  end

  # A real release term, because the version directory holding more than one
  # `.rel` is only resolvable by reading them, and `:file.consult/1` has to be
  # able to.
  defp write_rel!(path, vsn) do
    term = {:release, {~c"my_app", to_charlist(vsn)}, {:erts, ~c"16.2"}, [{:kernel, ~c"10.3"}]}

    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [term]))
  end

  # Named members rather than a `cd` into the tree, because `:erl_tar.create/3`
  # otherwise resolves its file list against the working directory - which this
  # suite must not move, since two of its modules are async.
  defp tar_up!(tarball, tree) do
    File.rm(tarball)

    members =
      for entry <- ~w(releases lib),
          do: {to_charlist(entry), to_charlist(Path.join(tree, entry))}

    :ok = :erl_tar.create(to_charlist(tarball), members, [:compressed])
  end

  defp cache_dir do
    Path.join([Path.dirname(Mix.Project.build_path()), "castle", "baselines"])
  end

  # Rolled by the system `tar` rather than by `:erl_tar.create/3`, which is the
  # whole point: `:erl_tar` writes none of these member types, so an archive it
  # built cannot exercise the ones it declines to read back faithfully.
  #
  # `expected` is asserted on the archive before the archive is used, because
  # `tar` decides for itself what it stores - it writes a hard link only for the
  # second copy of an inode it noticed - and an archive that came out without the
  # member is a test asserting nothing.
  defp tarball_with!(ctx, name, make_member, expected) do
    make_member.(Path.join(ctx.tree, "lib/my_app-1.0.0/ebin"))

    tarball = Path.join(ctx.dir, "#{name}.tar.gz")

    {output, status} =
      System.cmd("tar", ["-czf", tarball, "-C", ctx.tree, "releases", "lib"],
        stderr_to_stdout: true
      )

    assert status == 0, "could not build the #{name} artefact:\n\n#{output}"

    {:ok, entries} = :erl_tar.table(to_charlist(tarball), [:compressed, :verbose])

    assert Enum.any?(entries, fn {_name, type, _size, _mtime, _mode, _uid, _gid} ->
             type == expected
           end),
           "the #{name} artefact came out with no #{expected} member in it, " <>
             "so nothing here is under test"

    tarball
  end

  # Built with `:erl_tar.create/3` rather than the system `tar`, which is the
  # opposite choice from the other two artefacts here and for the same underlying
  # reason: what each test needs is a member type its builder can actually
  # produce. `tar` given one file twice notices the repeated inode and writes the
  # second as a *hard link*, so the type check refuses it before the collision
  # check is reached - which is what this asserted on macOS and not on Linux
  # until the archive stopped being built that way. `:erl_tar.create/3` writes
  # exactly the members it is given, names and all.
  #
  # Two different files, spelled onto one destination: `lib/…/my_app.app` and
  # `./lib/…/my_app.app` differ as strings and not as paths.
  defp tarball_with_colliding_members!(ctx) do
    tarball = Path.join(ctx.dir, "colliding.tar.gz")
    member = "lib/my_app-1.0.0/ebin/my_app.app"

    first = Path.join(ctx.dir, "first.app")
    second = Path.join(ctx.dir, "second.app")
    File.write!(first, "{application, my_app, [{vsn, \"1\"}]}.")
    File.write!(second, "{application, my_app, [{vsn, \"2\"}]}.")

    members = [
      {~c"releases", to_charlist(Path.join(ctx.tree, "releases"))},
      {to_charlist(member), to_charlist(first)},
      {to_charlist("./" <> member), to_charlist(second)}
    ]

    :ok = :erl_tar.create(to_charlist(tarball), members, [:compressed])

    # Both spellings really are in there, and both as ordinary files: if either
    # were dropped or stored as something else, this would be testing the type
    # check again rather than the collision check.
    {:ok, entries} = :erl_tar.table(to_charlist(tarball), [:compressed, :verbose])

    for name <- [member, "./" <> member] do
      assert Enum.any?(entries, fn {n, type, _size, _mtime, _mode, _uid, _gid} ->
               to_string(n) == name and type == :regular
             end),
             "the colliding artefact has no regular member named #{name}"
    end

    tarball
  end

  defp hard_link!(ebin) do
    File.write!(Path.join(ebin, "my_app.app"), "{application, my_app, []}.")
    File.ln!(Path.join(ebin, "my_app.app"), Path.join(ebin, "my_app_linked.app"))
  end

  defp fifo!(ebin) do
    path = Path.join(ebin, "my_app.beam")
    {output, status} = System.cmd("mkfifo", [path], stderr_to_stdout: true)

    assert status == 0, "could not create a fifo at #{path}:\n\n#{output}"
  end

  ## The throwaway repository the ref: cases are resolved in

  # Three commits, with the tag on the first. `git clone --depth 1` then produces
  # a clone whose object store genuinely does not hold the tagged commit, which
  # is the case CI hits constantly and the one the shallow message is for. A tag
  # on the tip would be fetched by the shallow clone and prove nothing.
  #
  # The third commit deliberately does not compile, and is tagged, because "a
  # build that failed leaves nothing a later run would reuse" cannot be asserted
  # without a build that fails.
  defp git_project(_ctx) do
    dir = Path.join(@root, "ref")
    repo = Path.join(dir, "origin")
    shallow = Path.join(dir, "shallow")
    nested = Path.join(dir, "nested")
    nested_project = Path.join(nested, "apps/thing")

    File.rm_rf!(dir)
    write_project!(repo)

    git!(repo, ["init", "--quiet"])
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "the baseline"])
    git!(repo, ["tag", "baseline"])
    sha = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(repo, "lib/baseline_fixture.ex"), module_source("moved on"))
    git!(repo, ["commit", "--quiet", "-a", "-m", "move past the baseline"])

    File.write!(Path.join(repo, "lib/baseline_fixture.ex"), "defmodule Broken do def(")
    git!(repo, ["commit", "--quiet", "-a", "-m", "a commit that does not build"])
    git!(repo, ["tag", "broken"])

    # Repaired on the way past, because the probe runs `mix` in this checkout: a
    # working tree left at `broken` would fail to compile the project the probe
    # is being run from, and every test here would report the wrong failure.
    File.write!(Path.join(repo, "lib/baseline_fixture.ex"), module_source("moved on again"))
    git!(repo, ["commit", "--quiet", "-a", "-m", "repair the working tree"])

    # `file://` rather than the path: git ignores `--depth` on a local clone and
    # says so, and a clone that is not shallow proves nothing here.
    git!(dir, ["clone", "--quiet", "--depth", "1", "file://#{repo}", shallow])

    # The same project, in a repository where it is *not* at the top level. What
    # `git worktree add` checks out is the whole repository, so where inside it
    # the build runs is a question a monorepo asks and a flat project never does.
    # And with `build_per_environment: false`, so that the same repository also
    # covers Mix writing to `shared` rather than to the environment's name.
    write_project!(nested_project, build_per_environment: false)

    # Two more beside it, which together are the umbrella shape: different
    # projects, built out of the same commit, sharing one build root and
    # therefore one baseline cache.
    for app <- ~w(a b), do: write_project!(Path.join(nested, "apps/" <> app))

    git!(nested, ["init", "--quiet"])
    git!(nested, ["add", "."])
    git!(nested, ["commit", "--quiet", "-m", "the baseline, one level down"])
    git!(nested, ["tag", "baseline"])

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok,
     dir: dir,
     repo: repo,
     shallow: shallow,
     nested_project: nested_project,
     siblings: %{a: Path.join(nested, "apps/a"), b: Path.join(nested, "apps/b")},
     shared_build: Path.join(dir, "shared-build"),
     tag: "baseline",
     sha: sha,
     git_shim: write_git_shim!(dir)}
  end

  # A `git` earlier on PATH than the real one, which writes to standard error and
  # then delegates. Git does this itself for all sorts of reasons - dubious
  # repository ownership, a deprecated configuration key, advice about something
  # unrelated - and none of them mean the command failed.
  defp write_git_shim!(dir) do
    shim_dir = Path.join(dir, "git-shim")
    File.mkdir_p!(shim_dir)

    real = System.find_executable("git") || flunk("git is not on PATH")
    shim = Path.join(shim_dir, "git")

    File.write!(shim, """
    #!/bin/sh
    echo "warning: a shimmed git wrote this to standard error" >&2
    exec #{real} "$@"
    """)

    File.chmod!(shim, 0o755)

    shim_dir
  end

  # The repository is built once for the whole block - `git init` and the first
  # `mix run` in it are the expensive part - but the cache under it is what most
  # of these tests are about, so each starts with it empty. ExUnit randomises
  # test order, so a test that assumed a warm or cold cache left by another would
  # be a test that passes on some seeds.
  defp cold_cache(ctx) do
    for repo <- [ctx.repo, ctx.shallow, ctx.nested_project] do
      File.rm_rf!(Path.join(repo, "_build/castle"))
    end

    File.rm_rf!(Path.join(ctx.shared_build, "castle"))

    :ok
  end

  # Everything published under a repository's cache, and everything still being
  # worked on. The second list is the one that has to stay empty: a staging
  # directory left behind is a run that did not clean up after itself, and the
  # whole reason the work happens in one is that nothing else ever reads it.
  defp entries(repo) do
    repo |> Path.join("_build/castle/baselines/ref-*/*") |> Path.wildcard()
  end

  defp staging(repo) do
    repo |> Path.join("_build/castle/baselines/.staging-*") |> Path.wildcard()
  end

  # `:compile` puts the modules at `<entry>/build/<env>/lib`, so the entry is
  # three levels up from what the probe reports.
  defp entry_of(lib_dir), do: Path.expand("../../..", lib_dir)

  # Small enough to compile in seconds and to assemble without ERTS, and
  # depending on Forecastle by path so that the probe can call the resolver at
  # all. The path is absolute and baked in: this project is generated for one
  # run of one test and is never checked out anywhere else.
  defp write_project!(repo, opts \\ []) do
    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(Path.join(repo, ".gitignore"), """
    /_build/
    /deps/
    /probe.exs
    """)

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule BaselineFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :baseline_fixture,
          version: "0.1.0",
          elixir: "~> 1.18",
          build_per_environment: #{Keyword.get(opts, :build_per_environment, true)},
          deps: [{:forecastle, path: "#{Fixture.repo_root()}"}],
          releases: [baseline_fixture: [include_erts: false]]
        ]
      end

      def application, do: [extra_applications: []]
    end
    """)

    File.write!(Path.join(repo, "lib/baseline_fixture.ex"), module_source("the baseline"))
  end

  defp module_source(says) do
    """
    defmodule BaselineFixture do
      def says, do: #{inspect(says)}
    end
    """
  end

  # Fields printed one per line rather than the struct inspected whole, so that
  # what the test reads back is the value the resolver produced rather than
  # something recovered from a rendering of it.
  @probe ~S"""
  spec = System.fetch_env!("BASELINE_SPEC")
  level = String.to_existing_atom(System.fetch_env!("BASELINE_LEVEL"))

  baseline = Forecastle.Baseline.resolve!(spec, level)

  for field <- [:spec, :source, :level, :rel_path, :lib_dir, :rebuilt?] do
    IO.puts("baseline.#{field}=#{Map.fetch!(baseline, field)}")
  end
  """

  # Raises on a failed resolution, for the cases where resolving is the setup
  # rather than the assertion.
  defp resolve!(repo, spec, level, opts \\ []) do
    case run_probe(repo, spec, level, opts) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("resolving #{spec} in #{repo} exited with #{status}:\n\n#{output}")
    end
  end

  # For the refusals, where a non-zero exit is half of what is under test.
  defp resolve(repo, spec, level, opts \\ []) do
    {output, status} = run_probe(repo, spec, level, opts)

    assert status != 0, "resolving #{spec} was expected to fail, and did not:\n\n#{output}"

    output
  end

  # `:env` entries replace rather than follow the defaults, because two entries
  # for one variable is not a thing an environment can hold and which of them
  # would win is the port driver's business rather than something to rely on.
  # `:path` puts a directory in front of PATH, which is how the shimmed git gets
  # found ahead of the real one.
  defp run_probe(repo, spec, level, opts) do
    probe = Path.join(repo, "probe.exs")
    File.write!(probe, @probe)

    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    env =
      Enum.map(@scrubbed, &{&1, nil}) ++
        @mix_env ++
        [
          {"BASELINE_SPEC", spec},
          {"BASELINE_LEVEL", to_string(level)},
          {"PATH", prepend_path(opts[:path])}
        ]

    System.cmd(mix, ["run", "--no-start", probe],
      cd: repo,
      stderr_to_stdout: true,
      env: replace_env(env, Keyword.get(opts, :env, []))
    )
  end

  defp prepend_path(nil), do: System.get_env("PATH")
  defp prepend_path(dir), do: dir <> ":" <> System.get_env("PATH")

  defp replace_env(env, overrides) do
    Enum.reduce(overrides, env, fn {name, value}, acc ->
      List.keystore(acc, name, 0, {name, value})
    end)
  end

  # `Regex.escape/1` because `rebuilt?` ends in one: unescaped, the `?` makes the
  # `t` optional and the pattern matches a field that does not exist.
  defp field(output, name) do
    case Regex.run(~r/^baseline\.#{Regex.escape(name)}=(.*)$/m, output) do
      [_line, value] -> value
      nil -> flunk("the probe printed no #{name}:\n\n#{output}")
    end
  end

  defp worktrees(repo) do
    repo
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
  end

  defp git!(cd, args) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: @git_env) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited with #{status}:\n\n#{output}")
    end
  end
end
