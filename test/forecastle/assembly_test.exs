defmodule Forecastle.AssemblyTest do
  @moduledoc """
  Assembles the sample fixture for real and asserts on the resulting tree.

  The central assertion is `bin/<name>` being byte-identical to the launcher
  plain Mix produces. Comparing against a freshly assembled Mix release rather
  than a checked-in golden file keeps the assertion honest as Elixir's own
  launcher template evolves.
  """

  use Forecastle.ReleaseCase

  @vsn "0.1.0"

  setup_all do
    {:ok,
     forecastle: assemble!(into: "rel-forecastle"),
     mix: assemble!(into: "rel-mix", env: [{"SAMPLE_STEPS", "mix"}])}
  end

  describe "the release launcher" do
    test "is left exactly as Mix generated it", %{forecastle: forecastle, mix: mix} do
      assert File.read!(Path.join(forecastle, "bin/sample")) ==
               File.read!(Path.join(mix, "bin/sample"))
    end

    test "carries none of the Castle commands", %{forecastle: forecastle} do
      launcher = File.read!(Path.join(forecastle, "bin/sample"))

      refute launcher =~ "Castle."
      refute launcher =~ "preboot"
    end

    test "keeps Mix's own runtime configuration handling", %{forecastle: forecastle} do
      launcher = File.read!(Path.join(forecastle, "bin/sample"))

      assert launcher =~ "export_release_sys_config"
      assert launcher =~ "readlink_f"
    end
  end

  describe "bin/castle" do
    test "is installed and executable", %{forecastle: forecastle} do
      castle = Path.join(forecastle, "bin/castle")

      assert File.exists?(castle)
      assert Bitwise.band(File.stat!(castle).mode, 0o111) != 0
    end

    test "exposes the release management commands", %{forecastle: forecastle} do
      castle = File.read!(Path.join(forecastle, "bin/castle"))

      for command <- ~w(releases unpack install commit remove) do
        assert castle =~ command
      end
    end

    test "is not installed by a plain Mix release", %{mix: mix} do
      refute File.exists?(Path.join(mix, "bin/castle"))
    end

    test "ships in the release tarball", %{forecastle: forecastle} do
      tarball = Path.join(forecastle, "sample-#{@vsn}.tar.gz")

      assert {:ok, entries} = :erl_tar.table(to_charlist(tarball), [:compressed])
      assert ~c"bin/castle" in entries
    end
  end

  describe "env.sh" do
    setup %{forecastle: forecastle} do
      {:ok, env_sh: File.read!(Path.join(forecastle, "releases/#{@vsn}/env.sh"))}
    end

    test "keeps the customization the project supplied", %{env_sh: env_sh} do
      assert env_sh =~ "export SAMPLE_ENV_MARKER=preserved"
    end

    test "installs the Castle hook", %{env_sh: env_sh} do
      assert env_sh =~ "Forecastle: Castle integration"
      assert env_sh =~ "Forecastle: end Castle integration"
    end

    test "does nothing on a normal start", %{env_sh: env_sh} do
      # Configuration is Mix's own business again, and the RELEASES file is
      # bin/castle's, so the hook runs no VM and no command of its own. The one
      # thing left for it is the provisional restart marker (#10); until that
      # lands it is a comment.
      refute env_sh =~ "Castle.generate"
      refute env_sh =~ "Castle.make_releases"

      fragment =
        env_sh
        |> String.split("\n")
        |> Enum.drop_while(&(not String.starts_with?(&1, "# --- Forecastle: Castle integration")))
        |> Enum.drop(1)
        |> Enum.reject(&(&1 == ""))

      assert fragment != [], "the hook was not found in env.sh"

      assert Enum.all?(fragment, &String.starts_with?(&1, "#")),
             "the hook has a line that does something:\n\n#{Enum.join(fragment, "\n")}"
    end

    test "comes after the project's own customization", %{env_sh: env_sh} do
      marker = :binary.match(env_sh, "export SAMPLE_ENV_MARKER") |> elem(0)
      castle = :binary.match(env_sh, "Forecastle: Castle integration") |> elem(0)

      assert marker < castle
    end

    test "is left alone by a plain Mix release", %{mix: mix} do
      env_sh = File.read!(Path.join(mix, "releases/#{@vsn}/env.sh"))

      assert env_sh =~ "export SAMPLE_ENV_MARKER=preserved"
      refute env_sh =~ "Castle."
    end
  end

  describe "the release layout" do
    test "leaves the configuration where Mix put it", %{forecastle: forecastle} do
      # Forecastle used to rename sys.config to build.config so that the stock
      # launcher could not boot from it and Castle had to expand it first.
      # Castle now dispatches on whether build.config exists - present means a
      # release whose configuration was intercepted at build time, absent means
      # Mix's pipeline is intact and the target is evaluated in a peer - so the
      # absence of that file is what selects the new path.
      version_path = Path.join(forecastle, "releases/#{@vsn}")

      refute File.exists?(Path.join(version_path, "build.config"))
      assert File.exists?(Path.join(version_path, "sys.config"))
    end

    test "declares its config providers where Elixir reads them",
         %{forecastle: forecastle, mix: mix} do
      # Elixir's own key, holding Elixir's own provider state, and no trace of
      # the list Forecastle used to stash under Castle's key for Castle to fold
      # by hand. Compared against the plain Mix release: what is asserted is
      # that Forecastle changed nothing about it.
      assert {:ok, [terms]} = consult(forecastle, "sys.config")
      assert {:ok, [plain]} = consult(mix, "sys.config")

      assert %Config.Provider{} = terms[:elixir][:config_provider_init]
      assert terms[:elixir] == plain[:elixir]
      refute terms[:castle][:config_providers]
    end

    test "carries the preboot script Castle's peer boots", %{forecastle: forecastle} do
      assert File.exists?(Path.join(forecastle, "releases/#{@vsn}/preboot.boot"))
    end

    test "has the runtime configuration Mix copied in", %{forecastle: forecastle} do
      # Mix copies the file named by :runtime_config_path into the version
      # directory itself, and points the Config.Reader it installs at that copy.
      # Forecastle used to copy config/runtime.exs there a second time, which is
      # how it ended up hardcoding a path Mix lets the project choose.
      assert File.exists?(Path.join(forecastle, "releases/#{@vsn}/runtime.exs"))
    end

    test "copies the .rel file where release_handler looks for it",
         %{forecastle: forecastle} do
      assert File.exists?(Path.join(forecastle, "releases/sample-#{@vsn}.rel"))
    end
  end

  describe "Windows executables" do
    # The .bat launcher boots now that Mix writes the sys.config it reads, but
    # bin/castle is a POSIX shell script, so nothing on a Windows deployment can
    # drive an upgrade. Assembly still succeeds, so the build has to say so out
    # loud.
    test "are warned about, since the release they produce cannot be upgraded" do
      output = assemble_output!("rel-windows", [{"SAMPLE_EXECUTABLES", "unix,windows"}])

      assert output =~ "Forecastle does not support Windows releases"
      assert output =~ "include_executables_for: [:unix]"
    end

    test "produce no warning when the release asks only for unix" do
      output = assemble_output!("rel-unix-only", [])

      refute output =~ "Forecastle does not support Windows releases"
    end

    defp assemble_output!(into, env) do
      workspace = Forecastle.Fixture.workspace()
      path = Path.join(workspace, into)
      File.rm_rf!(path)

      mix!(
        ["release", "sample", "--overwrite", "--path", path],
        [
          {"SAMPLE_VSN", "0.1.0"},
          {"MIX_BUILD_ROOT", Path.join(workspace, "_build-0.1.0")} | env
        ]
      )
    end
  end

  describe "relup" do
    test "is copied into the version path when the project has one" do
      write_relup!(relup_for(@vsn))

      release = assemble!(into: "rel-relup")

      # The plan, not the bytes: it is re-emitted from the term that was
      # checked rather than copied, so that what is packaged cannot be a
      # later read of a file something else has since replaced.
      assert {:ok, [{~c"0.1.0", [], []}]} =
               :file.consult(to_charlist(Path.join(release, "releases/#{@vsn}/relup")))
    end

    test "is refused when it is an upgrade plan for another version" do
      # The relup comes from a separate `mix forecastle.relup` run, so a stale
      # one can be sitting here - `--outdir` sends a successful generation
      # somewhere else and leaves this one behind. Packaging it would hand
      # `release_handler` the wrong version's instructions.
      write_relup!(relup_for("9.9.9"))

      output = assemble_failure!("rel-relup-stale")

      assert output =~ "is an upgrade plan for 9.9.9"
    end

    test "is refused when the version matches but the plan sections do not" do
      # The version alone is not enough. release_handler reaches into these two
      # lists with lists:keysearch/3, so an atom where a list belongs fails
      # during the live upgrade - exactly what checking the relup is meant to
      # stop. OTP applies this contract in systools_make:check_relup/1 when it
      # packs a tarball itself; Mix packs its own, so nothing applied it here.
      write_relup!(~s({"#{@vsn}", invalid, invalid}.\n))

      output = assemble_failure!("rel-relup-malformed")

      assert output =~ "is not an upgrade plan"
    end

    test "is refused when it is not an upgrade plan at all" do
      # What an interrupted write leaves behind. Existence was the only check.
      write_relup!("%% placeholder\n")

      output = assemble_failure!("rel-relup-partial")

      assert output =~ "is not an upgrade plan"
    end

    test "a corrected retry succeeds, having left nothing behind" do
      # The relup is checked before `:assemble`, so a rejected one leaves no
      # release on disk. Were it checked afterwards, Mix would have created the
      # version directory first, and this retry - which deliberately does not
      # pass --overwrite - would find it, decline to overwrite, and exit 0
      # having assembled nothing at all.
      path = Path.join(Forecastle.Fixture.workspace(), "rel-relup-retry")
      File.rm_rf!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      write_relup!(relup_for("9.9.9"))
      {_output, status} = assemble_at(path)
      assert status != 0

      refute File.exists?(path), "a rejected relup left a partial release behind"

      File.write!(Path.join(Forecastle.Fixture.workspace(), "relup"), relup_for(@vsn))
      {output, status} = assemble_at(path)

      assert status == 0, "the corrected retry failed:\n\n#{output}"
      assert File.exists?(Path.join(path, "releases/#{@vsn}/relup"))
    end
  end

  defp consult(release, basename) do
    :file.consult(to_charlist(Path.join([release, "releases", @vsn, basename])))
  end

  defp relup_for(vsn), do: ~s({"#{vsn}", [], []}.\n)

  # No --overwrite, on purpose: whether a retry can assemble at all is the point.
  defp assemble_at(path) do
    workspace = Forecastle.Fixture.workspace()

    mix(
      ["release", "sample", "--path", path],
      [{"SAMPLE_VSN", @vsn}, {"MIX_BUILD_ROOT", Path.join(workspace, "_build-#{@vsn}")}]
    )
  end

  # `mix/2` rather than `mix!/2`: assembly is meant to fail here, and what it
  # says while failing is the thing under test.
  defp assemble_failure!(into) do
    workspace = Forecastle.Fixture.workspace()
    path = Path.join(workspace, into)
    File.rm_rf!(path)

    {output, status} =
      mix(
        ["release", "sample", "--overwrite", "--path", path],
        [{"SAMPLE_VSN", @vsn}, {"MIX_BUILD_ROOT", Path.join(workspace, "_build-#{@vsn}")}]
      )

    assert status != 0, "assembly was expected to fail:\n\n#{output}"
    output
  end

  defp write_relup!(contents) do
    relup = Path.join(Forecastle.Fixture.workspace(), "relup")
    on_exit(fn -> File.rm(relup) end)
    File.write!(relup, contents)
  end
end
