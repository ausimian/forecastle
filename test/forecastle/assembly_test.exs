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

    test "matches the real launcher's unreachable-node diagnostic", %{forecastle: forecastle} do
      castle = File.read!(Path.join(forecastle, "bin/castle"))

      assert [_, classified_line] =
               Regex.run(~r/^lost_connection_line='([^'\n]+)'$/m, castle)

      unique = System.unique_integer([:positive])
      stdout = Path.join(forecastle, "classifier-#{unique}.stdout")
      stderr = Path.join(forecastle, "classifier-#{unique}.stderr")
      on_exit(fn -> File.rm(stdout) end)
      on_exit(fn -> File.rm(stderr) end)

      script =
        ~S(exec "$CASTLE_TEST_LAUNCHER" rpc ':ok' >"$CASTLE_TEST_STDOUT" 2>"$CASTLE_TEST_STDERR")

      env = [
        {"CASTLE_TEST_LAUNCHER", Path.join(forecastle, "bin/sample")},
        {"CASTLE_TEST_STDOUT", stdout},
        {"CASTLE_TEST_STDERR", stderr},
        {"RELEASE_DISTRIBUTION", "sname"},
        {"RELEASE_NODE", "castle_classifier_missing_#{unique}"},
        {"RELEASE_COOKIE", "castle_classifier_cookie"},
        {"ERL_CRASH_DUMP_SECONDS", "0"}
      ]

      assert {"", status} = cmd("/bin/sh", ["-c", script], env)
      assert status != 0
      assert File.read!(stdout) == ""

      assert String.split(File.read!(stderr), "\n", trim: true) == [classified_line]
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

  describe "bin/start" do
    test "is installed, executable, and does nothing", %{forecastle: forecastle} do
      # The path release_handler composes into heart's temporary reboot command,
      # and returns unexamined: init/1 yields {no_check, $ROOT/bin/start} when
      # {sasl, start_prg} is unset, and check_start_prg/2 does not look at it. So
      # it has to exist, and it has to do nothing - heart really does run it, both
      # on init:reboot() and on a heart-beat time-out, where HEART_NO_KILL means
      # the old VM is still alive.
      start = Path.join(forecastle, "bin/start")

      assert File.exists?(start)
      assert Bitwise.band(File.stat!(start).mode, 0o111) != 0
      assert {"", 0} = System.cmd(start, ["releases/new_start_erl.data"], cd: forecastle)
    end

    test "starts nothing", %{forecastle: forecastle} do
      # Asserted on the script rather than on its behaviour, because "it did not
      # start the release" is not observable from a single run of something that
      # exits 0. What must never appear here is an invocation of the launcher: a
      # bin/start that started the release would be a second restart authority
      # beside the supervisor, and with HEART_NO_KILL it could start one node
      # beside another that is still alive.
      start = File.read!(Path.join(forecastle, "bin/start"))

      refute start =~ "bin/sample"
      refute start =~ "exec"
      assert start =~ "exit 0"
    end

    test "is not installed by a plain Mix release", %{mix: mix} do
      refute File.exists?(Path.join(mix, "bin/start"))
    end

    test "ships in the release tarball", %{forecastle: forecastle} do
      # Which is what puts it into a deployment that migrates by hot upgrade:
      # release_handler extracts with keep_old_files, so a new file appears.
      tarball = Path.join(forecastle, "sample-#{@vsn}.tar.gz")

      assert {:ok, entries} = :erl_tar.table(to_charlist(tarball), [:compressed])
      assert ~c"bin/start" in entries
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

    test "expands no configuration", %{env_sh: env_sh} do
      # Configuration is Mix's own business again, so the hook neither runs the
      # release's config providers nor applies the launcher's defaults ahead of
      # doing so - the launcher assigns those itself, after sourcing this.
      refute env_sh =~ "Castle.generate"
      # How build.config used to be loaded into the preboot VM, and the last of
      # the launcher defaults the fragment used to have to apply for itself.
      refute env_sh =~ "--erl-config"
      refute env_sh =~ "RELEASE_BOOT_SCRIPT_CLEAN"
    end

    test "creates the RELEASES file, once, before the system starts", %{env_sh: env_sh} do
      # The only thing left for the hook on a normal start, and the only place it
      # can be done at all: release_handler reads that file in its init, so a
      # system that booted without one keeps the record it synthesised until it
      # is restarted. Guarded on the file, so this is the first start of a
      # deployment and nothing after it.
      assert env_sh =~ "Castle.make_releases"
      assert env_sh =~ ~s([ ! -f "$RELEASE_ROOT/releases/RELEASES" ])
    end

    test "does not change directory to do it", %{env_sh: env_sh} do
      # Castle derives the releases directory from code:root_dir(), the root
      # release_handler resolves its own paths against, so the call needs no
      # working directory of its own and nothing about the release has to be
      # interpolated into the expression to say where the file goes. The whole
      # expression, asserted as one, is what says both: it used to be a File.cd!
      # into a RELEASE_ROOT read out of the environment.
      assert env_sh =~ ~s|--eval "Castle.make_releases()"|
      refute env_sh =~ "fetch_env!"
    end

    test "only runs for the commands that start the system", %{env_sh: env_sh} do
      # Not eval, which the configuration expansion needed and this does not: an
      # eval VM manages no releases - and, since #10, must not consume the
      # provisional marker or start a heart process either. bin/castle drives
      # every command through `rpc`, so a fragment that ran for those would
      # consume the marker while an install was still waiting for the reboot.
      assert env_sh =~ ~r/case \$RELEASE_COMMAND in\n\s+start\|start_iex\|daemon\|daemon_iex\)/
    end

    test "runs heart, and assigns the whole of its configuration", %{env_sh: env_sh} do
      # heart exists only so that heart:set_cmd/1 returns ok instead of raising
      # badarg while release_handler prepares a reboot. Everything else about it
      # is switched off: no HEART_COMMAND, no kill, and a beat timeout at the
      # documented maximum, because HEART_NO_KILL does not make a time-out
      # harmless - the port program exits after running its command, heart is a
      # kernel process, and init halts the node when one of those dies.
      #
      # **What the fragment does to the environment is asserted in
      # `Forecastle.EnvScriptTest`, by running it.** This test used to be the
      # whole of the coverage and it asserted that the `${VAR:-default}`
      # expressions were *present* - which is exactly how a deployment with
      # HEART_COMMAND in its environment kept an active watchdog while this
      # passed. What is left here is the assembly-level claim: the heart
      # configuration is in the release's own env.sh, and it assigns.
      assert env_sh =~ ~s(ELIXIR_ERL_OPTIONS:+$ELIXIR_ERL_OPTIONS }-heart)
      assert env_sh =~ "unset HEART_COMMAND"
      assert env_sh =~ "HEART_NO_KILL=TRUE"
      assert env_sh =~ "HEART_BEAT_TIMEOUT=65535"

      # And the defect refuted by shape: a default is a value a deployment may
      # override, and there is nothing here it may override. Mix ships the
      # HEART_COMMAND assignment commented out in its own generated env.sh,
      # pointing at the launcher, which is the one thing that must never be
      # assigned here.
      refute env_sh =~ ~s(HEART_NO_KILL="${HEART_NO_KILL:-)
      refute env_sh =~ ~s(HEART_BEAT_TIMEOUT="${HEART_BEAT_TIMEOUT:-)
      refute env_sh =~ ~s(HEART_COMMAND="$)
      refute env_sh =~ "export HEART_COMMAND"

      # Nor may either of them be *read* with a colon, anywhere. The two are
      # compared against the value that replaces them so that a deployment which
      # already agrees is not warned at, and `${VAR:-default}` cannot make that
      # comparison: it treats a variable set to nothing as absent, so an empty
      # value is displaced in silence. `${VAR-default}` is the form that tells
      # unset from set-and-empty.
      refute env_sh =~ ~s(${HEART_NO_KILL:-)
      refute env_sh =~ ~s(${HEART_BEAT_TIMEOUT:-)
    end

    test "adds -heart only once", %{env_sh: env_sh} do
      # Load bearing rather than hygiene: two -heart flags make
      # init:get_argument(heart) answer {ok, [[], []]}, which heart's own startup
      # check has no clause for, and the boot hangs with nothing printed. What the
      # guard is for is a deployment supplying its own flag - in its vm.args, or in
      # one of the variables erlexec reads. The fragment's *own* flag used to be a
      # second source of one, because the heart block ran ahead of the provisional
      # selection and so on both passes of a re-exec; the order that stops that is
      # asserted below.
      #
      # The assembly-level claim is that the guard in the shipped env.sh *asks the
      # emulator* rather than reading the environment and deciding for itself, and
      # that it asks with everything the start will be given. Which values it
      # recognises is `Forecastle.EnvScriptTest`'s, by running it against a real
      # erlexec, and whether a real boot survives an inherited flag is
      # `Forecastle.RestartUpgradeTest`'s.
      #
      # `erl -emu_args_exit` prints the argument vector erlexec assembled and exits
      # without starting a VM, so it covers all six sources at once - the command
      # line, ERL_OTP<major>_FLAGS, ERL_AFLAGS, ERL_FLAGS, ERL_ZFLAGS and every
      # -args_file followed out of vm.args - with erlexec's own quoting, escaping
      # and comment handling.
      #
      # And that it reads that answer with the boundary `init` applies to it:
      # everything after -extra is the application's arguments rather than emulator
      # flags, so a plain argument spelled -heart is printed by -emu_args_exit and
      # is not a flag. Counting it would suppress the one that should be added,
      # which fails the opposite way to a duplicate - the release boots happily
      # without heart and the damage surfaces at heart:set_cmd/1 much later.
      assert env_sh =~ "-emu_args_exit"
      assert env_sh =~ "/^-extra$/ { exit 1 }"
      assert env_sh =~ "/^-heart$/ { found = 1; exit 0 }"

      # Asked of the emulator the launcher will run, and told which that is by the
      # file that decides it: the launcher execs `$REL_VSN_DIR/elixir`, and the
      # ERTS_BIN line Mix rewrites in that script is the only thing in it choosing
      # an emulator. Reading the assignment out of the same file the exec will read
      # it out of is not a model of the resolution - it is the resolution.
      # ERL_OTP<major>_FLAGS is named for the answering binary's OTP version, so
      # asking a different one would be asking about a different deployment.
      assert env_sh =~ ~s(sed -n 's|^ERTS_BIN="$SCRIPT_PATH"||p')
      assert env_sh =~ ~s("$REL_VSN_DIR/elixir" 2>/dev/null)
      assert env_sh =~ ~s([ -x "$REL_VSN_DIR${castle_erts_bin}erl" ])

      # And it used to glob the release root for erts-* and keep the last match,
      # which is the lexicographically last and so not even the newest. That is
      # refuted rather than merely superseded: a root holds several erts-* the
      # moment an ERTS-changing release is unpacked, and it reads as the obvious
      # spelling. Both the loop and the pattern, because either alone would be a
      # partial revert. The prose in the fragment deliberately does not repeat the
      # pattern, so this refutation is about the code.
      refute env_sh =~ "for castle_candidate in"
      refute env_sh =~ ~s|"$RELEASE_ROOT"/erts-*/bin/erl|

      # `erl` from PATH is the fallback, which is what a release built with
      # `include_erts: false` needs: Mix leaves ERTS_BIN empty there, so the
      # launcher runs PATH's emulator and the probe has to as well.
      assert env_sh =~ ~s(castle_erl="erl")

      # And asked with what the start will be given. ELIXIR_ERL_OPTIONS is expanded
      # *unquoted* and before -args_file, because that is what Mix's `elixir` does
      # with it, so an -extra in that variable swallows the args file here exactly
      # as it would on the boot.
      assert env_sh =~ "${ELIXIR_ERL_OPTIONS-} \\\n"
      refute env_sh =~ ~s("${ELIXIR_ERL_OPTIONS-}" \\\n)
      assert env_sh =~ ~s(${castle_args_file:+-args_file "$castle_args_file"})

      # The args file is the effective one, and the default is spelled with
      # REL_VSN_DIR because the launcher does not set RELEASE_VM_ARGS until *after*
      # it has sourced this file.
      assert env_sh =~ ~s(${RELEASE_VM_ARGS:-$REL_VSN_DIR/vm.args})

      # The probe must never boot anything, and the -boot it carries is what makes
      # that true even if -emu_args_exit - which is undocumented - ever stops being
      # recognised: erlexec would pass it through, and the emulator would then fail
      # on a boot file that cannot exist instead of starting a node. The -root test
      # is the other half, refusing to read an answer out of output that is not an
      # argument vector.
      assert env_sh =~ "-boot /nonexistent/castle-heart-probe"
      assert env_sh =~ ~s(grep -q '^-root$')
      assert env_sh =~ "ERL_CRASH_DUMP_SECONDS=0"

      # And there is nothing in front of it. The fragment used to gate the probe on
      # a `case` over the four flag variables and a `read` loop over the args file,
      # so that an ordinary start forked nothing; that is refuted here rather than
      # merely absent, because it reads as the obvious optimisation and would come
      # back. It judged the *text* of those values - the modelling asking erlexec
      # replaced - and it could not see ERL_OTP<major>_FLAGS at all, since POSIX sh
      # cannot enumerate variable names without a fork of its own. What the probe
      # costs, and that it really does run on an ordinary start, is
      # `Forecastle.EnvScriptTest`'s; that it has no gate to run behind is here.
      refute env_sh =~ "castle_ask"
      refute env_sh =~ ~S(*heart* | *args_file*)
      refute env_sh =~ ~s(while IFS= read -r castle_line)

      # The one condition that is left, and it is about the filesystem rather than
      # about contents: erlexec refuses an args file it cannot open, so a release
      # that ships no vm.args is asked about without one instead of being reported
      # unmeasurable. The `-e` test is deliberately not an `-f`/`-r` pair - anything
      # that exists is handed over and answered for.
      assert env_sh =~ ~s|if [ -e "$castle_vm_args" ]; then|

      # No timeout, no polling, no killing: the probe cannot hang, because it
      # starts no emulator. A deployment that already carries two -heart flags -
      # which is the boot this whole block exists to prevent - makes it print two
      # lines and exit 0.
      refute env_sh =~ "sleep"

      # And the three shapes this has been wrong in, refuted rather than merely
      # superseded, because each of them reads as the obvious spelling and each
      # shipped with a test in this repository that agreed with it.
      #
      # A match bounded by literal spaces: the launcher expands these variables
      # unquoted, so tabs and newlines separate fields as surely as spaces do.
      refute env_sh =~ ~s(case " ${ELIXIR_ERL_OPTIONS:-} " in)
      refute env_sh =~ ~s(*" -heart "*)

      # A split into fields, compared against the literal flag: erlexec unquotes
      # what it reads out of the environment, so `'-heart'`, `"-heart"` and
      # `-he\art` are all -heart to the emulator and none of them to that.
      refute env_sh =~ ~s|[ "$castle_opt" = "-heart" ]|
      refute env_sh =~ ~s(for castle_opt in ${ELIXIR_ERL_OPTIONS:-}; do)

      # And a literal scan of the args file, which misses the same escapes, misses
      # a nested -args_file, and cannot tell a commented flag from a live one
      # without a comment rule erlexec does not share.
      refute env_sh =~ ~s|for castle_opt in $(cat "$castle_vm_args")|
      refute env_sh =~ "sed 's/#"
    end

    test "ships the provisional marker protocol names", %{env_sh: env_sh} do
      # new_start_erl.data is written before the reboot and never removed, so on
      # its own it is not evidence that a reboot was asked for. Castle's marker is
      # the other half, and the two have to name one version.
      #
      # Which selection each state produces is asserted in
      # `Forecastle.EnvScriptTest`, by running the fragment over a release-shaped
      # directory. This assembly test owns only the protocol's stable names.
      assert env_sh =~ "releases/castle-restart-pending"
      assert env_sh =~ "releases/new_start_erl.data"
      assert env_sh =~ ~s(castle-restart-consumed.$$)
    end

    test "refuses a version that could name something other than a release",
         %{env_sh: env_sh} do
      # The version comes out of a file and is used to build a path and exported
      # into the VM's environment, so an empty one or one carrying a separator is
      # refused rather than resolved. Kept apart from the value that was read, so
      # that the warning can still say what was actually in the file.
      assert env_sh =~ ~s(case $castle_armed in)
      assert env_sh =~ ~s("" | */*)
      assert env_sh =~ ~s([ ! -f "$RELEASE_ROOT/releases/$castle_usable/env.sh" ])
      assert env_sh =~ ~s([ ! -f "$RELEASE_ROOT/releases/$castle_usable/start.boot" ])
    end

    test "re-execs the launcher rather than assigning the version", %{env_sh: env_sh} do
      # The launcher has already resolved REL_VSN_DIR by the time it sources this,
      # and vm.args, sys.config, the boot script and the elixir launcher all hang
      # off it. Assigning RELEASE_VSN here and returning boots the old version's
      # everything under the new version's name.
      assert env_sh =~ ~s(exec "$RELEASE_ROOT/bin/sample" "$@")

      # And the consumption comes first, which is what stops the second pass
      # recurring.
      claim = :binary.match(env_sh, ~s(mv "$castle_pending")) |> elem(0)
      reexec = :binary.match(env_sh, ~s(exec "$RELEASE_ROOT/bin/sample")) |> elem(0)

      assert claim < reexec
    end

    test "settles the version before it configures the boot", %{env_sh: env_sh} do
      # The re-exec means the fragment is read again, so anything it decides ahead
      # of the selection it decides about the version being *replaced*. heart is
      # the decision that made that fatal: the earlier order probed the permanent
      # version's args, found no flag and exported ELIXIR_ERL_OPTIONS=-heart, and
      # the second pass then counted that beside the target's own. Two flags is
      # init:get_argument(heart) == {ok, [[], []]}, which heart's startup check has
      # no clause for, and a boot that hangs having printed nothing.
      #
      # The same order is what makes the probe's emulator unambiguous, since the
      # release whose `elixir` names it is the selected one.
      #
      # Which flag count each order produces is `Forecastle.EnvScriptTest`'s, over
      # a release-shaped directory whose two versions carry different vm.args - the
      # case that suite did not have, which is why this shipped. What is asserted
      # here is the order itself, in the file that ships, and against the code
      # rather than the prose either side of it.
      reexec = :binary.match(env_sh, ~s(exec "$RELEASE_ROOT/bin/sample" "$@")) |> elem(0)
      probe = :binary.match(env_sh, "castle_argv=$(ERL_CRASH_DUMP_SECONDS=0") |> elem(0)

      heart =
        :binary.match(env_sh, ~s(ELIXIR_ERL_OPTIONS:+$ELIXIR_ERL_OPTIONS }-heart)) |> elem(0)

      assert reexec < probe
      assert reexec < heart
    end

    test "warns rather than refuses when it cannot create the file", %{env_sh: env_sh} do
      # A system does not need the file in order to boot, and a release root
      # nothing may write to is an ordinary way to run one. bin/castle is where
      # the consequence is refused, not the start.
      #
      # The refutation is anchored to a *shell* exit - a line whose whole content
      # is `exit 1` - rather than to the substring. A bare `=~ "exit 1"` also
      # matched `{ exit 1 }` inside the awk program that reads the probe's output,
      # where it ends an awk pass and has nothing to do with the launcher. What
      # this test is about is the fragment never taking the start down, so it has
      # to say that rather than something that happens to be spelled like it.
      # The path interpolated into the warning is the display-safe value with a
      # fixed fallback, never RELEASE_ROOT itself. Capture the local variable so
      # this pins the contract without pinning its implementation name.
      assert [_, display] =
               Regex.run(
                 ~r/(\w+)=\$\(castle_safe_display "\$RELEASE_ROOT"\)\s+\|\|\s+\1="<unprintable>"/,
                 env_sh
               )

      assert env_sh =~ "warning: cannot create $#{display}/releases/RELEASES"
      refute env_sh =~ ~s(warning: cannot create $RELEASE_ROOT/releases/RELEASES)
      assert env_sh =~ "warning: cannot create "
      assert env_sh =~ "/releases/RELEASES. This"
      assert env_sh =~ "can run and restart but cannot unpack or install upgrades"
      assert env_sh =~ "If the release root should be writable"
      assert env_sh =~ "restart before upgrading"
      refute env_sh =~ ~r/^\s*exit 1\s*$/m
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
      # Neither the rename nor anything that would read the renamed file exists
      # any more: Mix's pipeline is intact, the launcher boots what Mix wrote,
      # and Castle resolves the version it is installing in a peer. Both files
      # are asserted because the defect could be either - the configuration
      # withheld, or written twice under two names.
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
