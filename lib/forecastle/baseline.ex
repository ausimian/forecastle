defmodule Forecastle.Baseline do
  @moduledoc """
  Resolves the *baseline* a relup is generated against from the spec that names
  it.

  A relup describes a transition, so generating one needs a previous release to
  compare the new one against. That previous release can come from three places,
  and this is the one grammar that names all three:

      rel:_build/prod/rel/my_app/releases/1.0.0/my_app   # an assembled release
      tar:artifacts/my_app-1.0.0.tar.gz                  # a shipped artefact
      ref:v1.0.0                                         # a git ref, built in a worktree

  A value carrying no prefix is a `rel:` path, which is what the switches meant
  before this module existed, so nothing that worked before this needs changing.
  The direction stays on the switch name and the source stays in the value:
  crossing the two into separate switches would be a switch per combination.

  ## `tar:` is the recommended source, and the reason is correctness

  `release_handler` picks a relup entry by from-version *string*. It never
  verifies that the code actually running is the code the relup was generated
  against. So a baseline rebuilt from source today is built with today's Elixir
  and OTP patch releases, today's hex tarballs for anything the lock does not
  fully pin, and today's compiler - and if the module set that comes out differs
  at all from what is deployed, the relup's instructions miss modules. The
  upgrade then loads some of the new code over a system still running the rest of
  the old, which is the same stale-code failure a hand-written appup causes,
  arrived at from the other direction.

  A relup generated against a rebuilt baseline describes a transition from a
  release that never existed. Where the artefact that was actually shipped still
  exists, `tar:` names it and the question does not arise.

  ## `ref:` is genuinely useful and genuinely second best

  It is the right answer for development, for testing an upgrade path before
  anything ships, and for the common case where nobody kept the artefact. What it
  must not do is pretend to be something it is not, so every `ref:` resolution
  says out loud that the baseline was rebuilt.

  Old refs also often do not build today - a yanked dependency, a deprecation
  that became an error, a compiler that no longer accepts something. That is
  another reason `tar:` is the answer where there is a choice, and it is why a
  failed baseline build says which commit failed rather than only what the build
  printed.

  ## The cache

  Everything this resolves that had to be produced is kept under
  `_build/castle/baselines`, and every entry in it is **immutable and complete**:

      _build/castle/baselines/
        tar-<digest of the artefact>/         # the unpacked release
        ref-<sha>/<build context>/            # build/ deps/ rel/ context.txt
        .staging-<pid>-<random>/              # work in progress, never read

  Nothing is ever built or unpacked in place. Work happens in a staging directory
  and the finished thing is *renamed* into position, so an entry exists only once
  it is whole. That is what makes "the directory is there" a safe answer to "is
  this baseline usable?", and it is what makes an interrupted run - out of disk, a
  killed build, a machine that went away - leave nothing behind that a later run
  would mistake for a cache hit. Two runs resolving the same baseline at the same
  time each build their own and the first to finish wins; the loser throws its
  copy away, because the two are the same thing by construction.

  ### What each entry is keyed on

  A cache key has to name everything that could make the contents different, or
  the cache hands back something that was produced for a different question.

  **`tar:` is keyed on a digest of the artefact's bytes.** Not on its path: a
  pipeline that writes `my_app-1.0.0.tar.gz` afresh on every build would
  otherwise be served the first build's release for ever. The artefact is copied
  into staging *first* and the digest taken of the copy, so the bytes that were
  hashed are the bytes that get unpacked - hashing the path and then unpacking the
  path is two reads of something that can change in between, and publishing B's
  contents under A's digest is a silent wrong answer for every later run.

  **`ref:` is keyed on the resolved sha and on the build context.** The sha
  because a branch name or a moved tag has to get a fresh entry rather than a
  stale hit, and `^{commit}` so that an annotated tag keys on the commit rather
  than on the tag object. The build context because the same commit built two ways
  is two different baselines: `MIX_ENV`, `MIX_TARGET`, the Elixir version and the
  ERTS version all change what comes out, and a cache that ignored them would hand
  a `dev` build to a `prod` caller, or modules compiled by last month's Elixir to
  a relup being generated against this month's. That last one matters more here
  than in an ordinary build cache, because drift between the baseline's toolchain
  and the target's is the whole reason `tar:` is the recommended source.

  Each entry carries a `context.txt` recording what it was built with, so what is
  in the cache can be read rather than inferred from a digest.

  ### The worktree

  The commit is checked out into a linked worktree inside the staging directory,
  beside — rather than around — the artefacts: staging holds `src/` and `out/`,
  and only `out/` is ever published. `MIX_BUILD_ROOT`, `MIX_DEPS_PATH` and the
  release's `--path` all point into `out/`, so removing the worktree keeps the
  build, and a removal that *fails* cannot put a checkout inside a published
  entry. The worktree is not taken out of what gets renamed into the cache; it
  was never in it.

  Under `_build` rather than anywhere in the tracked tree, which is the same
  lesson `Forecastle.Fixture` records: a second copy of the project inside the
  project gets picked up by the formatter and by `mix test`, and its `mix.exs`
  gets found by anything that walks the tree looking for one.

  A worktree registration whose directory has gone - a killed run, a deleted
  `_build` - is cleaned up, but only ever one this module made. `git worktree
  prune` is not used: it operates on every worktree in the repository, and a
  relup task has no business deregistering somebody's checkout that happens to be
  on an unmounted disk today.

  ### Recursion

  Building an old commit runs *its* `mix.exs`, and in a project using Castle that
  calls `Castle.customize/1`, which may itself want to generate a relup - and so
  resolve a baseline, and so build another commit. `CASTLE_BASELINE` is set to the
  sha being built for the duration of that build, and a `ref:` resolution that
  finds it already set refuses rather than recursing.

  It is deliberately a refusal rather than a depth limit. There is no build in
  which resolving a baseline *of a baseline* is the right thing to do, so a run
  that asks for one is misconfigured, and saying so beats quietly generating a
  relup against something nobody asked for.

  ## Two levels

  An appup coverage check needs only the compiled modules, which `mix compile`
  produces; a relup needs an assembled release, which costs a `mix release` on
  top. That is a large difference on a real project, so `resolve!/2` takes the
  level and does the smaller thing where the smaller thing is enough.

  The level only changes what `ref:` does. `rel:` and `tar:` name a release that
  has already been built, so both levels resolve to the same thing.

  The level is part of a `ref:` entry's key, so the two do not share a cache
  entry and a project that wants both pays for both. An earlier revision shared
  one entry between them and let a release satisfy a later compile, which is true
  of the artefacts but not of the guarantee: the shared entry had to be mutated in
  place to grow from one level to the other, and a directory that is still being
  written to cannot also be the signal that it is finished.
  """

  # The two shapes of compiled-module directory this can hand back, because they
  # are not the same shape and a caller globbing one has to know which it has:
  #
  #   - a release's `lib/` holds `<app>-<vsn>/ebin` per application
  #   - a Mix build's `lib/` holds `<app>/ebin`, with no version in the name
  #
  # `<lib_dir>/*/ebin` matches both, which is what `mix castle.relup` builds its
  # code path from, and is the only thing this promises about the layout.
  defstruct [:spec, :source, :level, :rel_path, :lib_dir, :rebuilt?]

  @typedoc "Where the baseline comes from."
  @type source :: :rel | :tar | :ref

  @typedoc """
  How much of the baseline is needed.

  `:compile` yields compiled modules, `:release` an assembled release. Only
  `:release` guarantees a `:rel_path`.
  """
  @type level :: :compile | :release

  @typedoc """
  A resolved baseline.

    * `:spec` - the spec exactly as it was given, for diagnostics
    * `:source` - which of the three sources it named
    * `:level` - the level it was resolved at
    * `:rel_path` - the `.rel` file *without* its extension, which is how
      `:systools` names a release. `nil` only for `ref:` at `:compile` level,
      where no release was assembled
    * `:lib_dir` - the directory holding one directory of compiled modules per
      application, matched by `<lib_dir>/*/ebin`
    * `:rebuilt?` - whether the baseline was rebuilt from source rather than
      being the artefact that shipped
  """
  @type t :: %__MODULE__{
          spec: binary(),
          source: source(),
          level: level(),
          rel_path: Path.t() | nil,
          lib_dir: Path.t(),
          rebuilt?: boolean()
        }

  # Set for the duration of a baseline build, and read at the top of every `ref:`
  # resolution. Named for Castle rather than for Forecastle because the recursion
  # it guards against arrives through `Castle.customize/1`, which is the other
  # half's entry point and the other half's business to read.
  @recursion_guard "CASTLE_BASELINE"

  # How many names to try before concluding that something other than a name
  # collision is wrong. Each candidate carries 8 random bytes, so needing a second
  # one at all already means something strange; needing this many means the
  # directory is not behaving like a directory.
  @staging_attempts 5

  @prefixes %{"rel:" => :rel, "tar:" => :tar, "ref:" => :ref}

  # What counts as "this value carries a source prefix", whether or not the
  # prefix names a source that exists. A mistyped `re:v1.0.0` has to be a
  # mistyped spec rather than a path to a file called `re:v1.0.0`, or the typo
  # resolves to a missing release and says so in terms that mention neither the
  # spec nor the typo.
  #
  # Two characters at least before the colon, which is what keeps a Windows drive
  # letter out of it. Windows is not supported here (see the README) but being
  # gratuitously unable to name `c:/...` would be a poor way to say so, and
  # `rel:` in front of anything is the escape hatch for a path that genuinely
  # looks like this.
  @scheme ~r/\A[a-z][a-z0-9]+:/

  # A git object id and nothing else: 40 hex for sha1, 64 for sha256. Git is
  # asked for one and its answer is checked against this rather than trusted,
  # because an object id becomes a directory name and a revision to check out.
  @object_id ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @doc """
  Whether the value carries a source prefix.

  True for `rel:`, `tar:` and `ref:`, and true for anything else shaped like a
  prefix, so that a mistyped one is recognisable as a spec rather than read as a
  path. Used where a switch takes a path and never a spec, so that giving it one
  is answered rather than resolved.
  """
  @spec spec?(binary()) :: boolean()
  def spec?(value) when is_binary(value), do: Regex.match?(@scheme, value)

  @doc """
  Splits a spec into its source and its value, without touching the filesystem.

  A value with no prefix is a `rel:` path. Raises on a prefix that names no
  source, and on a spec with nothing after the prefix.
  """
  @spec parse!(binary()) :: {source(), binary()}
  def parse!(""), do: Mix.raise("a baseline spec cannot be empty: there is nothing to resolve.")

  def parse!(spec) when is_binary(spec) do
    case Regex.run(@scheme, spec) do
      nil -> {:rel, present!(spec, spec)}
      [prefix] -> {source!(prefix, spec), present!(String.replace_prefix(spec, prefix, ""), spec)}
    end
  end

  defp source!(prefix, spec) do
    case Map.fetch(@prefixes, prefix) do
      {:ok, source} ->
        source

      :error ->
        Mix.raise(
          "#{spec} names the baseline source #{inspect(prefix)}, and there is no such source. " <>
            "Use #{known_sources()}, or no prefix at all for a path to an assembled release."
        )
    end
  end

  defp known_sources do
    @prefixes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`")
  end

  defp present!("", spec) do
    Mix.raise("#{inspect(spec)} names no baseline: there is nothing after the prefix.")
  end

  defp present!(value, _spec), do: value

  @doc """
  Resolves a spec to a baseline on disk, building it if that is what the source
  means.

  `:release` assembles a release where one has to be built; `:compile` stops at
  compiled modules. Only `ref:` is affected by the level - the other two sources
  name something that was built already.

  Raises with an actionable message on anything it cannot resolve.
  """
  @spec resolve!(binary(), level()) :: t()
  def resolve!(spec, level) when is_binary(spec) and level in [:compile, :release] do
    # Dispatched here rather than through clauses of one private function so that
    # each source can keep its own helpers beside it. They are long enough that
    # interleaving three sets of them would be worse than the indirection.
    case parse!(spec) do
      {:rel, path} -> from_release(path, spec, level)
      {:tar, path} -> from_tarball(path, spec, level)
      {:ref, ref} -> from_ref(ref, spec, level)
    end
  end

  ## rel: an assembled release

  # Deliberately no filesystem check. A `rel:` path is what every switch meant
  # before this module existed, and `mix castle.relup` reads it a moment later
  # and says exactly what it could not read and why - so checking here would
  # either duplicate that message or replace it with a worse one.
  defp from_release(path, spec, level) do
    %__MODULE__{
      spec: spec,
      source: :rel,
      level: level,
      rel_path: path,
      lib_dir: release_lib_dir(path),
      rebuilt?: false
    }
  end

  ## tar: a shipped artefact

  defp from_tarball(path, spec, level) do
    rel_path = path |> unpack!(spec) |> release_rel_path!(spec, :tar)

    %__MODULE__{
      spec: spec,
      source: :tar,
      level: level,
      rel_path: rel_path,
      lib_dir: release_lib_dir(rel_path),
      rebuilt?: false
    }
  end

  # The artefact is copied into staging before anything else looks at it, and
  # every question after that is asked of the copy. That is one extra pass over
  # the file, and it buys the only thing that makes a content-addressed cache
  # mean anything: the bytes that were hashed are the bytes that were unpacked.
  #
  # Hashing the path and then unpacking the path reads it twice. A pipeline that
  # rewrites `my_app-1.0.0.tar.gz` between the two - and rewriting it is exactly
  # what a pipeline does - publishes the second artefact's contents under the
  # first one's digest, and every later run asking for the first silently gets
  # the second. A relup generated against the wrong release is precisely the
  # failure this whole feature exists to make impossible, so it does not get to
  # arrive through the cache.
  # The artefact as it lies is hashed first, and that answer is only ever used to
  # ask whether it has already been unpacked. Nothing is published from it, so
  # the artefact changing under this costs nothing: whichever bytes were hashed,
  # a hit is an entry that really was unpacked from bytes with that digest.
  #
  # It is the *miss* that has to be careful, and that is where the copy is.
  defp unpack!(tarball, spec) do
    unless File.regular?(tarball) do
      Mix.raise("#{spec} names #{tarball}, which is not a file that can be read.")
    end

    case cached_tree(digest(tarball)) do
      nil -> unpack_into_cache!(tarball, spec)
      root -> root
    end
  end

  defp cached_tree(digest) do
    root = Path.join(cache_dir(), "tar-" <> digest)

    if File.dir?(root), do: root
  end

  defp unpack_into_cache!(tarball, spec) do
    staging = staging_dir()

    try do
      snapshot = Path.join(staging, "artefact")
      copy!(tarball, snapshot, spec)

      root = Path.join(cache_dir(), "tar-" <> digest(snapshot))

      if File.dir?(root) do
        root
      else
        tree = Path.join(staging, "tree")
        File.mkdir_p!(tree)
        untar!(snapshot, spec, tree)
        publish!(tree, root)
        root
      end
    after
      File.rm_rf(staging)
    end
  end

  defp copy!(from, to, spec) do
    case File.cp(from, to) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("#{spec} could not be read: #{:file.format_error(reason)}")
    end
  end

  # Nothing here checks the members for `..` or a leading `/`: `:erl_tar` refuses
  # them itself, with `unsafe_path` and `unsafe_symlink`, and re-deriving that
  # check here would be a second implementation of it to keep correct. What this
  # does do is give it a directory of its own to be confined to, and that
  # directory is inside staging rather than being the cache entry, so a refusal
  # part way through leaves nothing a later run would take for a whole unpacking.
  defp untar!(tarball, spec, into) do
    refuse_unfaithful_members!(tarball, spec)

    case :erl_tar.extract(to_charlist(tarball), [:compressed, {:cwd, to_charlist(into)}]) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("#{spec} could not be unpacked: #{format_tar_error(reason)}")
    end
  end

  # The member types `:erl_tar` reproduces *faithfully*, which is a shorter list
  # than the ones it accepts. Verified in OTP 28.3, `stdlib-7.2`:
  # `write_extracted_element/3` has a clause per type, and two of them are not
  # fidelity at all - `char` and `block` and `fifo` are created as **empty
  # regular files**, and everything else, a **hard link** included, reaches a
  # final clause that logs "unsupported type" and returns `not_written`. Either
  # way the extraction comes back `:ok`, so a member that was dropped or replaced
  # is indistinguishable from one that arrived intact.
  @faithful [:regular, :directory, :symlink]

  # The hard link is the one that turns up in practice, and a release tree is
  # full of identical files for `tar` to store as one. `:erl_tar.create/3` does
  # not write them, so an artefact Mix packaged has none - but a `tar:` baseline
  # is meant to be the artefact that *shipped*, which may well have been rolled
  # by GNU tar somewhere in a pipeline, and GNU tar does.
  #
  # Silently, that costs a `.beam` or a whole `.app` out of `lib/<app>-<vsn>`,
  # and the relup is then generated against a release missing modules - the exact
  # failure the baseline resolver exists to make impossible, arriving through the
  # one source that was supposed to be beyond doubt. A device node or a FIFO at a
  # payload path is the same failure with an empty file in place of the modules.
  #
  # So the archive is read before it is unpacked and anything that would not come
  # back as itself is named. Refusing a device node in a release tarball costs
  # nothing real: there is no release that wants one, and `rel:` names an
  # already-unpacked tree for anyone who disagrees.
  defp refuse_unfaithful_members!(tarball, spec) do
    case :erl_tar.table(to_charlist(tarball), [:compressed, :verbose]) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn {_name, type, _size, _mtime, _mode, _uid, _gid} ->
          type in @faithful
        end)
        |> refuse_members!(spec)

        refuse_colliding_members!(entries, spec)

      {:error, reason} ->
        Mix.raise("#{spec} could not be read: #{format_tar_error(reason)}")
    end
  end

  # Two members that land on one path are the other way an archive can unpack
  # into something that is not what it lists. `:erl_tar` extracts in order, so a
  # regular file followed by another writes the second; a *symlink* over an
  # existing file is `file:make_symlink/2` returning `eexist`, and which member
  # wins is then a property of the order rather than of the archive. Either way
  # the tree that gets published is not the tree the archive describes, and a
  # relup generated against it is generated against something that never shipped.
  #
  # Names are compared after the two transformations `:erl_tar` itself applies -
  # a leading `/` is dropped, and `./` segments collapse - and after nothing else.
  # Predicting its destination in general would mean a second implementation of
  # `make_safe_path/2` to keep in step with OTP, which is the same reasoning that
  # keeps the traversal check out of here; what this does instead is refuse an
  # archive that names one thing twice, which no release tarball does.
  defp refuse_colliding_members!(entries, spec) do
    entries
    |> Enum.group_by(fn {name, _type, _size, _mtime, _mode, _uid, _gid} ->
      name |> to_string() |> String.replace_leading("/", "") |> Path.expand("/")
    end)
    |> Enum.reject(&match?({_destination, [_only]}, &1))
    |> Enum.each(fn {destination, colliding} ->
      Mix.raise(
        "#{spec} holds #{length(colliding)} members that unpack to the same path " <>
          "(#{destination}): " <>
          describe_members(colliding) <>
          ". Which of them survives is decided by the order they appear in rather than by " <>
          "the archive, so what would be unpacked is not what it lists."
      )
    end)
  end

  defp refuse_members!([], _spec), do: :ok

  defp refuse_members!(unfaithful, spec) do
    Mix.raise(
      "#{spec} holds #{length(unfaithful)} member(s) that unpacking would not reproduce as " <>
        "themselves (" <>
        describe_members(unfaithful) <>
        "). Erlang's tar reader writes regular files, directories and symlinks: a hard link " <>
        "is dropped and a device or FIFO becomes an empty file, in both cases without " <>
        "failing. Repack the artefact without them - `tar --hard-dereference` writes a hard " <>
        "link as the file it points at - or name the unpacked release with `rel:` instead."
    )
  end

  # Capped, because an archive built the wrong way could have thousands and the
  # first few say the same thing as all of them.
  defp describe_members(unfaithful) do
    shown = Enum.take(unfaithful, 5)

    listed =
      Enum.map_join(shown, ", ", fn {name, type, _size, _mtime, _mode, _uid, _gid} ->
        "#{name} (#{type})"
      end)

    if length(unfaithful) > length(shown), do: listed <> ", ...", else: listed
  end

  # `:erl_tar` reports either a formattable term or a bare atom depending on
  # where it failed, and `format_error/1` on the bare atom yields the atom's own
  # name back rather than a sentence. Both are more use than `inspect/1` alone,
  # and neither is reliably a sentence, so the term goes in as well.
  defp format_tar_error(reason) do
    "#{:erl_tar.format_error(reason)} (#{inspect(reason)})"
  end

  # The version directory's copy, which is the one `:systools` wants named on its
  # command line. A release tarball also carries `releases/<name>-<vsn>.rel` at
  # the top of `releases/`, which this glob does not reach.
  #
  # An *unpacked* release holds two `.rel` files in its version directory and
  # that is normal: `release_handler:do_unpack_release/4` copies
  # `releases/<name>-<vsn>.rel` in beside Mix's `<name>.rel` "for backwards
  # compatibility reasons with older systools:make_tar" (OTP-9746), and they are
  # byte-identical. So a tarball made from a deployment rather than from a build
  # matches twice and still names one release, which is why duplicates that
  # consult to the same term collapse rather than being refused.
  #
  # Both failures are reachable from `tar:` and from `ref:`, and they are not the
  # same failure seen twice: a tarball with no release in it is the wrong
  # tarball, while a built commit with no release in it is a commit that defines
  # none. Saying "is it a release tarball?" about a git ref would send the reader
  # to look at the wrong thing entirely, so the source picks the sentence.
  defp release_rel_path!(root, spec, source) do
    root
    |> Path.join("releases/*/*.rel")
    |> Path.wildcard()
    |> Enum.uniq_by(&:file.consult(to_charlist(&1)))
    |> case do
      [rel] -> Path.rootname(rel)
      [] -> Mix.raise(no_release(spec, root, source))
      many -> Mix.raise(many_releases(spec, root, many, source))
    end
  end

  defp no_release(spec, root, :tar) do
    "#{spec} unpacked without a release file in it: nothing matches " <>
      "releases/<vsn>/<name>.rel under #{root}. Is it a release tarball?"
  end

  defp no_release(spec, root, :ref) do
    "#{spec} built without producing a release: nothing matches " <>
      "releases/<vsn>/<name>.rel under #{root}. Does that commit define a release " <>
      "for `mix release` to assemble?"
  end

  defp many_releases(spec, root, many, source) do
    "#{spec} holds #{length(many)} different releases (" <>
      Enum.map_join(many, ", ", &Path.relative_to(&1, root)) <>
      "), so there is no one baseline in it. " <> name_one(source)
  end

  defp name_one(:tar), do: "Name the release with `rel:` instead."

  defp name_one(:ref) do
    "A `ref:` baseline takes whatever `mix release` assembles with no name given, so a " <>
      "commit defining more than one release cannot be named this way. Use `tar:` or `rel:`."
  end

  ## ref: a git ref, built in a worktree

  defp from_ref(ref, spec, level) do
    refuse_recursion!(spec)

    git = git_executable!()
    ensure_repository!(git, spec)

    sha = resolve_sha!(git, ref, spec)
    prefix = project_prefix!(git, spec)
    context = build_context(level, prefix)

    # Everything the build needs to know about itself, in one place: it is passed
    # through five functions and threading six arguments through all of them
    # obscures which of them each one actually uses.
    build = %{git: git, sha: sha, spec: spec, level: level, prefix: prefix, context: context}
    entry = Path.join([cache_dir(), "ref-" <> sha, context_key(context)])

    ensure_built!(build, entry)
    announce_rebuilt(spec, sha)

    baseline(spec, level, entry)
  end

  # Asked before the key is built rather than at build time, because *which
  # project* is being built out of the commit is part of what the key has to
  # name. An umbrella's children share one `_build`, so `apps/a` and `apps/b`
  # resolving the same ref would otherwise land on one entry and the second would
  # be handed the first's artefacts - a different project's, under a key that
  # said nothing about which.
  #
  # `--show-prefix` is git's own answer to "where am I relative to the top
  # level", asked of the *caller's* directory. Deriving it by subtracting the top
  # level from the working directory gets it wrong wherever a symlink stands
  # between the two, which on macOS is `/tmp` every time.
  defp project_prefix!(git, spec) do
    case out(git, ["rev-parse", "--show-prefix"], File.cwd!()) do
      {output, 0} ->
        trim_eol(output)

      {_output, status} ->
        Mix.raise(
          "#{spec}: could not work out where this project sits in its repository. " <>
            "git rev-parse --show-prefix exited with #{status}; what it had to say about " <>
            "that is on standard error."
        )
    end
  end

  defp baseline(spec, :release, entry) do
    rel_path = entry |> release_dir() |> release_rel_path!(spec, :ref)

    %__MODULE__{
      spec: spec,
      source: :ref,
      level: :release,
      rel_path: rel_path,
      lib_dir: release_lib_dir(rel_path),
      rebuilt?: true
    }
  end

  # No release was assembled, so there is no `.rel` to name and the modules are
  # where Mix left them: one directory per application, with no version in the
  # name.
  defp baseline(spec, :compile, entry) do
    %__MODULE__{
      spec: spec,
      source: :ref,
      level: :compile,
      rel_path: nil,
      lib_dir: compiled_lib_dir!(entry, spec),
      rebuilt?: true
    }
  end

  # Found rather than reconstructed. Mix's build directory is
  # `<root>/<target_><env>`, except that `build_per_environment: false` replaces
  # the environment with `shared` and `:host` contributes no target prefix - and
  # the first of those is the *baseline project's* configuration, which the
  # calling project cannot know and must not guess. `MIX_BUILD_ROOT` belongs to
  # this entry alone, so whatever single directory is under it is the one this
  # build wrote.
  defp compiled_lib_dir!(entry, spec) do
    case Path.wildcard(Path.join(build_dir(entry), "*/lib")) do
      [lib] ->
        lib

      [] ->
        Mix.raise(
          "#{spec} compiled without leaving anything under #{build_dir(entry)}. " <>
            "Does that commit build?"
        )

      many ->
        Mix.raise(
          "#{spec} left #{length(many)} build directories under #{build_dir(entry)} (" <>
            Enum.map_join(many, ", ", &Path.relative_to(&1, build_dir(entry))) <>
            "), so which of them holds the baseline is not decidable here."
        )
    end
  end

  defp refuse_recursion!(spec) do
    case System.get_env(@recursion_guard) do
      nil ->
        :ok

      sha ->
        Mix.raise("""
        #{spec} was asked for while building the baseline #{short(sha)}.

        Building a git ref runs that commit's own mix.exs, and a project using \
        Castle configures its release from there - so a baseline whose build asks \
        for a baseline of its own would go round again, against a release nobody \
        named.

        Make the baseline build not ask for one. `Castle.customize/1` can read \
        #{@recursion_guard} to tell that it is running inside a baseline build \
        rather than a real one.
        """)
    end
  end

  ## What a ref: entry is keyed on

  # What decides the contents of an entry, as far as that is knowable.
  #
  # `level`, `mix_env` and `mix_target` are what this module hands the child.
  # `project` is which project inside the commit is being built, and it is here
  # because an umbrella's children share one `_build`: without it `apps/a` and
  # `apps/b` resolving the same ref land on one entry, and whichever built first
  # answers for both.
  #
  # The Elixir and ERTS versions are here for a reason specific to what a
  # baseline is *for*. An ordinary build cache can leave them out because Mix
  # notices a version change and recompiles; nothing recompiles a hit here, since
  # the whole point is to skip the build. Without them a toolchain upgrade leaves
  # every cached baseline compiled by the old one and the relup is generated
  # between module sets from two different compilers - the drift `tar:` exists to
  # avoid, arriving through the door `ref:` came in by. `os` is the same argument
  # for a `_build` shared across a container boundary, which a bind mount does
  # every day; the architecture is left out of it because two architectures
  # sharing one `_build` on one operating system is not a thing that happens, and
  # a full `system_architecture` would rebuild every baseline on an OS point
  # release.
  #
  # **What this cannot cover, and does not pretend to.** A `mix.exs` is arbitrary
  # code and may read anything - an environment variable, a file, the clock - to
  # decide what it builds. No key computable from here can name that, and Mix's
  # own build directory does not try either. The contract is: this keys what
  # Forecastle chooses and what the toolchain is. A project whose build depends on
  # something outside that has two honest options, and both are better than a key
  # that grew until it looked complete - name the artefact with `tar:`, which is
  # the recommended source anyway, or clear `_build/castle/baselines`.
  defp build_context(level, prefix) do
    {family, name} = :os.type()

    [
      {"level", to_string(level)},
      {"project", if(prefix == "", do: ".", else: prefix)},
      {"mix_env", to_string(Mix.env())},
      {"mix_target", to_string(Mix.target())},
      {"elixir", System.version()},
      {"erts", to_string(:erlang.system_info(:version))},
      {"os", "#{family}-#{name}"}
    ]
  end

  defp context_key(context) do
    context
    |> render_context()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp render_context(context) do
    Enum.map_join(context, "\n", fn {key, value} -> "#{key}=#{value}" end) <> "\n"
  end

  ## Building a ref in a worktree

  # An entry exists only when it is whole, so its presence is the whole of the
  # question. Nothing is built in place and nothing is mutated after publication,
  # which is what lets two runs resolve the same baseline at once without either
  # having to know about the other.
  defp ensure_built!(build, entry) do
    if File.dir?(entry) do
      Mix.shell().info(
        "#{build.spec}: reusing the baseline already built for #{short(build.sha)}."
      )
    else
      build!(build, entry)
    end
  end

  # The checkout and the artefacts are siblings inside staging, and only the
  # artefacts are published. That is structural rather than careful: the worktree
  # is not *removed from* the thing that gets renamed into the cache, it was
  # never inside it. A cleanup that fails - a checkout whose permissions changed
  # under it, a filesystem that will not let go - can then leave rubbish in
  # staging and say so, without a `src/` and a dangling worktree pointer ending
  # up inside an entry that is supposed to be immutable and finished.
  defp build!(build, entry) do
    staging = staging_dir()

    try do
      worktree = Path.join(staging, "src")
      artefacts = Path.join(staging, "out")
      File.mkdir_p!(artefacts)

      add_worktree!(build, worktree)

      try do
        run_build!(build, worktree, artefacts)
      after
        remove_worktree!(build.git, worktree)
      end

      File.write!(Path.join(artefacts, "context.txt"), render_context(build.context))
      publish!(artefacts, entry)
    after
      File.rm_rf(staging)
    end
  end

  defp add_worktree!(%{git: git, sha: sha, spec: spec}, worktree) do
    # Only ever a registration this module made, and only one whose directory is
    # already gone. `git worktree prune` would do this job in one word, and it is
    # the wrong word: it operates on every worktree in the repository, so a
    # checkout of somebody's on a disk that is not mounted today would lose its
    # administrative record because a relup task ran.
    prune_own_worktrees(git)

    case cmd(git, ["worktree", "add", "--detach", worktree, sha], File.cwd!()) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise(
          "#{spec}: could not check out #{short(sha)} into #{worktree} " <>
            "(git worktree add exited with #{status}):\n\n" <> String.trim_trailing(output)
        )
    end
  end

  # A worktree's registration is a directory under `<common git dir>/worktrees`,
  # holding a `gitdir` file naming the checkout's own `.git`. Removing that
  # directory is what `git worktree prune` does; doing it here is the same thing
  # with a filter on it.
  #
  # Two filters, both of them the point. The path has to be inside this cache, so
  # nothing outside it can be touched whatever else is registered. And a locked
  # worktree is left alone, because `git worktree lock` is how somebody says "the
  # directory is missing on purpose" - which is exactly the case a blanket prune
  # gets wrong.
  defp prune_own_worktrees(git) do
    git
    |> worktree_records()
    |> Enum.filter(&stale_baseline_record?/1)
    |> Enum.each(&File.rm_rf/1)
  end

  # `out/3` rather than `cmd/4`, as everywhere the output is a value: a warning
  # git wrote to standard error would otherwise become part of the directory this
  # then goes looking for registrations in.
  defp worktree_records(git) do
    case out(git, ["rev-parse", "--git-common-dir"], File.cwd!()) do
      {output, 0} ->
        output
        |> trim_eol()
        |> Path.expand(File.cwd!())
        |> Path.join("worktrees/*")
        |> Path.wildcard()

      {_output, _status} ->
        []
    end
  end

  defp stale_baseline_record?(record) do
    with false <- File.exists?(Path.join(record, "locked")),
         {:ok, gitdir} <- File.read(Path.join(record, "gitdir")) do
      path = gitdir |> String.trim() |> Path.dirname() |> Path.expand()

      String.starts_with?(path, Path.expand(cache_dir()) <> "/") and not File.dir?(path)
    else
      _locked_or_unreadable -> false
    end
  end

  # `--force`, because the build modifies the checkout. `mix deps.get` rewrites
  # `mix.lock` wherever the old lock cannot be satisfied as written, and an
  # unforced remove refuses a worktree with modified tracked files in it. Nothing
  # in there is worth keeping: every artefact was written outside it.
  #
  # A failure here is reported rather than raised. The baseline is built by this
  # point, so throwing the whole resolution away over a directory that would not
  # come off would be a worse outcome than saying so - and the fallback clears the
  # directory anyway, leaving a registration the next run's own prune will take.
  defp remove_worktree!(git, worktree) do
    case cmd(git, ["worktree", "remove", "--force", worktree], File.cwd!()) do
      {_output, 0} -> :ok
      {output, _status} -> remove_by_hand(worktree, output)
    end
  end

  # Reported for what actually happened rather than for what was attempted. This
  # used to say the contents had been removed while ignoring whether the removal
  # worked, which turns a directory somebody has to go and deal with into a line
  # saying it was already dealt with.
  defp remove_by_hand(worktree, output) do
    case File.rm_rf(worktree) do
      {:ok, _removed} ->
        Mix.shell().error(
          "could not remove the baseline worktree #{worktree}, and deleted its contents " <>
            "instead. Its registration goes on the next resolution's own cleanup.\n\n" <>
            String.trim_trailing(output)
        )

      {:error, reason, path} ->
        Mix.shell().error(
          "could not remove the baseline worktree #{worktree}, and could not delete " <>
            "#{path} either: #{:file.format_error(reason)}. It is still there; " <>
            "`git worktree remove --force #{worktree}` is what clears it. The baseline " <>
            "itself was built and is unaffected - nothing in that directory is part of " <>
            "it.\n\n" <> String.trim_trailing(output)
        )
    end
  end

  defp run_build!(build, worktree, artefacts) do
    mix =
      System.find_executable("mix") ||
        Mix.raise("a `ref:` baseline is built by running mix, and mix is not on PATH.")

    project = project_dir!(worktree, build.prefix, build.sha, build.spec)
    env = build_env(artefacts, build.sha)

    Mix.shell().info(
      "#{build.spec}: building the baseline for #{short(build.sha)} in #{project}. " <>
        "This #{describe_level(build.level)} that commit and can take a while."
    )

    mix!(mix, ["deps.get"], project, env, build)
    mix!(mix, build_args(artefacts, build.level), project, env, build)
  end

  # The worktree is a checkout of the *repository*, and the project is not
  # necessarily at the root of one - a monorepo, or an umbrella that lives in a
  # subdirectory, puts it somewhere else. `--show-prefix` is git's own answer to
  # "where am I relative to the top level", so the same relative position inside
  # the worktree is where the build has to run.
  #
  # Asked of git rather than derived by subtracting the top level from the working
  # directory, which gets the answer wrong wherever a symlink stands between the
  # two - `/tmp` on macOS being the everyday case.
  defp project_dir!(worktree, prefix, sha, spec) do
    project = if prefix == "", do: worktree, else: Path.join(worktree, prefix)

    unless File.regular?(Path.join(project, "mix.exs")) do
      Mix.raise(
        "#{spec}: #{short(sha)} has no mix.exs at #{describe_prefix(prefix)}. The project " <>
          "was somewhere else at that commit, so there is nothing there to build."
      )
    end

    project
  end

  defp describe_prefix(""), do: "the repository root"
  defp describe_prefix(prefix), do: prefix

  defp describe_level(:compile), do: "compiles"
  defp describe_level(:release), do: "compiles and assembles a release from"

  defp build_args(_staging, :compile), do: ["compile"]

  defp build_args(staging, :release) do
    ["release", "--overwrite", "--path", release_dir(staging)]
  end

  # Every path an artefact could be written to points outside the worktree, so
  # that removing the worktree keeps the build rather than throwing it away.
  #
  # `MIX_BUILD_PATH` is unset rather than set, because it names one build
  # directory outright and takes precedence over `MIX_BUILD_ROOT` - one inherited
  # from the calling build would put this commit's artefacts where the calling
  # project's already are, which is the failure a build root per baseline exists
  # to prevent, arrived at from outside.
  #
  # `MIX_ENV` is the calling build's, not a hardcoded `prod`. A relup compares a
  # baseline against a release, and comparing a `prod` release with a `dev`
  # baseline would report differences that are the environment rather than the
  # change. It is in the cache key for the same reason.
  # `MIX_TARGET` is passed rather than left to be inherited. `Mix.target/0` is
  # process state in the calling build, not necessarily an environment variable -
  # it can come from `def cli`'s `preferred_targets` or from `Mix.target/1` - and
  # `System.cmd/3` carries none of that across. Left out, the child could build
  # for `:host` while the entry it is published under claims the caller's target.
  # It is in the cache key, so what the key says and what was built have to be
  # the same thing.
  #
  # `MIX_EXS` is cleared, and it is the one that would be silently catastrophic.
  # It names the full path of the project file, so an absolute one inherited from
  # the calling build would have the child load *the current checkout's* mix.exs
  # while standing in a worktree of an old commit - and then publish the result
  # under that commit's key. The baseline would be configured by today's code and
  # nothing would say so. The child has to read the mix.exs it checked out;
  # `project_dir!/4` has already established there is one.
  defp build_env(staging, sha) do
    [
      {"MIX_ENV", to_string(Mix.env())},
      {"MIX_TARGET", to_string(Mix.target())},
      {"MIX_EXS", nil},
      {"MIX_BUILD_ROOT", build_dir(staging)},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", Path.join(staging, "deps")},
      {@recursion_guard, sha}
    ]
  end

  # Captured rather than streamed, so that a failure can be reported with the
  # output that explains it beside the commit that produced it - a build failing
  # in a directory the caller never named is not a failure they can go and read
  # the scrollback for. The cost is silence while a long build runs, which is
  # what the announcement before it is for.
  defp mix!(mix, args, project, env, %{spec: spec, sha: sha}) do
    case cmd(mix, args, project, env) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("""
        #{spec}: the baseline for #{short(sha)} could not be built. \
        `mix #{Enum.join(args, " ")}` exited with #{status}.

        An old commit often does not build today - a yanked dependency, a \
        deprecation that became an error - which is why an artefact named with \
        `tar:` is the better baseline wherever one still exists.

        #{String.trim_trailing(output)}
        """)
    end
  end

  ## Saying what a baseline is

  # Said on every `ref:` resolution, cache hit or not, because it is a property
  # of the baseline rather than of the work done to get it. A relup is read by
  # whoever deploys it, and "generated against a rebuilt 1.0.0" and "generated
  # against the 1.0.0 that shipped" are different claims about the same file.
  defp announce_rebuilt(spec, sha) do
    Mix.shell().info(
      "#{spec}: this baseline was rebuilt from #{short(sha)} and is not the release that " <>
        "was deployed. Rebuilding picks up today's Elixir, OTP and dependencies, so its " <>
        "module set can differ from the running one. Use `tar:` where the shipped artefact " <>
        "still exists."
    )
  end

  ## Asking git for a value

  defp git_executable! do
    System.find_executable("git") ||
      Mix.raise("a `ref:` baseline is built from a git checkout, and git is not on PATH.")
  end

  defp ensure_repository!(git, spec) do
    case cmd(git, ["rev-parse", "--git-dir"], File.cwd!()) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        Mix.raise(
          "#{spec} names a git ref, and #{File.cwd!()} is not inside a git repository:\n\n" <>
            String.trim_trailing(output)
        )
    end
  end

  # `^{commit}` rather than the bare ref, so that an annotated tag resolves to
  # the commit it points at rather than to the tag object - a tag object's sha is
  # not something `git worktree add` can check out, and it would key the cache on
  # a different value for the same tree.
  #
  # `--end-of-options` because the ref comes off a command line and can therefore
  # begin with a dash. `--verify` already refuses an option-shaped revision on
  # every git this supports - measured, rather than assumed - so this changes no
  # behaviour today; what it does is stop that from resting on `--verify` keeping
  # a property it does not document. It needs git 2.24, which is newer than the
  # 2.15 that `--is-shallow-repository` below already requires.
  #
  # Read with `out/3` rather than `cmd/4`: git writes advice and warnings to
  # standard error - dubious ownership, a deprecated config key, a hint about
  # something unrelated - and a command whose output *is* a value must not have
  # those folded into it. One did exactly that, and the warning lines went on to
  # become part of a directory name and part of a revision to check out.
  defp resolve_sha!(git, ref, spec) do
    args = ["rev-parse", "--verify", "--quiet", "--end-of-options", ref <> "^{commit}"]

    case out(git, args, File.cwd!()) do
      {output, 0} -> object_id!(String.trim(output), ref, spec)
      {_output, _status} -> refuse_unresolvable!(git, ref, spec)
    end
  end

  defp object_id!(value, ref, spec) do
    if Regex.match?(@object_id, value) do
      value
    else
      Mix.raise(
        "#{spec}: git resolved #{inspect(ref)} to something that is not an object id: " <>
          "#{inspect(value)}."
      )
    end
  end

  # A shallow clone is the case worth naming, because CI makes them constantly -
  # `actions/checkout` and GitLab's default both fetch a single commit - and the
  # tag being generated against is then simply not in the object store. Left to
  # itself that surfaces as `git worktree add` failing on an unknown revision,
  # which says nothing about why the revision is unknown or what to do about it.
  defp refuse_unresolvable!(git, ref, spec) do
    if shallow?(git) do
      Mix.raise("""
      #{spec} names no commit in this repository, which is a shallow clone.

      A shallow clone holds only the history it was cloned with, so a tag or a \
      commit outside it is not there to build. Fetch the rest of it:

          git fetch --tags --unshallow

      In CI, ask the checkout for full history instead - `fetch-depth: 0` for \
      actions/checkout, `GIT_DEPTH: 0` for GitLab.
      """)
    else
      Mix.raise("""
      #{spec} names no commit in this repository.

      Check the spelling of #{inspect(ref)}. If it is a tag that was pushed after \
      this clone last fetched, `git fetch --tags` will bring it in.
      """)
    end
  end

  defp shallow?(git) do
    case out(git, ["rev-parse", "--is-shallow-repository"], File.cwd!()) do
      {output, 0} -> String.trim(output) == "true"
      {_output, _status} -> false
    end
  end

  ## Paths

  # `_build/castle/baselines`, beside the environments rather than inside one:
  # what is cached is a commit or an artefact, and neither belongs to the
  # environment the calling build happens to be running in. What the environment
  # does belong to is a `ref:` entry's key, which is where it is accounted for.
  #
  # `Mix.Project.build_path/0` is `<build root>/<env>` and there is no public
  # accessor for the root on its own, so the environment comes back off the end.
  # That holds for `MIX_BUILD_ROOT` too, which is how the test suite gives each
  # fixture version a build root of its own.
  defp cache_dir, do: Path.join([Path.dirname(Mix.Project.build_path()), "castle", "baselines"])

  defp build_dir(dir), do: Path.join(dir, "build")
  defp release_dir(dir), do: Path.join(dir, "rel")

  # A `.rel` path is `<release>/releases/<vsn>/<name>`, so the release's library
  # directory - one `<app>-<vsn>/ebin` per application - is three levels up.
  defp release_lib_dir(rel_path), do: Path.expand(Path.join(rel_path, "../../../lib"))

  # Inside the cache directory, so the rename that publishes it is within one
  # filesystem, and unmistakable for a finished entry: a leading dot, and a name
  # nothing looks up. Unique per run, because two runs resolving the same
  # baseline at once must not share a directory - which is the whole reason the
  # work happens somewhere other than where it ends up.
  # The directory is *claimed*, not chosen and then cleared. `File.mkdir/1` is
  # `mkdir(2)`, which either creates the directory or tells you somebody else has
  # it - and that atomicity is the whole mechanism, because a name this run
  # believes is unique is not something it may act on destructively.
  #
  # It once cleared the candidate with `File.rm_rf!/1` first, on the reasoning
  # that the name carried the OS pid and a per-run counter and so could not
  # already be taken. Both halves of that are weaker than they look: two BEAMs in
  # separate PID namespaces - two containers over one bind-mounted `_build` - can
  # hold the same pid, and `System.unique_integer/1` is unique within one BEAM
  # rather than between them. The two runs then agree on a name, and the second
  # deletes the first's live workspace out from under it. Random bytes make the
  # collision vanishingly unlikely and `mkdir` makes it harmless.
  defp staging_dir do
    File.mkdir_p!(cache_dir())
    claim_staging_dir(@staging_attempts)
  end

  defp claim_staging_dir(0) do
    Mix.raise(
      "could not claim a staging directory under #{cache_dir()}: every candidate name was " <>
        "already taken. Something else is writing there."
    )
  end

  defp claim_staging_dir(attempts) do
    token = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    dir = Path.join(cache_dir(), ".staging-#{System.pid()}-#{token}")

    case File.mkdir(dir) do
      :ok ->
        dir

      {:error, :eexist} ->
        claim_staging_dir(attempts - 1)

      {:error, reason} ->
        Mix.raise("#{dir} could not be created: #{:file.format_error(reason)}")
    end
  end

  defp publish!(staging, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case File.rename(staging, dest) do
      :ok ->
        :ok

      # Another run published the same baseline while this one was working. The
      # key names everything that decides the contents, so the two are the same
      # thing and there is nothing to choose between them; this one is thrown
      # away by the caller's `after`.
      {:error, reason} when reason in [:eexist, :enotempty] ->
        :ok

      {:error, reason} ->
        Mix.raise("the baseline could not be moved to #{dest}: #{inspect(reason)}")
    end
  end

  # Streamed rather than read whole: a release tarball carrying ERTS is tens of
  # megabytes, and there is no reason for all of it to be resident at once when
  # the answer is 32 bytes. The digest is not a security claim - it identifies a
  # tarball, and nothing here defends against one crafted to collide with
  # another.
  #
  # `File.stream!/2` with the byte count and no modes: the three-argument form
  # taking modes *before* the byte count is deprecated as of Elixir 1.20, and the
  # two-argument form has meant this since 1.16 - well under the `~> 1.18` floor.
  defp digest(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  ## Running things

  # For a command whose output is read back as a *value*. Standard error is left
  # where it is, so git's advice and warnings reach the terminal rather than the
  # value.
  defp out(executable, args, cd) do
    System.cmd(executable, args, cd: cd, env: [])
  end

  # Git terminates its output with a newline; the newline is the terminator and
  # everything before it is the value. `String.trim/1` does not know the
  # difference, and where the value is a *path* that matters: a directory whose
  # name begins with a space is legal, so a prefix of ` odd/` would come back as
  # `odd/` - and the resolver would then look for the project somewhere else, or
  # find a genuinely different sibling and build that instead. Since the prefix is
  # in the cache key, two different projects would also key the same.
  #
  # A sha or a `true`/`false` can go through `String.trim/1` safely and does,
  # because neither can contain whitespace and the sha is pattern-checked besides.
  defp trim_eol(output), do: String.trim_trailing(output, "\n")

  # For a command whose output is only ever quoted in a diagnostic, where the two
  # streams together are what explains the failure.
  defp cmd(executable, args, cd, env \\ []) do
    System.cmd(executable, args, cd: cd, env: env, stderr_to_stdout: true)
  end

  defp short(sha), do: String.slice(sha, 0, 12)
end
