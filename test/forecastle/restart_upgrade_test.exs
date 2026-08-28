defmodule Forecastle.RestartUpgradeTest do
  @moduledoc """
  Boots a real release under the stock Mix launcher and upgrades it through a
  transition that restarts the emulator.

  The sibling of `Forecastle.UpgradeTest`, and its opposite where it counts: that
  suite asserts the operating system pid does *not* change across the install,
  and this one asserts that it does. Everything else about the shape is the same,
  and deliberately so - `bin/castle unpack`, `install`, `commit`, against a
  release started by `bin/<name>`.

  What it takes to make that work is spread across both halves of the pair, and
  each piece is asserted here because nothing smaller can be:

    * `release_handler` calls `heart:set_cmd/1` while preparing the reboot, and
      that raises `badarg` with no `heart` process, so the install would fail
      before anything rebooted. The `env.sh` fragment runs the real heart,
      defanged: `HEART_NO_KILL`, no `HEART_COMMAND`, and an inert
      `$ROOT/bin/start` to neutralise the temporary command `release_handler`
      installs. The fixture supplies its own `-heart` through `rel/vm.args.eex`,
      which the launcher passes as `-args_file`, and spells it `-he\art` -
      because *two* of them hang the boot, and because the only way to see that
      one is to ask erlexec what it made of the file rather than to read the file.
    * `release_handler` writes the target to `releases/new_start_erl.data` and
      leaves `releases/start_erl.data` naming the version that is still
      permanent, so the reboot would come back on the old version. The `env.sh`
      fragment selects the provisional one, and only when Castle's own marker
      agrees with OTP's.
    * nothing in the release restarts it. The test is the supervisor; see
      `Forecastle.Deployment.install_supervised/3`.

  The rollback half is exercised before the commit half, and in that order for a
  reason: a provisional release that is killed before `Castle.commit/1` has to
  come back as the *previous* version, and the only way to see that is to kill
  one. The second install then goes through the same transition again from the
  release that rolled back, and is committed.

      mix test --include e2e

  Distribution runs without epmd (see the fixture's `rel/vm.args.eex`), so no
  daemon needs to be running on the host for this to work.
  """

  use Forecastle.ReleaseCase
  use Forecastle.UpgradeCase

  alias Forecastle.Fixture

  @moduletag :e2e

  @from "0.1.0"
  @to "0.1.1"

  # The greeting changes between the first boot and the provisional one, on
  # purpose. `config/runtime.exs` reads it, so the provisional boot answering the
  # second value is what says its own providers ran again over the `sys.config`
  # Castle materialised - which is a thing nothing asserted before, because until
  # now no suite restarted a release after an install.
  @first_greeting "hello-from-runtime"
  @restart_greeting "hello-after-restart"

  # `CASTLE_INSTALL_TIMEOUT` is generous, because the wait covers a reboot and a
  # full cold boot, and bounded, so that a hang fails the suite rather than
  # sitting for the five-minute default.
  @restart_env [{"CASTLE_INSTALL_TIMEOUT", "120"}, {"SAMPLE_GREETING", @restart_greeting}]

  # The first start is made hostile on purpose. These three are what a deployment
  # can already have in its environment - a systemd unit that once ran a release
  # with heart as a watchdog, an image that sets them for something else - and
  # every one of them contradicts what this release says it does: a command to
  # restart with, heart's killing turned back on, and a timeout short enough to
  # bite. The whole restart transition then runs under them, so a fragment that
  # only *defaulted* these would have this suite exercising a release with a live
  # watchdog beside its supervisor.
  #
  # Measured, and worth knowing before reading the assertions: an inherited
  # HEART_COMMAND is not merely a restart authority for an unexpected death.
  # heart runs it on an *orderly* halt too - "Erlang has closed. Executed ... ->
  # 0. Terminating." - so with one in the environment every `bin/<name> stop`
  # would start the release again.
  @hostile_heart [
    {"HEART_COMMAND", "/usr/local/bin/restart-me"},
    {"HEART_NO_KILL", "FALSE"},
    {"HEART_BEAT_TIMEOUT", "11"}
  ]

  # The -heart this deployment already has arrives from the fixture's own
  # `rel/vm.args.eex`, which the launcher passes to the emulator as `-args_file`,
  # and it is asked for at *assembly* time so that only the releases this suite
  # builds carry it: -heart makes heart print `heart_beat_kill_pid = <pid>` on
  # every VM started with that file, `eval` included, and
  # `Forecastle.ConfigurationTest` asserts on the exact output of an `eval`.
  #
  # **It is spelled `-he\art`, because that is the case no reading of the
  # environment can answer.** erlexec removes the backslash and hands the emulator
  # `-heart`; a fragment that matched text, split fields or scanned the file
  # appends a second one, `init:get_argument(heart)` answers `{ok, [[], []]}`,
  # `heart:check_start_heart/0` raises a case_clause at heart.erl:348 and the boot
  # hangs having printed nothing. Three versions of that guard shipped, each with a
  # unit test that shared its model; the fragment now asks `erl -emu_args_exit`
  # what the argument vector came out as. The rest of the note lives in that file,
  # which is where a reader looking for it will go.
  #
  # It has to be exercised on a real boot rather than only in the shell: what a
  # unit test can assert about the fragment is what the fragment says, what
  # `-emu_args_exit` reports is what erlexec assembled, and what hangs is the
  # emulator. A fragment that misses this flag makes the suite time out inside
  # `start!/2` rather than fail an assertion, which is exactly why that call
  # carries a deadline. Which values the guard recognises, one at a time and
  # against a real erlexec, is `Forecastle.EnvScriptTest`'s.
  @heart_in_vm_args [{"SAMPLE_HEART", "-he\\art"}]

  # ERL_AFLAGS carries the tab probe and *only* the tab probe: a -heart in both it
  # and vm.args would itself be the two-flag hang. `-env` is what makes the tab
  # observable - erlexec splits that variable into arguments on tabs as readily as
  # on spaces, measured - so a node answering with the value is a node whose
  # argument list was really split on them. It is also an ordinary flag variable
  # standing beside the measurement, carrying no heart of its own: the probe reads
  # it on every start here and the boot still gets exactly the one flag vm.args
  # supplies. This used to be phrased as the probe's *gate* not tripping on it;
  # there is no gate any more, and what the case says now is that asking about an
  # unremarkable variable does not manufacture a second flag.
  @tabbed_heart [{"ERL_AFLAGS", "-env\tCASTLE_TAB_PROBE\ttabbed"}]

  @probe_report ~s|IO.puts(inspect(System.get_env("CASTLE_TAB_PROBE")))|

  # What the running node says about the environment it was started with, and
  # about the command heart is actually holding. The environment is what heart's
  # port program reads, so it is the effective configuration rather than a
  # description of one.
  @heart_report """
  IO.puts(inspect({
    System.get_env("HEART_COMMAND"),
    System.get_env("HEART_NO_KILL"),
    System.get_env("HEART_BEAT_TIMEOUT")
  }))
  """

  setup_all do
    workspace = Fixture.workspace()
    relup = Path.join(workspace, "relup")

    deploy = deployment(assemble!(into: "restart-deploy", vsn: @from, env: @heart_in_vm_args))
    next = assemble!(into: "restart-next", vsn: @to, env: @heart_in_vm_args)

    # `--restart`, explicitly, for the reason the hot suite asks for `--hot`: the
    # transition is the subject, so the task rather than an assertion further down
    # is what fails if it stops being generatable. `auto` would judge this edge
    # hot - the dependency's appup covers its move - so it is not the strategy
    # that produces the relup this suite needs.
    make_relup!({deploy.root, @from}, {next, @to}, ["--restart"])
    ^next = assemble!(into: "restart-next", vsn: @to, env: @heart_in_vm_args)

    Deployment.stage!(deploy, Path.join(next, "sample-#{@to}.tar.gz"))

    on_exit(fn ->
      Deployment.stop(deploy)
      File.rm(relup)
    end)

    # Captured rather than discarded: the fragment warns when it overrides an
    # inherited heart setting, and that warning is part of what this suite
    # asserts.
    hostile_start =
      Deployment.start!(
        deploy,
        [{"SAMPLE_GREETING", @first_greeting}] ++ @hostile_heart ++ @tabbed_heart
      )

    booted = %{
      os_pid: Deployment.os_pid(deploy),
      heart: Deployment.rpc!(deploy, "IO.puts(inspect(:erlang.whereis(:heart)))"),
      heart_cmd: Deployment.rpc!(deploy, "IO.puts(inspect(:heart.get_cmd()))"),
      heart_env: Deployment.rpc!(deploy, @heart_report),
      heart_args: Deployment.rpc!(deploy, "IO.puts(inspect(:init.get_argument(:heart)))"),
      tab_probe: Deployment.rpc!(deploy, @probe_report),
      erl_aflags: Deployment.rpc!(deploy, ~s|IO.puts(inspect(System.get_env("ERL_AFLAGS")))|),
      elixir_erl_options:
        Deployment.rpc!(deploy, ~s|IO.puts(inspect(System.get_env("ELIXIR_ERL_OPTIONS")))|),
      start_output: hostile_start,
      counter: Deployment.rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
      releases: Deployment.castle!(deploy, ["releases"]),
      start_erl: File.read!(Path.join(deploy.root, "releases/start_erl.data"))
    }

    Deployment.castle!(deploy, ["unpack", @to])

    # The first transition, abandoned. `install` reboots the node, the launcher
    # selects the provisional version on the way back up, and nothing has been
    # committed - so what a crash from here has to do is come back on @from.
    {provisional_output, provisional_status} =
      Deployment.install_supervised(deploy, @to, @restart_env)

    provisional = %{
      output: provisional_output,
      status: provisional_status,
      os_pid: Deployment.os_pid(deploy),
      counter: Deployment.rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
      greeting: Deployment.rpc!(deploy, "IO.puts(Sample.greeting())"),
      env_marker: Deployment.rpc!(deploy, "IO.puts(Sample.env_marker())"),
      release_env: Deployment.rpc!(deploy, "IO.puts(inspect(Sample.release_env()))"),
      releases: Deployment.castle!(deploy, ["releases"]),
      version: Deployment.launcher!(deploy, ["version"]),
      start_erl: File.read!(Path.join(deploy.root, "releases/start_erl.data")),
      pending?: File.exists?(Path.join(deploy.root, "releases/castle-restart-pending")),
      marker?: File.exists?(Path.join(deploy.root, "releases/new_start_erl.data")),
      castle_names: Path.wildcard(Path.join(deploy.root, "releases/castle-*"))
    }

    # A crash, not a stop: `bin/sample stop` would be an orderly shutdown, and
    # what has to be survivable is the other kind.
    {_output, 0} = System.cmd("kill", ["-9", provisional.os_pid])
    Deployment.await_exit!(provisional.os_pid)
    Deployment.start!(deploy, [{"SAMPLE_GREETING", @first_greeting}])

    rolled_back = %{
      counter: Deployment.rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
      releases: Deployment.castle!(deploy, ["releases"]),
      version: Deployment.launcher!(deploy, ["version"])
    }

    # And again, from the release that came back, this time through to a commit.
    {installed_output, installed_status} =
      Deployment.install_supervised(deploy, @to, @restart_env)

    installed = %{output: installed_output, status: installed_status}

    committed = %{output: Deployment.castle!(deploy, ["commit"])}
    refute committed.output =~ "__CASTLE_COMMIT_"
    refute committed.output =~ "__CASTLE_NOTHING_TO_COMMIT_"

    committed =
      Map.merge(committed, %{
        releases: Deployment.castle!(deploy, ["releases"]),
        version: Deployment.launcher!(deploy, ["version"]),
        start_erl: File.read!(Path.join(deploy.root, "releases/start_erl.data"))
      })

    # One more restart, with no marker anywhere: what an ordinary start boots is
    # the other half of what `commit` means.
    committed_pid = Deployment.os_pid(deploy)
    Deployment.launcher!(deploy, ["stop"])
    Deployment.await_exit!(committed_pid)

    # The one start in this suite with nothing hostile in its environment, and
    # nothing for the fragment to select either, so it is what says the heart
    # warnings above are about the environment rather than about every start.
    quiet_start = Deployment.start!(deploy, [{"SAMPLE_GREETING", @first_greeting}])

    restarted = %{
      start_output: quiet_start,
      heart_env: Deployment.rpc!(deploy, @heart_report),
      counter: Deployment.rpc!(deploy, "IO.puts(inspect(Sample.Counter.info()))"),
      releases: Deployment.castle!(deploy, ["releases"])
    }

    {:ok,
     deploy: deploy,
     booted: booted,
     provisional: provisional,
     rolled_back: rolled_back,
     installed: installed,
     committed: committed,
     restarted: restarted}
  end

  describe "heart, on a release that is going to need it" do
    test "is running", %{booted: booted} do
      # Not because the deployment wants a watchdog - it does not, and heart is
      # configured to do nothing - but because heart:set_cmd/1 sends to the
      # registered name and raises badarg when nothing is there, which is what
      # made a restart transition fail before it could reboot.
      assert booted.heart =~ ~r/^#PID</
    end

    test "has no command of its own", %{booted: booted} do
      # HEART_COMMAND is deliberately unset, so an unexpected death starts
      # nothing at all. release_handler installs a temporary command of its own
      # while preparing a reboot, and that one is inert - see below.
      #
      # **This is the effective command, and it is asserted against a deployment
      # that supplied one.** heart:get_cmd/0 reports whatever the port program
      # holds, and the port program takes its initial command from HEART_COMMAND
      # in the environment - measured: with the variable set, get_cmd/0 answers
      # {ok, "/usr/bin/true"}. So the fragment failing to unset it would show up
      # right here, as the deployment's own command coming back out of heart.
      #
      # Matched either way an empty command can be printed: an empty Erlang
      # string inspects as [] or as "" depending on what it was built from. What
      # is being asserted is that there is nothing in it.
      assert booted.heart_cmd =~ ~r/^\{:ok, (\[\]|"")\}$/
    end

    test "is defanged in the environment it was actually started with",
         %{booted: booted} do
      # The whole suite runs on a deployment that had HEART_COMMAND, a
      # HEART_NO_KILL of FALSE and an 11-second beat timeout in its environment,
      # and this is what the node was started with instead. Asserted on the
      # effective environment rather than on the text of the fragment: heart's
      # port program reads these variables, so what they are in the running VM is
      # the configuration - and a fragment that merely defaulted them would leave
      # a release under an external supervisor with a live watchdog and a way to
      # be killed for a missed heartbeat, which is what every document about this
      # release says it has not got.
      assert booted.heart_env == ~s({nil, "TRUE", "65535"})
    end

    test "says which inherited settings it overrode", %{booted: booted} do
      # Overriding rather than refusing to start: an operator who set these has a
      # configuration conflict, not an emergency. But the setting has stopped
      # taking effect, so it is named, along with what replaced it.
      assert booted.start_output =~ "ignoring HEART_COMMAND=[/usr/local/bin/restart-me]"
      assert booted.start_output =~ "overriding HEART_NO_KILL=[FALSE] with TRUE"
      assert booted.start_output =~ "overriding HEART_BEAT_TIMEOUT=[11] with 65535"
    end

    test "does not report the RELEASES helper stopping as the daemon stopping",
         %{booted: booted} do
      # The first start has no releases/RELEASES, so env.sh boots a short-lived
      # VM to create it before the daemon starts. Forecastle used to add -heart
      # before that call. The helper then printed heart's orderly-shutdown report
      # to the daemon command, including "Would reboot", even though the daemon
      # started immediately afterwards and remained alive. The live-node checks
      # in setup prove the second half; these pin the command's side of it.
      refute booted.start_output =~ "heart_beat_kill_pid"
      refute booted.start_output =~ "heart_beat_timeout"
      refute booted.start_output =~ "Erlang has closed"
      refute booted.start_output =~ "Would reboot"
    end

    test "says nothing on a start that inherited none of them", %{restarted: restarted} do
      # The ordinary deployment, which is every one that does not set these. A
      # warning on every start is a warning nobody reads, and the heart
      # configuration is still exactly the same.
      refute restarted.start_output =~ "HEART_COMMAND"
      refute restarted.start_output =~ "HEART_NO_KILL"
      refute restarted.start_output =~ "HEART_BEAT_TIMEOUT"
      assert restarted.heart_env == ~s({nil, "TRUE", "65535"})
    end

    test "was given exactly one -heart, having inherited an escaped one from vm.args",
         %{booted: booted} do
      # The boot happening at all is most of this: two -heart flags leave
      # heart:check_start_heart/0 with no clause for {ok, [[], []]} and the node
      # never finishes starting, so the suite's own start! would have timed out
      # before any assertion ran. What is left to assert is the argument the
      # emulator actually got, which is the thing that clause matches on - and it
      # is `[[]]` rather than nothing, which says erlexec unescaped the `-he\art`
      # in the fixture's vm.args into a live flag.
      assert booted.heart_args == "{:ok, [[]]}"

      # The flag came from the fixture's vm.args, which the launcher passes as
      # -args_file, and the fragment therefore assigned nothing. An unset
      # ELIXIR_ERL_OPTIONS in the running node is the whole of the evidence that
      # the guard measured rather than modelled: no reading of that file finds a
      # flag spelled `-he\art`, so a fragment that read it would have appended its
      # own here, and the two together are the hang.
      assert booted.elixir_erl_options == "nil"

      # And the tabs really were separators rather than characters in a word -
      # otherwise the field splitting the guard has to do was never exercised, and
      # the tab half of this would pass against a fragment that split nothing.
      assert booted.tab_probe == ~s("tabbed")
      assert booted.erl_aflags == ~s("-env\\tCASTLE_TAB_PROBE\\ttabbed")
    end

    test "is handed an inert bin/start", %{deploy: deploy} do
      # The default start_prg, $ROOT/bin/start, which release_handler composes
      # into heart's temporary command without checking that it exists
      # (check_start_prg/2 returns the {no_check, _} form unexamined). heart
      # really does run it - on init:reboot(), and on a heart-beat time-out where
      # HEART_NO_KILL means the old VM is still alive - so starting anything from
      # it would risk two live nodes.
      start = Path.join(deploy.root, "bin/start")

      assert File.exists?(start)
      assert {"", 0} = System.cmd(start, ["releases/new_start_erl.data"], cd: deploy.root)
    end
  end

  describe "installing a restart transition" do
    test "reports success", %{provisional: provisional} do
      # Zero, which is what a pipeline reads. bin/castle install cannot trust the
      # reply - release_handler answers as soon as it has accepted the upgrade,
      # and the reboot takes distribution down with it - so it asks the system
      # what it is running until the version it installed answers.
      assert provisional.status == 0, provisional.output
    end

    test "restarts the VM", %{booted: booted, provisional: provisional} do
      # The assertion this suite exists for, and the exact opposite of the hot
      # suite's. A restart_emulator transition applies the relup in the running
      # VM and then reboots, so the process the system runs in afterwards is a
      # different one.
      refute provisional.os_pid == booted.os_pid
    end

    test "comes back on the version that was installed", %{provisional: provisional} do
      # Which takes the env.sh fragment: release_handler wrote the target to
      # releases/new_start_erl.data and left start_erl.data alone, so the stock
      # launcher on its own would have booted @from again. Asked of the running
      # node, because that is the only place the answer is.
      assert provisional.counter == ~s({"#{@to}", 0})
    end

    test "still reports the previous version as the one to be booted",
         %{provisional: provisional} do
      # `bin/<name> version` prints "the release name and version to be booted",
      # which it takes from start_erl.data - and it is not a command that starts
      # the system, so the fragment does not select anything for it. So it names
      # @from while @to is what is running, and that is right rather than a bug in
      # either: what it is reporting is where an ordinary restart would land,
      # which for an uncommitted provisional release is the rollback target.
      assert provisional.version == "sample #{@from}"
    end

    test "resolved every path from the provisional version's directory",
         %{deploy: deploy, provisional: provisional} do
      # This is what says the hook re-execs the launcher rather than assigning
      # RELEASE_VSN and returning. By the time env.sh is sourced the launcher has
      # already computed REL_VSN_DIR from start_erl.data, and RELEASE_VM_ARGS -
      # which runtime.exs reads with fetch_env! - is derived from it *after*.
      # Assigning the version in place would have booted @from's vm.args, sys.config
      # and boot script under @to's name; only an exec recomputes them.
      assert provisional.release_env =~ "#{deploy.root}/releases/#{@to}/vm.args"
    end

    test "runs the project's own env.sh across the re-exec", %{provisional: provisional} do
      # The fragment is appended to whatever the project supplied, so the project's
      # half runs on both passes. A marker that survived says the second pass was a
      # real launcher invocation rather than something reconstructed.
      assert provisional.env_marker == "preserved"
    end

    test "re-runs the provisional version's own config providers",
         %{booted: booted, provisional: provisional} do
      # A cold boot of @to, through Elixir's own pipeline, over the sys.config
      # Castle's peer materialised before the install was asked for. The peer
      # resolved it with SAMPLE_GREETING at its first value; this boot sees the
      # second, and answers with it - so materialising did not freeze the
      # configuration, which is what the header Mix wrote is preserved for.
      assert booted.counter == ~s({"#{@from}", 0})
      assert provisional.greeting == @restart_greeting
    end

    test "leaves the new version current and the old one permanent",
         %{provisional: provisional} do
      # release_handler persisted @to as tmp_current before the reboot;
      # transform_release/3 wrote that back as unpacked on disk and set_current/2
      # made it current in the record the handler holds, because init:script_id()
      # names it. Which is what Castle.running/1 needs, and what commit needs.
      assert provisional.releases =~ ~r/#{@to}\s+current/
      assert provisional.releases =~ ~r/#{@from}\s+permanent/
    end

    test "does not touch what an ordinary restart boots",
         %{booted: booted, provisional: provisional} do
      # start_erl.data is written only by make_permanent, and this is the whole
      # rollback property: until the upgrade is committed, the version a restart
      # selects is still the one that was permanent before.
      assert provisional.start_erl == booted.start_erl
      assert provisional.start_erl =~ @from
    end

    test "consumes both markers", %{provisional: provisional} do
      # One-shot, and both of them, so that a second start does not select the
      # provisional version again - which is what makes the rollback below
      # possible at all.
      refute provisional.pending?, "Castle's restart marker survived the boot that used it"
      refute provisional.marker?, "releases/new_start_erl.data survived the boot that used it"
    end

    test "leaves nothing of the protocol behind", %{provisional: provisional} do
      # Every name either side of this puts in the releases directory begins
      # `castle-`: the marker, the claim the hook renames it to, and the working
      # directory Castle stages the marker in before linking it into place. An
      # install and a provisional boot have to leave none of them.
      assert provisional.castle_names == []
    end
  end

  describe "a provisional release that dies before it is committed" do
    test "comes back as the previous permanent version", %{rolled_back: rolled_back} do
      # No marker, so the stock launcher reads start_erl.data, which
      # make_permanent never wrote. Nothing intervened and nothing had to.
      assert rolled_back.version == "sample #{@from}"
      assert rolled_back.counter == ~s({"#{@from}", 0})
    end

    test "leaves the version it rolled back from unpacked", %{rolled_back: rolled_back} do
      assert rolled_back.releases =~ ~r/#{@to}\s+unpacked/
      assert rolled_back.releases =~ ~r/#{@from}\s+permanent/
    end
  end

  describe "committing a restart transition" do
    test "installs again from the release that rolled back", %{installed: installed} do
      assert installed.status == 0, installed.output
    end

    test "reports what was committed", %{committed: committed} do
      assert committed.output =~ "Committed #{@to}."
    end

    test "makes it permanent", %{committed: committed} do
      assert committed.releases =~ ~r/#{@to}\s+permanent/
      assert committed.releases =~ ~r/#{@from}\s+old/
    end

    test "points the stock launcher's version selection at it", %{committed: committed} do
      # The file Castle never writes itself: make_permanent/1 does, and it is what
      # turns the provisional version into the one an ordinary start boots.
      assert committed.start_erl =~ @to
      assert committed.version == "sample #{@to}"
    end

    test "is what an ordinary restart then boots", %{restarted: restarted} do
      # With no marker in sight, so nothing but start_erl.data selected it.
      assert restarted.counter == ~s({"#{@to}", 0})
      assert restarted.releases =~ ~r/#{@to}\s+permanent/
    end
  end
end
