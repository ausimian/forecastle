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
- `bin/castle commit` may now be given no version, in which case it commits the
  provisional release awaiting commit. It exits non-zero if there is none, so
  automation can tell nothing was committed.
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

  That polling is what carries an emulator restart, and it is the reason the
  initial reply cannot be trusted: `release_handler` accepts a
  `restart_emulator` transition and then reboots, so the reply may not even
  survive long enough to arrive.
  `install` treats a lost connection as settling nothing and keeps asking until
  the version it installed answers - across the reboot, and across the cold boot
  after it. Both paths are covered end to end by the `:e2e` suite, and every
  branch of the shell logic - inconclusive, confirmed, failed, timed out - against
  a launcher stub as well. A continuation that fails and rolls back on the way up
  belongs to `restart_new_emulator`, which is not supported; see *Known
  limitations*.
- `mix castle.relup` now takes an upgrade strategy, because whether a
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
  evaluated in full in the running system, and the emulator then reboots. The
  two-stage `restart_new_emulator` - which boots a hybrid temporary release
  carrying the new ERTS, kernel, stdlib and sasl over the old applications, and
  continues the relup on the way up - is not a strategy here. It is refused
  where it turns up. The task keeps the exact instruction name in its output
  because the two transitions behave differently.

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

  A run says which transitions restart - or that none of them do - exactly once,
  and the announcement names both ways a restart can arrive: the edges `auto`
  classified, with the reason for each, and any `restart_emulator` an appup asked
  for by name. It also says that the emulator reboots into a provisional release
  that must be committed. Both kinds are settled after generation, because only
  one of them is knowable before it: an appup's own instruction is invisible
  until `systools` has produced a script. `--hot` and `--restart` remain the ways
  to insist on something else.
- The release now selects a provisional version after an upgrade that restarted
  the emulator, which is what makes such an upgrade work on a deployment
  supervised by systemd, Docker, Kubernetes or runit.

  `release_handler` writes the version it installed to
  `releases/new_start_erl.data` and deliberately leaves
  `releases/start_erl.data` - which is where the stock launcher reads
  `RELEASE_VSN` from - naming the version that is still permanent. That is the
  rollback property, and it is worth keeping: a provisional release that dies
  before `bin/castle commit` is followed by an ordinary start of the version that
  was permanent before, with nobody intervening. What it costs is that something
  has to select the installed version on the boot after the reboot, and the
  `env.sh` fragment is now that something.

  It requires *two* markers, not one, and it re-execs the launcher rather than
  assigning `RELEASE_VSN` in place. Two markers, because `new_start_erl.data` is
  written before the reboot and never removed, so on its own it is not evidence
  that a reboot was asked for: Castle arms a marker of its own beside it and
  clears it if the install failed, and the fragment requires both files and
  requires them to name one version. A re-exec, because by the time the launcher
  sources `env.sh` it has already resolved the version directory, and everything
  it goes on to use - the boot script, `vm.args`, `sys.config`, the `elixir`
  launcher itself - hangs off that. With no valid pair, the stock launcher reads
  `start_erl.data` exactly as it always did.
  A malformed OTP marker is renamed to `new_start_erl.data.rejected.<pid>` for
  inspection; its contents are not printed or left able to control another start.
  Marker values in a warning are percent-encoded rather than replaced by a
  label, so the release is still named. An ordinary space survives that
  encoding, which matters because OTP builds its marker as `EVsn ++ " " ++ Vsn`
  and the fragment keeps the remainder exactly: Mix permits spaces in versions,
  so a space-bearing release is still named in the warning that tells an
  operator which releases to inspect.

  The selection comes before anything else the hook configures, and that is
  load-bearing rather than tidy. Re-exec'ing means the hook is read again, so
  anything decided beforehand is decided about the version being *replaced* - and
  exported to the pass that boots. `heart` is the case that shows it: the two
  versions can carry different `vm.args`, so whether the emulator is already
  getting a `-heart` has to be asked about the one that will actually start.
  Everything after the selection is therefore settled once, by that pass.

  What is atomic is the *claim*, and it is worth being exact about because the
  rest follows from it. The fragment takes Castle's marker by renaming it, which
  is one operation, so exactly one start can act on the pair however many are
  racing. OTP's file is then read and removed in further steps, and no POSIX
  operation moves two files together - so the pair is not consumed as a unit, and
  the order is what makes that safe: the marker goes first, so a start killed
  part way through leaves no marker behind, and the next start reads
  `start_erl.data` and boots the version that was permanent. A provisional
  selection can therefore be lost by an ill-timed kill. It cannot be applied
  twice, and it cannot be applied to a version that was never installed.
