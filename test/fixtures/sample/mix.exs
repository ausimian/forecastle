defmodule Sample.MixProject do
  use Mix.Project

  @forecastle Path.expand("../../..", __DIR__)

  def project do
    [
      app: :sample,
      version: System.get_env("SAMPLE_VSN", "0.1.0"),
      elixir: "~> 1.18",
      appup: appup(),
      compilers: Mix.compilers() ++ [:appup],
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sample.Application, []}
    ]
  end

  defp deps do
    [
      # TEMPORARY for the 1.0.0 cycle: the fixture needs Castle's in-progress API.
      # Flip back to {:castle, "~> 1.0"} before publishing.
      #
      # It was pinned to Castle's `issue/14-restart` while castle#14 and #10 were
      # open, because the two halves of an emulator-restart upgrade are useless
      # apart and this suite is the only thing that exercises them together. Both
      # have merged, so it is back on the integration branch - and it had to move
      # before that issue branch was deleted, which nothing enforces.
      #
      # It is on `feature/upgrade-tooling` for the duration of castle#32, for the
      # same reason: the tooling changes both halves at once, and this suite is
      # what exercises them together. Back to `release/1.0.0` when that tree
      # merges - the same unenforced step as last time.
      {:castle, github: "ausimian/castle", branch: "feature/upgrade-tooling"},
      {:forecastle, path: System.get_env("FORECASTLE_PATH", @forecastle), override: true},
      # An application the relup never mentions, versioned in step with this
      # one, so that "release_handler knows its version changed" is observable
      # from outside the system. See dep/mix.exs.
      {:sample_dep, path: "dep"}
    ]
  end

  # A `fn -> ... end` thunk, which is the shape Castle's own documentation
  # prescribes and which this fixture needs for a concrete reason: Mix loads
  # `mix.exs` to get the project configuration, and it does that *before* the
  # path dependency on Forecastle has been compiled. Capturing
  # `&Forecastle.pre_assemble/1` is fine at that point - a remote capture does
  # not load the module - but *calling* `Forecastle.steps/1`, which the `custom`
  # steps mode does, raises `UndefinedFunctionError`. Mix evaluates the thunk
  # later, when the release is being built and the dependency is there.
  defp releases do
    [
      sample: fn ->
        [
          include_executables_for: executables(),
          steps: steps()
        ] ++ configuration() ++ upgrade_from()
      end
    ]
  end

  # Switched by the test suite so that the fixture can be assembled with the
  # relup generated during the build. The option is set directly rather than
  # through `Castle.customize/2` on purpose: Forecastle reads it out of the
  # release options itself, and this half has to be testable without Castle's
  # API - the same reason `steps/0` below names the two step functions rather
  # than calling `Castle.customize/1`.
  #
  # Four shapes, because what the option does when it names nothing is as much
  # part of the contract as what it does when it names something:
  #
  #   - unset: the key is absent altogether, which is the documented no-op
  #   - "empty": `upgrade_from: []`, a request naming nothing, which is refused
  #   - "bare:<spec>": one spec as a string rather than a list, also refused
  #   - anything else: a `|`-separated list of specs
  #
  # `|` rather than a comma because a spec is a path and a comma is a legal
  # character in one; `System.cmd/3` cannot pass an empty value, which is why
  # the empty list has a word of its own.
  defp upgrade_from do
    case System.get_env("SAMPLE_UPGRADE_FROM") do
      nil -> []
      "empty" -> [upgrade_from: []]
      "bare:" <> spec -> [upgrade_from: spec]
      specs -> [upgrade_from: String.split(specs, "|", trim: true)]
    end
  end

  # Switched by the test suite so that the fixture can be assembled as a project
  # that configures itself in the two ways Forecastle used to get wrong: naming a
  # runtime configuration file other than `config/runtime.exs` while that file
  # also exists, and declaring providers whose init arguments are not keyword
  # lists.
  defp configuration do
    if System.get_env("SAMPLE_CONFIG") == "custom" do
      [
        runtime_config_path: "config/prod_runtime.exs",
        config_providers: [
          {Sample.EchoProvider, "a binary"},
          {Sample.EchoProvider, %{a: :map}},
          {Sample.EchoProvider, [:not, :a, :keyword, :list]}
        ]
      ]
    else
      []
    end
  end

  # Switched by the test suite so that the fixture can be built as a project
  # that does not ask for an appup at all. "none" rather than an empty value,
  # which `System.cmd/3` cannot pass: it unsets the variable instead. `nil` is
  # as close as this can get to dropping the key, and it is close enough - the
  # compiler reads it through `Mix.Project.config()[:appup]`, which cannot tell
  # the two apart.
  #
  # "false" is a *different value* that the compiler treats the same way - it
  # reads the key with `if src = config[:appup]`, so any falsy one means it
  # compiles nothing. `mix castle.appup.gen` has to agree with it about that, and
  # once read `nil` as unset and `false` as configured.
  defp appup do
    case System.get_env("SAMPLE_APPUP", "appup.exs") do
      "none" -> nil
      "false" -> false
      path -> path
    end
  end

  # Switched by the test suite so that the warning about unsupported Windows
  # executables can be provoked.
  defp executables do
    case System.get_env("SAMPLE_EXECUTABLES") do
      "unix,windows" -> [:unix, :windows]
      "windows" -> [:windows]
      _ -> [:unix]
    end
  end

  # Switched by the test suite: the same fixture is assembled with Forecastle,
  # without it so the two launchers can be compared, with a caller-supplied step
  # of its own between `:assemble` and `:tar`, and as a project that packs its
  # own archive.
  #
  # The default spells the step functions out rather than taking them from
  # `Forecastle.steps/1`, and the list is what that function builds: this is the
  # arrangement a project ends up with, written by hand, so a splice that put a
  # step on the wrong side of `:assemble` could not hide behind the same function
  # producing both sides of the comparison.
  defp steps do
    case System.get_env("SAMPLE_STEPS") do
      "mix" ->
        [:assemble, :tar]

      # The two modes that go through `Forecastle.steps/1` deliberately, because
      # where the splice puts relup generation is exactly what it is for. Every
      # other mode spells the list out so that a splice bug cannot produce both
      # sides of the comparison.
      "custom" ->
        Forecastle.steps([:assemble, &Sample.MixProject.remove_dep_appup/1, :tar])

      # The arrangement Forecastle documents for a project that packs its own
      # archive: no `:tar`, generation placed by hand in front of the step that
      # packs, because nothing in `steps/1` can tell which step that is. Run
      # through `steps/1` on purpose - whether it adds a second generation step
      # after the packing is the whole of what this mode exists to show.
      "packing" ->
        Forecastle.steps([:assemble, &Forecastle.generate_relup/1, &Sample.MixProject.pack/1])

      # A list `mix release` accepts and `Forecastle.steps/1` refuses: generation
      # after `:tar`, where the relup it writes can never be packaged. Also
      # through `steps/1`, because the refusal is what is under test.
      "after-tar" ->
        Forecastle.steps([:assemble, :tar, &Forecastle.generate_relup/1])

      # The same misplacement, reached by a release that named no baselines when
      # the build started and had one added by a step of its own. A `Mix.Release`
      # is the caller's to rewrite, so the guard that runs before `:assemble`
      # passes and the one immediately before `:tar` is the only thing left.
      "after-tar-late" ->
        Forecastle.steps([
          :assemble,
          &Sample.MixProject.add_upgrade_from/1,
          :tar,
          &Forecastle.generate_relup/1
        ])

      _default ->
        [
          &Forecastle.pre_assemble/1,
          :assemble,
          &Forecastle.post_assemble/1,
          &Forecastle.generate_relup/1,
          :tar
        ]
    end
  end

  @doc """
  A caller-supplied step of the kind `mix release` documents: one that changes
  the assembled tree between `:assemble` and `:tar`.

  It removes the dependency's appup from the assembled release, which is what
  `auto` consults to decide whether that application's version change can be
  hot. So a relup generated *before* this step runs says the transition is a hot
  upgrade, and one generated *after* it says `restart_emulator` - which is what
  makes the placement observable in the packaged relup rather than only in the
  steps list.
  """
  def remove_dep_appup(%Mix.Release{path: path} = release) do
    appups = Path.wildcard(Path.join(path, "lib/sample_dep-*/ebin/sample_dep.appup"))

    # Loudly, so that a fixture which stopped removing anything - a renamed
    # dependency, a changed layout - fails the test that rests on it rather than
    # quietly making its assertion about nothing.
    if appups == [] do
      raise "no sample_dep appup to remove under #{path}"
    end

    Enum.each(appups, &File.rm!/1)

    release
  end

  @doc """
  A caller-supplied step that adds `upgrade_from:` to a release that did not have
  it, which `mix release` permits: the `Mix.Release` handed between steps is the
  project's to rewrite, and `Forecastle` says so itself about the baselines it
  stashes in `pre_assemble/1`.

  It exists so that a build can reach `:tar` having become one that asks for a
  relup *after* the guard that runs before `:assemble` has already passed it.

  The spec comes from the environment rather than being computed, so that the
  test naming it decides what the build asks for.
  """
  def add_upgrade_from(%Mix.Release{options: options} = release) do
    spec = System.fetch_env!("SAMPLE_LATE_UPGRADE_FROM")

    %Mix.Release{release | options: Keyword.put(options, :upgrade_from, [spec])}
  end

  @doc """
  A caller-supplied step that packs the release's own archive, in the shape
  Forecastle documents: no `:tar`, and `&Forecastle.generate_relup/1` placed by
  hand in front of this.

  **It slims the tree before packing it**, and that is what makes the placement
  observable rather than merely asserted. Appups are what `auto` consults while
  deciding whether an application's version change can be hot, and nothing reads
  them at upgrade time - so a packaging step that does not ship them is a
  reasonable one, and it is precisely why generation has to come first. Generated
  before this step, the transition is a hot upgrade; generated after it, with the
  dependency's appup gone, the same transition is `restart_emulator`.

  So a second, spliced generation step running after this one leaves the archive
  holding one upgrade plan and the version path holding a different one, which is
  what `Forecastle.AssemblyRelupTest` asserts cannot happen.

  The archive is named after the release directory rather than after the release,
  so that two builds into the same workspace cannot write over each other's.
  """
  def pack(%Mix.Release{path: path} = release) do
    remove_dep_appup(release)

    # Built before the archive is opened, so that the archive - a sibling of the
    # release directory, not a member of it - cannot pack itself.
    members = Enum.map(File.ls!(path), &{Path.join(path, &1), &1})

    archive = path <> ".tar.gz"
    File.rm(archive)

    {:ok, tar} = :erl_tar.open(to_charlist(archive), [:write, :compressed])

    try do
      Enum.each(members, fn {source, name} ->
        :ok = :erl_tar.add(tar, to_charlist(source), to_charlist(name), [])
      end)
    after
      :ok = :erl_tar.close(tar)
    end

    release
  end
end
