defmodule Forecastle.CastleCliTest do
  @moduledoc """
  Exercises the generated `bin/castle` as a shell script.

  The release launcher is replaced with a stub that records the arguments it was
  handed, so these tests pin down exactly what `bin/castle` delegates without
  needing a running system. Every call appends to the same record, so a command
  that reaches the launcher more than once - `install`, which confirms what it
  installed - reads back as one flat list of arguments in the order they were
  passed.

  Replacing that stub is also the only way to simulate a transition that
  restarts the emulator: nothing can build a relup that asks for one until #4,
  so the end-to-end suite cannot produce it.
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
      ~s(#!/bin/sh\nprintf '%s\\0' "$@" >> "#{record}"\nprintf '%s' "$CASTLE_STUB_OUTPUT"\n)
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

    test "install, and then the confirmation that it took effect", context do
      assert castle!(context, ["install", "0.1.1"]) == [
               "rpc",
               "Castle.install(~s(0.1.1))",
               "rpc",
               "Castle.running(~s(0.1.1))"
             ]
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

  describe "install" do
    # release_handler replies as soon as it has accepted an upgrade. For a
    # transition that restarts the emulator that is before the upgrade has run,
    # and the reply may not even outlive the reboot it triggers - so the reply
    # is not what decides the exit status here. Seeing the version running is.

    test "reports what the install said, and exits zero once confirmed", context do
      assert {output, 0} =
               castle(context, ["install", "0.1.1"], [
                 {"CASTLE_STUB_OUTPUT", "Now running 0.1.1 (previously 0.1.0)."}
               ])

      assert output =~ "Now running 0.1.1 (previously 0.1.0)."
    end

    test "treats a node that has gone away as inconclusive, not as a failure", context do
      # A successful restart transition looks exactly like this from out here:
      # the reply crosses distribution, and the reboot takes distribution down.
      stub_launcher!(context, """
      if [ -f "#{context.root}/rebooted" ]; then exit 0; fi
      : > "#{context.root}/rebooted"
      echo '--rpc-eval : RPC failed with reason :noconnection' >&2
      exit 1
      """)

      assert {output, 0} = castle(context, ["install", "0.1.1"])
      assert output =~ "noconnection"

      assert calls(context) == [
               "rpc",
               "Castle.install(~s(0.1.1))",
               "rpc",
               "Castle.running(~s(0.1.1))"
             ]
    end

    test "does not mistake an install that failed for a restart", context do
      stub_launcher!(context, """
      echo '** (Castle.Error) Install of 0.1.1 failed. {:no_such_release, 0.1.1}' >&2
      exit 1
      """)

      assert {output, 1} = castle(context, ["install", "0.1.1"])
      assert output =~ "Install of 0.1.1 failed."

      # Nothing to wait for: the system said no. Polling would only delay the
      # report by however long the timeout is.
      assert calls(context) == ["rpc", "Castle.install(~s(0.1.1))"]
    end

    test "propagates a failing launcher exit status", context do
      stub_launcher!(context, "echo 'rpc failed' >&2\nexit 3\n")

      assert {_output, 3} = castle(context, ["install", "0.1.1"])
    end

    test "does not read a failure that merely mentions the word as a restart", context do
      # `noconnection` is a usable release version, so it appears in the message
      # naming the version that could not be installed. Recognising it there
      # would send a failed install off to be confirmed rather than reported -
      # and confirmation succeeds here, so a bare match would exit 0 for a
      # launcher that failed with 3.
      stub_launcher!(context, """
      if [ -f "#{context.root}/tried" ]; then exit 0; fi
      : > "#{context.root}/tried"
      echo '** (Castle.Error) Install of noconnection failed. {:no_such_release, noconnection}' >&2
      exit 3
      """)

      assert {output, 3} = castle(context, ["install", "noconnection"])
      assert output =~ "Install of noconnection failed."
      assert calls(context) == ["rpc", "Castle.install(~s(noconnection))"]
    end

    test "confirms a version named noconnection like any other", context do
      # The other half of that: the word in the version must not get in the way
      # of the ordinary path either.
      assert castle!(context, ["install", "noconnection"]) == [
               "rpc",
               "Castle.install(~s(noconnection))",
               "rpc",
               "Castle.running(~s(noconnection))"
             ]
    end

    test "fails when the version never becomes the one running", context do
      stub_launcher!(context, """
      if [ -f "#{context.root}/installed" ]; then
        echo '** (Castle.Error) 0.1.1 is not the running release. 0.1.0 is.' >&2
        exit 1
      fi
      : > "#{context.root}/installed"
      exit 0
      """)

      assert {output, 1} =
               castle(context, ["install", "0.1.1"], [{"CASTLE_INSTALL_TIMEOUT", "1"}])

      assert output =~ "0.1.1 is not the running release, 1s after installing it"
      # And what the last attempt saw, which is what says where it went wrong.
      assert output =~ "0.1.1 is not the running release. 0.1.0 is."
    end

    test "refuses a timeout that is not a number of seconds", context do
      assert {output, status} =
               castle(context, ["install", "0.1.1"], [{"CASTLE_INSTALL_TIMEOUT", "soon"}])

      assert status != 0
      assert output =~ "CASTLE_INSTALL_TIMEOUT must be a whole number of seconds"
      refute recorded?(context)
    end
  end

  describe "the timeout install waits for" do
    # It is a deadline in elapsed time, not a count of attempts: the operator
    # gave seconds, and the time each attempt takes has to count against them
    # as much as the sleeps do.

    test "is waited out, rather than spent on a fixed number of attempts", context do
      # Two seconds used to buy exactly one attempt, made immediately, so a
      # confirmation that needed a second one never got it.
      stub_confirmations!(context, 2)

      {{_output, status}, elapsed} =
        timed(fn -> install(context, "0.1.1", "2") end)

      assert status == 0

      assert calls(context) == [
               "rpc",
               "Castle.install(~s(0.1.1))",
               "rpc",
               "Castle.running(~s(0.1.1))",
               "rpc",
               "Castle.running(~s(0.1.1))"
             ]

      assert elapsed >= 2_000, "gave up #{elapsed}ms into a 2s timeout"
    end

    test "is honoured when it is not a multiple of how often it looks", context do
      stub_confirmations!(context, :never)

      {{output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "3") end)

      assert status == 1
      assert output =~ "3s after installing it"
      # At 0s and 2s, and a last one at the deadline itself, so a confirmation
      # that arrives just as time runs out is not thrown away.
      assert confirmations(context) == 3
      assert elapsed >= 3_000, "gave up #{elapsed}ms into a 3s timeout"
    end

    test "still buys one attempt when there is no time to sleep in", context do
      stub_confirmations!(context, :never)

      # The clock is whole seconds, so a one-second deadline can be reached by
      # the first attempt. What has to hold is that an attempt is always made,
      # and that nothing waits longer than it was told to.
      {{output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "1") end)

      assert status == 1
      assert output =~ "1s after installing it"
      assert confirmations(context) >= 1
      assert elapsed < 5_000, "waited #{elapsed}ms for a 1s timeout"
    end

    test "asks once and gives up when it is zero", context do
      stub_confirmations!(context, :never)

      {{_output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "0") end)

      assert status == 1
      assert confirmations(context) == 1
      assert elapsed < 5_000, "waited #{elapsed}ms for a timeout of 0"
    end

    test "is refused before anything is installed", context do
      # Refusing it late would mean aborting after `Castle.install/1` had
      # already moved the system onto another release, with nothing left to
      # confirm that it had.
      for value <- ["soon", " 5", "86401", "99999999999999999999"] do
        stub_launcher!(context, "exit 0\n")
        File.rm(context.record)

        assert {output, status} = install(context, "0.1.1", value)

        assert status != 0, "accepted CASTLE_INSTALL_TIMEOUT=#{inspect(value)}"
        assert output =~ "CASTLE_INSTALL_TIMEOUT"
        refute recorded?(context), "delegated with CASTLE_INSTALL_TIMEOUT=#{inspect(value)}"
      end
    end

    test "is read as the decimal it looks like, however it is written", context do
      # Shell arithmetic reads 060 as octal 48, and refuses 08 outright - and it
      # is downstream of the install, so it would refuse it too late.
      for value <- ["08", "060", "86400"] do
        stub_launcher!(context, "exit 0\n")
        File.rm(context.record)

        assert {"", 0} = install(context, "0.1.1", value)
      end
    end

    test "is reported as that same decimal when it runs out", context do
      stub_confirmations!(context, :never)

      assert {output, 1} = install(context, "0.1.1", "01")
      assert output =~ "1s after installing it"
    end
  end

  describe "what install settles before installing anything" do
    # Anything able to stop the script belongs ahead of the launcher. Past it,
    # the system is on another release, and an abort says nothing about that
    # while leaving nobody to confirm it.

    test "refuses a clock that cannot tell it the time", context do
      # `date +%s` is not a conversion POSIX requires of date, and the deadline
      # is the first thing that needs it - which is downstream of the install.
      for answer <- ["exit 1", "echo not-a-number", "echo"] do
        stub_launcher!(context, "exit 0\n")
        File.rm(context.record)

        assert {output, status} =
                 castle(context, ["install", "0.1.1"], shimmed_date(context, answer))

        assert status != 0, "accepted a date that answers with: #{answer}"
        assert output =~ "date +%s"
        refute recorded?(context), "delegated with a date that answers with: #{answer}"
      end
    end

    test "refuses a RELEASE_TMP it cannot write in", context do
      stub_launcher!(context, "exit 0\n")

      # bin/castle is a file, so nothing can be created underneath it.
      assert {output, status} =
               castle(context, ["install", "0.1.1"], [
                 {"RELEASE_TMP", Path.join([context.root, "bin", "castle", "nowhere"])}
               ])

      assert status != 0
      assert output =~ "RELEASE_TMP"
      refute recorded?(context)
    end

    test "leaves nothing behind in RELEASE_TMP", context do
      tmp = Path.join(context.root, "scratch")
      stub_launcher!(context, "echo 'boom' >&2\nexit 3\n")

      assert {_output, 3} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])
      assert File.ls!(tmp) == []
    end

    test "captures into a directory nobody else can reach", context do
      tmp = Path.join(context.root, "scratch")
      File.mkdir_p!(tmp)

      stub_launcher!(context, """
      ls -ld "#{tmp}"/castle-install-* >> "#{context.root}/modes" 2>/dev/null
      exit 0
      """)

      assert {_output, 0} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])

      # RELEASE_TMP can be somewhere shared, so what install captures into is
      # the caller's alone from the moment it exists.
      assert File.read!(Path.join(context.root, "modes")) =~ ~r/^drwx------/
      assert File.ls!(tmp) == []
    end

    test "refuses a capture directory something else already owns", context do
      tmp = Path.join(context.root, "scratch")
      victim = Path.join(context.root, "victim")
      File.mkdir_p!(tmp)
      File.mkdir_p!(victim)
      File.write!(Path.join(victim, "keep"), "precious")

      stub_launcher!(context, "exit 0\n")

      # The preamble runs in the process that goes on to become bin/castle, so
      # its `$$` is the one bin/castle names the capture after: the symlink
      # lands exactly where bin/castle will look. Redirecting into that name
      # would write through it, into a directory chosen by whoever planted it.
      # Claiming it with mkdir cannot.
      assert {output, status} =
               castle_after(
                 context,
                 ~s(ln -s "#{victim}" "#{tmp}/castle-install-$$"),
                 ["install", "0.1.1"],
                 [{"RELEASE_TMP", tmp}]
               )

      assert status != 0
      assert output =~ "cannot claim"
      refute recorded?(context)
      assert File.ls!(victim) == ["keep"]
      assert File.read!(Path.join(victim, "keep")) == "precious"
    end

    test "gives two installs at once a capture each", context do
      tmp = Path.join(context.root, "scratch")
      seen = Path.join(context.root, "seen")
      File.mkdir_p!(tmp)

      stub_launcher!(context, """
      ls -d "#{tmp}"/castle-install-* >> "#{seen}" 2>/dev/null
      exit 0
      """)

      statuses =
        [1, 2]
        |> Task.async_stream(
          fn _ ->
            {_output, status} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])
            status
          end,
          max_concurrency: 2,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, status} -> status end)

      assert statuses == [0, 0]

      # Named after the process, so neither can claim what the other is using.
      assert seen |> File.read!() |> String.split("\n", trim: true) |> Enum.uniq() |> length() >=
               2

      assert File.ls!(tmp) == []
    end
  end

  describe "install's report of success" do
    # It is held until it is true. Printing what the install said on standard
    # output and only then failing to confirm would leave a success line on the
    # success stream for an install that had not taken effect - which is what
    # automation reads.

    test "goes to standard output, once, when the version is confirmed", context do
      stub_launcher!(context, """
      if [ ! -f "#{context.root}/installed" ]; then
        : > "#{context.root}/installed"
        echo 'Now running 0.1.1 (previously 0.1.0).'
      fi
      exit 0
      """)

      assert {out, err, 0} = castle_streams(context, ["install", "0.1.1"])
      assert occurrences(out, "Now running") == 1
      assert occurrences(err, "Now running") == 0
    end

    test "does not swallow what the launcher said while confirming", context do
      # A warning is worth no less for arriving as the upgrade is declared good.
      # Merging the confirmation's two streams and discarding them on success
      # lost it at exactly that moment.
      stub_launcher!(context, """
      if [ ! -f "#{context.root}/installed" ]; then
        : > "#{context.root}/installed"
        echo 'Now running 0.1.1 (previously 0.1.0).'
        exit 0
      fi
      echo 'warning: heard while confirming' >&2
      exit 0
      """)

      assert {out, err, 0} = castle_streams(context, ["install", "0.1.1"])

      assert occurrences(out, "Now running") == 1
      assert occurrences(out, "heard while confirming") == 0
      assert occurrences(err, "heard while confirming") == 1
    end

    test "leaves what the launcher wrote to standard error on standard error", context do
      # A merged capture cannot be unmerged, so on a confirmed install the
      # launcher's own standard error - the preboot integration's warnings, the
      # VM's complaints - used to come back out on standard output. A pipeline
      # alerting on one stream would never see it; one parsing the other would.
      stub_launcher!(context, """
      if [ ! -f "#{context.root}/installed" ]; then
        : > "#{context.root}/installed"
        echo 'Now running 0.1.1 (previously 0.1.0).'
        echo 'warning: something the VM wanted to mention' >&2
      fi
      exit 0
      """)

      assert {out, err, 0} = castle_streams(context, ["install", "0.1.1"])

      assert occurrences(out, "Now running") == 1
      assert occurrences(out, "warning: something") == 0
      assert occurrences(err, "warning: something") == 1
      assert occurrences(err, "Now running") == 0
    end

    test "goes to standard error when the version is never confirmed", context do
      stub_launcher!(context, """
      if [ -f "#{context.root}/installed" ]; then
        echo '** (Castle.Error) 0.1.1 is not the running release. 0.1.0 is.' >&2
        exit 1
      fi
      : > "#{context.root}/installed"
      echo 'Now running 0.1.1 (previously 0.1.0).'
      exit 0
      """)

      assert {out, err, 1} =
               castle_streams(context, ["install", "0.1.1"], [{"CASTLE_INSTALL_TIMEOUT", "1"}])

      assert occurrences(out, "Now running") == 0
      assert occurrences(err, "Now running") == 1
      assert err =~ "is not the running release, 1s after installing it"
    end

    test "stays on standard error when the node went away and came back", context do
      # The install can print its line and lose the connection immediately
      # afterwards; that is what a restart looks like. The line still settles
      # nothing until the confirmation, so it goes out as part of the account of
      # what happened rather than as the outcome.
      stub_launcher!(context, """
      if [ -f "#{context.root}/rebooted" ]; then exit 0; fi
      : > "#{context.root}/rebooted"
      echo 'Now running 0.1.1 (previously 0.1.0).'
      echo '--rpc-eval : RPC failed with reason :noconnection' >&2
      exit 1
      """)

      assert {out, err, 0} = castle_streams(context, ["install", "0.1.1"])
      assert occurrences(out, "Now running") == 0
      assert occurrences(err, "Now running") == 1
      assert occurrences(err, "noconnection") == 1
    end

    test "is absent from both streams when the install failed", context do
      stub_launcher!(context, """
      echo '** (Castle.Error) Install of 0.1.1 failed. {:no_such_release, 0.1.1}' >&2
      exit 1
      """)

      assert {out, err, 1} = castle_streams(context, ["install", "0.1.1"])
      assert out == ""
      assert occurrences(err, "Now running") == 0
      assert occurrences(err, "Install of 0.1.1 failed.") == 1
    end

    test "cannot be forged by a version that carries the disconnect diagnostic", context do
      # The launcher here fails the install and would confirm anything asked of
      # it afterwards, so a version able to pass itself off as a lost connection
      # would be installed, failed, confirmed and reported as a success. It does
      # not get that far: a version carrying a newline is refused outright.
      stub_launcher!(context, """
      if [ -f "#{context.root}/tried" ]; then exit 0; fi
      : > "#{context.root}/tried"
      printf '** (Castle.Error) Install of %s failed.\\n' "$2" >&2
      exit 3
      """)

      forged = "0.1.1\n--rpc-eval : RPC failed with reason :noconnection"

      assert {out, err, status} = castle_streams(context, ["install", forged])

      assert status != 0
      assert out == ""
      assert err =~ "is not a usable release version"
      refute recorded?(context)
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

    test "documents the timeout install waits for, and its default", context do
      assert {output, 0} = castle(context, [])
      assert output =~ "CASTLE_INSTALL_TIMEOUT"
      assert output =~ "300"
      assert output =~ "86400"
      # And that it bounds the asking rather than any single question, which is
      # what an operator wanting a hard limit needs to know.
      assert output =~ "not an individual question"
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
      "sub/dir",
      # A version is echoed back in the messages that report a failure to act on
      # it, so a newline lets it contribute a whole line of its own - here a
      # forgery of the launcher's disconnect diagnostic, which `install` reads
      # to decide whether a failure was really a reboot. With it, a failed
      # install of a version that happens to be the one running would be
      # confirmed and reported as a success.
      "0.1.1\n--rpc-eval : RPC failed with reason :noconnection",
      "1.2.3\t",
      "1.2.3\r"
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
        assert ["rpc", installing, "rpc", confirming] =
                 castle!(context, ["install", unquote(version)])

        # The real property is not the text of the expression but its meaning:
        # one call, to the function asked for, whose only argument is a literal
        # holding exactly this version. A single-element <<>> is what rules out
        # an interpolation having been introduced. Both calls are checked - the
        # confirmation interpolates the same version into the same kind of
        # sigil, so it is the same sink.
        for {expression, fun} <- [{installing, :install}, {confirming, :running}] do
          assert {{:., _, [{:__aliases__, _, [:Castle]}, ^fun]}, _,
                  [{:sigil_s, _, [{:<<>>, _, [unquote(version)]}, []]}]} =
                   Code.string_to_quoted!(expression)
        end
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

    calls(context)
  end

  defp install(context, vsn, timeout) do
    castle(context, ["install", vsn], [{"CASTLE_INSTALL_TIMEOUT", timeout}])
  end

  # The two streams kept apart, which the merged output of `castle/3` cannot
  # show: what bin/castle reports as the outcome has to be told from what it
  # reports on the way to one.
  defp castle_streams(context, args, env \\ []) do
    out = Path.join(context.root, "stdout")
    err = Path.join(context.root, "stderr")
    command = Enum.map_join([Path.join([context.root, "bin", "castle"]) | args], " ", &quoted/1)

    {_, status} =
      cmd("/bin/sh", ["-c", "#{command} > #{quoted(out)} 2> #{quoted(err)}"], env,
        cd: context.root
      )

    {File.read!(out), File.read!(err), status}
  end

  defp quoted(argument), do: "'" <> String.replace(argument, "'", "'\\''") <> "'"

  # Runs bin/castle with a shell preamble in front of it, in the same process:
  # `exec` replaces the shell without changing its process id, so the preamble
  # can act on the `$$` that bin/castle itself will see.
  defp castle_after(context, preamble, args, env) do
    launcher = Enum.map_join([Path.join([context.root, "bin", "castle"]) | args], " ", &quoted/1)

    cmd("/bin/sh", ["-c", preamble <> "\nexec " <> launcher], env, cd: context.root)
  end

  # An environment whose `date` answers with the given shell body, and whose
  # PATH is otherwise the caller's, so that everything else bin/castle runs is
  # found as usual.
  defp shimmed_date(context, body) do
    shims = Path.join(context.root, "shims")
    File.mkdir_p!(shims)
    File.write!(Path.join(shims, "date"), "#!/bin/sh\n#{body}\n")
    File.chmod!(Path.join(shims, "date"), 0o755)

    [{"PATH", shims <> ":" <> System.get_env("PATH")}]
  end

  defp occurrences(text, needle), do: length(String.split(text, needle)) - 1

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  # A launcher that answers the install, then fails every confirmation up to the
  # one numbered `confirms_on` - or all of them, for `:never`.
  defp stub_confirmations!(context, confirms_on) do
    succeeds_on = if confirms_on == :never, do: 0, else: confirms_on + 1

    stub_launcher!(context, """
    n=$(cat "#{context.root}/n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "#{context.root}/n"
    if [ "$n" -eq 1 ] || [ "$n" -eq #{succeeds_on} ]; then exit 0; fi
    exit 1
    """)
  end

  defp confirmations(context) do
    Enum.count(calls(context), &String.starts_with?(&1, "Castle.running("))
  end

  # Every argument of every call the launcher stub was handed, in order.
  defp calls(context) do
    case File.read(context.record) do
      {:ok, recorded} -> String.split(recorded, <<0>>, trim: true)
      {:error, :enoent} -> []
    end
  end

  # Replaces the recording stub with one that behaves like a system in a
  # particular state. The recording is kept: what was called still matters.
  defp stub_launcher!(context, body) do
    stub = Path.join([context.root, "bin", "sample"])

    File.write!(
      stub,
      ~s(#!/bin/sh\nprintf '%s\\0' "$@" >> "#{context.record}"\n) <> body
    )

    File.chmod!(stub, 0o755)
  end

  defp recorded?(context), do: File.exists?(context.record)
end