- The release now runs OTP's `heart`, deliberately configured to do nothing, on
  the commands that start the system.

  This is not a watchdog and is not offered as one. `release_handler` calls
  `heart:set_cmd/1` while preparing *any* transition that restarts the emulator,
  and with no `heart` process that raises `badarg` - so the install failed before
  anything rebooted, on exactly the externally supervised deployment this library
  is for. The handshake has to be satisfied, and running the real `heart`
  satisfies it through documented interfaces only.

  `heart` is then kept out of the way. `HEART_COMMAND` is not set, so an
  unexpected death starts nothing; `HEART_NO_KILL=TRUE`, so a node that misses
  heartbeats is not killed; `HEART_BEAT_TIMEOUT` is raised to heart's documented
  maximum, because `HEART_NO_KILL` alone does not make a heart-beat time-out
  harmless - the port program exits once it has run its command, and `heart` is a
  kernel process, so `init` halts the node when it goes; and `$ROOT/bin/start`,
  the path `release_handler` composes into heart's temporary command and does not
  check, is shipped and does nothing at all. That last one is not belt and
  braces: `HEART_NO_KILL` suppresses the kill but *not* the command, so a
  `bin/start` that really started the release could start a second node beside a
  live one. The external supervisor remains the only thing that starts this
  release. `-heart` is added to `ELIXIR_ERL_OPTIONS` only when the emulator is not
  going to get one anyway: two of them make `init:get_argument(heart)` answer
  `{ok, [[], []]}`, which heart's own startup check has no clause for, and the
  boot hangs having printed nothing.

  **Whether the emulator is already going to get one is measured rather than
  guessed at, and there is more than one way for it to arrive.**
  `ELIXIR_ERL_OPTIONS` is the variable Mix's generated `elixir` expands; `erl`
  itself prepends `ERL_AFLAGS` and appends `ERL_FLAGS` and then `ERL_ZFLAGS` to
  its effective command line; and the launcher passes `vm.args` as `-args_file`,
  so a project's own `rel/vm.args.eex` carries flags too - and `erl` follows a
  nested `-args_file` out of it. A flag arriving by any of those routes reaches
  `init:get_argument/1` exactly as one on the command line does, and a deployment
  that had one used to receive it plus the appended one, which is the boot hang
  above.

  It is recognised however it is written, which is why the hook does not read
  these itself: `erl` applies shell-style quoting and backslash escaping to
  everything it takes from the environment and from an args file, so `'-heart'`,
  `"-heart"` and `-he\art` all arrive as `-heart` without containing the word.
  The hook therefore asks `erl` - with the start's own environment and args file,
  and without starting a VM - what argument list it would build, and adds a flag
  only if that list has none. **It asks on every start**, whether or not anything
  in the environment looks like it could carry a flag, which costs one
  `fork`+`exec` of a C program that exits without booting an emulator - about
  11ms, once per node start. Nothing is asked for an `eval`, an `rpc` or a
  `remote`: the whole hook runs only for the commands that start the system.

  `ERL_OTP<major>_FLAGS` is covered along with the rest. It is undocumented and
  described by OTP's own source as for internal use, but `erl` reads it, so a
  `-heart` there is a `-heart` the emulator gets - and because asking is
  unconditional, one set only there is detected like any other.

  The `erl` that is asked is the one the launcher is going to run, and the hook is
  told which that is by the file that decides it: Mix's generated
  `releases/<vsn>/elixir` resolves the emulator through an `ERTS_BIN` it rewrites
  at build time, so the hook reads that assignment out of the same file the
  launcher will, and falls back to `erl` on `PATH` - which is what an
  un-rewritten `ERTS_BIN` means - for a release built with `include_erts: false`.
  That matters because a release root holds more than one `erts-*` as soon as an
  ERTS-changing release has been unpacked into it, and `ERL_OTP<major>_FLAGS` is
  named for the OTP version of whichever emulator answers.

  Where the question cannot be answered - an args file `erl` refuses to read, for
  instance - the hook adds nothing and says so on standard error. The start
  proceeds normally. To support `restart_emulator` upgrades, either make the
  `-emu_args_exit` probe answerable so the hook can add a missing flag, or supply
  exactly one `-heart` through the effective `RELEASE_VM_ARGS` or emulator
  options. A duplicate `-heart` hangs the boot in silence. Adding nothing is the
  safe fallback: an upgrade that needs an emulator restart then fails loudly
  with the system still running. A `vm.args` that is simply *absent* is not such
  a case: the file is passed to `erl` only when it exists, so a release shipping
  none is asked about without it rather than reported unmeasurable.

  All three variables are **assigned**, and `HEART_COMMAND` is **unset**, rather
  than defaulted - so a deployment that already has any of them in its
  environment gets the defanged heart anyway. That is deliberate and it is not
  negotiable while this hook is in use: the supervisor owning the restart is the
  contract the rest of this depends on, and an inherited `HEART_COMMAND`, a
  `HEART_NO_KILL` of anything but `TRUE`, or a shorter `HEART_BEAT_TIMEOUT` each
  break it - the last one by giving a stalled node a way to be killed that a
  release without `-heart` has not got.
  A start that overrides one of them says so on standard error, naming the value
  it displaced and why, because a setting that silently stops taking effect is
  worse than one that is refused - and refusing is what it does *not* do: a
  conflicting variable is a configuration mistake, not a reason to fail a boot. A
  deployment that sets none of them, which is the ordinary case, says nothing. A
  variable that is *set to nothing* counts as a value for the two that are
  assigned, and is reported as `[]`: neither an empty `HEART_NO_KILL` nor an empty
  `HEART_BEAT_TIMEOUT` is the value that replaces it. An empty `HEART_COMMAND`
  stays silent, because unsetting a variable that was already empty changes
  nothing heart can read.
- A test suite. It assembles a real release from a fixture application and, in
  the `:e2e` suite, boots it and upgrades it - once hot, asserting that the
  operating system pid does not change, and once through an emulator restart,
  asserting that it does, that an uncommitted provisional release rolls back when
  it is killed, and that committing makes it the version an ordinary start boots.
  The restart suite runs the whole transition on a deployment whose environment
  already carries a `HEART_COMMAND`, a `HEART_NO_KILL` of `FALSE` and an
  11-second beat timeout, and whose `vm.args` supplies a `-heart` spelled
  `-he\art`, and asks the running node what it was actually started with. That
  start is given a deadline, because a boot handed two `-heart` flags hangs rather
  than fails and would otherwise stop the suite for as long as whatever ran it
  would wait. The `env.sh` hook is also run directly, over a release-shaped directory,
  so that what it selects and what environment it leaves behind are asserted by
  observation rather than by reading the script.
- `mix castle.relup`'s `--fromto`, `--upfrom` and `--downto` now take a
  *baseline spec*: one grammar naming the three places the release being upgraded
  from can come from. `rel:` is an assembled release, `tar:` is a shipped
  artefact, and `ref:` is a git ref that is checked out and built. A value with no
  prefix is a `rel:` path, so every invocation written before this means exactly
  what it meant then. The direction stays on the switch name and the source stays
  in the value. `--target` is not a spec: it names the release being generated
  for, which has just been assembled, and it says so if it is handed one.

  **`tar:` is the source to prefer, and the reason is correctness rather than
  convenience.** `release_handler` selects a relup entry by from-version *string*
  and never checks that the code actually running is the code the relup was
  generated against. A baseline rebuilt from source is built with today's Elixir,
  today's OTP and today's hex tarballs for whatever the lock does not fully pin,
  so its module set can differ from the one that is deployed — and where it does,
  the relup's instructions miss modules and the upgrade loads part of the new
  code over a system still running the rest of the old. A relup generated against
  a rebuilt baseline describes a transition from a release that never existed.

  `ref:` is still the right answer for development, for testing an upgrade path
  before anything ships, and for the common case where nobody kept the artefact —
  and it says on every use that what it produced was rebuilt rather than
  deployed. The commit is checked out into a git worktree, built there, and the
  worktree removed; what it built is kept, because none of it was ever inside the
  worktree. A shallow clone that does not hold the ref is named as such, with the
  `git fetch --tags --unshallow` that fixes it, rather than surfacing as an
  unknown revision from `git worktree add`. A project that does not sit at the top
  of its repository is built where it actually is. And because building an old
  commit runs that commit's own `mix.exs` — which in a project using Castle
  configures its release, and may want a relup of its own — `CASTLE_BASELINE`
  carries the sha being built, and a resolution that finds it set refuses rather
  than recursing.

  Both `tar:` and `ref:` keep what they produced under
  `_build/castle/baselines`, and every entry there is immutable: the work happens
  in a staging directory and the finished thing is renamed into place, so an
  entry exists only once it is whole, an interrupted run leaves nothing a later
  one would take for a usable baseline, and two runs resolving the same baseline
  at once each build their own with the first to finish winning.

  What an entry is keyed on is everything that could change its contents. A
  `tar:` artefact is keyed on a digest of its bytes rather than on its path, so a
  pipeline writing the same filename on every build is never served the previous
  build's release — and the artefact is copied before it is unpacked, so the bytes
  that were hashed are the bytes that get unpacked. A `ref:` baseline is keyed on
  the resolved commit *and* on what it was built with: which project inside the
  commit, the Mix environment and target, and the Elixir version, ERTS version
  and operating system. Without the toolchain versions, upgrading Elixir would
  leave every cached baseline compiled by the old one and the relup would be
  generated between module sets from two different compilers, which is the very
  drift that makes `tar:` the source to prefer; without the project, an
  umbrella's children would share one entry, since they share one `_build`.

  What that key cannot cover is stated rather than approximated: a `mix.exs` is
  arbitrary code and may read anything to decide what it builds. Where a build
  depends on something outside the key, name the artefact with `tar:` or clear
  `_build/castle/baselines`.

  A `tar:` artefact holding anything unpacking would not reproduce as itself is
  refused rather than unpacked in part. Erlang's tar reader writes regular files,
  directories and symlinks; a hard link is dropped and a device node or FIFO
  becomes an empty file, in both cases while still reporting success. A hard link
  is the one that turns up in practice — GNU tar writes one for the second copy
  of a file and a release tree has plenty of those — and it would come out as a
  missing `.beam` and a relup generated against a release short of modules. Two
  members that unpack to the *same* path are refused for the same reason: which
  of them survives is decided by the order they appear in rather than by the
  archive.

  Naming two *different* baselines for the same release version is refused too.
  A relup carries one entry per from-version and `release_handler` selects by
  version, so only one of them could ever be used and which one would depend on
  the order the switches were written in. Specs make that easy to reach without
  meaning to — `tar:my_app-1.0.0.tar.gz` beside `ref:v1.0.0` is a natural thing
  to write while checking the two agree, and they may not. One release named two
  ways is not that, and is not refused: the relative, absolute and symlinked
  spellings of one release are recognised as the one file.

  Two levels are available to callers: an appup coverage check needs only
  `mix compile` in the worktree, while a relup needs `mix release`, and on a real
  project that is a large difference.

  Nothing in this touches worktree registrations it did not make. `git worktree
  prune` would clear a stale one in a word, but it clears every stale one in the
  repository, and a checkout on a disk that is not mounted today looks exactly
  like a dead one — so only registrations inside the baseline cache are removed,
  and never a locked one.
