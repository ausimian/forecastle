defmodule Forecastle.CastleCliTest do
  @moduledoc """
  Exercises the generated `bin/castle` as a shell script.

  The release launcher is replaced with a stub that records the arguments it was
  handed, so these tests pin down exactly what `bin/castle` delegates without
  needing a running system.
  """

  use Forecastle.ReleaseCase

  setup_all do
    release = assemble!(into: "rel-forecastle")
    {:ok, release: release}
  end

  setup %{release: release} do
    root = Path.join(System.tmp_dir!(), "castle-cli-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(Path.join(release, "bin/castle"), Path.join(bin, "castle"))
    File.chmod!(Path.join(bin, "castle"), 0o755)

    record = Path.join(root, "argv")
    stub = Path.join(bin, "sample")

    File.write!(
      stub,
      ~s(#!/bin/sh\nprintf '%s\\0' "$@" > "#{record}"\nprintf '%s' "$CASTLE_STUB_OUTPUT"\n)
    )

    File.chmod!(stub, 0o755)

    {:ok, root: root, record: record}
  end

  describe "delegation to the release launcher" do
    test "releases", context do
      assert castle!(context, ["releases"]) == ["rpc", "Castle.releases()"]
    end

    test "unpack composes the tarball name from the build-time release name", context do
      assert castle!(context, ["unpack", "0.1.1"]) == ["rpc", "Castle.unpack(~s(sample-0.1.1))"]
    end

    test "install", context do
      assert castle!(context, ["install", "0.1.1"]) == ["rpc", "Castle.install(~s(0.1.1))"]
    end

    test "commit with an explicit version", context do
      assert castle!(context, ["commit", "0.1.1"]) == ["rpc", "Castle.commit(~s(0.1.1))"]
    end

    test "remove", context do
      assert castle!(context, ["remove", "0.1.1"]) == ["rpc", "Castle.remove(~s(0.1.1))"]
    end
  end

  describe "commit without a version" do
    test "resolves the version that is running now", context do
      assert ["rpc", expression] = castle!(context, ["commit"])

      assert expression =~ ":release_handler.which_releases(:current)"
      assert expression =~ "Castle.commit(to_string(vsn))"
    end

    test "says so when there is nothing to commit", context do
      assert ["rpc", expression] = castle!(context, ["commit"])
      assert expression =~ "No release is awaiting commit"
    end

    test "exits non-zero when there was nothing to commit", context do
      # Whatever asked for a commit has to be able to tell that none happened.
      assert {output, status} =
               castle(context, ["commit"], [
                 {"CASTLE_STUB_OUTPUT",
                  "No release is awaiting commit. Pass a version explicitly."}
               ])

      assert status == 1
      assert output =~ "No release is awaiting commit"
    end

    test "exits zero, and reports, when a commit happened", context do
      assert {output, 0} =
               castle(context, ["commit"], [
                 {"CASTLE_STUB_OUTPUT",
                  "Committed 0.1.1. System restarts will now boot into this version."}
               ])

      assert output =~ "Committed 0.1.1"
    end

    test "propagates a failing launcher exit status", context do
      File.write!(
        Path.join([context.root, "bin", "sample"]),
        "#!/bin/sh\necho 'rpc failed' >&2\nexit 3\n"
      )

      assert {_output, 3} = castle(context, ["commit"])
    end
  end

  describe "RELEASE_NAME" do
    # RELEASE_NAME names the node. The launcher and the tarballs are named at
    # build time and do not move when it is set, so nothing here may depend on
    # an executable called after it. No bin/other is created on purpose: doing
    # so would hide exactly the defect these pin down.
    test "does not change which launcher is invoked", context do
      assert ["rpc", "Castle.releases()"] =
               castle!(context, ["releases"], [{"RELEASE_NAME", "other"}])
    end

    test "does not rename the release tarballs", context do
      assert ["rpc", expression] =
               castle!(context, ["unpack", "0.1.1"], [{"RELEASE_NAME", "other"}])

      assert expression == "Castle.unpack(~s(sample-0.1.1))"
    end

    test "reaches the launcher, so the node it names is still the caller's",
         %{release: release} do
      # Passed through the environment rather than consumed here.
      refute File.read!(Path.join(release, "bin/castle")) =~ "RELEASE_NAME="
    end
  end

  describe "usage" do
    test "is printed, with a zero exit, when no command is given", context do
      assert {output, 0} = castle(context, [])
      assert output =~ "The known commands are:"
      refute recorded?(context)
    end

    test "is printed, with a non-zero exit, for an unknown command", context do
      assert {output, status} = castle(context, ["frobnicate"])
      assert status != 0
      assert output =~ "Unknown command frobnicate"
      refute recorded?(context)
    end

    test "documents that commit's version is optional", context do
      assert {output, 0} = castle(context, [])
      assert output =~ ~r/commit \[VSN\]/
    end

    for command <- ~w(unpack install remove) do
      test "#{command} without a version is rejected rather than delegated", context do
        assert {output, status} = castle(context, [unquote(command)])

        assert status != 0
        assert output =~ "#{unquote(command)} expects a version as argument"
        refute recorded?(context)
      end
    end
  end

  describe "version arguments" do
    # Versions are interpolated into Elixir source that the running node
    # evaluates. `1.2.3));System.stop(1)#` ends the ~s() sigil and the call,
    # leaving the rest to run with the release cookie's authority.
    @dangerous [
      ~S|1.2.3));System.stop(1)#|,
      "1.2.3)",
      "1.2.3(",
      ~S|1.2.3#{System.stop()}|,
      "1.2.3#comment",
      ~S|1.2.3\)|,
      "1.2.3$(id)",
      "1.2.3\nSystem.stop()",
      "../../etc/passwd",
      "sub/dir"
    ]

    for {version, index} <- Enum.with_index(@dangerous) do
      test "#{index}: #{inspect(version)} is refused rather than delegated", context do
        for command <- ~w(unpack install commit remove) do
          assert {output, status} = castle(context, [command, unquote(version)])

          assert status != 0, "#{command} accepted #{inspect(unquote(version))}"
          assert output =~ "is not a usable release version"
          refute recorded?(context), "#{command} delegated #{inspect(unquote(version))}"
        end
      end
    end

    # Mix does not constrain a release version, so plenty of odd-looking ones
    # assemble and boot. They are inert inside the sigil and must go through -
    # refusing them would break management of a release that works.
    @unusual_but_valid [
      "0.1.1",
      "1.2.3-rc.1",
      "1.0.0+build.5",
      "0.1.0-alpha_2",
      "20240101.1",
      "1.0~rc1",
      "1.2.3 4",
      ~s(1.2.3'x),
      ~s(1.2.3"x),
      "1.2.3;x",
      "1.2.3`id`",
      "1.2.3$HOME",
      "1.2.3|x",
      "1.2.3&x"
    ]

    for {version, index} <- Enum.with_index(@unusual_but_valid) do
      test "#{index}: #{inspect(version)} is passed through as itself", context do
        assert ["rpc", expression] = castle!(context, ["install", unquote(version)])

        # The real property is not the text of the expression but its meaning:
        # one call, to the function asked for, whose only argument is a literal
        # holding exactly this version. A single-element <<>> is what rules out
        # an interpolation having been introduced.
        assert {{:., _, [{:__aliases__, _, [:Castle]}, :install]}, _,
                [{:sigil_s, _, [{:<<>>, _, [unquote(version)]}, []]}]} =
                 Code.string_to_quoted!(expression)
      end
    end
  end

  describe "the generated scripts" do
    test "are valid POSIX shell", %{release: release} do
      for script <- ["bin/castle", "releases/0.1.0/env.sh"] do
        {output, status} =
          System.cmd("sh", ["-n", Path.join(release, script)], stderr_to_stdout: true)

        assert status == 0, "sh -n rejected #{script}:\n\n#{output}"
      end
    end
  end

  defp castle(context, args, env \\ []) do
    cmd(Path.join([context.root, "bin", "castle"]), args, env, cd: context.root)
  end

  defp castle!(context, args, env \\ []) do
    {output, 0} = castle(context, args, env)
    assert output == "", "expected no output from bin/castle, got: #{output}"

    context.record
    |> File.read!()
    |> String.split(<<0>>, trim: true)
  end

  defp recorded?(context), do: File.exists?(context.record)
end
