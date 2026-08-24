defmodule Forecastle.CastleCliTest do
  @moduledoc """
  Exercises the generated `bin/castle` as a shell script.

  The release launcher is replaced with a stub that records the arguments it was
  handed, so these tests pin down exactly what `bin/castle` delegates without
  needing a running system. Every call appends to the same record, so a command
  that reaches the launcher more than once - `install`, which confirms what it
  installed - reads back as one flat list of arguments in the order they were
  passed. What the system refuses is Castle's to refuse, from inside the call
  that acts, so a stub that answers a command non-zero is how a refusal is
  simulated here.

  Replacing that stub is also the only way to simulate a transition that
  restarts the emulator: nothing can build a relup that asks for one until #4,
  so the end-to-end suite cannot produce it.
  """

  use Forecastle.ReleaseCase

  @commit_done_signal "__CASTLE_COMMIT_DONE_V2__"
  @nothing_to_commit_signal "__CASTLE_NOTHING_TO_COMMIT_V2__"

  # An upper bound on how long a command driven by the launcher stub may take.
  # Deliberately far above anything a real run needs: it says "this waited when
  # it should have stopped", not "this took exactly so long", and a loaded
  # runner must not trip it. It can only report a command that finished late -
  # one that never finishes is ExUnit's own test timeout to catch, since nothing
  # here interrupts a `System.cmd/3` in flight.
  @runaway 60_000

  setup_all do
    release = assemble!(into: "rel-forecastle")
    {:ok, release: release}
  end

  setup %{release: release} do
    # The operating system pid as well as a unique integer, and the root removed
    # before it is created as well as after.
    #
    # `System.unique_integer/1` is unique within a *VM run* and no further than
    # that: a fresh VM starts its counter at very nearly the same place as the
    # last one - measured, three consecutive runs handing out 2690, 2693 and
    # 2694 - so the names recur across runs. And `File.mkdir_p!/1` succeeds on a
    # directory that is already there. So a run killed part-way - a timeout, a
    # signal, an interrupted matrix cell - leaves its `argv` behind, and a later
    # run's `setup` can adopt it. Eleven assertions in this file read
    # `File.exists?(record)` to say the launcher was *not* reached, and a stale
    # file answers yes.
    #
    # It does not reproduce on demand, because it needs the earlier run to have
    # died *and* the counter to land on the same value - which is what makes it
    # worth removing by construction rather than chasing.
    #
    # `on_exit` cannot cover this, since the case being defended against is
    # precisely the one where `on_exit` did not run. The `rm_rf!` is what makes
    # the directory this run's own; the pid is what stops two VMs running at once
    # from choosing the same name and deleting each other's.
    root =
      Path.join(
        System.tmp_dir!(),
        "castle-cli-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    File.rm_rf!(root)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(Path.join(release, "bin/castle"), Path.join(bin, "castle"))
    File.chmod!(Path.join(bin, "castle"), 0o755)

    record = Path.join(root, "argv")
    stub = Path.join(bin, "sample")

    write_stub!(stub, record, ~s(printf '%s' "$CASTLE_STUB_OUTPUT"\n))

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

    test "upgradable", context do
      assert castle!(context, ["upgradable"]) == ["rpc", "Castle.upgradable()"]
    end

    test "commit with an explicit version", context do
      assert castle!(context, ["commit", "0.1.1"]) == ["rpc", "Castle.commit(~s(0.1.1))"]
    end

    test "remove", context do
      assert castle!(context, ["remove", "0.1.1"]) == ["rpc", "Castle.remove(~s(0.1.1))"]
    end
  end

  describe "a system that cannot be upgraded from" do
    # release_handler reads releases/RELEASES once, in its init, and when the
    # file is missing - or cannot be read - it works from a record it builds out
    # of the boot script's name and version, which names no applications.
    # Upgrading from that leaves any application whose version moved, but whose
    # code the relup does not load, running from the release being replaced.
    #
    # Castle refuses `unpack` and `install` for it, from inside the call that
    # acts. Nothing here asks first: two rpcs are two moments and possibly two
    # node instances, so a node could answer on the record it read at boot,
    # restart onto a synthesised one, and have the operation arrive afterwards
    # and act on an answer that no longer held. What bin/castle owes an operator
    # is the refusal, its remedy, and a non-zero status.

    test "is asked about by nothing but the command for asking", context do
      for args <- [
            ["unpack", "0.1.1"],
            ["install", "0.1.1"],
            ["commit", "0.1.1"],
            ["remove", "0.1.1"],
            ["releases"]
          ] do
        File.rm(context.record)

        refute Enum.any?(castle!(context, args), &(&1 =~ "Castle.upgradable")),
               "#{hd(args)} asked whether the system could be upgraded first"
      end
    end

    test "refuses the unpack, in the words the system refused it with", context do
      refuses!(context, "unpack sample-0.1.1")

      assert {output, status} = castle(context, ["unpack", "0.1.1"])

      assert status != 0
      # Castle's message, passed through rather than paraphrased: it leads with
      # the operation that did not happen and it names the remedy, which is a
      # restart, because that is the only thing that changes the record.
      assert output =~ "Cannot unpack sample-0.1.1"
      assert output =~ "Restart the system"
      # It came back from the unpack itself. Nothing was asked beforehand.
      assert calls(context) == ["rpc", "Castle.unpack(~s(sample-0.1.1))"]
    end

    test "refuses the install, and reports it as the failure it is", context do
      refuses!(context, "install 0.1.1")

      assert {out, err, status} = castle_streams(context, ["install", "0.1.1"])

      assert status != 0
      assert out == ""
      assert err =~ "Cannot install 0.1.1"
      assert err =~ "Restart the system"
      # A refusal is final, so it is reported in full and nothing is left in
      # doubt for the epilogue to raise - and there is nothing to wait for: the
      # system said no, and polling would only delay the report.
      refute err =~ "outcome is not known"
      assert calls(context) == ["rpc", "Castle.install(~s(0.1.1))"]
    end

    test "leaves nothing behind in RELEASE_TMP when the install is refused", context do
      # The refusal arrives after install has claimed somewhere to capture what
      # the launcher says, so the capture still has to be tidied up on the way
      # out.
      tmp = Path.join(context.root, "scratch")
      refuses!(context, "install 0.1.1")

      assert {_output, status} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])

      assert status != 0
      assert File.ls!(tmp) == []
    end

    test "does not have bin/castle create the file instead", context do
      # It cannot be created usefully from here: the record is read at boot, and
      # the first operation that changes anything writes that record straight
      # back over the file. The release's env.sh creates it before the system
      # starts, and nowhere else.
      for args <- [
            ["unpack", "0.1.1"],
            ["install", "0.1.1"],
            ["commit", "0.1.1"],
            ["remove", "0.1.1"],
            ["releases"],
            ["upgradable"]
          ] do
        File.rm(context.record)

        refute Enum.any?(castle!(context, args), &(&1 =~ "make_releases")),
               "#{hd(args)} tried to create the RELEASES file"
      end
    end
  end

  describe "commit without a version" do
    test "resolves the release awaiting commit, not whatever is running", context do
      # `:current` and "running" are not the same set, which is what this test's
      # name used to imply and what the usage text used to say outright. A system
      # with only a permanent release *is* running one and has no `:current`, so
      # the argumentless form has nothing to commit there and says so rather than
      # committing the release it is already on. The assertion was always about
      # `:current`; only the name was wrong.
      stub_commit!(context, :done)
      assert ["rpc", expression] = castle!(context, ["commit"])

      assert expression =~ ":release_handler.which_releases(:current)"
      assert expression =~ ":ok = Castle.commit(to_string(vsn))"
      assert expression =~ @commit_done_signal
      assert expression =~ @nothing_to_commit_signal
    end

    test "keeps the human diagnostic out of the remote protocol", context do
      stub_commit!(context, :done)
      assert ["rpc", expression] = castle!(context, ["commit"])

      refute expression =~ "No release is awaiting commit"
    end

    test "exits non-zero when there was nothing to commit", context do
      # Whatever asked for a commit has to be able to tell that none happened.
      stub_commit!(context, :nothing)
      assert {output, status} = castle(context, ["commit"])

      assert status == 1
      assert output == "No release is awaiting commit. Pass a version explicitly.\n"
      refute output =~ @nothing_to_commit_signal
    end

    test "preserves output before the exact no-commit record", context do
      noise = "warning: the node reported ordinary output"
      stub_commit!(context, :nothing, noise)

      assert {output, 1} = castle(context, ["commit"])

      assert output ==
               noise <> "\nNo release is awaiting commit. Pass a version explicitly.\n"
    end

    test "exits zero, and reports, when a commit happened", context do
      report = "Committed 0.1.1. System restarts will now boot into this version."
      stub_commit!(context, :done, report)

      assert {output, 0} = castle(context, ["commit"])

      assert output == report <> "\n"
      refute output =~ @commit_done_signal
    end

    test "preserves launcher output after a successful commit record", context do
      stub_commit!(context, :done, "commit report", "launcher warning")

      assert {"commit report\nlauncher warning\n", 0} = castle(context, ["commit"])
    end

    test "preserves launcher output after a no-commit record", context do
      stub_commit!(context, :nothing, "before", "after")

      assert {output, 1} = castle(context, ["commit"])

      assert output ==
               "before\nafter\nNo release is awaiting commit. Pass a version explicitly.\n"
    end

    test "a done record wins over a non-zero launcher status", context do
      stub_commit_with_status!(
        context,
        :done,
        7,
        "commit report",
        "trailing launcher output",
        "--rpc-eval : RPC failed with reason :noconnection"
      )

      assert {out, err, 0} = castle_streams(context, ["commit"])
      assert out == "commit report\n"

      assert err ==
               "--rpc-eval : RPC failed with reason :noconnection\n" <>
                 "trailing launcher output\n" <>
                 "WARNING: commit succeeded, but the launcher exited with status 7 after " <>
                 "reporting the result.\n"

      refute out =~ @commit_done_signal
      refute err =~ @commit_done_signal
    end

    test "a no-current record wins over a non-zero launcher status", context do
      stub_commit_with_status!(context, :nothing, 6, "", "launcher warning", "")

      assert {out, err, 1} = castle_streams(context, ["commit"])
      assert out == "No release is awaiting commit. Pass a version explicitly.\n"

      assert err ==
               "launcher warning\n" <>
                 "WARNING: no release was committed; the launcher exited with status 6 after " <>
                 "reporting the result.\n"

      refute out =~ @nothing_to_commit_signal
      refute err =~ @nothing_to_commit_signal
    end

    test "does not confuse ordinary token text or an earlier exact record with the result",
         context do
      ordinary =
        "Castle printed #{@nothing_to_commit_signal}:not-this-run and #{@commit_done_signal}"

      # The selected record carries the shell invocation's tag. Even an exact
      # record for a different invocation remains ordinary output.
      stub_commit!(
        context,
        :done,
        ordinary <> "\n#{@nothing_to_commit_signal}:999999"
      )

      assert {output, 0} = castle(context, ["commit"])

      assert output == ordinary <> "\n#{@nothing_to_commit_signal}:999999\n"
    end

    test "the expression's later record wins over an earlier exact record", context do
      stub_launcher!(context, """
      done=$(printf '%s\n' "$2" | sed -n 's/.*~s(\\(#{@commit_done_signal}:[0-9][0-9]*\\)).*/\\1/p')
      nothing=$(printf '%s\n' "$2" | sed -n 's/.*~s(\\(#{@nothing_to_commit_signal}:[0-9][0-9]*\\)).*/\\1/p')
      printf '%s\nordinary output\n%s\n' "$nothing" "$done"
      """)

      assert {output, 0} = castle(context, ["commit"])
      assert [earlier, "ordinary output", ""] = String.split(output, "\n")
      assert earlier =~ ~r/^#{@nothing_to_commit_signal}:[0-9]+$/
    end

    test "rejects a successful launcher response without a protocol record", context do
      assert {out, err, 1} =
               castle_streams(context, ["commit"], [
                 {"CASTLE_STUB_OUTPUT", "ordinary output only"}
               ])

      assert out == ""

      assert err ==
               "ordinary output only\n" <>
                 "ERROR: commit returned no recognised result; it may or may not be permanent. " <>
                 "Run bin/castle releases to inspect release state.\n"
    end

    test "preserves a successful result when ordinary-output filtering fails", context do
      stub_commit!(context, :done, "commit report")

      assert {out, err, 0} =
               castle_streams(context, ["commit"], failing_nth_tool(context, "awk", 2))

      assert out == ""
      assert err == "WARNING: commit succeeded, but its ordinary output could not be displayed.\n"
      refute err =~ @commit_done_signal
      refute err =~ @nothing_to_commit_signal
    end

    test "preserves an empty result when ordinary-output filtering fails", context do
      stub_commit!(context, :nothing, "launcher warning")

      assert {out, err, 1} =
               castle_streams(context, ["commit"], failing_nth_tool(context, "awk", 2))

      assert out == "No release is awaiting commit. Pass a version explicitly.\n"

      assert err ==
               "WARNING: no release was committed, and ordinary command output could not be displayed.\n"

      refute err =~ @commit_done_signal
      refute err =~ @nothing_to_commit_signal
    end

    test "does not replay a record when the protocol parser fails", context do
      stub_commit_with_status!(context, :done, 5, "commit report", "", "")

      assert {out, err, 5} =
               castle_streams(context, ["commit"], failing_nth_tool(context, "awk", 1))

      assert out == ""

      assert err ==
               "ERROR: commit result could not be read safely; it may or may not be permanent. " <>
                 "Run bin/castle releases to inspect release state.\n"

      refute err =~ @commit_done_signal
      refute err =~ @nothing_to_commit_signal
    end

    test "routes a failing launcher's captured output to standard error", context do
      stub_launcher!(context, """
      printf '%s\n' 'rpc stdout'
      printf '%s\n' 'rpc stderr' >&2
      exit 3
      """)

      assert {out, err, 3} = castle_streams(context, ["commit"])
      assert out == ""
      assert err == "rpc stderr\nrpc stdout\n"
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

    test "requires the launcher disconnect diagnostic to occupy the whole line", context do
      stub_launcher!(context, """
      if [ -f "#{context.root}/tried" ]; then exit 0; fi
      : > "#{context.root}/tried"
      echo '--rpc-eval : RPC failed with reason :noconnection (quoted by an operator message)' >&2
      exit 3
      """)

      assert {output, 3} = castle(context, ["install", "0.1.1"])
      assert output =~ "quoted by an operator message"
      assert calls(context) == ["rpc", "Castle.install(~s(0.1.1))"]
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

    test "does not echo control bytes from an invalid timeout", context do
      hostile = "soon\nforged\r\e[31m\a"

      assert {"", err, status} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", hostile}
               ])

      assert status != 0

      assert err ==
               "ERROR: CASTLE_INSTALL_TIMEOUT must be a whole number of seconds, " <>
                 "got: soon%0Aforged%0D%1B[31m%07\n"

      refute recorded?(context)
    end

    test "keeps a non-ASCII RELEASE_TMP identifiable when it cannot be created", context do
      blocker = Path.join(context.root, "blocked")
      File.write!(blocker, "not a directory")
      tmp = Path.join(blocker, "café")

      assert {"", err, status} =
               castle_streams(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])

      assert status != 0
      assert err =~ String.replace(tmp, "é", "%C3%A9")
      assert err =~ "set RELEASE_TMP somewhere writable"
      refute recorded?(context)
    end
  end

  describe "the timeout install waits for" do
    # It is a deadline in elapsed time, not a count of attempts: the operator
    # gave seconds, and the time each attempt takes has to count against them
    # as much as the sleeps do.
    #
    # Which is why nothing here asserts how many attempts fit inside one. That
    # is a property of how fast the machine is - the same three seconds buy
    # three attempts on an idle laptop and two on a loaded runner - and neither
    # number is promised. What is promised is that it keeps asking rather than
    # giving up at the first refusal, that it stops, and that it spends the
    # number of seconds it was given rather than a rounded-off version of it.

    test "keeps asking rather than giving up at the first refusal", context do
      # Two seconds used to buy exactly one attempt, made immediately, so a
      # confirmation that needed a second one never got it. Asked here with room
      # to spare, so that a slow machine cannot be the reason it did or did not
      # ask again.
      stub_confirmations!(context, 2)

      assert {_output, 0} = install(context, "0.1.1", "60")
      assert confirmations(context) >= 2
    end

    test "is spent as the number given, not rounded to how often it looks", context do
      stub_confirmations!(context, :never)

      # Three seconds is not a multiple of the two between attempts, so the last
      # wait has to be a short one - the only path that sleeps for less than the
      # interval. What it reports is the three seconds it was asked for.
      {{output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "3") end)

      assert status == 1
      assert output =~ "3s after installing it"
      assert elapsed < @runaway, "a 3s timeout took #{elapsed}ms"
    end

    test "still asks once when there is no time to sleep in", context do
      stub_confirmations!(context, :never)

      # The clock is whole seconds, so a one-second deadline can be reached by
      # the first attempt. What has to hold is that an attempt is made at all.
      {{output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "1") end)

      assert status == 1
      assert output =~ "1s after installing it"
      assert confirmations(context) >= 1
      assert elapsed < @runaway, "a 1s timeout took #{elapsed}ms"
    end

    test "asks once and gives up when it is zero", context do
      stub_confirmations!(context, :never)

      # The one count worth asserting, because nothing about it depends on how
      # long anything took: with no time at all the first attempt is also the
      # last, and time only moves forwards, so the deadline is already past
      # whenever it is next looked at.
      {{_output, status}, elapsed} = timed(fn -> install(context, "0.1.1", "0") end)

      assert status == 1
      assert confirmations(context) == 1
      assert elapsed < @runaway, "a timeout of 0 took #{elapsed}ms"
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

    test "refuses a RELEASE_TMP anyone may write to unless it is sticky", context do
      # Claiming the name settles who created the directory, not who may rename
      # it afterwards: that is the parent's business. Where anyone may write and
      # the sticky bit is not set, another user can move the directory aside and
      # leave a symlink behind it, and mode 0700 on something no longer there
      # protects nothing. So the parent is refused rather than the race narrowed.
      tmp = Path.join(context.root, "shared")
      File.mkdir_p!(tmp)
      File.chmod!(tmp, 0o777)

      stub_launcher!(context, "exit 0\n")

      assert {output, status} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])

      assert status != 0
      assert output =~ "can be written by anyone and is not sticky"
      assert output =~ "chmod +t"
      refute recorded?(context)
      assert File.ls!(tmp) == []
    end

    test "accepts one anyone may write to when it is sticky", context do
      # Which is to say: /tmp. The sticky bit is what makes a shared directory
      # usable, and refusing it would condemn the most ordinary setting there is.
      tmp = Path.join(context.root, "shared-sticky")
      File.mkdir_p!(tmp)

      # Through chmod(1): File.chmod/2 keeps only the permission bits, so it
      # cannot set this one, and a fixture that quietly came out non-sticky
      # would be testing the opposite of what it says.
      {_, 0} = System.cmd("chmod", ["1777", tmp])
      assert File.stat!(tmp).mode |> Integer.to_string(8) |> String.ends_with?("1777")

      stub_launcher!(context, "exit 0\n")

      assert {"", 0} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])
      assert File.ls!(tmp) == []
    end

    test "accepts one that is nobody else's business", context do
      tmp = Path.join(context.root, "own")
      File.mkdir_p!(tmp)
      File.chmod!(tmp, 0o700)

      stub_launcher!(context, "exit 0\n")

      assert {"", 0} = castle(context, ["install", "0.1.1"], [{"RELEASE_TMP", tmp}])
      assert File.ls!(tmp) == []
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
          timeout: @runaway
        )
        |> Enum.map(fn {:ok, status} -> status end)

      assert statuses == [0, 0]

      # Named after the process, so neither can claim what the other is using.
      assert seen |> File.read!() |> String.split("\n", trim: true) |> Enum.uniq() |> length() >=
               2

      assert File.ls!(tmp) == []
    end
  end

  describe "when something stops install after the install has run" do
    # The preflight settles what it can, but the deadline has to be taken after
    # the install - anchoring it earlier would let a slow install eat the window
    # meant for confirming it - so the clock is asked again where a failure can
    # no longer be moved out of the way. Whatever stops the script from here on
    # still has to say that an install happened, or the operator is left with a
    # diagnostic about the clock and no idea their system moved.

    test "says the install happened when the clock fails on the deadline", context do
      stub_launcher!(context, install_then_refuse(context))

      # The second reading is the deadline anchor, taken once the install is
      # already done. The first, in the preflight, still answers.
      assert {out, err, status} =
               castle_streams(context, ["install", "0.1.1"], failing_date(context, 2))

      assert status != 0
      assert out == ""
      # What the install said, and that nothing confirmed it.
      assert occurrences(err, "Now running 0.1.1") == 1
      assert err =~ "outcome is not known"
      assert err =~ "bin/castle releases"
      # Not only the clock's own complaint, which was the whole defect.
      assert err =~ "date +%s"
    end

    test "says it again when the clock fails between attempts", context do
      stub_launcher!(context, install_then_refuse(context))

      # The third reading is inside the polling loop, a distinct path from the
      # anchor above.
      assert {out, err, status} =
               castle_streams(context, ["install", "0.1.1"], failing_date(context, 3))

      assert status != 0
      assert out == ""
      assert occurrences(err, "Now running 0.1.1") == 1
      assert err =~ "outcome is not known"
      assert err =~ "bin/castle releases"
    end

    test "says nothing extra when a terminal path has already spoken", context do
      # The timeout reports the held output itself, so the epilogue must not
      # repeat it, and an install that simply failed has no outcome in doubt.
      stub_launcher!(context, install_then_refuse(context))

      assert {_out, err, 1} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", "1"}
               ])

      assert occurrences(err, "Now running 0.1.1") == 1
      assert occurrences(err, "is not the running release, 1s") == 1
      refute err =~ "outcome is not known"

      stub_launcher!(context, "echo '** (Castle.Error) Install of 0.1.1 failed.' >&2\nexit 3\n")

      assert {_out, failed, 3} = castle_streams(context, ["install", "0.1.1"])
      refute failed =~ "outcome is not known"
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

    test "does not swallow what an attempt on the way there said either", context do
      # An attempt that fails is not the last word, but it is the only chance to
      # pass on anything it said: the next one truncates the capture. This one
      # says something worth hearing alongside the ordinary diagnostic, and a
      # later attempt confirms - so it used to be lost entirely.
      stub_launcher!(context, """
      n=$(cat "#{context.root}/n" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > "#{context.root}/n"
      case $n in
        1) echo 'Now running 0.1.1 (previously 0.1.0).'; exit 0 ;;
        2) echo 'warning: a disk is filling up' >&2
           echo '--rpc-eval : RPC failed with reason :noconnection' >&2
           exit 1 ;;
        *) exit 0 ;;
      esac
      """)

      assert {out, err, 0} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", "60"}
               ])

      assert occurrences(out, "Now running") == 1
      assert occurrences(err, "a disk is filling up") == 1
      # Selectively, though: the diagnostic that came with it is the sound of a
      # node that is not back yet, and is not news between attempts.
      assert occurrences(err, "RPC failed with reason :noconnection") == 0
    end

    test "does not filter prose that quotes the disconnect diagnostic", context do
      quoted =
        "--rpc-eval : RPC failed with reason :noconnection (quoted by an operator message)"

      stub_launcher!(context, """
      n=$(cat "#{context.root}/n" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > "#{context.root}/n"
      case $n in
        1) echo 'Now running 0.1.1 (previously 0.1.0).'; exit 0 ;;
        2) echo '#{quoted}' >&2; exit 1 ;;
        *) exit 0 ;;
      esac
      """)

      assert {_out, err, 0} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", "60"}
               ])

      assert err =~ quoted
    end

    test "does not repeat the expected diagnostic once per attempt", context do
      # Every couple of seconds for the length of the wait, which is what
      # replaying each attempt unconditionally would mean, buries anything that
      # matters under the one line that never does.
      stub_launcher!(context, """
      n=$(cat "#{context.root}/n" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > "#{context.root}/n"
      case $n in
        1) echo 'Now running 0.1.1 (previously 0.1.0).'; exit 0 ;;
        2|3) echo '--rpc-eval : RPC failed with reason :noconnection' >&2; exit 1 ;;
        *) exit 0 ;;
      esac
      """)

      assert {out, err, 0} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", "60"}
               ])

      assert occurrences(out, "Now running") == 1
      assert occurrences(err, "RPC failed with reason :noconnection") == 0
    end

    test "keeps the expected diagnostic when it is the last thing seen", context do
      # Between attempts it is noise; as the last thing before giving up it is
      # the finding, and tells "never came back" from "came back running
      # something else". One attempt is intermediate here and one is final, so
      # exactly one copy is both halves of that.
      stub_launcher!(context, """
      if [ -f "#{context.root}/installed" ]; then
        echo '--rpc-eval : RPC failed with reason :noconnection' >&2
        exit 1
      fi
      : > "#{context.root}/installed"
      echo 'Now running 0.1.1 (previously 0.1.0).'
      exit 0
      """)

      assert {out, err, 1} =
               castle_streams(context, ["install", "0.1.1"], [
                 {"CASTLE_INSTALL_TIMEOUT", "1"}
               ])

      assert out == ""
      assert occurrences(err, "RPC failed with reason :noconnection") == 1
      assert occurrences(err, "Now running") == 1
      assert err =~ "is not the running release, 1s after installing it"
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
      assert err =~ "install cannot use release version [0.1.1%0A--rpc-eval"
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
      assert output =~ "With no VSN, commits the release awaiting commit"
      assert output =~ "when there is none"
    end

    test "documents upgradable, and that the operations ask it for themselves", context do
      # An operator who meets the refusal needs to know both halves: that the
      # question can be asked on its own, and that a silent answer is the good
      # one - and that asking it first is not a step they are missing.
      assert {output, 0} = castle(context, [])

      assert output =~ ~r/upgradable\s+Asks whether the system can be upgraded from/
      assert output =~ "saying nothing if it can"
      assert output =~ "ask that same question themselves"
      assert output =~ "cannot upgrade from that state"
      assert output =~ "If the release root should be writable"
    end

    test "describes OTP's fallback release record accurately", context do
      assert {output, 0} = castle(context, [])

      assert output =~ ~r/OTP is\s+using a fallback release record/
      assert output =~ "instead of one loaded from releases/RELEASES"
      assert output =~ ~r/read-only deployment can run and\s+restart/
      assert output =~ "cannot take an upgrade"
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

    test "does not echo control bytes from the timeout in help", context do
      hostile = "300\nforged\r\e[31m\a"

      assert {out, err, 0} =
               castle_streams(context, [], [{"CASTLE_INSTALL_TIMEOUT", hostile}])

      assert out == ""
      assert err =~ "(300%0Aforged%0D%1B[31m%07, at most 86400)"
      refute err =~ "\r"
      refute err =~ "\e"
      refute err =~ "\a"
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
          assert output =~ "ERROR: #{command} cannot use release version ["
          refute recorded?(context), "#{command} delegated #{inspect(unquote(version))}"
        end
      end
    end

    test "rejected control bytes are represented without reaching the terminal", context do
      controls = [
        {"\n", "%0A"},
        {"\r", "%0D"},
        {"\t", "%09"},
        {"\e", "%1B"},
        {"\a", "%07"},
        {<<0xC2, 0x9B>>, "%C2%9B"}
      ]

      for {control, encoded} <- controls do
        version = "0.1.1#{control}forged"

        assert {"", err, status} = castle_streams(context, ["install", version])

        assert status != 0
        assert err == "ERROR: install cannot use release version [0.1.1#{encoded}forged]\n"
        refute recorded?(context)
      end
    end

    test "rejects malformed UTF-8 and renders its bytes safely", context do
      malformed = [
        {<<0x7F>>, "%7F"},
        {<<0x80>>, "%80"},
        {<<0xC0, 0xAF>>, "%C0%AF"},
        {<<0xE0, 0x80, 0xAF>>, "%E0%80%AF"},
        {<<0xED, 0xA0, 0x80>>, "%ED%A0%80"},
        {<<0xF4, 0x90, 0x80, 0x80>>, "%F4%90%80%80"},
        {<<0xE2, 0x82>>, "%E2%82"}
      ]

      for {bytes, encoded} <- malformed do
        version = "1.2.3-" <> bytes

        assert {output, status} = castle(context, ["remove", version])
        assert status != 0
        assert output == "ERROR: remove cannot use release version [1.2.3-#{encoded}]\n"
        refute recorded?(context)
      end
    end

    test "validator-tool failures refuse versions with an actionable diagnostic", context do
      for tool <- ["od", "awk"] do
        File.rm(context.record)
        env = failing_tool(context, tool)

        assert {"", err, status} =
                 castle_streams(context, ["install", "1.2.3-café"], env)

        assert status != 0

        assert err ==
                 "ERROR: install cannot validate release version [<unprintable>]; " <>
                   "release-version validation is unavailable. Check od and awk.\n"

        refute recorded?(context)
      end
    end

    test "uses the safe value when display remains available after validation fails", context do
      env = failing_nth_tool(context, "awk", 1)

      assert {"", err, status} =
               castle_streams(context, ["remove", "1.2.3-café"], env)

      assert status != 0

      assert err ==
               "ERROR: remove cannot validate release version [1.2.3-caf%C3%A9]; " <>
                 "release-version validation is unavailable. Check od and awk.\n"

      refute recorded?(context)
    end

    test "the separator codepoints a control class over-matches are still versions",
         context do
      # U+2028 and U+2029 are permitted by the contract - valid UTF-8, outside
      # C0, DEL and C1 - and they are the codepoints that make a `[[:cntrl:]]`
      # shortcut unsafe: glibc's tables put both in that class, so a bash in a
      # UTF-8 locale would refuse these while dash accepted them, and which
      # releases could be managed would come down to the locale the deployment
      # inherited. The validator's shortcut is a literal C0/DEL byte set for that
      # reason, and the decoder behind it is bytewise.
      #
      # Asserted by comparing the delegated arguments directly rather than
      # through `Code.string_to_quoted!/1` like the list above: these two are
      # exactly the characters Elixir's parser warns about seeing raw, and the
      # claim here is about the bytes surviving, not about the expression's
      # shape.
      for version <- ["1.2.3-a\u2028b", "1.2.3-a\u2029b"] do
        File.rm(context.record)

        assert castle!(context, ["install", version]) == [
                 "rpc",
                 "Castle.install(~s(#{version}))",
                 "rpc",
                 "Castle.running(~s(#{version}))"
               ]
      end
    end

    test "literal echo escape spellings stay literal in rejected versions", context do
      for suffix <- [~S(\nforged), ~S(\0033[31mforged), ~S(\cforged)] do
        version = "0.1.1#{suffix}"

        assert {"", err, status} = castle_streams(context, ["remove", version])

        assert status != 0
        assert err == "ERROR: remove cannot use release version [#{version}]\n"
        refute err =~ "\e"
        refute recorded?(context)
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
      "1.2.3-café",
      "1.2.3-雪",
      "1.2.3-🦀",
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

  # A launcher that installs once, reporting as it goes, and refuses every
  # confirmation afterwards - so what happens next is decided by whatever else
  # goes wrong.
  defp install_then_refuse(context) do
    """
    if [ -f "#{context.root}/installed" ]; then exit 1; fi
    : > "#{context.root}/installed"
    echo 'Now running 0.1.1 (previously 0.1.0).'
    exit 0
    """
  end

  # An environment whose `date` answers until its nth invocation and fails from
  # then on, so that a clock which satisfied the preflight can still fail where
  # nothing can be moved out of the way.
  defp failing_date(context, nth) do
    shimmed_date(context, """
    n=$(cat "#{context.root}/dates" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "#{context.root}/dates"
    if [ "$n" -ge #{nth} ]; then exit 1; fi
    exec #{System.find_executable("date")} "$@"
    """)
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

  defp failing_tool(context, tool) do
    shims = Path.join(context.root, "failing-#{tool}")
    File.mkdir_p!(shims)
    File.write!(Path.join(shims, tool), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(shims, tool), 0o755)

    [{"PATH", shims <> ":" <> System.get_env("PATH")}]
  end

  defp failing_nth_tool(context, tool, nth) do
    shims = Path.join(context.root, "failing-#{tool}-#{nth}")
    count = Path.join(shims, "count")
    File.mkdir_p!(shims)

    File.write!(Path.join(shims, tool), """
    #!/bin/sh
    n=$(sed -n '1p' #{quoted(count)} 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s\n' "$n" > #{quoted(count)}
    if [ "$n" -eq #{nth} ]; then exit 1; fi
    exec #{quoted(System.find_executable(tool))} "$@"
    """)

    File.chmod!(Path.join(shims, tool), 0o755)
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
    write_stub!(Path.join([context.root, "bin", "sample"]), context.record, body)
  end

  # The record includes bin/castle's process id, so a protocol-aware launcher
  # stub extracts the record embedded in the RPC expression instead of guessing
  # it. This also keeps the tests honest about the per-invocation boundary.
  defp stub_commit!(context, result, before \\ "", trailing \\ "") do
    prefix =
      case result do
        :done -> @commit_done_signal
        :nothing -> @nothing_to_commit_signal
      end

    stub_launcher!(context, """
    record=$(printf '%s\n' "$2" | sed -n 's/.*~s(\\(#{prefix}:[0-9][0-9]*\\)).*/\\1/p')
    printf '%s' #{quoted(before)}
    printf '\n%s\n' "$record"
    printf '%s' #{quoted(trailing)}
    """)
  end

  defp stub_commit_with_status!(
         context,
         result,
         status,
         before,
         trailing,
         stderr
       ) do
    prefix =
      case result do
        :done -> @commit_done_signal
        :nothing -> @nothing_to_commit_signal
      end

    stub_launcher!(context, """
    record=$(printf '%s\n' "$2" | sed -n 's/.*~s(\\(#{prefix}:[0-9][0-9]*\\)).*/\\1/p')
    printf '%s' #{quoted(before)}
    printf '\n%s\n' "$record"
    printf '%s' #{quoted(trailing)}
    if [ -n #{quoted(stderr)} ]; then printf '%s\n' #{quoted(stderr)} >&2; fi
    exit #{status}
    """)
  end

  # Writes a launcher stub: it records every call it is handed, and then runs
  # `body`.
  defp write_stub!(stub, record, body) do
    File.write!(stub, """
    #!/bin/sh
    printf '%s\\0' "$@" >> "#{record}"
    #{body}
    """)

    File.chmod!(stub, 0o755)
  end

  # A launcher whose system refuses the operation for the release record it is
  # running from, the way Castle refuses it from inside the call that acts. The
  # message leads with the operation that did not happen, abridged from
  # Castle.Commands.ensure_upgradable/2, and names the remedy - the part nothing
  # else can supply.
  defp refuses!(context, operation) do
    stub_launcher!(context, """
    echo '** (Castle.Error) Cannot #{operation}: 0.1.0 is running from a release' \\
         'record OTP built from the boot script, which names no applications -' \\
         'releases/RELEASES was missing, or could not be read, when the system' \\
         'booted. Restart the system: the release creates the file before it starts.' >&2
    exit 1
    """)
  end

  defp recorded?(context), do: File.exists?(context.record)
end