- `mix castle.relup --dry-run` answers *can 1.0.0 be upgraded to 1.1.0 hot, and
  if not, which edge and why* without writing anything, and before any appup has
  been written. It does everything the same invocation without the switch would
  have done — the same announcement included — and then discards the plan.
  Nothing is written where the relup would have gone, including when one is
  already sitting there: the run does not touch that file, and leaves no staging
  file beside it. What it prints says what *it* did rather than what the file now
  holds, since nothing stops another run publishing into the same directory
  while this one generates.

  What "everything" amounts to depends on the strategy, and a dry run is worth
  exactly what the run it stands in for is worth. The baselines are resolved
  under all three. `auto` then classifies each edge and asks `systools` for
  whatever half it judged hot; `--hot` asks `systools` for the whole relup;
  `--restart` reads no appup at all and never reaches `systools`, because writing
  the entries by hand is the whole of what it does — so `--restart --dry-run`
  reports that the releases could be read and the entries built, and nothing
  whatever about appups.

  The exit status is the other half of the answer, and it is about generation:
  zero when the relup could have been generated, non-zero when generation would
  have failed. A dry run that cannot generate fails rather than reporting success
  with a caveat, so a pipeline can ask the question before it builds and act on
  what it is told. Generation ends at the encoded bytes, which is the last step
  that is a property of the plan rather than of the destination — so everything
  that refuses before the write refuses here too, `--outdir` included, and a dry
  run never reports success where an ordinary run would have refused the *plan*.
  What it cannot see is a failure to *publish* one: a directory standing where
  the relup goes, a destination that cannot be written, no space left. Those are
  found by writing, and writing is the one thing this mode does not do.

  It is orthogonal to the strategy and combines with either switch.
  `--hot --dry-run` is the zero-downtime pipeline's question asked before the
  pipeline runs. `--hot` announces nothing of its own on success, which is why
  the dry run prints a line at all — without it that run is a silent exit 0. It
  is not necessarily the only line: `systools` warnings still reach standard
  error under `--dry-run` exactly as they would without it, so the exit status
  rather than the output is what a pipeline should read.

  "Writes nothing" is a promise about the relup and the directory it would have
  gone in, rather than about the run as a whole. A dry run still resolves its
  baselines, and resolving one writes: `tar:` unpacks the artefact into
  `_build/castle/baselines` and `ref:` builds the commit into the same place,
  while `rel:` names a release already on disk and costs nothing. A baseline that
  cannot be resolved is a generation that would have failed, and saying so means
  resolving it.
