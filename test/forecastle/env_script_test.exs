defmodule Forecastle.EnvScriptTest do
  @moduledoc """
  Runs the `env.sh` fragment as a shell script, in a directory laid out like a
  release, and asserts on what it *did*.

  This is the companion to the `env.sh` assertions in `Forecastle.AssemblyTest`,
  and the division between them is deliberate. That suite says the fragment is
  appended to the release's own `env.sh` and that it is gated on a command which
  starts the system - facts about assembly, which need a real release. This one
  says what the fragment does when it runs, which nothing about the text of it
  can establish.

  That distinction is not academic. The heart configuration was first written as
  a set of `${VAR:-default}` expressions, and the test that covered it asserted
  those expressions were *present* - so it passed while a deployment that had
  `HEART_COMMAND` in its environment kept an active watchdog, which is the one
  thing this release says it has not got. What the fragment has to be held to is
  the environment it leaves behind, and the only way to see that is to source it
  and look.

  The sandbox is a release-shaped directory with a stub `bin/sample`, because the
  fragment's other half *execs* the launcher and what it hands over - the
  version, and that it handed over at all - is the whole of what there is to
  observe. `Forecastle.CastleCliTest` drives `bin/castle` against a launcher stub
  for the same reason.

  The fragment is rendered from `priv/env.sh.eex` rather than read out of an
  assembled release, so these tests need no `mix release` and stay async;
  `Forecastle.AssemblyTest` is what pins that this template is what ships.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @vsn "0.1.0"
  @next "0.1.1"

  # What the stub launcher prints when the fragment execs it. Nothing else in the
  # fragment writes to standard output, so its presence is the discriminator
  # between a start that selected a provisional version and one that did not.
  @exec "exec:"

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "bin"))

    # Two version directories with the launcher's own furniture in them. The
    # fragment refuses to exec into a version that has no `env.sh` and no
    # `start.boot`, because the next pass sources the first and the VM boots the
    # second.
    for vsn <- [@vsn, @next] do
      dir = Path.join([root, "releases", vsn])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "env.sh"), "# nothing\n")
      File.write!(Path.join(dir, "start.boot"), "")
    end

    # Present so that the RELEASES bootstrap - the fragment's third part, which
    # starts a VM - is skipped. It is not what any of this is about.
    File.write!(Path.join(root, "releases/RELEASES"), "[].\n")
    File.write!(Path.join(root, "releases/start_erl.data"), "16.0 #{@vsn}\n")

    File.write!(Path.join(root, "bin/sample"), """
    #!/bin/sh
    echo "#{@exec}$RELEASE_VSN"
    """)

    File.chmod!(Path.join(root, "bin/sample"), 0o755)

    {:ok, root: root}
  end

  describe "heart, with nothing inherited" do
    test "assigns the whole of it", %{root: root} do
      # The ordinary deployment. heart runs, because release_handler calls
      # heart:set_cmd/1 while preparing a reboot and that raises badarg with no
      # heart process - and it is given nothing to do.
      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] =~ "-heart"
      assert run.env["HEART_COMMAND"] == "<unset>"
      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "says nothing at all", %{root: root} do
      # The normal case has to be silent. A warning on every start of every
      # deployment is a warning nobody reads.
      assert start(root).stderr == ""
    end

    test "adds -heart once", %{root: root} do
      # Load bearing rather than hygiene: two -heart flags make
      # init:get_argument(heart) answer {ok, [[], []]}, which heart's own startup
      # check has no clause for, and the boot hangs with nothing printed. The
      # fragment is read twice on a provisional start, because it execs the
      # launcher, so a deployment that already has the flag is the ordinary case
      # rather than an odd one.
      run = start(root, [{"ELIXIR_ERL_OPTIONS", "-heart"}])

      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
    end
  end

  describe "heart, with a deployment's own settings inherited" do
    # The environment that made the defaulted version wrong: a HEART_COMMAND to
    # restart with, heart's killing turned back on, and a timeout short enough
    # for it to bite.
    @hostile [
      {"HEART_COMMAND", "/usr/local/bin/restart-me"},
      {"HEART_NO_KILL", "FALSE"},
      {"HEART_BEAT_TIMEOUT", "11"}
    ]

    test "defangs heart anyway", %{root: root} do
      # Asserted on the effective environment, which is the only thing heart
      # reads. The contract is that the external supervisor is the only thing
      # that starts a replacement, and a deployment does not get to opt out of
      # that while using this hook.
      run = start(root, @hostile)

      assert run.env["HEART_COMMAND"] == "<unset>"
      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "says what it overrode, and why, on standard error", %{root: root} do
      # Not a refusal: an operator who set these has a configuration conflict,
      # not an emergency, and a failed boot is worse than the conflict. But the
      # setting has stopped taking effect, so silence would be losing it.
      run = start(root, @hostile)

      assert run.stderr =~ "unsetting HEART_COMMAND=[/usr/local/bin/restart-me]"
      assert run.stderr =~ "restarting the system belongs to whatever supervises it"

      assert run.stderr =~ "overriding HEART_NO_KILL=[FALSE] with TRUE"
      assert run.stderr =~ "overriding HEART_BEAT_TIMEOUT=[11] with 65535"

      # And nothing about it reaches standard output, which on a start belongs to
      # the release.
      refute run.stdout =~ "warning"
    end

    test "is silent about a setting that agrees with it", %{root: root} do
      # Assigning is not the same as complaining. A deployment that set the
      # values this hook would have chosen has no conflict to be told about.
      run = start(root, [{"HEART_NO_KILL", "TRUE"}, {"HEART_BEAT_TIMEOUT", "65535"}])

      assert run.stderr == ""
      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "leaves an empty HEART_COMMAND alone to complain about", %{root: root} do
      # HEART_COMMAND= is a variable that is set and means nothing, so unsetting
      # it changes nothing an operator would notice. Warning about it would be
      # noise on a deployment that has no conflict.
      run = start(root, [{"HEART_COMMAND", ""}])

      assert run.stderr == ""
      assert run.env["HEART_COMMAND"] == "<unset>"
    end
  end

  describe "a command that does not start the system" do
    test "reaches none of it", %{root: root} do
      # bin/castle drives every command through `rpc`, so a fragment that ran for
      # those would start a heart process in a VM that manages nothing - and,
      # worse, consume the provisional marker while an install was still waiting
      # for the reboot.
      arm(root, @next)

      run = run(root, "eval", @hostile)

      assert run.env["HEART_COMMAND"] == "/usr/local/bin/restart-me"
      assert run.env["HEART_NO_KILL"] == "FALSE"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      refute run.stdout =~ @exec
      assert armed?(root)
      assert provisional?(root)
    end
  end

  describe "the provisional version" do
    test "is selected from a pair that agrees, by exec'ing the launcher",
         %{root: root} do
      # release_handler wrote the target to new_start_erl.data and left
      # start_erl.data naming the version that is still permanent, so the stock
      # launcher on its own would boot the old one. An exec rather than an
      # assignment, because by the time env.sh is sourced the launcher has
      # already resolved REL_VSN_DIR and everything hangs off it.
      arm(root, @next)

      run = start(root)

      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.stderr == ""
    end

    test "consumes both markers before the exec", %{root: root} do
      # One-shot. The second pass has to find nothing, or a provisional boot
      # would select itself again for ever and the rollback would be unreachable.
      arm(root, @next)

      assert start(root).stdout =~ @exec
      refute armed?(root)
      refute provisional?(root)
      assert claims(root) == []
    end

    test "is not selected from Castle's marker alone", %{root: root} do
      # What a hard restart between the arming and release_handler's own write
      # leaves: Castle said a reboot was coming and the preparation never got to
      # write its half. There is nothing to boot, so the permanent version is
      # what starts - and the marker is consumed, so the next start is an
      # ordinary one.
      File.write!(pending(root), "#{@next}\nsome-attempt\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "the version to boot could not be settled"
      assert run.stderr =~ "Castle armed [#{@next}] and release_handler recorded []"
      refute armed?(root)
    end

    test "is not selected from OTP's marker alone", %{root: root} do
      # The stale half a failed preparation leaves behind, which nothing removes.
      # On its own it is not a boot instruction and it is not evidence of
      # anything, so this is silent: no marker, nothing to say. It is Castle that
      # clears the file, on the way into the next install that needs to.
      File.write!(provisional(root), "16.0 #{@next}\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr == ""
      assert provisional?(root)
    end

    test "is not selected by the start after an interrupted consumption",
         %{root: root} do
      # The claim is atomic and the pair is not: OTP's file is read and removed
      # after the rename, so a start killed in between leaves a claim behind and
      # OTP's file with it. What must not happen is the next start acting on what
      # is left. The marker is gone, so it does not - the selection is lost, and
      # a lost selection is a boot of the version that was permanent.
      File.write!(Path.join(root, "releases/castle-restart-consumed.999999"), "#{@next}\nx\n")
      File.write!(provisional(root), "16.0 #{@next}\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr == ""
    end

    test "is not selected from a pair that disagrees", %{root: root} do
      # Both files are still consumed, and the warning names both values: what
      # they are is the only diagnosis there is, and leaving either behind would
      # have the next start make the same mistake.
      File.write!(pending(root), "#{@next}\nsome-attempt\n")
      File.write!(provisional(root), "16.0 #{@vsn}\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "Castle armed [#{@next}] and release_handler recorded [#{@vsn}]"
      refute armed?(root)
      refute provisional?(root)
    end

    test "is not selected from a version that could name something else",
         %{root: root} do
      # The version comes out of a file, is used to build a path and is exported
      # into the environment of a VM, so one carrying a separator is refused
      # rather than resolved.
      File.write!(pending(root), "../#{@next}\nsome-attempt\n")
      File.write!(provisional(root), "16.0 ../#{@next}\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "could not be settled"
    end

    test "is not selected from a version directory with nothing to boot",
         %{root: root} do
      # A version the two markers agree on, unpacked far enough to be named and
      # not far enough to be started. env.sh is sourced from it on the next pass
      # and start.boot is what the VM boots.
      File.rm!(Path.join([root, "releases", @next, "start.boot"]))
      arm(root, @next)

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "could not be settled"
    end
  end

  ## The sandbox

  # Sources the fragment with `$RELEASE_COMMAND` set to one that starts the
  # system, and reports what it did: what the launcher printed if it was exec'd,
  # what went to standard error, and the environment as the fragment left it.
  defp start(root, env \\ []), do: run(root, "start", env)

  defp run(root, command, env) do
    script = Path.join(root, "run.sh")
    out = Path.join(root, "stdout")
    err = Path.join(root, "stderr")

    File.write!(script, fragment() <> reporting())

    # Redirected inside the shell rather than merged by System.cmd/3, because
    # which stream a warning went to is one of the things being asserted.
    {_, status} =
      System.cmd("sh", ["-c", ~s(sh "#{script}" > "#{out}" 2> "#{err}")],
        env: environment(root, command, env)
      )

    stdout = File.read!(out)

    %{
      status: status,
      stdout: stdout,
      stderr: File.read!(err),
      env: reported(stdout)
    }
  end

  # Everything the launcher exports before it sources env.sh that the fragment
  # reads, and nothing else: an inherited variable has to arrive through `env`
  # rather than out of the test runner's own environment.
  defp environment(root, command, env) do
    [
      {"RELEASE_COMMAND", command},
      {"RELEASE_ROOT", root},
      {"REL_VSN_DIR", Path.join([root, "releases", @vsn])},
      {"RELEASE_VSN", @vsn},
      {"ELIXIR_ERL_OPTIONS", nil},
      {"HEART_COMMAND", nil},
      {"HEART_NO_KILL", nil},
      {"HEART_BEAT_TIMEOUT", nil}
    ] ++ env
  end

  defp fragment do
    :forecastle
    |> :code.priv_dir()
    |> Path.join("env.sh.eex")
    |> EEx.eval_file(release: %Mix.Release{name: :sample})
  end

  # Appended to the fragment, so it only runs when the fragment did *not* exec
  # the launcher. `${VAR-<unset>}` rather than `${VAR:-<unset>}`, because a
  # variable set to nothing and a variable that is not set are different answers
  # and one of them is what unsetting HEART_COMMAND has to produce.
  defp reporting do
    """

    for castle_var in ELIXIR_ERL_OPTIONS HEART_COMMAND HEART_NO_KILL HEART_BEAT_TIMEOUT; do
      eval "castle_val=\\${$castle_var-<unset>}"
      echo "env $castle_var=$castle_val"
    done
    """
  end

  defp reported(stdout) do
    for "env " <> line <- String.split(stdout, "\n"), into: %{} do
      [name, value] = String.split(line, "=", parts: 2)
      {name, value}
    end
  end

  # A pair that agrees, as Castle and release_handler leave it: the marker with
  # the version on its first line and the attempt on its second, and OTP's
  # `<erts vsn> <release vsn>`.
  defp arm(root, vsn) do
    File.write!(pending(root), "#{vsn}\n1234-5678-1\n")
    File.write!(provisional(root), "16.0 #{vsn}\n")
  end

  defp pending(root), do: Path.join(root, "releases/castle-restart-pending")
  defp provisional(root), do: Path.join(root, "releases/new_start_erl.data")

  defp armed?(root), do: File.exists?(pending(root))
  defp provisional?(root), do: File.exists?(provisional(root))
  defp claims(root), do: Path.wildcard(Path.join(root, "releases/castle-restart-consumed*"))
end
