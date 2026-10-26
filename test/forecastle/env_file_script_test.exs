defmodule Forecastle.EnvFileScriptTest do
  @moduledoc """
  Runs the `CASTLE_ENV_FILE` prefix as a shell script and asserts on what it
  did: the environment it exported, whether what followed it ran, and what it
  said on standard error.

  It is the same division as `Forecastle.EnvScriptTest` for the suffix.
  `Forecastle.AssemblyTest` says the prefix is in the release's `env.sh`, ahead
  of the project's own content; this says what it does when it runs, which no
  assertion about its text can.

  The script is the rendered prefix, then a stand-in for the project's own
  `env.sh`, then a report: `env` for what is *exported*, which is what reaches
  the VM, and `${VAR-<unset>}` for what is merely set in the shell. It runs
  under `sh` with `set -e`, as the launcher sources `env.sh`.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @missing "which is not a readable file"

  # The version the launcher exports before it sources env.sh, and so the
  # directory a relative name is joined to.
  @vsn "1.2.3"

  setup %{tmp_dir: root} do
    # Where the launcher's working directory is, kept apart from RELEASE_ROOT so
    # that a relative name resolved against the wrong one finds nothing - or
    # finds the decoy, which says something different and is reported.
    cwd = Path.join(root, "cwd")
    File.mkdir_p!(cwd)

    {:ok, root: root, cwd: cwd}
  end

  describe "with CASTLE_ENV_FILE unset" do
    test "does nothing", %{root: root, cwd: cwd} do
      run = run(root, cwd, [{"CASTLE_ENV_FILE", nil}])

      assert run.status == 0
      assert run.stderr == ""
      assert run.notes["consumer"] == "<unset>"
      refute Map.has_key?(run.env, "FROM_FILE")
    end

    test "and does nothing when it is set and empty", %{root: root, cwd: cwd} do
      # Empty is unset, here and in Castle's peer; neither treats it as a name.
      run = run(root, cwd, [{"CASTLE_ENV_FILE", ""}])

      assert run.status == 0
      assert run.stderr == ""
      assert run.notes["consumer"] == "<unset>"
    end
  end

  describe "with CASTLE_ENV_FILE naming a file" do
    test "exports every variable it assigns", %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "FROM_FILE=absolute\nexport ALSO_EXPORTED=yes\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

      assert run.status == 0
      assert run.env["FROM_FILE"] == "absolute"
      assert run.env["ALSO_EXPORTED"] == "yes"
    end

    test "runs ahead of the project's own env.sh, which can use what it set",
         %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "FROM_FILE=seen\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

      assert run.notes["consumer"] == "seen"
    end

    test "turns automatic export off again afterwards", %{root: root, cwd: cwd} do
      # The project's own assignments are not exported unless it says so, as
      # they were not before.
      file = env_file(root, "castle.env", "FROM_FILE=x\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

      assert run.notes["not_exported"] == "later"
      refute Map.has_key?(run.env, "NOT_EXPORTED")
    end

    test "leaves no variable of its own behind", %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "FROM_FILE=x\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

      assert run.notes["helper"] == "<unset>"
      refute Map.has_key?(run.env, "castle_env_file")
    end

    test "removes a variable the supervisor set, with unset", %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "unset FROM_SUPERVISOR\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}, {"FROM_SUPERVISOR", "set"}])

      assert run.status == 0
      refute Map.has_key?(run.env, "FROM_SUPERVISOR")
    end

    test "replaces a value the supervisor set", %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "FROM_SUPERVISOR=replaced\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}, {"FROM_SUPERVISOR", "set"}])

      assert run.env["FROM_SUPERVISOR"] == "replaced"
    end

    test "leaves a variable the file does not mention as it was", %{root: root, cwd: cwd} do
      # Which is why deleting a line is not the way to remove a variable.
      file = env_file(root, "castle.env", "FROM_FILE=x\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}, {"FROM_SUPERVISOR", "kept"}])

      assert run.env["FROM_SUPERVISOR"] == "kept"
    end
  end

  describe "a relative name" do
    test "is resolved against the version's own directory", %{root: root, cwd: cwd} do
      env_file(version_dir(root), "etc/castle.env", "FROM_FILE=version\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", "etc/castle.env"}])

      assert run.status == 0
      assert run.env["FROM_FILE"] == "version"
    end

    # Each version reads its own file, which is what makes the file the
    # version's: a rollback reads the one its version was installed with.
    test "follows RELEASE_VSN", %{root: root, cwd: cwd} do
      env_file(version_dir(root), "castle.env", "FROM_FILE=#{@vsn}\n")
      env_file(Path.join(root, "releases/1.2.4"), "castle.env", "FROM_FILE=1.2.4\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", "castle.env"}, {"RELEASE_VSN", "1.2.4"}])

      assert run.env["FROM_FILE"] == "1.2.4"
    end

    # It was joined to RELEASE_ROOT once, which made it one file for every
    # version; a file left there is not read.
    test "is not resolved against RELEASE_ROOT", %{root: root, cwd: cwd} do
      env_file(root, "castle.env", "FROM_FILE=release-root\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", "castle.env"}])

      assert run.status != 0
      assert run.stderr =~ "#{Path.join(version_dir(root), "castle.env")}, #{@missing}"
      refute Map.has_key?(run.env, "FROM_FILE")
    end

    test "is not resolved against the working directory", %{root: root, cwd: cwd} do
      env_file(cwd, "castle.env", "FROM_FILE=working-directory\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", "castle.env"}])

      assert run.status != 0
      assert run.stderr =~ "#{Path.join(version_dir(root), "castle.env")}, #{@missing}"
      refute Map.has_key?(run.env, "FROM_FILE")
    end

    test "is not looked up on PATH, which is what `.` does with a bare name",
         %{root: root, cwd: cwd} do
      bin = Path.join(root, "on-path")
      env_file(bin, "castle.env", "FROM_FILE=path\n")

      run =
        run(root, cwd, [
          {"CASTLE_ENV_FILE", "castle.env"},
          {"PATH", bin <> ":" <> System.get_env("PATH")}
        ])

      assert run.status != 0
      assert run.stderr =~ @missing
      refute Map.has_key?(run.env, "FROM_FILE")
    end
  end

  describe "a file that cannot be used" do
    test "stops the launcher, naming the file, before anything else runs",
         %{root: root, cwd: cwd} do
      missing = Path.join(root, "absent.env")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", missing}])

      assert run.status != 0

      assert run.stderr ==
               "ERROR: CASTLE_ENV_FILE names #{missing}, which is not a readable file\n"

      refute Map.has_key?(run.notes, "consumer")
    end

    test "is refused when it names a directory", %{root: root, cwd: cwd} do
      dir = Path.join(root, "a-directory")
      File.mkdir_p!(dir)

      run = run(root, cwd, [{"CASTLE_ENV_FILE", dir}])

      assert run.status != 0
      assert run.stderr =~ "#{dir}, #{@missing}"
    end

    test "is refused when it cannot be read", %{root: root, cwd: cwd} do
      file = env_file(root, "castle.env", "FROM_FILE=x\n")
      File.chmod!(file, 0o000)

      # Root reads it anyway, and then there is nothing to test.
      if match?({:ok, _}, File.read(file)) do
        :ok
      else
        run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

        assert run.status != 0
        assert run.stderr =~ "#{file}, #{@missing}"
      end
    end

    test "stops the launcher when a command in it fails", %{root: root, cwd: cwd} do
      # Under the launcher's own `set -e`; the prefix adds nothing to it.
      file = env_file(root, "castle.env", "FROM_FILE=x\nfalse\nAFTER_FAILURE=y\n")

      run = run(root, cwd, [{"CASTLE_ENV_FILE", file}])

      assert run.status != 0
      refute Map.has_key?(run.notes, "consumer")
    end
  end

  ## The sandbox

  defp version_dir(root), do: Path.join(root, "releases/#{@vsn}")

  defp env_file(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  # A variable that has to arrive set and empty cannot go through
  # `System.cmd/3`'s `:env`, which removes it, so those are shell assignments in
  # front of the command instead - the same arrangement
  # `Forecastle.EnvScriptTest` makes, for the same reason.
  defp run(root, cwd, env) do
    script = Path.join(root, "run.sh")
    out = Path.join(root, "stdout")
    err = Path.join(root, "stderr")

    File.write!(script, "set -e\n" <> prefix() <> consumer())

    # What the launcher exports before it sources env.sh, unless the test says
    # otherwise.
    launcher = [{"RELEASE_ROOT", root}, {"RELEASE_VSN", @vsn}]
    env = Enum.reject(launcher, fn {name, _} -> List.keymember?(env, name, 0) end) ++ env

    {empty, set} = Enum.split_with(env, &(elem(&1, 1) == ""))

    assignments = Enum.map_join(empty, "", fn {name, _} -> "#{name}= " end)

    # The paths are arguments rather than interpolated, because `tmp_dir` is
    # named after the test and a test name may hold a backtick.
    {_, status} =
      System.cmd(
        "sh",
        ["-c", ~s(#{assignments}sh "$1" > "$2" 2> "$3"), "sh", script, out, err],
        env: set,
        cd: cwd
      )

    {notes, env} = parse(File.read!(out))

    %{status: status, stderr: File.read!(err), notes: notes, env: env}
  end

  # What the project's own env.sh would be, and then the report. It only runs if
  # the prefix let the script get this far, which is the other thing it says.
  defp consumer do
    """
    printf 'consumer=%s\\n' "${FROM_FILE-<unset>}"
    NOT_EXPORTED=later
    printf 'not_exported=%s\\n' "$NOT_EXPORTED"
    printf 'helper=%s\\n' "${castle_env_file-<unset>}"
    echo '--- env'
    env
    """
  end

  defp parse(stdout) do
    {notes, env} =
      case String.split(stdout, "--- env\n", parts: 2) do
        [notes, env] -> {notes, env}
        [notes] -> {notes, ""}
      end

    {pairs(notes), pairs(env)}
  end

  defp pairs(text) do
    for line <- String.split(text, "\n", trim: true),
        [name, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {name, value}
  end

  defp prefix do
    :forecastle
    |> :code.priv_dir()
    |> Path.join("env_prefix.sh.eex")
    |> EEx.eval_file(release: %Mix.Release{name: :sample})
  end
end