- `mix castle.appup`, a read-only check that compares two builds of an
  application and reports how the committed appup covers the modules that moved.
  It exits non-zero when one is mentioned by no instruction, which is what makes
  it usable as a release-pipeline gate.

      mix castle.appup --from <spec> [--to <spec>] [--app <app>]...

  **It catches a failure nothing else can see.** The `:appup` compiler never
  sees a second version of the application, so it cannot tell whether the
  instructions it compiles are right. `:systools.make_relup/4` fails when an
  appup has no *entry* for the from-version being upgraded from — but it does
  not, and cannot, notice that an entry is *incomplete*. If two modules changed
  and the appup mentions one of them, the relup generates, the upgrade succeeds,
  `release_handler` swaps the code path, and the unmentioned module is still the
  version that was loaded before, serving calls, because nothing named it and
  nothing purged it. New code sits on disk, reachable, unused, and is loaded on
  the next restart, underneath a system nobody was upgrading.

  `--from` takes a baseline spec, the same grammar `mix castle.relup` takes on
  its from-switches, so the baseline can be an assembled release, the artefact
  that shipped, or a git ref. `--to` defaults to **the current build** rather
  than to an assembled release, so the everyday question — what has changed since
  1.0.0, and does my appup cover it? — costs a `mix compile` and nothing more.
  Given explicitly it compiles nothing at all, so two shipped artefacts can be
  compared without the working tree being in a state that builds. Both are
  resolved at the compile level, so a `ref:` baseline is compiled rather than
  assembled.

  `--app` may be given more than once and defaults to the project's own
  applications plus any umbrella children, which is the same set
  `mix castle.relup` treats as the appups this project owns. Naming a dependency
  explicitly is how its appup gets checked.

  Each direction is reported on its own, because an appup's upgrade and
  downgrade lists are independent and a from-version present in one need not be
  present in the other.

  **It asks whether the appup names everything that moved, and not whether the
  resulting script is one `:systools` will accept.** Only the first question
  needs help: `make_relup/4` already fails loudly on a malformed script, at the
  moment a relup is generated, and what it cannot see is an entry that is
  *incomplete*. Some invalid scripts are reported here anyway, because an
  instruction `:systools` will not accept covers nothing and crediting one would
  overstate coverage — but that is a side effect rather than a promise. A green
  run means the coverage is complete, not that a relup will build.

  **Coverage is judged by what an instruction does, not by which modules it
  names.** `update`, `load_module` and `add_module` put new code into the running
  system; `delete_module` takes code out and loads nothing. So a changed module
  named only by a `delete_module` is not covered — it is *deleted*, out of a
  release that still has it — and that is reported both ways round: as a module
  nothing loads, and as an instruction deleting something the target still
  carries. The whole-application instructions divide the same way:
  `add_application` covers what arrives, `remove_application` what leaves, and
  `restart_application` both.

  What counts as a gap, and so as a non-zero exit: a module that changed or was
  added and that no instruction loads; one that was removed and that no
  instruction deletes; one a `delete_module` names that is still in the target
  build; a module that moved but that the application's own `.app` does not name,
  which `systools_rc` cannot resolve object code for and so no instruction can
  carry; an instruction whose shape is not one `:systools` accepts, which
  `systools_rc` refuses as a `bad_instruction` before it translates anything, so
  the edge produces no relup at all and the instruction covers nothing; no entry
  at all for the from-version; and an application whose modules moved while its
  version did not, since `:systools` consults no appup for an application that
  did not change and so no instruction anywhere could carry that code.

  An instruction is credited only once its *whole shape* is legal rather than by
  its leading elements, and the shapes it is checked against are deliberately no
  wider than `:systools`': being narrower costs a report about an instruction
  that was in fact fine, being wider would let an unusable appup be pronounced
  complete.

  Coverage is the state the script *leaves* each module in rather than membership
  of a loaded set and a removed set, and the low-level `load` and `remove` that
  the high-level instructions translate into count, since they can be written by
  hand. A module the same edge both loads and removes is reported rather than
  resolved: which one wins depends on the order `:systools` translates the
  instructions into, and that is not the order they are written in — it hoists
  dependency-connected instructions past independent ones.

  A module defined by more than one instruction is a gap too. `:systools` refuses
  it as `muldef_module` before producing anything, and an application-level
  instruction counts through its expansion, so `restart_application` beside an
  explicit `update` of one of that application's own modules is refused.

  "Every module of the application" means the `.app` resource's `modules` list
  rather than the beams on disk, because that is what `:systools` expands a
  whole-application instruction over — so a `restart_application` does not cover
  a changed beam the `.app` does not name, and that mismatch is reachable in an
  ordinary build, since a project supplying its own `modules:` list keeps it.

  What is reported and is deliberately *not* a gap: a module an instruction
  mentions that did not change. It is usually a leftover naming the wrong
  module — and where it is, the module that really did change is covered by
  nothing and fails on its own account, so nothing is lost by not failing twice.
  An instruction that loads a module whose code is identical is inert, and a
  pipeline should not go red for something that cannot go wrong.

  Nothing at all is said about an edge that ends by restarting the emulator:
  module-level instructions are moot when the code is going to be loaded from
  scratch by a new VM. Which edges those are is `systools_rc`'s answer rather
  than a reading of the appup's own ordering, and the two differ — a
  `restart_emulator` is moved to the end of the script wherever the appup wrote
  it, and a `restart_new_emulator` on the way *down* is rewritten into one. That
  exemption is per application: a restart supplied by an application `--app` did
  not name, or inserted for an ERTS change, is not visible to a check that reads
  no `.rel`, and coverage is then reported for an edge that would have restarted.
  `mix castle.relup` is what decides restarts properly.

  A module's fingerprint is `:beam_lib.md5/1` together with its persisted
  attributes, and not a digest of the file bytes. A release's beams are stripped
  and rebuilt from a subset of their chunks, so a release's copy of a module is a
  different sequence of bytes from the `_build` copy of identical code, and a byte
  digest would report the whole application as changed; the md5 is stable across
  that stripping, which is what lets the baseline be a stripped release while the
  target is an unstripped build. The md5 alone is not enough either — it covers
  the code and, in `:beam_lib`'s own words, "compilation date and other
  attributes are not included", so two modules differing only in an explicit
  `@vsn` share one. Those attributes are loaded with the module and readable
  through `module_info/1`, and an explicit `@vsn` is exactly what hot-upgrade
  code carries. The attribute list survives stripping unchanged, so pairing the
  two adds sensitivity without adding noise: a `@doc` change still moves nothing
  and still needs no instruction.

  A beam with no `Attr` chunk at all is compared on its md5 alone rather than
  refused. Such a module loads and reports no attributes, so that is what it is
  compared by — and `:beam_lib.strip/1` produces them, so refusing would have
  left the check unable to run against a dependency somebody had stripped that
  way.

  A script element that is itself a list is spliced into the script, exactly as
  `:systools` splices it. `appup(4)` does not document the shape, but
  `systools_rc` accepts one level of it, so a nested instruction counts towards
  coverage and a nested `restart_emulator` really does exempt the edge.

  The check is deliberately not part of `mix precommit`: it needs a baseline,
  and precommit has not got one.

  Three things it refuses rather than reports, because absence is a meaningful
  answer here and a spurious absence would exit zero: a library directory it
  cannot read — a mistyped baseline, most obviously, which no earlier step
  validates — an application directory with no `ebin` in it, and an entry named
  for the application that is not a directory at all, where nothing else in the
  library directory is. Each would otherwise make the application look as though
  the transition added or removed it, which needs no appup and passes.
