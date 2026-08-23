### Added

- `bin/castle`, a release management CLI, is now installed alongside the
  standard launcher. It provides `releases`, `upgradable`, `unpack`, `install`,
  `commit` and `remove`, and delegates to the running system through the standard
  launcher.
- `bin/castle upgradable` asks whether the system can be upgraded from, for an
  operator who wants to know where one stands without staging or installing
  anything. It says nothing when it can, and exits zero; when it cannot, it
  reports the same refusal `unpack` and `install` would, and exits non-zero.
  Nothing has to call it first — those two ask the question for themselves, from
  inside the operation.
- `bin/castle commit` may now be given no version, in which case it commits
  whichever release is currently running. It exits non-zero if there was no
  such release, so that automation can tell nothing was committed.
- `bin/castle install` now confirms that the version it installed is the one
  running before it reports success, rather than trusting what
  `release_handler` replied. That reply says only that the upgrade was
  accepted: a transition that restarts the emulator is replied to and *then*
  reboots, so a successful upgrade can arrive back here as a lost connection,
  and an upgrade that replaces the emulator finishes on the way back up, where
  it can still fail and roll back. A reply that the node has gone away is
  therefore taken to settle nothing either way, and `install` polls
  `Castle.running/1` until the version is running - exiting 0 only then, and
  non-zero on a real failure or if the version never becomes the running one.
  What the install printed on standard output is held back until the version has
  been confirmed. Only then does it go to standard output as the report of
  success it is; if the version is never confirmed it goes to standard error
  with the rest of the diagnosis instead, so nothing on the success stream ever
  describes an install that did not take effect. What the launcher wrote to
  standard error stays on standard error throughout - from the install, and from
  every confirmation after it: the two streams are captured separately, so a
  warning from the VM, or from a config provider running in the peer that
  resolves the target's configuration, arrives where a pipeline watching that
  stream will find it, including when it arrives just as the upgrade is being
  declared good.

  Everything that could refuse to go on is settled before the install runs - the
  timeout, the clock, and somewhere to capture what the launcher says, which is
  a directory `install` creates for itself under `RELEASE_TMP` and removes when
  it is done. Past that point the system is on another release, and stopping
  there would leave that unsaid and unconfirmed.

  And when something does go wrong past that point - the deadline has to be
  timed from after the install, so not everything can be settled in advance -
  what the install said is reported anyway, along with the fact that nothing
  confirmed it and a pointer at `bin/castle releases`. A failure late in the
  wait never leaves an operator holding a diagnostic about a clock or a
  temporary file with no mention of the release that moved.

  One of those checks is worth spelling out, because it can refuse a directory
  that would have been used before: `RELEASE_TMP` must not be writable by
  everyone unless it is sticky. Where it is, another user can rename the capture
  directory and leave a symlink in its place, whatever mode it was created
  with - renaming an entry is the parent directory's business, not the entry's -
  so `install` says so and stops rather than racing it. Neither ordinary setting
  is affected: the default is a `tmp` directory inside the release itself, and
  `/tmp` is sticky on every mainstream Unix, which is exactly what the sticky bit
  is for. A shared directory that is world-writable and *not* sticky is the one
  case, and `chmod +t` on it, or a `RELEASE_TMP` of the operator's own, is what
  the message asks for.

  `CASTLE_INSTALL_TIMEOUT` sets how long it keeps asking, in seconds, and
  defaults to 300, with 86400 the most it accepts: how long a reboot takes is a
  property of the system being upgraded. It is a deadline in elapsed time
  rather than a count of attempts, so the time the attempts themselves take
  counts against it, and the clock is whole seconds, so the wait can come out
  up to a second short of the number given. It is the system clock, so a
  correction to that clock while `install` is waiting moves the deadline with
  it; there is no monotonic clock to be had from a POSIX shell, and elapsed
  wall-clock time is what a number of seconds means to an operator anyway.

  It is a deadline for the *retrying*, not a limit on any single question.
  Nothing can interrupt one already in flight: `rpc` reaches the node through
  `:erpc`, which waits indefinitely, so a node that holds the connection open
  without answering holds the attempt with it - as it would hold the install
  itself, which happens before the deadline exists at all. An operator who
  needs a hard bound has to impose one from outside, with `timeout(1)` or
  whatever runs the deployment.

  Worth knowing before it surprises anyone: a lost connection is exactly what a
  successful restart looks like from out here, and so is a wrong cookie, or a
  node that was already down. `install` asks about those until the deadline and
  then fails, rather than failing at once. That is honest - it genuinely cannot
  tell whether the system is coming back - but with the default it means a
  five-minute wait for a typo in `RELEASE_COOKIE`. Set `CASTLE_INSTALL_TIMEOUT`
  low when driving a system that is known to be reachable.

  And the other way round: interrupting `bin/castle install` stops the waiting,
  not the upgrade. The work runs on the system being upgraded, in
  `release_handler`, and it carries on whether or not anything is still
  listening - so a version may well become the running one after the command
  that asked for it has gone. `bin/castle releases` is how to find out where
  the system actually got to.

  A relup that restarts the emulator can now be built - see
  `mix forecastle.relup --restart` below - but the transition it describes
  **cannot be performed**: the install fails while preparing the reboot, and
  nothing would bring the reboot back up on the version that was installed
  anyway. That is
  [castle#14](https://github.com/ausimian/castle/issues/14) and
  [#10](https://github.com/ausimian/forecastle/issues/10). What is covered is
  the hot-upgrade path, by the `:e2e` suite, which now installs *and* confirms;
  and every branch of the shell logic - inconclusive, confirmed, failed, timed
  out - against a launcher stub, which remains the only place the restart shape
  can be simulated. A continuation that fails and rolls back is left to the
  end-to-end coverage those two bring.
- `mix forecastle.relup` now takes an upgrade strategy, because whether a
  transition can be hot is a property of the edge between two releases rather
  than of either release. `--hot` requires a genuine hot upgrade and fails,
  having written nothing, if the transition cannot be one - a missing appup
  entry, an ERTS change, or an appup that asks for the emulator to be restarted -
  which is what a pipeline that promises zero downtime needs. `--restart` makes
  every transition in the relup a single `restart_emulator` instruction, written
  directly, with no appup read for any application, not even one the project
  owns: the escape hatch for a change whose upgrade instructions are not worth
  maintaining. With
  neither, the strategy is `auto`, and each transition is generated from the
  appups unless something in it cannot be hot-upgraded - in which case that
  transition, and only that one, becomes a restart.

  `auto` makes a transition a restart when the ERTS version changed - which is
  not a hot upgrade under any policy, and which no appup could make one - or when
  the version of an application the project does not own changed and *no appup
  covers that move*: a dependency, one of Elixir's own applications, or one of
  OTP's. An appup entry that names the from-version is an instruction for this
  transition whoever wrote it, so an edge it covers stays hot; nothing matching
  means there is no hot upgrade to be had. The appup read is the one beside the
  target release's copy of the application,
  `lib/<app>-<vsn>/ebin/<app>.appup`, and the from-version is matched the way
  `systools_relup` matches it, so an appup that names a from-version as a regex
  resolves here exactly as it will during the upgrade.

  Each direction is classified on its own, because an appup's upgrade and
  downgrade lists are independent and a from-version in one need not be in the
  other: a relup may carry a hot upgrade from a version and a restart back down
  to it. Applications merely added or removed are left to `systools`, since
  starting or stopping one is hot. Which transitions were chosen, and why, is
  printed.

  Every restart generated is the one-stage `restart_emulator`: the relup is
  evaluated in full in the running system, `install_release/1` replies
  `{ok, Vsn, Descr}`, and the emulator then reboots. The two-stage
  `restart_new_emulator` - which boots a hybrid temporary release carrying the
  new ERTS, kernel, stdlib and sasl over the old applications, and continues the
  relup on the way up, replying `{continue_after_restart, Vsn, Descr}` - is not a
  strategy here, and is refused where it turns up. Which of the two a relup
  carries is worth saying out loud precisely because those replies differ and
  automation reads them.

  That is also why `auto` decides the ERTS case for itself rather than asking
  `systools` and taking what comes: `systools` inserts `restart_new_emulator` on
  its own whenever the ERTS version differs between the two releases, so a
  default strategy that simply generated a relup would ship the two-stage
  transition without anybody having chosen it. An ERTS change becomes a
  `restart_emulator` transition instead, and whatever `systools` does produce for
  the remaining transitions is inspected, so a `restart_new_emulator` arriving
  through an appup is refused rather than packaged.

  `auto` does not fall back to a restart when an appup for an application the
  project *does* own is missing, either. A transition it judged hot and `systools`
  then could not generate is a failure, so that the default never silently ships
  something other than the upgrade it decided on; ask for the restart with
  `--restart`.

  **While a restart transition cannot be performed, `auto` refuses to write one.**
  A relup that restarts the emulator can be built and packaged, but the transition
  it describes fails on install - see the known limitation below - so `auto`
  exits non-zero rather than produce an upgrade plan that is known not to
  install. The message names the edge that forced the restart and why, whether
  that is the ERTS change or the application whose move no appup covers, and
  points at `--restart` as the deliberate override. The same applies to a
  `restart_emulator` an appup asked for by name during an `auto` run: how the
  relup came by the instruction makes no difference to whether it can be
  installed.

  A run says which transitions restart - or that none of them do - exactly once,
  and the two kinds are settled at the point each becomes knowable. An edge
  classification found to need a restart is refused before anything is generated,
  because that already decides the run: nothing the remaining transitions turn out
  to be can change it, so generating them can only fail in a way that reports
  something other than the reason the run is failing. An appup that asks for the
  restart by name is invisible until `systools` has produced a script, so it is
  settled after generation. A relup with both kinds in it therefore names the
  classified edge and generates nothing; anything an appup in the rest of it asks
  for is reported by the run that follows, once that edge is gone.

  This is temporary and will be lifted, at which point `auto` will announce the
  restart it chose instead of refusing - and then, since the run proceeds, both
  kinds are named in the one announcement. Lifting it is work still to do rather
  than a switch to throw: there is no flag, environment variable or build option
  that turns the refusal off, and no announcement waiting behind one. `--hot`
  and `--restart` are unaffected in either direction; both are explicit
  requests, and it is fine for `--restart` to produce a relup that cannot yet be
  deployed.
- A test suite. It assembles a real release from a fixture application and, in
  the `:e2e` suite, boots it and performs a hot upgrade.

### Changed

- **Breaking:** Forecastle no longer touches configuration. It used to set
  `:runtime_config_path` to `false`, install a `Config.Reader` of its own,
  initialise every config provider itself and stash the results, and rename the
  `sys.config` Mix wrote to `build.config` — so that the standard launcher could
  not configure the system and Castle had to expand the configuration in a
  preboot VM before every start. All of that is gone. Mix decides which file
  configures a release at runtime, initialises the providers a project declared
  with whatever term it declared them with, writes `sys.config`, and expands
  runtime configuration in the booting VM, exactly as it does for a release
  Forecastle was never involved in.

  The reason that interception existed was to give the version being upgraded
  *to* a configuration resolved by *its* providers, which is not something a
  boot of the version being upgraded *from* can produce.
  [castle#13](https://github.com/ausimian/castle/issues/13) now does that
  properly: `install` and `commit` materialise the target's configuration in a
  temporary `:peer`, booted on the target's own code and running the target's
  own providers through Elixir's own pipeline. The two changes are atomic —
  neither works without the other. It is also the only path Castle 1.0 has: the
  branch that read a `build.config` is gone along with the file, so a release
  assembled by this Forecastle carries the `sys.config` Mix wrote and nothing
  else, and an older Castle handed one looks for a file that is not there. This
  release requires the Castle it ships with, and that Castle requires this one.

  What this fixes, what it costs, and what it means for an existing deployment
  are below.
- The `env.sh` fragment no longer expands configuration, and no longer runs on
  every start. It used to run a preboot VM on every `start`, `daemon` and
  `eval`, to expand `build.config` and to create `releases/RELEASES`. The
  configuration half is gone outright. What remains is `releases/RELEASES`, and
  the fragment now creates it only when the release has not got one — the first
  start of a deployment, and no start after it. It is still appended after any
  `env.sh` the project supplied, and it is still where
  [#10](https://github.com/ausimian/forecastle/issues/10) will consume the
  provisional restart marker that a relup restarting the emulator leaves in
  `releases/new_start_erl.data`.

  A release therefore starts as quickly as a plain Mix release every time bar
  the first, and a start that used to fail because configuration could not be
  expanded now fails, or does not, wherever Mix would have it fail. A start that
  *cannot* create `releases/RELEASES` — a release root nothing may write to, say
  — warns and carries on, rather than refusing to start a system that does not
  need that file in order to run.
- `bin/castle unpack` and `bin/castle install` refuse a system that cannot be
  upgraded from, and say why and what to do about it. The refusal is Castle's,
  made inside the operation itself, so what `bin/castle` does is pass it on: the
  message goes to standard error and the command exits non-zero, which is what a
  script chaining `unpack` and `install` needs. What decides is the release
  record `release_handler` is working from, not whether `releases/RELEASES` is on
  disk: it reads that file once, in its `init`, and when the file is missing — or
  cannot be read — it works from a record it builds out of the boot script's name
  and version, which names no applications. Upgrading from that is silently wrong
  rather than refused; see the fix below for what it leaves behind.

  **The remedy is a restart, not creating the file.** Nothing can repair the
  record a running system holds: `release_handler` never reads `RELEASES` again
  after its `init`, so a file created afterwards changes nothing about what the
  node is working from — and the first operation that changes anything, `unpack`
  among them, writes the record it is already holding straight back over the
  file, so creating it by hand is erased moments later and a restart after
  *that* reads the erased version. Restart first, and the release creates the
  file before the system starts.

  **A restart is enough only when the file was missing.** The record is
  synthesised when `RELEASES` was absent *or* unreadable, and the `env.sh`
  fragment creates it only when it is absent — so a file that is there and cannot
  be read is stepped over on every start, and the system comes back on another
  synthesised record. Make that file readable, or remove it, before restarting;
  otherwise the restart changes nothing and the refusal repeats. Castle's message
  says which of the two applies.

  Nothing asks the question ahead of those operations, and a deployment script
  should not either. A check made in one call and acted on in another is a check
  about a moment that has passed: the node can restart in between, onto a record
  it makes up afresh, and the operation would then go ahead on an answer that no
  longer held. `commit`, `remove` and `releases` are not refused at all — none of
  them can write that record back, and refusing them could strand a version that
  was already installed.
- Assembling a release that includes Windows executables still warns, but for a
  different reason, and the warning says so. The `.bat` launcher now boots: Mix
  writes the `sys.config` it reads and configures the system itself, which it
  could not do while Forecastle was withholding both. What a Windows deployment
  has not got is `bin/castle`, which is a POSIX shell script, so nothing on it
  can unpack, install or commit an upgrade.
- **Breaking:** the `:appup` compiler now fails the build when the `:appup`
  project key names a file that does not exist, rather than warning and
  carrying on. The project asked for an appup and cannot have one, and the
  alternative is a release whose missing upgrade instructions only surface
  later — in `:systools.make_relup/4`, or during the upgrade itself. Its
  messages also reach the shell now: diagnostics returned by a compiler are
  for editors to display inline, and nothing prints them on the command line.
  A project that only has an appup in some environments should say so, rather
  than name a file that is not there:

  ```elixir
  appup: if(Mix.env() == :prod, do: "appup.exs")
  ```

  A `nil` key is the supported off switch: it removes any output an earlier
  build left and reports nothing further.
- **Breaking:** the standard Mix launcher, `bin/<release>`, is no longer
  replaced. It keeps everything Mix gives it — cookie handling, distribution,
  `eval`/`rpc`/`remote`, daemon mode, version selection — and stays current with
  Elixir's own launcher. The release management commands that Forecastle used
  to graft onto it have moved to `bin/castle`; `bin/<release> unpack`,
  `install`, `commit`, `remove` and `releases` are now `bin/castle unpack` and
  so on.
- The Castle integration is installed by extending the release's `env.sh`
  rather than by replacing the launcher. An `env.sh` supplied through
  `rel/env.sh.eex` is preserved and runs first.
- `mix forecastle.relup` with no strategy switch is now `auto`, which changes what
  an existing invocation does with some transitions. Case by case, against a task
  that simply asked `systools` for the relup:

  - **A dependency bump whose appup covers the move** - an entry naming this
    from-version, in the direction being generated - is a hot upgrade, exactly as
    it was. **Unchanged.** This is the ordinary case, a Castle bump among them.
  - **A dependency bump with no appup, or none that matches** already failed. The
    task delegated to `systools_relup:get_script_from_appup/5`, which throws
    `file_problem` for an appup that is not there and `no_relup` when no entry
    matches the from-version, so this case produced no relup before either. It
    still fails, and only the message changed: it names the application, both
    versions and the appup entry that is missing, rather than reporting
    `no_relup` against whichever application `systools` happened to reach first.
  - **An ERTS change** did produce a relup, and the wrong kind.
    `systools_relup:check_for_emulator_restart/5` inserts the two-stage
    `restart_new_emulator` on its own whenever the ERTS version differs, warning
    only that it changed - so the relup carried a transition nobody had chosen,
    which replies `{continue_after_restart, Vsn, Descr}` and which Castle cannot
    install. `auto` now decides this case for itself, as a one-stage restart
    transition, which while such a transition cannot be performed means the
    generation is refused. `--restart` generates it. **Materially changed.**
  - **An appup that names an emulator restart itself** was passed straight
    through, and the relup was written with the restart in it. `auto` now refuses
    it, `--hot` refuses it, and `--restart` - which reads no appup at all - makes
    the transition a `restart_emulator` by its own choosing. **Materially
    changed.**

  So the two cases that changed are the two that used to write a relup carrying
  an emulator restart; the other two are a hot upgrade that is still a hot
  upgrade, and a failure that is still a failure.

  `--hot` is **not** the previous behaviour and is not the way back to it: it
  refuses an appup-supplied emulator restart that the old task packaged. What it
  is good for is a pipeline that wants the generation to fail rather than degrade.
  `--restart` is the way to get a relup out of the two changed cases.
- A `mix forecastle.relup` run that fails now writes nothing at all. It used to
  let `systools` write the relup and report afterwards, which was harmless while
  every refusal came from `systools` itself; the strategies add refusals that can
  only be made once a relup has been generated, so the file is now written by the
  task, from the term it inspected, when there is nothing left to refuse. A relup
  already in the output directory is therefore the one still sitting there after
  a failure, rather than one that was replaced by a plan that was then rejected.
  The bytes are unchanged: the same encoding comment and single term `systools`
  writes and `release_handler` reads.

  The relup is also never opened for writing. It is published by renaming a
  staging file written beside it in the same directory, so the guarantee holds
  for a failure with a file already open too: a truncating write that then failed
  - out of space, a killed process, a close that failed - would leave the earlier
  relup empty or half a plan even though the run failed. A reader now sees the
  whole of one relup or the whole of the other, and a build that reads it while a
  generation is running cannot read a partial one.
- `mix forecastle.relup` now requires at least one of `--fromto`, `--upfrom` or
  `--downto`. It used to accept none and write a relup with no transitions in it,
  which is not an upgrade plan and which `release_handler` can do nothing with.
- Raised the minimum Elixir requirement to 1.18.

### Security

- `bin/castle` built its RPC expression by interpolating the version
  argument into Elixir source, so a version such as `1.2.3));System.stop(1)#`
  closed the sigil and ran arbitrary code on the node with the release
  cookie's authority. `bin/castle` now refuses the characters that can end
  the sigil, escape within it, or start an interpolation, along with the
  path separator, and control characters: a version is echoed back in the
  messages that report a failure to act on it, so one carrying a newline can
  add a whole line of its own to that output - including a forgery of the
  launcher's disconnect diagnostic, which `install` reads to decide whether a
  failure was really a reboot, and which would have it confirm and report a
  success for an install that had failed. Everything else is passed through,
  since Mix does not constrain a release version. The same sink existed in the
  launcher Forecastle used to generate.

### Fixed

- `mix forecastle.relup` failed with `:systools is not available` in projects
  that do not themselves depend on `:sasl`, because Elixir prunes unused OTP
  applications from the build's code path.
- `mix forecastle.relup` exited 0 when it had generated nothing.
  `:systools.make_relup/4` reports ordinary failure by returning `:error`, and
  Mix does not turn what a task returns into an exit status, so a build
  pipeline could not tell that generation had failed. Nothing removes a relup
  the task did not write, so the build then went on to package whatever plan an
  earlier run had left in the project root, as this version's. The task now
  says what `systools` could not do and fails. Warnings that `systools` used to
  print for itself - an ERTS version change among them - are passed on rather
  than swallowed.
- `mix forecastle.relup --outdir` was accepted and then ignored, so the relup
  was written to the current directory regardless, overwriting any unrelated
  relup already there. The switch now decides where the file goes, and the
  directory has to exist. Post-assembly still copies the relup it finds in the
  project root, which is where the default puts it, so `--outdir` is for
  generating a relup to look at or to keep - not for feeding one to a release.
- Assembling a release checked only that a `relup` existed in the project
  root before packaging it, so an upgrade plan for another version — or the
  remains of a write that was interrupted — was copied in and later applied by
  `release_handler` as this version's plan. The relup is now read and its
  target version checked against the release being assembled, and assembly
  fails if it does not match, if the upgrade and downgrade sections are not
  the lists `release_handler` will reach into, or if the file cannot be read
  as an upgrade plan at all. That is the contract OTP applies in
  `systools_make:check_relup/1` when it packs a tarball itself, plus the
  version check; Mix packs its own tarball, so nothing was applying it. A
  build that was silently packaging the wrong plan will now stop instead —
  before assembly begins, so a rejected relup leaves no half-built release
  behind for a later build to stumble over.
- `mix forecastle.relup` discarded arguments it did not recognise, so a
  mistyped switch, or a path given without one, generated a relup between
  releases the caller had not named instead of reporting the mistake. Omitting
  `--target` raised a `KeyError` from the middle of the task. Both are now
  errors that say what is wrong, as is repeating `--target` or `--outdir`,
  which used to keep the last occurrence and generate from a target the
  caller had not asked for. `--fromto`, `--upfrom` and `--downto` may still
  be given more than once, as they always could.
- A release naming its runtime configuration file with `:runtime_config_path`
  booted `config/runtime.exs` instead. The option was read as a boolean — any
  value meant "there is runtime configuration" — and the provider that replaced
  Mix's was hardcoded to `config/runtime.exs`, so a project asking for
  `config/prod_runtime.exs` got the other file if it happened to exist, and a
  provider pointing at a file that was never copied into the release if it did
  not. Mix has always handled this option correctly, and now nothing overrides
  it.
- Config providers declared with anything other than a keyword list were handed
  something else. `Mix.Release` allows any term as a provider's init argument,
  and Forecastle rewrote a non-list into `[path: term]` and then added an `:env`
  key to whatever was left — so a provider declared with a binary, a map or a
  plain list saw a keyword list it had never asked for. Providers are no longer
  intercepted, so `init/1` is called by Mix, with the term the project wrote.
- Runtime configuration could not read the standard release variables.
  The launcher sources `env.sh`, and so used to run the preboot VM that expanded
  configuration, before it assigns `RELEASE_COOKIE`, `RELEASE_NODE`,
  `RELEASE_TMP` and the rest, leaving them unset for `runtime.exs`. Nothing
  expands configuration from `env.sh` any more: the launcher exports all of them
  before it starts the VM that configures itself, so `runtime.exs` sees them the
  way Mix's own documentation says it does.
- Concurrent `start`, `daemon` and `eval` invocations no longer race on
  `sys.config`. Expanding configuration into the version directory meant two
  boots with differing environments overwrote each other's configuration; Mix
  applies the resolved configuration inside the booting VM instead, and writes
  nothing.
- `bin/castle` looked for the launcher at `bin/$RELEASE_NAME`. `RELEASE_NAME`
  names the node, not the executable, so setting it sent the CLI looking for
  a launcher that does not exist. It is now passed through to the launcher
  and the executable is the one named at build time.
- The `RELEASES` file was created relative to the working directory, so
  starting a release from anywhere other than its root left the system unable
  to manage its own releases. Where the launcher is invoked from still makes no
  difference.
- An upgrade could silently leave an application running from the release it was
  replacing. `release_handler` only replaces the code path of an application it
  knows has changed version, and it knows that by comparing the release record it
  is running against the one it is installing. Where `releases/RELEASES` was
  missing at startup, the record it is running is one OTP builds out of the boot
  script, which names no applications at all — so *nothing* compared as changed,
  and every application whose new code the relup does not explicitly load was
  left reachable only through the directory of the superseded release, which the
  next `bin/castle remove` deletes. Nothing reported it. The file is now created
  before the system starts, and `bin/castle unpack` and `bin/castle install`
  refuse rather than upgrade a system that started without one — the operations
  reading the node's own records as they act, so that a file which appeared after
  the boot that went looking for it is not mistaken for a system that can be
  upgraded, and so that nothing acts on an answer given before a restart. The
  `:e2e`
  suite covers it with an application whose version changes and whose appup asks
  for nothing, which is the shape that used to go unnoticed.
- The `GitHub` link in the Hex package metadata pointed at the Castle
  repository rather than Forecastle's.
- The `:appup` compiler left `<app>.appup` behind in `ebin` once the project
  stopped asking for one, whether because the source file was deleted or
  because the `:appup` key was removed. It only worked out where the output
  went on its way to writing it, so neither of those cases could remove
  anything. An incremental build — which is what a CI cache produces —
  therefore went on packaging upgrade instructions from an earlier version of
  the application, and `release_handler` applied that obsolete plan during a
  hot upgrade. The stale output is now deleted instead. Leaving the `:appup`
  key unset is a supported way to turn an appup off for an environment: the
  earlier output is removed, and beyond saying so once, nothing is reported.
  Removal needs the compiler to stay in `:compilers` — dropping it from the
  list stops it running at all, as it would any Mix compiler.
- The `:appup` project key is resolved relative to the project file, as the
  README has always said it is, rather than to whatever the working directory
  happens to be. That is what makes "the source is missing" a trustworthy
  verdict, now that it deletes the output and fails the build.
- The `:appup` compiler returned a bare diagnostic where `Mix.Task.Compiler`
  expects a list of them, so Mix discarded it and reported that the compiler
  had misbehaved instead of saying what was wrong. It also ignored the result
  of writing the appup, and so reported success when the write had failed.
- The appup was written as the formatter produced it, which is Unicode
  chardata rather than iodata. An appup containing a codepoint above 255 —
  a module or term with a non-ASCII name — failed to write at all, and one
  between 128 and 255 was written as a lone byte that `:file.consult/1`
  cannot read back, so the build reported success and left behind an appup
  that `systools` will not parse. It is encoded as UTF-8 now.

### Upgrading an existing deployment

OTP's `release_handler` extracts release tarballs with `keep_old_files`, so a
hot upgrade never replaces files that already exist at the top level. Upgrading
a deployment that was built by an earlier Forecastle therefore leaves its old
`bin/<release>` in place: the upgrade succeeds and `bin/castle` appears, since
that file is new, but the old launcher and its release management commands
remain until they are replaced out of band.

Replace the contents of `bin` from the new release when migrating, or the
deployment keeps running the launcher Forecastle used to generate - including
the version argument handling fixed in this release.

This applies to `bin/castle` too: once installed, later changes to it will not
reach an existing deployment through a hot upgrade. That is the same property
Mix's own `bin/<release>` has always had.

Configuration is decided per version directory, so a deployment part way through
this migration is coherent rather than confused: the version it is running keeps
its `build.config`, and a restart back into it is still expanded the old way — by
that version's own `env.sh` and its own copy of Castle, both of which the upgrade
leaves where they are — while the version it is upgraded to has a `sys.config`
and is resolved in a peer. Nothing has to be converted in place, and nothing in
the new version reads the old file.

### Known limitations

- **A transition that restarts the emulator can be generated, but not
  performed.** `mix forecastle.relup --restart` writes the relup, assembly
  packages it, and `bin/castle install` handles the reply, each branch of that
  handling tested against a stub - but the transition itself does not complete.
  `release_handler` calls `heart:set_cmd/1` while preparing the reboot, which
  fails where there is no `heart` process, so the install fails before anything
  reboots; and even past that, the reboot comes back on whichever version
  `releases/start_erl.data` names, which only `commit` writes, while
  `release_handler` leaves the installed version in
  `releases/new_start_erl.data` instead.
  [castle#14](https://github.com/ausimian/castle/issues/14) and
  [#10](https://github.com/ausimian/forecastle/issues/10) are what close that.
  Until they land, treat a restart relup as something to generate and inspect
  rather than to deploy - which is why `auto` refuses to produce one, and why
  `--restart`, an explicit request, still will.
- **`restart_new_emulator` is not supported.** The two-stage transition - a
  hybrid temporary release, a reboot into it, and the rest of the relup applied
  on the way up - is refused wherever it turns up rather than generated. An ERTS
  change, which is what `systools` would otherwise insert it for, is taken out of
  `systools`' hands and treated as a one-stage restart transition, which under
  `auto` today means the generation is refused and under `--restart` means a
  `restart_emulator` relup. Supporting the two-stage transition properly is its
  own piece of work: the provisional boot would have to come up and *resume* an
  upgrade, which is strictly more than coming up on a provisional version.
- **A system that cannot write `releases/RELEASES` cannot be upgraded.** The
  release creates it on its first start; where that fails — a read-only release
  root is the usual reason — the start warns, the system runs perfectly well, and
  `bin/castle unpack` and `bin/castle install` then refuse, because upgrading
  from the release record OTP builds out of the boot script leaves applications
  on old code without saying so. Make the release root writable, or the
  `releases` directory within it, and restart once. There is no way to repair a
  running system: `release_handler` reads that file only in its `init`.
- Windows releases are not supported; see above. What is missing is now
  `bin/castle` rather than a bootable release.
