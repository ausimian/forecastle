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

  Two things about the sandbox exist for the heart guard in particular, and both
  are answers to the same three-times-repeated defect - a guard that modelled what
  `erlexec` would make of the environment, and a test that mirrored the model.

  The flag count is obtained by asking a real emulator with `erl -emu_args_exit`,
  which prints the argument vector `erlexec` assembled and exits without starting
  a VM. Nothing here parses a variable or an args file. See `reporting/0`.

  And the sandbox holds a release's own `erts-16.2/bin/erl` - a script that records
  every invocation and then hands over to the real emulator - named by an `elixir`
  carrying the one line of Mix's generated launcher that decides which emulator it
  runs. That is how the fragment resolves its probe, so `probes/2` is how a test
  sees whether the fragment asked *and what it asked with*, neither of which the
  resulting environment says. It asks on every start, deliberately - there used to
  be a gate, and the cases below that changed when it went say so one at a time;
  and `legacy_erl/1` replaces it with one that strips `-emu_args_exit`, which is
  the only way to exercise what the fragment does when an emulator does not know
  the flag it relies on. A second emulator installed under another `erts-*` writes
  to its own log, which is the only way to see *which* one answered.

  The stub `bin/sample` sources the fragment again, as the real launcher sources
  `env.sh` again after the re-exec, so a provisional start is observed as two
  passes rather than as the fact of one. That matters more than it sounds: the
  version is settled before anything else is decided, so on such a start every
  decision the fragment makes belongs to the second pass.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @vsn "0.1.0"
  @next "0.1.1"

  # What the stub launcher prints when the fragment execs it. Nothing else in the
  # fragment writes to standard output, so its presence is the discriminator
  # between a start that selected a provisional version and one that did not.
  @exec "exec:"

  # The emulator of the VM these tests run in, by the path `code:root_dir()`
  # names rather than by a PATH lookup, so that both the fragment's probe and this
  # suite's own reporting ask exactly one binary.
  @erl Path.join([to_string(:code.root_dir()), "bin", "erl"])

  # The ERTS directory the sandbox's releases name, as a release that brought its
  # own has one. Its version is not the running emulator's and does not have to
  # be: nothing here reads a version out of the directory name, which is the
  # point - the fragment is told which directory by the release's own `elixir`
  # rather than left to work it out from the root.
  @erts "erts-16.2"

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

      # The launcher passes this file to the emulator as -args_file, so it is a
      # source of -heart exactly as the flag variables are. This one is the
      # ordinary deployment's: inert, so the probe reads it, finds no flag, and
      # the fragment adds one. The cases that are about it write over this.
      File.write!(Path.join(dir, "vm.args"), "## nothing\n-start_epmd false\n")

      # The one line of Mix's generated `elixir` that decides which emulator the
      # launcher runs, and where the fragment reads that decision from. Both
      # versions name the same ERTS, as every release that did not change one
      # does; the case that is about a root holding several writes over this.
      elixir(root, vsn, @erts)
    end

    # The release's own emulator, as a release that brought its ERTS has it, and
    # the only way to see whether the fragment probed at all: it records the
    # invocation and then hands over to the real thing, so a probe is measured
    # rather than reconstructed. The fragment resolves it out of the `elixir`
    # written above, and this suite's own reporting deliberately does *not* go
    # through it - otherwise every run would look like a probe.
    probing_erl(root)

    # Present so that the RELEASES bootstrap - the fragment's third part, which
    # starts a VM - is skipped. It is not what any of this is about.
    File.write!(Path.join(root, "releases/RELEASES"), "[].\n")
    File.write!(Path.join(root, "releases/start_erl.data"), "16.0 #{@vsn}\n")

    # The launcher, as much of it as the fragment's re-exec depends on. It says
    # which version it was handed - the discriminator for a provisional start -
    # and then does what `bin/<name>` does with it: resolves REL_VSN_DIR from the
    # RELEASE_VSN the previous pass exported, and sources the fragment again.
    #
    # **Sourcing it is the whole point.** Without that, a provisional start is
    # observable only by what the exec printed, and every decision the second pass
    # makes - which is now all of them, since the version is settled before
    # anything else - would be invisible. The pass that boots is the pass under
    # test; this is what lets a test see it.
    File.write!(Path.join(root, "bin/sample"), """
    #!/bin/sh
    echo "#{@exec}$RELEASE_VSN"
    REL_VSN_DIR="$RELEASE_ROOT/releases/$RELEASE_VSN"
    . "$RELEASE_ROOT/run.sh"
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
      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["HEART_COMMAND"] == "<unset>"
      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "says nothing at all", %{root: root} do
      # The normal case has to be silent. A warning on every start of every
      # deployment is a warning nobody reads.
      assert start(root).stderr == ""
    end

    test "asks the emulator anyway", %{root: root} do
      # The cost of the fix on an ordinary start, and it is stated as a property
      # rather than left implied: no flag variable is set and the vm.args is plain
      # flags and comments, so there is nothing here that *could* carry a -heart,
      # and the emulator is asked all the same.
      #
      # There used to be a gate - a `case` over the four flag variables and a
      # `read` loop over the args file - so that a start like this forked nothing,
      # and this test asserted exactly that. It went because it was the last thing
      # in the fragment reasoning about the *text* of those values instead of
      # measuring them, and because it could not see ERL_OTP<major>_FLAGS at all.
      # So what every start now pays is this: one invocation, of a C program that
      # exits without booting an emulator. It is deliberate, and it is asserted
      # rather than tolerated.
      #
      # Recorded by the release's own erl, which is the binary the fragment
      # resolves and the only place a probe could come from.
      assert start(root).env["CASTLE_HEART_FLAGS"] == "1"
      assert [_probe] = probes(root)
    end
  end

  # **The fragment does not read these variables to decide anything; it asks
  # erlexec what the argument vector came out as.** That is the fix, and the
  # matrix below is why it had to be: erlexec applies shell-style quoting and
  # backslash escaping to each of the flag variables it reads, so `'-heart'`,
  # `"-heart"` and `-he\art` all arrive at the emulator as -heart while carrying no
  # `-heart` substring for anything to match on. Three successive versions of this
  # guard modelled the parsing - a match between literal spaces, then a split into
  # fields, then a literal scan of the args file - and each shipped with a test in
  # this file that mirrored the same model and agreed with it.
  #
  # ELIXIR_ERL_OPTIONS is deliberately in the same table and behaves *differently*,
  # which is the sharpest thing here. It is expanded by Mix's generated `elixir`,
  # so the shell splits it into fields and the quotes survive into the token:
  # erlexec unquotes what it reads out of the environment and does not touch the
  # command line, so ELIXIR_ERL_OPTIONS="'-heart'" leaves the emulator with no
  # heart at all and the fragment has to add one. No model of "the four flag
  # variables" gets that right, because they are not four of a kind.
  describe "heart, inherited through a variable erlexec reads" do
    for source <- ~w(ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS),
        {shape, value} <- [
          {"plain", "-heart"},
          {"single quoted", "'-heart'"},
          {"double quoted", ~s("-heart")},
          {"backslash escaped", "-he\\art"},
          {"tab separated", "-heart\t-noshell"},
          {"newline separated", "-noshell\n-heart"},
          {"padded with whitespace", "  -heart \t -noshell  "}
        ] do
      test "is not added a second time for a #{shape} #{source}", %{root: root} do
        source = unquote(source)
        run = start(root, [{source, unquote(value)}])

        # One flag reaching the emulator, from the variable that already had it,
        # and nothing appended to ELIXIR_ERL_OPTIONS - which the fragment must
        # leave alone rather than assign, since assigning it is what makes two.
        # The inherited value is not asserted on: one of these carries a newline,
        # and a value with a newline in it cannot be reported a line at a time.
        assert run.env["CASTLE_HEART_FLAGS"] == "1", "#{source} = #{inspect(unquote(value))}"
        assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      end
    end

    test "is not added a second time for an ERL_OTP<major>_FLAGS", %{root: root} do
      # **The fifth variable, and the one the fragment's gate could not see.**
      # erlexec prepends ERL_OTP<major>_FLAGS exactly as it prepends ERL_AFLAGS, so
      # a -heart in it reaches init:get_argument(heart) like any other - but its
      # name carries the emulator's OTP major, and a POSIX shell looking for it
      # would have to enumerate variable names, which `env` and `export -p` can
      # only do by forking. So the gated fragment never probed for a deployment
      # that set only this one: it appended a second flag and the boot hung having
      # printed nothing. Removing the gate is what closes that, and this is the
      # property it was removed for.
      #
      # The name is derived from the running emulator rather than written out. A
      # hardcoded ERL_OTP28_FLAGS is inert on four of the six cells this repository
      # is verified on, and a test that sets an inert variable measures nothing
      # while passing.
      run = start(root, [{otp_flags(), "-heart"}])

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr == ""
    end

    for source <- ~w(ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS) do
      test "is still added when #{source} carries other flags but no -heart",
           %{root: root} do
        # The other direction, and what stops the fix from being "never add one".
        # A deployment with unrelated flags in these variables still needs the
        # heart the restart transition depends on - and the emulator is asked about
        # them even though nothing in the value could become a -heart, because
        # measuring is unconditional now. The count is what changed here; the
        # outcome is the same one the gated version reached without asking.
        source = unquote(source)
        run = start(root, [{source, "-kernel shell_history enabled"}])

        assert run.env["CASTLE_HEART_FLAGS"] == "1"
        assert run.env["ELIXIR_ERL_OPTIONS"] =~ "-heart"
        assert [_probe] = probes(root)
      end
    end

    for {shape, value} <- [
          {"plain", "-heart"},
          {"tab separated", "-heart\t-noshell"},
          {"newline separated", "-noshell\n-heart\n"},
          {"padded with whitespace", " \t -heart \n  -noshell  "}
        ] do
      test "is not added a second time for a #{shape} ELIXIR_ERL_OPTIONS",
           %{root: root} do
        # The variable Mix's `elixir` expands, unquoted, so what reaches the
        # emulator is its fields under $IFS - space, tab and newline, all three.
        # Only the flag count is asserted for the values carrying a newline,
        # because a value with one in it cannot be reported a line at a time - and
        # the count is the property anyway: it is what init:get_argument(heart)
        # gets built from.
        run = start(root, [{"ELIXIR_ERL_OPTIONS", unquote(value)}])

        assert run.env["CASTLE_HEART_FLAGS"] == "1"
      end
    end

    for {shape, value} <- [
          {"single quoted", "'-heart'"},
          {"double quoted", ~s("-heart")},
          {"backslash escaped", "-he\\art"}
        ] do
      test "is added beside a #{shape} ELIXIR_ERL_OPTIONS, which is not one",
           %{root: root} do
        # And the case that says this is a measurement rather than a rule about
        # four look-alike variables. The shell removes nothing when it expands a
        # variable's value, and erlexec unquotes only what it reads out of the
        # environment itself - so this token reaches the emulator with its quotes
        # or its backslash intact and is not the heart flag. A guard that treated
        # these variables alike would leave the release with no heart and a
        # restart install failing at heart:set_cmd/1.
        run = start(root, [{"ELIXIR_ERL_OPTIONS", unquote(value)}])

        assert run.env["CASTLE_HEART_FLAGS"] == "1"
        assert run.env["ELIXIR_ERL_OPTIONS"] == unquote(value) <> " -heart"
      end
    end

    test "counts one across two sources that each carry a -heart", %{root: root} do
      # A deployment that had already broken its own boot, in which case the
      # fragment's job is only not to make it worse: it adds nothing, and
      # ELIXIR_ERL_OPTIONS is left exactly as it arrived. The two flags are the
      # deployment's, and nothing here can un-break that - but the probe is not
      # troubled by it either, which is what makes a timeout unnecessary: it prints
      # two lines and exits, where a boot would hang.
      run = start(root, [{"ELIXIR_ERL_OPTIONS", "-heart"}, {"ERL_AFLAGS", "-heart"}])

      assert run.env["CASTLE_HEART_FLAGS"] == "2"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
    end
  end

  # The source that is not an environment variable at all: the launcher passes
  # --vm-args to Mix's `elixir`, which becomes erl's -args_file, and a project may
  # legitimately put -heart in its own rel/vm.args.eex. erlexec reads that file
  # with the same quoting it applies to the variables, plus # comments, and follows
  # a nested -args_file out of it - so a literal scan of the file is wrong in three
  # separate directions, and the probe is right in all of them by not being a scan.
  describe "heart, inherited through vm.args" do
    for {shape, contents} <- [
          {"plain", "-heart\n-noshell\n"},
          {"single quoted", "'-heart'\n"},
          {"double quoted", ~s("-heart"\n)},
          {"backslash escaped", "-he\\art\n"},
          {"quoted-hash-preceded", ~s(-setcookie "a#b" -heart\n)}
        ] do
      test "is not added a second time when vm.args carries a #{shape} -heart",
           %{root: root} do
        # The quoted-hash case is the one that refutes comment stripping: erlexec
        # does not treat that # as starting a comment - measured, the cookie
        # arrives as "a#b" - so the -heart after it is live, and a scan that
        # stripped from the first hash would drop it and hang the boot.
        vm_args(root, unquote(contents))

        run = start(root)

        assert run.env["CASTLE_HEART_FLAGS"] == "1"
        assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
        assert run.stderr == ""
      end
    end

    test "is still added when a plain argument after -extra is spelled -heart",
         %{root: root} do
      # The boundary `init` applies and `-emu_args_exit` does not. Everything after
      # -extra goes to the application rather than being parsed as an emulator
      # flag, so `init:get_argument(heart)` answers `error` here - measured - while
      # the probe's output still carries a `-heart` line for it. Counting that line
      # would suppress the flag that *should* be added.
      #
      # Note which way this fails, because it is the opposite of every other case
      # in this describe block and that is why it outlived them: those would add a
      # second flag and hang the boot, this adds none, the release boots happily
      # without heart, and the damage surfaces much later as heart:set_cmd/1
      # refusing a restart transition on a system that looks entirely healthy.
      vm_args(root, "-noinput\n-extra\n-heart\n")

      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.stderr == ""
    end

    test "is not added a second time for one a nested args file supplies",
         %{root: root} do
      # erlexec follows a nested -args_file, so the flag is live and there is no
      # second one to add. The fragment does not follow it and does not have to:
      # what it asks is what the vector came out as, and erlexec built the vector.
      # This case used to produce a warning and no heart, because the fragment
      # could see the nesting and not through it.
      nested = Path.join(root, "nested.vm.args")
      File.write!(nested, "-heart\n")
      vm_args(root, "-args_file #{nested}\n")

      run = start(root)

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr == ""
    end

    test "is added when a nested args file supplies no heart", %{root: root} do
      # The other side of following it, and the reason "assume a nested file has
      # one" was not good enough either: it silently took heart away from every
      # deployment whose vm.args happened to include another file.
      nested = Path.join(root, "nested.vm.args")
      File.write!(nested, "-start_epmd false\n")
      vm_args(root, "-args_file #{nested}\n")

      run = start(root)

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.stderr == ""
    end

    test "is added when the only -heart is inside a comment", %{root: root} do
      # erlexec treats # as starting a comment in an args file, so the emulator
      # really gets no -heart here and one has to be added. The previous fragment
      # counted this as present on purpose, because it could not tell a commented
      # flag from a live one without a comment-stripping rule that would have been
      # wrong about the quoted hash above. Asking erlexec needs no such trade: it
      # is the thing that decides what a comment is.
      vm_args(root, "## an example: -heart\n-noshell\n")

      run = start(root)

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.stderr == ""
    end

    test "is still added when vm.args carries other flags but no -heart",
         %{root: root} do
      # The ordinary deployment, whose vm.args is full of distribution settings and
      # says nothing about heart. The probe reads it and finds nothing, so a flag
      # is added - which is the outcome the gated version reached without asking.
      # The count is what moved; the answer did not.
      vm_args(root, "-start_epmd false\n-erl_epmd_port 24601\n")

      run = start(root)

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.stderr == ""
      assert [_probe] = probes(root)
    end

    test "is read from the file RELEASE_VM_ARGS names, not from the default",
         %{root: root} do
      # RELEASE_VM_ARGS is documented as settable before the release is invoked or
      # inside env.sh, and the launcher only defaults it *after* it has sourced
      # this fragment - so when it is set here, it is set by the deployment and the
      # default would be the wrong file. The default is left inert, so a fragment
      # asking about it instead would append a second flag.
      elsewhere = Path.join(root, "custom.vm.args")
      File.write!(elsewhere, "-heart\n")

      run = start(root, [{"RELEASE_VM_ARGS", elsewhere}])

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"

      # And the probe was told which file, rather than being left to default it
      # the way the launcher will after this returns.
      assert [probe] = probes(root)
      assert probe =~ "-args_file #{elsewhere}"
    end

    test "adds one when the vm.args path does not exist at all", %{root: root} do
      # **The one thing about the measurement that is still conditional, and it is
      # a fact about the filesystem rather than a judgement about contents.**
      # erlexec refuses an args file it cannot open and exits non-zero, so handing
      # over a path that is not there would report the measurement as impossible
      # and decline to add a flag. So the question is asked without the file, and a
      # flag is added.
      #
      # The condition is defensive, not load-bearing: `mix release` always renders
      # rel/vm.args.eex, so a stock build's launcher default always resolves to a
      # file that exists. What this covers is a RELEASE_VM_ARGS pointing at a
      # missing path, or a hand-deleted vm.args - starts the launcher fails on
      # moments later anyway. It is pinned here because it is free and because the
      # refutation below is what makes it observable at all.
      #
      # The reported count is `?` rather than a number because this suite's own
      # reporting passes the missing path unconditionally and so cannot be
      # answered. That is the launcher's position, not the fragment's.
      run = start(root, [{"RELEASE_VM_ARGS", Path.join(root, "nope.vm.args")}])

      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.env["CASTLE_HEART_FLAGS"] == "?"
      assert run.stderr == ""

      # Asked, and asked *without* an args file. Both halves are the discriminator:
      # the first says the fragment measured rather than assuming an absent file
      # carries nothing, and the second says the existence check is what keeps that
      # measurement answerable. Without it this start would take the unmeasurable
      # branch and leave the release with no heart.
      assert [probe] = probes(root)
      refute probe =~ "-args_file"
    end
  end

  # Which emulator answers, which is a question the resulting environment never
  # says anything about - and one the fragment got wrong. It used to glob
  # "$RELEASE_ROOT"/erts-*/bin/erl and keep the last match, which is fine while a
  # release root holds one ERTS and wrong the moment an ERTS-changing release is
  # unpacked into it. ERL_OTP<major>_FLAGS is named for the OTP version of
  # whichever binary answers, so a probe that asked a different one would be
  # answering about a different deployment.
  describe "the emulator the probe asks" do
    test "is the one the selected version's own launcher will run", %{root: root} do
      # **The discriminator: the lexicographically last erts-* is deliberately not
      # the one the release names.** `erts-9.9` sorts after `erts-16.2` - '1' comes
      # before '9' - so this is also the case that shows the old glob was not even
      # "the newest one", which is the reading that makes it sound harmless.
      #
      # The decoy is a working emulator writing to its own log, so the start
      # succeeds either way and the only thing that differs is which log has an
      # entry in it. A test that arranged for the wrong choice to *fail* would pass
      # for the wrong reason.
      probing_erl(root, "erts-9.9", "decoys")

      run = start(root)

      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert [_probe] = probes(root)
      assert probes(root, "decoys") == []
    end

    test "is PATH's when the release brought no ERTS of its own", %{root: root} do
      # `include_erts: false` leaves Mix's own `ERTS_BIN="$ERTS_BIN"` in place, so
      # ERTS_BIN is empty and the launcher runs whatever `erl` is on PATH. The
      # probe has to do the same - this is the shape the fallback exists for, and
      # it has to keep working rather than merely not crash.
      #
      # The release's own erl is still sitting in the root, and its log staying
      # empty is what says the fragment read the file instead of globbing. The
      # measurement itself still lands: PATH's emulator answers, so a -heart is
      # added and nothing is reported as unmeasurable.
      no_erts_elixir(root, @vsn)

      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.stderr == ""
      assert probes(root) == []
    end

    test "is PATH's when the version directory has no elixir at all", %{root: root} do
      # Not a shape a release has - Mix always writes one - but the fragment reads
      # a file to answer this and so has to answer when the file is not there. It
      # falls back rather than reporting the measurement impossible: `erl` from
      # PATH is what an empty ERTS_BIN means, and a start that has lost its
      # `elixir` is one the launcher fails moments later anyway.
      File.rm!(Path.join([root, "releases", @vsn, "elixir"]))

      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.stderr == ""
      assert probes(root) == []
    end
  end

  # The two ways the measurement can fail, and they take the same branch: add
  # nothing and say so. Appending a flag that turns out to be a second one hangs
  # the boot with nothing printed, while adding none leaves heart:set_cmd/1 raising
  # badarg during a restart install - which fails loudly with the system still
  # running. The two are not symmetric, so the unmeasurable case takes the one an
  # operator can see.
  describe "heart, when the emulator cannot be asked" do
    test "adds nothing, and says why, when the args file cannot be read",
         %{root: root} do
      # A directory at the path, rather than a mode, because root and some
      # filesystems ignore modes and this has to be the state it says it is.
      # erlexec refuses to read it, exits non-zero and prints no argument vector.
      path = Path.join(root, "opaque.vm.args")
      File.mkdir!(path)

      run = start(root, [{"RELEASE_VM_ARGS", path}])

      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr =~ "-emu_args_exit did not return an argument vector"
      assert run.stderr =~ "The probe passed -args_file #{path}"
      assert run.stderr =~ "Effective RELEASE_VM_ARGS is [#{path}]"
      assert run.stderr =~ "This start proceeds normally without adding -heart"
      assert run.stderr =~ "a duplicate -heart can hang startup"
      assert run.stderr =~ "Inspect that path and the emulator options"
      assert run.stderr =~ "For restart_emulator upgrades"
      assert run.stderr =~ "either make -emu_args_exit return an argument vector"
      assert run.stderr =~ "supply exactly one -heart"
      assert run.stderr =~ "effective RELEASE_VM_ARGS or emulator options"
      assert [_probe] = probes(root)
    end

    test "adds nothing when -emu_args_exit is not recognised", %{root: root} do
      # The flag is undocumented, and this is the reason relying on it is
      # acceptable: an emulator that no longer knows it degrades to *this*, not to
      # a wrong answer. The probe carries a -boot naming a file that cannot exist,
      # so such an emulator exits at once instead of starting a node, and the -root
      # test refuses to read an answer out of output that is not an argument
      # vector. Arranged by an erl that strips the flag before handing over.
      legacy_erl(root)

      path = Path.join([root, "releases", @vsn, "vm.args"])

      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr =~ "-emu_args_exit did not return an argument vector"
      assert run.stderr =~ "The probe passed -args_file #{path}"
      assert run.stderr =~ "Effective RELEASE_VM_ARGS is [#{path}]"
      assert run.stderr =~ "This start proceeds normally without adding -heart"
      assert run.stderr =~ "Inspect that path and the emulator options"
      assert run.stderr =~ "either make -emu_args_exit return an argument vector"
      assert run.stderr =~ "supply exactly one -heart"
      assert run.stderr =~ "effective RELEASE_VM_ARGS or emulator options"
      assert [_probe] = probes(root)

      # Nothing was booted and nothing was left behind by the attempt: a crash
      # dump in the directory an operator started the release from would be a
      # regression of its own.
      assert Path.wildcard(Path.join(root, "**/erl_crash.dump")) == []
    end

    test "reports a skipped missing args file after a failed probe", %{root: root} do
      legacy_erl(root)

      path = Path.join([root, "releases", @vsn, "vm.args"])
      File.rm!(path)

      run = start(root)

      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr =~ "-emu_args_exit did not return an argument vector"
      assert run.stderr =~ "The probe did not pass -args_file"
      assert run.stderr =~ "Effective RELEASE_VM_ARGS is [#{path}]"
      assert run.stderr =~ "This start proceeds normally without adding -heart"
      assert run.stderr =~ "Inspect that path and the emulator options"
      assert run.stderr =~ "either make -emu_args_exit return an argument vector"
      assert run.stderr =~ "supply exactly one -heart"
      assert run.stderr =~ "effective RELEASE_VM_ARGS or emulator options"
      assert [_probe] = probes(root)
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

      assert run.stderr =~ "ignoring HEART_COMMAND=[/usr/local/bin/restart-me]"
      assert run.stderr =~ "the external supervisor owns restarts"

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
      #
      # Set and empty, which is not the same thing as unset and is what this
      # test used to arrange by accident: an empty value in `System.cmd/3`'s
      # `:env` *removes* the variable, so the case it named was never run. See
      # `run/3`.
      run = start(root, [{"HEART_COMMAND", ""}])

      assert run.stderr == ""
      assert run.env["HEART_COMMAND"] == "<unset>"
    end

    test "says what it overrode when the inherited value is empty", %{root: root} do
      # The two assigned values have no such exemption. An empty HEART_NO_KILL is
      # not TRUE and an empty HEART_BEAT_TIMEOUT is not 65535, so both are being
      # displaced, and the promise is to name every value that stops taking
      # effect. `${VAR:-default}` cannot keep that promise, because it treats a
      # variable set to nothing as absent - which is what these were written with,
      # and why this went unsaid.
      run = start(root, [{"HEART_NO_KILL", ""}, {"HEART_BEAT_TIMEOUT", ""}])

      assert run.stderr =~ "overriding HEART_NO_KILL=[] with TRUE"
      assert run.stderr =~ "overriding HEART_BEAT_TIMEOUT=[] with 65535"

      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "does not echo control bytes from overridden values", %{root: root} do
      hostile = "value\nforged\r\e[31m\a" <> <<0xC2, 0x9B>>
      display = "value%0Aforged%0D%1B[31m%07%C2%9B"

      run =
        start(root, [
          {"HEART_COMMAND", hostile},
          {"HEART_NO_KILL", hostile},
          {"HEART_BEAT_TIMEOUT", hostile}
        ])

      assert run.status == 0

      assert run.stderr ==
               "warning: ignoring HEART_COMMAND=[#{display}] for this " <>
                 "start; the external supervisor owns restarts. Remove HEART_COMMAND from " <>
                 "the environment to silence this.\n" <>
                 "warning: overriding HEART_NO_KILL=[#{display}] with " <>
                 "TRUE for this start so heart cannot kill the node. Remove HEART_NO_KILL " <>
                 "from the environment to silence this.\n" <>
                 "warning: overriding HEART_BEAT_TIMEOUT=[#{display}] " <>
                 "with 65535 for this start so a heartbeat timeout cannot stop the node. " <>
                 "Remove HEART_BEAT_TIMEOUT from the environment to silence this.\n"

      assert run.env["HEART_COMMAND"] == "<unset>"
      assert run.env["HEART_NO_KILL"] == "TRUE"
      assert run.env["HEART_BEAT_TIMEOUT"] == "65535"
    end

    test "keeps literal echo escape spellings inert", %{root: root} do
      run =
        start(root, [
          {"HEART_COMMAND", ~S(value\nforged)},
          {"HEART_NO_KILL", ~S(value\0033[31mforged)},
          {"HEART_BEAT_TIMEOUT", ~S(value\cforged)}
        ])

      assert run.status == 0
      assert run.stderr =~ "HEART_COMMAND=[value\\nforged]"
      assert run.stderr =~ "HEART_NO_KILL=[value\\0033[31mforged]"
      assert run.stderr =~ "HEART_BEAT_TIMEOUT=[value\\cforged] with 65535"
      assert length(String.split(run.stderr, "\n", trim: true)) == 3
      refute run.stderr =~ "\e"
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

      # And no emulator was asked anything, which is the sharper half now that the
      # heart guard asks on *every* start: `bin/castle` reaches every command
      # through `rpc`, so a fragment that ran here would put a fork of erl in front
      # of every release-management call. This is the assertion that keeps the
      # probe's cost bounded to a node start, and it is the reason the removed gate
      # was not the only thing standing between the fork and the common path.
      assert probes(root) == []
    end
  end

  describe "RELEASES bootstrap diagnostics" do
    test "keeps a non-ASCII release root identifiable", %{root: root} do
      unicode_root = root <> "-café"
      File.ln_s!(root, unicode_root)
      on_exit(fn -> File.rm(unicode_root) end)
      File.rm!(Path.join(root, "releases/RELEASES"))

      run =
        start(root, [
          {"RELEASE_ROOT", unicode_root},
          {"REL_VSN_DIR", Path.join([unicode_root, "releases", @vsn])}
        ])

      assert run.status == 0
      assert run.stderr =~ String.replace(unicode_root, "é", "%C3%A9") <> "/releases/RELEASES"
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

      assert run.status == 0
      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.stderr == ""
    end

    test "falls back safely when OTP's marker has only one field", %{root: root} do
      File.write!(pending(root), "#{@next}\nsome-attempt\n")
      File.write!(provisional(root), "#{@next}\n")

      run = start(root)

      assert run.status == 0
      refute run.stdout =~ @exec
      assert run.stderr =~ "cannot select the provisional release"
      assert run.stderr =~ "OTP marker [<malformed non-empty line>]"
      assert run.stderr =~ "OTP marker is malformed; expected '<erts> <version>'"
      assert run.stderr =~ "Preserved as releases/new_start_erl.data.rejected."
      assert run.stderr =~ "Booting the permanent release from releases/start_erl.data"
      refute armed?(root)
      refute provisional?(root)
      assert claims(root) == []
      assert [evidence] = rejected(root)
      assert File.read!(evidence) == "#{@next}\n"

      retry = start(root)
      refute retry.stdout =~ @exec
      assert retry.stderr == ""
      assert rejected(root) == [evidence]
    end

    test "rejects other malformed OTP marker shapes", %{root: root} do
      malformed = [
        {"tab separator", "16.0\t#{@next}\n", "\t"},
        {"trailing carriage return", "16.0 #{@next}\r\n", "\r"},
        {"path separator", "16.0 ../#{@next}\n", nil}
      ]

      for {shape, line, control} <- malformed do
        File.write!(pending(root), "#{@next}\nsome-attempt\n")
        File.write!(provisional(root), line)

        run = start(root)

        assert run.status == 0, shape
        refute run.stdout =~ @exec, shape
        assert run.stderr =~ "OTP marker [<malformed non-empty line>]", shape
        assert run.stderr =~ "OTP marker is malformed; expected '<erts> <version>'", shape
        assert run.stderr =~ "Preserved as releases/new_start_erl.data.rejected.", shape
        refute armed?(root), shape
        refute provisional?(root), shape
        assert claims(root) == [], shape

        assert [evidence] = rejected(root)
        assert File.read!(evidence) == line
        if control, do: refute(String.contains?(run.stderr, control), shape)
        File.rm!(evidence)
      end
    end

    test "preserves spaces after OTP's first separator as part of the version", %{root: root} do
      versions = ["#{@next} extra", " #{@next}"]

      for version <- versions do
        release_fixture(root, version)
        arm(root, version)

        run = start(root)

        assert run.status == 0, inspect(version)
        assert run.stdout =~ "#{@exec}#{version}", inspect(version)
        assert run.stderr == "", inspect(version)
        refute armed?(root), inspect(version)
        refute provisional?(root), inspect(version)
        assert claims(root) == [], inspect(version)
        assert rejected(root) == [], inspect(version)
      end
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

    test "still boots when the OTP marker cannot be removed", %{root: root} do
      # A removal that fails must not take the launcher down with it. The launcher
      # sources this fragment under `set -e`, and `rm -f` exits non-zero for a path
      # it cannot unlink - a directory at the name being the easy case, since `-f`
      # does not cover one. Unguarded, that ended the launcher here, *after* the
      # `mv` had already claimed the pending marker: no warning, no fallback, and
      # no boot at all. A service that stays down is worse than one on the wrong
      # version, and the wrong version was never the risk here.
      #
      # So the pair is treated as unsettled and the fragment falls through to the
      # fallback path: it warns, execs nothing, and leaves the stock launcher to
      # read start_erl.data - the permanent version, which is the safe direction
      # and the one the rollback property rests on.
      #
      # **The discriminator is the exit status**, not the output. Under `set -e` an
      # unguarded `rm` ends the sourcing shell where it stands, so the fragment
      # neither warns nor returns: status is non-zero and the warning is absent.
      # Both assertions below fail against the unguarded version, and the status is
      # the one that says the launcher would have died rather than merely said
      # something different.
      arm(root, @next)
      File.rm!(provisional(root))
      File.mkdir_p!(provisional(root))

      run = start(root)

      assert run.status == 0, "the launcher was taken down while sourcing env.sh"
      assert run.stderr =~ "cannot select the provisional release"
      assert run.stderr =~ "OTP marker could not be removed"
      assert run.stderr =~ "Booting the permanent release from releases/start_erl.data"
      assert provisional?(root)
      assert claims(root) == []
      refute run.stdout =~ @exec
    end

    test "still boots when Castle's claim cannot be removed", %{root: root} do
      # A directory can be renamed into the claim slot but not removed with
      # `rm -f`. The OTP marker is still consumed, and the warning identifies
      # the claim that remains for an operator to inspect.
      File.mkdir!(pending(root))
      File.write!(provisional(root), "16.0 #{@next}\n")

      run = start(root)

      assert run.status == 0, "the launcher was taken down while sourcing env.sh"
      assert run.stderr =~ "Castle marker could not be removed"
      assert run.stderr =~ "Booting the permanent release from releases/start_erl.data"
      assert length(claims(root)) == 1
      refute provisional?(root)
      refute run.stdout =~ @exec
    end

    test "reports a Castle claim that cannot be read", %{root: root} do
      # A symlink to a directory is readable on some systems and rejected by
      # `head` differently across implementations. The regular-file check makes
      # the result independent of either behavior.
      opaque = Path.join(root, "opaque-castle-marker")
      File.mkdir!(opaque)
      File.ln_s!(opaque, pending(root))
      File.write!(provisional(root), "16.0 #{@next}\n")

      run = start(root)

      assert run.status == 0
      assert run.stderr =~ "Castle marker could not be read"
      assert claims(root) == []
      refute provisional?(root)
      refute run.stdout =~ @exec
    end

    test "reports an OTP marker that cannot be read", %{root: root} do
      # As above, use a directory symlink so this does not rely on file modes or
      # on a particular `head` implementation's handling of directories.
      opaque = Path.join(root, "opaque-otp-marker")
      File.mkdir!(opaque)
      File.write!(pending(root), "#{@next}\nsome-attempt\n")
      File.ln_s!(opaque, provisional(root))

      run = start(root)

      assert run.status == 0
      assert run.stderr =~ "OTP marker could not be read"
      assert claims(root) == []
      refute provisional?(root)
      refute run.stdout =~ @exec
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
      assert run.stderr =~ "cannot select the provisional release"
      assert run.stderr =~ "Castle marker [#{@next}]; OTP marker [<absent>]"
      assert run.stderr =~ "OTP marker is absent; no restart was prepared"
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
      assert run.stderr =~ "Castle marker [#{@next}]; OTP marker [#{@vsn}]"
      assert run.stderr =~ "the markers name different versions"
      refute armed?(root)
      refute provisional?(root)
    end

    test "does not print control bytes from Castle's marker", %{root: root} do
      controlled = [
        {"carriage return", "#{@next}\r", "\r", "%0D"},
        {"escape", "#{@next}\e[31m", "\e", "%1B[31m"},
        {"C1 control", "#{@next}" <> <<0xC2, 0x9B>>, <<0xC2, 0x9B>>, "%C2%9B"}
      ]

      for {shape, version, control, encoded} <- controlled do
        File.write!(pending(root), "#{version}\nsome-attempt\n")
        File.write!(provisional(root), "16.0 #{@next}\n")

        run = start(root)

        assert run.status == 0, shape
        refute run.stdout =~ @exec, shape

        assert run.stderr =~ "Castle marker [#{@next}#{encoded}]", shape

        assert run.stderr =~ "Castle's marker has no usable version", shape
        refute String.contains?(run.stderr, control), shape
        refute armed?(root), shape
        refute provisional?(root), shape
        assert claims(root) == [], shape
        assert rejected(root) == [], shape
      end
    end

    test "display-tool failures cannot reject valid provisional evidence", %{root: root} do
      for tool <- ["od", "awk"] do
        arm(root, @next)

        run = start(root, failing_tool(root, tool))

        assert run.status == 0, tool
        assert run.stdout =~ "#{@exec}#{@next}", tool
        assert run.stderr == "", tool
        refute armed?(root), tool
        refute provisional?(root), tool
        assert claims(root) == [], tool
        assert rejected(root) == [], tool

        if tool == "od" do
          refute File.exists?(failing_tool_log(root, tool))
        end

        # A real mismatch still reports its real reason. Only the values fall
        # back when the display helper is unavailable; neither marker is called
        # malformed and OTP's valid marker is not quarantined.
        File.write!(pending(root), "#{@next}\nsome-attempt\n")
        File.write!(provisional(root), "16.0 #{@vsn}\n")

        mismatch = start(root, failing_tool(root, tool))

        assert mismatch.status == 0, tool
        refute mismatch.stdout =~ @exec, tool
        assert mismatch.stderr =~ "Castle marker [<unprintable>]", tool
        assert mismatch.stderr =~ "OTP marker [<unprintable>]", tool
        assert mismatch.stderr =~ "the markers name different versions", tool
        refute mismatch.stderr =~ "malformed", tool
        assert rejected(root) == [], tool

        if tool == "od" do
          assert File.exists?(failing_tool_log(root, tool))
        end
      end
    end

    test "is not selected from a version that could name something else",
         %{root: root} do
      # The version comes out of a file, is used to build a path and is exported
      # into the environment of a VM, so one carrying a separator is refused
      # rather than resolved.
      File.write!(pending(root), "../#{@next}\nsome-attempt\n")
      File.write!(provisional(root), "16.0 #{@next}\n")

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "cannot select the provisional release"
      assert run.stderr =~ "Castle marker [../#{@next}]; OTP marker [#{@next}]"
      assert run.stderr =~ "Castle's marker has no usable version"
    end

    test "is not selected from a version directory without env.sh", %{root: root} do
      File.rm!(Path.join([root, "releases", @next, "env.sh"]))
      arm(root, @next)

      run = start(root)

      refute run.stdout =~ @exec
      assert run.stderr =~ "Castle marker [#{@next}]; OTP marker [#{@next}]"
      assert run.stderr =~ "env.sh is missing from the target release"
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
      assert run.stderr =~ "cannot select the provisional release"
      assert run.stderr =~ "Castle marker [#{@next}]; OTP marker [#{@next}]"
      assert run.stderr =~ "start.boot is missing from the target release"
    end
  end

  # **Everything the fragment configures, it configures for the version that is
  # going to boot.** The selection re-execs, so the fragment is read twice on a
  # provisional start - and the boot is the second pass's. Anything decided before
  # the re-exec is decided about the version the launcher was *invoked* as, which
  # on this start is the one that is being replaced.
  #
  # That is not a tidiness argument. It shipped the other way round, with the heart
  # block ahead of the selection, and the two halves of what that costs are below.
  # The suite had no case where the two versions differed, which is why it shipped.
  describe "a provisional start decides for the version it boots" do
    test "counts the target's -heart rather than inheriting one for it",
         %{root: root} do
      # **The bug, and the case the suite was missing.** With the heart block
      # ahead of the selection: pass 1 probed the *permanent* version's vm.args,
      # found no -heart, and exported ELIXIR_ERL_OPTIONS=-heart; pass 2 then probed
      # the target's, saw its own flag beside the inherited one, measured two and
      # so declined to append a third - but nothing removes what pass 1 exported.
      # The target booted with two, which is init:get_argument(heart) ==
      # {ok, [[], []]} and a hang with nothing printed.
      #
      # So the target carries a -heart and the permanent version does not, which is
      # the shape that separates the two orders. There is nothing for the fragment
      # to do here: one flag is already coming, and it must add none.
      vm_args(root, "-heart\n", @next)
      arm(root, @next)

      run = start(root)

      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "<unset>"
      assert run.stderr == ""

      # Asked once, and asked about the target. Two probes is the other face of
      # the same defect: the first of them was a question about a version that is
      # not going to boot, and its answer is what got exported.
      assert [probe] = probes(root)
      assert probe =~ "-args_file #{Path.join([root, "releases", @next, "vm.args"])}"
    end

    test "adds one for a target that has none, whatever the permanent version had",
         %{root: root} do
      # The other direction, and the one that says the permanent version's args are
      # not consulted at all rather than merely consulted early. Its vm.args has a
      # -heart, the target's does not, and the target needs one added.
      vm_args(root, "-heart\n")
      arm(root, @next)

      run = start(root)

      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.env["ELIXIR_ERL_OPTIONS"] == "-heart"
      assert run.env["CASTLE_HEART_FLAGS"] == "1"
      assert [_probe] = probes(root)
    end

    test "asks the target's own emulator, not the root's last erts-*",
         %{root: root} do
      # **The two defects meeting, and the one case that separates both of them at
      # once.** An install that changes ERTS leaves a second erts-* in the root,
      # and it is a provisional start that boots the version which brought it. The
      # version being replaced names `erts-9.9` and the target names `erts-16.2`,
      # so the wrong answer is the same either way round: the glob this replaced
      # keeps the lexicographically last match, which is `erts-9.9`, and the order
      # this replaced asked before the target was chosen, which is also `erts-9.9`.
      probing_erl(root, "erts-9.9", "decoys")
      elixir(root, @vsn, "erts-9.9")
      arm(root, @next)

      run = start(root)

      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.env["CASTLE_HEART_FLAGS"] == "1"

      # The target's emulator answered, and the one belonging to the version being
      # replaced was not asked at all.
      assert [_probe] = probes(root)
      assert probes(root, "decoys") == []
    end

    test "reports an overridden heart setting once", %{root: root} do
      # The warnings belong to the boot, and there is one boot. This used to hold
      # for a different reason - pass 1 warned and exported the corrected values,
      # so pass 2 found nothing left to override - and it has to keep holding now
      # that the block runs only on the pass that boots. Either way an operator
      # sees each conflict named once.
      arm(root, @next)

      run = start(root, [{"HEART_COMMAND", "/usr/local/bin/restart-me"}])

      assert run.stdout =~ "#{@exec}#{@next}"
      assert run.env["HEART_COMMAND"] == "<unset>"
      assert [_before, _after] = String.split(run.stderr, "ignoring HEART_COMMAND")
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

    # `set -e`, because the launcher has it: `bin/<name>` is `#!/bin/sh` followed
    # by `set -e`, and it *sources* this fragment, so every command in here runs
    # under it. Without it the sandbox is more forgiving than the boot path - a
    # top-level non-zero exit would take a real launcher down and pass here - and
    # the fragment has several commands whose failure is ordinary: a `grep -q` that
    # finds nothing, a command substitution around an emulator that refused an args
    # file. Each of those has to be written so that it cannot end the start.
    File.write!(script, "set -e\n" <> fragment() <> reporting())

    {empty, set} = Enum.split_with(environment(root, command, env), &(elem(&1, 1) == ""))

    # Redirected inside the shell rather than merged by System.cmd/3, because
    # which stream a warning went to is one of the things being asserted.
    #
    # A variable that has to arrive *set and empty* cannot go through
    # `System.cmd/3`'s `:env`, and this is measured rather than assumed: an empty
    # value there removes the variable, the same as `nil` does. So the empty ones
    # are shell assignments prefixed to the command instead, which is the one
    # place the distinction can be made - and it has to be made, because
    # `${VAR:-default}` cannot tell the two apart and that is the defect these
    # tests are here for. Without `exec`, so that they prefix an ordinary command
    # and are exported to it by the rules for one.
    assignments = Enum.map_join(empty, "", fn {name, _} -> "#{name}= " end)

    # `cd: root` so that anything an emulator drops in its working directory - a
    # crash dump, most of all - lands inside the sandbox where a test can look for
    # it, rather than in whatever directory the suite was started from.
    {_, status} =
      System.cmd("sh", ["-c", ~s(#{assignments}sh "#{script}" > "#{out}" 2> "#{err}")],
        env: set,
        cd: root
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
  #
  # The three ERL_*FLAGS are cleared for the same reason ELIXIR_ERL_OPTIONS is.
  # They matter more, not less: they are read by erlexec rather than by anything
  # Mix generates, so a developer or a CI image with one of them set would leak a
  # -heart into every case here and make the fragment's own additions invisible.
  #
  # `otp_flags()` is in the list for that reason and no other. It is a fifth
  # variable erlexec reads, so it leaks the same way - and it is the one this
  # environment could not have named while the fragment's gate existed, since the
  # gate's whole limitation was that a shell cannot enumerate variable names.
  # Cleared here and set by the one test that is about it.
  defp environment(root, command, env) do
    [
      {"RELEASE_COMMAND", command},
      {"RELEASE_ROOT", root},
      {"REL_VSN_DIR", Path.join([root, "releases", @vsn])},
      {"RELEASE_VSN", @vsn},
      {"ELIXIR_ERL_OPTIONS", nil},
      {"ERL_AFLAGS", nil},
      {"ERL_FLAGS", nil},
      {"ERL_ZFLAGS", nil},
      {otp_flags(), nil},
      {"RELEASE_VM_ARGS", nil},
      {"HEART_COMMAND", nil},
      {"HEART_NO_KILL", nil},
      {"HEART_BEAT_TIMEOUT", nil}
    ] ++ env
  end

  defp failing_tool(root, tool) do
    shims = Path.join(root, "failing-#{tool}")
    File.mkdir_p!(shims)

    File.write!(
      Path.join(shims, tool),
      "#!/bin/sh\nprintf x >> #{failing_tool_log(root, tool)}\nexit 1\n"
    )

    File.chmod!(Path.join(shims, tool), 0o755)

    [{"PATH", shims <> ":" <> System.get_env("PATH")}]
  end

  defp failing_tool_log(root, tool), do: Path.join(root, "failing-#{tool}-calls")

  # ERL_OTP<major>_FLAGS for the emulator the fragment will probe. That is the
  # same one this suite reports with - the sandbox's erts-*/bin/erl hands over to
  # `@erl` - so one name covers both, and it is resolved at run time rather than
  # compiled in, because the major differs across the cells this is verified on.
  defp otp_flags, do: "ERL_OTP#{:erlang.system_info(:otp_release)}_FLAGS"

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
  #
  # CASTLE_HEART_FLAGS is not one of the variables: it is how many -heart flags
  # the emulator would be given, which is the property the fragment's check
  # exists for and the only one that survives a value with a tab or a newline in
  # it, since those cannot be reported a line at a time. Two of them is
  # init:get_argument(heart) == {ok, [[], []]}, which hangs the boot.
  #
  # **It is counted by asking an emulator, and it used to be counted by a shell
  # loop.** That loop is how three successive defects survived: the guard modelled
  # what erlexec would make of the environment, this counter modelled the same
  # thing the same way, and so they agreed with each other and with the bug. It
  # matched between spaces while the guard did; it split into fields while the
  # guard did; it read vm.args literally while the guard did. Every version of it
  # was refuted by the same counterexample that refuted the guard, one round late.
  #
  # So there is no parsing here at all. `erl -emu_args_exit` prints the argument
  # vector erlexec assembled - out of the command line, ERL_OTP<major>_FLAGS,
  # ERL_AFLAGS, ERL_FLAGS, ERL_ZFLAGS and every -args_file it followed, with all of
  # erlexec's quoting, escaping and comment handling applied - one argument per
  # line, and exits without starting a VM. A line that is exactly `-heart` is a
  # -heart the emulator would get. **Do not replace this with a shell counter
  # again**, whatever shape it takes: what it would be counting is somebody's model
  # of erlexec, which is the thing under test.
  #
  # ELIXIR_ERL_OPTIONS is expanded unquoted and placed before -args_file because
  # that is where Mix's generated `elixir` puts them, so this is the vector the
  # start would really have produced rather than a rearrangement of it.
  #
  # The emulator is asked by its absolute path, deliberately *not* through the
  # release's own erts-*/bin/erl - that one records the fact of being called, so
  # that a test can tell whether the fragment probed, and this reporting must not
  # look like a probe.
  #
  # `?` rather than a number when the answer is not an argument vector, which
  # happens when erlexec refuses the args file. A count of nothing must not be
  # reportable as a count of zero.
  defp reporting do
    """

    for castle_var in ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS \\
                      HEART_COMMAND HEART_NO_KILL HEART_BEAT_TIMEOUT; do
      eval "castle_val=\\${$castle_var-<unset>}"
      printf 'env %s=%s\\n' "$castle_var" "$castle_val"
    done

    castle_report_argv=$(ERL_CRASH_DUMP_SECONDS=0 "#{@erl}" \\
                           -emu_args_exit -noinput \\
                           -boot /nonexistent/castle-heart-report \\
                           ${ELIXIR_ERL_OPTIONS-} \\
                           -args_file "${RELEASE_VM_ARGS:-$REL_VSN_DIR/vm.args}" \\
                           2>/dev/null </dev/null) || castle_report_argv=""

    if printf '%s\\n' "$castle_report_argv" | grep -q '^-root$'; then
      castle_flags=$(printf '%s\\n' "$castle_report_argv" | grep -c '^-heart$') ||
        castle_flags=0
    else
      castle_flags="?"
    fi

    printf 'env CASTLE_HEART_FLAGS=%s\\n' "$castle_flags"
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

  defp release_fixture(root, vsn) do
    dir = Path.join([root, "releases", vsn])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "env.sh"), "# nothing\n")
    File.write!(Path.join(dir, "start.boot"), "")
    File.write!(Path.join(dir, "vm.args"), "## nothing\n-start_epmd false\n")
    elixir(root, vsn, @erts)
  end

  # Replaces the inert vm.args the setup wrote for a version, which is the file
  # the launcher will pass as -args_file when it boots that one. The default is
  # the version start_erl.data names, because that is the one an ordinary start
  # boots; a provisional start's target is named explicitly.
  defp vm_args(root, contents, vsn \\ @vsn) do
    File.write!(Path.join([root, "releases", vsn, "vm.args"]), contents)
  end

  # The one line of Mix's generated `elixir` that the fragment reads to find the
  # emulator the launcher will run. `mix release` rewrites the stock
  # `ERTS_BIN="$ERTS_BIN"` into this when the release brought an ERTS of its own,
  # and leaves it alone when it did not - which `no_erts_elixir/2` is for. The
  # rest of that script is a few hundred lines of argument parsing that nothing
  # here reads, so only the assignment is written.
  #
  # `$SCRIPT_PATH` is left as the literal it is in the real file: the fragment
  # resolves it against REL_VSN_DIR rather than expanding it, so writing anything
  # else here would be testing a file Mix does not generate.
  defp elixir(root, vsn, erts) do
    File.write!(
      Path.join([root, "releases", vsn, "elixir"]),
      ~s|ERTS_BIN=\nERTS_BIN="$SCRIPT_PATH"/../../#{erts}/bin/\n|
    )
  end

  # The same file as a release with `include_erts: false` has it, which is Mix's
  # own two lines untouched. ERTS_BIN comes out empty, so the launcher runs `erl`
  # from PATH and so must the probe.
  defp no_erts_elixir(root, vsn) do
    File.write!(
      Path.join([root, "releases", vsn, "elixir"]),
      ~s|ERTS_BIN=\nERTS_BIN="$ERTS_BIN"\n|
    )
  end

  # The release's own emulator, at the path Mix's generated `elixir` resolves
  # ERTS_BIN to and the fragment resolves its probe through. It records that it was
  # called, with its arguments, and then hands over to the real one - so whether
  # the fragment probed, how often, and what it asked are observable, which nothing
  # about the resulting environment says.
  #
  # A recording wrapper rather than a stub answer, because a stub would make every
  # case about the wrapper's idea of erlexec instead of about erlexec.
  defp probing_erl(root, erts \\ @erts, log \\ "probes") do
    install_erl(root, erts, log, ~s|exec "#{@erl}" "$@"\n|)
  end

  # The same, for an emulator that does not know -emu_args_exit: it strips the flag
  # and hands the rest over, which is what a future OTP that dropped it would
  # effectively do - erlexec would pass the unknown flag through and try to boot.
  # That is the case the fragment has to degrade safely on rather than answer
  # wrongly, and there is no other way to arrange it.
  defp legacy_erl(root) do
    install_erl(root, @erts, "probes", """
    castle_n=$#
    castle_i=0
    while [ $castle_i -lt $castle_n ]; do
      case $1 in
        -emu_args_exit) ;;
        *) set -- "$@" "$1" ;;
      esac
      shift
      castle_i=$((castle_i + 1))
    done
    exec "#{@erl}" "$@"
    """)
  end

  # The log is a parameter so that a second emulator in the same root can be told
  # apart from the release's own. Which binary answered is not visible in the
  # arguments - it is the same probe either way - so the only way to see it is for
  # each to write somewhere different.
  defp install_erl(root, erts, log, body) do
    path = Path.join([root, erts, "bin", "erl"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    echo "probe: $*" >> "#{Path.join(root, log)}"
    #{body}
    """)

    File.chmod!(path, 0o755)
  end

  # One entry per invocation of the erl that writes to this log, each the
  # arguments it was given. Split on the marker rather than on newlines, because
  # an argument may carry one.
  defp probes(root, log \\ "probes") do
    case File.read(Path.join(root, log)) do
      {:ok, contents} -> String.split(contents, "probe: ", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp pending(root), do: Path.join(root, "releases/castle-restart-pending")
  defp provisional(root), do: Path.join(root, "releases/new_start_erl.data")
  defp rejected(root), do: Path.wildcard(provisional(root) <> ".rejected.*")

  defp armed?(root), do: File.exists?(pending(root))
  defp provisional?(root), do: File.exists?(provisional(root))
  defp claims(root), do: Path.wildcard(Path.join(root, "releases/castle-restart-consumed*"))
end