- `mix castle.appup.gen`, which takes the same arguments and the same diff as the
  check above and drafts the appup entry for the transition, writing it into the
  appup source or merging it into the one that is there.

      mix castle.appup.gen --from <spec> [--to <spec>] [--app <app>]...

  `.gen.` is Elixir's idiom for *this writes source you will review and commit*,
  which is exactly what this is. Nothing generates an appup during assembly and
  nothing here changes that: the `:appup` compiler is untouched and the file it
  compiles stays the single source of truth. The check and the generator read
  both builds through one module, so they cannot disagree about which modules
  moved.

  **What decides the instruction is the behaviour in the beam, and nothing else.**
  A changed module that implements `Supervisor` or `supervisor` gets
  `{:update, M, :supervisor}`; one implementing `GenServer`, `gen_server`,
  `gen_statem`, `gen_event` or `gen_fsm` gets `{:update, M, {:advanced, []}}`;
  anything else gets `{:load_module, M}`. A module in the new build and not the
  old gets `{:add_module, M}`, and one in the old and not the new
  `{:delete_module, M}`. Both attribute spellings are read, including the
  American `-behavior` an Erlang dependency may have been written with.

  It deliberately does **not** classify on `code_change/3` being exported: Elixir
  injects an overridable one into every `use GenServer` module, and the injected
  one cannot be told from a hand-written one at a release's beams, where the
  documentation chunk and the abstract code have both been stripped. A module
  that hand-writes `code_change/3` without declaring a behaviour is therefore a
  `load_module`, which is the honest answer rather than a guess.

  **Every instruction is written with the comments that say what could not be
  decided**, because a draft that hides its uncertainty is worse than no draft.
  The `Extra` term in an `{:advanced, Extra}` is always `[]` and nothing can
  derive it. A `{:update, M, :supervisor}` re-reads `init/1` and reconciles child
  *specs*; it does not upgrade the children, which need instructions of their
  own. `update` only reaches processes found through the supervision tree, so a
  process nobody supervises keeps its old code silently while the entry looks as
  though it covered it. And the ordering is stable rather than correct:
  `add_module` comes first and `delete_module` last, which is the decidable part,
  while the dependency ordering between two changed modules is not computed.

  Three more are said where they apply. An instruction naming a module the
  application's own `.app` does not list is drafted with the reason it cannot
  work: `:systools` resolves object code through that list, so such an
  instruction fails the whole relup with `no_such_module`, and the fix is the
  list rather than the instruction. An advanced update on a module that exports
  no `code_change` says so: the callback is optional in every behaviour that
  calls it, so `@behaviour GenServer` without `use`, and any Erlang callback
  module, can declare the behaviour and export neither — and the install then
  fails with `undef`. Every behaviour the module declares is asked for its own
  arity, since `gen_server` and `gen_event` call `code_change/3` while
  `gen_statem` and `gen_fsm` call `code_change/4`, and which one a running
  process asks for is not visible in a beam. And a module whose behaviour *role*
  differs between the two
  builds is drafted for what it becomes, with a note that the process running now
  was started by the old code and that what it should become is not something an
  instruction decides.

  All three still draft the instruction. Leaving one out silently is the failure
  this tooling exists to catch, arriving from the other direction, and refusing a
  whole entry over one module would take the rest of the application with it.

  **An appup that computes is refused rather than rewritten.** An appup source is
  arbitrary Elixir evaluated for its value, so flattening one into a static term
  would silently discard the logic that decides what it produces. Three cases,
  and the third is what makes the other two safe: no appup yet writes one; an
  appup whose syntax tree is a pure literal gains the entry and the diff is
  printed; an appup that computes anything at all is left alone and the entry is
  printed for you to merge by hand. Which of the two a file is gets decided on
  its parsed syntax tree rather than guessed at from its text.

  A merge inserts the entry as text and touches nothing else, so comments,
  formatting and hand-written entries all survive — including the comments a
  previous run wrote. An entry that is already there for the same from-version is
  never rewritten: once a transition has instructions, they are yours. Where only
  one direction is missing, only that one is added, and the report says so.

  Every result is parsed and read back before it reaches the file: unless it
  reads as exactly the entry that was drafted, nothing is written and the run
  says so. What comes out is itself a pure literal, so the next run can merge
  into it.

  Writing is separate and careful, because verifying the text says nothing about
  the file. A first appup is created exclusively, so a file that appeared while
  the run was working is refused rather than replaced — and a write that fails
  after the file has been created takes it away again, rather than leaving a
  half-written appup the next build cannot evaluate. A merge is written through
  a staging file beside the source and renamed on, keeping the source's mode, so
  a failure part way through cannot leave it neither what it was nor what it was
  going to be — and the bytes are compared against what was read first, so an
  edit made while the run was working is refused rather than discarded.

  **A run that has nothing to write says so rather than reporting success.**
  Nothing moved while the version did writes the entry with an empty script and a
  comment saying that an empty script is the instruction that nothing has to be
  loaded — `:systools` refuses an edge with no entry for the from-version
  outright, so the entry is still required. An appup that already covers the
  transition in both directions is reported and left alone. And it exits non-zero
  rather than writing anything for an application in one build and not the other,
  one whose version did not move, one whose build holds no beams, or an appup it
  will not rewrite.

  It writes the file named by the `:appup` project key. Where there is no key it
  writes `appup.exs` beside `mix.exs` and tells you to add the key and the
  `:appup` compiler. An application that is neither this project nor an umbrella
  child of it — a dependency — is written to
  `rel/appups/<app>-<from>-<to>.exs` instead; see the next entry.

  The output is a draft. Read the comments, then run `mix castle.appup` over it.
- Appups for dependencies, supplied by the project. Most hot upgrades die because
  a dependency bumped a patch version and ships no appup, so `auto` degrades the
  whole edge to a restart — correctly, since there is no hot upgrade to be had.
  The missing piece is usually small, and the project is in a position to supply
  it.

  Put one in `rel/appups`, beside `rel/env.sh.eex`, named for the transition it
  is for — `rel/appups/jason-1.4.0-1.4.2.exs` — holding the same kind of appup
  source the `:appup` key names: arbitrary Elixir evaluated for its value, and
  source you review and commit.
  `mix castle.appup.gen --app jason --from <spec>` drafts one and writes it
  there, asking whether the transition is already covered across *every* source
  for that application rather than only the one it would write — so a sibling
  whose from-version is a regular expression that already matches leaves it a
  no-op rather than a second entry the next build would refuse.
  `mix release` then places it into the assembled release at
  `lib/<app>-<vsn>/ebin/<app>.appup` and names it on standard output, and `auto`
  reads it exactly as it reads an appup a dependency shipped for itself — an
  entry that matches this from-version *is* an instruction for this transition —
  so the edge stays hot instead of degrading to a restart.

  **Nothing is ever written into `deps/`.** That checkout, and `_build`'s copy of
  a dependency, are shared by every release built from the tree and by other
  projects wherever the build cache is shared, so an appup there would be one
  project's upgrade instructions sitting in builds that never asked for them.

  **A stale one fails the build rather than being packaged**, which is what the
  version pair in the name is for. The name is read against the release rather
  than parsed — a version may itself contain a `-`, so splitting on dashes would
  be a guess — by anchoring the application at the front and, at the back, the
  version that release actually carries. A file naming a transition this release
  is not part of is refused, naming the version the release has.

  So are: an application you own, whose appup comes from the `:appup` compiler
  and would be written over after the compiler produced it; a file that does not
  evaluate to an appup, or whose version tag is not the version the release
  carries, or that holds something which is not a `{from_version, instructions}`
  entry; a file whose own appup has no entry for the from-version its name
  claims; two entries for one application that can both be *selected* for one
  version; an appup the application ships for itself that cannot be read; and
  anything in the directory that is not a `.exs` file, dotfiles excepted. Every
  one of those fails before `:assemble`, so a corrected retry has no half-built
  release in its way.

  Several files for one application are merged, in the order the names sort,
  because a release upgradeable from several baselines needs an entry per
  baseline — and since `appup_search_for_version/2` takes the first entry that
  matches, and matches a binary key as a *regular expression*, "can both be
  selected" is asked with that function rather than by comparing keys. A file
  covering only one direction is not refused: `auto` classifies each direction on
  its own and announces the restart it makes of the other.

  **An appup a dependency ships for itself is merged into, not written over.**
  Your entries go first, so where both describe one transition yours is the one
  selected — which is how you correct an appup that is wrong or incomplete — and
  everything the dependency shipped is still in the placed file behind them. The
  build names the shipped file, says how many of its entries were kept, and names
  every one your entries override.

  Two refusals come *after* assembly, because nothing before it can be sure: an
  appup at `lib/<app>-<vsn>/ebin/<app>.appup` that is not the copy Mix made of
  the build's own — or is not a regular file at all, since `mix release`
  preserves an overlay's symlinks — and an application named by a source that has
  no `lib/<app>-<vsn>/ebin` in the assembled release, which is what a release
  built with `include_erts: false` does with OTP's own applications. Both leave
  the release directory behind, so the corrected retry needs
  `mix release --overwrite`; without it `mix release` assembles nothing and exits
  zero.

  One boundary worth knowing: `mix castle.appup --app <dep>` reads the appup out
  of the build `--to` names, and a project-supplied one is only ever in an
  assembled release — so point `--to` at a `rel:` or `tar:` baseline to check it.
