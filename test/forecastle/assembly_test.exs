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

    test "installs the Castle integration", %{env_sh: env_sh} do
      assert env_sh =~ "Castle.generate"
      assert env_sh =~ "Castle.make_releases"
    end

    test "runs the integration after the project's own customization", %{env_sh: env_sh} do
      marker = :binary.match(env_sh, "export SAMPLE_ENV_MARKER") |> elem(0)
      castle = :binary.match(env_sh, "Castle.generate") |> elem(0)

      assert marker < castle
    end

    test "only expands configuration for commands that boot the system", %{env_sh: env_sh} do
      assert env_sh =~
               ~r/case \$RELEASE_COMMAND in\n\s+start\|start_iex\|daemon\|daemon_iex\|eval\)/
    end

    test "is left alone by a plain Mix release", %{mix: mix} do
      env_sh = File.read!(Path.join(mix, "releases/#{@vsn}/env.sh"))

      assert env_sh =~ "export SAMPLE_ENV_MARKER=preserved"
      refute env_sh =~ "Castle."
    end
  end

  describe "the release layout" do
    test "holds the build-time configuration back from Mix", %{forecastle: forecastle} do
      version_path = Path.join(forecastle, "releases/#{@vsn}")

      assert File.exists?(Path.join(version_path, "build.config"))
      refute File.exists?(Path.join(version_path, "sys.config"))
    end

    test "records the config providers for Castle to run", %{forecastle: forecastle} do
      config = Path.join(forecastle, "releases/#{@vsn}/build.config")

      assert {:ok, [terms]} = :file.consult(to_charlist(config))
      assert [{Config.Reader, _state} | _] = terms[:castle][:config_providers]
    end

    test "carries a preboot script", %{forecastle: forecastle} do
      assert File.exists?(Path.join(forecastle, "releases/#{@vsn}/preboot.boot"))
    end

    test "copies runtime.exs into the version path", %{forecastle: forecastle} do
      assert File.exists?(Path.join(forecastle, "releases/#{@vsn}/runtime.exs"))
    end

    test "copies the .rel file where release_handler looks for it",
         %{forecastle: forecastle} do
      assert File.exists?(Path.join(forecastle, "releases/sample-#{@vsn}.rel"))
    end
  end

  describe "Windows executables" do
    # Configuration is withheld from Mix and expanded at boot by the env.sh
    # integration, which has no env.bat counterpart, so the .bat launcher looks
    # for a sys.config nothing creates. That predates this change, and assembly
    # still succeeds, so the build has to say so out loud.
    test "are warned about, since the release they produce cannot boot" do
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
      relup = Path.join(Forecastle.Fixture.workspace(), "relup")
      on_exit(fn -> File.rm(relup) end)
      File.write!(relup, "%% placeholder\n")

      release = assemble!(into: "rel-relup")

      assert File.read!(Path.join(release, "releases/#{@vsn}/relup")) == "%% placeholder\n"
    end
  end
end