- A release may now name the versions it can be upgraded from, with an
  `upgrade_from:` release option, and a single `mix release` then produces a
  tarball with the relup already in it. The value is a list of the same baseline
  specs `mix castle.relup` takes — `rel:`, `tar:` or `ref:` — and each of them
  gets both directions of the transition, generated under `auto`.

  This removes a double build that was mandatory and undocumented. Generating a
  relup needs the target release's `<name>.rel` and its populated `lib/`, and
  those exist only after `:assemble` — so a relup destined for a release meant
  building it, running `mix castle.relup` against what came out, and building it
  again to package the result, with a mutable file in the project root as the
  hand-off between the two. `Forecastle.generate_relup/1` runs between
  post-assembly and `:tar`, where everything it needs exists, and writes the
  relup straight into the version path.

  `Castle.customize/1` places that step for you, immediately before `:tar` and
  after any function step of the project's own — `mix release` documents such a
  step as the way to customise an assembled release, so generating before it
  would describe a tree that `:tar` then packaged differently. Where a release
  has no `:tar` step, generation is appended last. A project spelling its steps
  out by hand needs `&Forecastle.generate_relup/1` immediately before `:tar`, and
  `&Forecastle.refuse_late_upgrade_from/1` last of all.

  **`upgrade_from:` is settled before `:assemble`, and a step of the project's
  own that changes it afterwards is refused**, naming what the release said then,
  what it says now, and where to say it instead. Pre-assembly reads the option
  and resolves the baselines, and what a release asks for is not re-read after
  that. A step setting it later can be too late for a relup to be generated from
  it, and one setting it after `:tar` reaches a build that has already packed an
  archive with no upgrade plan in it, at exit 0 — the outcome this closes.
  Baselines worked out at build time go in a step placed *before* `:assemble`:
  nothing is inserted in front of a project's own pre-assembly steps, so what one
  of them sets is resolved with the rest. Have a step of your own rewrite the
  keyword list it is handed rather than replace it: the check compares against a
  record pre-assembly leaves in the release options, and a fresh list drops it,
  so a release naming baselines with no record beside them is refused too — not
  because they are known to be different, but because nothing there can tell
  whether they are. Omitting `upgrade_from:` altogether stays a no-op whatever a
  step does to the release options.
  Supporting a genuinely late baseline is deferred rather than ruled out.

  What it does when it is given nothing, or something malformed, is part of the
  contract rather than an accident. Omitting `upgrade_from:` is a no-op and
  assembles exactly as before. An `upgrade_from: []` is refused — it is a build
  asking for an upgrade plan and naming nothing to generate one against, and
  assembling that in silence would produce a release with no relup and no
  complaint. A malformed spec, and a repeated `upgrade_from:`, are both refused
  before `:assemble` runs, and so is a baseline that cannot be resolved at all —
  a `tar:` that is not there, a `ref:` that does not build — so a corrected retry
  has no half-built release in its way. A baseline that resolves to no release,
  or to a directory holding none of the applications it names, fails the build
  naming what could not be read, rather than reading as a transition in which
  everything was removed.

  What is left that can only fail *after* assembly is reading the target's `.rel`
  and asking `:systools` for a script, both of which need the assembled release.
  Such a failure leaves the release on disk without a relup, and the build is
  retried with `--overwrite`: `mix release` decides whether to run its steps
  before any step is reached, so a plain retry into a directory that already
  holds a release assembles nothing, whatever a step would prefer.

  A hand-written `relup` in the project root and `upgrade_from:` together are
  refused, naming both. They are two upgrade plans for one release and only one
  can be packaged, so which of them was discarded would be invisible in the
  assembled release. Hand-written relups are otherwise unchanged, and
  `mix castle.relup` still covers what this cannot: a target release that already
  exists rather than one this build is producing, and the `--hot` and `--restart`
  strategies. Whether anything is rebuilt is a property of the baseline spec in
  either case — `rel:` and `tar:` name something already built, `ref:` runs that
  commit's build.

  One tension, accepted: with `ref:`, an ordinary `mix release` triggers a build
  of a previous version as a side effect. It is opt-in and `tar:` is both fast
  and the recommended source. Building that commit runs its own `mix.exs`, so a
  baseline would ask for a baseline of its own — that is refused rather than
  recursed, and a `mix.exs` naming a `ref:` baseline should leave the option out
  when `CASTLE_BASELINE` is set in the environment.

- An upgrade test harness, so a project can test that its own release survives
  the upgrade rather than only that it builds. `Forecastle.UpgradeCase` is an
  `ExUnit.CaseTemplate` and `Forecastle.Deployment` drives a release from
  outside: it lays a baseline out in a directory of its own, starts it under the
  stock Mix launcher, runs `bin/castle` and `rpc` against it, and stands in for
  the external supervisor a transition that restarts the emulator needs. Both
  ship as ordinary library code, so `mix test` runs an upgrade test like any
  other test — and because Castle takes Forecastle as `runtime: false`, they are
  there at build and test time and never enter a release.

  ```elixir
  defmodule MyApp.UpgradeTest do
    use Forecastle.UpgradeCase

    @moduletag :upgrade

    setup_all %{scratch: scratch} do
      deployment =
        Deployment.deploy!("tar:artifacts/myapp-1.0.0.tar.gz", Path.join(scratch, "deploy"))

      on_exit(fn -> Deployment.stop(deployment) end)

      Deployment.start!(deployment)
      Deployment.rpc!(deployment, "IO.puts(MyApp.Counter.bump())")

      Deployment.stage!(deployment, "_build/prod/myapp-1.1.0.tar.gz")
      Deployment.castle!(deployment, ["unpack", "1.1.0"])
      Deployment.castle!(deployment, ["install", "1.1.0"])
      Deployment.castle!(deployment, ["commit"])

      {:ok, deployment: deployment}
    end

    test "moved to 1.1.0 and took the count with it", %{deployment: deployment} do
      assert Deployment.rpc!(deployment, "IO.puts(inspect(MyApp.Counter.info()))") ==
               ~s({"1.1.0", 1})

      assert Deployment.version(deployment) == "1.1.0"
    end
  end
  ```

  **Nothing in it decides whether the upgrade worked**, and that is why it is a
  case template rather than a task. What "worked" means is the project's to say —
  a counter that kept counting for one, a socket still open or a job still in
  flight for another — and a task would have had to hardcode one answer. As a
  case template it composes with tags, with CI and with the project's own
  assertions.

  What it does have to say about writing them is that a count which survived is
  not evidence that anything moved: an appup that does not mention a module
  leaves that module's old code serving calls, and unchanged code preserves a
  count perfectly. So the assertion above reads a version the module carries as
  a compile-time literal — a fact about the code executing the call — alongside
  `Deployment.version/1`, which is the fact about the release, and they are
  different questions. `Forecastle.UpgradeCase` documents the shape of such a
  module.

  The release under test is named with the same baseline grammar as
  `upgrade_from:` and `mix castle.relup`, so it can be the artefact that actually
  shipped (`tar:`), a release already on disk (`rel:`), or a git ref built in a
  worktree (`ref:`). `tar:` is the one to prefer here for the same reason relup
  generation prefers it: `release_handler` selects a relup entry by from-version
  string and never checks it against the code that is running, so an upgrade
  tested from a baseline rebuilt today is an upgrade tested from a release nobody
  ever deployed. A deployment is a copy rather than the resolved baseline — a
  system started in the cache under `_build/castle/baselines` would leave every
  later resolution of that spec holding a booted, half-upgraded release — and
  deploying **refuses a destination whose release is still running** rather than
  emptying the directory underneath it, since a run interrupted before its
  teardown leaves a node that a recursive delete does not stop and that still
  answers to the release's name.

  A release is given 20 seconds to answer after it has been started, which
  describes one that does nothing on the way up; an application that runs
  migrations or waits on a dependency says how long it wants with
  `boot_timeout:`. What the deadlines do is fail the test: nothing in Elixir can
  reach the operating system process behind `System.cmd/3`, so a launcher that
  hung is still hung when the failure is reported, and the harness says so
  rather than leaving the impression it tidied up.

  Both kinds of transition are covered. A hot upgrade installs through
  `Deployment.castle!/3`; one that restarts the emulator installs through
  `Deployment.install_supervised!/3`, which waits for the old operating system
  process to go and starts the release again — because `bin/start` is inert,
  `HEART_COMMAND` is unset, and the supervisor outside the release owns the
  restart. There is deliberately no single call for both: a hot upgrade never
  leaves its process, so waiting for that process to exit would be waiting for
  something that is not coming. It raises the way `castle!/3` does, and what it
  is usually raising about is on the far side of the reboot — `bin/castle
  install` polls for the version it installed *after* the release has come back,
  so a provisional release that rolled back on the way up is reported there and
  nowhere earlier. `Deployment.install_supervised/3` returns `{output, status}`
  for a test that wants to assert on the status itself.

  Every command a deployment runs is given an environment with the variables that
  would otherwise leak into it unset: the emulator flag variables
  (`ELIXIR_ERL_OPTIONS`, `ERL_AFLAGS`, `ERL_FLAGS`, `ERL_ZFLAGS`,
  `ERL_OTP<major>_FLAGS`) and **every variable the generated launcher takes as a
  default** — `RELEASE_VM_ARGS`, `RELEASE_BOOT_SCRIPT`, `RELEASE_SYS_CONFIG`,
  `RELEASE_MODE`, `RELEASE_DISTRIBUTION`, `RELEASE_NODE` and the rest, each of
  which redirects the release at something other than its own rather than merely
  adding to it. `MIX_ENV` because a deployed release is started with no Mix at all,
  while one started from a test run inherits `test` — and `config/runtime.exs`
  is the one file a project routinely shares between the two. A `-heart` in a
  developer's shell or a CI image would otherwise reach
  every release the tests start, and a release that already supplies one is then
  given two, which hangs the boot having printed nothing.
  `Deployment.scrubbed_env/1` exposes the same list for the `mix release` that
  builds the versions being tested.

### Changed

- `bin/castle` now uses shorter, plainer help and error messages. Diagnostics
  lead with the problem and give the recovery step directly; command behaviour,
  exit statuses and output streams are unchanged.
- **Breaking:** `mix forecastle.relup` is now `mix castle.relup`. The task is
  still implemented in Forecastle and still ships with it; only the name has
  changed. Where build-time code lives is a packaging decision and what the task
  is called is a user-interface one, and making the two agree split the
  vocabulary in half: an operator ran `bin/castle install` while a developer ran
  `mix forecastle.relup`, against a package that is, by design, in nobody's
  `mix.exs`. Both READMEs say to depend on `Castle`, so `castle.*` is the name
  the user already thinks in. There is no compatibility alias — a shim for a
  package documented as not taken directly is code maintained forever for a user
  who does not exist — so rename the invocation in any build pipeline that calls
  it. `mix compile.appup` is unaffected: it is named by its `:compilers` entry
  rather than by a package.
  ([forecastle#24](https://github.com/ausimian/forecastle/issues/24))
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
  `env.sh` the project supplied. It also configures `heart` and selects a
  provisional version after an emulator restart — see *Added* — and everything in
  it is now gated on a command that starts the system, so an `eval`, an `rpc` or
  a `remote` reaches none of it.

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
- `mix castle.relup` with no strategy switch is now `auto`, which changes what
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
    which continues across the reboot and which Castle does not support. `auto`
    now decides this case for itself, as a one-stage restart
    transition, and announces it. `--restart` generates the same thing on
    request. **Materially changed.**
  - **An appup that names an emulator restart itself** was passed straight
    through, and the relup was written with the restart in it without anybody
    being told. `auto` now announces a one-stage `restart_emulator` and refuses
    the two-stage `restart_new_emulator`; `--hot` refuses both; and `--restart` -
    which reads no appup at all - makes the transition a `restart_emulator` by
    its own choosing. **Materially changed.**

  So the two cases that changed are the two that used to write a relup carrying
  an emulator restart; the other two are a hot upgrade that is still a hot
  upgrade, and a failure that is still a failure.

  `--hot` is **not** the previous behaviour and is not the way back to it: it
  refuses an appup-supplied emulator restart that the old task packaged. What it
  is good for is a pipeline that wants the generation to fail rather than degrade.
  `--restart` is the way to get a relup out of the two changed cases.
- A `mix castle.relup` run that fails now writes nothing at all. It used to
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
- `mix castle.relup` now requires at least one of `--fromto`, `--upfrom` or
  `--downto`. It used to accept none and write a relup with no transitions in it,
  which is not an upgrade plan and which `release_handler` can do nothing with.
- Raised the minimum Elixir requirement to 1.18.

### Security

- Rejected release versions and invalid environment settings are shown with a
  reversible, single-line representation. Diagnostics name the command and
  preserve visible ASCII; other bytes are percent-encoded, so paths remain
  identifiable without letting control bytes forge logs or drive a terminal.
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
  success for an install that had failed. Managed versions must be valid UTF-8
  and contain no C0, DEL or C1 controls. If that validation is unavailable, the
  command refuses the version and names the failed validation. The same sink
  existed in the launcher Forecastle used to generate.

  Which versions are accepted does not depend on the locale the release
  inherited. Neither script expresses the forbidden bytes as a `[[:cntrl:]]`
  character class, because a shell resolves that against its locale: dash and a
  C-locale bash match C0 and DEL, while a UTF-8 bash also matches the C1 block,
  and glibc puts U+2028 and U+2029 in the class as well. A literal set of the C0
  bytes and DEL is used instead, so the answer is the same under every supported
  shell. `bin/castle` keeps that set only as a shortcut in front of the byte
  decoder, which remains authoritative for invalid UTF-8 and C1; the `env.sh`
  fragment, which deliberately forks no tool to choose a version, refuses C0 and
  DEL and leaves C1 to the marker comparison and the version-directory check
  that already have to pass.

### Fixed

- A deployment's first `bin/<name> daemon` no longer prints a stopped Erlang VM
  and a proposed reboot while successfully starting the daemon. Those lines came
  from the short-lived VM that creates `releases/RELEASES`: Forecastle added its
  own `-heart` before launching the helper, so heart reported the helper's
  orderly exit immediately before the real daemon started. Forecastle now waits
  for that helper to return before adding its flag. It still clears
  `HEART_COMMAND` and assigns the no-kill and maximum-timeout settings first,
  keeping the helper safe when a deployment supplies a heart flag of its own.
- `Forecastle.steps/1` no longer splices a second `&Forecastle.generate_relup/1`
  into a steps list that already has one. A project that packs its own archive in
  a step of its own is told to place generation itself, so the one documented
  arrangement produced two — the summary printed twice, and the spliced step ran
  *after* the packing, leaving the archive and the version path holding different
  upgrade plans with nothing said about it. A generation step placed where its
  relup can be packaged now keeps its position; one placed before `:assemble`
  does not count, because it cannot generate anything there.
- A `&Forecastle.generate_relup/1` placed after `:tar` is now refused by name,
  before anything is assembled and again immediately before `:tar`. `mix release`
  allows a function step on either side of `:tar`, but `:tar` packs the version
  directory — so generation afterwards can never reach the archive, and the build
  would announce the upgrade plan it had generated and exit 0 having shipped an
  artefact with none in it. A release that sets no `:upgrade_from` is unaffected:
  generation does nothing there, so the placement costs nothing and the build is
  left alone — which is why the check happens twice rather than once, since a
  step of your own can add the option after the first has passed. Such a build is
  refused for the placement it chose, which is the thing it can move; the option
  it added is refused in its own right too, a step further on.
- `mix castle.relup` now refuses a baseline whose version is the version being
  generated for, naming the file. `:systools` accepts such a pair and generates
  an entry from the version to itself, and since `release_handler` selects an
  entry by the version it is upgrading *from* — and will not unpack a version a
  deployment already has — that entry could never be used, while the run
  packaged it as the release's upgrade plan without a word. The easiest way to
  reach it is a release assembled twice into one path with `upgrade_from:`
  naming that path.
- `mix castle.relup` no longer announces its upgrade strategy before the relup
  has been written. The `auto` and `--restart` verdicts are claims about a file,
  and encoding, opening, writing, closing or renaming can each fail — leaving
  either no relup or, as the publication contract promises, the previous one. A
  failed run could therefore report that every transition was a hot upgrade and
  produce no such relup. The verdict is now printed only once publication has
  succeeded.
- Argumentless `bin/castle commit` now uses a dedicated machine result instead
  of matching human-facing text in command output. Its diagnostic can change
  without changing the exit status, and launcher output around the result is
  preserved. A recognised result remains authoritative if the launcher exits
  afterwards. If no result can be read safely, the command withholds the machine
  output, reports that permanence is unknown and points to `bin/castle releases`.
  Install's lost-connection check is isolated as a whole-line launcher
  diagnostic, so ordinary error copy cannot trigger the restart-confirmation
  path.
- `mix castle.relup` failed with `:systools is not available` in projects
  that do not themselves depend on `:sasl`, because Elixir prunes unused OTP
  applications from the build's code path.
- `mix castle.relup` exited 0 when it had generated nothing.
  `:systools.make_relup/4` reports ordinary failure by returning `:error`, and
  Mix does not turn what a task returns into an exit status, so a build
  pipeline could not tell that generation had failed. Nothing removes a relup
  the task did not write, so the build then went on to package whatever plan an
  earlier run had left in the project root, as this version's. The task now
  says what `systools` could not do and fails. Warnings that `systools` used to
  print for itself - an ERTS version change among them - are passed on rather
  than swallowed.
- `mix castle.relup --outdir` was accepted and then ignored, so the relup
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
- `mix castle.relup` discarded arguments it did not recognise, so a
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

`bin/start` is new, so it does appear, and both the heart configuration and the
provisional-version selection live in the version directory's `env.sh`, which a
hot upgrade does replace. So a deployment that takes one hot upgrade to this
release can take a restart transition after it. What it cannot do is take a
restart transition *as* the first upgrade from an older deployment: the node is
running from the old version's `env.sh`, so it has no `heart` process, and
`release_handler` calls `heart:set_cmd/1` while preparing the reboot - which
raises, and the install fails before anything reboots. Get to this release with a
hot upgrade or a redeploy first.

Configuration is decided per version directory, so a deployment part way through
this migration is coherent rather than confused: the version it is running keeps
its `build.config`, and a restart back into it is still expanded the old way — by
that version's own `env.sh` and its own copy of Castle, both of which the upgrade
leaves where they are — while the version it is upgraded to has a `sys.config`
and is resolved in a peer. Nothing has to be converted in place, and nothing in
the new version reads the old file.

### Known limitations

- **An emulator restart needs an external supervisor, and the release will not
  restart itself.** The reboot is the point at which something outside the
  release has to start it again: `bin/start` is inert on purpose, `HEART_COMMAND`
  is unset, and nothing else in the release is watching. A deployment run by hand
  from a shell, rather than under systemd, Docker, Kubernetes or runit, therefore
  stays down after such an upgrade until somebody starts it - and the version it
  comes back on is the one that was installed, because the markers are still
  there waiting to be consumed.
- **`restart_new_emulator` is not supported.** The two-stage transition - a
  hybrid temporary release, a reboot into it, and the rest of the relup applied
  on the way up - is refused wherever it turns up rather than generated. An ERTS
  change, which is what `systools` would otherwise insert it for, is taken out of
  `systools`' hands and treated as a one-stage restart transition instead.
  Supporting the two-stage transition properly is its own piece of work, and not
  only because the provisional boot would have to come up and *resume* an upgrade:
  the version `release_handler` writes into `new_start_erl.data` for it is the
  temporary hybrid release, whose version directory holds a boot script and a
  configuration and none of the launcher's own files, so there is nothing there
  for a launcher to boot. Castle arms no marker for it for that reason.
- **A system that cannot write `releases/RELEASES` cannot be upgraded, only
  restarted.** The release creates the file on its first start. Where that fails
  — a deliberately read-only release root is an ordinary case — the start warns,
  the system can run and restart, and `bin/castle unpack` and `bin/castle install`
  refuse. If the deployment is intended to be writable, fix the reported error
  and restart once before upgrading. A running system cannot be repaired in
  place because `release_handler` reads the file only in its `init`.
- Windows releases are not supported; see above. What is missing is now
  `bin/castle` rather than a bootable release.
